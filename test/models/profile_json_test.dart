import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/storage/project_repository.dart';

/// `Device.profile` e `Tag.memory` (MP-2): campo novo e opcional, no arquivo
/// só quando existe — projeto genérico fica byte a byte igual ao de antes e
/// o `schemaVersion` continua 1 (ARQUITETURA §10.4).
void main() {
  group('Device.profile', () {
    test('ida e volta com perfil', () {
      const d = Device(id: 'd', name: 'CLP', host: '192.168.1.10', profile: 'inovance-h3u');
      final j = d.toJson();
      expect(j['profile'], 'inovance-h3u');
      expect(Device.fromJson(j).profile, 'inovance-h3u');
    });

    test('genérico não grava o campo; arquivo antigo abre como genérico', () {
      const d = Device(id: 'd', name: 'CLP', host: '192.168.1.10');
      expect(d.toJson().containsKey('profile'), isFalse);
      final old = {'id': 'd', 'name': 'CLP', 'kind': 'modbusTcp', 'host': '10.0.0.1', 'port': 502, 'unitId': 1, 'timeoutMs': 1500, 'pollMs': 500};
      expect(Device.fromJson(old).profile, isNull);
    });

    test('copyWith mantém o perfil; withProfile troca, inclusive para genérico', () {
      const d = Device(id: 'd', name: 'CLP', profile: 'weg-tpw04');
      expect(d.copyWith(name: 'Outro').profile, 'weg-tpw04');
      expect(d.withProfile(null).profile, isNull);
      expect(d.withProfile('invt-ivc3').name, 'CLP');
      // Trocar a marca não reabre a conexão.
      expect(d.withProfile('invt-ivc3').sameLinkAs(d), isTrue);
    });

    test('id de perfil de versão mais nova é preservado no arquivo', () {
      final j = const Device(id: 'd', name: 'CLP', profile: 'marca-do-futuro').toJson();
      expect(Device.fromJson(j).toJson()['profile'], 'marca-do-futuro');
    });
  });

  group('Tag.memory', () {
    test('ida e volta com a memória do manual', () {
      const t = Tag(id: 't', name: 'Temperatura', deviceId: 'd', address: 200, memory: 'D200');
      final j = t.toJson();
      expect(j['memory'], 'D200');
      final back = Tag.fromJson(j);
      expect((back.memory, back.address, back.area), ('D200', 200, t.area));
    });

    test('sem memória não grava o campo; arquivo antigo abre sem memória', () {
      const t = Tag(id: 't', name: 'x', deviceId: 'd', address: 5);
      expect(t.toJson().containsKey('memory'), isFalse);
      final old = {'id': 't', 'name': 'x', 'deviceId': 'd', 'area': 'holdingRegister', 'address': 5, 'dataType': 'uint16'};
      expect(Tag.fromJson(old).memory, isNull);
    });

    test('memória vazia vira nula; withMemory troca e apaga', () {
      expect(const Tag(id: 't', name: 'x', deviceId: 'd', memory: '  ').normalized().memory, isNull);
      const t = Tag(id: 't', name: 'x', deviceId: 'd', memory: 'D1', alarms: []);
      expect(t.copyWith(name: 'y').memory, 'D1');
      expect(t.withMemory(null).memory, isNull);
      expect(t.withMemory('D2').name, 'x');
    });

    test('a lista mostra a memória antes do endereço Modbus', () {
      expect(const Tag(id: 't', name: 'x', deviceId: 'd', address: 200, memory: 'D200').memoryLabel, 'D200 · HR 200');
      expect(const Tag(id: 't', name: 'x', deviceId: 'd', address: 200).memoryLabel, 'HR 200');
    });
  });

  test('projeto com perfil e memória passa pelo arquivo sem subir o schemaVersion', () {
    const p = Project(
      devices: [Device(id: 'd', name: 'CLP', host: '10.0.0.1', profile: 'invt-ivc1')],
      tags: [Tag(id: 't', name: 'Entrada', deviceId: 'd', address: 8, memory: 'X10')],
    );
    final bytes = ProjectRepository.encode(p);
    final back = ProjectRepository.decode(bytes);
    expect(p.toJson()['schemaVersion'], 1);
    expect(back.devices.single.profile, 'invt-ivc1');
    expect(back.tags.single.memory, 'X10');
  });
}
