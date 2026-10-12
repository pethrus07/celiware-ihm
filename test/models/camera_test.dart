import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/models/camera.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/storage/project_repository.dart';

/// Câmeras no projeto (CM-1, CM-5): arquivo, senha fora dele, endereços.
void main() {
  const cam = IpCamera(
    id: 'cam1',
    name: 'Saída da cortadora',
    deviceId: DemoProject.deviceId,
    url: 'rtsp://192.168.1.64:554/Streaming/Channels/101',
    substreamUrl: 'rtsp://192.168.1.64:554/Streaming/Channels/102',
    snapshotUrl: 'http://192.168.1.64/ISAPI/Streaming/channels/101/picture',
    username: 'admin',
    secretRef: 'cs_ref1',
  );

  group('arquivo do projeto', () {
    test('projeto sem câmera abre e grava igual ao de antes, schemaVersion 1', () {
      final demo = DemoProject.build();
      final old = jsonDecode(utf8.decode(ProjectRepository.encode(demo))) as Map<String, dynamic>;
      expect(old.containsKey('cameras'), isFalse);
      final again = jsonDecode(utf8.decode(ProjectRepository.encode(ProjectRepository.decode(utf8.encode(jsonEncode(old)))))) as Map<String, dynamic>;
      expect(again, old);
      expect(again['schemaVersion'], 1);
    });

    test('câmera passa pelo arquivo com tudo, menos a senha', () {
      final p = DemoProject.build().upsertCamera(cam);
      final bytes = ProjectRepository.encode(p);
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      expect(json['schemaVersion'], 1);
      expect((json['cameras'] as List).single, {
        'id': 'cam1',
        'name': 'Saída da cortadora',
        'deviceId': DemoProject.deviceId,
        'url': 'rtsp://192.168.1.64:554/Streaming/Channels/101',
        'substreamUrl': 'rtsp://192.168.1.64:554/Streaming/Channels/102',
        'snapshotUrl': 'http://192.168.1.64/ISAPI/Streaming/channels/101/picture',
        'username': 'admin',
        'secretRef': 'cs_ref1',
      });
      final back = ProjectRepository.decode(bytes);
      expect(back.camera('cam1')!.liveUrl, cam.substreamUrl);
      expect(back.camerasOf(DemoProject.deviceId).single.name, 'Saída da cortadora');
      expect(ProjectRepository.encode(back), bytes);
    });

    test('campos vazios não vão para o arquivo; câmera sem senha não tem chave', () {
      const bare = IpCamera(id: 'c', name: 'Portão', url: 'rtsp://10.0.0.9/live');
      expect(bare.toJson(), {'id': 'c', 'name': 'Portão', 'url': 'rtsp://10.0.0.9/live'});
      expect(bare.hasPassword, isFalse);
      expect(bare.liveUrl, 'rtsp://10.0.0.9/live', reason: 'sem fluxo leve, abre o principal');
    });

    test('URL com senha num arquivo editado à mão: a senha some e a câmera passa a pedir', () {
      final c = IpCamera.fromJson({'id': 'c', 'name': 'X', 'url': 'rtsp://admin:s3gr3d0@192.168.1.64:554/live', 'password': 'outra'});
      expect(c.url, 'rtsp://192.168.1.64:554/live');
      expect(c.username, 'admin');
      expect(c.hasPassword, isTrue, reason: 'havia senha: o app pede de novo');
      final text = jsonEncode(DemoProject.build().upsertCamera(c).toJson());
      expect(text.contains('s3gr3d0'), isFalse);
      expect(text.contains('outra'), isFalse);
    });

    test('importar: toda câmera com senha ganha chave nova no cofre; a sem senha fica igual', () {
      const open = IpCamera(id: 'c2', name: 'Pátio', url: 'rtsp://10.0.0.2/live');
      final p = DemoProject.build().upsertCamera(cam).upsertCamera(open);
      final imported = p.withFreshCameraSecrets();
      expect(imported.camera('cam1')!.hasPassword, isTrue);
      expect(imported.camera('cam1')!.secretRef, isNot('cs_ref1'));
      expect(imported.camera('c2')!.secretRef, isNull);
      expect(imported.cameraSecretRefs, {imported.camera('cam1')!.secretRef});
      expect(DemoProject.build().withFreshCameraSecrets().cameras, isEmpty);
    });

    test('apagar câmera', () {
      final p = DemoProject.build().upsertCamera(cam).removeCamera('cam1');
      expect(p.cameras, isEmpty);
    });
  });

  group('endereços', () {
    test('separa usuário e senha de dentro da URL, decodificando', () {
      final r = CameraUrl.split('rtsp://admin:p%40ss%3Aw0rd@192.168.1.64:554/cam/realmonitor?channel=1&subtype=0');
      expect(r.url, 'rtsp://192.168.1.64:554/cam/realmonitor?channel=1&subtype=0', reason: 'a consulta fica como estava');
      expect(r.user, 'admin');
      expect(r.password, 'p@ss:w0rd');
      expect(CameraUrl.split('rtsp://192.168.1.64/live').user, isNull);
      expect(CameraUrl.split('rtsp://so-usuario@10.0.0.1/x'), (url: 'rtsp://10.0.0.1/x', user: 'so-usuario', password: null));
      // "@" depois do caminho não é usuário.
      expect(CameraUrl.split('rtsp://10.0.0.1/a@b').url, 'rtsp://10.0.0.1/a@b');
    });

    test('junta usuário e senha codificados para o player (senha com @ : / #)', () {
      final url = CameraUrl.withCredentials('rtsp://192.168.1.64:554/live', 'admin', 'a@b:c/d#e');
      expect(url, 'rtsp://admin:a%40b%3Ac%2Fd%23e@192.168.1.64:554/live');
      final back = CameraUrl.split(url);
      expect((back.user, back.password, back.url), ('admin', 'a@b:c/d#e', 'rtsp://192.168.1.64:554/live'));
      expect(CameraUrl.withCredentials('rtsp://h/x', '', 'senha'), 'rtsp://h/x', reason: 'sem usuário, nada');
    });

    test('IP para a lista', () {
      expect(CameraUrl.host('rtsp://admin:x@192.168.1.64:554/live'), '192.168.1.64');
      expect(CameraUrl.host('rtsp://camera.local/live'), 'camera.local');
      expect(CameraUrl.host('rtsp://[fe80::1]:554/x'), 'fe80::1');
      expect(CameraUrl.host('rtsp:///x'), isNull);
    });

    test('erros do endereço em palavras', () {
      expect(CameraUrl.rtspError(''), contains('rtsp://'));
      expect(CameraUrl.rtspError('http://192.168.1.64/live'), 'O endereço do vídeo começa com rtsp://');
      expect(CameraUrl.rtspError('rtsp:///live'), contains('Falta o IP'));
      expect(CameraUrl.rtspError('rtsp://192.168.1.64/minha camera'), contains('espaço'));
      expect(CameraUrl.rtspError('RTSP://192.168.1.64/live'), isNull);
      expect(CameraUrl.httpError(''), isNull, reason: 'foto é opcional');
      expect(CameraUrl.httpError('rtsp://x/y'), 'O endereço da foto começa com http://');
      expect(CameraUrl.httpError('https://10.0.0.1/snap.jpg'), isNull);
    });

    test('sugere o fluxo leve das marcas conhecidas', () {
      expect(CameraUrl.substreamGuess('rtsp://h:554/Streaming/Channels/101'), 'rtsp://h:554/Streaming/Channels/102');
      expect(CameraUrl.substreamGuess('rtsp://h/Streaming/Channels/201?transportmode=unicast'), 'rtsp://h/Streaming/Channels/202?transportmode=unicast');
      expect(CameraUrl.substreamGuess('rtsp://h/h264/ch1/main/av_stream'), 'rtsp://h/h264/ch1/sub/av_stream');
      expect(CameraUrl.substreamGuess('rtsp://h:554/cam/realmonitor?channel=1&subtype=0'), 'rtsp://h:554/cam/realmonitor?channel=1&subtype=1');
      expect(CameraUrl.substreamGuess('rtsp://h:554/stream1'), 'rtsp://h:554/stream2');
      expect(CameraUrl.substreamGuess('rtsp://h/Streaming/Channels/102'), isNull, reason: 'já é o leve');
      expect(CameraUrl.substreamGuess('rtsp://h/live'), isNull);
      expect(CameraUrl.substreamGuess('rtsp://admin:x@h/Streaming/Channels/101'), 'rtsp://h/Streaming/Channels/102', reason: 'nunca devolve a senha');
    });

    test('modelos das marcas preenchem o IP', () {
      final hik = CameraBrand.all.first;
      expect(hik.fill(hik.main, ' 192.168.1.64 '), 'rtsp://192.168.1.64:554/Streaming/Channels/101');
      expect(CameraUrl.substreamGuess(hik.fill(hik.main, '10.0.0.5')), hik.fill(hik.sub, '10.0.0.5'));
      final dahua = CameraBrand.all[1];
      expect(CameraUrl.substreamGuess(dahua.fill(dahua.main, '10.0.0.5')), dahua.fill(dahua.sub, '10.0.0.5'));
    });
  });
}
