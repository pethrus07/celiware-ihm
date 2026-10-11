import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

/// Saída de áudio do celular, pelo canal `celiware/voz` (`SaidaDeAudio.kt`).
///
/// O `flutter_tts` não diz se há fone conectado nem abre os ajustes de voz
/// do sistema; isso é Android puro (`AudioManager.getDevices` e o intent
/// `com.android.settings.TTS_SETTINGS`). Fora do Android (testes, Windows)
/// tudo aqui é inofensivo: [headsetConnected] devolve nulo ("não sei").
class AudioOutput {
  AudioOutput._();

  static final Logger _log = Logger('AudioOutput');
  static const _channel = MethodChannel('celiware/voz');

  /// A plataforma informa se há fone? (Sem isso, a opção "só com fone" nem
  /// aparece — prometer o que não dá para cumprir é pior que não oferecer.)
  static bool get canDetectHeadset => Platform.isAndroid;

  /// Fone com fio, Bluetooth (A2DP/SCO/LE) ou USB conectado agora. Nulo =
  /// a plataforma não informa.
  static Future<bool?> headsetConnected() async {
    if (!canDetectHeadset) return null;
    try {
      return await _channel.invokeMethod<bool>('foneConectado');
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      _log.warning('Não leu as saídas de áudio: ${e.message}');
      return null;
    }
  }

  /// Há ajustes de voz do sistema para abrir? (Só no Android.)
  static bool get canOpenVoiceSettings => Platform.isAndroid;

  /// Abre os ajustes de voz do sistema (motor, idioma, baixar a voz pt-BR).
  /// Devolve falso se não conseguiu abrir nada.
  static Future<bool> openVoiceSettings() async {
    if (!canOpenVoiceSettings) return false;
    try {
      return await _channel.invokeMethod<bool>('abrirAjustesDeVoz') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      _log.warning('Não abriu os ajustes de voz: ${e.message}');
      return false;
    }
  }
}
