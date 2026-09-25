import 'dart:math';
import 'dart:typed_data';

import 'modbus_client.dart';
import 'modbus_exception.dart';
import 'modbus_memory.dart';

/// Cliente Modbus que fala com uma [ModbusMemory] dentro do próprio app.
///
/// Serve ao **modo demonstração**: o app funciona completo — telas, botões,
/// gráficos, erros de endereço — sem nenhum CLP na rede. As PDUs passam pelo
/// mesmo [ModbusPdu] e pela mesma [ModbusServerLogic] que um equipamento real
/// usaria, então o que funciona aqui funciona no TCP.
///
/// [latency] imita o tempo de resposta de uma rede de fábrica, e
/// [failureRate] permite simular perda de pacotes em testes.
class SimulatedModbusClient extends ModbusClient {
  SimulatedModbusClient({
    required this.memory,
    super.unitId,
    this.latency = const Duration(milliseconds: 15),
    this.failureRate = 0,
    Random? random,
  })  : _logic = ModbusServerLogic(memory),
        _random = random ?? Random();

  final ModbusMemory memory;
  final ModbusServerLogic _logic;
  final Random _random;

  Duration latency;

  /// Probabilidade (0..1) de um pedido "se perder" e estourar como timeout.
  double failureRate;

  @override
  Future<void> connect() async {
    linkState = ModbusLinkState.connected;
  }

  @override
  Future<void> disconnect() async {
    linkState = ModbusLinkState.disconnected;
  }

  @override
  Future<Uint8List> transact(Uint8List requestPdu) async {
    if (!isConnected) {
      throw const ModbusConnectionError('Simulador desconectado');
    }
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (failureRate > 0 && _random.nextDouble() < failureRate) {
      throw const ModbusTimeout('Falha simulada');
    }
    return _logic.handle(requestPdu);
  }
}
