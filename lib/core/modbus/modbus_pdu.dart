import 'dart:typed_data';

import 'modbus_exception.dart';

/// Montagem e leitura de PDUs Modbus — funções puras, sem rede.
///
/// A PDU (Protocol Data Unit) é a parte do quadro que independe do transporte:
/// `[código da função][dados]`. No Modbus TCP ela vai embrulhada no cabeçalho
/// MBAP (ver [ModbusClientTcp]); no simulador embutido ela é entregue direto à
/// [ModbusServerLogic]. Manter esta camada isolada permite testar todo o
/// protocolo sem abrir socket e garante que cliente real e simulado falam
/// exatamente os mesmos bytes.
///
/// Convenções:
///   • registradores trafegam sempre em big-endian (padrão do protocolo); a
///     ordem de bytes/palavras de tipos de 32 bits é tratada no codec de
///     variáveis, não aqui;
///   • endereços são os do protocolo (base 0). Deslocamentos de fabricante
///     ("M0 = endereço 0", "D0 = 700"...) pertencem ao perfil do equipamento.
class ModbusPdu {
  ModbusPdu._();

  // ── Códigos de função ────────────────────────────────────────────────────────
  static const int readCoils = 0x01;
  static const int readDiscreteInputs = 0x02;
  static const int readHoldingRegisters = 0x03;
  static const int readInputRegisters = 0x04;
  static const int writeSingleCoil = 0x05;
  static const int writeSingleRegister = 0x06;
  static const int writeMultipleCoils = 0x0F;
  static const int writeMultipleRegisters = 0x10;

  // ── Limites do protocolo (Modbus Application Protocol v1.1b3) ───────────────
  static const int maxReadBits = 2000;
  static const int maxReadRegisters = 125;
  static const int maxWriteBits = 1968;
  static const int maxWriteRegisters = 123;
  static const int maxAddress = 0xFFFF;

  // ── Pedidos ──────────────────────────────────────────────────────────────────

  /// Leitura de bits (FC01/FC02) ou registradores (FC03/FC04).
  static Uint8List readRequest(int function, int start, int quantity) {
    final isBits = function == readCoils || function == readDiscreteInputs;
    _checkRange(start, quantity, isBits ? maxReadBits : maxReadRegisters);
    return _u8([function, ..._u16(start), ..._u16(quantity)]);
  }

  static Uint8List writeSingleCoilRequest(int address, bool value) {
    _checkRange(address, 1, 1);
    return _u8([writeSingleCoil, ..._u16(address), value ? 0xFF : 0x00, 0x00]);
  }

  static Uint8List writeSingleRegisterRequest(int address, int value) {
    _checkRange(address, 1, 1);
    _checkRegisterValue(value);
    return _u8([writeSingleRegister, ..._u16(address), ..._u16(value)]);
  }

  static Uint8List writeMultipleCoilsRequest(int start, List<bool> values) {
    _checkRange(start, values.length, maxWriteBits);
    final bytes = packBits(values);
    return _u8([
      writeMultipleCoils,
      ..._u16(start),
      ..._u16(values.length),
      bytes.length,
      ...bytes,
    ]);
  }

  static Uint8List writeMultipleRegistersRequest(int start, List<int> values) {
    _checkRange(start, values.length, maxWriteRegisters);
    values.forEach(_checkRegisterValue);
    return _u8([
      writeMultipleRegisters,
      ..._u16(start),
      ..._u16(values.length),
      values.length * 2,
      for (final v in values) ..._u16(v),
    ]);
  }

  // ── Respostas ────────────────────────────────────────────────────────────────

  /// Lança [ModbusExceptionResponse] se a resposta for de exceção, ou
  /// [ModbusProtocolError] se a função não bater com a pedida.
  static void checkResponse(int requestedFunction, Uint8List pdu) {
    if (pdu.isEmpty) {
      throw const ModbusProtocolError('Resposta vazia');
    }
    final fc = pdu[0];
    if (fc == (requestedFunction | 0x80)) {
      if (pdu.length < 2) {
        throw const ModbusProtocolError('Exceção sem código');
      }
      throw ModbusExceptionResponse(
          functionCode: requestedFunction, code: pdu[1]);
    }
    if (fc != requestedFunction) {
      throw ModbusProtocolError(
          'Função esperada 0x${requestedFunction.toRadixString(16)}, '
          'recebida 0x${fc.toRadixString(16)}');
    }
  }

  /// Extrai [count] bits de uma resposta FC01/FC02.
  static List<bool> parseBits(int function, Uint8List pdu, int count) {
    checkResponse(function, pdu);
    if (pdu.length < 2) throw const ModbusProtocolError('Resposta curta');
    final byteCount = pdu[1];
    if (pdu.length < 2 + byteCount || byteCount < (count + 7) ~/ 8) {
      throw ModbusProtocolError(
          'Esperados ${(count + 7) ~/ 8} bytes de bits, recebidos $byteCount');
    }
    return unpackBits(pdu.sublist(2, 2 + byteCount), count);
  }

  /// Extrai [quantity] registradores de uma resposta FC03/FC04.
  static List<int> parseRegisters(int function, Uint8List pdu, int quantity) {
    checkResponse(function, pdu);
    if (pdu.length < 2) throw const ModbusProtocolError('Resposta curta');
    final byteCount = pdu[1];
    if (byteCount != quantity * 2 || pdu.length < 2 + byteCount) {
      throw ModbusProtocolError(
          'Esperados ${quantity * 2} bytes de registradores, recebidos $byteCount');
    }
    return List<int>.generate(
        quantity, (i) => (pdu[2 + i * 2] << 8) | pdu[3 + i * 2]);
  }

  /// Confirma o eco de uma escrita (FC05/06/15/16 respondem endereço + dado).
  static void parseWriteEcho(int function, Uint8List pdu) {
    checkResponse(function, pdu);
    if (pdu.length < 5) {
      throw const ModbusProtocolError('Eco de escrita incompleto');
    }
  }

  // ── Utilitários de bits ──────────────────────────────────────────────────────

  /// Bit i vai no byte i÷8, posição i%8 (LSB primeiro), como manda a norma.
  static List<int> packBits(List<bool> values) {
    final bytes = List<int>.filled((values.length + 7) ~/ 8, 0);
    for (var i = 0; i < values.length; i++) {
      if (values[i]) bytes[i ~/ 8] |= 1 << (i % 8);
    }
    return bytes;
  }

  static List<bool> unpackBits(List<int> bytes, int count) =>
      List<bool>.generate(
          count, (i) => (bytes[i ~/ 8] & (1 << (i % 8))) != 0);

  // ── Internos ─────────────────────────────────────────────────────────────────

  static List<int> _u16(int v) => [(v >> 8) & 0xFF, v & 0xFF];

  static Uint8List _u8(List<int> bytes) => Uint8List.fromList(bytes);

  static void _checkRange(int start, int quantity, int maxQuantity) {
    if (start < 0 || start > maxAddress) {
      throw ModbusRequestError('Endereço $start fora de 0..$maxAddress');
    }
    if (quantity < 1 || quantity > maxQuantity) {
      throw ModbusRequestError(
          'Quantidade $quantity fora de 1..$maxQuantity');
    }
    if (start + quantity - 1 > maxAddress) {
      throw ModbusRequestError(
          'Faixa $start..${start + quantity - 1} passa do endereço $maxAddress');
    }
  }

  static void _checkRegisterValue(int v) {
    if (v < 0 || v > 0xFFFF) {
      throw ModbusRequestError('Valor $v não cabe em 16 bits sem sinal');
    }
  }
}
