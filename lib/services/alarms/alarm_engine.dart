import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../app/project_controller.dart';
import '../../models/alarm.dart';
import '../../models/tag.dart';
import '../runtime/hmi_runtime.dart';
import '../runtime/tag_codec.dart';
import '../runtime/tag_store.dart';

/// Em que pé está um alarme (ANSI/ISA-18.2 §11.3.2, Tabela 4).
enum AlarmPhase {
  /// Condição presente, ninguém reconheceu: **pisca**.
  activeUnack,

  /// Condição presente, reconhecido: fixo.
  activeAck,

  /// Condição sumiu antes do reconhecimento: continua na lista, esperando
  /// alguém confirmar que viu (senão o alarme "passaria batido").
  returnedUnack,
}

extension AlarmPhaseMeta on AlarmPhase {
  bool get unacked => this != AlarmPhase.activeAck;
  bool get active => this != AlarmPhase.returnedUnack;

  String get label => switch (this) {
        AlarmPhase.activeUnack => 'Não reconhecido',
        AlarmPhase.activeAck => 'Reconhecido',
        AlarmPhase.returnedUnack => 'Voltou ao normal',
      };
}

/// Um alarme na lista (ativo ou esperando reconhecimento).
class AlarmEntry {
  const AlarmEntry({
    required this.key,
    required this.priority,
    required this.message,
    required this.phase,
    required this.since,
    this.tagId,
    this.deviceId,
    this.rule,
    this.valueText = '',
  });

  /// `regra:<tagId>:<ruleId>` ou `com:<deviceId>` (falta de comunicação).
  final String key;
  final AlarmPriority priority;
  final String message;
  final AlarmPhase phase;
  final DateTime since;
  final String? tagId;
  final String? deviceId;
  final AlarmRule? rule;

  /// Valor quando ativou ("88,2 °C").
  final String valueText;

  bool get isComm => key.startsWith('com:');

  AlarmEntry copyWith({AlarmPhase? phase, DateTime? since, String? valueText}) => AlarmEntry(
        key: key,
        priority: priority,
        message: message,
        phase: phase ?? this.phase,
        since: since ?? this.since,
        tagId: tagId,
        deviceId: deviceId,
        rule: rule,
        valueText: valueText ?? this.valueText,
      );
}

enum AlarmEventType { activated, acknowledged, returned }

extension AlarmEventTypeMeta on AlarmEventType {
  String get label => switch (this) {
        AlarmEventType.activated => 'Ativou',
        AlarmEventType.acknowledged => 'Reconhecido',
        AlarmEventType.returned => 'Normalizou',
      };
}

/// Linha do histórico.
class AlarmEvent {
  const AlarmEvent({required this.at, required this.type, required this.priority, required this.message, this.valueText = ''});

  final DateTime at;
  final AlarmEventType type;
  final AlarmPriority priority;
  final String message;
  final String valueText;

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'type': type.name,
        'priority': priority.name,
        'message': message,
        if (valueText.isNotEmpty) 'value': valueText,
      };

  static AlarmEvent? fromJson(Map<String, dynamic> j) {
    final at = DateTime.tryParse(j['at'] as String? ?? '');
    if (at == null) return null;
    return AlarmEvent(
      at: at,
      type: AlarmEventType.values.firstWhere((t) => t.name == j['type'], orElse: () => AlarmEventType.activated),
      priority: AlarmPriorityMeta.fromName(j['priority'] as String?),
      message: j['message'] as String? ?? '',
      valueText: j['value'] as String? ?? '',
    );
  }
}

/// Regra pura de disparo — separada para ser testada sem app.
class AlarmLogic {
  AlarmLogic._();

  /// A condição está presente? Com **banda morta** na volta: acima de 85
  /// só normaliza abaixo de 84,15 (1% do limite). Sem ela, um valor
  /// oscilando em cima do limite liga/desliga o alarme sem parar — o
  /// "alarme tagarela" que a EEMUA 191 manda eliminar.
  static bool condition(AlarmRule rule, Object? value, {required bool wasActive}) {
    switch (rule.kind) {
      case AlarmKind.on:
        return value == true;
      case AlarmKind.off:
        return value == false;
      case AlarmKind.above:
      case AlarmKind.below:
        if (value is! num) return false;
        final db = wasActive ? (rule.limit.abs() * 0.01) : 0.0;
        return rule.kind == AlarmKind.above ? value > rule.limit - db : value < rule.limit + db;
    }
  }

  /// Texto padrão quando a regra não tem mensagem: "Temperatura do motor
  /// acima de 85 °C".
  static String defaultMessage(Tag tag, AlarmRule rule) => switch (rule.kind) {
        AlarmKind.above => '${tag.name} acima de ${TagCodec.format(tag, rule.limit)}',
        AlarmKind.below => '${tag.name} abaixo de ${TagCodec.format(tag, rule.limit)}',
        AlarmKind.on => '${tag.name} ligado',
        AlarmKind.off => '${tag.name} desligado',
      };
}

/// Motor de alarmes: vigia as variáveis que têm alarme — **em qualquer tela**,
/// não só na que está aberta (alarme só na tela que ninguém está olhando não
/// é alarme) — e mantém a lista e o histórico.
///
/// Enquanto o app está aberto, as variáveis com alarme ficam inscritas no
/// [HmiRuntime] (o equipamento continua sendo lido). Com o app em segundo
/// plano a leitura para (bateria), então **não há alarme com o app
/// fechado** — limite documentado em ARQUITETURA.md.
class AlarmEngine extends ChangeNotifier {
  AlarmEngine({required this.controller, required this.runtime, this.historyFile, this.onDelay = const Duration(seconds: 1)}) {
    controller.addListener(_sync);
    _sync();
    unawaited(_loadHistory());
  }

  static final Logger _log = Logger('AlarmEngine');

  /// Máximo guardado no histórico (o mais antigo sai).
  static const historyLimit = 300;

  final ProjectController controller;
  final HmiRuntime runtime;
  final Future<File> Function()? historyFile;

  /// A condição precisa persistir por este tempo para disparar — um pico de
  /// uma leitura só não vira alarme.
  final Duration onDelay;

  final Map<String, AlarmEntry> _entries = {};
  final Map<String, DateTime> _pending = {};
  final List<AlarmEvent> _history = [];
  final Map<String, VoidCallback> _listeners = {};
  TagSubscription? _sub;
  Set<String> _watched = const {};
  Timer? _blinkTimer;
  Timer? _saveTimer;
  bool _disposed = false;

  final ValueNotifier<bool> _blink = ValueNotifier(true);
  final ValueNotifier<int> _newAlarm = ValueNotifier(0);

  /// Fase do piscar (1 Hz) — só corre enquanto há alarme não reconhecido.
  ValueListenable<bool> get blink => _blink;

  /// Sobe a cada alarme novo (a faixa vibra o celular).
  ValueListenable<int> get newAlarm => _newAlarm;

  /// Ativos e à espera de reconhecimento: prioridade primeiro, mais novo em cima.
  List<AlarmEntry> get entries {
    final list = _entries.values.toList()
      ..sort((a, b) {
        final p = a.priority.index.compareTo(b.priority.index);
        return p != 0 ? p : b.since.compareTo(a.since);
      });
    return list;
  }

  /// Histórico, mais novo primeiro.
  List<AlarmEvent> get history => List.unmodifiable(_history.reversed);

  int get unackCount => _entries.values.where((e) => e.phase.unacked).length;
  bool get hasAny => _entries.isNotEmpty;

  /// O alarme mais grave de uma variável (o elemento da tela se pinta com ele).
  AlarmEntry? forTag(String tagId) {
    AlarmEntry? best;
    for (final e in _entries.values) {
      if (e.tagId != tagId) continue;
      if (best == null || e.priority.index < best.priority.index) best = e;
    }
    return best;
  }

  // ── Reconhecer ──────────────────────────────────────────────────────────────

  void acknowledge(String key) {
    final e = _entries[key];
    if (e == null || !e.phase.unacked) return;
    _log.info('Reconhecido: ${e.message}');
    _addEvent(AlarmEvent(at: clock.now(), type: AlarmEventType.acknowledged, priority: e.priority, message: e.message, valueText: e.valueText));
    if (e.phase == AlarmPhase.returnedUnack) {
      _entries.remove(key);
    } else {
      _entries[key] = e.copyWith(phase: AlarmPhase.activeAck);
    }
    _changed();
  }

  void acknowledgeAll() {
    for (final k in [..._entries.keys]) {
      acknowledge(k);
    }
  }

  // ── Vigiar ──────────────────────────────────────────────────────────────────

  /// Projeto mudou: refaz a lista de variáveis vigiadas e tira da lista
  /// alarmes de regras que não existem mais.
  void _sync() {
    if (_disposed) return;
    final project = controller.project;
    final ids = {for (final t in project.tags) if (t.alarms.isNotEmpty) t.id};

    for (final id in _watched.difference(ids)) {
      final l = _listeners.remove(id);
      if (l != null) runtime.watch(id).removeListener(l);
    }
    for (final id in ids.difference(_watched)) {
      void l() => _evaluate(id);
      _listeners[id] = l;
      runtime.watch(id).addListener(l);
    }
    if (ids.length != _watched.length || !ids.containsAll(_watched)) {
      final old = _sub;
      _sub = ids.isEmpty ? null : runtime.subscribe(ids);
      old?.cancel();
    }
    _watched = ids;

    final valid = <String>{
      for (final t in project.tags)
        for (final r in t.alarms) _ruleKey(t.id, r.id),
      for (final t in project.tags)
        if (t.alarms.isNotEmpty) 'com:${t.deviceId}',
    };
    final before = _entries.length;
    _entries.removeWhere((k, _) => !valid.contains(k));
    _pending.removeWhere((k, _) => !valid.contains(k));
    if (_entries.length != before) _changed();
    for (final id in ids) {
      _evaluate(id);
    }
  }

  static String _ruleKey(String tagId, String ruleId) => 'regra:$tagId:$ruleId';

  void _evaluate(String tagId) {
    if (_disposed) return;
    final tag = controller.project.tag(tagId);
    if (tag == null) return;
    final reading = runtime.watch(tagId).value;
    final now = clock.now();
    var changed = false;

    // Sem comunicação: os alarmes da variável ficam como estão (não dá para
    // saber se normalizou) e o equipamento ganha um alarme próprio.
    final commKey = 'com:${tag.deviceId}';
    if (reading.quality == TagQuality.commLost) {
      if (!_entries.containsKey(commKey)) {
        final device = controller.project.device(tag.deviceId);
        _activate(AlarmEntry(
          key: commKey,
          priority: AlarmPriority.medium,
          message: 'Sem comunicação com ${device?.name ?? 'o equipamento'}',
          phase: AlarmPhase.activeUnack,
          since: now,
          deviceId: tag.deviceId,
        ));
        changed = true;
      }
      if (changed) _changed();
      return;
    }
    if (reading.quality == TagQuality.good && _entries[commKey]?.phase.active == true) {
      changed |= _normalize(commKey);
    }
    if (reading.quality != TagQuality.good) {
      if (changed) _changed();
      return;
    }

    for (final rule in tag.alarms) {
      final key = _ruleKey(tag.id, rule.id);
      final entry = _entries[key];
      final wasActive = entry?.phase.active ?? false;
      final cond = AlarmLogic.condition(rule, reading.value, wasActive: wasActive);
      if (cond) {
        if (wasActive) continue;
        final since = _pending.putIfAbsent(key, () => now);
        if (now.difference(since) < onDelay) continue;
        _pending.remove(key);
        _activate(AlarmEntry(
          key: key,
          priority: rule.priority,
          message: rule.message.trim().isEmpty ? AlarmLogic.defaultMessage(tag, rule) : rule.message.trim(),
          phase: AlarmPhase.activeUnack,
          since: now,
          tagId: tag.id,
          deviceId: tag.deviceId,
          rule: rule,
          valueText: TagCodec.format(tag, reading.value),
        ));
        changed = true;
      } else {
        _pending.remove(key);
        if (wasActive) changed |= _normalize(key);
      }
    }
    if (changed) _changed();
  }

  void _activate(AlarmEntry e) {
    _log.warning('Alarme ${e.priority.label}: ${e.message}');
    _entries[e.key] = e;
    _addEvent(AlarmEvent(at: e.since, type: AlarmEventType.activated, priority: e.priority, message: e.message, valueText: e.valueText));
    _newAlarm.value++;
  }

  /// Condição sumiu: reconhecido sai da lista; não reconhecido fica
  /// "voltou ao normal" esperando alguém confirmar.
  bool _normalize(String key) {
    final e = _entries[key];
    if (e == null) return false;
    _addEvent(AlarmEvent(at: clock.now(), type: AlarmEventType.returned, priority: e.priority, message: e.message));
    if (e.phase == AlarmPhase.activeAck) {
      _entries.remove(key);
    } else {
      _entries[key] = e.copyWith(phase: AlarmPhase.returnedUnack);
    }
    return true;
  }

  // ── Piscar e avisar ─────────────────────────────────────────────────────────

  void _changed() {
    if (_disposed) return;
    // Pisca só com alarme não reconhecido: timer de 500 ms (2 quadros/s),
    // nunca animação contínua — e para sozinho quando todos forem vistos.
    if (unackCount > 0) {
      _blinkTimer ??= Timer.periodic(const Duration(milliseconds: 500), (_) => _blink.value = !_blink.value);
    } else {
      _blinkTimer?.cancel();
      _blinkTimer = null;
      _blink.value = true;
    }
    notifyListeners();
  }

  // ── Histórico em disco ──────────────────────────────────────────────────────

  void _addEvent(AlarmEvent ev) {
    _history.add(ev);
    if (_history.length > historyLimit) _history.removeRange(0, _history.length - historyLimit);
    if (historyFile != null) {
      _saveTimer?.cancel();
      _saveTimer = Timer(const Duration(seconds: 1), () => unawaited(_saveHistory()));
    }
  }

  Future<void> _loadHistory() async {
    final f = historyFile;
    if (f == null) return;
    try {
      final file = await f();
      if (!await file.exists()) return;
      final list = jsonDecode(await file.readAsString()) as List;
      final loaded = [
        for (final j in list)
          if (j is Map) ?AlarmEvent.fromJson(Map<String, dynamic>.from(j)),
      ];
      if (_disposed) return;
      _history.insertAll(0, loaded);
      notifyListeners();
    } catch (e) {
      _log.warning('Histórico de alarmes ilegível, começando vazio: $e');
    }
  }

  Future<void> _saveHistory() async {
    final f = historyFile;
    if (f == null) return;
    try {
      final file = await f();
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode([for (final e in _history) e.toJson()]), flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      _log.warning('Não gravou o histórico de alarmes: $e');
    }
  }

  /// Grava o que estiver pendente (app indo para segundo plano).
  Future<void> flush() async {
    if (_saveTimer?.isActive ?? false) {
      _saveTimer?.cancel();
      await _saveHistory();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    controller.removeListener(_sync);
    for (final e in _listeners.entries) {
      runtime.watch(e.key).removeListener(e.value);
    }
    _listeners.clear();
    _sub?.cancel();
    _blinkTimer?.cancel();
    _saveTimer?.cancel();
    _blink.dispose();
    _newAlarm.dispose();
    super.dispose();
  }
}
