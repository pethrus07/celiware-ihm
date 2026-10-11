import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../link/byte_link.dart';
import 'modbus_client.dart';
import 'modbus_exception.dart';
import 'modbus_framing.dart';

/// Modbus RTU ou ASCII sobre um [ByteLink] — RS-485 por USB, ou um gateway
/// serial→Ethernet que repassa os bytes crus pelo TCP ("RTU sobre TCP").
///
/// As funções Modbus são as mesmas do TCP (vêm de [ModbusClient]); aqui só
/// muda o envelope ([ModbusFrames]) e como se acha o fim da resposta: em RTU,
/// pelo código da função (não há cabeçalho de tamanho); em ASCII, pelo fim de
/// linha. Um pedido por vez, como no TCP — numa linha RS-485 isso é
/// obrigatório, não só prudência.
///
/// [discardEcho]: alguns adaptadores RS-485 devolvem o que acabou de ser
/// enviado. Ligado, os primeiros bytes de cada resposta (o tamanho do pedido)
/// são descartados.
class ModbusClientSerial extends ModbusClient {
  ModbusClientSerial({
    required this.link,
    this.framing = ModbusFraming.rtu,
    super.unitId,
    this.responseTimeout = const Duration(seconds: 2),
    this.discardEcho = false,
    this.label = 'serial',
  });

  static final Logger _log = Logger('ModbusClientSerial');

  final ByteLink link;
  final ModbusFraming framing;
  Duration responseTimeout;
  final bool discardEcho;

  /// Para o log ("192.168.0.50:4001", "USB CH340").
  final String label;

  StreamSubscription<Uint8List>? _sub;
  final List<int> _rx = [];
  int _echoLeft = 0;
  Completer<Uint8List>? _pending;
  Timer? _timer;
  final _lock = _AsyncLock();
  bool _manualDisconnect = true;

  // ── Conexão ──────────────────────────────────────────────────────────────────

  @override
  Future<void> connect() async {
    if (link.isOpen) return;
    _manualDisconnect = false;
    linkState = ModbusLinkState.connecting;
    try {
      link.onClosed = _onClosed;
      await link.open();
      await _sub?.cancel();
      _sub = link.input.listen(_onData);
      linkState = ModbusLinkState.connected;
      _log.info('Conectado a $label (${framing.label})');
    } catch (e) {
      linkState = ModbusLinkState.lost;
      if (e is ModbusError) rethrow;
      throw ModbusConnectionError('Falha ao abrir $label: $e', refused: isConnectionRefused(e));
    }
  }

  @override
  Future<void> disconnect() async {
    _manualDisconnect = true;
    await _sub?.cancel();
    _sub = null;
    await link.close();
    _rx.clear();
    _fail(const ModbusConnectionError('Desconectado'));
    linkState = ModbusLinkState.disconnected;
  }

  void _onClosed(String reason) {
    _log.warning('$label: $reason');
    _rx.clear();
    _fail(ModbusConnectionError(reason));
    if (!_manualDisconnect) linkState = ModbusLinkState.lost;
  }

  void _fail(ModbusError error) {
    final p = _pending;
    _pending = null;
    _timer?.cancel();
    if (p != null && !p.isCompleted) p.completeError(error);
  }

  // ── Transação ────────────────────────────────────────────────────────────────

  @override
  Future<Uint8List> transact(Uint8List requestPdu) {
    return _lock.synchronized(() async {
      if (!link.isOpen) {
        if (_manualDisconnect) throw const ModbusConnectionError('Cliente desconectado');
        await connect(); // reconexão automática após queda
      }
      final frame = framing == ModbusFraming.rtu ? ModbusFrames.rtu(unitId, requestPdu) : ModbusFrames.ascii(unitId, requestPdu);
      _rx.clear(); // sobra de resposta atrasada não pode casar com este pedido
      _echoLeft = discardEcho ? frame.length : 0;
      final completer = Completer<Uint8List>();
      _pending = completer;
      _timer = Timer(responseTimeout, () {
        if (identical(_pending, completer)) _pending = null;
        if (!completer.isCompleted) {
          completer.completeError(ModbusTimeout('$label: sem resposta em ${responseTimeout.inMilliseconds} ms'));
        }
      });
      try {
        await link.write(frame);
      } catch (e) {
        _onClosed('falha ao enviar: $e');
      }
      return completer.future;
    });
  }

  // ── Recepção ─────────────────────────────────────────────────────────────────

  void _onData(Uint8List data) {
    _rx.addAll(data);
    if (_echoLeft > 0) {
      final n = _echoLeft < _rx.length ? _echoLeft : _rx.length;
      _rx.removeRange(0, n);
      _echoLeft -= n;
    }
    final pending = _pending;
    if (pending == null) {
      _rx.clear(); // ninguém esperando: resposta órfã
      return;
    }
    final int? end = framing == ModbusFraming.rtu ? ModbusFrames.rtuResponseLength(_rx) : ModbusFrames.asciiFrameEnd(_rx);
    if (end == null || _rx.length < end) return;
    final frame = _rx.sublist(0, end);
    _rx.removeRange(0, end);
    try {
      final (unit, pdu) = framing == ModbusFraming.rtu ? ModbusFrames.parseRtu(frame) : ModbusFrames.parseAscii(frame);
      if (unit != unitId && unitId != 0) {
        _log.fine('$label: resposta de outro escravo ($unit) descartada');
        return;
      }
      _pending = null;
      _timer?.cancel();
      if (!pending.isCompleted) pending.complete(pdu);
    } on FormatException catch (e) {
      _rx.clear();
      _fail(ModbusProtocolError('$label: ${e.message}'));
    }
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await super.dispose();
  }
}

/// "Conexão recusada": errno 111 (Linux/Android), 61 (macOS/iOS), 10061
/// (Windows) — o aparelho existe, mas nada escuta na porta.
bool isConnectionRefused(Object e) {
  if (e is! SocketException) return false;
  final code = e.osError?.errorCode;
  if (code == 111 || code == 61 || code == 10061) return true;
  return '${e.osError?.message} ${e.message}'.toLowerCase().contains('refused');
}

class _AsyncLock {
  Future<void> _tail = Future.value();

  Future<T> synchronized<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }
}
