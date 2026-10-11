import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/models/alarm.dart';
import 'package:ihm/models/narration.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/alarms/alarm_engine.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/runtime/tag_store.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:ihm/services/voice/speech_engine.dart';
import 'package:ihm/services/voice/voice_announcer.dart';
import 'package:ihm/services/voice/voice_prefs.dart';

/// Motor de voz falso: anota o que falou e quando parou. A fala só termina
/// quando o teste manda ([finish]) ou alguém para ([stop]) — assim dá para
/// ver a interrupção acontecendo no meio da frase.
class FakeSpeech implements SpeechEngine {
  final List<String> log = [];
  Completer<void>? _talking;
  VoiceStatus status = const VoiceStatus(VoiceAvailability.ready);

  List<String> get spoken => [for (final l in log) if (l.startsWith('fala: ')) l.substring(6)];
  bool get talking => _talking != null;

  @override
  Future<void> speak(String text, {required double volume, required double rate}) {
    log.add('fala: $text');
    final c = _talking = Completer<void>();
    return c.future;
  }

  /// A frase em curso chegou ao fim.
  void finish() {
    final c = _talking;
    _talking = null;
    c?.complete();
  }

  @override
  Future<void> stop() async {
    log.add('para');
    finish();
  }

  @override
  Future<VoiceStatus> check() async => status;
}

/// Alarmes "na mão": a lista que o [AlarmEngine] publicaria.
class Rig {
  Rig({VoicePrefs prefs = const VoicePrefs(onlyWithHeadset: false)}) : prefs = ValueNotifier(prefs) {
    voice = VoiceAnnouncer(
      alarms: AlarmFeed(changes: feed, read: () => feed.value),
      engine: speech,
      prefs: this.prefs,
      headset: () async => headset,
    );
  }

  final speech = FakeSpeech();
  final feed = ValueNotifier<List<AlarmEntry>>(const []);
  final ValueNotifier<VoicePrefs> prefs;
  bool? headset = true;
  late final VoiceAnnouncer voice;

  void set(List<AlarmEntry> list) => feed.value = list;

  /// Termina a frase em curso e deixa a fila andar.
  void finish(FakeAsync fa) {
    speech.finish();
    fa.flushMicrotasks();
  }
}

AlarmEntry alarm(String key, AlarmPriority p, {AlarmPhase phase = AlarmPhase.activeUnack, bool silenced = false, DateTime? since}) =>
    AlarmEntry(key: key, priority: p, message: key, phase: phase, since: since ?? DateTime(2026, 10, 11, 8), silenced: silenced);

void main() {
  group('fila por prioridade (VZ-1)', () {
    test('alarme novo fala a mensagem, com a urgência na frente', () {
      fakeAsync((fa) {
        final r = Rig();
        r.set([alarm('Porta aberta', AlarmPriority.high)]);
        fa.flushMicrotasks();
        expect(r.speech.spoken, ['Alarme urgente: Porta aberta']);
        r.voice.dispose();
      });
    });

    test('mesma prioridade em ordem de chegada; alta interrompe a média e a cortada fala depois', () {
      fakeAsync((fa) {
        final r = Rig(prefs: const VoicePrefs(onlyWithHeadset: false, low: VoiceMode.once));
        final a = alarm('A', AlarmPriority.medium);
        final b = alarm('B', AlarmPriority.medium);
        final c = alarm('C', AlarmPriority.low);
        r.set([a]);
        fa.flushMicrotasks();
        r.set([a, b, c]);
        fa.flushMicrotasks();
        expect(r.voice.pending, ['Alarme: B', 'Atenção: C']);

        // Alta chega no meio da fala de A: corta, fala já, e A volta para a
        // frente das médias (ainda não foi ouvida inteira).
        r.set([alarm('H', AlarmPriority.high), a, b, c]);
        fa.flushMicrotasks();
        expect(r.speech.log, ['fala: Alarme: A', 'para', 'fala: Alarme urgente: H']);
        expect(r.voice.pending, ['Alarme: A', 'Alarme: B', 'Atenção: C']);

        r.finish(fa);
        r.finish(fa);
        r.finish(fa);
        r.finish(fa);
        expect(r.speech.spoken, ['Alarme: A', 'Alarme urgente: H', 'Alarme: A', 'Alarme: B', 'Atenção: C']);
        r.voice.dispose();
      });
    });

    test('média não interrompe média; baixa não interrompe nada', () {
      fakeAsync((fa) {
        final r = Rig(prefs: const VoicePrefs(onlyWithHeadset: false, low: VoiceMode.once));
        final a = alarm('A', AlarmPriority.medium);
        r.set([a]);
        fa.flushMicrotasks();
        r.set([a, alarm('B', AlarmPriority.medium), alarm('C', AlarmPriority.low)]);
        fa.flushMicrotasks();
        expect(r.speech.log, ['fala: Alarme: A']);
        r.voice.dispose();
      });
    });
  });

  group('repetição (VZ-2)', () {
    test('alta não reconhecida repete a cada 30 s; média fala uma vez; baixa não fala', () {
      fakeAsync((fa) {
        final r = Rig();
        r.set([alarm('H', AlarmPriority.high), alarm('M', AlarmPriority.medium), alarm('L', AlarmPriority.low)]);
        fa.flushMicrotasks();
        r.finish(fa); // H
        final t0 = clock.now();
        r.finish(fa); // M
        expect(r.speech.spoken, ['Alarme urgente: H', 'Alarme: M']);

        fa.elapse(const Duration(seconds: 29));
        expect(r.speech.spoken, hasLength(2), reason: 'antes de 30 s não repete');
        fa.elapse(const Duration(seconds: 1));
        expect(r.speech.spoken.last, 'Alarme urgente: H');
        expect(clock.now().difference(t0), const Duration(seconds: 30));
        r.finish(fa);

        fa.elapse(const Duration(seconds: 30));
        r.finish(fa);
        fa.elapse(const Duration(seconds: 30));
        expect(r.speech.spoken.where((s) => s == 'Alarme urgente: H'), hasLength(4));
        expect(r.speech.spoken.where((s) => s == 'Alarme: M'), hasLength(1), reason: 'média fala uma vez');
        expect(r.speech.spoken.any((s) => s.contains('L')), isFalse, reason: 'baixa não fala');
        r.voice.dispose();
      });
    });

    test('intervalo e quem fala são configuráveis', () {
      fakeAsync((fa) {
        final r = Rig(prefs: const VoicePrefs(onlyWithHeadset: false, repeatSec: 15, medium: VoiceMode.repeat, low: VoiceMode.once));
        r.set([alarm('M', AlarmPriority.medium), alarm('L', AlarmPriority.low)]);
        fa.flushMicrotasks();
        r.finish(fa);
        r.finish(fa);
        fa.elapse(const Duration(seconds: 15));
        expect(r.speech.spoken, ['Alarme: M', 'Atenção: L', 'Alarme: M']);
        r.voice.dispose();
      });
    });

    test('reconhecer cala na hora, no meio da frase, e acaba a repetição', () {
      fakeAsync((fa) {
        final r = Rig();
        final h = alarm('H', AlarmPriority.high);
        r.set([h]);
        fa.flushMicrotasks();
        r.finish(fa);
        fa.elapse(const Duration(seconds: 30));
        expect(r.speech.talking, isTrue);
        r.set([alarm('H', AlarmPriority.high, phase: AlarmPhase.activeAck)]);
        fa.flushMicrotasks();
        expect(r.speech.log.last, 'para');
        fa.elapse(const Duration(minutes: 5));
        expect(r.speech.spoken, hasLength(2));
        r.voice.dispose();
      });
    });

    test('voltou ao normal sem reconhecimento: não repete mais', () {
      fakeAsync((fa) {
        final r = Rig();
        r.set([alarm('H', AlarmPriority.high)]);
        fa.flushMicrotasks();
        r.finish(fa);
        r.set([alarm('H', AlarmPriority.high, phase: AlarmPhase.returnedUnack)]);
        fa.elapse(const Duration(minutes: 2));
        expect(r.speech.spoken, hasLength(1));
        r.voice.dispose();
      });
    });

    test('disparou de novo (outro "desde") antes de reconhecer: fala de novo', () {
      fakeAsync((fa) {
        final r = Rig();
        r.set([alarm('M', AlarmPriority.medium)]);
        fa.flushMicrotasks();
        r.finish(fa);
        r.set([alarm('M', AlarmPriority.medium, since: DateTime(2026, 10, 11, 9))]);
        fa.flushMicrotasks();
        expect(r.speech.spoken, ['Alarme: M', 'Alarme: M']);
        r.voice.dispose();
      });
    });
  });

  group('silenciar (VZ-3)', () {
    test('cala a voz na hora sem reconhecer, e não repete mais', () {
      fakeAsync((fa) {
        final r = Rig();
        final h = alarm('H', AlarmPriority.high);
        r.set([h]);
        fa.flushMicrotasks();
        expect(VoiceAnnouncer.canSilence(h, r.prefs.value), isTrue);

        final silenced = alarm('H', AlarmPriority.high, silenced: true);
        r.set([silenced]);
        fa.flushMicrotasks();
        expect(r.speech.log, ['fala: Alarme urgente: H', 'para']);
        expect(silenced.phase.unacked, isTrue, reason: 'continua pedindo reconhecimento');
        expect(VoiceAnnouncer.canSilence(silenced, r.prefs.value), isFalse);
        fa.elapse(const Duration(minutes: 3));
        expect(r.speech.spoken, hasLength(1));
        r.voice.dispose();
      });
    });

    test('o botão só aparece onde a voz insiste (repetição) e com a voz ligada', () {
      const p = VoicePrefs();
      expect(VoiceAnnouncer.canSilence(alarm('M', AlarmPriority.medium), p), isFalse);
      expect(VoiceAnnouncer.canSilence(alarm('H', AlarmPriority.high), p.copyWith(enabled: false)), isFalse);
      expect(VoiceAnnouncer.canSilence(alarm('H', AlarmPriority.high, phase: AlarmPhase.activeAck), p), isFalse);
    });

    test('motor de alarmes: silenciar não reconhece e entra no histórico; reconhecer depois funciona', () async {
      final dir = await Directory.systemTemp.createTemp('voz_silenciar');
      final runtime = HmiRuntime();
      final controller = ProjectController(repository: ProjectRepository(directory: dir), runtime: runtime);
      const tag = Tag(id: 'p', name: 'Porta', deviceId: 'sem_equipamento', dataType: TagDataType.bool, alarms: [
        AlarmRule(id: 'a', kind: AlarmKind.off, priority: AlarmPriority.high, message: 'Porta aberta'),
      ]);
      await controller.replace(const Project(name: 'T', tags: [tag]));
      final engine = AlarmEngine(controller: controller, runtime: runtime, onDelay: Duration.zero);
      runtime.store.publish('p', TagReading(value: false, quality: TagQuality.good, at: DateTime.now()));
      final key = engine.entries.single.key;

      engine.silence(key);
      expect(engine.entries.single.silenced, isTrue);
      expect(engine.entries.single.phase, AlarmPhase.activeUnack);
      expect(engine.history.first.type, AlarmEventType.silenced);
      expect(engine.history.first.type.label, 'Silenciado');

      engine.acknowledge(key);
      expect(engine.entries.single.phase, AlarmPhase.activeAck);
      expect(engine.history.map((e) => e.type), [AlarmEventType.acknowledged, AlarmEventType.silenced, AlarmEventType.activated]);

      engine.dispose();
      controller.dispose();
      await runtime.dispose();
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {/* Windows segurando o arquivo */}
    });
  });

  group('histórico com "Silenciado" e versões antigas', () {
    test('versão antiga (1.3.2) lê o arquivo novo sem quebrar', () {
      final now = DateTime(2026, 10, 11, 8);
      final file = jsonEncode([
        AlarmEvent(at: now, type: AlarmEventType.activated, priority: AlarmPriority.high, message: 'Porta aberta', valueText: 'DESLIGADO').toJson(),
        AlarmEvent(at: now, type: AlarmEventType.silenced, priority: AlarmPriority.high, message: 'Porta aberta').toJson(),
        AlarmEvent(at: now, type: AlarmEventType.acknowledged, priority: AlarmPriority.high, message: 'Porta aberta').toJson(),
      ]);
      // Cópia fiel da leitura da 1.3.2: enum com 3 tipos e "Ativou" para o
      // que não conhece.
      const oldTypes = ['activated', 'acknowledged', 'returned'];
      final old = [
        for (final j in jsonDecode(file) as List)
          if (DateTime.tryParse((j as Map)['at'] as String? ?? '') != null)
            oldTypes.firstWhere((t) => t == j['type'], orElse: () => 'activated'),
      ];
      expect(old, ['activated', 'activated', 'acknowledged']);
    });

    test('esta versão lê "silenced" e pula tipo de versão mais nova em vez de inventar "Ativou"', () {
      final at = DateTime(2026, 10, 11, 8).toIso8601String();
      final read = [
        for (final j in [
          {'at': at, 'type': 'silenced', 'priority': 'high', 'message': 'X'},
          {'at': at, 'type': 'shelved', 'priority': 'high', 'message': 'X'},
          {'at': at, 'type': 'returned', 'priority': 'low', 'message': 'Y'},
        ])
          ?AlarmEvent.fromJson(j),
      ];
      expect(read.map((e) => e.type), [AlarmEventType.silenced, AlarmEventType.returned]);
    });
  });

  group('só com fone (VZ-4)', () {
    test('sem fone não fala, mas a repetição segue e fala quando o fone volta', () {
      fakeAsync((fa) {
        final r = Rig(prefs: const VoicePrefs());
        r.headset = false;
        r.set([alarm('H', AlarmPriority.high)]);
        fa.flushMicrotasks();
        expect(r.speech.spoken, isEmpty);
        r.headset = true;
        fa.elapse(const Duration(seconds: 30));
        expect(r.speech.spoken, ['Alarme urgente: H']);
        r.voice.dispose();
      });
    });

    test('plataforma que não informa o fone (nulo) não cala o alarme', () {
      fakeAsync((fa) {
        final r = Rig(prefs: const VoicePrefs());
        r.headset = null;
        r.set([alarm('H', AlarmPriority.high)]);
        fa.flushMicrotasks();
        expect(r.speech.spoken, hasLength(1));
        r.voice.dispose();
      });
    });

    test('"Falar um exemplo" fala mesmo sem fone', () {
      fakeAsync((fa) {
        final r = Rig(prefs: const VoicePrefs());
        r.headset = false;
        r.voice.speakSample();
        fa.flushMicrotasks();
        expect(r.speech.spoken.single, startsWith('Exemplo de aviso'));
        r.voice.dispose();
      });
    });
  });

  group('narração (VZ-5)', () {
    test('fala depois dos alarmes, é cortada por alarme e fala no máximo 1 vez por evento a cada N s', () {
      fakeAsync((fa) {
        final r = Rig();
        r.voice.narrate('narr:st:1', 'A máquina está iniciando');
        fa.flushMicrotasks();
        r.set([alarm('M', AlarmPriority.medium)]);
        fa.flushMicrotasks();
        // Alarme corta a narração; ela volta depois.
        expect(r.speech.log, ['fala: A máquina está iniciando', 'para', 'fala: Alarme: M']);
        r.finish(fa);
        r.finish(fa);
        expect(r.speech.spoken.last, 'A máquina está iniciando');

        // Mesmo evento antes de 10 s: calado. Outro evento: fala.
        fa.elapse(const Duration(seconds: 5));
        r.voice.narrate('narr:st:1', 'A máquina está iniciando');
        r.voice.narrate('narr:st:2', 'Montagem');
        fa.flushMicrotasks();
        r.finish(fa);
        expect(r.speech.spoken.sublist(3), ['Montagem']);
        fa.elapse(const Duration(seconds: 6));
        r.voice.narrate('narr:st:1', 'A máquina está iniciando');
        fa.flushMicrotasks();
        expect(r.speech.spoken.last, 'A máquina está iniciando');
        r.voice.dispose();
      });
    });

    test('narração desligada nas preferências não fala', () {
      fakeAsync((fa) {
        final r = Rig(prefs: const VoicePrefs(onlyWithHeadset: false, narrate: false));
        r.voice.narrate('narr:x:1', 'Oi');
        fa.flushMicrotasks();
        expect(r.speech.spoken, isEmpty);
        r.voice.dispose();
      });
    });

    test('regra pura: só na passagem; liga/desliga conta como 1/0; vírgula de escala', () {
      const st = EventNarration(id: 'a', value: 2, text: 'Montagem');
      expect(NarrationLogic.fires(st, previous: 1, current: 2), isTrue);
      expect(NarrationLogic.fires(st, previous: 2, current: 2), isFalse, reason: 'parado lá não fala de novo');
      expect(NarrationLogic.fires(st, previous: null, current: 2), isFalse, reason: 'sem base não é evento');
      const above = EventNarration(id: 'b', kind: NarrationKind.above, value: 80, text: 'Quente');
      expect(NarrationLogic.fires(above, previous: 79.9, current: 80.1), isTrue);
      expect(NarrationLogic.fires(above, previous: 81.0, current: 82.0), isFalse);
      const below = EventNarration(id: 'c', kind: NarrationKind.below, value: 20, text: 'Pouco');
      expect(NarrationLogic.fires(below, previous: 21, current: 19), isTrue);
      const on = EventNarration(id: 'd', value: 1, text: 'Ligou');
      expect(NarrationLogic.fires(on, previous: false, current: true), isTrue);
      expect(NarrationLogic.matches(const EventNarration(id: 'e', value: 75.2, text: 'x'), 752 * 0.1), isTrue);
    });

    test('narrador: fala na passagem; não na primeira leitura nem na volta da comunicação', () async {
      final dir = await Directory.systemTemp.createTemp('voz_narrador');
      final runtime = HmiRuntime();
      final controller = ProjectController(repository: ProjectRepository(directory: dir), runtime: runtime);
      const tag = Tag(id: 'st', name: 'Estado', deviceId: 'sem_equipamento', narrations: [
        EventNarration(id: 'a', value: 1, text: 'A máquina está iniciando'),
        EventNarration(id: 'b', value: 2, text: 'Montagem'),
      ]);
      await controller.replace(const Project(name: 'T', tags: [tag]));
      final said = <String>[];
      final narrator = EventNarrator(controller: controller, runtime: runtime, onEvent: (k, t) => said.add('$k=$t'))..active = true;
      void put(Object v) => runtime.store.publish('st', TagReading(value: v, quality: TagQuality.good, at: DateTime.now()));

      put(1); // primeira leitura: vira a base, calado
      put(2);
      put(2); // continua lá: calado
      put(1);
      runtime.store.publish('st', const TagReading(quality: TagQuality.commLost, message: 'sem resposta'));
      put(2); // comunicação voltou: base nova, calado
      expect(said, ['narr:st:b=Montagem', 'narr:st:a=A máquina está iniciando']);

      narrator.active = false; // narração desligada: deixa de vigiar
      put(1);
      expect(said, hasLength(2));

      narrator.dispose();
      controller.dispose();
      await runtime.dispose();
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {/* Windows segurando o arquivo */}
    });

    test('narrações vão para o arquivo e voltam; variável sem narração não ganha a chave', () {
      const t = Tag(id: 't', name: 'Estado', deviceId: 'd', narrations: [
        EventNarration(id: 'a', value: 1, text: 'Iniciando'),
        EventNarration(id: 'b', kind: NarrationKind.above, value: 80.5, text: 'Quente'),
      ]);
      final back = Tag.fromJson(jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>);
      expect(back.narrations.map((n) => (n.id, n.kind, n.value, n.text)), [
        ('a', NarrationKind.equals, 1.0, 'Iniciando'),
        ('b', NarrationKind.above, 80.5, 'Quente'),
      ]);
      expect(const Tag(id: 'x', name: 'x', deviceId: 'd').toJson().containsKey('narrations'), isFalse);
      // Arquivo de antes da narração continua abrindo.
      final old = Tag.fromJson({'id': 'o', 'name': 'Velha', 'deviceId': 'd', 'area': 'holdingRegister', 'address': 3});
      expect(old.narrations, isEmpty);
    });

    test('narração que não casa com o tipo é descartada (texto, sem fala, liga/desliga com limite)', () {
      const bit = Tag(id: 'b', name: 'B', deviceId: 'd', dataType: TagDataType.bool, narrations: [
        EventNarration(id: 'on', value: 1, text: 'Ligou'),
        EventNarration(id: 'lim', kind: NarrationKind.above, value: 5, text: 'Não serve'),
        EventNarration(id: 'dois', value: 2, text: 'Não serve'),
      ]);
      expect(bit.normalized().narrations.map((n) => n.id), ['on']);
      const blank = Tag(id: 'n', name: 'N', deviceId: 'd', narrations: [EventNarration(id: 'v', value: 1, text: '  ')]);
      expect(blank.normalized().narrations, isEmpty);
      const txt = Tag(id: 's', name: 'S', deviceId: 'd', dataType: TagDataType.string, length: 4, narrations: [EventNarration(id: 'x', value: 1, text: 'Oi')]);
      expect(txt.normalized().narrations, isEmpty);
    });
  });

  group('preferências e ciclo de vida', () {
    test('voz desligada não fala; ligar com alarme alto esperando fala na hora', () {
      fakeAsync((fa) {
        final r = Rig(prefs: const VoicePrefs(enabled: false, onlyWithHeadset: false));
        r.set([alarm('H', AlarmPriority.high), alarm('M', AlarmPriority.medium)]);
        fa.flushMicrotasks();
        expect(r.speech.spoken, isEmpty);
        r.prefs.value = r.prefs.value.copyWith(enabled: true);
        fa.elapse(Duration.zero);
        expect(r.speech.spoken, ['Alarme urgente: H'], reason: 'a média já passou; a alta ainda pede ação');
        r.prefs.value = r.prefs.value.copyWith(enabled: false);
        fa.flushMicrotasks();
        expect(r.speech.log.last, 'para');
        r.voice.dispose();
      });
    });

    test('segundo plano: para de falar, joga fora a narração e retoma o alarme ao voltar', () {
      fakeAsync((fa) {
        final r = Rig();
        r.set([alarm('H', AlarmPriority.high)]);
        fa.flushMicrotasks();
        r.voice.narrate('narr:x:1', 'Narração velha');
        r.voice.pause();
        fa.flushMicrotasks();
        expect(r.speech.log, ['fala: Alarme urgente: H', 'para']);
        fa.elapse(const Duration(minutes: 1));
        expect(r.speech.spoken, hasLength(1), reason: 'em segundo plano não há voz');
        r.voice.resume();
        fa.flushMicrotasks();
        expect(r.speech.spoken, ['Alarme urgente: H', 'Alarme urgente: H']);
        r.finish(fa);
        expect(r.voice.pending, isEmpty);
        r.voice.dispose();
      });
    });

    test('voz pt-BR ausente vira status com o nome do motor (VZ-6)', () async {
      final r = Rig();
      r.speech.status = const VoiceStatus(VoiceAvailability.missing, engine: 'com.google.android.tts');
      final s = await r.voice.refreshStatus();
      expect(s.isProblem, isTrue);
      expect(s.problem, contains('Serviços de fala do Google'));
      expect(r.voice.status.value.availability, VoiceAvailability.missing);
      expect(const VoiceStatus(VoiceAvailability.notOffline, engine: 'com.exemplo.tts').problem, contains('com.exemplo.tts'));
      expect(const VoiceStatus(VoiceAvailability.ready).problem, isNull);
      r.voice.dispose();
    });

    test('preferências vão e voltam do JSON; lixo cai no padrão', () {
      const p = VoicePrefs(enabled: false, volume: 0.6, rate: VoiceRate.fast, high: VoiceMode.once, repeatSec: 60, narrationGapSec: 30);
      expect(VoicePrefs.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>), p);
      final junk = VoicePrefs.fromJson({'volume': 'alto', 'rate': 'turbo', 'repeatSec': -5, 'high': 'gritar', 'low': 3, 'enabled': 'sim'});
      expect(junk, const VoicePrefs());
    });
  });
}
