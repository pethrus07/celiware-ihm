import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/services/cameras/camera_player.dart';
import 'package:ihm/services/cameras/exo_camera_player.dart';

/// O lado Dart do player nativo (`CameraRtsp.kt`) pelo canal
/// `celiware/camera`, com o Android trocado por um canal simulado: abrir,
/// receber o estado, desenhar a textura, fechar.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('celiware/camera');
  const codec = StandardMethodCodec();
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'abrir') return {'id': 7};
      return null;
    });
  });

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

  /// O Android mandando o estado do player [id].
  Future<void> fromNative(Map<String, Object?> state) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        'celiware/camera',
        codec.encodeMethodCall(MethodCall('estado', state)),
        (_) {},
      );

  test('abre pelo canal, traduz o estado do ExoPlayer e fecha a textura', () async {
    final p = ExoCameraPlayer();
    await p.open('rtsp://admin:1234@10.0.0.5/live');
    expect(calls.single.method, 'abrir');
    expect(calls.single.arguments, {'url': 'rtsp://admin:1234@10.0.0.5/live'});

    await fromNative({'id': 7, 'fase': 'playing', 'erro': null, 'posicao': 4000, 'carregado': 4300, 'largura': 640, 'altura': 360});
    expect(p.state.value, const PlayerState(
      phase: PlayerPhase.playing,
      position: Duration(seconds: 4),
      bufferedEnd: Duration(milliseconds: 4300),
      size: Size(640, 360),
    ));
    final view = p.view();
    expect(view, isA<Center>());

    await fromNative({'id': 7, 'fase': 'failed', 'erro': 'ERROR_CODE_IO_UNSPECIFIED | rtsp DESCRIBE 401', 'posicao': 0, 'carregado': 0, 'largura': 0, 'altura': 0});
    expect(p.state.value.phase, PlayerPhase.failed);
    expect(p.state.value.error, contains('DESCRIBE 401'));
    // Estado de outro player não mexe neste.
    await fromNative({'id': 8, 'fase': 'playing', 'posicao': 1, 'carregado': 1, 'largura': 1, 'altura': 1});
    expect(p.state.value.phase, PlayerPhase.failed);

    await p.dispose();
    expect(calls.last.method, 'fechar');
    expect(calls.last.arguments, {'id': 7});
    await fromNative({'id': 7, 'fase': 'playing', 'posicao': 9, 'carregado': 9, 'largura': 1, 'altura': 1});
    expect(p.state.value.phase, PlayerPhase.failed, reason: 'fechado não recebe mais nada');
  });

  test('descartado antes de o Android responder: fecha a textura que acabou de nascer', () async {
    final p = ExoCameraPlayer();
    final opening = p.open('rtsp://10.0.0.5/live');
    await p.dispose();
    await opening;
    expect(calls.map((c) => c.method), ['abrir', 'fechar']);
  });

  test('Android sem o canal: vira erro de vídeo, sem travar', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    final p = ExoCameraPlayer();
    await p.open('rtsp://10.0.0.5/live');
    expect(p.state.value.phase, PlayerPhase.failed);
    expect(p.state.value.error, contains('decoder'));
  });
}
