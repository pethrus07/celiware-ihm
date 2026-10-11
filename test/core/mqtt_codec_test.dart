import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/mqtt/mqtt_topic.dart';
import 'package:ihm/models/mqtt_config.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/runtime/mqtt_codec.dart';
import 'package:ihm/services/runtime/tag_codec.dart';

/// Regras puras do MQTT, sem rede: curingas, caminho no JSON, payload ⇄ valor.
void main() {
  Tag tag(TagDataType type, {String path = '', double scale = 1, double offset = 0, int length = 1, MqttBoolFormat bools = MqttBoolFormat.oneZero, bool json = false}) => Tag(
        id: 't',
        deviceId: 'd',
        name: 'Velocidade',
        dataType: type,
        scale: scale,
        offset: offset,
        length: length,
        writable: true,
        mqtt: MqttAddress(topic: 'a/b', jsonPath: path, boolFormat: bools, commandJson: json),
      );

  group('tópico', () {
    test('curingas + e # seguem a norma', () {
      expect(MqttTopic.matches('fabrica/+/temp', 'fabrica/sala1/temp'), isTrue);
      expect(MqttTopic.matches('fabrica/+/temp', 'fabrica/sala1/x/temp'), isFalse);
      expect(MqttTopic.matches('fabrica/#', 'fabrica'), isTrue, reason: '# vale nenhum nível também');
      expect(MqttTopic.matches('fabrica/#', 'fabrica/a/b/c'), isTrue);
      expect(MqttTopic.matches('#', 'qualquer/coisa'), isTrue);
      expect(MqttTopic.matches('a/+', 'a/'), isTrue, reason: 'nível vazio é nível');
      expect(MqttTopic.matches('a/b', 'a/b/c'), isFalse);
      expect(MqttTopic.matches('a/b', 'A/b'), isFalse, reason: 'maiúscula conta');
      expect(MqttTopic.matches('#', r'$SYS/broker/uptime'), isFalse, reason: r'$SYS não entra no "ouvir tudo"');
      expect(MqttTopic.matches(r'$SYS/#', r'$SYS/broker/uptime'), isTrue);
    });

    test('filtro e tópico de publicação válidos', () {
      for (final ok in ['a', 'a/b', '#', 'a/#', '+/b', '+', '/a']) {
        expect(MqttTopic.isValidFilter(ok), isTrue, reason: ok);
      }
      for (final bad in ['', 'a/#/b', 'a#', 'a/b+', '#/a']) {
        expect(MqttTopic.isValidFilter(bad), isFalse, reason: bad);
      }
      expect(MqttTopic.isValidTopic('a/b/set'), isTrue);
      expect(MqttTopic.isValidTopic('a/+/set'), isFalse);
      expect(MqttTopic.isValidTopic(''), isFalse);
    });
  });

  group('leitura', () {
    test('número, vírgula brasileira, escala e inteiro que veio com .0', () {
      expect(MqttCodec.decode(tag(TagDataType.float32), '72.5'), 72.5);
      expect(MqttCodec.decode(tag(TagDataType.float32), ' 23,5 '), 23.5);
      expect(MqttCodec.decode(tag(TagDataType.uint16), '23.0'), 23);
      expect(MqttCodec.decode(tag(TagDataType.uint16, scale: 0.1), '752'), closeTo(75.2, 1e-9));
      expect(MqttCodec.decode(tag(TagDataType.int16, scale: 0.01, offset: -40), '6500'), closeTo(25, 1e-9));
      expect(() => MqttCodec.decode(tag(TagDataType.uint16), 'abc'), throwsA(isA<TagValueError>()));
      expect(() => MqttCodec.decode(tag(TagDataType.uint16), ''), throwsA(isA<TagValueError>()));
    });

    test('liga/desliga aceita as convenções de mercado', () {
      final b = tag(TagDataType.bool);
      for (final on in ['true', '1', 'ON', 'on', 'Ligado', '5']) {
        expect(MqttCodec.decode(b, on), isTrue, reason: on);
      }
      for (final off in ['false', '0', 'OFF', 'desligado', '0.0']) {
        expect(MqttCodec.decode(b, off), isFalse, reason: off);
      }
      expect(() => MqttCodec.decode(b, 'talvez'), throwsA(isA<TagValueError>()));
    });

    test('texto vem como chegou; string JSON perde as aspas', () {
      expect(MqttCodec.decode(tag(TagDataType.string), 'Rótulo 330 ml  '), 'Rótulo 330 ml');
      expect(MqttCodec.decode(tag(TagDataType.string), '"Lote 12"'), 'Lote 12');
      expect(MqttCodec.decode(tag(TagDataType.string), '{"a":1}'), '{"a":1}');
      expect(MqttCodec.decode(tag(TagDataType.string), ''), '');
    });

    test('JSON com caminho: objeto, posição de lista e campo que não veio', () {
      const msg = '{"sensores": {"temp": 72.5, "porta": true}, "valores": [10, 20, 30], "nome": "C1"}';
      expect(MqttCodec.decode(tag(TagDataType.float32, path: 'sensores.temp'), msg), 72.5);
      expect(MqttCodec.decode(tag(TagDataType.bool, path: 'sensores.porta'), msg), isTrue);
      expect(MqttCodec.decode(tag(TagDataType.uint16, path: 'valores[1]'), msg), 20);
      expect(MqttCodec.decode(tag(TagDataType.uint16, path: 'valores.2'), msg), 30);
      expect(MqttCodec.decode(tag(TagDataType.string, path: 'nome'), msg), 'C1');
      expect(MqttCodec.decode(tag(TagDataType.uint16, path: 'valores', length: 3), msg), [10, 20, 30]);
      expect(
        () => MqttCodec.decode(tag(TagDataType.float32, path: 'sensores.umidade'), msg),
        throwsA(isA<TagValueError>().having((e) => e.message, 'mensagem', contains('sensores.umidade'))),
      );
      expect(() => MqttCodec.decode(tag(TagDataType.float32, path: 'temp'), '72.5'), throwsA(isA<TagValueError>()));
      // JSON sem campo escolhido: diz o que falta em vez de "não é número".
      expect(
        () => MqttCodec.decode(tag(TagDataType.float32), msg),
        throwsA(isA<TagValueError>().having((e) => e.message, 'mensagem', contains('qual campo'))),
      );
    });

    test('campos de uma mensagem para o "ouvir o broker"', () {
      final f = MqttCodec.fields('{"temp": 72.5, "porta": true, "producao": [10, 12], "eixos": [{"rpm": 900}]}');
      expect(f.map((e) => e.$1), ['temp', 'porta', 'producao', 'eixos.0.rpm']);
      expect(MqttCodec.fields('72.5'), isEmpty);
      expect(MqttCodec.guessType(72.5), TagDataType.float32);
      expect(MqttCodec.guessType(900), TagDataType.uint16);
      expect(MqttCodec.guessType(true), TagDataType.bool);
      expect(MqttCodec.guessType('OFF'), TagDataType.bool);
      expect(MqttCodec.guessType('23,5'), TagDataType.string);
      expect(MqttCodec.guessType('23.5'), TagDataType.float32);
      expect(MqttCodec.guessType('C1'), TagDataType.string);
    });
  });

  group('gravação', () {
    test('liga/desliga no formato escolhido', () {
      expect(MqttCodec.encode(tag(TagDataType.bool), true), '1');
      expect(MqttCodec.encode(tag(TagDataType.bool), false), '0');
      expect(MqttCodec.encode(tag(TagDataType.bool, bools: MqttBoolFormat.trueFalse), true), 'true');
      expect(MqttCodec.encode(tag(TagDataType.bool, bools: MqttBoolFormat.onOff), false), 'OFF');
    });

    test('número desfaz a escala; inteiro recusa passo quebrado', () {
      expect(MqttCodec.encode(tag(TagDataType.uint16), 180), '180');
      expect(MqttCodec.encode(tag(TagDataType.uint16, scale: 0.1), 75.2), '752');
      expect(MqttCodec.encode(tag(TagDataType.float32), 23.5), '23.5');
      expect(MqttCodec.encode(tag(TagDataType.float32), 24.0), '24');
      expect(
        () => MqttCodec.encode(tag(TagDataType.uint16, scale: 0.1), 75.25),
        throwsA(isA<TagValueError>().having((e) => e.message, 'mensagem', contains('0,1'))),
      );
      expect(() => MqttCodec.encode(tag(TagDataType.uint16), 'abc'), throwsA(isA<TagValueError>()));
      expect(() => MqttCodec.encode(tag(TagDataType.string), 'x'), throwsA(isA<TagValueError>()));
    });

    test('comando em JSON com o campo da variável', () {
      expect(MqttCodec.encode(tag(TagDataType.uint16, path: 'velocidade', json: true), 180), '{"velocidade":180}');
      expect(MqttCodec.encode(tag(TagDataType.bool, path: 'estado.liga', json: true, bools: MqttBoolFormat.onOff), true), '{"estado":{"liga":"ON"}}');
      expect(MqttCodec.encode(tag(TagDataType.bool, path: 'liga', json: true, bools: MqttBoolFormat.trueFalse), true), '{"liga":true}');
      // Sem a opção, o valor vai puro mesmo com caminho de leitura.
      expect(MqttCodec.encode(tag(TagDataType.uint16, path: 'velocidade'), 180), '180');
    });
  });
}
