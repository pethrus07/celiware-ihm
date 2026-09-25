import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'modbus_memory.dart';

/// Servidor (escravo) Modbus TCP mínimo, em Dart.
///
/// Existe para os **testes de integração**: sobe numa porta local, e o
/// [ModbusClientTcp] real conversa com ele por socket de verdade — framing
/// MBAP, Transaction ID, queda de conexão, tudo. Não depende de Python nem de
/// ferramenta externa, então roda em qualquer máquina com `flutter test`.
///
/// Para simular com ferramentas de mercado ou cenários longos, use os scripts
/// de `sim/` (pymodbus), descritos em `docs/SIMULACAO.md`.
///
/// Ganchos de teste: [responseDelay] atrasa respostas (provoca timeout),
/// [dropNextRequests] ignora pedidos, e [closeAllClients] derruba as conexões.
class ModbusTcpServer {
  ModbusTcpServer(this.memory, {this.unitId}) : _logic = ModbusServerLogic(memory);

  final ModbusMemory memory;
  final ModbusServerLogic _logic;

  /// Se definido, só responde a este Unit ID (os outros são ignorados, como
  /// num gateway com um único escravo).
  final int? unitId;

  Duration responseDelay = Duration.zero;
  int dropNextRequests = 0;

  ServerSocket? _server;
  final List<Socket> _clients = [];

  int get port => _server!.port;
  int get clientCount => _clients.length;

  /// Porta 0 = o sistema escolhe uma livre (ideal para testes paralelos).
  Future<void> start({int port = 0, String address = '127.0.0.1'}) async {
    _server = await ServerSocket.bind(address, port);
    _server!.listen(_onClient);
  }

  Future<void> stop() async {
    await closeAllClients();
    await _server?.close();
    _server = null;
  }

  Future<void> closeAllClients() async {
    for (final c in List<Socket>.of(_clients)) {
      c.destroy();
    }
    _clients.clear();
  }

  void _onClient(Socket client) {
    _clients.add(client);
    final buffer = <int>[];
    client.listen(
      (data) {
        buffer.addAll(data);
        while (buffer.length >= 7) {
          final length = (buffer[4] << 8) | buffer[5];
          final total = 6 + length;
          if (buffer.length < total) break;
          final frame = Uint8List.fromList(buffer.sublist(0, total));
          buffer.removeRange(0, total);
          unawaited(_respond(client, frame));
        }
      },
      onDone: () => _clients.remove(client),
      onError: (_) => _clients.remove(client),
      cancelOnError: true,
    );
  }

  Future<void> _respond(Socket client, Uint8List frame) async {
    if (dropNextRequests > 0) {
      dropNextRequests--;
      return;
    }
    final unit = frame[6];
    if (unitId != null && unit != unitId) return;
    final response = _logic.handle(Uint8List.sublistView(frame, 7));
    if (responseDelay > Duration.zero) await Future<void>.delayed(responseDelay);
    final length = response.length + 1;
    final out = Uint8List(7 + response.length)
      ..[0] = frame[0]
      ..[1] = frame[1]
      ..[2] = 0
      ..[3] = 0
      ..[4] = (length >> 8) & 0xFF
      ..[5] = length & 0xFF
      ..[6] = unit
      ..setRange(7, 7 + response.length, response);
    try {
      client.add(out);
    } catch (_) {}
  }
}
