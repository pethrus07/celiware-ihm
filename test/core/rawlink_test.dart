import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/link/byte_link.dart';
import 'package:ihm/core/rawlink/fake_arduino_server.dart';
import 'package:ihm/core/rawlink/message_parser.dart';
import 'package:ihm/core/rawlink/message_profile.dart';
import 'package:ihm/core/rawlink/raw_client.dart';
import 'package:ihm/core/rawlink/raw_link_error.dart';

/// Bytes de um texto com escapes do Dart (`'\x02T=1\x03'`): um caractere, um byte.
List<int> b(String s) => s.codeUnits;

List<Map<String, Object>> fieldsOf(List<RawFrame> frames) => [for (final f in frames) f.fields];

/// Espera uma condição de rede acontecer (com prazo, para o teste não travar).
Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 3)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) fail('a condição não aconteceu em ${timeout.inMilliseconds} ms');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('delimitação', () {
    test('fim de linha: \\n e \\r\\n; linha em branco não é mensagem', () {
      final parser = MessageParser(const MessageProfile());
      final f = parser.add(b('T=25.3;P=1\n\r\nT=26;P=0\r\n'));
      expect(fieldsOf(f), [
        {'T': 25.3, 'P': 1},
        {'T': 26, 'P': 0},
      ]);
      expect(f.every((x) => x.ok), isTrue);
      expect(f[1].preview, r'T=26;P=0\r\n');
    });

    test('fim de linha configurável, inclusive de dois bytes partido no meio', () {
      final cr = MessageParser(const MessageProfile(framing: LineFraming(end: '\r'), fields: CsvFields()));
      expect(fieldsOf(cr.add(b('1,2\r3,4\r'))), [
        {'1': 1, '2': 2},
        {'1': 3, '2': 4},
      ]);
      final duplo = MessageParser(const MessageProfile(framing: LineFraming(end: '<>')));
      expect(duplo.add(b('A=1<')), isEmpty);
      expect(fieldsOf(duplo.add(b('>B=2<>'))), [
        {'A': 1},
        {'B': 2},
      ]);
    });

    test('mensagem partida byte a byte e várias grudadas numa leitura', () {
      final parser = MessageParser(const MessageProfile());
      final all = <RawFrame>[];
      for (final c in b('T=25.3;P=1\n')) {
        all.addAll(parser.add([c]));
      }
      expect(all.single.fields, {'T': 25.3, 'P': 1});
      expect(parser.buffered, 0);

      final grudadas = parser.add(b('T=1\nT=2\nT=3\nT=4'));
      expect(grudadas.map((f) => f.fields['T']), [1, 2, 3]);
      expect(parser.buffered, 3); // "T=4" esperando o fim
      expect(parser.add(b('\n')).single.fields, {'T': 4});
    });

    test('fim do pacote UDP fecha a mensagem sem fim de linha', () {
      final parser = MessageParser(const MessageProfile());
      expect(parser.add(b('T=1')), isEmpty);
      expect(parser.endOfPacket().single.fields, {'T': 1});
      expect(parser.buffered, 0);
      expect(parser.add(b('T=2\n')).single.fields, {'T': 2});
      expect(parser.endOfPacket(), isEmpty); // com \n, o fim do pacote não duplica
    });

    test('início/fim: lixo antes sai; novo início antes do fim descarta a incompleta', () {
      final parser = MessageParser(const MessageProfile(framing: StartEndFraming(start: '<', end: '>')));
      final f = parser.add(b('lixo<T=1>xx<T=2<T=3;P=1>'));
      expect(f.map((x) => x.problem), [null, FrameProblem.incomplete, null]);
      expect(f[0].fields, {'T': 1});
      expect(f[2].fields, {'T': 3, 'P': 1});
      expect(parser.discardedBytes, 4 + 2 + 4); // "lixo", "xx", "<T=2"

      final stx = MessageParser(const MessageProfile(framing: StartEndFraming()));
      expect(stx.add(b('\x02T=')), isEmpty);
      expect(stx.add(b('5\x03')).single.fields, {'T': 5});
    });

    test('tamanho fixo com cabeçalho: lixo antes, pacote partido, ressincroniza depois de um byte perdido', () {
      List<int> pacote(int raw16, int p) {
        final body = [0xAA, 0x55, (raw16 >> 8) & 0xFF, raw16 & 0xFF, p];
        return [...body, (body[2] + body[3] + body[4]) & 0xFF];
      }

      final parser = MessageParser(const MessageProfile(
        framing: FixedLengthFraming(length: 6, header: '\xAA\x55'),
        checksum: ChecksumSpec(kind: ChecksumKind.sum8, skipStart: 2),
        fields: BinaryFields([
          BinaryField(key: 't', offset: 2, type: RawType.i16),
          BinaryField(key: 'p', offset: 4, type: RawType.u8),
        ]),
      ));
      final a = pacote(0xFF85, 1); // -123
      expect(parser.add([0x00, 0x13, ...a.sublist(0, 3)]), isEmpty);
      expect(fieldsOf(parser.add([...a.sublist(3), ...pacote(250, 0)])), [
        {'t': -123, 'p': 1},
        {'t': 250, 'p': 0},
      ]);
      expect(parser.discardedBytes, 2);

      final cortado = pacote(10, 1)..removeAt(3);
      final r = parser.add([...cortado, ...pacote(20, 1)]);
      expect(r.first.problem, FrameProblem.checksum);
      expect(r.last.fields, {'t': 20, 'p': 1});
      expect(r.where((f) => !f.ok).length, 1, reason: 'uma falha por episódio, não uma por byte');
    });

    test('tamanho fixo sem cabeçalho', () {
      final parser = MessageParser(const MessageProfile(
        framing: FixedLengthFraming(length: 4),
        fields: BinaryFields([BinaryField(key: 'v', offset: 0, type: RawType.u32)]),
      ));
      expect(parser.add([0, 0, 1, 0, 0, 0]).single.fields, {'v': 256});
      expect(parser.buffered, 2);
    });

    group('prefixo de tamanho', () {
      const profile = MessageProfile(
        framing: LengthPrefixFraming(header: '\x7E', adjust: 2), // o tamanho conta só os dados; +2 do CRC
        checksum: ChecksumSpec(kind: ChecksumKind.crc16),
        fields: BinaryFields([
          BinaryField(key: 'a', offset: 2),
          BinaryField(key: 'b', offset: 4, type: RawType.f32, order: RawByteOrder.dcba),
        ]),
      );
      List<int> pkt(List<int> payload) {
        final body = [0x7E, payload.length, ...payload];
        final crc = profile.checksum.compute(body);
        return [...body, crc & 0xFF, crc >> 8];
      }

      final um = pkt([0x01, 0x2C, 0x00, 0x00, 0xCC, 0x41]); // 300 e 25,5 (little-endian)
      final dois = pkt([0x00, 0x07, 0x00, 0x00, 0x80, 0xBF]); // 7 e -1,0

      test('partido em pedaços de 3 bytes e grudado', () {
        final parser = MessageParser(profile);
        final out = <RawFrame>[];
        for (var i = 0; i < um.length; i += 3) {
          out.addAll(parser.add(um.sublist(i, math.min(i + 3, um.length))));
        }
        out.addAll(parser.add([...dois, ...um]));
        expect(out.map((f) => f.fields['a']), [300, 7, 300]);
        expect(out[0].fields['b'], 25.5);
        expect(out[1].fields['b'], -1.0);
      });

      test('CRC errado e tamanho impossível ressincronizam', () {
        final parser = MessageParser(profile.copyWith(maxFrameBytes: 64));
        final ruim = [...um]..[3] ^= 0xFF;
        final r = parser.add([...ruim, ...dois]);
        expect(r.first.problem, FrameProblem.checksum);
        expect(r.last.fields['a'], 7);

        final r2 = parser.add([0x7E, 200, 1, 2, ...um]);
        expect(r2.first.problem, FrameProblem.tooLong);
        expect(r2.last.fields['a'], 300);
      });

      test('pacote curto: campo que passa do fim fica ausente', () {
        final parser = MessageParser(const MessageProfile(
          framing: LengthPrefixFraming(),
          fields: BinaryFields([BinaryField(key: 'a', offset: 1, type: RawType.u8), BinaryField(key: 'b', offset: 3)]),
        ));
        expect(parser.add([2, 0x05, 0x06]).single.fields, {'a': 5});
      });
    });

    test('mensagem gigante: memória limitada, um aviso só, e o rabo dela não vira mensagem', () {
      final parser = MessageParser(const MessageProfile(maxFrameBytes: 64));
      final r = parser.add(List.filled(5000, 0x41)); // "AAAA…" sem fim de linha
      expect(r.single.problem, FrameProblem.tooLong);
      expect(r.single.bytes.length, 64);
      expect(parser.buffered, 0);
      expect(fieldsOf(parser.add(b('AAAA=1\nT=7\n'))), [
        {'T': 7},
      ]);
      expect(parser.discardedBytes, 5000 + 7);

      var avisos = 0;
      for (var i = 0; i < 100; i++) {
        avisos += parser.add(List.filled(100, 0x42)).length;
        expect(parser.buffered, lessThanOrEqualTo(64));
      }
      expect(avisos, 1);

      final numaLeitura = MessageParser(const MessageProfile(maxFrameBytes: 64)).add([...List.filled(100, 0x43), 0x0A, ...b('T=1\n')]);
      expect(numaLeitura.map((f) => f.problem), [FrameProblem.tooLong, null]);

      final se = MessageParser(const MessageProfile(framing: StartEndFraming(start: '<', end: '>'), maxFrameBytes: 32));
      final r3 = se.add([...b('<'), ...List.filled(100, 0x41), ...b('><T=1>')]);
      expect(r3.map((f) => f.problem), [FrameProblem.tooLong, null]);
      expect(r3.last.fields, {'T': 1});
      expect(se.buffered, 0);
    });
  });

  group('checksum', () {
    test('vetores conhecidos: CRC16 Modbus, XOR do NMEA, soma 8 bits', () {
      const crc = ChecksumSpec(kind: ChecksumKind.crc16);
      expect(crc.compute([0x01, 0x03, 0x00, 0x00, 0x00, 0x0A]), 0xCDC5);
      expect(crc.encodeValue(0xCDC5), [0xC5, 0xCD]);
      expect(const ChecksumSpec(kind: ChecksumKind.crc16, lowByteFirst: false).encodeValue(0xCDC5), [0xCD, 0xC5]);
      expect(const ChecksumSpec(kind: ChecksumKind.xor).compute(b('GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,')), 0x47);
      expect(const ChecksumSpec(kind: ChecksumKind.sum8).compute([0x10, 0x20, 0xF0]), 0x20);
      expect(const ChecksumSpec(kind: ChecksumKind.xor, encoding: ChecksumEncoding.hex).encodeValue(0x0A), b('0A'));
    });

    test('XOR em hexadecimal depois do "*", sem o "\$" (NMEA): certo, errado e ausente', () {
      final parser = MessageParser(const MessageProfile(
        fields: CsvFields(names: ['tipo', 'hora']),
        checksum: ChecksumSpec(kind: ChecksumKind.xor, encoding: ChecksumEncoding.hex, separator: '*', skipStart: 1),
      ));
      const gga = r'$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47';
      final ok = parser.add(b('$gga\r\n')).single;
      expect(ok.ok, isTrue);
      expect(ok.fields['tipo'], r'$GPGGA');
      expect(ok.fields['hora'], 123519);
      expect(ok.fields['3'], 4807.038);
      expect(ok.fields.containsKey('14'), isFalse, reason: 'campo vazio não vira valor');

      final errado = parser.add(b('${gga.replaceFirst('*47', '*48')}\n')).single;
      expect(errado.problem, FrameProblem.checksum);
      expect(errado.fields, isEmpty);
      expect(parser.add(b('\$GPGGA,1\n')).single.problem, FrameProblem.checksum);
    });

    test('CRC16 em hexadecimal, maiúsculas ou minúsculas', () {
      const cs = ChecksumSpec(kind: ChecksumKind.crc16, encoding: ChecksumEncoding.hex, separator: '|');
      final crc = cs.compute(b('T=25')).toRadixString(16).toUpperCase().padLeft(4, '0');
      final parser = MessageParser(const MessageProfile(checksum: cs));
      expect(parser.add(b('T=25|$crc\n')).single.fields, {'T': 25});
      expect(parser.add(b('T=26|$crc\n')).single.problem, FrameProblem.checksum);
      expect(parser.add(b('T=25|${crc.toLowerCase()}\n')).single.ok, isTrue);
    });

    test('BCC depois do ETX (balança): chega partido, confere e recusa o errado', () {
      final parser = MessageParser(const MessageProfile(
        framing: StartEndFraming(),
        checksum: ChecksumSpec(kind: ChecksumKind.xor, afterEnd: true),
        fields: RegexFields(r'(?<peso>[+-]?\d+\.\d+)kg'),
      ));
      List<int> msg(String body) {
        final cover = [...b(body), 0x03];
        return [0x02, ...cover, cover.fold<int>(0, (a, c) => a ^ c)];
      }

      final boa = msg('ST,GS,+012.345kg');
      expect(parser.add(boa.sublist(0, boa.length - 1)), isEmpty, reason: 'falta o BCC');
      expect(parser.add([boa.last]).single.fields, {'peso': 12.345});
      final ruim = [...boa]..[boa.length - 1] ^= 0x01;
      expect(parser.add(ruim).single.problem, FrameProblem.checksum);
    });
  });

  group('campos', () {
    test('chave=valor com separadores configuráveis; vazio e sem chave ficam de fora', () {
      final parser = MessageParser(const MessageProfile(fields: KeyValueFields(pairSeparator: ',', assign: ':')));
      expect(parser.add(b('T: 25.3, P:1 , S:OK, V:, :9, X\n')).single.fields, {'T': 25.3, 'P': 1, 'S': 'OK'});
      expect(parser.add(b('OK\n')).single.problem, FrameProblem.noFields);
    });

    test('CSV por posição: nome, posição sem nome, aspas com separador dentro', () {
      final parser = MessageParser(const MessageProfile(fields: CsvFields(names: ['temp', '', 'status'])));
      expect(parser.add(b('25.3,1,"OK, pronto",-4\n')).single.fields, {'temp': 25.3, '2': 1, 'status': 'OK, pronto', '4': -4});
      final pv = MessageParser(const MessageProfile(fields: CsvFields(separator: ';')));
      expect(pv.add(b('"diz ""oi""";2\n')).single.fields, {'1': 'diz "oi"', '2': 2});
      expect(MessageParser.splitCsv('a,"b",c', ',', ''), ['a', '"b"', 'c']);
    });

    test('regex com grupos nomeados e por posição', () {
      final nomeada = MessageParser(const MessageProfile(fields: RegexFields(r'^(?<estado>ST|US),GS,(?<peso>[+-]?[\d.]+)kg$')));
      expect(nomeada.add(b('ST,GS,+012.345kg\r\n')).single.fields, {'estado': 'ST', 'peso': 12.345});
      expect(nomeada.add(b('lixo\n')).single.problem, FrameProblem.noFields);
      final posicao = MessageParser(const MessageProfile(fields: RegexFields(r'(\d+)/(\d+)')));
      expect(posicao.add(b('pos 3/40\n')).single.fields, {'1': 3, '2': 40});
    });

    test('binário: tipos e as quatro ordens de bytes', () {
      final parser = MessageParser(const MessageProfile(
        framing: FixedLengthFraming(length: 21),
        fields: BinaryFields([
          BinaryField(key: 'u8', offset: 0, type: RawType.u8),
          BinaryField(key: 'i8', offset: 0, type: RawType.i8),
          BinaryField(key: 'u16', offset: 1),
          BinaryField(key: 'u16le', offset: 1, order: RawByteOrder.dcba),
          BinaryField(key: 'i16', offset: 3, type: RawType.i16),
          BinaryField(key: 'u32', offset: 5, type: RawType.u32, order: RawByteOrder.cdab),
          BinaryField(key: 'i32', offset: 9, type: RawType.i32, order: RawByteOrder.badc),
          BinaryField(key: 'f', offset: 13, type: RawType.f32),
          BinaryField(key: 'fle', offset: 17, type: RawType.f32, order: RawByteOrder.dcba),
        ]),
      ));
      final pacote = [
        0xF0, //                        u8 240 / i8 -16
        0x12, 0x34, //                  u16 0x1234
        0xFF, 0xFE, //                  i16 -2
        0x33, 0x44, 0x11, 0x22, //      u32 0x11223344 em CDAB
        0xFF, 0xFF, 0x18, 0xFC, //      i32 -1000 em BADC
        0x41, 0xCC, 0x00, 0x00, //      f32 25,5 em ABCD
        0x00, 0x00, 0x80, 0xBF, //      f32 -1,0 em DCBA (o do Arduino)
      ];
      expect(parser.add(pacote).single.fields, {
        'u8': 240,
        'i8': -16,
        'u16': 0x1234,
        'u16le': 0x3412,
        'i16': -2,
        'u32': 0x11223344,
        'i32': -1000,
        'f': 25.5,
        'fle': -1.0,
      });
    });

    test('número quando o texto inteiro é número; senão, texto', () {
      expect(MessageParser.toValue('25.3'), 25.3);
      expect(MessageParser.toValue(' 12 '), 12);
      expect(MessageParser.toValue('-7'), -7);
      expect(MessageParser.toValue('+5'), 5);
      expect(MessageParser.toValue('.5'), 0.5);
      expect(MessageParser.toValue('1e3'), 1000.0);
      expect(MessageParser.toValue('007'), 7);
      expect(MessageParser.toValue('99999999999999999999'), isA<double>());
      for (final t in ['OK', 'nan', '25.3C', '0x1F', '1.2.3', '25,3']) {
        expect(MessageParser.toValue(t), t);
      }
      expect(MessageParser.toValue('25,3', decimalComma: true), 25.3);
    });

    test('ruído grudado na ponta (placa ligando) sai; separador de controle no meio fica', () {
      final parser = MessageParser(const MessageProfile());
      expect(parser.add([0x00, 0xFF, 0xFE, ...b('T=25.3;P=1\n')]).single.fields, {'T': 25.3, 'P': 1});
      final rs = MessageParser(const MessageProfile(fields: KeyValueFields(pairSeparator: '\x1E')));
      expect(rs.add(b('T=1\x1EP=2\n')).single.fields, {'T': 1, 'P': 2});
    });

    test('acentos: UTF-8 (padrão) e Latin-1', () {
      expect(MessageParser(const MessageProfile()).add([...b('U='), 0xC2, 0xB0, ...b('C\n')]).single.fields, {'U': '°C'});
      expect(MessageParser(const MessageProfile(charset: RawCharset.latin1)).add([...b('U='), 0xB0, ...b('C\n')]).single.fields, {'U': '°C'});
    });
  });

  group('comandos', () {
    test('texto: campo, valor, casas, verdadeiro/falso, marcador livre, chave que não é marcador', () {
      final parser = MessageParser(const MessageProfile());
      const modelo = CommandTemplate.text('SET {campo}={valor}\n');
      String cmd(CommandTemplate t, {String? field, Object? value, Map<String, Object?> args = const {}}) =>
          String.fromCharCodes(parser.buildCommand(t, field: field, value: value, args: args));

      expect(cmd(modelo, field: 'P', value: 50), 'SET P=50\n');
      expect(cmd(modelo, field: 'P', value: 50.0), 'SET P=50\n');
      expect(cmd(modelo, field: 'SP', value: 25.5), 'SET SP=25.5\n');
      expect(cmd(modelo, field: 'R', value: true), 'SET R=1\n');
      expect(cmd(const CommandTemplate.text('SP{canal}:{valor:2}\r'), value: 7, args: {'canal': 3}), 'SP3:7.00\r');
      expect(cmd(const CommandTemplate.text('{"p":{valor}}'), value: 1), '{"p":1}');

      final br = MessageParser(const MessageProfile(decimalComma: true));
      expect(String.fromCharCodes(br.buildCommand(modelo, field: 'P', value: 25.5)), 'SET P=25,5\n');

      expect(() => parser.buildCommand(modelo, field: 'P'), throwsA(isA<RawCommandError>()));
      expect(() => parser.buildCommand(modelo, value: 1), throwsA(isA<RawCommandError>()));
      expect(() => parser.buildCommand(const CommandTemplate.text('X{valor:u16}'), value: 1), throwsA(isA<RawCommandError>()));
      expect(() => parser.buildCommand(const CommandTemplate.text('  ')), throwsA(isA<RawCommandError>()));
    });

    test('texto com {cs} no estilo NMEA: o equipamento confere com a mesma regra', () {
      final parser = MessageParser(const MessageProfile(
        fields: CsvFields(),
        checksum: ChecksumSpec(kind: ChecksumKind.xor, encoding: ChecksumEncoding.hex, separator: '*', skipStart: 1),
      ));
      final bytes = parser.buildCommand(const CommandTemplate.text('\$SET,P,{valor}*{cs}\r\n'), value: 1);
      final x = b('SET,P,1').fold<int>(0, (a, c) => a ^ c);
      expect(String.fromCharCodes(bytes), '\$SET,P,1*${x.toRadixString(16).toUpperCase().padLeft(2, '0')}\r\n');
      expect(parser.add(bytes).single.fields, {'1': r'$SET', '2': 'P', '3': 1});
    });

    test('binário: hexadecimal, tipo, ordem, checksum; valor que não cabe não sai', () {
      final parser = MessageParser(const MessageProfile(checksum: ChecksumSpec(kind: ChecksumKind.sum8, skipStart: 1)));
      expect(parser.buildCommand(const CommandTemplate.binary('AA 01 {valor:u16} {cs}'), value: 300), [0xAA, 0x01, 0x01, 0x2C, 0x2E]);
      expect(parser.buildCommand(const CommandTemplate.binary('AA55 {valor:i16}', order: RawByteOrder.dcba), value: -2), [0xAA, 0x55, 0xFE, 0xFF]);
      expect(parser.buildCommand(const CommandTemplate.binary('{valor:f32}'), value: 25.5), [0x41, 0xCC, 0x00, 0x00]);
      expect(
        parser.buildCommand(const CommandTemplate.binary('{valor:u32} {x:u8}', order: RawByteOrder.cdab), value: 0x11223344, args: {'x': 7}),
        [0x33, 0x44, 0x11, 0x22, 7],
      );
      expect(
        () => parser.buildCommand(const CommandTemplate.binary('{valor:u8}'), value: 300),
        throwsA(isA<RawCommandError>().having((e) => e.userMessage, 'mensagem', contains('não cabe em u8'))),
      );
      expect(() => parser.buildCommand(const CommandTemplate.binary('ZZ'), value: 1), throwsA(isA<RawCommandError>()));
      expect(() => parser.buildCommand(const CommandTemplate.binary('{valor}'), value: 1), throwsA(isA<RawCommandError>()));
      expect(() => MessageParser(const MessageProfile()).buildCommand(const CommandTemplate.binary('01 {cs}')), throwsA(isA<RawCommandError>()));
    });

    test('qual modelo grava cada campo', () {
      const profile = MessageProfile(commands: [
        CommandTemplate.text('Z\r\n', name: 'Zerar'),
        CommandTemplate.text('SET {campo}={valor}\n'),
        CommandTemplate.text('SP={valor}\n', field: 'SP'),
      ]);
      expect(profile.commandFor('SP')!.template, 'SP={valor}\n');
      expect(profile.commandFor('P')!.template, 'SET {campo}={valor}\n');
      expect(profile.commandNamed('Zerar')!.template, 'Z\r\n');
      expect(const MessageProfile(commands: [CommandTemplate.text('Z\r\n')]).commandFor('P'), isNull,
          reason: 'comando sem valor não serve para gravar variável');
    });
  });

  group('perfil', () {
    final perfis = <MessageProfile>[
      const MessageProfile(),
      const MessageProfile(
        framing: LineFraming(end: '\r', trimCr: false),
        fields: CsvFields(separator: ';', quote: '', names: ['a', 'b']),
        decimalComma: true,
        charset: RawCharset.latin1,
      ),
      const MessageProfile(
        framing: StartEndFraming(),
        checksum: ChecksumSpec(kind: ChecksumKind.xor, afterEnd: true),
        fields: RegexFields(r'(?<peso>[\d.]+)kg'),
      ),
      const MessageProfile(
        framing: FixedLengthFraming(length: 6, header: '\xAA\x55'),
        checksum: ChecksumSpec(kind: ChecksumKind.sum8, skipStart: 2),
        fields: BinaryFields([BinaryField(key: 't', offset: 2, type: RawType.i16, order: RawByteOrder.dcba)]),
      ),
      const MessageProfile(
        framing: LengthPrefixFraming(header: '\x7E', lengthBytes: 2, bigEndian: false, adjust: 2),
        checksum: ChecksumSpec(kind: ChecksumKind.crc16, lowByteFirst: false),
        fields: BinaryFields([BinaryField(key: 'a', offset: 3, type: RawType.f32)]),
        maxFrameBytes: 512,
      ),
      const MessageProfile(
        mode: RawMode.polling,
        pollRequest: CommandTemplate.text('?\r\n'),
        pollMs: 250,
        staleAfterMs: 3000,
        checksum: ChecksumSpec(kind: ChecksumKind.crc16, encoding: ChecksumEncoding.hex, separator: '*', skipStart: 1),
        commands: [
          CommandTemplate.text('SET {campo}={valor}\n'),
          CommandTemplate.binary('AA {valor:u16} {cs}', name: 'bin', field: 'P', order: RawByteOrder.cdab),
        ],
      ),
    ];

    test('JSON ida e volta de cada tipo, com a mesma interpretação', () {
      for (final p in perfis) {
        final json = jsonEncode(p.toJson());
        final volta = MessageProfile.fromJson(jsonDecode(json) as Map<String, dynamic>);
        expect(jsonEncode(volta.toJson()), json);
      }
      // A notação no arquivo é a que o editor mostra.
      expect((perfis[3].toJson()['framing'] as Map)['header'], r'\xAAU'); // 0x55 é o "U" imprimível
      expect((perfis[0].toJson()['framing'] as Map)['end'], r'\n');
      expect((perfis[5].toJson()['commands'] as List).first, {'text': r'SET {campo}={valor}\n'});

      final pacote = [0xAA, 0x55, 0x85, 0xFF, 0x00, 0x84];
      final volta = MessageProfile.fromJson(jsonDecode(jsonEncode(perfis[3].toJson())) as Map<String, dynamic>);
      expect(MessageParser(volta).add(pacote).single.fields, MessageParser(perfis[3]).add(pacote).single.fields);
      expect(MessageParser(volta).add(pacote).single.fields, {'t': -123});
    });

    test('arquivo incompleto ou de versão futura abre com os padrões', () {
      final p = MessageProfile.fromJson({
        'framing': {'type': 'inventado'},
        'fields': 7,
        'mode': 'telepatia',
        'checksum': {'kind': 'md5'},
      });
      expect(p.framing, isA<LineFraming>());
      expect(p.fields, isA<KeyValueFields>());
      expect(p.mode, RawMode.streaming);
      expect(p.checksum.enabled, isFalse);
      expect(MessageParser(p).add(b('T=1\n')).single.fields, {'T': 1});
    });

    test('notação de bytes: ida e volta exata, contrabarra solta preservada', () {
      const texto = 'a\\b\n\r\t\x00\x02\x7F\xAA\xFFçé€';
      expect(ByteEscapes.decode(ByteEscapes.encode(texto)), texto);
      expect(ByteEscapes.encode('\r\n\x02'), r'\r\n\x02');
      expect(ByteEscapes.decode(r'\q \x4 fim\'), r'\q \x4 fim\');
      expect(ByteEscapes.decode(r'\xaa\x55'), '\xAA\x55');
    });

    test('perfil que não fecha vira RawProfileError antes de qualquer byte', () {
      expect(const MessageProfile().problems(), isEmpty);
      for (final ruim in const [
        MessageProfile(fields: RegexFields('(?<a>')),
        MessageProfile(framing: FixedLengthFraming(length: 4, header: '\xAA\x55\x01\x02')),
        MessageProfile(framing: LineFraming(end: '')),
        MessageProfile(checksum: ChecksumSpec(kind: ChecksumKind.xor, afterEnd: true)),
        MessageProfile(mode: RawMode.polling, pollRequest: CommandTemplate.text('?{cs}\n')),
        MessageProfile(fields: CsvFields(), decimalComma: true),
        MessageProfile(framing: FixedLengthFraming(length: 4), fields: BinaryFields([BinaryField(key: 'x', offset: 2, type: RawType.u32)])),
      ]) {
        expect(() => MessageParser(ruim), throwsA(isA<RawProfileError>()), reason: '${ruim.toJson()}');
      }
    });
  });

  group('cliente por TCP (Arduino falso)', () {
    late FakeArduinoServer server;
    RawClient? client;

    Future<RawClient> liga(MessageProfile profile, {Duration responseTimeout = const Duration(seconds: 1)}) async {
      final c = RawClient(link: TcpByteLink(host: '127.0.0.1', port: server.port), profile: profile, responseTimeout: responseTimeout);
      client = c;
      await c.connect();
      return c;
    }

    tearDown(() async {
      await client?.dispose();
      client = null;
      await server.stop();
    });

    test('streaming: valor mais recente com horário; meia mensagem e lixo pelo socket; perfil trocado ao vivo', () async {
      server = FakeArduinoServer(streamEvery: const Duration(milliseconds: 30));
      await server.start();
      final antes = DateTime.now();
      final c = await liga(const MessageProfile());
      final ruins = <RawFrame>[];
      c.frames.where((f) => !f.ok).listen(ruins.add);

      await until(() => c.valueOf('T') != null);
      expect(c.valueOf('T')!.value, 25.3);
      expect(c.valueOf('P')!.value, 1);
      expect(c.valueOf('T')!.at.isBefore(antes), isFalse);
      server.values['T'] = 31.5;
      await until(() => c.valueOf('T')!.value == 31.5);

      server.silent = true; // só os bytes do teste, sem a transmissão no meio
      server.sendRaw(b('\x00\xFFlixo\nT=4'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      server.sendRaw(b('0.5;P=0\n'));
      await until(() => c.valueOf('T')!.value == 40.5);
      expect(c.valueOf('P')!.value, 0);
      expect(ruins.single.problem, FrameProblem.noFields);

      c.profile = const MessageProfile(fields: RegexFields(r'T=(?<temp>[\d.]+)'));
      server.sendRaw(b('T=12.5;P=1\n'));
      await until(() => c.valueOf('temp')?.value == 12.5);
    });

    test('polling: pede a cada pollMs e poll() espera a resposta', () async {
      server = FakeArduinoServer(); // só responde quando pedem
      await server.start();
      final c = await liga(const MessageProfile(mode: RawMode.polling, pollMs: 40));
      await until(() => server.received.where((l) => l == '?').length >= 3);
      expect(c.valueOf('T')!.value, 25.3);
      server.values['P'] = 0;
      // Sem número de pedido no protocolo, uma resposta automática já a caminho
      // (com o valor antigo) pode chegar antes da do poll(); espera o valor novo
      // entrar e só então confere que o poll() devolve o atual.
      await until(() => c.valueOf('P')?.value == 0);
      expect((await c.poll()).fields['P'], 0);
    });

    test('comando grava e a confirmação do equipamento atualiza o valor', () async {
      server = FakeArduinoServer();
      await server.start();
      final c = await liga(const MessageProfile(commands: [CommandTemplate.text('SET {campo}={valor}\n')]));
      final confirmacao = c.nextFrame();
      await c.write('P', 0);
      expect((await confirmacao).fields['P'], 0);
      expect(server.received.last, 'SET P=0');
      expect(server.values['P'], 0);
      expect(c.valueOf('P')!.value, 0);

      final semComando = RawClient(link: TcpByteLink(host: '127.0.0.1', port: server.port), profile: const MessageProfile());
      await expectLater(semComando.write('P', 1), throwsA(isA<RawCommandError>()));
      await semComando.dispose();
    });

    test('silêncio: a validade vence e poll sem resposta é RawTimeout', () async {
      server = FakeArduinoServer(streamEvery: const Duration(milliseconds: 20));
      await server.start();
      final c = await liga(const MessageProfile(staleAfterMs: 150), responseTimeout: const Duration(milliseconds: 150));
      await until(() => c.valueOf('T') != null);
      expect(c.isStale, isFalse);
      server.silent = true;
      await until(() => c.isStale);
      expect(c.checkFresh, throwsA(isA<RawTimeout>().having((e) => e.userMessage, 'mensagem', 'sem mensagem do equipamento')));
      await expectLater(c.poll(), throwsA(isA<RawTimeout>()));
      server.silent = false;
      await until(() => !c.isStale);
    });

    test('queda: avisa, a próxima operação reconecta; desconectado de propósito não', () async {
      server = FakeArduinoServer();
      await server.start();
      final c = await liga(const MessageProfile());
      String? motivo;
      c.onLost = (r) => motivo = r;
      expect((await c.poll()).fields['T'], 25.3);
      server.dropClients();
      await until(() => motivo != null);
      expect(c.isConnected, isFalse);
      expect((await c.poll()).fields['T'], 25.3, reason: 'reabriu sozinho');

      await c.disconnect();
      await expectLater(c.poll(), throwsA(isA<RawConnectionError>()));
    });

    test('porta fechada = recusou nesta porta', () async {
      server = FakeArduinoServer();
      await server.start();
      final c = RawClient(link: TcpByteLink(host: '127.0.0.1', port: 1), profile: const MessageProfile());
      client = c;
      await expectLater(
        c.connect(),
        throwsA(isA<RawConnectionError>()
            .having((e) => e.refused, 'refused', isTrue)
            .having((e) => e.userMessage, 'mensagem', 'o equipamento recusou a conexão nesta porta')),
      );
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('cliente por UDP (Arduino falso)', () {
    late FakeArduinoServer server;
    late RawClient client;

    tearDown(() async {
      await client.dispose();
      await server.stop();
    });

    test('streaming para a porta local do app', () async {
      server = FakeArduinoServer(udp: true, streamEvery: const Duration(milliseconds: 30));
      await server.start();
      final link = UdpByteLink(host: '127.0.0.1', port: server.port);
      client = RawClient(link: link, profile: const MessageProfile());
      await client.connect();
      expect(link.isDatagram, isTrue);
      server.streamTo(InternetAddress.loopbackIPv4, link.boundPort!);
      await until(() => client.valueOf('T') != null);
      expect(client.valueOf('T')!.value, 25.3);
      expect(client.valueOf('P')!.value, 1);
    });

    test('polling com pacote sem fim de linha, e comando', () async {
      // Um pacote = uma mensagem, sem \n — o comum em ESP por UDP.
      server = FakeArduinoServer(udp: true, encode: (v) => utf8.encode('T=${v['T']};P=${v['P']}'));
      await server.start();
      client = RawClient(
        link: UdpByteLink(host: '127.0.0.1', port: server.port),
        profile: const MessageProfile(mode: RawMode.polling, pollMs: 40, commands: [CommandTemplate.text('SET {campo}={valor}\n')]),
      );
      await client.connect();
      await until(() => client.valueOf('T') != null);
      expect(server.received, contains('?'));
      expect(client.valueOf('P')!.value, 1);

      await client.write('P', 0);
      await until(() => client.valueOf('P')?.value == 0);
      expect(server.values['P'], 0);
      expect((await client.poll()).fields, {'T': 25.3, 'P': 0});
    });
  });
}
