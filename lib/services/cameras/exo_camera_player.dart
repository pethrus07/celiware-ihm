// Player de câmera do Android: o ExoPlayer (Media3) com RTSP, pelo canal
// `celiware/camera` (`CameraRtsp.kt`), desenhando numa textura.
//
// Por que um canal próprio e não o `video_player` (que também é ExoPlayer):
// ele começa só com 2,5 s de vídeo guardado e não deixa mudar, trata o fluxo
// ao vivo como vídeo de duração zero (a posição fica em 0 e ele "termina" na
// hora) e entrega todo erro como "Source error" — sem dizer se foi a senha.
// Ver ARQUITETURA.md, "Câmeras".

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'camera_player.dart';

class ExoCameraPlayer implements CameraPlayer {
  static const _channel = MethodChannel('celiware/camera');

  /// Players abertos, pelo id da textura (o lado nativo manda o estado de
  /// todos pelo mesmo canal).
  static final _open = <int, ExoCameraPlayer>{};
  static bool _wired = false;

  final _state = ValueNotifier(const PlayerState());
  int? _id;
  bool _disposed = false;

  @override
  ValueListenable<PlayerState> get state => _state;

  static void _wire() {
    if (_wired) return;
    _wired = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'estado' || call.arguments is! Map) return;
      final m = Map<String, Object?>.from(call.arguments as Map);
      _open[(m['id'] as num?)?.toInt()]?._apply(m);
    });
  }

  @override
  Future<void> open(String url) async {
    _wire();
    try {
      final r = await _channel.invokeMapMethod<String, Object?>('abrir', {'url': url});
      final id = (r?['id'] as num?)?.toInt();
      if (id == null) throw PlatformException(code: 'camera', message: 'sem textura');
      if (_disposed) {
        await _channel.invokeMethod<void>('fechar', {'id': id});
        return;
      }
      _id = id;
      _open[id] = this;
    } on MissingPluginException {
      if (!_disposed) _state.value = const PlayerState(phase: PlayerPhase.failed, error: 'decoder: sem player de vídeo neste aparelho');
    } on PlatformException catch (e) {
      if (!_disposed) _state.value = PlayerState(phase: PlayerPhase.failed, error: e.message ?? e.code);
    }
  }

  void _apply(Map<String, Object?> m) {
    if (_disposed) return;
    final phase = switch (m['fase']) {
      'playing' => PlayerPhase.playing,
      'buffering' => PlayerPhase.buffering,
      'ended' => PlayerPhase.ended,
      'failed' => PlayerPhase.failed,
      _ => PlayerPhase.opening,
    };
    final w = (m['largura'] as num?)?.toDouble() ?? 0;
    final h = (m['altura'] as num?)?.toDouble() ?? 0;
    _state.value = PlayerState(
      phase: phase,
      error: m['erro'] as String?,
      position: Duration(milliseconds: (m['posicao'] as num?)?.toInt() ?? 0),
      bufferedEnd: m['carregado'] == null ? null : Duration(milliseconds: (m['carregado'] as num).toInt()),
      size: w > 0 && h > 0 ? Size(w, h) : null,
    );
  }

  @override
  Widget view() {
    final id = _id;
    if (id == null) return const SizedBox.expand();
    final size = _state.value.size;
    return Center(child: AspectRatio(aspectRatio: size == null ? 16 / 9 : size.width / size.height, child: Texture(textureId: id)));
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    final id = _id;
    _id = null;
    if (id == null) return;
    _open.remove(id);
    try {
      await _channel.invokeMethod<void>('fechar', {'id': id});
    } on PlatformException {
      // Activity já encerrada: o lado nativo soltou tudo.
    } on MissingPluginException {
      // Idem.
    }
  }
}
