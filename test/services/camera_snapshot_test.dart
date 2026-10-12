import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/services/cameras/camera_snapshot.dart';

/// Foto da câmera pela URL HTTP (CM-4) contra um servidor de verdade no
/// próprio teste: senha (Basic), senha errada sem insistir, endereço errado,
/// página de erro no lugar da foto, câmera muda.
void main() {
  late HttpServer server;
  late int hits;
  final jpeg = [0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(64, 0), 0xFF, 0xD9];

  setUp(() async {
    hits = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      hits++;
      final res = req.response;
      final auth = req.headers.value(HttpHeaders.authorizationHeader);
      switch (req.uri.path) {
        case '/foto.jpg':
          if (auth != 'Basic ${base64.encode(utf8.encode('admin:1234'))}') {
            res.statusCode = 401;
            res.headers.set(HttpHeaders.wwwAuthenticateHeader, 'Basic realm="cam"');
          } else {
            res.headers.contentType = ContentType('image', 'jpeg');
            res.add(jpeg);
          }
        case '/aberta.jpg':
          res.add(jpeg);
        case '/pagina':
          res.headers.contentType = ContentType.html;
          res.write('<html>login</html>');
        case '/muda':
          await Future<void>.delayed(const Duration(seconds: 2));
          res.add(jpeg);
        default:
          res.statusCode = 404;
      }
      await res.close();
    });
  });

  tearDown(() => server.close(force: true));

  String url(String path) => 'http://127.0.0.1:${server.port}$path';

  test('com usuário e senha, responde ao pedido de senha da câmera e traz o JPEG', () async {
    final bytes = await CameraSnapshot.fetch(url('/foto.jpg'), user: 'admin', password: '1234');
    expect(bytes, jpeg);
    expect(hits, 2, reason: 'o primeiro pedido volta 401 e o segundo leva a senha');
  });

  test('câmera sem senha', () async {
    expect(await CameraSnapshot.fetch(url('/aberta.jpg')), jpeg);
  });

  test('senha errada: uma tentativa só e o motivo em palavras', () async {
    await expectLater(
      CameraSnapshot.fetch(url('/foto.jpg'), user: 'admin', password: 'errada'),
      throwsA(isA<SnapshotError>().having((e) => e.message, 'message', 'a câmera recusou o usuário ou a senha')),
    );
    expect(hits, 2, reason: 'não insiste: câmera bloqueia o usuário');
  });

  test('endereço errado, página no lugar da foto, câmera muda', () async {
    await expectLater(CameraSnapshot.fetch(url('/nada')),
        throwsA(isA<SnapshotError>().having((e) => e.message, 'message', contains('respondeu 404'))));
    await expectLater(CameraSnapshot.fetch(url('/pagina')),
        throwsA(isA<SnapshotError>().having((e) => e.message, 'message', contains('não mandou uma imagem'))));
    await expectLater(CameraSnapshot.fetch(url('/muda'), timeout: const Duration(milliseconds: 300)),
        throwsA(isA<SnapshotError>().having((e) => e.message, 'message', 'a câmera não respondeu a tempo')));
    await expectLater(CameraSnapshot.fetch('rtsp://x/y'), throwsA(isA<SnapshotError>()));
  });

  test('reconhece JPEG e PNG pelos primeiros bytes', () {
    expect(CameraSnapshot.isImage(jpeg), isTrue);
    expect(CameraSnapshot.isImage([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0]), isTrue);
    expect(CameraSnapshot.isImage(utf8.encode('<html>')), isFalse);
  });
}
