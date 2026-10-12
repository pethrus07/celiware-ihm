import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../comm/comm_error.dart';
import '../link/byte_link.dart';
import '../serial/serial_params.dart';
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
/// **Linha serial de verdade** ([SerialLink], o cabo USB). Além do tamanho
/// esperado, o tempo entre caracteres vem da velocidade (RT-2):
///   • antes de cada pedido a linha fica quieta 3,5 caracteres (t3.5 da
///     norma) — escravo lento junta o pedido novo com o fim do anterior;
///   • no meio de uma resposta, pausa maior que t3.5 + a folga do USB
///     ([usbSlack]) quer dizer que o que veio antes não continua: é ruído ou
///     quadro cortado, e sai. Só o silêncio não serve para fechar o quadro —
///     o adaptador entrega os bytes em pacotes, com pausas maiores que t3.5
///     dentro da mesma resposta; por isso o fim continua sendo o tamanho;
///   • a pausa é medida onde os bytes chegam (leitura do USB), não quando o
///     Dart os vê ([SerialChunk.gapBefore]);
///   • a linha é dividida entre os equipamentos dela: o pedido e a resposta
///     acontecem dentro de [SerialLink.exclusive].
///
/// **Ressincronia.** A resposta RTU começa com o ID do escravo e a função
/// pedida (ou a exceção dela); o que vem antes disso — o byte espúrio que
/// alguns transceptores RS-485 soltam ao virar a linha, sobra de outro
/// quadro — é descartado. No ASCII, tudo antes do ':'. Se no fim do prazo
/// chegaram bytes mas nenhum formou resposta, o erro diz isso
/// ([ModbusProtocolError.garbled]): é o sinal clássico de velocidade ou
/// paridade diferente nos dois lados — "sem resposta" mandaria conferir os
/// fios à toa.
///
/// **Eco.** Adaptador RS-485 de 2 fios com eco devolve o que acabou de ser
/// enviado. [discardEcho] força o descarte desde o primeiro pedido; sem ele,
/// uma leitura cujo começo é exatamente o pedido revela o eco e daí em
/// diante ele é descartado sozinho (só leitura serve de prova: em FC05/06 a
/// resposta normal é igual ao pedido). Bytes que não batem com o pedido
/// nunca são jogados fora como eco — são a resposta.
class ModbusClientSerial extends ModbusClient {
  ModbusClientSerial({
    required this.link,
    this.framing = ModbusFraming.rtu,
    super.unitId,
    this.responseTimeout = const Duration(seconds: 2),
    this.discardEcho = false,
    this.label = 'serial',
    this.usbSlack = const Duration(milliseconds: 20),
  });

  static final Logger _log = Logger('ModbusClientSerial');

  final ByteLink link;
  final ModbusFraming framing;
  Duration responseTimeout;
  final bool discardEcho;

  /// Para o log ("192.168.0.50:4001", "USB CH340").
  final String label;

  /// Folga somada aos 3,5 caracteres no meio de uma resposta: o adaptador
  /// junta os bytes em pacotes (o FTDI de fábrica manda a cada 16 ms; o lado
  /// Android pede 1 ms a ele) e o Android lê em blocos.
  final Duration usbSlack;

  StreamSubscription<Object>? _sub;
  final List<int> _rx = [];
  Completer<Uint8List>? _pending;
  Timer? _timer;
  final _lock = _AsyncLock();
  bool _manualDisconnect = true;

  /// O pedido enviado, enquanto ainda pode voltar como eco.
  Uint8List? _echo;
  bool _echoLearned = false;

  /// A função pedida: a resposta começa com ela (ou com ela | 0x80).
  int _expectFc = 0;

  /// Bytes descartados nesta transação por não formarem resposta.
  int _garbage = 0;
  DateTime? _lastRxAt;
  bool _afterTimeout = false;

  SerialLink? get _line => link is SerialLink ? link as SerialLink : null;

  /// O adaptador devolve o que o app manda (percebido numa leitura).
  bool get echoDetected => _echoLearned;

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
      final line = _line;
      _sub = line != null ? line.chunks.listen((c) => _onData(c.bytes, c.gapBefore)) : link.input.listen(_onData);
      _echoLearned = false;
      _lastRxAt = null;
      _afterTimeout = false;
      linkState = ModbusLinkState.connected;
      _log.info('Conectado a $label (${framing.label}${line != null ? ' · ${line.params.label}' : ''})');
    } catch (e) {
      linkState = ModbusLinkState.lost;
      // Erro que já tem nome (adaptador USB não encontrado, sem permissão)
      // passa como está: "sem conexão" esconderia o que conferir.
      if (e is CommError) rethrow;
      throw ModbusConnectionError('Falha ao abrir $label: $e', refused: isConnectionRefused(e));
    }
  }

  @override
  Future<void> disconnect() async {
    _manualDisconnect = true;
    await _sub?.cancel();
    _sub = null;
    _rx.clear();
    // Antes de fechar: o pedido no ar libera a fila da linha dividida já,
    // sem esperar o tempo-limite.
    _fail(const ModbusConnectionError('Desconectado'));
    await link.close();
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
      final line = _line;
      if (line == null) return _exchange(requestPdu, null);
      return line.exclusive(() => _exchange(requestPdu, line.params));
    });
  }

  Future<Uint8List> _exchange(Uint8List requestPdu, SerialParams? line) async {
    final frame = framing == ModbusFraming.rtu ? ModbusFrames.rtu(unitId, requestPdu) : ModbusFrames.ascii(unitId, requestPdu);
    if (line != null && framing == ModbusFraming.rtu) await _quietLine(line);
    _rx.clear(); // sobra de resposta atrasada não pode casar com este pedido
    _garbage = 0;
    _expectFc = requestPdu.isEmpty ? 0 : requestPdu[0];
    final read = _expectFc >= 0x01 && _expectFc <= 0x04;
    _echo = discardEcho || _echoLearned || read ? frame : null;
    final completer = Completer<Uint8List>();
    // Ouvinte desde já: se a conexão cair (ou o app desconectar) enquanto o
    // pedido ainda está saindo, o erro chega antes de alguém esperar a
    // resposta — sem ouvinte, vira "erro não tratado" na zona. Quem chamou
    // recebe o erro do mesmo jeito.
    unawaited(completer.future.then<void>((_) {}, onError: (Object _) {}));
    _pending = completer;
    _timer = Timer(responseTimeout, () {
      if (identical(_pending, completer)) _pending = null;
      if (completer.isCompleted) return;
      _afterTimeout = true;
      final heard = _garbage + (_echo == null ? _rx.length : 0);
      _rx.clear();
      completer.completeError(heard > 0
          ? ModbusProtocolError('$label: $heard bytes sem formar resposta em ${responseTimeout.inMilliseconds} ms', garbled: true)
          : ModbusTimeout('$label: sem resposta em ${responseTimeout.inMilliseconds} ms'));
    });
    try {
      await link.write(frame);
    } catch (e) {
      _onClosed('falha ao enviar: $e');
    }
    return completer.future;
  }

  /// Antes do pedido, a linha quieta por 3,5 caracteres desde o último byte
  /// recebido. Depois de um tempo esgotado, um pouco mais: a resposta
  /// atrasada do pedido anterior chega nesse meio-tempo e é descartada (ela
  /// tem o mesmo formato — viraria a resposta deste pedido).
  Future<void> _quietLine(SerialParams p) async {
    final quiet = _afterTimeout ? p.t35 + usbSlack * 2 : p.t35;
    _afterTimeout = false;
    final since = _lastRxAt == null ? quiet : DateTime.now().difference(_lastRxAt!);
    final wait = quiet - since;
    // O timer conta em milissegundos inteiros: arredonda para cima, nunca
    // menos que t3.5.
    if (wait > Duration.zero) await Future<void>.delayed(Duration(milliseconds: (wait.inMicroseconds / 1000).ceil()));
  }

  /// Pausa máxima no meio de uma resposta (ver [usbSlack]). No ASCII a norma
  /// aceita até 1 s entre caracteres.
  Duration _interCharLimit(SerialParams p) => framing == ModbusFraming.ascii ? const Duration(seconds: 1) : p.t35 + usbSlack;

  // ── Recepção ─────────────────────────────────────────────────────────────────

  void _onData(Uint8List data, [Duration? gapBefore]) {
    _lastRxAt = DateTime.now();
    final pending = _pending;
    if (pending == null) {
      _rx.clear(); // ninguém esperando: resposta órfã
      return;
    }
    final line = _line;
    if (line != null && gapBefore != null && _rx.isNotEmpty && _echo == null && gapBefore > _interCharLimit(line.params)) {
      // Pausa longa no meio de um quadro: o começo dele não continua aqui.
      _garbage += _rx.length;
      _rx.clear();
    }
    _rx.addAll(data);
    if (!_consumeEcho()) return;
    if (framing == ModbusFraming.rtu) {
      _parseRtu(pending);
    } else {
      _parseAscii(pending);
    }
  }

  /// Tira o eco do começo, se for ele. Falso = ainda não dá para saber (os
  /// bytes que chegaram batem com o começo do pedido): espera mais.
  bool _consumeEcho() {
    final e = _echo;
    if (e == null) return true;
    final n = min(_rx.length, e.length);
    for (var i = 0; i < n; i++) {
      if (_rx[i] != e[i]) {
        _echo = null; // não é eco: é a resposta
        return true;
      }
    }
    if (_rx.length < e.length) return false;
    _rx.removeRange(0, e.length);
    _echo = null;
    if (!discardEcho && !_echoLearned) {
      _echoLearned = true;
      _log.info('$label: o adaptador devolve o que o app manda (eco) — descartado daqui em diante');
    }
    return true;
  }

  bool get _anyUnit => unitId == 0;

  /// A resposta RTU começa com o ID do escravo e a função pedida (ou a
  /// exceção dela).
  bool _plausibleRtuStart() {
    if (!_anyUnit && _rx[0] != unitId) return false;
    if (_rx.length < 2 || _expectFc == 0) return true;
    final fc = _rx[1];
    return fc == _expectFc || fc == (_expectFc | 0x80);
  }

  void _parseRtu(Completer<Uint8List> pending) {
    while (_rx.isNotEmpty) {
      if (!_plausibleRtuStart()) {
        _rx.removeAt(0);
        _garbage++;
        continue;
      }
      final end = ModbusFrames.rtuResponseLength(_rx);
      if (end == null || _rx.length < end) return; // espera o resto do quadro
      final frame = _rx.sublist(0, end);
      _rx.removeRange(0, end);
      try {
        final (_, pdu) = ModbusFrames.parseRtu(frame);
        _complete(pending, pdu);
      } on FormatException catch (e) {
        _rx.clear();
        _fail(ModbusProtocolError('$label: ${e.message}'));
      }
      return;
    }
  }

  void _parseAscii(Completer<Uint8List> pending) {
    while (_rx.isNotEmpty) {
      final start = _rx.indexOf(0x3A); // ':'
      if (start < 0) {
        _garbage += _rx.length;
        _rx.clear();
        return;
      }
      if (start > 0) {
        _garbage += start;
        _rx.removeRange(0, start);
      }
      final end = ModbusFrames.asciiFrameEnd(_rx);
      if (end == null) return;
      final frame = _rx.sublist(0, end);
      _rx.removeRange(0, end);
      try {
        final (unit, pdu) = ModbusFrames.parseAscii(frame);
        if (unit != unitId && !_anyUnit) {
          _log.fine('$label: resposta de outro escravo ($unit) descartada');
          continue;
        }
        _complete(pending, pdu);
      } on FormatException catch (e) {
        _rx.clear();
        _fail(ModbusProtocolError('$label: ${e.message}'));
      }
      return;
    }
  }

  void _complete(Completer<Uint8List> pending, Uint8List pdu) {
    _pending = null;
    _timer?.cancel();
    if (!pending.isCompleted) pending.complete(pdu);
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
