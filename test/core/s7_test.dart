import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/comm/comm_error.dart';
import 'package:ihm/core/modbus/modbus_client.dart' show ModbusLinkState;
import 'package:ihm/core/s7/s7_address.dart';
import 'package:ihm/core/s7/s7_client.dart';
import 'package:ihm/core/s7/s7_codec.dart';
import 'package:ihm/core/s7/s7_error.dart';
import 'package:ihm/core/s7/s7_pdu.dart';
import 'package:ihm/core/s7/s7_test_server.dart';

S7Address at(String text) => S7Address.parse(text);

Matcher _formatError(String message) =>
    throwsA(isA<FormatException>().having((e) => e.message, 'message', message));

void main() {
  group('endereços', () {
    test('DB em todos os tamanhos, com texto canônico', () {
      final bit = at('DB1.DBX0.0');
      expect((bit.area, bit.dbNumber, bit.byteOffset, bit.bitIndex, bit.byteLength), (S7Area.db, 1, 0, 0, 1));
      expect(bit.isBit, isTrue);
      expect(bit.toString(), 'DB1.DBX0.0');

      final b = at('DB1.DBB2');
      expect((b.byteOffset, b.bitIndex, b.byteLength), (2, null, 1));
      expect(at('DB1.DBW4').byteLength, 2);
      final d = at('DB12.DBD8');
      expect((d.dbNumber, d.byteOffset, d.byteLength), (12, 8, 4));
      for (final text in ['DB1.DBX0.0', 'DB1.DBB2', 'DB1.DBW4', 'DB12.DBD8', 'DB65535.DBX65535.7']) {
        expect(at(text).toString(), text);
      }
    });

    test('M, I/E e Q/A: alemão e inglês dão o mesmo endereço', () {
      final m = at('M10.3');
      expect((m.area, m.dbNumber, m.byteOffset, m.bitIndex), (S7Area.flags, 0, 10, 3));
      expect(at('MB10').byteLength, 1);
      expect(at('MW10').byteLength, 2);
      expect(at('MD10').byteLength, 4);

      const pares = {
        'I0.0': 'E0.0',
        'IB1': 'EB1',
        'IW64': 'EW64',
        'ID4': 'ED4',
        'Q0.1': 'A0.1',
        'QB2': 'AB2',
        'QW4': 'AW4',
        'QD8': 'AD8',
      };
      pares.forEach((english, german) {
        expect(at(german), at(english), reason: '$german = $english');
        expect(at(german).toString(), english, reason: 'canônico é o internacional');
        expect(at(english).format(german: true), german);
      });
      expect(at('IW64').area, S7Area.inputs);
      expect(at('AW4').area, S7Area.outputs);
    });

    test('tolerâncias: %, minúsculas, espaços, MX e DB sem ponto', () {
      expect(at('%MW10'), at('MW10'));
      expect(at('%DB1.DBX0.0'), at('DB1.DBX0.0'));
      expect(at('  db1.dbw4 '), at('DB1.DBW4'));
      expect(at('MX10.3').toString(), 'M10.3');
      expect(at('DB1DBW4').toString(), 'DB1.DBW4');
    });

    test('faixa de bytes (STRING, bloco) no formato P# do Step 7', () {
      final s = at('P#DB1.DBX10.0 BYTE 22');
      expect((s.area, s.dbNumber, s.byteOffset, s.bitIndex, s.byteLength), (S7Area.db, 1, 10, null, 22));
      expect(s.toString(), 'P#DB1.DBX10.0 BYTE 22');
      expect(at('p#m4.0 byte 6').toString(), 'P#M4.0 BYTE 6');
      expect(at('P#DB1.DBX10.0 BYTE 2'), at('DB1.DBW10'), reason: '2 bytes é uma palavra');
      expect(at('DB1.DBB10').withLength(S7Codec.stringBytes(20)), s);
    });

    test('tipo sugerido pelo tamanho', () {
      expect(at('DB1.DBX0.0').suggestedTypes, [S7Type.boolean]);
      expect(at('MB0').suggestedTypes, [S7Type.byte]);
      expect(at('DB1.DBW4').suggestedTypes, [S7Type.word, S7Type.int16]);
      expect(at('DB1.DBD8').suggestedTypes, [S7Type.dword, S7Type.int32, S7Type.real]);
      expect(at('P#DB1.DBX10.0 BYTE 22').suggestedType, S7Type.string);
    });

    test('erros com mensagem curta em português', () {
      expect(() => at('DB1.DBX0.8'), _formatError('DB1.DBX0.8: o bit vai de 0 a 7'));
      expect(() => at('M10.9'), _formatError('M10.9: o bit vai de 0 a 7'));
      expect(() => at('DB0.DBW0'), _formatError('DB0.DBW0: o número do DB vai de 1 a 65535'));
      expect(() => at('DB1.DBX0'), _formatError('DB1.DBX0: falta o bit (ex.: DB1.DBX0.0)'));
      expect(() => at('M10'), _formatError('M10: falta o bit (ex.: M10.0) ou o tamanho (MB10, MW10, MD10)'));
      expect(() => at('DB1.DBW4.1'), _formatError('DB1.DBW4.1: só endereço de bit leva ponto (ex.: DB1.DBX4.1)'));
      expect(() => at('MW65535'), _formatError('MW65535: o byte vai de 0 a 65534'));
      expect(() => at('DB1'), _formatError('DB1: falta o endereço dentro do DB (ex.: DB1.DBW0)'));
      expect(() => at('DBW4'), _formatError('DBW4: falta o número do DB (ex.: DB1.DBW4)'));
      expect(() => at('DB1.XYZ'), _formatError('DB1.XYZ: depois do DB vem DBX, DBB, DBW ou DBD (ex.: DB1.DBW4)'));
      expect(() => at('T5'), _formatError('T5: temporizador e contador não são lidos; use DB, M, I ou Q'));
      expect(() => at('X10'), _formatError('X10: endereço não reconhecido (ex.: DB1.DBW4, M10.3, IW64)'));
      expect(() => at('  '), _formatError('endereço vazio'));
      expect(() => at('P#DB1.DBX10.3 BYTE 4'), _formatError('P#DB1.DBX10.3 BYTE 4: a faixa começa no bit 0'));
      expect(() => at('P#DB1.DBX10.8 BYTE 4'), _formatError('P#DB1.DBX10.8 BYTE 4: o bit vai de 0 a 7'));

      expect(S7Address.validate('DB1.DBW4'), isNull);
      expect(S7Address.validate('DB1.DBX0.8'), 'DB1.DBX0.8: o bit vai de 0 a 7');
      expect(S7Address.tryParse('ZZ'), isNull);
      expect(() => S7Address(area: S7Area.db, dbNumber: 1, byteOffset: 0, bitIndex: 8), throwsArgumentError);
      expect(() => S7Address(area: S7Area.db, byteOffset: 0), throwsArgumentError, reason: 'DB0');
    });
  });

  group('codecs (big-endian)', () {
    Uint8List b(List<int> v) => Uint8List.fromList(v);

    test('números', () {
      expect(S7Codec.encode(S7Type.real, 1.5), [0x3F, 0xC0, 0x00, 0x00]);
      expect(S7Codec.decode(S7Type.real, b([0xC0, 0x20, 0x00, 0x00])), -2.5);
      expect(S7Codec.encode(S7Type.int16, -2), [0xFF, 0xFE]);
      expect(S7Codec.decode(S7Type.int16, b([0xFF, 0xFE])), -2);
      expect(S7Codec.decode(S7Type.word, b([0xFF, 0xFE])), 0xFFFE);
      expect(S7Codec.encode(S7Type.word, 0xABCD), [0xAB, 0xCD]);
      expect(S7Codec.encode(S7Type.int32, -100000), [0xFF, 0xFE, 0x79, 0x60]);
      expect(S7Codec.decode(S7Type.int32, b([0xFF, 0xFE, 0x79, 0x60])), -100000);
      expect(S7Codec.decode(S7Type.dword, b([0xDE, 0xAD, 0xBE, 0xEF])), 0xDEADBEEF);
      expect(S7Codec.encode(S7Type.dword, 0xDEADBEEF), [0xDE, 0xAD, 0xBE, 0xEF]);
      expect(S7Codec.encode(S7Type.byte, 200), [200]);
      expect(S7Codec.decode(S7Type.byte, b([200])), 200);
    });

    test('BOOL pelo bit do byte', () {
      expect(S7Codec.decode(S7Type.boolean, b([0x08]), bit: 3), isTrue);
      expect(S7Codec.decode(S7Type.boolean, b([0x08]), bit: 2), isFalse);
      expect(S7Codec.decode(S7Type.boolean, b([1])), isTrue);
      expect(S7Codec.encode(S7Type.boolean, true), [1]);
      expect(S7Codec.encode(S7Type.boolean, 0), [0]);
    });

    test('STRING com 2 bytes de cabeçalho', () {
      final s = S7Codec.encodeString('Lote 42', 10);
      expect(s, [10, 7, ...'Lote 42'.codeUnits, 0, 0, 0]);
      expect(S7Codec.decodeString(s), 'Lote 42');
      expect(S7Codec.decodeString(S7Codec.encodeString('ação', 8)), 'ação', reason: 'Latin-1');
      expect(S7Codec.decodeString(S7Codec.encodeString('5€', 4)), '5?');
      // Cabeçalho incoerente (tamanho > capacidade) não estoura a leitura.
      expect(S7Codec.decodeString(b([5, 9, ...'ABCDEFGH'.codeUnits])), 'ABCDE');
      expect(S7Codec.decodeString(b([20, 9, ...'ABC'.codeUnits])), 'ABC');
      expect(S7Codec.encode(S7Type.string, 'OK', maxChars: 4), [4, 2, 0x4F, 0x4B, 0, 0]);
    });

    test('valor que não cabe é recusado, não cortado', () {
      expect(() => S7Codec.encode(S7Type.int16, 40000), throwsA(isA<ArgumentError>().having((e) => e.message, 'm', 'INT aceita de -32768 a 32767')));
      expect(() => S7Codec.encode(S7Type.word, -1), throwsArgumentError);
      expect(() => S7Codec.encode(S7Type.byte, 1.5), throwsA(isA<ArgumentError>().having((e) => e.message, 'm', 'BYTE aceita só número inteiro')));
      expect(() => S7Codec.encode(S7Type.real, 1e39), throwsArgumentError);
      expect(() => S7Codec.encodeString('texto comprido', 5), throwsA(isA<ArgumentError>().having((e) => e.message, 'm', 'texto com 14 letras; o campo aceita até 5')));
      expect(() => S7Codec.decode(S7Type.real, b([1, 2])), throwsArgumentError);
    });
  });

  group('mensagens (vetores de referência)', () {
    test('COTP CR com TSAP de rack 0, slot 2 (S7-300)', () {
      final c = S7Client(host: 'x', rack: 0, slot: 2);
      expect(c.remoteTsap, 0x0102);
      expect(S7Pdu.connectionRequest(localTsap: c.localTsap, remoteTsap: c.remoteTsap), [
        0x03, 0x00, 0x00, 0x16, 0x11, 0xE0, 0x00, 0x00, 0x00, 0x01, 0x00, //
        0xC0, 0x01, 0x0A, 0xC1, 0x02, 0x01, 0x00, 0xC2, 0x02, 0x01, 0x02,
      ]);
      expect(S7Client(host: 'x', rack: 1, slot: 3, connectionType: S7ConnectionType.op).remoteTsap, 0x0223);
      expect(() => S7Client(host: 'x', rack: 8), throwsArgumentError);
      expect(() => S7Client(host: 'x', slot: 32), throwsArgumentError);
    });

    test('Setup Communication pedindo PDU de 960', () {
      expect(S7Pdu.dataFrame(S7Pdu.setupCommunication(1, 960)), [
        0x03, 0x00, 0x00, 0x19, 0x02, 0xF0, 0x80, //
        0x32, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x08, 0x00, 0x00,
        0xF0, 0x00, 0x00, 0x01, 0x00, 0x01, 0x03, 0xC0,
      ]);
    });

    test('Read Var de DB1.DBW4 e de DB1.DBX0.3 (transporte BIT)', () {
      expect(S7Pdu.readRequest(5, [S7ItemSpec.of(at('DB1.DBW4'))]), [
        0x32, 0x01, 0x00, 0x00, 0x00, 0x05, 0x00, 0x0E, 0x00, 0x00, //
        0x04, 0x01, 0x12, 0x0A, 0x10, 0x02, 0x00, 0x02, 0x00, 0x01, 0x84, 0x00, 0x00, 0x20,
      ]);
      expect(S7ItemSpec.of(at('DB1.DBX0.3')).bytes, [0x12, 0x0A, 0x10, 0x01, 0x00, 0x01, 0x00, 0x01, 0x84, 0x00, 0x00, 0x03]);
      expect(S7ItemSpec.of(at('QW2')).bytes, [0x12, 0x0A, 0x10, 0x02, 0x00, 0x02, 0x00, 0x00, 0x82, 0x00, 0x00, 0x10]);
    });

    test('Write Var: bit com transporte BIT, bytes em bits, enchimento entre itens ímpares', () {
      final pdu = S7Pdu.writeRequest(
        7,
        [S7ItemSpec.of(at('DB1.DBX0.3')), S7ItemSpec.of(at('DB1.DBD4'))],
        [Uint8List.fromList([1]), Uint8List.fromList([0x3F, 0xC0, 0x00, 0x00])],
      );
      // Dados: bit (4 + 1 + enchimento) e REAL (4 + 4).
      expect(pdu.sublist(pdu.length - 14), [0x00, 0x03, 0x00, 0x01, 0x01, 0x00, 0x00, 0x04, 0x00, 0x20, 0x3F, 0xC0, 0x00, 0x00]);
      expect(pdu.length, S7Pdu.writeRequestSize([1, 4]));
    });

    test('tamanhos: com PDU 240 cabem 222 bytes numa leitura e 212 numa escrita', () {
      expect(S7Pdu.readRequestSize(1), 24);
      expect(S7Pdu.readResponseSize([222]), 240);
      expect(S7Pdu.readResponseSize([1, 2]), 14 + 6 + 6);
      expect(S7Pdu.writeRequestSize([212]), 240);
    });
  });

  group('cliente × servidor por socket real', () {
    late S7Memory memory;
    late S7TestServer server;
    late S7Client client;

    setUp(() async {
      memory = S7Memory()
        ..addDb(1, 100)
        ..addDb(2, 600)
        ..addDb(3, 10);
      // PDU 240, como S7-300 e S7-1200: obriga a dividir cedo.
      server = S7TestServer(memory, pduSize: 240);
      await server.start();
      client = S7Client(host: '127.0.0.1', port: server.port, responseTimeout: const Duration(milliseconds: 300));
      await client.connect();
    });

    tearDown(() async {
      await client.dispose();
      await server.stop();
    });

    test('conecta (COTP + Setup Communication) e fica com a PDU do CLP', () async {
      expect(client.state.value, ModbusLinkState.connected);
      expect(client.pduSize, 240, reason: 'pediu 960, o CLP aceita 240');
      expect(server.connections, 1);
      expect(server.lastRemoteTsap, 0x0101, reason: 'PG, rack 0, slot 1');
    });

    test('vários itens num pedido só: bit, byte, INT, REAL, STRING, M, I, Q', () async {
      memory
        ..poke(at('DB1.DBX0.3'), [1])
        ..poke(at('DB1.DBB1'), [200])
        ..poke(at('DB1.DBW2'), S7Codec.encode(S7Type.int16, -1234))
        ..poke(at('DB1.DBD4'), S7Codec.encode(S7Type.real, 3.25))
        ..poke(at('P#DB1.DBX8.0 BYTE 12'), S7Codec.encodeString('Lote 42', 10))
        ..poke(at('MW10'), S7Codec.encode(S7Type.word, 0xBEEF))
        ..poke(at('E0.1'), [1])
        ..poke(at('QD4'), S7Codec.encode(S7Type.int32, -100000));

      final r = await client.read([
        at('DB1.DBX0.3'),
        at('DB1.DBX0.2'),
        at('DB1.DBB1'),
        at('DB1.DBW2'),
        at('DB1.DBD4'),
        at('P#DB1.DBX8.0 BYTE 12'),
        at('MW10'),
        at('I0.1'),
        at('AD4'),
      ]);
      expect(server.readJobs, 1);
      expect(server.readItemCounts, [9]);
      expect(r.every((x) => x.ok), isTrue);
      expect(r[0].value(), isTrue);
      expect(r[1].value(), isFalse);
      expect(r[2].value(), 200);
      expect(r[3].value(S7Type.int16), -1234);
      expect(r[4].value(S7Type.real), 3.25);
      expect(r[5].value(), 'Lote 42');
      expect(r[6].value(), 0xBEEF);
      expect(r[7].value(), isTrue);
      expect(r[8].value(S7Type.int32), -100000);
    });

    test('divide pelo limite de itens e pela PDU, e remonta item maior que a PDU', () async {
      for (var i = 0; i < 30; i++) {
        memory.poke(at('DB1.DBW${i * 2}'), S7Codec.encode(S7Type.word, 1000 + i));
      }
      final words = await client.read([for (var i = 0; i < 30; i++) at('DB1.DBW${i * 2}')]);
      // O próprio pedido limita: 12 + 12 × itens ≤ 240 → 19 itens.
      expect(server.readItemCounts, [19, 11]);
      expect([for (final w in words) w.value()], [for (var i = 0; i < 30; i++) 1000 + i]);

      // Limite de itens por pedido, independente da PDU.
      final few = S7Client(host: '127.0.0.1', port: server.port, maxItemsPerRequest: 5);
      await few.connect();
      server.readItemCounts.clear();
      final some = await few.read([for (var i = 0; i < 12; i++) at('DB1.DBW${i * 2}')]);
      expect(server.readItemCounts, [5, 5, 2]);
      expect(some.last.value(), 1011);
      await few.dispose();

      // 3 × 100 bytes: dois cabem (14 + 104 + 104 = 222), o terceiro passaria de 240.
      server.readItemCounts.clear();
      await client.read([at('P#DB2.DBX0.0 BYTE 100'), at('P#DB2.DBX100.0 BYTE 100'), at('P#DB2.DBX200.0 BYTE 100')]);
      expect(server.readItemCounts, [2, 1]);

      // 600 bytes num item só: 222 + 222 + 156, remontados na ordem.
      final pattern = [for (var i = 0; i < 600; i++) (i * 7) & 0xFF];
      memory.poke(at('P#DB2.DBX0.0 BYTE 600'), pattern);
      server.readItemCounts.clear();
      final big = await client.readBytes(at('P#DB2.DBX0.0 BYTE 600'));
      expect(server.readItemCounts, [1, 1, 1]);
      expect(big, pattern);
    });

    test('escreve bit com transporte BIT sem mexer nos vizinhos', () async {
      memory.poke(at('DB1.DBB0'), [0xA5]); // 1010 0101
      await client.writeBit(at('DB1.DBX0.1'), true);
      expect(memory.peek(at('DB1.DBB0')), [0xA7]);
      await client.writeBit(at('DB1.DBX0.0'), false);
      expect(memory.peek(at('DB1.DBB0')), [0xA6]);
      await client.writeValue(at('Q1.7'), S7Type.boolean, true);
      expect(memory.bit(at('Q1.7')), isTrue);
      expect(() => client.writeBit(at('DB1.DBW0'), true), throwsA(isA<S7RequestError>()));
    });

    test('escreve REAL, INT, STRING; vários itens num pedido; e lê de volta', () async {
      await client.writeValue(at('DB1.DBD4'), S7Type.real, 75.5);
      expect(S7Codec.decode(S7Type.real, memory.peek(at('DB1.DBD4'))), 75.5);
      await client.writeValue(at('MW10'), S7Type.int16, -2);
      expect(memory.peek(at('MW10')), [0xFF, 0xFE]);
      await client.writeValue(at('P#DB1.DBX20.0 BYTE 12'), S7Type.string, 'Receita B');
      expect(await client.readValue(at('P#DB1.DBX20.0 BYTE 12')), 'Receita B');

      final jobs = server.writeJobs;
      final errors = await client.write([
        S7WriteItem.bit(at('M0.0'), true),
        S7WriteItem.value(at('DB1.DBB40'), S7Type.byte, 7),
        S7WriteItem.value(at('DB1.DBD44'), S7Type.int32, 123456),
      ]);
      expect(errors, [null, null, null]);
      expect(server.writeJobs, jobs + 1, reason: 'três itens, um pedido');
      expect(memory.bit(at('M0.0')), isTrue);
      expect(memory.peek(at('DB1.DBB40')), [7]);
      expect(await client.readValue(at('DB1.DBD44'), S7Type.int32), 123456);
    });

    test('escrita maior que a PDU vai em pedaços', () async {
      final data = Uint8List.fromList([for (var i = 0; i < 500; i++) (i * 3) & 0xFF]);
      await client.writeBytes(at('P#DB2.DBX50.0 BYTE 500'), data);
      expect(server.writeJobs, 3, reason: '212 + 212 + 76');
      expect(memory.peek(at('P#DB2.DBX50.0 BYTE 500')), data);
    });

    test('item com erro não derruba os outros (DB inexistente, fora do DB, acesso negado)', () async {
      memory
        ..poke(at('DB1.DBW0'), [0x00, 0x2A])
        ..poke(at('DB1.DBW98'), [0x00, 0x63])
        ..poke(at('MW0'), [0x01, 0x00]);
      server.deniedDbs.add(3);
      final r = await client.read([
        at('DB1.DBW0'),
        at('DB99.DBW0'),
        at('DB1.DBW98'),
        at('DB1.DBD98'),
        at('MW0'),
        at('DB3.DBB0'),
      ]);
      expect(server.readJobs, 1);
      expect(r[0].value(), 42);
      expect(r[1].error, isA<S7ItemError>().having((e) => e.code, 'code', S7ItemError.objectMissing));
      expect(r[1].error!.isAddressError, isTrue);
      expect(r[1].error!.userMessage, 'DB inexistente no CLP');
      expect(r[2].value(), 99);
      expect(r[3].error!.code, S7ItemError.addressOutOfRange);
      expect(r[3].error!.userMessage, contains('acesso otimizado'));
      expect(r[4].value(), 256);
      expect(r[5].error!.isAccessDenied, isTrue);
      expect(r[5].error!.userMessage, contains('habilite PUT/GET'));
      expect(r[5].error, isA<CommError>());
      expect(() => r[1].value(), throwsA(isA<S7ItemError>()));

      await expectLater(client.readBytes(at('DB99.DBW0')), throwsA(isA<S7ItemError>()));
      final w = await client.write([
        S7WriteItem.value(at('DB1.DBW0'), S7Type.int16, 5),
        S7WriteItem.value(at('DB99.DBW0'), S7Type.int16, 5),
      ]);
      expect(w[0], isNull);
      expect(w[1]!.code, S7ItemError.objectMissing);
      expect(client.state.value, ModbusLinkState.connected, reason: 'erro de item não é queda');
    });

    test('PUT/GET desligado: conexão aceita, leitura recusada com a dica certa', () async {
      server.refuseJobs = true;
      await expectLater(
        client.read([at('DB1.DBW0')]),
        throwsA(isA<S7RequestRefused>()
            .having((e) => e.userMessage, 'userMessage', 'o CLP recusou: habilite PUT/GET e desligue o acesso otimizado do DB')),
      );
      await expectLater(client.ping(), throwsA(isA<S7RequestRefused>()));
      await expectLater(client.writeBit(at('M0.0'), true), throwsA(isA<S7RequestRefused>()));
      server.refuseJobs = false;
      expect(await client.readValue(at('DB1.DBW0')), 0);
      expect(server.connections, 1, reason: 'a recusa não derruba a conexão');
    });

    test('tipo que não cabe no endereço é recusado antes da rede', () async {
      await expectLater(client.readValue(at('DB1.DBW0'), S7Type.real), throwsA(isA<S7RequestError>()));
      expect(() => S7WriteItem.value(at('DB1.DBX0.0'), S7Type.int16, 1), throwsA(isA<S7RequestError>()));
      expect(server.readJobs, 0);
    });

    test('sem resposta vira S7Timeout e o próximo pedido funciona', () async {
      server.dropNextRequests = 1;
      await expectLater(
        client.read([at('DB1.DBW0')]),
        throwsA(isA<S7Timeout>().having((e) => e.userMessage, 'userMessage', 'sem resposta do CLP')),
      );
      memory.poke(at('DB1.DBW0'), [0, 9]);
      expect(await client.readValue(at('DB1.DBW0')), 9);
    });

    test('resposta atrasada de um pedido vencido é descartada pela referência', () async {
      memory.poke(at('DB1.DBW0'), [0, 1]);
      server.responseDelay = const Duration(milliseconds: 450);
      await expectLater(client.readValue(at('DB1.DBW0')), throwsA(isA<S7Timeout>()));
      server.responseDelay = Duration.zero;
      memory.poke(at('DB1.DBW0'), [0, 2]);
      client.responseTimeout = const Duration(seconds: 2);
      expect(await client.readValue(at('DB1.DBW0')), 2, reason: 'não pode casar com a resposta velha (1)');
    });

    test('pedidos em paralelo são serializados e cada um recebe a sua resposta', () async {
      for (var i = 0; i < 20; i++) {
        memory.poke(at('DB1.DBW${i * 2}'), S7Codec.encode(S7Type.int16, i * 11));
      }
      final results = await Future.wait([for (var i = 0; i < 20; i++) client.readValue(at('DB1.DBW${i * 2}'), S7Type.int16)]);
      expect(results, [for (var i = 0; i < 20; i++) i * 11]);
    });

    test('resposta picada no TCP e em vários COTP DT é remontada', () async {
      client.responseTimeout = const Duration(seconds: 3);
      server
        ..tcpChunk = 5
        ..cotpChunk = 7;
      memory.poke(at('DB1.DBD4'), S7Codec.encode(S7Type.real, -12.5));
      final r = await client.read([at('DB1.DBD4'), at('DB1.DBX0.0'), at('P#DB1.DBX8.0 BYTE 12')]);
      expect(r[0].value(S7Type.real), -12.5);
      expect(r[1].ok, isTrue);
    });

    test('queda marca "lost" e o próximo pedido reconecta sozinho (COTP + Setup de novo)', () async {
      await server.closeAllClients();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(client.state.value, ModbusLinkState.lost);

      memory.poke(at('MW2'), [0, 77]);
      expect(await client.readValue(at('MW2')), 77);
      expect(client.state.value, ModbusLinkState.connected);
      expect(server.connections, 2);
    });

    test('desconexão manual não reconecta', () async {
      await client.disconnect();
      expect(client.state.value, ModbusLinkState.disconnected);
      await expectLater(client.read([at('MW0')]), throwsA(isA<S7ConnectionError>()));
      expect(server.connections, 1);
    });

    test('servidor que devolve o byte inteiro na leitura de bit (python-snap7) dá o bit certo', () async {
      server.bitReadsAsByte = true;
      memory.poke(at('DB1.DBB0'), [0x08]); // só o bit 3
      final r = await client.read([at('DB1.DBX0.3'), at('DB1.DBX0.0'), at('DB1.DBW2')]);
      expect([r[0].value(), r[1].value()], [true, false]);
      expect(r[2].ok, isTrue);
    });

    test('ping lê MB0 e passa', () async {
      await client.ping();
      expect(server.readItemCounts, [1]);
    });
  });

  group('conexão recusada', () {
    test('porta fechada num IP que existe = "recusou nesta porta"', () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final closedPort = probe.port;
      await probe.close();
      // 5 s: o Windows insiste ~2 s antes de devolver "recusado" (10061).
      final c = S7Client(host: '127.0.0.1', port: closedPort, connectionTimeout: const Duration(seconds: 5));
      await expectLater(
        c.connect(),
        throwsA(isA<S7ConnectionError>()
            .having((e) => e.refusal, 'refusal', S7Refusal.port)
            .having((e) => e.refused, 'refused', isTrue)
            .having((e) => e.userMessage, 'userMessage', 'o CLP recusou a conexão nesta porta')),
      );
      expect(c.state.value, ModbusLinkState.lost);
      await c.dispose();
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('rack/slot errados = "confira rack e slot"; certos conectam', () async {
      final memory = S7Memory()..addDb(1, 10);
      final server = S7TestServer(memory, requiredRemoteTsap: 0x0102); // CPU no slot 2 (S7-300)
      await server.start();
      final hosts = <String>[];
      final wrong = S7Client(host: '127.0.0.1', port: server.port, slot: 1, responseTimeout: const Duration(milliseconds: 500));
      await expectLater(
        wrong.connect(),
        throwsA(isA<S7ConnectionError>()
            .having((e) => e.refusal, 'refusal', S7Refusal.rackSlot)
            .having((e) => e.userMessage, 'userMessage', 'o CLP recusou a conexão: confira rack e slot')),
      );
      expect(wrong.state.value, ModbusLinkState.lost);

      final right = S7Client(
        host: '127.0.0.1',
        port: server.port,
        rack: S7Cpu.s7300.rack,
        slot: S7Cpu.s7300.slot,
        beforeConnect: (h) async => hosts.add(h),
      );
      await right.connect();
      expect(right.isConnected, isTrue);
      expect(right.pduSize, 480);
      expect(hosts, ['127.0.0.1'], reason: 'beforeConnect antes de abrir o socket');
      await wrong.dispose();
      await right.dispose();
      await server.stop();
    });
  });
}
