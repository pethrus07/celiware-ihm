import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/http/http_error.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/http_config.dart';
import 'package:ihm/models/mqtt_config.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/runtime/http_codec.dart';
import 'package:ihm/services/runtime/tag_codec.dart';
import 'package:ihm/services/storage/project_repository.dart';

Tag ht(String select,
        {HttpExtract extract = HttpExtract.json,
        TagDataType type = TagDataType.float32,
        double scale = 1,
        int length = 1,
        bool writable = false,
        HttpTagAddress? address}) =>
    Tag(
      id: 'x',
      name: 'x',
      deviceId: 'esp',
      dataType: type,
      scale: scale,
      length: length,
      writable: writable,
      http: address ?? HttpTagAddress(path: '/api/status', extract: extract, select: select),
    );

/// HTTP sem rede: o modelo (URL base, arquivo do projeto, segredos fora
/// dele), o seletor do valor (caminho JSON e expressão regular) e o comando
/// de gravar com `{valor}`.
void main() {
  const status = '{"data": {"temperatura": 25.3, "umidade": "61", "bomba": true, "modo": "AUTO"},'
      ' "itens": [{"valor": 7}, {"valor": 8.5}], "producao": [10, 20, 30], "vazio": null}';

  group('caminho JSON', () {
    test('campo dentro de objeto e posição de lista', () {
      expect(HttpCodec.decode(ht('data.temperatura'), status), 25.3);
      expect(HttpCodec.decode(ht('itens[0].valor', type: TagDataType.uint16), status), 7);
      expect(HttpCodec.decode(ht('itens[1].valor'), status), 8.5);
      expect(HttpCodec.decode(ht('itens.1.valor'), status), 8.5, reason: 'posição também com ponto');
    });

    test('número em texto, liga/desliga, texto, lista e escala', () {
      expect(HttpCodec.decode(ht('data.umidade', type: TagDataType.uint16), status), 61);
      expect(HttpCodec.decode(ht('data.bomba', type: TagDataType.bool), status), isTrue);
      expect(HttpCodec.decode(ht('data.modo', type: TagDataType.string), status), 'AUTO');
      expect(HttpCodec.decode(ht('producao', type: TagDataType.uint16, length: 3), status), [10, 20, 30]);
      expect(HttpCodec.decode(ht('data.temperatura', scale: 10), status), closeTo(253, 1e-9));
    });

    test('erros da variável, com o campo no texto', () {
      expect(() => HttpCodec.decode(ht('data.pressao'), status), throwsA(isA<TagValueError>().having((e) => e.message, 'm', 'o campo "data.pressao" não veio na resposta')));
      expect(() => HttpCodec.decode(ht('vazio'), status), throwsA(isA<TagValueError>().having((e) => e.message, 'm', contains('veio vazio'))));
      expect(() => HttpCodec.decode(ht('data'), status), throwsA(isA<TagValueError>().having((e) => e.message, 'm', contains('é um objeto'))));
      expect(() => HttpCodec.decode(ht('data.modo'), status), throwsA(isA<TagValueError>().having((e) => e.message, 'm', '"AUTO" não é número')));
      expect(() => HttpCodec.decode(ht('data.temperatura'), '<html>ok</html>'),
          throwsA(isA<TagValueError>().having((e) => e.message, 'm', 'a resposta não é JSON (esperava o campo "data.temperatura")')));
    });

    test('sem campo: a resposta inteira (ESP32 que responde só o número)', () {
      expect(HttpCodec.decode(ht(''), '25.3\n'), 25.3);
      expect(HttpCodec.decode(ht(''), '25,3'), 25.3, reason: 'vírgula de firmware brasileiro');
      expect(HttpCodec.decode(ht('', type: TagDataType.bool), 'ON'), isTrue);
      expect(HttpCodec.decode(ht('', type: TagDataType.bool), '0'), isFalse);
      expect(HttpCodec.decode(ht('', type: TagDataType.uint16, length: 3), '[1,2,3]'), [1, 2, 3]);
      expect(() => HttpCodec.decode(ht(''), status), throwsA(isA<TagValueError>().having((e) => e.message, 'm', contains('diga qual campo'))));
    });
  });

  group('expressão regular', () {
    test('grupo "valor", primeiro grupo, ou o trecho inteiro', () {
      const page = '<p>Temperatura: 25.3 C</p><p>Pressao=4,5bar</p>';
      expect(HttpCodec.decode(ht(r'Temperatura: (?<valor>-?\d+\.\d) C', extract: HttpExtract.regex), page), 25.3);
      expect(HttpCodec.decode(ht(r'Pressao=([\d,]+)bar', extract: HttpExtract.regex), page), 4.5);
      expect(HttpCodec.decode(ht(r'\d+\.\d', extract: HttpExtract.regex), page), 25.3);
    });

    test('não achou e expressão inválida', () {
      expect(() => HttpCodec.decode(ht(r'Umidade: (\d+)', extract: HttpExtract.regex), 'T=1'),
          throwsA(isA<TagValueError>().having((e) => e.message, 'm', 'a expressão regular não achou nada na resposta')));
      expect(const HttpTagAddress(extract: HttpExtract.regex, select: '(abc').problem, startsWith('expressão regular inválida'));
      expect(const HttpTagAddress(extract: HttpExtract.regex).problem, 'escreva a expressão regular');
    });
  });

  group('gravar com {valor}', () {
    test('no corpo JSON e na URL, com a escala desfeita', () {
      final t = ht('', type: TagDataType.float32, scale: 0.1, writable: true,
          address: const HttpTagAddress(path: '/api/status', writePath: '/api/setpoint', writeMethod: HttpMethod.put, writeBody: '{"setpoint": {valor}}'));
      final p = HttpCodec.writePlan(t, 75.2);
      expect((p.method, p.path, p.body), (HttpMethod.put, '/api/setpoint', '{"setpoint": 752}'));

      final g = HttpCodec.writePlan(
          ht('', type: TagDataType.uint16, writable: true, address: const HttpTagAddress(path: '/x', writeMethod: HttpMethod.get, writePath: '/set?nome=bomba 1&valor={valor}')),
          42);
      expect((g.method, g.path, g.body), (HttpMethod.get, '/set?nome=bomba 1&valor=42', null));
      final txt = HttpCodec.writePlan(ht('', type: TagDataType.float32, writable: true, address: const HttpTagAddress(path: '/x', writeMethod: HttpMethod.get, writePath: '/s?v={valor}')), 1.5);
      expect(txt.path, '/s?v=1.5', reason: 'ponto decimal, o que firmware e JSON entendem');
    });

    test('POST sem corpo escrito manda só o valor; sem caminho de gravar, usa o da leitura', () {
      final p = HttpCodec.writePlan(ht('', type: TagDataType.uint16, writable: true, address: const HttpTagAddress(path: '/api/vel')), 1500);
      expect((p.method, p.path, p.body), (HttpMethod.post, '/api/vel', '1500'));
    });

    test('liga/desliga nos três formatos e valor que não cabe', () {
      Tag b(MqttBoolFormat f) => ht('', type: TagDataType.bool, writable: true, address: HttpTagAddress(path: '/rele', writeBody: '{"ligar": {valor}}', boolFormat: f));
      expect(HttpCodec.writePlan(b(MqttBoolFormat.oneZero), true).body, '{"ligar": 1}');
      expect(HttpCodec.writePlan(b(MqttBoolFormat.trueFalse), false).body, '{"ligar": false}');
      expect(HttpCodec.writePlan(b(MqttBoolFormat.onOff), true).body, '{"ligar": ON}');
      expect(() => HttpCodec.writePlan(ht('', type: TagDataType.uint16, writable: true), 1.5),
          throwsA(isA<TagValueError>().having((e) => e.message, 'm', '"x" só aceita número inteiro')));
    });

    test('tipo do corpo pelo jeito dele', () {
      expect(HttpCodec.contentTypeFor('{"a":1}'), startsWith('application/json'));
      expect(HttpCodec.contentTypeFor('42'), startsWith('text/plain'));
    });
  });

  group('requisição', () {
    test('mesma chave = mesma requisição; corpo do GET não conta', () {
      const a = HttpTagAddress(path: '/api/status', select: 'data.temperatura');
      const b = HttpTagAddress(path: '/api/status', select: 'itens[0].valor', extract: HttpExtract.regex);
      expect(a.requestKey, b.requestKey);
      expect(const HttpTagAddress(path: '/api/status', body: 'x').requestKey, a.requestKey);
      expect(const HttpTagAddress(method: HttpMethod.post, path: '/api/status', body: '{"q":1}').requestKey, isNot(a.requestKey));
      expect(const HttpTagAddress(path: 'http://1.2.3.4/x').problem, contains('só o caminho'));
    });

    test('URL base: ler, montar e a regra do texto claro', () {
      expect(HttpConfig.parseUrl('http://192.168.0.50:8080/api/'), (host: '192.168.0.50', port: 8080, https: false, path: '/api'));
      expect(HttpConfig.parseUrl('192.168.0.50'), (host: '192.168.0.50', port: 80, https: false, path: ''));
      expect(HttpConfig.parseUrl('https://gw.local'), (host: 'gw.local', port: 443, https: true, path: ''));
      expect(HttpConfig.parseUrl('ftp://x'), isNull);
      expect(HttpConfig.parseUrl('http://:80'), isNull);
      const c = HttpConfig(basePath: '/api');
      expect(c.baseUrl('192.168.0.50', 80), 'http://192.168.0.50/api');
      expect(c.baseUrl('192.168.0.50', 8080), 'http://192.168.0.50:8080/api');
      expect(c.resolve('192.168.0.50', 80, 'status?canal=2').toString(), 'http://192.168.0.50/api/status?canal=2');
      expect(HttpConfig.cleartextProblem('192.168.0.50', https: false), isNull);
      expect(HttpConfig.cleartextProblem('10.0.2.2', https: false), isNull);
      expect(HttpConfig.cleartextProblem('esp32.local', https: false), isNull);
      expect(HttpConfig.cleartextProblem('8.8.8.8', https: false), contains('use https://'));
      expect(HttpConfig.cleartextProblem('8.8.8.8', https: true), isNull);
    });

    test('código HTTP em palavras', () {
      expect(HttpCommError.statusText(404), '404: caminho não existe');
      expect(HttpCommError.auth(401, sentCredentials: true).userMessage, '401: o equipamento recusou o usuário ou a senha');
      expect(HttpCommError.auth(401, sentCredentials: false).userMessage, '401: o equipamento pede usuário e senha');
      expect(HttpCommError.statusText(503), startsWith('503'));
    });
  });

  group('arquivo do projeto', () {
    const device = Device(
      id: 'esp',
      name: 'ESP32',
      kind: DeviceKind.http,
      host: '192.168.0.50',
      port: 80,
      http: HttpConfig(basePath: '/api', auth: HttpAuth.basic, username: 'admin', secretRef: 'hs_1', headers: [HttpHeader('X-Linha', '2')], pendingSecret: 'senha-secreta'),
    );

    test('ida e volta, sem a senha', () {
      final json = jsonEncode(device.toJson());
      expect(json, isNot(contains('senha-secreta')), reason: 'a senha digitada nunca vai para o arquivo');
      final back = Device.fromJson(jsonDecode(json) as Map<String, dynamic>);
      expect(back.kind, DeviceKind.http);
      expect(back.http, device.http, reason: 'tudo menos a senha pendente');
      expect(back.http.pendingSecret, isNull);
      expect(back.sameLinkAs(device), isTrue);

      const tag = Tag(id: 't', name: 'Temperatura', deviceId: 'esp', dataType: TagDataType.float32, http: HttpTagAddress(path: '/status', select: 'data.temperatura'));
      final t2 = Tag.fromJson(jsonDecode(jsonEncode(tag.toJson())) as Map<String, dynamic>);
      expect(t2.http, tag.http);
      expect(t2.addressLabel, 'GET /status · data.temperatura');
      expect(tag.toJson()['http'], {'path': '/status', 'select': 'data.temperatura'}, reason: 'só o que difere do padrão');
    });

    test('senha escrita à mão no arquivo é descartada; sem senha, nada além do tipo', () {
      final hand = Device.fromJson({
        'id': 'e', 'name': 'E', 'kind': 'http', 'host': '10.0.0.5', 'port': 80, 'pollMs': 100,
        'http': {'auth': 'basic', 'username': 'u', 'password': '1234', 'token': 'abc'},
      });
      expect(jsonEncode(hand.toJson()), isNot(contains('1234')));
      expect(hand.pollMs, HttpConfig.minPollMs, reason: 'nunca abaixo de 500 ms');
      const plain = Device(id: 'p', name: 'P', kind: DeviceKind.http, host: '10.0.0.6', port: 80);
      expect(plain.toJson().containsKey('http'), isFalse);
    });

    test('projeto sem HTTP fica igual; importar troca a chave do cofre', () {
      const modbus = Project(name: 'M', devices: [Device(id: 'd', name: 'CLP', host: '192.168.0.10')]);
      expect(ProjectRepository.encode(modbus), isNot(contains('http')));
      final p = Project(name: 'H', devices: const [device]);
      expect(p.deviceSecretRefs, {'hs_1'});
      final fresh = p.withFreshDeviceSecrets();
      expect(fresh.devices.single.http.secretRef, isNot('hs_1'));
      expect(fresh.devices.single.http.secretRef, startsWith('hs_'));
      expect(const Project(name: 'X', devices: [Device(id: 'p', name: 'P', kind: DeviceKind.http)]).withFreshDeviceSecrets().devices.single.http.secretRef, isNull);
    });
  });
}
