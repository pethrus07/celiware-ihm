import 'camera_player.dart';
import 'exo_camera_player.dart';

/// De onde vem o player das câmeras. Os testes de tela trocam por um falso.
class CameraPlayers {
  CameraPlayers._();

  static CameraPlayerFactory factory = ExoCameraPlayer.new;
}
