import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:logging/logging.dart';

/// Se o aparelho consegue falar português do Brasil sem internet (VZ-6).
enum VoiceAvailability {
  /// Ainda não conferido, ou a plataforma não informa (testes).
  unknown,

  /// Voz pt-BR instalada, funciona offline.
  ready,

  /// O motor conhece pt-BR, mas a voz não está baixada (ou só fala com
  /// internet) — a rede da máquina quase nunca tem.
  notOffline,

  /// O motor de voz não tem português do Brasil.
  missing,

  /// O aparelho não tem motor de voz nenhum.
  noEngine,
}

/// Resultado da conferência da voz, com o nome do motor para a mensagem.
class VoiceStatus {
  const VoiceStatus(this.availability, {this.engine});

  final VoiceAvailability availability;

  /// Pacote do motor de voz padrão ("com.google.android.tts").
  final String? engine;

  static const unknown = VoiceStatus(VoiceAvailability.unknown);

  bool get isProblem =>
      availability == VoiceAvailability.notOffline ||
      availability == VoiceAvailability.missing ||
      availability == VoiceAvailability.noEngine;

  /// Nome que a pessoa reconhece nos ajustes do Android.
  String get engineName => switch (engine) {
        null || '' => 'motor de voz do celular',
        'com.google.android.tts' => 'Serviços de fala do Google',
        'com.samsung.SMT' => 'Conversão de texto em voz da Samsung',
        _ => engine!,
      };

  /// O que falta, dito com nome — ou nulo se está tudo certo.
  String? get problem => switch (availability) {
        VoiceAvailability.missing => 'Falta a voz em português (Brasil) em "$engineName".',
        VoiceAvailability.notOffline => 'A voz em português (Brasil) de "$engineName" não está baixada: sem internet ela não fala.',
        VoiceAvailability.noEngine => 'Este celular não tem motor de voz. Instale um, como os Serviços de fala do Google.',
        _ => null,
      };
}

/// O que fala de fato. Interface para o [VoiceAnnouncer] ser testado com um
/// motor falso (a fila, a interrupção e a repetição são lógica de Dart; o
/// motor só fala e para).
abstract class SpeechEngine {
  /// Fala [text] e completa quando terminar — ou quando [stop] interromper.
  /// Nunca fica pendurado: falha vira exceção.
  Future<void> speak(String text, {required double volume, required double rate});

  /// Para a fala em curso agora.
  Future<void> stop();

  /// Confere se há voz pt-BR que funcione sem internet.
  Future<VoiceStatus> check();
}

/// Motor real: `flutter_tts` (Android `TextToSpeech`; Windows WinRT).
///
/// Ajustes de Android: a fala usa o atributo de **navigation guidance**
/// (como o GPS: abaixa a música e sai no fone, se houver) e pede foco de
/// áudio transitório com "abaixar os outros" (`speak(focus: true)`). Um
/// silêncio curto antes de cada fala dá tempo ao fone Bluetooth de acordar —
/// sem ele, a primeira sílaba some.
class FlutterTtsEngine implements SpeechEngine {
  FlutterTtsEngine();

  static final Logger _log = Logger('Voz');
  static const language = 'pt-BR';

  FlutterTts? _tts;
  Future<FlutterTts>? _starting;
  bool _unavailable = false;
  void Function(Object?)? _onError;
  double? _volume;
  double? _rate;

  /// Cria o motor uma vez, no primeiro uso (a conferência da voz pt-BR logo
  /// que o app abre com a voz ligada). Com a voz desligada, nunca é criado.
  Future<FlutterTts> _ready() => _starting ??= () async {
        final t = FlutterTts();
        t.setErrorHandler((m) => _onError?.call(m));
        await t.awaitSpeakCompletion(true);
        if (Platform.isAndroid) {
          await t.setAudioAttributesForNavigation();
          await t.setSilence(300);
        }
        await t.setLanguage(language);
        _tts = t;
        return t;
      }();

  @override
  Future<void> speak(String text, {required double volume, required double rate}) async {
    if (_unavailable) return;
    final FlutterTts tts;
    try {
      tts = await _ready();
    } on MissingPluginException {
      // Sem o plugin (testes de widget, plataforma sem voz): cala para sempre.
      _unavailable = true;
      return;
    }
    if (volume != _volume) {
      await tts.setVolume(volume);
      _volume = volume;
    }
    if (rate != _rate) {
      await tts.setSpeechRate(rate);
      _rate = rate;
    }
    final failed = Completer<void>();
    _onError = (m) {
      if (!failed.isCompleted) failed.completeError(StateError('motor de voz: $m'));
    };
    try {
      // O plugin do Android não responde ao `speak` quando o motor dá erro
      // no meio da fala: o erro chega pelo handler, e o tempo-limite (folgado,
      // pela velocidade mais lenta) garante que a fila nunca trava.
      await Future.any([tts.speak(text, focus: true), failed.future])
          .timeout(Duration(milliseconds: 5000 + (text.length * 150 / (rate / 0.5)).round()));
    } on TimeoutException {
      _log.warning('A fala não terminou no tempo esperado; seguindo a fila.');
      await stop();
    } finally {
      _onError = null;
    }
  }

  @override
  Future<void> stop() async {
    final t = _tts;
    if (t == null) return;
    try {
      await t.stop();
    } catch (e) {
      _log.warning('Não parou a fala: $e');
    }
  }

  @override
  Future<VoiceStatus> check() async {
    if (_unavailable) return VoiceStatus.unknown;
    try {
      // Sem tempo-limite aqui: o Android sempre responde à criação do motor
      // (sucesso ou erro), e se não respondesse o pior seria o aviso não
      // aparecer. O tempo-limite que importa é o da fala (a fila não trava).
      final tts = await _ready();
      if (Platform.isAndroid) {
        final engines = await tts.getEngines;
        final engine = await tts.getDefaultEngine as String?;
        if (engines is List && engines.isEmpty) return const VoiceStatus(VoiceAvailability.noEngine);
        if (await tts.isLanguageAvailable(language) != true) return VoiceStatus(VoiceAvailability.missing, engine: engine);
        // "Instalada" no plugin = voz pt-BR que não exige rede e já baixada.
        final offline = await tts.isLanguageInstalled(language) == true;
        return VoiceStatus(offline ? VoiceAvailability.ready : VoiceAvailability.notOffline, engine: engine);
      }
      final langs = await tts.getLanguages;
      final has = langs is List && langs.any((l) => '$l'.replaceAll('_', '-').toLowerCase() == 'pt-br');
      return VoiceStatus(has ? VoiceAvailability.ready : VoiceAvailability.missing, engine: Platform.isWindows ? 'Windows' : null);
    } on MissingPluginException {
      _unavailable = true;
      return VoiceStatus.unknown;
    } catch (e) {
      _log.warning('Não conferiu a voz: $e');
      return VoiceStatus.unknown;
    }
  }
}
