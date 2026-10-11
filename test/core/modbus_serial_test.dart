import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/link/byte_link.dart';
import 'package:ihm/core/modbus/modbus_client_serial.dart';
import 'package:ihm/core/modbus/modbus_exception.dart';
import 'package:ihm/core/modbus/modbus_framing.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/core/modbus/modbus_serial_server.dart';

void main() {
  group('envelopes', () {
    test('CRC16 do vetor clássico 01 03 00 00 00 0A = C5 CD', () {
      final f = ModbusFrames.rtu(1, Uint8List.fromList([0x03, 0x00, 0x00, 0x00, 0x0A]));
      expect(f, [0x01, 0x03, 0x00, 0x00, 0x00, 0x0A, 0xC5, 0xCD]);
      final (unit, pdu) = ModbusFrames.parseRtu(f);
      expect(unit, 1);
      expect(pdu, [0x03, 0x00, 0x00, 0x00, 0x0A]);
    });

    test('CRC errado é recusado', () {
      expect(() => ModbusFrames.parseRtu([0x01, 0x03, 0x00, 0x00, 0x00, 0x0A, 0xC5, 0xCE]), throwsFormatException);
    });

    test('LRC do ASCII: :010300000001FB', () {
      final f = ModbusFrames.ascii(1, Uint8List.fromList([0x03, 0x00, 0x00, 0x00, 0x01]));
      expect(String.fromCharCodes(f), ':010300000001FB\r\n');
      final (unit, pdu) = ModbusFrames.parseAscii(f);
      expect(unit, 1);
      expect(pdu, [0x03, 0x00, 0x00, 0x00, 0x01]);
      expect(() => ModbusFrames.parseAscii(':010300000001FC\r\n'.codeUnits), throwsFormatException);
    });

    test('tamanho da resposta RTU pelo código da função', () {
      expect(ModbusFrames.rtuResponseLength([1]), isNull);
      expect(ModbusFrames.rtuResponseLength([1, 3]), isNull);
      expect(ModbusFrames.rtuResponseLength([1, 3, 4]), 9); // 2 registradores
      expect(ModbusFrames.rtuResponseLength([1, 0x06]), 8);
      expect(ModbusFrames.rtuResponseLength([1, 0x83]), 5); // exceção
    });
  });

  group('RTU e ASCII sobre TCP (gateway), por socket real', () {
    late ModbusMemory memory;
    late ModbusSerialTcpServer server;
    late ModbusClientSerial client;

    Future<void> sobe({ModbusFraming framing = ModbusFraming.rtu, bool echo = false, int unidade = 1}) async {
      memory = ModbusMemory(holdingRegisters: 200, coils: 200);
      server = ModbusSerialTcpServer(memory, framing: framing, unitId: 7, echo: echo);
      await server.start();
      client = ModbusClientSerial(
        link: TcpByteLink(host: '127.0.0.1', port: server.port),
        framing: framing,
        unitId: unidade,
        discardEcho: echo,
        responseTimeout: const Duration(milliseconds: 300),
      );
      await client.connect();
    }

    tearDown(() async {
      await client.dispose();
      await server.stop();
    });

    test('RTU: lê e escreve registradores e coils', () async {
      await sobe(unidade: 7);
      memory.pokeRegisters(ModbusArea.holdingRegister, 0, [1, 1200, 0, 85]);
      expect(await client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 4), [1, 1200, 0, 85]);
      await client.fn06WriteSingleRegister(address: 50, value: 4321);
      expect(memory.register(ModbusArea.holdingRegister, 50), 4321);
      await client.fn16WriteMultipleRegisters(startAddress: 10, values: [7, 8, 9]);
      expect(memory.readRegisters(ModbusArea.holdingRegister, 10, 3), [7, 8, 9]);
      await client.fn05WriteSingleCoil(address: 5, value: true);
      expect(await client.fn01ReadCoils(startAddress: 0, count: 8), [false, false, false, false, false, true, false, false]);
    });

    test('RTU: endereço inexistente vira exceção Modbus, não queda', () async {
      await sobe(unidade: 7);
      await expectLater(
        client.fn03ReadHoldingRegisters(startAddress: 190, quantity: 20),
        throwsA(isA<ModbusExceptionResponse>().having((e) => e.code, 'code', ModbusExceptionResponse.illegalDataAddress)),
      );
      expect(await client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 1), [0]);
    });

    test('RTU com adaptador que devolve eco', () async {
      await sobe(unidade: 7, echo: true);
      memory.pokeRegister(ModbusArea.holdingRegister, 3, 555);
      expect(await client.fn03ReadHoldingRegisters(startAddress: 3, quantity: 1), [555]);
      expect(await client.fn03ReadHoldingRegisters(startAddress: 3, quantity: 1), [555]);
    });

    test('RTU: CRC corrompido = resposta inválida; a próxima funciona', () async {
      await sobe(unidade: 7);
      server.corruptNext = true;
      await expectLater(client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 2), throwsA(isA<ModbusProtocolError>()));
      expect(await client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 2), [0, 0]);
    });

    test('RTU: ID de escravo errado = sem resposta (como na linha RS-485)', () async {
      await sobe(unidade: 3);
      await expectLater(client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 1), throwsA(isA<ModbusTimeout>()));
    });

    test('ASCII: ida e volta', () async {
      await sobe(framing: ModbusFraming.ascii, unidade: 7);
      memory.pokeRegisters(ModbusArea.holdingRegister, 20, [0x1234, 0xABCD]);
      expect(await client.fn03ReadHoldingRegisters(startAddress: 20, quantity: 2), [0x1234, 0xABCD]);
      await client.fn06WriteSingleRegister(address: 21, value: 99);
      expect(memory.register(ModbusArea.holdingRegister, 21), 99);
    });
  });

  test('desconectar com o pedido ainda saindo: o erro vai para quem pediu, nunca "não tratado"', () async {
    // O envio fica preso até o teste soltar; desconectar nesse meio falha o
    // pedido antes de alguém esperar a resposta (a corrida que derrubava o
    // teste do RTU sob carga, ao cancelar a inscrição no meio da varredura).
    final link = _SlowLink();
    final c = ModbusClientSerial(link: link, responseTimeout: const Duration(seconds: 2));
    await c.connect();
    final read = c.fn03ReadHoldingRegisters(startAddress: 0, quantity: 1);
    await link.writing.future;
    await c.disconnect();
    link.release.complete();
    await expectLater(read, throwsA(isA<ModbusConnectionError>()));
  });

  test('porta fechada num gateway = recusou', () async {
    final c = ModbusClientSerial(link: TcpByteLink(host: '127.0.0.1', port: 1), responseTimeout: const Duration(milliseconds: 300));
    await expectLater(c.connect(), throwsA(isA<ModbusConnectionError>().having((e) => e.refused, 'refused', isTrue)));
    await c.dispose();
  }, timeout: const Timeout(Duration(seconds: 10)));
}

/// Link cujo envio só termina quando o teste solta ([release]).
class _SlowLink extends ByteLink {
  final writing = Completer<void>();
  final release = Completer<void>();
  final _input = StreamController<Uint8List>.broadcast();
  bool _open = false;

  @override
  bool get isOpen => _open;

  @override
  Stream<Uint8List> get input => _input.stream;

  @override
  Future<void> open() async => _open = true;

  @override
  Future<void> write(Uint8List bytes) async {
    if (!writing.isCompleted) writing.complete();
    await release.future;
  }

  @override
  Future<void> close() async => _open = false;
}
