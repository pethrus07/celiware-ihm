import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../app/project_controller.dart';
import '../../models/log_group.dart';
import '../../models/tag.dart';
import '../runtime/hmi_runtime.dart';
import '../runtime/tag_store.dart';
import 'log_csv.dart';
import 'log_store.dart';

/// Regra pura de amostragem — separada para ser testada sem app.
class LogSampler {
  LogSampler._();

  /// O que vai para a coluna: número como está, liga/desliga como 1/0.
  /// Texto, lista, infinito e NaN não são graváveis (viram lacuna).
  static double? toNumber(Object? v) {
    if (v is bool) return v ? 1 : 0;
    if (v is num && v.isFinite) return v.toDouble();
    return null;
  }

  /// A amostra de agora vira linha?
  ///
  /// Periódico: sempre. "Ao mudar": quando alguma variável muda além da banda
  /// morta em relação ao último valor **gravado** (deriva lenta acumula e
  /// acaba gravando), quando a comunicação cai ou volta, ou quando passou o
  /// máximo entre amostras — valor parado por horas não pode parecer buraco.
  static bool shouldRecord(LogGroup g, List<Tag> tags, Map<String, double?> sample,
      {Map<String, double?>? last, DateTime? lastAt, required DateTime at}) {
    if (last == null || lastAt == null || g.mode == LogMode.periodic) return true;
    if (at.difference(lastAt) >= g.maxGap) return true;
    for (final t in tags) {
      if (!last.containsKey(t.id)) return true; // variável nova no grupo
      final a = sample[t.id], b = last[t.id];
      if ((a == null) != (b == null)) return true;
      if (a == null || b == null) continue;
      final band = t.dataType == TagDataType.bool ? 0.0 : g.deadband;
      final diff = (a - b).abs();
      if (band == 0 ? diff > 0 : diff >= band) return true;
    }
    return false;
  }
}

/// Um grupo ligado em andamento.
class _Run {
  _Run(this.group, this.tags);
  LogGroup group;
  List<Tag> tags;
  DateTime? nextDue;
  Map<String, double?>? last;
  DateTime? lastAt;
  List<LogRow> pending = [];
}

/// Motor de registro: grava as variáveis dos grupos ligados **em qualquer
/// tela**, com o app aberto (RG-2) — mesmo padrão do `AlarmEngine`: as
/// variáveis ficam inscritas no [HmiRuntime], então o equipamento continua
/// sendo lido sem nenhuma tela aberta.
///
/// - Uma conferência por segundo decide quais grupos venceram o intervalo.
/// - Sem comunicação (ou leitura parada) a coluna fica **nula**: lacuna,
///   nunca o último valor como se fosse bom (RG-3).
/// - As linhas esperam na memória e vão para o banco **em lote**, a cada
///   10 s, numa transação, e na ida para segundo plano (RG-4).
/// - Retenção: de hora em hora apaga o que passou do prazo de cada grupo.
///
/// Com o app em segundo plano a leitura para (bateria), e o registro também:
/// o histórico mostra o buraco. Ponto de extensão do serviço em primeiro
/// plano (REQUISITOS-ETAPA4 §9.6): ver [pause].
class DataLogger extends ChangeNotifier implements ProjectScoped {
  DataLogger({
    required this.controller,
    required this.runtime,
    required this.store,
    Duration? tickEvery = const Duration(seconds: 1),
    Duration? flushEvery = const Duration(seconds: 10),
    this.startupGrace = const Duration(seconds: 10),
  }) {
    controller.addListener(_sync);
    controller.attachScoped(this);
    _sync();
    if (tickEvery != null) _tickTimer = Timer.periodic(tickEvery, (_) => tick());
    if (flushEvery != null) _flushTimer = Timer.periodic(flushEvery, (_) => unawaited(flush()));
    unawaited(_startup());
  }

  static final Logger _log = Logger('DataLogger');

  /// Folga do compasso: o timer de 1 s chega alguns ms antes ou depois.
  static const _slack = Duration(milliseconds: 200);

  /// Retenção conferida de hora em hora (e logo ao abrir).
  static const rotateEvery = Duration(hours: 1);

  final ProjectController controller;
  final HmiRuntime runtime;
  final LogStore store;

  /// Logo depois de abrir (ou de voltar do segundo plano) a primeira leitura
  /// ainda está a caminho: espera até isto antes de gravar lacuna.
  final Duration startupGrace;

  final Map<String, _Run> _runs = {};
  final List<_Run> _leftovers = [];
  final Map<String, VoidCallback> _listeners = {};
  final Map<String, DateTime> _seenAt = {};
  final Map<String, DateTime> _watchedSince = {};
  final Map<String, int> _usage = {};
  TagSubscription? _sub;
  Set<String> _watched = const {};
  Timer? _tickTimer;
  Timer? _flushTimer;
  DateTime? _lastRotation;
  Future<void> _queue = Future.value();
  bool _paused = false;
  bool _disposed = false;
  String? _problem;

  /// Última falha ao gravar (disco cheio, aparelho sem SQLite) — a tela de
  /// registros mostra. Nulo quando está tudo certo.
  String? get problem => _problem;

  /// Bytes no disco de um grupo (banco + diário).
  int usageOf(String groupId) => _usage[groupId] ?? store.sizeOf(groupId);

  /// Linhas ainda na memória, esperando o próximo lote.
  int pendingOf(String groupId) => _runs[groupId]?.pending.length ?? 0;

  // ── Vigiar ──────────────────────────────────────────────────────────────────

  /// Projeto mudou: refaz os grupos em andamento e a lista de variáveis
  /// inscritas.
  void _sync() {
    if (_disposed) return;
    final project = controller.project;
    final next = <String, _Run>{};
    for (final g in project.logGroups) {
      if (!g.enabled) continue;
      final tags = [
        for (final id in g.tagIds)
          if (project.tag(id) case final t? when LogGroup.canLog(t)) t,
      ];
      if (tags.isEmpty) continue;
      final run = _runs[g.id];
      if (run == null) {
        next[g.id] = _Run(g, tags);
        continue;
      }
      if (run.group.intervalSec != g.intervalSec) run.nextDue = null;
      // Retenção diminuiu: apaga o excedente já, não daqui a uma hora.
      if (g.retentionDays < run.group.retentionDays) _lastRotation = null;
      run
        ..group = g
        ..tags = tags;
      next[g.id] = run;
    }
    // Grupo desligado ou apagado: o que já foi amostrado ainda vai para o banco.
    for (final e in _runs.entries) {
      if (!next.containsKey(e.key) && e.value.pending.isNotEmpty) _leftovers.add(e.value);
    }
    _runs
      ..clear()
      ..addAll(next);

    final ids = {for (final r in _runs.values) for (final t in r.tags) t.id};
    final now = clock.now();
    for (final id in _watched.difference(ids)) {
      final l = _listeners.remove(id);
      if (l != null) runtime.watch(id).removeListener(l);
      _seenAt.remove(id);
      _watchedSince.remove(id);
    }
    for (final id in ids.difference(_watched)) {
      // Cada leitura publicada (boa ou não) carimba "visto agora" no relógio
      // do registro: valor bom que parou de chegar não é mais valor bom.
      void l() => _seenAt[id] = clock.now();
      _listeners[id] = l;
      _watchedSince[id] = now;
      runtime.watch(id).addListener(l);
    }
    if (ids.length != _watched.length || !ids.containsAll(_watched)) {
      final old = _sub;
      _sub = ids.isEmpty ? null : runtime.subscribe(ids);
      old?.cancel();
    }
    _watched = ids;
    notifyListeners();
  }

  /// Leitura parada há mais que isto deixa de valer: o laço do equipamento
  /// publica a cada varredura (ou marca "sem comunicação" no tempo-limite).
  Duration _staleAfter(Tag t) {
    final d = controller.project.device(t.deviceId);
    final ms = d == null ? 0 : d.pollMs * 3 + d.timeoutMs * 2;
    return Duration(milliseconds: ms < 10000 ? 10000 : ms);
  }

  // ── Amostrar ────────────────────────────────────────────────────────────────

  /// Amostra os grupos cujo intervalo venceu. O timer chama a cada segundo;
  /// os testes chamam direto, com o relógio controlado (`withClock`).
  void tick() {
    if (_disposed || _paused) return;
    final now = clock.now();
    for (final run in _runs.values) {
      final g = run.group;
      final due = run.nextDue;
      if (due != null && now.isBefore(due.subtract(_slack))) continue;
      // Próxima no compasso do intervalo, não a partir do atraso do timer;
      // muito atrasado (voltou do segundo plano) recomeça a contar daqui.
      run.nextDue = (due == null || now.difference(due) >= g.interval) ? now.add(g.interval) : due.add(g.interval);
      final sample = _sample(run, now);
      if (sample == null) continue;
      if (!LogSampler.shouldRecord(g, run.tags, sample, last: run.last, lastAt: run.lastAt, at: now)) continue;
      run.pending.add(LogRow(now, sample));
      run.last = sample;
      run.lastAt = now;
    }
  }

  /// Valores de agora do grupo, ou nulo se ainda é cedo para saber.
  Map<String, double?>? _sample(_Run run, DateTime now) {
    final out = <String, double?>{};
    for (final t in run.tags) {
      final seen = _seenAt[t.id];
      if (seen == null) {
        // Nenhuma leitura desde que passou a ser vigiada: dentro da folga,
        // espera; depois dela, é lacuna mesmo.
        final since = _watchedSince[t.id] ?? now;
        if (now.difference(since) < startupGrace) return null;
        out[t.id] = null;
        continue;
      }
      final r = runtime.watch(t.id).value;
      final fresh = now.difference(seen) <= _staleAfter(t);
      out[t.id] = r.quality == TagQuality.good && fresh ? LogSampler.toNumber(r.value) : null;
    }
    return out;
  }

  // ── Gravar ──────────────────────────────────────────────────────────────────

  /// Uma operação de disco por vez (lote, retenção, apagar grupo).
  Future<T> _serial<T>(Future<T> Function() f) {
    final run = _queue.then((_) => f());
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Grava o lote pendente numa transação por grupo (RG-4) e cuida da
  /// retenção. O timer chama a cada 10 s; a ida para segundo plano e a tela
  /// de histórico também.
  Future<void> flush() => _serial(() async {
        final work = [..._leftovers, ..._runs.values.where((r) => r.pending.isNotEmpty)];
        _leftovers.clear();
        final problemBefore = _problem;
        for (final run in work) {
          if (run.pending.isEmpty) continue;
          final rows = run.pending;
          run.pending = [];
          try {
            await store.append(run.group, run.tags, rows);
            _problem = null;
          } catch (e) {
            // Sem disco ou sem SQLite: descarta o lote (guardar na memória
            // para sempre derrubaria o app) e avisa na tela de registros.
            _log.warning('Não gravou ${rows.length} linhas de "${run.group.name}": $e');
            _problem = 'Não consegui gravar o registro "${run.group.name}" neste aparelho.';
          }
        }
        if (_problem != problemBefore && !_disposed) notifyListeners();
        await _maintain();
      });

  Future<void> _startup() => _serial(() async {
        try {
          await store.prepare();
          // Grupos que saíram do projeto: valem até a retenção que tinham.
          await store.sweep({for (final g in controller.project.logGroups) g.id}, clock.now());
        } catch (e) {
          _log.warning('Pasta de registros indisponível: $e');
        }
        await _maintain();
      });

  /// Retenção (de hora em hora) e uso de disco por grupo.
  Future<void> _maintain() async {
    final now = clock.now();
    final groups = controller.project.logGroups;
    if (_lastRotation == null || now.difference(_lastRotation!) >= rotateEvery) {
      _lastRotation = now;
      for (final g in groups) {
        try {
          final n = await store.rotate(g.id, now.subtract(Duration(days: g.retentionDays)));
          if (n > 0) _log.info('Registro "${g.name}": $n linhas além de ${g.retentionDays} dias apagadas');
        } catch (e) {
          _log.warning('Retenção de "${g.name}" falhou: $e');
        }
      }
    }
    var changed = false;
    for (final g in groups) {
      final size = store.sizeOf(g.id);
      if (_usage[g.id] != size) {
        _usage[g.id] = size;
        changed = true;
      }
    }
    if (changed && !_disposed) notifyListeners();
  }

  /// Confere a retenção agora (testes; a tela não precisa).
  @visibleForTesting
  Future<void> rotateNow() {
    _lastRotation = null;
    return _serial(_maintain);
  }

  // ── Para as telas ───────────────────────────────────────────────────────────

  /// Histórico de um período, reduzido a [buckets] fatias. Grava o lote
  /// pendente antes: o gráfico mostra até o último segundo.
  Future<LogWindow> history(LogGroup g, {required DateTime from, required DateTime to, required List<String> tagIds, required int buckets}) async {
    await flush();
    return _serial(() => store.query(g.id, from: from, to: to, tagIds: tagIds, buckets: buckets));
  }

  /// Exporta o período para CSV (RG-6) em [dir].
  Future<LogExport> exportCsv(LogGroup g, {required DateTime from, required DateTime to, required Directory dir}) async {
    await flush();
    return _serial(() => LogCsv.export(store: store, group: g, from: from, to: to, dir: dir));
  }

  /// Apaga o grupo do projeto **e** o histórico dele.
  Future<void> deleteGroup(String groupId) {
    controller.deleteLogGroup(groupId);
    _leftovers.removeWhere((r) => r.group.id == groupId);
    return _serial(() async {
      await store.delete(groupId);
      _usage.remove(groupId);
      if (!_disposed) notifyListeners();
    });
  }

  // ── Ciclo de vida ───────────────────────────────────────────────────────────

  /// App indo para segundo plano: a leitura para (bateria), então o registro
  /// também — grava o lote e o histórico mostra o buraco.
  ///
  /// Ponto de extensão: com o serviço em primeiro plano (notificação fixa,
  /// `connectedDevice`, REQUISITOS-ETAPA4 §9.6), o runtime continuaria lendo
  /// e aqui bastaria **não** pausar.
  Future<void> pause() async {
    _paused = true;
    await flush();
  }

  /// Voltou: o que foi lido antes de pausar não vale mais — cada variável
  /// espera uma leitura nova (com a mesma folga da abertura).
  void resume() {
    if (!_paused) return;
    _paused = false;
    final now = clock.now();
    _seenAt.clear();
    for (final id in _watchedSince.keys) {
      _watchedSince[id] = now;
    }
    for (final run in _runs.values) {
      run.nextDue = null;
    }
  }

  // ── Troca de projeto ─────────────────────────────────────────────────────────

  Future<void>? _reopen;

  /// Grava o lote do projeto que sai, nos bancos dele.
  @override
  Future<void> beforeSwitch() => flush();

  /// Esquece os grupos do projeto que saiu e fecha os bancos dele; a pasta
  /// passa a ser a do projeto novo (`registros/<projeto>/`). Fechar entra na
  /// fila de disco antes de qualquer gravação do projeto novo.
  @override
  void onSwitch() {
    _runs.clear();
    _leftovers.clear();
    _usage.clear();
    _lastRotation = null;
    _problem = null;
    final now = clock.now();
    _seenAt.clear();
    for (final id in _watchedSince.keys) {
      _watchedSince[id] = now;
    }
    _reopen = _serial(store.reset);
  }

  /// Abre a pasta do projeto novo e confere a retenção dos bancos dele.
  @override
  Future<void> afterSwitch() async {
    await _reopen;
    await _startup();
  }

  /// Grava o que falta e fecha o banco.
  Future<void> close() async {
    await flush();
    await _serial(store.close);
  }

  @override
  void dispose() {
    _disposed = true;
    controller.removeListener(_sync);
    controller.detachScoped(this);
    for (final e in _listeners.entries) {
      runtime.watch(e.key).removeListener(e.value);
    }
    _listeners.clear();
    _sub?.cancel();
    _tickTimer?.cancel();
    _flushTimer?.cancel();
    unawaited(close());
    super.dispose();
  }
}
