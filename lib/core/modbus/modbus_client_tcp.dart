import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import 'modbus_client.dart';
import 'modbus_exception.dart';

/// Transporte Modbus TCP/IP sobre socket cru.
///
/// Monta o cabeçalho MBAP (7 bytes) em volta de cada PDU, casa a resposta com
/// o pedido pelo Transaction ID e reconecta sozinho se a ligação cair sem ter
/// sido pedida.
///
/// ```
///  MBAP: [TID hi][TID lo][0][0][LEN hi][LEN lo][UNIT]  +  PDU: [FC][dados…]
///         └ transação ┘ └protocolo┘ └ unit + PDU ┘
/// ```
///
/// **Um pedido por vez.** O cliente antigo permitia várias transações
/// pendentes no mesmo socket. A norma permite, mas muitos CLPs de entrada e
/// conversores serial→TCP descartam ou embaralham pedidos simultâneos. Aqui o
/// ciclo inteiro pedido→resposta roda dentro de uma trava: o próximo só sai
/// quando o anterior respondeu ou estourou o tempo-limite. O custo é latência
/// somada quando há muitos blocos — o [ScanPlanner] compensa agrupando
/// endereços vizinhos numa leitura só.
class ModbusClientTcp extends ModbusClient {
  ModbusClientTcp({
    required this.host,
    this.port = 502,
    super.unitId,
    this.responseTimeout = const Duration(seconds: 2),
    this.connectionTimeout = const Duration(seconds: 5),
    this.beforeConnect,
  });

  static final Logger _log = Logger('ModbusClientTcp');

  final String host;
  final int port;
  Duration responseTimeout;
  Duration connectionTimeout;

  /// Chamado antes de abrir o socket — o app usa para fazer a conexão sair
  /// pela rede local certa (ver `LocalNetwork.prepare`). Falha aqui não
  /// impede a tentativa: só fica no log.
  final Future<void> Function(String host)? beforeConnect;

  Socket? _socket;
  StreamSubscription<Uint8List>? _socketSub;
  final List<int> _rx = [];

  int _transactionId = 0;
  _Pending? _pending;
  final _lock = _AsyncLock();
  bool _manualDisconnect = true;

  String get _label => '$host:$port#$unitId';

  // ── Conexão ──────────────────────────────────────────────────────────────────

  @override
  Future<void> connect() async {
    if (_socket != null) return;
    _manualDisconnect = false;
    linkState = ModbusLinkState.connecting;
    try {
      _log.info('Conectando a $_label...');
      final hook = beforeConnect;
      if (hook != null) {
        try {
          await hook(host);
        } catch (e) {
          _log.warning('$_label: preparo da rede falhou: $e');
        }
      }
      final socket =
          await Socket.connect(host, port, timeout: connectionTimeout);
      socket.setOption(SocketOption.tcpNoDelay, true);
      _socket = socket;
      _socketSub = socket.listen(
        _onData,
        onError: (Object e) => _onClosed('Erro de socket: $e'),
        onDone: () => _onClosed('Conexão encerrada pelo equipamento'),
        cancelOnError: true,
      );
      linkState = ModbusLinkState.connected;
      _log.info('Conectado a $_label');
    } catch (e) {
      _socket = null;
      linkState = ModbusLinkState.lost;
      throw ModbusConnectionError('Falha ao conectar em $_label: $e', refused: _isRefused(e));
    }
  }

  /// "Conexão recusada": errno 111 no Linux/Android, 61 no macOS/iOS, 10061
  /// no Windows. O texto cobre o caso de a plataforma não dar o código.
  static bool _isRefused(Object e) {
    if (e is! SocketException) return false;
    final code = e.osError?.errorCode;
    if (code == 111 || code == 61 || code == 10061) return true;
    return '${e.osError?.message} ${e.message}'.toLowerCase().contains('refused');
  }

  @override
  Future<void> disconnect() async {
    _manualDisconnect = true;
    final socket = _socket;
    _socket = null;
    await _socketSub?.cancel();
    _socketSub = null;
    try {
      await socket?.close();
      socket?.destroy();
    } catch (_) {}
    _rx.clear();
    _failPending(const ModbusConnectionError('Desconectado'));
    linkState = ModbusLinkState.disconnected;
  }

  void _onClosed(String reason) {
    _log.warning('$_label: $reason');
    _socket?.destroy();
    _socket = null;
    _socketSub = null;
    _rx.clear();
    _failPending(ModbusConnectionError(reason));
    if (!_manualDisconnect) linkState = ModbusLinkState.lost;
  }

  void _failPending(ModbusError error) {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.completer.isCompleted) {
      pending.timer.cancel();
      pending.completer.completeError(error);
    }
  }

  // ── Transação ────────────────────────────────────────────────────────────────

  @override
  Future<Uint8List> transact(Uint8List requestPdu) {
    return _lock.synchronized(() async {
      if (_socket == null) {
        if (_manualDisconnect) {
          throw const ModbusConnectionError('Cliente desconectado');
        }
        await connect(); // reconexão automática após queda
      }
      final socket = _socket!;

      _transactionId = _transactionId >= 0xFFFF ? 1 : _transactionId + 1;
      final tid = _transactionId;
      final length = requestPdu.length + 1; // unit + PDU
      final frame = Uint8List(7 + requestPdu.length)
        ..[0] = (tid >> 8) & 0xFF
        ..[1] = tid & 0xFF
        ..[2] = 0
        ..[3] = 0
        ..[4] = (length >> 8) & 0xFF
        ..[5] = length & 0xFF
        ..[6] = unitId & 0xFF
        ..setRange(7, 7 + requestPdu.length, requestPdu);

      final completer = Completer<Uint8List>();
      // Ouvinte desde já: se a conexão cair (ou o app desconectar) enquanto o
      // pedido ainda está saindo, o erro chega antes de alguém esperar a
      // resposta — sem ouvinte, vira "erro não tratado" na zona. Quem chamou
      // recebe o erro do mesmo jeito.
      unawaited(completer.future.then<void>((_) {}, onError: (Object _) {}));
      final timer = Timer(responseTimeout, () {
        if (_pending?.tid == tid) _pending = null;
        if (!completer.isCompleted) {
          completer.completeError(ModbusTimeout(
              '$_label: sem resposta em ${responseTimeout.inMilliseconds} ms '
              '(TID $tid)'));
        }
      });
      _pending = _Pending(tid, completer, timer);

      try {
        socket.add(frame);
        await socket.flush();
      } catch (e) {
        _onClosed('Falha ao enviar: $e');
      }
      return completer.future;
    });
  }

  // ── Recepção ─────────────────────────────────────────────────────────────────

  void _onData(Uint8List data) {
    _rx.addAll(data);
    while (_rx.length >= 7) {
      final tid = (_rx[0] << 8) | _rx[1];
      final protocol = (_rx[2] << 8) | _rx[3];
      final length = (_rx[4] << 8) | _rx[5];

      // Cabeçalho impossível → fluxo dessincronizado. Descarta tudo; o
      // pedido pendente vai estourar o tempo-limite e o próximo recomeça limpo.
      if (protocol != 0 || length < 2 || length > 254) {
        _log.warning('$_label: cabeçalho MBAP inválido, descartando buffer');
        _rx.clear();
        return;
      }
      final total = 6 + length;
      if (_rx.length < total) return;

      final pdu = Uint8List.fromList(_rx.sublist(7, total));
      _rx.removeRange(0, total);

      final pending = _pending;
      if (pending == null || pending.tid != tid) {
        _log.fine('$_label: resposta atrasada/órfã (TID $tid) descartada');
        continue;
      }
      _pending = null;
      pending.timer.cancel();
      if (!pending.completer.isCompleted) pending.completer.complete(pdu);
    }
  }
}

class _Pending {
  _Pending(this.tid, this.completer, this.timer);
  final int tid;
  final Completer<Uint8List> completer;
  final Timer timer;
}

/// Trava assíncrona FIFO: uma ação por vez, na ordem de chegada.
class _AsyncLock {
  Future<void> _tail = Future.value();

  Future<T> synchronized<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }
}
