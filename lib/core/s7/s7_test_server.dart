import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 's7_address.dart';

/// Memória de um CLP S7 de mentira: DBs, M (marcadores), I (entradas) e Q
/// (saídas), em bytes, como no CLP.
class S7Memory {
  S7Memory({int inputs = 256, int outputs = 256, int flags = 256})
      : inputs = Uint8List(inputs),
        outputs = Uint8List(outputs),
        flags = Uint8List(flags);

  final Uint8List inputs;
  final Uint8List outputs;
  final Uint8List flags;
  final Map<int, Uint8List> _dbs = {};

  /// Cria (ou recria, zerado) o DB [number] com [size] bytes.
  void addDb(int number, int size) => _dbs[number] = Uint8List(size);

  /// Bytes da área; `null` quando o DB não existe.
  Uint8List? area(S7Area area, [int db = 0]) => switch (area) {
        S7Area.inputs => inputs,
        S7Area.outputs => outputs,
        S7Area.flags => flags,
        S7Area.db => _dbs[db],
      };

  Uint8List _bytesOf(S7Address a) {
    final mem = area(a.area, a.dbNumber);
    if (mem == null) throw StateError('DB${a.dbNumber} não existe na memória de teste');
    return mem;
  }

  /// Grava [bytes] a partir do endereço. Em endereço de bit, liga/desliga só
  /// o bit, conforme `bytes[0] != 0`.
  void poke(S7Address a, List<int> bytes) {
    final mem = _bytesOf(a);
    final bit = a.bitIndex;
    if (bit != null) {
      final mask = 1 << bit;
      mem[a.byteOffset] = bytes.first != 0 ? mem[a.byteOffset] | mask : mem[a.byteOffset] & ~mask;
      return;
    }
    mem.setRange(a.byteOffset, a.byteOffset + bytes.length, bytes);
  }

  /// Bytes do endereço (em endereço de bit, o byte inteiro onde ele mora).
  Uint8List peek(S7Address a) => Uint8List.fromList(_bytesOf(a).sublist(a.byteOffset, a.endByte));

  bool bit(S7Address a) => (_bytesOf(a)[a.byteOffset] >> (a.bitIndex ?? 0)) & 1 == 1;
}

/// Servidor S7 mínimo, em Dart — um "CLP" para os testes de integração.
///
/// Fala o mesmo subconjunto do [S7Client]: TPKT, COTP CR/CC, Setup
/// Communication, Read Var e Write Var (vários itens, bit e bytes), em DBs e
/// nas áreas M, I e Q. Sobe numa porta local e o cliente de produção
/// conversa com ele por socket de verdade. Escrito à parte, sem usar a
/// montagem de mensagens do cliente, para que um erro de formato de um lado
/// não seja "confirmado" pelo outro. A conferência contra um servidor de
/// mercado é o `python-snap7` (ver docs/ARQUITETURA.md).
///
/// Respeita a PDU negociada como um CLP real: pedido ou resposta maior que
/// ela volta com erro 0x8500 — é assim que os testes provam que o cliente
/// divide os pedidos.
///
/// Ganchos de teste: [responseDelay] atrasa respostas, [dropNextRequests]
/// ignora leituras/escritas, [refuseJobs] recusa toda leitura/escrita (PUT/GET
/// desligado), [deniedDbs] nega acesso por item, [requiredRemoteTsap] recusa
/// rack/slot errados, [closeAllClients] derruba as conexões, e
/// [tcpChunk]/[cotpChunk] picam as respostas para provar a remontagem.
class S7TestServer {
  S7TestServer(this.memory, {this.pduSize = 480, this.requiredRemoteTsap});

  final S7Memory memory;

  /// Maior PDU que este "CLP" aceita no Setup Communication.
  final int pduSize;

  /// Se definido, só aceita a conexão ISO com este TSAP de destino; com
  /// outro, derruba a conexão — como uma CPU que não está naquele rack/slot.
  final int? requiredRemoteTsap;

  Duration responseDelay = Duration.zero;
  int dropNextRequests = 0;

  /// PUT/GET desligado: toda leitura/escrita volta com erro 0x81/0x04
  /// ("função não disponível") no cabeçalho, como no S7-1200/1500 de fábrica.
  bool refuseJobs = false;

  /// DBs que respondem "acesso negado" (0x03) por item.
  final Set<int> deniedDbs = {};

  /// Manda cada resposta em pedaços de N bytes no TCP.
  int? tcpChunk;

  /// Divide cada mensagem S7 em vários COTP DT de N bytes.
  int? cotpChunk;

  /// Leitura de bit devolve o byte inteiro (transporte BYTE), como o
  /// servidor do python-snap7 — uma CPU real devolve só o bit.
  bool bitReadsAsByte = false;

  /// Conexões ISO aceitas (sobe na reconexão).
  int connections = 0;
  int readJobs = 0;
  int writeJobs = 0;

  /// Quantos itens veio em cada leitura, na ordem.
  final List<int> readItemCounts = [];

  /// TSAP de destino do último pedido de conexão.
  int? lastRemoteTsap;

  ServerSocket? _server;
  final List<Socket> _clients = [];

  int get port => _server!.port;
  int get clientCount => _clients.length;

  /// Porta 0 = o sistema escolhe uma livre (testes em paralelo).
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

  void _onClient(Socket socket) {
    _clients.add(socket);
    final conn = _Conn(socket);
    socket.listen(
      (data) {
        conn.rx.addAll(data);
        while (conn.rx.length >= 4) {
          final length = (conn.rx[2] << 8) | conn.rx[3];
          if (conn.rx[0] != 0x03 || length < 5) {
            conn.rx.clear();
            return;
          }
          if (conn.rx.length < length) break;
          final tpdu = Uint8List.fromList(conn.rx.sublist(4, length));
          conn.rx.removeRange(0, length);
          // Uma mensagem por vez por conexão, na ordem, como uma CPU.
          conn.queue = conn.queue.then((_) => _onTpdu(conn, tpdu)).catchError((_) {});
        }
      },
      onDone: () => _clients.remove(socket),
      onError: (_) => _clients.remove(socket),
      cancelOnError: true,
    );
  }

  Future<void> _onTpdu(_Conn conn, Uint8List t) async {
    if (t.length < 2) return;
    final headerLength = t[0] + 1;
    switch (t[1] & 0xF0) {
      case 0xE0:
        _onConnectionRequest(conn, t, headerLength);
      case 0xF0:
        if (t.length < 3) return;
        conn.fragment.add(t.sublist(headerLength));
        if (t[2] & 0x80 != 0) await _onJob(conn, conn.fragment.takeBytes());
    }
  }

  void _onConnectionRequest(_Conn conn, Uint8List t, int headerLength) {
    // Parâmetros depois de: LI, tipo, ref. destino (2), ref. origem (2), classe.
    var localTsap = 0;
    var remoteTsap = 0;
    for (var p = 7; p + 1 < headerLength;) {
      final code = t[p];
      final len = t[p + 1];
      if (code == 0xC1 && len == 2) localTsap = (t[p + 2] << 8) | t[p + 3];
      if (code == 0xC2 && len == 2) remoteTsap = (t[p + 2] << 8) | t[p + 3];
      p += 2 + len;
    }
    lastRemoteTsap = remoteTsap;
    final required = requiredRemoteTsap;
    if (required != null && remoteTsap != required) {
      conn.socket.destroy(); // a CPU não existe ali: muita CPU simplesmente fecha
      return;
    }
    connections++;
    _sendRaw(conn, _tpkt([
      0x11, 0xD0,
      t[4], t[5], // referência de destino = a de origem do cliente
      0x00, 0x0C, // a nossa
      0x00,
      0xC0, 0x01, 0x0A,
      0xC1, 0x02, (localTsap >> 8) & 0xFF, localTsap & 0xFF,
      0xC2, 0x02, (remoteTsap >> 8) & 0xFF, remoteTsap & 0xFF,
    ]));
  }

  Future<void> _onJob(_Conn conn, Uint8List s7) async {
    if (s7.length < 10 || s7[0] != 0x32 || s7[1] != 0x01) return;
    final ref = (s7[4] << 8) | s7[5];
    final paramLength = (s7[6] << 8) | s7[7];
    final dataLength = (s7[8] << 8) | s7[9];
    if (s7.length < 10 + paramLength + dataLength || paramLength < 2) return;
    final param = s7.sublist(10, 10 + paramLength);
    final data = s7.sublist(10 + paramLength, 10 + paramLength + dataLength);
    final function = param[0];

    if (function == 0xF0) {
      final requested = paramLength >= 8 ? (param[6] << 8) | param[7] : pduSize;
      conn.pdu = requested < pduSize ? requested : pduSize;
      await _reply(conn, ref, [0xF0, 0x00, 0x00, 0x01, 0x00, 0x01, (conn.pdu >> 8) & 0xFF, conn.pdu & 0xFF], const []);
      return;
    }
    if (function != 0x04 && function != 0x05) {
      await _reply(conn, ref, const [], const [], errorClass: 0x81, errorCode: 0x04);
      return;
    }
    if (function == 0x04) {
      readJobs++;
      readItemCounts.add(param[1]);
    } else {
      writeJobs++;
    }
    if (dropNextRequests > 0) {
      dropNextRequests--;
      return;
    }
    if (refuseJobs) {
      await _reply(conn, ref, const [], const [], errorClass: 0x81, errorCode: 0x04);
      return;
    }
    if (s7.length > conn.pdu) {
      await _reply(conn, ref, const [], const [], errorClass: 0x85, errorCode: 0x00);
      return;
    }
    final items = _items(param);
    if (items == null) {
      await _reply(conn, ref, const [], const [], errorClass: 0x84, errorCode: 0x01);
      return;
    }
    if (function == 0x04) {
      await _read(conn, ref, items);
    } else {
      await _write(conn, ref, items, data);
    }
  }

  /// Itens S7ANY do parâmetro; `null` se algum não for S7ANY.
  static List<_Item>? _items(Uint8List param) {
    final count = param[1];
    if (param.length < 2 + 12 * count) return null;
    final out = <_Item>[];
    for (var k = 0; k < count; k++) {
      final p = 2 + 12 * k;
      if (param[p] != 0x12 || param[p + 1] != 0x0A || param[p + 2] != 0x10) return null;
      out.add(_Item(
        transport: param[p + 3],
        count: (param[p + 4] << 8) | param[p + 5],
        db: (param[p + 6] << 8) | param[p + 7],
        area: param[p + 8],
        address: (param[p + 9] << 16) | (param[p + 10] << 8) | param[p + 11],
      ));
    }
    return out;
  }

  /// Memória do item, ou o código de erro do item.
  (Uint8List?, int) _memoryFor(_Item it) {
    switch (it.area) {
      case 0x81:
        return (memory.inputs, 0xFF);
      case 0x82:
        return (memory.outputs, 0xFF);
      case 0x83:
        return (memory.flags, 0xFF);
      case 0x84:
        if (deniedDbs.contains(it.db)) return (null, 0x03);
        final db = memory.area(S7Area.db, it.db);
        return db == null ? (null, 0x0A) : (db, 0xFF);
      default:
        return (null, 0x0A);
    }
  }

  static int? _elementSize(int transport) => switch (transport) {
        0x02 || 0x03 => 1, // BYTE, CHAR
        0x04 || 0x05 => 2, // WORD, INT
        0x06 || 0x07 || 0x08 => 4, // DWORD, DINT, REAL
        _ => null,
      };

  Future<void> _read(_Conn conn, int ref, List<_Item> items) async {
    final data = <int>[];
    for (var k = 0; k < items.length; k++) {
      final it = items[k];
      final (mem, code) = _memoryFor(it);
      var item = <int>[code == 0xFF ? 0x05 : code, 0x00, 0x00, 0x00];
      if (mem != null) {
        final start = it.address >> 3;
        if (it.transport == 0x01) {
          if (it.count == 1 && start < mem.length) {
            item = bitReadsAsByte
                ? [0xFF, 0x04, 0x00, 0x08, mem[start]]
                : [0xFF, 0x03, 0x00, 0x01, (mem[start] >> (it.address & 7)) & 1];
          }
        } else {
          final size = _elementSize(it.transport);
          if (size == null) {
            item = [0x06, 0x00, 0x00, 0x00];
          } else {
            final n = it.count * size;
            if (it.address & 7 == 0 && start + n <= mem.length) {
              final bits = n * 8;
              item = [0xFF, 0x04, (bits >> 8) & 0xFF, bits & 0xFF, ...mem.sublist(start, start + n)];
            }
          }
        }
      }
      data.addAll(item);
      final payload = item.length - 4;
      if (payload.isOdd && k < items.length - 1) data.add(0x00);
    }
    // Resposta maior que a PDU: o CLP recusa o pedido inteiro.
    if (12 + 2 + data.length > conn.pdu) {
      await _reply(conn, ref, const [], const [], errorClass: 0x85, errorCode: 0x00);
      return;
    }
    await _reply(conn, ref, [0x04, items.length], data);
  }

  Future<void> _write(_Conn conn, int ref, List<_Item> items, Uint8List data) async {
    final codes = <int>[];
    var p = 0;
    for (var k = 0; k < items.length; k++) {
      if (p + 4 > data.length) {
        codes.add(0x07);
        continue;
      }
      final ts = data[p + 1];
      final raw = (data[p + 2] << 8) | data[p + 3];
      final n = ts == 0x03 || ts == 0x04 || ts == 0x05 ? (raw + 7) >> 3 : raw;
      final payload = data.sublist(p + 4, (p + 4 + n).clamp(0, data.length));
      p += 4 + n;
      if (n.isOdd && k < items.length - 1) p++;

      final it = items[k];
      final (mem, code) = _memoryFor(it);
      if (mem == null) {
        codes.add(code);
        continue;
      }
      final start = it.address >> 3;
      if (it.transport == 0x01) {
        if (ts != 0x03 || payload.length != 1) {
          codes.add(0x07);
        } else if (it.count != 1 || start >= mem.length) {
          codes.add(0x05);
        } else {
          final mask = 1 << (it.address & 7);
          mem[start] = payload[0] & 1 == 1 ? mem[start] | mask : mem[start] & ~mask;
          codes.add(0xFF);
        }
        continue;
      }
      final size = _elementSize(it.transport);
      if (size == null) {
        codes.add(0x06);
      } else if (payload.length != it.count * size) {
        codes.add(0x07);
      } else if (it.address & 7 != 0 || start + payload.length > mem.length) {
        codes.add(0x05);
      } else {
        mem.setRange(start, start + payload.length, payload);
        codes.add(0xFF);
      }
    }
    await _reply(conn, ref, [0x05, items.length], codes);
  }

  /// Ack_Data: cabeçalho de 12 bytes (com classe/código de erro) +
  /// parâmetros + dados, dentro de COTP DT e TPKT.
  Future<void> _reply(_Conn conn, int ref, List<int> param, List<int> data,
      {int errorClass = 0, int errorCode = 0}) async {
    if (responseDelay > Duration.zero) await Future<void>.delayed(responseDelay);
    final s7 = [
      0x32, 0x03, 0x00, 0x00,
      (ref >> 8) & 0xFF, ref & 0xFF,
      (param.length >> 8) & 0xFF, param.length & 0xFF,
      (data.length >> 8) & 0xFF, data.length & 0xFF,
      errorClass, errorCode,
      ...param,
      ...data,
    ];
    final piece = cotpChunk ?? s7.length;
    final out = BytesBuilder();
    for (var off = 0; off < s7.length; off += piece) {
      final end = off + piece < s7.length ? off + piece : s7.length;
      out.add(_tpkt([0x02, 0xF0, end == s7.length ? 0x80 : 0x00, ...s7.sublist(off, end)]));
    }
    final bytes = out.takeBytes();
    final chunk = tcpChunk;
    if (chunk == null) {
      _sendRaw(conn, bytes);
      return;
    }
    for (var off = 0; off < bytes.length; off += chunk) {
      _sendRaw(conn, bytes.sublist(off, off + chunk < bytes.length ? off + chunk : bytes.length));
      try {
        await conn.socket.flush();
      } catch (_) {}
      // Pausa curta para os pedaços chegarem em segmentos TCP separados.
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  static Uint8List _tpkt(List<int> payload) {
    final total = payload.length + 4;
    return Uint8List.fromList([0x03, 0x00, (total >> 8) & 0xFF, total & 0xFF, ...payload]);
  }

  void _sendRaw(_Conn conn, List<int> bytes) {
    try {
      conn.socket.add(bytes);
    } catch (_) {}
  }
}

class _Conn {
  _Conn(this.socket);
  final Socket socket;
  final List<int> rx = [];
  final BytesBuilder fragment = BytesBuilder();
  Future<void> queue = Future.value();

  /// PDU negociada nesta conexão (antes do Setup Communication, a mínima).
  int pdu = 240;
}

class _Item {
  const _Item({required this.transport, required this.count, required this.db, required this.area, required this.address});
  final int transport;
  final int count;
  final int db;
  final int area;

  /// Endereço em bits (byte × 8 + bit).
  final int address;
}
