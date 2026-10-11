import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'modbus_framing.dart';
import 'modbus_memory.dart';

/// Escravo Modbus **RTU/ASCII sobre TCP**, em Dart — o que um gateway
/// serial→Ethernet faz com um CLP do outro lado.
///
/// Existe para os testes: o [ModbusClientSerial] real conversa com ele por
/// socket de verdade (CRC, LRC, fim de quadro pelo código da função, eco).
/// Para testar com ferramentas de mercado use o pymodbus de `sim/` com
/// `framer=rtu` (ver docs/SIMULACAO.md).
class ModbusSerialTcpServer {
  ModbusSerialTcpServer(this.memory, {this.framing = ModbusFraming.rtu, this.unitId = 1, this.echo = false})
      : _logic = ModbusServerLogic(memory);

  final ModbusMemory memory;
  final ModbusFraming framing;
  final int unitId;

  /// Devolve o pedido antes da resposta, como um adaptador RS-485 com eco.
  final bool echo;
  final ModbusServerLogic _logic;

  /// Gancho de teste: corrompe o CRC/LRC da próxima resposta.
  bool corruptNext = false;

  ServerSocket? _server;
  final List<Socket> _clients = [];

  int get port => _server!.port;

  Future<void> start({int port = 0, String address = '127.0.0.1'}) async {
    _server = await ServerSocket.bind(address, port);
    _server!.listen(_onClient);
  }

  Future<void> stop() async {
    for (final c in List<Socket>.of(_clients)) {
      c.destroy();
    }
    _clients.clear();
    await _server?.close();
    _server = null;
  }

  void _onClient(Socket client) {
    _clients.add(client);
    final buf = <int>[];
    client.listen(
      (data) {
        buf.addAll(data);
        while (true) {
          final end = framing == ModbusFraming.rtu ? _rtuRequestLength(buf) : ModbusFrames.asciiFrameEnd(buf);
          if (end == null || buf.length < end) break;
          final frame = buf.sublist(0, end);
          buf.removeRange(0, end);
          _respond(client, frame);
        }
      },
      onDone: () => _clients.remove(client),
      onError: (_) => _clients.remove(client),
      cancelOnError: true,
    );
  }

  /// Tamanho do pedido RTU: leituras e escritas simples têm 8 bytes; as
  /// múltiplas, 7 + contagem de bytes + CRC.
  static int? _rtuRequestLength(List<int> b) {
    if (b.length < 2) return null;
    switch (b[1]) {
      case 0x0F:
      case 0x10:
        return b.length < 7 ? null : 7 + b[6] + 2;
      default:
        return 8;
    }
  }

  void _respond(Socket client, List<int> frame) {
    try {
      final (unit, pdu) = framing == ModbusFraming.rtu ? ModbusFrames.parseRtu(frame) : ModbusFrames.parseAscii(frame);
      if (unit != unitId) return; // outro escravo da linha: silêncio
      final reply = _logic.handle(pdu);
      final out = framing == ModbusFraming.rtu ? ModbusFrames.rtu(unit, reply) : ModbusFrames.ascii(unit, reply);
      if (corruptNext) {
        corruptNext = false;
        out[out.length - (framing == ModbusFraming.rtu ? 1 : 3)] ^= 0x01;
      }
      if (echo) client.add(Uint8List.fromList(frame));
      client.add(out);
    } on FormatException {
      // Quadro com CRC/LRC errado: um escravo real simplesmente não responde.
    } catch (_) {}
  }
}
