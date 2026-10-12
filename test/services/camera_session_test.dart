import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/models/camera.dart';
import 'package:ihm/services/cameras/camera_session.dart';
import 'package:ihm/services/cameras/camera_vault.dart';

import '../support/fake_camera_player.dart';

/// Sessão da câmera (CM-2, CM-3) com player falso e relógio simulado:
/// estado, atraso, reconexão sozinha, senha recusada sem insistir, e nada
/// decodificando depois de fechar ou ir para segundo plano.
void main() {
  const cam = IpCamera(
    id: 'c',
    name: 'Prensa',
    url: 'rtsp://192.168.1.64:554/Streaming/Channels/101',
    substreamUrl: 'rtsp://192.168.1.64:554/Streaming/Channels/102',
    username: 'admin',
    secretRef: 'ref',
  );

  late MemoryCameraVault vault;
  late FakeCameraHub hub;

  setUp(() {
    vault = MemoryCameraVault()..entries['ref'] = 'p@ss:1';
    hub = FakeCameraHub();
  });

  CameraSession open(FakeAsync async, {IpCamera camera = cam}) {
    final s = CameraSession(camera, vault: vault, newPlayer: hub.create)..start();
    async.flushMicrotasks();
    return s;
  }

  test('abre o fluxo leve com usuário e senha codificados; ao vivo mostra o atraso', () {
    fakeAsync((async) {
      final s = open(async);
      expect(s.status.link, CameraLink.connecting);
      expect(hub.opened.single, 'rtsp://admin:p%40ss%3A1@192.168.1.64:554/Streaming/Channels/102');
      for (var i = 1; i <= 6; i++) {
        hub.last.play(Duration(milliseconds: 500 * i), ahead: const Duration(milliseconds: 600));
        async.elapse(const Duration(milliseconds: 500));
      }
      expect(s.status.link, CameraLink.live);
      expect(s.status.latency, const Duration(milliseconds: 600));
      expect(s.status.resolution, (width: 640, height: 360));
      s.dispose();
      async.flushMicrotasks();
      expect(hub.alive, 0, reason: 'fechar descarta o player: nada decodifica escondido');
    });
  });

  test('alta qualidade troca para o fluxo principal, com um player novo', () {
    fakeAsync((async) {
      final s = open(async);
      expect(s.canSwitchQuality, isTrue);
      s.setHighQuality(true);
      async.flushMicrotasks();
      expect(hub.opened.last, 'rtsp://admin:p%40ss%3A1@192.168.1.64:554/Streaming/Channels/101');
      expect(hub.alive, 1);
      s.dispose();
    });
  });

  test('câmera desligada: sem sinal com o motivo e tenta de novo sozinha, com espera crescente', () {
    fakeAsync((async) {
      final s = open(async);
      hub.last.fail('ERROR_CODE_IO_NETWORK_CONNECTION_FAILED | connect failed to connect to /192.168.1.64 (port 554): ECONNREFUSED (Connection refused)');
      async.flushMicrotasks();
      expect(s.status.link, CameraLink.noSignal);
      expect(s.status.detail, contains('recusou a conexão'));
      expect(s.status.retryInSec, 1);
      expect(hub.alive, 0, reason: 'o player com erro é descartado');
      async.elapse(const Duration(milliseconds: 1100));
      expect(hub.players, hasLength(2), reason: 'reconectou depois de 1 s');
      expect((s.status.link, s.status.retryInSec), (CameraLink.noSignal, 0),
          reason: 'tentando de novo continua "sem sinal" com o motivo, não "conectando"');
      expect(s.status.detail, contains('recusou a conexão'));
      hub.last.fail('timeout');
      async.flushMicrotasks();
      expect(s.status.retryInSec, 2);
      expect(s.status.detail, contains('não respondeu'));
      async.elapse(const Duration(seconds: 1));
      expect(s.status.retryInSec, 1, reason: 'a contagem anda na tela');
      async.elapse(const Duration(seconds: 1));
      expect(hub.players, hasLength(3));
      // Voltou: a espera zera.
      hub.last.play(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(s.status.link, CameraLink.live);
      hub.last.end();
      async.flushMicrotasks();
      expect(s.status.retryInSec, 1);
      s.dispose();
    });
  });

  test('senha recusada: avisa e não tenta de novo sozinha (câmera bloqueia o usuário)', () {
    fakeAsync((async) {
      final s = open(async);
      hub.last.fail('ERROR_CODE_IO_UNSPECIFIED | rtsp DESCRIBE 401');
      async.flushMicrotasks();
      expect(s.status.link, CameraLink.authFailed);
      async.elapse(const Duration(minutes: 1));
      expect(hub.players, hasLength(1));
      // Senha nova digitada: abre de novo.
      vault.entries['ref'] = 'certa';
      s.update(cam);
      async.flushMicrotasks();
      expect(hub.opened.last, contains('admin:certa@'));
      s.dispose();
    });
  });

  test('imagem parada (câmera caiu sem fechar a conexão) vira sem sinal e reconecta', () {
    fakeAsync((async) {
      final s = open(async);
      hub.last.play(const Duration(seconds: 1));
      async.elapse(const Duration(seconds: 4));
      expect(s.status.link, CameraLink.live);
      async.elapse(const Duration(seconds: 2));
      expect(s.status.link, CameraLink.noSignal);
      expect(s.status.detail, 'a imagem parou de chegar');
      async.elapse(const Duration(seconds: 1));
      expect(hub.players, hasLength(2));
      s.dispose();
    });
  });

  test('conectou e nunca mandou imagem: sem sinal depois de 15 s', () {
    fakeAsync((async) {
      final s = open(async);
      async.elapse(const Duration(seconds: 14));
      expect(s.status.link, CameraLink.connecting);
      async.elapse(const Duration(seconds: 2));
      expect(s.status.link, CameraLink.noSignal);
      expect(s.status.detail, 'a câmera não mandou imagem');
      s.dispose();
    });
  });

  test('segundo plano solta o player na hora; a volta abre de novo', () {
    fakeAsync((async) {
      final s = open(async);
      hub.last.play(const Duration(seconds: 1));
      async.flushMicrotasks();
      s.pause();
      async.flushMicrotasks();
      expect(s.status.link, CameraLink.paused);
      expect(hub.alive, 0);
      async.elapse(const Duration(minutes: 1));
      expect(hub.players, hasLength(1), reason: 'em segundo plano não reconecta');
      s.resume();
      async.flushMicrotasks();
      expect(hub.players, hasLength(2));
      expect(hub.alive, 1);
      s.dispose();
    });
  });

  test('senha que não está neste aparelho (projeto importado): pede, sem abrir o vídeo', () {
    fakeAsync((async) {
      vault.entries.clear();
      final s = open(async);
      expect(s.status.link, CameraLink.needsPassword);
      expect(hub.players, isEmpty);
      s.dispose();
    });
  });

  test('câmera sem senha abre sem usuário na URL', () {
    fakeAsync((async) {
      final s = open(async, camera: const IpCamera(id: 'x', url: 'rtsp://10.0.0.2/live'));
      expect(hub.opened.single, 'rtsp://10.0.0.2/live');
      expect(s.canSwitchQuality, isFalse);
      s.dispose();
    });
  });

  test('erros do player em palavras', () {
    expect(CameraErrors.isAuth('rtsp DESCRIBE 401'), isTrue);
    expect(CameraErrors.isAuth('connect failed to /192.168.1.40 (port 4010)'), isFalse, reason: '401 dentro de IP ou porta não é senha');
    expect(CameraErrors.describe('rtsp DESCRIBE 404'), contains('não conhece esse endereço'));
    expect(CameraErrors.describe('connect ... EHOSTUNREACH (No route to host)'), contains('não respondeu'));
    expect(CameraErrors.describe('ERROR_CODE_PARSING_MANIFEST_MALFORMED | missing sprop parameter'), contains('não consegue mostrar'));
    expect(CameraErrors.describe('ERROR_CODE_DECODER_INIT_FAILED'), contains('não consegue mostrar'));
    expect(CameraErrors.describe('unknownhost'), contains('não encontrado'));
    expect(CameraErrors.describe('???'), 'sem sinal da câmera');
  });
}
