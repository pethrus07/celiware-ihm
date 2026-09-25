import 'package:flutter/foundation.dart';

import 'modbus_pdu.dart';

/// Estado da ligação com um equipamento, observável pela interface.
enum ModbusLinkState {
  /// Nunca conectou ou foi desconectado de propósito.
  disconnected,

  /// Tentando abrir o socket.
  connecting,

  /// Socket aberto e respondendo.
  connected,

  /// Caiu sem ter sido pedido; a próxima requisição tenta reconectar.
  lost,
}

/// Cliente Modbus genérico — a "raiz" de toda comunicação do app.
///
/// Evolução direta do `ModbusClientTcp` do InoRobot/machine_monitor: os nomes
/// das funções (`fn01ReadCoils`, `fn03ReadHoldingRegisters`...) foram
/// mantidos para quem já conhece aquela classe. O que mudou:
///
///   • as funções Modbus são implementadas **uma vez**, aqui; cada transporte
///     só implementa [transact] (manda uma PDU, devolve a PDU de resposta).
///     O TCP real e o simulador embutido passam pelo mesmo código;
///   • falhas viram exceções tipadas ([ModbusError]) em vez de lista vazia;
///   • registradores voltam crus, em big-endian como manda a norma. A antiga
///     flag `isLittleEndian` (que trocava bytes de todo registrador) saiu: a
///     ordem de bytes/palavras agora é propriedade de cada variável, porque
///     no mesmo equipamento um INT16 e um FLOAT32 podem ter ordens diferentes;
///   • FC02 e FC04 voltaram (a versão do machine_monitor tinha removido as
///     leituras contínuas delas).
///
/// Uma instância por equipamento. Não é thread-safe entre isolates, mas é
/// seguro chamar várias funções em paralelo: cada transporte serializa ou
/// casa as respostas pelo Transaction ID.
abstract class ModbusClient {
  ModbusClient({this.unitId = 1});

  /// Endereço do escravo na rede (1..247; 255 é aceito por muitos gateways).
  int unitId;

  final ValueNotifier<ModbusLinkState> _state =
      ValueNotifier(ModbusLinkState.disconnected);

  /// Estado da ligação — a tela usa para o selo "online/sem conexão".
  ValueListenable<ModbusLinkState> get state => _state;

  bool get isConnected => _state.value == ModbusLinkState.connected;

  @protected
  set linkState(ModbusLinkState value) => _state.value = value;

  /// Abre a ligação. Lança [ModbusConnectionError] se não conseguir.
  Future<void> connect();

  /// Fecha a ligação de propósito (não tenta reconectar sozinho).
  Future<void> disconnect();

  /// Envia uma PDU de pedido e devolve a PDU de resposta (ainda não
  /// verificada). Lança [ModbusTimeout]/[ModbusConnectionError].
  @protected
  Future<Uint8List> transact(Uint8List requestPdu);

  /// Libera recursos. Depois disso a instância não pode ser reutilizada.
  @mustCallSuper
  Future<void> dispose() async {
    await disconnect();
    _state.dispose();
  }

  // ── Leitura ──────────────────────────────────────────────────────────────────

  Future<List<bool>> fn01ReadCoils({required int startAddress, required int count}) =>
      _readBits(ModbusPdu.readCoils, startAddress, count);

  Future<List<bool>> fn02ReadDiscreteInputs({required int startAddress, required int count}) =>
      _readBits(ModbusPdu.readDiscreteInputs, startAddress, count);

  Future<List<int>> fn03ReadHoldingRegisters({required int startAddress, required int quantity}) =>
      _readRegisters(ModbusPdu.readHoldingRegisters, startAddress, quantity);

  Future<List<int>> fn04ReadInputRegisters({required int startAddress, required int quantity}) =>
      _readRegisters(ModbusPdu.readInputRegisters, startAddress, quantity);

  // ── Escrita ──────────────────────────────────────────────────────────────────

  Future<void> fn05WriteSingleCoil({required int address, required bool value}) async {
    final pdu = await transact(ModbusPdu.writeSingleCoilRequest(address, value));
    ModbusPdu.parseWriteEcho(ModbusPdu.writeSingleCoil, pdu);
  }

  Future<void> fn06WriteSingleRegister({required int address, required int value}) async {
    final pdu = await transact(ModbusPdu.writeSingleRegisterRequest(address, value));
    ModbusPdu.parseWriteEcho(ModbusPdu.writeSingleRegister, pdu);
  }

  Future<void> fn15WriteMultipleCoils({required int startAddress, required List<bool> values}) async {
    final pdu = await transact(ModbusPdu.writeMultipleCoilsRequest(startAddress, values));
    ModbusPdu.parseWriteEcho(ModbusPdu.writeMultipleCoils, pdu);
  }

  Future<void> fn16WriteMultipleRegisters({required int startAddress, required List<int> values}) async {
    final pdu = await transact(ModbusPdu.writeMultipleRegistersRequest(startAddress, values));
    ModbusPdu.parseWriteEcho(ModbusPdu.writeMultipleRegisters, pdu);
  }

  // ── Internos ─────────────────────────────────────────────────────────────────

  Future<List<bool>> _readBits(int function, int start, int count) async {
    final pdu = await transact(ModbusPdu.readRequest(function, start, count));
    return ModbusPdu.parseBits(function, pdu, count);
  }

  Future<List<int>> _readRegisters(int function, int start, int quantity) async {
    final pdu = await transact(ModbusPdu.readRequest(function, start, quantity));
    return ModbusPdu.parseRegisters(function, pdu, quantity);
  }
}
