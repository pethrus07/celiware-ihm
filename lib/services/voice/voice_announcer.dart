import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../app/project_controller.dart';
import '../../models/alarm.dart';
import '../../models/narration.dart';
import '../alarms/alarm_engine.dart';
import '../runtime/hmi_runtime.dart';
import '../runtime/tag_store.dart';
import 'audio_output.dart';
import 'speech_engine.dart';
import 'voice_prefs.dart';

/// O que o anunciador precisa dos alarmes: a lista e o aviso de mudança. O
/// [AlarmEngine] serve ([AlarmFeed.of]); os testes passam uma lista na mão.
class AlarmFeed {
  const AlarmFeed({required this.changes, required this.read});

  factory AlarmFeed.of(AlarmEngine engine) => AlarmFeed(changes: engine, read: () => engine.entries);

  final Listenable changes;
  final List<AlarmEntry> Function() read;
}

/// Uma fala na fila.
class _Utterance {
  _Utterance({required this.key, required this.text, required this.rank, this.force = false});

  /// Alarme: a chave do [AlarmEntry]. Narração: `narr:<tagId>:<id>`.
  final String key;
  final String text;

  /// 0 alta · 1 média · 2 baixa · 3 narração. Menor fala antes.
  final int rank;

  /// "Falar um exemplo": fala mesmo sem fone (é a pessoa pedindo).
  final bool force;

  bool get isAlarm => rank < VoiceAnnouncer.narrationRank;
}

/// Avisos por voz no fone (REQUISITOS-ETAPA4 §9.1, VZ-1 a VZ-6).
///
/// **Fila por prioridade, em Dart** — o `flutter_tts` só fala e para; a
/// ordem é daqui (no Windows o motor nem tem fila):
/// - alarme novo entra na fila pela prioridade; mesma prioridade, ordem de
///   chegada; **alta interrompe** média, baixa e narração (o que foi cortado
///   volta para a frente da sua prioridade e é falado depois);
/// - alta não reconhecida **repete** a cada 30 s; média fala uma vez; baixa
///   não fala — tudo configurável em [VoicePrefs];
/// - **reconhecer ou silenciar** cala aquele alarme na hora, inclusive no
///   meio da frase. Silenciar não reconhece (ver [AlarmEngine.silence]);
/// - narração de evento fala abaixo de todo alarme, no máximo uma vez por
///   evento a cada N s.
///
/// A voz **nunca é a única indicação**: a faixa no topo e a vibração
/// continuam iguais, com ou sem voz, com ou sem fone. Com o app em segundo
/// plano a varredura para (ARQUITETURA §2.4) e a voz também ([pause]).
class VoiceAnnouncer {
  VoiceAnnouncer({
    required this.alarms,
    required this.engine,
    required this.prefs,
    ProjectController? controller,
    HmiRuntime? runtime,
    Future<bool?> Function()? headset,
  }) : _headset = headset ?? AudioOutput.headsetConnected {
    alarms.changes.addListener(_onAlarms);
    prefs.addListener(_onPrefs);
    _enabled = prefs.value.enabled;
    if (controller != null && runtime != null) {
      _narrator = EventNarrator(controller: controller, runtime: runtime, onEvent: narrate);
    }
    _narrator?.active = _narrationOn;
    _onAlarms();
    if (_enabled) unawaited(refreshStatus());
  }

  static final Logger _log = Logger('Voz');

  /// Posição da narração na fila: depois de todo alarme.
  static const narrationRank = 3;

  final AlarmFeed alarms;
  final SpeechEngine engine;
  final ValueListenable<VoicePrefs> prefs;
  final Future<bool?> Function() _headset;
  EventNarrator? _narrator;

  final List<_Utterance> _queue = [];
  _Utterance? _current;
  bool _looping = false;
  bool _paused = false;
  bool _disposed = false;
  bool _enabled = true;

  /// Última foto dos alarmes (para achar o que é novo e o que saiu).
  Map<String, AlarmEntry> _known = const {};

  /// Quando cada alarme em repetição volta a falar.
  final Map<String, DateTime> _nextRepeat = {};
  Timer? _repeatTimer;

  /// Última fala de cada narração (limite de N s por evento).
  final Map<String, DateTime> _lastNarration = {};

  final ValueNotifier<VoiceStatus> _status = ValueNotifier(VoiceStatus.unknown);

  /// Há voz pt-BR que funcione sem internet? (VZ-6 — a folha de voz avisa.)
  ValueListenable<VoiceStatus> get status => _status;

  /// O que está na fila agora, em ordem (testes).
  @visibleForTesting
  List<String> get pending => [for (final u in _queue) u.text];

  bool get _narrationOn => prefs.value.enabled && prefs.value.narrate;

  /// O que o fone fala: a urgência na frente, para o operador saber sem
  /// olhar se é alarme ou narração.
  static String spokenText(AlarmEntry e) => switch (e.priority) {
        AlarmPriority.high => 'Alarme urgente: ${e.message}',
        AlarmPriority.medium => 'Alarme: ${e.message}',
        AlarmPriority.low => 'Atenção: ${e.message}',
      };

  /// O botão Silenciar só aparece onde a voz **insiste** (repetição): o
  /// alarme que fala uma vez já calou sozinho.
  static bool canSilence(AlarmEntry e, VoicePrefs p) =>
      p.enabled && e.phase == AlarmPhase.activeUnack && !e.silenced && p.modeFor(e.priority) == VoiceMode.repeat;

  // ── Alarmes ─────────────────────────────────────────────────────────────────

  void _onAlarms() {
    if (_disposed) return;
    final list = alarms.read();
    final now = {for (final e in list) e.key: e};
    final before = _known;
    _known = now;
    for (final e in list) {
      // Nova ativação = chave nova ou outro `since` (o mesmo alarme pode
      // voltar ao normal e disparar de novo antes de ser reconhecido).
      final old = before[e.key];
      if ((old == null || old.since != e.since) && e.phase == AlarmPhase.activeUnack) _announce(e);
    }
    // Reconhecido, silenciado ou fora da lista: cala já. Voltou ao normal sem
    // reconhecimento: não repete mais (o que já está na fila ainda fala — o
    // alarme aconteceu e ninguém viu).
    final touched = {..._nextRepeat.keys, for (final u in _queue) if (u.isAlarm) u.key, if (_current?.isAlarm ?? false) _current!.key};
    for (final key in touched) {
      final e = now[key];
      if (e == null || !e.phase.unacked || e.silenced) {
        _cancel(key);
      } else if (e.phase != AlarmPhase.activeUnack) {
        _nextRepeat.remove(key);
      }
    }
    _armRepeat();
  }

  void _announce(AlarmEntry e) {
    final p = prefs.value;
    if (!p.enabled || e.silenced || p.modeFor(e.priority) == VoiceMode.never) return;
    _enqueue(_Utterance(key: e.key, text: spokenText(e), rank: e.priority.index));
  }

  /// Pode repetir este alarme? Ativo, não reconhecido, não silenciado e com a
  /// prioridade em "Repete".
  bool _repeats(AlarmEntry? e) {
    final p = prefs.value;
    return e != null && p.enabled && e.phase == AlarmPhase.activeUnack && !e.silenced && p.modeFor(e.priority) == VoiceMode.repeat;
  }

  /// Ainda vale falar o que está na fila? (A preferência pode ter mudado.)
  bool _stillWanted(_Utterance u) {
    final p = prefs.value;
    if (!p.enabled) return false;
    if (u.force) return true;
    if (!u.isAlarm) return p.narrate;
    final e = _known[u.key];
    return e != null && e.phase.unacked && !e.silenced && p.modeFor(e.priority) != VoiceMode.never;
  }

  // ── Narração ────────────────────────────────────────────────────────────────

  /// Uma narração aconteceu (VZ-5): entra depois dos alarmes, e o mesmo
  /// evento fala no máximo uma vez a cada [VoicePrefs.narrationGapSec].
  void narrate(String key, String text) {
    final p = prefs.value;
    if (_disposed || _paused || !p.enabled || !p.narrate || text.trim().isEmpty) return;
    final now = clock.now();
    final last = _lastNarration[key];
    if (last != null && now.difference(last) < Duration(seconds: p.narrationGapSec)) return;
    _lastNarration[key] = now;
    _enqueue(_Utterance(key: key, text: text.trim(), rank: narrationRank));
  }

  /// "Falar um exemplo" da folha de voz: com o volume e a velocidade de
  /// agora, e mesmo sem fone (é a pessoa pedindo para ouvir).
  void speakSample() {
    if (_disposed || !prefs.value.enabled) return;
    _enqueue(_Utterance(key: 'exemplo', text: 'Exemplo de aviso: temperatura do motor acima de 85 graus.', rank: narrationRank, force: true));
  }

  // ── Fila ────────────────────────────────────────────────────────────────────

  void _enqueue(_Utterance u) {
    if (_current?.key == u.key || _queue.any((x) => x.key == u.key)) return;
    _insert(u);
    final cur = _current;
    if (cur != null && u.rank < cur.rank) {
      // Mais urgente chegou: corta a fala e devolve a cortada para a frente
      // da prioridade dela — ela ainda não foi ouvida inteira.
      _current = null;
      _insert(cur, front: true);
      unawaited(engine.stop());
    }
    unawaited(_loop());
  }

  /// Insere pela prioridade; [front] = na frente dos da mesma prioridade.
  void _insert(_Utterance u, {bool front = false}) {
    final i = _queue.indexWhere((x) => front ? x.rank >= u.rank : x.rank > u.rank);
    _queue.insert(i < 0 ? _queue.length : i, u);
  }

  /// Um laço só, uma fala por vez. Interromper = trocar [_current] e parar
  /// o motor: o `speak` em curso termina e o laço segue para a próxima.
  Future<void> _loop() async {
    if (_looping) return;
    _looping = true;
    try {
      while (!_disposed && !_paused && _queue.isNotEmpty) {
        final u = _queue.removeAt(0);
        _current = u;
        final p = prefs.value;
        final allowed = u.force || await _outputAllowed(p);
        if (!identical(_current, u)) continue; // cancelada ou cortada enquanto conferia o fone
        if (allowed) {
          try {
            await engine.speak(u.text, volume: p.volume, rate: p.rate.value);
          } catch (e) {
            _log.warning('Não falou "${u.text}": $e');
          }
        }
        if (!identical(_current, u)) continue; // cortada: já voltou para a fila
        _current = null;
        // Repetição conta do fim da fala (frase longa não come o intervalo).
        // Sem fone também conta: o próximo aviso sai quando o fone voltar.
        if (u.isAlarm && _repeats(_known[u.key])) {
          _nextRepeat[u.key] = clock.now().add(Duration(seconds: prefs.value.repeatSec));
          _armRepeat();
        }
      }
    } finally {
      _looping = false;
    }
  }

  Future<bool> _outputAllowed(VoicePrefs p) async {
    if (!p.onlyWithHeadset) return true;
    // Plataforma que não informa (nulo): a opção nem aparece, e um palpite
    // não deve calar um alarme.
    return await _headset() ?? true;
  }

  /// Tira um alarme da fila, da repetição e — se estiver falando — da boca.
  void _cancel(String key) {
    _nextRepeat.remove(key);
    _queue.removeWhere((u) => u.key == key);
    if (_current?.key == key) {
      _current = null;
      unawaited(engine.stop());
    }
  }

  // ── Repetição ───────────────────────────────────────────────────────────────

  void _armRepeat() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
    if (_disposed || _paused || _nextRepeat.isEmpty) return;
    final next = _nextRepeat.values.reduce((a, b) => a.isBefore(b) ? a : b);
    final wait = next.difference(clock.now());
    _repeatTimer = Timer(wait.isNegative ? Duration.zero : wait, _onRepeatDue);
  }

  void _onRepeatDue() {
    _repeatTimer = null;
    final now = clock.now();
    for (final key in [for (final e in _nextRepeat.entries) if (!e.value.isAfter(now)) e.key]) {
      _nextRepeat.remove(key);
      final e = _known[key];
      if (_repeats(e)) _enqueue(_Utterance(key: key, text: spokenText(e!), rank: e.priority.index));
    }
    _armRepeat();
  }

  // ── Preferências ────────────────────────────────────────────────────────────

  void _onPrefs() {
    if (_disposed) return;
    final p = prefs.value;
    final turnedOn = p.enabled && !_enabled;
    _enabled = p.enabled;
    _queue.removeWhere((u) => !_stillWanted(u));
    final cur = _current;
    if (cur != null && !_stillWanted(cur)) {
      _current = null;
      unawaited(engine.stop());
    }
    _nextRepeat.removeWhere((k, _) => !_repeats(_known[k]));
    // Voz ligada agora (ou prioridade passou a "Repete") com alarme alto
    // esperando: fala já, em vez de esperar o próximo disparo.
    for (final e in _known.values) {
      final busy = _nextRepeat.containsKey(e.key) || _current?.key == e.key || _queue.any((u) => u.key == e.key);
      if (_repeats(e) && !busy) _nextRepeat[e.key] = clock.now();
    }
    _narrator?.active = _narrationOn;
    _armRepeat();
    if (turnedOn) unawaited(refreshStatus());
  }

  // ── Voz instalada (VZ-6) ────────────────────────────────────────────────────

  Future<VoiceStatus> refreshStatus() async {
    final s = await engine.check();
    if (!_disposed) _status.value = s;
    return s;
  }

  // ── Ciclo de vida ───────────────────────────────────────────────────────────

  /// App foi para segundo plano: para de falar. Narração na fila é jogada
  /// fora (ao voltar já é passado); alarme fica, e fala ao voltar se ainda
  /// estiver pedindo reconhecimento.
  void pause() {
    if (_paused || _disposed) return;
    _paused = true;
    _repeatTimer?.cancel();
    _repeatTimer = null;
    _queue.removeWhere((u) => !u.isAlarm);
    final cur = _current;
    if (cur != null) {
      _current = null;
      if (cur.isAlarm) _insert(cur, front: true);
      unawaited(engine.stop());
    }
  }

  void resume() {
    if (!_paused || _disposed) return;
    _paused = false;
    _queue.removeWhere((u) => !_stillWanted(u));
    _armRepeat();
    unawaited(_loop());
    // Pode estar voltando dos ajustes de voz do sistema (VZ-6).
    if (prefs.value.enabled) unawaited(refreshStatus());
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    alarms.changes.removeListener(_onAlarms);
    prefs.removeListener(_onPrefs);
    _narrator?.dispose();
    _repeatTimer?.cancel();
    _queue.clear();
    if (_current != null) {
      _current = null;
      unawaited(engine.stop());
    }
    _status.dispose();
  }
}

/// Vigia as variáveis que têm narração e avisa a passagem (VZ-5) — em
/// qualquer tela, como o [AlarmEngine]: só fica inscrito no runtime enquanto
/// a narração está ligada (inscrever = o equipamento continua sendo lido).
class EventNarrator {
  EventNarrator({required this.controller, required this.runtime, required this.onEvent}) {
    controller.addListener(_sync);
  }

  final ProjectController controller;
  final HmiRuntime runtime;
  final void Function(String key, String text) onEvent;

  bool _active = false;
  bool _disposed = false;
  final Map<String, VoidCallback> _listeners = {};

  /// Último valor bom de cada variável. Sem ele não há "passagem".
  final Map<String, Object?> _last = {};
  TagSubscription? _sub;
  Set<String> _watched = const {};

  bool get active => _active;
  set active(bool v) {
    if (v == _active) return;
    _active = v;
    _sync();
  }

  void _sync() {
    if (_disposed) return;
    final ids = !_active ? <String>{} : {for (final t in controller.project.tags) if (t.narrations.isNotEmpty) t.id};
    for (final id in _watched.difference(ids)) {
      final l = _listeners.remove(id);
      if (l != null) runtime.watch(id).removeListener(l);
      _last.remove(id);
    }
    for (final id in ids.difference(_watched)) {
      void l() => _evaluate(id);
      _listeners[id] = l;
      runtime.watch(id).addListener(l);
      // Base de comparação: o valor de agora, sem falar.
      final r = runtime.watch(id).value;
      if (r.isGood) _last[id] = r.value;
    }
    if (ids.length != _watched.length || !ids.containsAll(_watched)) {
      final old = _sub;
      _sub = ids.isEmpty ? null : runtime.subscribe(ids);
      old?.cancel();
    }
    _watched = ids;
  }

  void _evaluate(String tagId) {
    if (_disposed || !_active) return;
    final tag = controller.project.tag(tagId);
    final r = runtime.watch(tagId).value;
    if (tag == null) return;
    if (!r.isGood) {
      // Sem comunicação (ou erro): esquece a base. Ao voltar, o valor novo
      // não é "evento" — não dá para saber quando mudou.
      if (r.quality.isProblem) _last.remove(tagId);
      return;
    }
    final prev = _last[tagId];
    _last[tagId] = r.value;
    if (prev == r.value) return;
    for (final n in tag.narrations) {
      if (NarrationLogic.fires(n, previous: prev, current: r.value)) onEvent('narr:${tag.id}:${n.id}', n.text.trim());
    }
  }

  void dispose() {
    _disposed = true;
    controller.removeListener(_sync);
    for (final e in _listeners.entries) {
      runtime.watch(e.key).removeListener(e.value);
    }
    _listeners.clear();
    _sub?.cancel();
    _sub = null;
  }
}
