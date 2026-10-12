import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:ihm/services/cameras/camera_player.dart';

/// Player de câmera de mentira: o teste diz o que "a câmera" faz (tocar,
/// cair, recusar a senha) e confere o que a sessão pediu — endereço aberto,
/// player descartado.
class FakeCameraPlayer implements CameraPlayer {
  FakeCameraPlayer(this.hub);
  final FakeCameraHub hub;

  final _state = ValueNotifier(const PlayerState());
  String? openedUrl;
  bool disposed = false;

  @override
  ValueListenable<PlayerState> get state => _state;

  @override
  Future<void> open(String url) async {
    openedUrl = url;
    hub.opened.add(url);
    hub.onOpen?.call(this);
  }

  /// A câmera manda imagem: o vídeo anda até [position], com [buffered] de
  /// vídeo já recebido à frente.
  void play(Duration position, {Duration ahead = const Duration(milliseconds: 400), Size size = const Size(640, 360)}) =>
      _state.value = PlayerState(phase: PlayerPhase.playing, position: position, bufferedEnd: position + ahead, size: size);

  void fail(String error) => _state.value = PlayerState(phase: PlayerPhase.failed, error: error);

  void end() => _state.value = const PlayerState(phase: PlayerPhase.ended);

  @override
  Widget view() => const ColoredBox(key: ValueKey('video-falso'), color: Color(0xFF203040), child: SizedBox.expand());

  @override
  Future<void> dispose() async {
    disposed = true;
    hub.disposed++;
  }
}

/// Junta os players criados por uma sessão (cada reconexão cria um novo).
class FakeCameraHub {
  final players = <FakeCameraPlayer>[];
  final opened = <String>[];
  int disposed = 0;

  /// O que a câmera faz ao ser aberta (ex.: tocar logo).
  void Function(FakeCameraPlayer p)? onOpen;

  FakeCameraPlayer create() {
    final p = FakeCameraPlayer(this);
    players.add(p);
    return p;
  }

  FakeCameraPlayer get last => players.last;

  /// Players que ainda não foram descartados (decodificando).
  int get alive => players.where((p) => !p.disposed).length;
}
