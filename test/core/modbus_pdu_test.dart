import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/modbus/modbus_exception.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/core/modbus/modbus_pdu.dart';

void main() {
  group('Pedidos', () {
    test('FC03 monta função + início + quantidade em big-endian', () {
      expect(ModbusPdu.readRequest(0x03, 0x0102, 10), [0x03, 0x01, 0x02, 0x00, 0x0A]);
    });

    test('FC05 usa 0xFF00 para ligar e 0x0000 para desligar', () {
      expect(ModbusPdu.writeSingleCoilRequest(7, true), [0x05, 0, 7, 0xFF, 0]);
      expect(ModbusPdu.writeSingleCoilRequest(7, false), [0x05, 0, 7, 0, 0]);
    });

    test('FC15 empacota bits LSB primeiro', () {
      final pdu = ModbusPdu.writeMultipleCoilsRequest(0, [true, false, true, true, false, false, false, false, true]);
      expect(pdu, [0x0F, 0, 0, 0, 9, 2, 0x0D, 0x01]);
    });

    test('limites do protocolo viram ModbusRequestError antes da rede', () {
      expect(() => ModbusPdu.readRequest(0x03, 0, 126), throwsA(isA<ModbusRequestError>()));
      expect(() => ModbusPdu.readRequest(0x01, 0, 2001), throwsA(isA<ModbusRequestError>()));
      expect(() => ModbusPdu.readRequest(0x03, 65535, 2), throwsA(isA<ModbusRequestError>()));
      expect(() => ModbusPdu.writeSingleRegisterRequest(0, 70000), throwsA(isA<ModbusRequestError>()));
    });
  });

  group('Respostas', () {
    test('resposta de exceção vira ModbusExceptionResponse com o código', () {
      expect(
        () => ModbusPdu.parseRegisters(0x03, Uint8List.fromList([0x83, 0x02]), 1),
        throwsA(isA<ModbusExceptionResponse>()
            .having((e) => e.code, 'code', 2)
            .having((e) => e.userMessage, 'msg', contains('endereço inexistente'))),
      );
    });

    test('função trocada vira ModbusProtocolError', () {
      expect(() => ModbusPdu.parseRegisters(0x03, Uint8List.fromList([0x04, 2, 0, 1]), 1),
          throwsA(isA<ModbusProtocolError>()));
    });

    test('contagem de bytes errada vira ModbusProtocolError', () {
      expect(() => ModbusPdu.parseRegisters(0x03, Uint8List.fromList([0x03, 2, 0, 1]), 2),
          throwsA(isA<ModbusProtocolError>()));
    });
  });

  group('ModbusServerLogic (escravo simulado)', () {
    late ModbusMemory memory;
    late ModbusServerLogic logic;

    setUp(() {
      memory = ModbusMemory(holdingRegisters: 100, coils: 100);
      logic = ModbusServerLogic(memory);
    });

    test('leitura fora do mapa responde exceção 0x02, como um CLP', () {
      final r = logic.handle(ModbusPdu.readRequest(0x03, 99, 2));
      expect(r, [0x83, 0x02]);
    });

    test('função desconhecida responde exceção 0x01', () {
      expect(logic.handle(Uint8List.fromList([0x2B, 0, 0])), [0xAB, 0x01]);
    });

    test('escrita e leitura de registradores fecham o ciclo', () {
      logic.handle(ModbusPdu.writeMultipleRegistersRequest(10, [1, 0xBEEF]));
      final r = logic.handle(ModbusPdu.readRequest(0x03, 10, 2));
      expect(ModbusPdu.parseRegisters(0x03, r, 2), [1, 0xBEEF]);
    });

    test('escrita de coil e leitura de bits fecham o ciclo', () {
      logic.handle(ModbusPdu.writeSingleCoilRequest(3, true));
      final r = logic.handle(ModbusPdu.readRequest(0x01, 0, 8));
      expect(ModbusPdu.parseBits(0x01, r, 8), [false, false, false, true, false, false, false, false]);
    });
  });
}
