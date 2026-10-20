import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../app/project_controller.dart';
import '../../models/alarm.dart';
import '../../models/logic_rule.dart';
import '../../models/tag.dart';
import '../alarms/alarm_engine.dart';
import '../calc/calc_evaluator.dart';
import '../calc/calc_graph.dart';
import '../runtime/hmi_runtime.dart';
import '../runtime/tag_codec.dart';
import '../runtime/tag_store.dart';

/// Em que pé está uma regra.
enum RuleState {
  /// Desligada pela pessoa.
  off,

  /// Vigiando: a condição não está presente.
  watching,

  /// A condição está presente e o tempo está contando.
  counting,

  /// Já agiu (ou propôs) nesta passagem; espera a condição sumir para valer
  /// de novo — dispara na transição, nunca em laço (LG-4).
  acted,

  /// Não pode rodar: sem comunicação, destino sem permissão, condição com
  /// erro. Vira alarme (LG-7).
  blocked,
}

/// Estado de uma regra para a tela: o quê e por quê.
@immutable
class RuleStatus {
  const RuleStatus(this.state, [this.message = '']);
  final RuleState state;
  final String message;

  static const off = RuleStatus(RuleState.off);
  static const watching = RuleStatus(RuleState.watching);
}

/// Uma proposta à espera da pessoa (LG-6): "Parar a prensa?" [Ignorar] [Desligar].
@immutable
class RuleProposal {
  const RuleProposal({required this.ruleId, required this.question, required this.detail, required this.action, required this.since});
  final String ruleId;

  /// "Parar a prensa?"
  final String question;

  /// 'Grava DESLIGADO em "Liga prensa" (Prensa)'.
  final String detail;

  /// O verbo do botão: Desligar, Ligar ou Gravar.
  final String action;
  final DateTime since;
}

enum RuleEventType { fired, proposed, written, ignored, withdrawn, failed, stopped }

extension RuleEventTypeMeta on RuleEventType {
  String get label => switch (this) {
        RuleEventType.fired => 'Disparou',
        RuleEventType.proposed => 'Perguntou',
        RuleEventType.written => 'Gravou',
        RuleEventType.ignored => 'Ignorada',
        RuleEventType.withdrawn => 'Retirada',
        RuleEventType.failed => 'Não gravou',
        RuleEventType.stopped => 'Parada',
      };
}

/// Linha do histórico das regras: todo disparo, proposta, gravação e parada
/// fica aqui (LG-7).
@immutable
class RuleEvent {
  const RuleEvent({required this.at, required this.type, required this.rule, this.text = ''});
  final DateTime at;
  final RuleEventType type;

  /// Nome da regra no momento (a regra pode ser renomeada ou apagada depois).
  final String rule;
  final String text;

  Map<String, dynamic> toJson() => {'at': at.toIso8601String(), 'type': type.name, 'rule': rule, if (text.isNotEmpty) 'text': text};

  static RuleEvent? fromJson(Map<String, dynamic> j) {
    final at = DateTime.tryParse(j['at'] as String? ?? '');
    // Tipo de uma versão mais nova: pula, em vez de inventar um evento.
    final type = RuleEventType.values.where((t) => t.name == j['type']).firstOrNull;
    if (at == null || type == null) return null;
    return RuleEvent(at: at, type: type, rule: j['rule'] as String? ?? '', text: j['text'] as String? ?? '');
  }
}

class _Run {
  DateTime? since;
  bool acted = false;
  bool proposed = false;
  TagReading condition = TagReading.waiting;
  RuleStatus status = RuleStatus.watching;
}

/// Motor das regras entre máquinas (LG-4 a LG-7), no padrão do [AlarmEngine]:
/// vigia **em qualquer tela** enquanto o app está aberto.
///
/// "Quando [condição] durar [T s], então gravar [valor] em [variável]":
///   • a condição é uma conta da mesma linguagem das calculadas, sobre as
///     leituras de agora; sem comunicação ou com erro, a regra **não roda** e
///     vira alarme (LG-7);
///   • precisa durar [LogicRule.holdSec] seguidos; age **uma vez** por
///     passagem e só volta a valer quando a condição some (LG-4);
///   • o destino precisa estar marcado "aceita escrita por regra" (LG-5);
///   • padrão: **propor** — a pergunta aparece em qualquer tela e só grava se
///     a pessoa confirmar; automático só para parar (LG-6);
///   • com o app em segundo plano nada roda: a proposta pendente é retirada
///     (nunca grava depois, com a situação já outra) e, na volta, um alarme
///     diz quanto tempo as regras ficaram paradas.
///
/// Nada disso é intertravamento de segurança — o celular pode demorar ou
/// parar de ler a qualquer momento. Segurança mora no CLP.
class RuleEngine extends ChangeNotifier implements ProjectScoped {
  RuleEngine({
    required this.controller,
    required this.runtime,
    this.alarms,
    this.historyFile,
    this.tick = const Duration(seconds: 1),
  }) {
    _evaluator = CalcEvaluator(() => controller.project);
    controller.addListener(_sync);
    controller.attachScoped(this);
    _sync();
    _timer = Timer.periodic(tick, (_) => _evaluateAll());
    unawaited(_loadHistory());
  }

  static final Logger _log = Logger('RuleEngine');

  /// Máximo guardado no histórico (o mais antigo sai).
  static const historyLimit = 300;

  /// Segundo plano mais curto que isto não vira alarme na volta.
  static const pausedAlarmAfter = Duration(seconds: 10);

  final ProjectController controller;
  final HmiRuntime runtime;

  /// Onde a regra que não pode rodar vira alarme. Nulo nos testes que não
  /// precisam.
  final AlarmEngine? alarms;
  final Future<File> Function()? historyFile;
  final Duration tick;

  late final CalcEvaluator _evaluator;
  final Map<String, _Run> _runs = {};
  final List<RuleProposal> _proposals = [];
  final List<RuleEvent> _history = [];
  final Map<String, VoidCallback> _listeners = {};
  Set<String> _watched = const {};
  TagSubscription? _sub;
  Timer? _timer;
  Timer? _saveTimer;
  bool _scheduled = false;
  bool _paused = false;
  bool _disposed = false;
  DateTime? _pausedAt;

  /// Perguntas à espera, a mais antiga primeiro.
  List<RuleProposal> get proposals => List.unmodifiable(_proposals);

  /// Histórico, mais novo primeiro.
  List<RuleEvent> get history => List.unmodifiable(_history.reversed);

  RuleStatus status(String ruleId) => _runs[ruleId]?.status ?? RuleStatus.watching;

  /// A condição da regra agora (para o editor e a lista).
  TagReading condition(String ruleId) => _runs[ruleId]?.condition ?? TagReading.waiting;

  static String alarmKey(String ruleId) => 'regra-logica:$ruleId';
  static const pausedKey = 'regras:segundo-plano';

  // ── Vigiar ──────────────────────────────────────────────────────────────────

  /// Projeto mudou: refaz o que vigiar, solta regra apagada ou desligada.
  void _sync() {
    if (_disposed) return;
    final project = controller.project;
    final ids = <String>{
      for (final r in project.rules)
        if (r.enabled) ...{
          ...CalcGraph.expand(project, r.condition.inputIds),
          if (r.targetTagId.isNotEmpty) r.targetTagId,
        },
    };
    for (final id in _watched.difference(ids)) {
      final l = _listeners.remove(id);
      if (l != null) runtime.watch(id).removeListener(l);
    }
    for (final id in ids.difference(_watched)) {
      void l() => _schedule();
      _listeners[id] = l;
      runtime.watch(id).addListener(l);
    }
    if (!setEquals(ids, _watched)) {
      final old = _sub;
      _sub = ids.isEmpty ? null : runtime.subscribe(ids);
      old?.cancel();
    }
    _watched = ids;

    final live = {for (final r in project.rules) if (r.enabled) r.id};
    for (final id in _runs.keys.where((id) => !live.contains(id)).toList()) {
      _runs.remove(id);
      alarms?.clear(alarmKey(id));
    }
    final before = _proposals.length;
    _proposals.removeWhere((p) => !live.contains(p.ruleId));
    if (before != _proposals.length) notifyListeners();
    _evaluateAll();
  }

  void _schedule() {
    if (_scheduled || _disposed || _paused) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      _evaluateAll();
    });
  }

  void _evaluateAll() {
    if (_disposed || _paused) return;
    var changed = false;
    for (final r in controller.project.rules) {
      changed |= _evaluate(r);
    }
    if (changed) notifyListeners();
  }

  /// Avalia uma regra. Devolve se algo mudou para a tela.
  bool _evaluate(LogicRule rule) {
    final run = _runs.putIfAbsent(rule.id, _Run.new);
    final before = run.status;
    if (!rule.enabled) {
      run.status = RuleStatus.off;
      return before != run.status;
    }
    final now = clock.now();
    final problem = _problem(rule, run);
    if (problem != null) {
      // Não pode rodar: não conta tempo (não dá para saber se a condição
      // durou) e vira alarme.
      run.since = null;
      // Pergunta pendente sai: com a regra cega, a situação pode já ser outra.
      if (run.proposed) _withdraw(rule, problem);
      if (before.state != RuleState.blocked || before.message != problem) {
        run.status = RuleStatus(RuleState.blocked, problem);
        alarms?.raise(alarmKey(rule.id), priority: AlarmPriority.medium, message: 'Regra "${rule.name}" parada: $problem');
        if (before.state != RuleState.blocked) _addEvent(RuleEvent(at: now, type: RuleEventType.stopped, rule: rule.name, text: problem));
      }
      return before != run.status;
    }
    if (before.state == RuleState.blocked) alarms?.clear(alarmKey(rule.id));

    final c = run.condition;
    final present = c.value == true || (c.value is num && c.value != 0);
    if (!present) {
      run.since = null;
      run.acted = false;
      if (run.proposed) _withdraw(rule, 'a condição passou antes da resposta');
      run.status = c.quality == TagQuality.waiting ? const RuleStatus(RuleState.watching, 'esperando a primeira leitura') : RuleStatus.watching;
      return before.state != run.status.state || before.message != run.status.message;
    }
    final since = run.since ??= now;
    final held = now.difference(since);
    if (!run.acted && held >= Duration(seconds: rule.holdSec)) {
      run.acted = true;
      _fire(rule, held);
    }
    run.status = run.acted
        ? const RuleStatus(RuleState.acted)
        : RuleStatus(RuleState.counting, '${held.inSeconds} de ${rule.holdSec} s');
    return before.state != run.status.state || before.message != run.status.message;
  }

  /// Por que a regra não pode rodar agora (nulo = pode). Também atualiza a
  /// leitura da condição.
  String? _problem(LogicRule rule, _Run run) {
    final project = controller.project;
    final target = project.tag(rule.targetTagId);
    if (rule.targetTagId.isEmpty) return 'falta escolher onde gravar';
    if (target == null) return 'a variável de destino foi apagada';
    if (!target.canWrite) return '"${target.name}" não pode ser alterada';
    if (!target.acceptsRuleWrite) return '"${target.name}" não aceita escrita por regra';
    run.condition = _evaluator.evaluate('regra:${rule.id}', rule.condition, runtime.store.read, previous: run.condition);
    final c = run.condition;
    if (c.quality == TagQuality.commLost) return c.message;
    if (c.quality == TagQuality.configError || c.quality == TagQuality.addressError) return 'condição com erro: ${c.message}';
    if (runtime.watch(target.id).value.quality == TagQuality.commLost) {
      return 'sem comunicação com ${project.device(target.deviceId)?.name ?? 'o destino'}';
    }
    return null;
  }

  // ── Agir ────────────────────────────────────────────────────────────────────

  void _fire(LogicRule rule, Duration held) {
    final now = clock.now();
    final target = controller.project.tag(rule.targetTagId)!;
    _addEvent(RuleEvent(at: now, type: RuleEventType.fired, rule: rule.name, text: rule.holdSec == 0 ? 'condição presente' : 'condição durou ${held.inSeconds} s'));
    if (rule.mode == RuleMode.automatic && rule.canBeAutomatic) {
      _log.warning('Regra automática "${rule.name}": ${describeWrite(rule, target)}');
      unawaited(_write(rule, target, automatic: true));
      return;
    }
    if (_proposals.any((p) => p.ruleId == rule.id)) return;
    _runs[rule.id]?.proposed = true;
    _proposals.add(RuleProposal(
      ruleId: rule.id,
      question: '${rule.name.trim().isEmpty ? 'Agir' : rule.name.trim()}?',
      detail: describeWrite(rule, target),
      action: actionLabel(rule, target),
      since: now,
    ));
    _addEvent(RuleEvent(at: now, type: RuleEventType.proposed, rule: rule.name, text: describeWrite(rule, target)));
  }

  /// 'Grava DESLIGADO em "Liga prensa" (Prensa)'.
  String describeWrite(LogicRule rule, Tag target) {
    final device = controller.project.device(target.deviceId)?.name;
    return 'Grava ${TagCodec.format(target, valueFor(rule, target))} em "${target.name}"${device == null ? '' : ' ($device)'}';
  }

  /// O valor que vai para a variável: liga/desliga para liga/desliga.
  static Object valueFor(LogicRule rule, Tag target) => target.dataType == TagDataType.bool ? rule.value != 0 : rule.value;

  /// O verbo do botão de confirmar.
  static String actionLabel(LogicRule rule, Tag target) =>
      target.dataType == TagDataType.bool ? (rule.value != 0 ? 'Ligar' : 'Desligar') : 'Gravar';

  /// A pessoa confirmou a proposta: grava. Devolve o erro, se não gravou.
  Future<String?> confirm(String ruleId) async {
    final p = _take(ruleId);
    if (p == null) return null;
    final rule = controller.project.rule(ruleId);
    final target = rule == null ? null : controller.project.tag(rule.targetTagId);
    if (rule == null || target == null) return 'A regra ou o destino não existe mais';
    return _write(rule, target, automatic: false);
  }

  /// A pessoa disse não: nada é gravado.
  void ignore(String ruleId) {
    if (_take(ruleId) == null) return;
    final rule = controller.project.rule(ruleId);
    _addEvent(RuleEvent(at: clock.now(), type: RuleEventType.ignored, rule: rule?.name ?? ''));
    notifyListeners();
  }

  RuleProposal? _take(String ruleId) {
    final i = _proposals.indexWhere((p) => p.ruleId == ruleId);
    if (i < 0) return null;
    _runs[ruleId]?.proposed = false;
    return _proposals.removeAt(i);
  }

  /// Retira a pergunta sem resposta. A regra volta a valer: se a condição
  /// continuar (ou voltar) pelo tempo pedido, pergunta de novo.
  void _withdraw(LogicRule rule, String why) {
    if (_take(rule.id) == null) return;
    _runs[rule.id]?.acted = false;
    _addEvent(RuleEvent(at: clock.now(), type: RuleEventType.withdrawn, rule: rule.name, text: why));
  }

  Future<String?> _write(LogicRule rule, Tag target, {required bool automatic}) async {
    // A permissão pode ter sido tirada entre a pergunta e o toque.
    final now = controller.project.tag(target.id) ?? target;
    String? error;
    if (!now.acceptsRuleWrite) {
      error = '"${now.name}" não aceita escrita por regra';
    } else {
      try {
        await runtime.write(now.id, valueFor(rule, now));
      } catch (e) {
        error = e is TagValueError ? e.message : (e is Exception ? '$e' : 'falha ao gravar');
      }
    }
    if (_disposed) return error;
    if (error == null) {
      _addEvent(RuleEvent(at: clock.now(), type: RuleEventType.written, rule: rule.name, text: '${describeWrite(rule, now)}${automatic ? ' · automático' : ' · confirmado'}'));
    } else {
      _addEvent(RuleEvent(at: clock.now(), type: RuleEventType.failed, rule: rule.name, text: error));
      // Automática que falhou ninguém viu acontecer: vira alarme.
      if (automatic) alarms?.raise(alarmKey(rule.id), priority: AlarmPriority.medium, message: 'Regra "${rule.name}" não gravou: $error');
    }
    notifyListeners();
    return error;
  }

  // ── Ciclo de vida ───────────────────────────────────────────────────────────

  /// App foi para segundo plano: nada roda. Proposta pendente é retirada —
  /// gravar depois, com a situação já outra, seria pior que não gravar.
  void pause() {
    if (_paused || _disposed) return;
    _paused = true;
    _pausedAt = clock.now();
    _timer?.cancel();
    _timer = null;
    final project = controller.project;
    for (final p in [..._proposals]) {
      final rule = project.rule(p.ruleId);
      if (rule != null) _withdraw(rule, 'app em segundo plano');
    }
    for (final run in _runs.values) {
      run.since = null;
    }
    if (project.rules.any((r) => r.enabled)) {
      _addEvent(RuleEvent(at: _pausedAt!, type: RuleEventType.stopped, rule: 'Todas', text: 'app em segundo plano'));
    }
    notifyListeners();
  }

  /// Voltou: as regras voltam a vigiar (a contagem do tempo recomeça) e, se
  /// ficaram paradas um bom tempo, um alarme diz isso.
  void resume() {
    if (!_paused || _disposed) return;
    _paused = false;
    final since = _pausedAt;
    _pausedAt = null;
    final away = since == null ? Duration.zero : clock.now().difference(since);
    if (away >= pausedAlarmAfter && controller.project.rules.any((r) => r.enabled)) {
      final minutes = away.inMinutes;
      alarms?.raise(pausedKey,
          priority: AlarmPriority.low, message: 'As regras ficaram paradas ${minutes < 1 ? '${away.inSeconds} s' : '$minutes min'}: app em segundo plano');
      // A causa já passou: fica como "voltou ao normal" até alguém reconhecer.
      alarms?.clear(pausedKey);
    }
    _timer = Timer.periodic(tick, (_) => _evaluateAll());
    _evaluateAll();
  }

  // ── Troca de projeto ─────────────────────────────────────────────────────────

  /// Grava o histórico do projeto que sai, no arquivo dele.
  @override
  Future<void> beforeSwitch() => flush();

  /// As perguntas pendentes eram de máquinas do projeto que saiu: somem sem
  /// gravar nada. O histórico também era dele.
  @override
  void onSwitch() {
    _generation++;
    _saveTimer?.cancel();
    _saveTimer = null;
    _runs.clear();
    _proposals.clear();
    _history.clear();
    notifyListeners();
  }

  /// O histórico do projeto que entrou (`historico-regras.json` da pasta dele).
  @override
  Future<void> afterSwitch() => _loadHistory();

  // ── Histórico em disco ──────────────────────────────────────────────────────

  void _addEvent(RuleEvent ev) {
    _history.add(ev);
    if (_history.length > historyLimit) _history.removeRange(0, _history.length - historyLimit);
    if (historyFile != null) {
      _saveTimer?.cancel();
      _saveTimer = Timer(const Duration(seconds: 1), () => unawaited(_saveHistory()));
    }
  }

  /// Sobe a cada troca de projeto: leitura do histórico que termina depois
  /// da troca é do projeto que saiu e é descartada.
  int _generation = 0;

  Future<void> _loadHistory() async {
    final f = historyFile;
    if (f == null) return;
    final generation = _generation;
    try {
      final file = await f();
      if (!await file.exists()) return;
      final list = jsonDecode(await file.readAsString()) as List;
      final loaded = [
        for (final j in list)
          if (j is Map) ?RuleEvent.fromJson(Map<String, dynamic>.from(j)),
      ];
      if (_disposed || generation != _generation) return;
      _history.insertAll(0, loaded);
      notifyListeners();
    } catch (e) {
      _log.warning('Histórico das regras ilegível, começando vazio: $e');
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
      _log.warning('Não gravou o histórico das regras: $e');
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
    controller.detachScoped(this);
    for (final e in _listeners.entries) {
      runtime.watch(e.key).removeListener(e.value);
    }
    _listeners.clear();
    _sub?.cancel();
    _timer?.cancel();
    _saveTimer?.cancel();
    super.dispose();
  }
}
