import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'modbus_exception.dart';
import 'modbus_pdu.dart';

/// As quatro áreas de dados do modelo Modbus.
enum ModbusArea {
  /// Bits de leitura/escrita (FC01 lê, FC05/FC15 escrevem). "0x" na notação
  /// clássica; em CLPs costumam ser os relés internos (M, Y).
  coil,

  /// Bits só de leitura (FC02). "1x"; em CLPs, entradas físicas (X).
  discreteInput,

  /// Registradores de 16 bits de leitura/escrita (FC03 lê, FC06/FC16
  /// escrevem). "4x"; em CLPs, a memória de dados (D).
  holdingRegister,

  /// Registradores de 16 bits só de leitura (FC04). "3x".
  inputRegister,
}

extension ModbusAreaMeta on ModbusArea {
  bool get isBit => this == ModbusArea.coil || this == ModbusArea.discreteInput;
  bool get isWritable =>
      this == ModbusArea.coil || this == ModbusArea.holdingRegister;

  /// Rótulo curto usado nas telas de configuração.
  String get label {
    switch (this) {
      case ModbusArea.coil:
        return 'Coil (0x)';
      case ModbusArea.discreteInput:
        return 'Entrada discreta (1x)';
      case ModbusArea.holdingRegister:
        return 'Holding register (4x)';
      case ModbusArea.inputRegister:
        return 'Input register (3x)';
    }
  }

  String get shortLabel {
    switch (this) {
      case ModbusArea.coil:
        return 'COIL';
      case ModbusArea.discreteInput:
        return 'DI';
      case ModbusArea.holdingRegister:
        return 'HR';
      case ModbusArea.inputRegister:
        return 'IR';
    }
  }
}

/// Memória de um equipamento Modbus em RAM.
///
/// Cada área tem um tamanho fixo; acessar além dele gera a exceção Modbus
/// 0x02 (endereço inexistente), igual a um CLP real — é isso que permite
/// testar o caminho de erro do app sem hardware.
///
/// Notifica ouvintes a cada escrita (vinda da rede ou de [poke]), o que a tela
/// de simulação usa para mostrar os valores ao vivo.
class ModbusMemory extends ChangeNotifier {
  ModbusMemory({
    int coils = 10000,
    int discreteInputs = 10000,
    int holdingRegisters = 10000,
    int inputRegisters = 10000,
  })  : _coils = List<bool>.filled(coils, false),
        _discrete = List<bool>.filled(discreteInputs, false),
        _holding = Uint16List(holdingRegisters),
        _input = Uint16List(inputRegisters);

  final List<bool> _coils;
  final List<bool> _discrete;
  final Uint16List _holding;
  final Uint16List _input;

  int sizeOf(ModbusArea area) {
    switch (area) {
      case ModbusArea.coil:
        return _coils.length;
      case ModbusArea.discreteInput:
        return _discrete.length;
      case ModbusArea.holdingRegister:
        return _holding.length;
      case ModbusArea.inputRegister:
        return _input.length;
    }
  }

  // ── Acesso direto (simulação, testes) ────────────────────────────────────────

  bool bit(ModbusArea area, int address) =>
      (area == ModbusArea.coil ? _coils : _discrete)[address];

  int register(ModbusArea area, int address) =>
      (area == ModbusArea.holdingRegister ? _holding : _input)[address];

  /// Escreve direto na memória, sem passar pelo protocolo — é como o "programa
  /// do CLP" altera seus próprios dados. Aceita também as áreas só-leitura.
  void pokeBit(ModbusArea area, int address, bool value) {
    (area == ModbusArea.coil ? _coils : _discrete)[address] = value;
    notifyListeners();
  }

  void pokeRegister(ModbusArea area, int address, int value) {
    (area == ModbusArea.holdingRegister ? _holding : _input)[address] =
        value & 0xFFFF;
    notifyListeners();
  }

  void pokeRegisters(ModbusArea area, int start, List<int> values) {
    final target = area == ModbusArea.holdingRegister ? _holding : _input;
    for (var i = 0; i < values.length; i++) {
      target[start + i] = values[i] & 0xFFFF;
    }
    notifyListeners();
  }

  // ── Acesso pelo protocolo ────────────────────────────────────────────────────

  List<bool> readBits(ModbusArea area, int start, int count) {
    _check(area, start, count);
    return (area == ModbusArea.coil ? _coils : _discrete)
        .sublist(start, start + count);
  }

  List<int> readRegisters(ModbusArea area, int start, int count) {
    _check(area, start, count);
    return (area == ModbusArea.holdingRegister ? _holding : _input)
        .sublist(start, start + count);
  }

  void writeCoils(int start, List<bool> values) {
    _check(ModbusArea.coil, start, values.length);
    _coils.setRange(start, start + values.length, values);
    notifyListeners();
  }

  void writeHolding(int start, List<int> values) {
    _check(ModbusArea.holdingRegister, start, values.length);
    for (var i = 0; i < values.length; i++) {
      _holding[start + i] = values[i] & 0xFFFF;
    }
    notifyListeners();
  }

  void _check(ModbusArea area, int start, int count) {
    if (start < 0 || start + count > sizeOf(area)) {
      throw _AddressFault();
    }
  }
}

class _AddressFault implements Exception {}

/// Responde PDUs a partir de uma [ModbusMemory] — o "firmware" do escravo.
///
/// Recebe a PDU de pedido e devolve a PDU de resposta, inclusive as de
/// exceção (função | 0x80). Não conhece transporte: o [SimulatedModbusClient]
/// chama direto, o [ModbusTcpServer] chama por trás de um socket.
class ModbusServerLogic {
  ModbusServerLogic(this.memory);

  final ModbusMemory memory;

  Uint8List handle(Uint8List request) {
    if (request.isEmpty) return _exception(0, ModbusExceptionResponse.illegalFunction);
    final fc = request[0];
    try {
      switch (fc) {
        case ModbusPdu.readCoils:
        case ModbusPdu.readDiscreteInputs:
          return _readBits(fc, request);
        case ModbusPdu.readHoldingRegisters:
        case ModbusPdu.readInputRegisters:
          return _readRegisters(fc, request);
        case ModbusPdu.writeSingleCoil:
          return _writeSingleCoil(request);
        case ModbusPdu.writeSingleRegister:
          return _writeSingleRegister(request);
        case ModbusPdu.writeMultipleCoils:
          return _writeMultipleCoils(request);
        case ModbusPdu.writeMultipleRegisters:
          return _writeMultipleRegisters(request);
        default:
          return _exception(fc, ModbusExceptionResponse.illegalFunction);
      }
    } on _AddressFault {
      return _exception(fc, ModbusExceptionResponse.illegalDataAddress);
    } on _ValueFault {
      return _exception(fc, ModbusExceptionResponse.illegalDataValue);
    } on RangeError {
      return _exception(fc, ModbusExceptionResponse.illegalDataValue);
    }
  }

  Uint8List _readBits(int fc, Uint8List r) {
    final start = _u16(r, 1), count = _u16(r, 3);
    if (count < 1 || count > ModbusPdu.maxReadBits) throw _ValueFault();
    final area = fc == ModbusPdu.readCoils ? ModbusArea.coil : ModbusArea.discreteInput;
    final bytes = ModbusPdu.packBits(memory.readBits(area, start, count));
    return Uint8List.fromList([fc, bytes.length, ...bytes]);
  }

  Uint8List _readRegisters(int fc, Uint8List r) {
    final start = _u16(r, 1), count = _u16(r, 3);
    if (count < 1 || count > ModbusPdu.maxReadRegisters) throw _ValueFault();
    final area = fc == ModbusPdu.readHoldingRegisters
        ? ModbusArea.holdingRegister
        : ModbusArea.inputRegister;
    final regs = memory.readRegisters(area, start, count);
    return Uint8List.fromList([
      fc,
      count * 2,
      for (final v in regs) ...[(v >> 8) & 0xFF, v & 0xFF],
    ]);
  }

  Uint8List _writeSingleCoil(Uint8List r) {
    final address = _u16(r, 1), raw = _u16(r, 3);
    if (raw != 0xFF00 && raw != 0x0000) throw _ValueFault();
    memory.writeCoils(address, [raw == 0xFF00]);
    return Uint8List.fromList(r.sublist(0, 5));
  }

  Uint8List _writeSingleRegister(Uint8List r) {
    memory.writeHolding(_u16(r, 1), [_u16(r, 3)]);
    return Uint8List.fromList(r.sublist(0, 5));
  }

  Uint8List _writeMultipleCoils(Uint8List r) {
    final start = _u16(r, 1), count = _u16(r, 3), byteCount = r[5];
    if (count < 1 || count > ModbusPdu.maxWriteBits || byteCount != (count + 7) ~/ 8) {
      throw _ValueFault();
    }
    memory.writeCoils(start, ModbusPdu.unpackBits(r.sublist(6, 6 + byteCount), count));
    return Uint8List.fromList(r.sublist(0, 5));
  }

  Uint8List _writeMultipleRegisters(Uint8List r) {
    final start = _u16(r, 1), count = _u16(r, 3), byteCount = r[5];
    if (count < 1 || count > ModbusPdu.maxWriteRegisters || byteCount != count * 2) {
      throw _ValueFault();
    }
    memory.writeHolding(start, [for (var i = 0; i < count; i++) _u16(r, 6 + i * 2)]);
    return Uint8List.fromList(r.sublist(0, 5));
  }

  static int _u16(Uint8List b, int i) => (b[i] << 8) | b[i + 1];

  static Uint8List _exception(int fc, int code) =>
      Uint8List.fromList([(fc | 0x80) & 0xFF, code]);
}

class _ValueFault implements Exception {}
