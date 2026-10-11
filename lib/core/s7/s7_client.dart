import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

// O estado da ligação é o mesmo para todos os protocolos (o contrato do
// DeviceDriver usa este enum); o nome ficou da época em que só havia Modbus.
import '../modbus/modbus_client.dart' show ModbusLinkState;
import 's7_address.dart';
import 's7_codec.dart';
import 's7_error.dart';
import 's7_pdu.dart';

/// Tipo de conexão no TSAP de destino. PG (programadora) é o que o Snap7 e
/// o S7.Net usam por padrão e o que toda CPU aceita; OP e "S7 básico"
/// existem para CPUs com poucas conexões de PG livres.
enum S7ConnectionType {
  pg(0x01),
  op(0x02),
  basic(0x03);

  const S7ConnectionType(this.code);
  final int code;
}

/// Rack e slot de fábrica por família (matriz do python-snap7). No S7-400
/// o slot depende de onde a CPU está no bastidor; 3 é o mais comum.
enum S7Cpu {
  s7300('S7-300', 0, 2),
  s7400('S7-400', 0, 3),
  s71200('S7-1200', 0, 1),
  s71500('S7-1500', 0, 1);

  const S7Cpu(this.label, this.rack, this.slot);
  final String label;
  final int rack;
  final int slot;
}

/// Resultado de um endereço numa leitura de vários: os bytes ou o erro
/// daquele item.
class S7ReadResult {
  const S7ReadResult(this.address, this.bytes, this.error);

  final S7Address address;

  /// Bytes lidos (big-endian, como no CLP). Endereço de bit vem como 1 byte,
  /// 0 ou 1. `null` quando o item falhou.
  final Uint8List? bytes;

  final S7ItemError? error;

  bool get ok => error == null;

  /// Valor já decodificado; lança o [error] se o item falhou.
  Object value([S7Type? type]) {
    final e = error;
    if (e != null) throw e;
    return S7Codec.decode(S7Client.typeFor(address, type), bytes!);
  }
}

/// Um endereço e os bytes a gravar nele.
class S7WriteItem {
  /// [bytes] tem o tamanho do endereço; em endereço de bit, 1 byte (0 ou 1).
  S7WriteItem(this.address, Uint8List bytes) : bytes = _normalize(address, bytes);

  factory S7WriteItem.bit(S7Address address, bool value) => S7WriteItem(address, Uint8List.fromList([value ? 1 : 0]));

  /// Valor pelo codec do [type] (STRING usa o tamanho do endereço − 2 como
  /// capacidade). Lança [ArgumentError] se o valor não couber no tipo e
  /// [S7RequestError] se o tipo não couber no endereço.
  factory S7WriteItem.value(S7Address address, S7Type type, Object value) {
    final t = S7Client.typeFor(address, type);
    return S7WriteItem(address, S7Codec.encode(t, value, maxChars: address.byteLength - 2));
  }

  final S7Address address;
  final Uint8List bytes;

  static Uint8List _normalize(S7Address a, Uint8List b) {
    if (a.isBit) {
      if (b.length != 1) throw ArgumentError('$a: bit grava 1 byte (0 ou 1); vieram ${b.length}');
      return Uint8List.fromList([b[0] != 0 ? 1 : 0]);
    }
    if (b.length != a.byteLength) throw ArgumentError('$a: são ${a.byteLength} bytes; vieram ${b.length}');
    return b;
  }
}

/// Cliente Siemens S7 ("S7 clássico", PUT/GET) em Dart puro — ISO-on-TCP.
///
/// Não há cliente S7 em Dart no pub.dev, e o Snap7 é LGPL e pede compilar
/// código nativo para quatro ABIs. O subconjunto que uma IHM precisa é
/// pequeno: abrir a conexão ISO, negociar o tamanho da PDU, ler e gravar
/// variáveis. Consultados (sem copiar código): S7.Net (MIT), gos7 (BSD-3) e
/// nodeS7 (MIT).
///
/// ```
///  TCP 102 ─► COTP CR (TSAP de rack/slot) ─► CC
///          ─► Setup Communication (PDU pedida) ─► PDU aceita pelo CLP
///          ─► Read Var / Write Var, vários itens por pedido
/// ```
///
/// **Um pedido por vez**, como no `ModbusClientTcp`: o próximo só sai
/// quando o anterior respondeu ou estourou o tempo. O CLP aceita mais de um
/// em paralelo (o Setup Communication negocia quantos), mas a varredura de
/// uma IHM não ganha nada com isso e um pedido por vez é o que se prova
/// correto nos testes. Resposta atrasada de um pedido que já estourou o
/// tempo é descartada pela referência da PDU.
///
/// **Vários itens por pedido.** Uma leitura de várias variáveis vira o menor
/// número de pedidos que respeita a PDU negociada (pedido e resposta) e o
/// limite de [maxItemsPerRequest] itens; um item maior que a PDU é dividido
/// em pedaços e remontado. Item recusado pelo CLP volta como [S7ItemError]
/// só nele — os outros chegam normalmente.
///
/// **Limite conhecido:** só o S7 clássico. No S7-1200/1500 é preciso
/// habilitar PUT/GET e desligar o acesso otimizado do DB; o S7CommPlus (DB
/// otimizado, acesso simbólico) não é falado aqui.
class S7Client {
  S7Client({
    required this.host,
    this.port = 102,
    this.rack = 0,
    this.slot = 1,
    this.connectionType = S7ConnectionType.pg,
    int? localTsap,
    int? remoteTsap,
    this.requestedPduSize = 960,
    this.maxItemsPerRequest = 20,
    this.responseTimeout = const Duration(seconds: 2),
    this.connectionTimeout = const Duration(seconds: 5),
    this.beforeConnect,
  })  : localTsap = localTsap ?? 0x0100,
        remoteTsap = remoteTsap ?? _tsap(connectionType, rack, slot) {
    if (requestedPduSize < minPduSize || requestedPduSize > 0xFFFF) {
      throw ArgumentError('PDU pedida vai de $minPduSize a 65535');
    }
    if (maxItemsPerRequest < 1) throw ArgumentError('ao menos 1 item por pedido');
  }

  static final Logger _log = Logger('S7Client');

  /// Abaixo disso não cabe um item útil na PDU; nenhuma CPU real negocia
  /// menos de 240.
  static const int minPduSize = 64;

  final String host;
  final int port;
  final int rack;
  final int slot;
  final S7ConnectionType connectionType;

  /// TSAP local (0x0100 = PG). LOGO! e S7-200 usam pares próprios.
  final int localTsap;

  /// TSAP de destino: tipo de conexão no byte alto, rack × 32 + slot no
  /// baixo. Rack/slot errados = o CLP recusa a conexão ISO.
  final int remoteTsap;

  /// PDU pedida no Setup Communication; o CLP responde com o que aceita.
  final int requestedPduSize;

  /// Itens por pedido. 20 é o limite que o Snap7 usa e que as CPUs 300/400
  /// aceitam; a PDU costuma limitar antes.
  final int maxItemsPerRequest;

  Duration responseTimeout;
  Duration connectionTimeout;

  /// Chamado antes de abrir o socket — o app usa para a conexão sair pela
  /// rede local certa no Android (ver `LocalNetwork.prepare`). Falha aqui não
  /// impede a tentativa: só fica no log.
  final Future<void> Function(String host)? beforeConnect;

  final ValueNotifier<ModbusLinkState> _state = ValueNotifier(ModbusLinkState.disconnected);

  Socket? _socket;
  StreamSubscription<Uint8List>? _sub;
  final List<int> _rx = [];
  final BytesBuilder _fragment = BytesBuilder();
  Completer<bool>? _cotp;
  _Pending? _pending;
  int _ref = 0;
  int _pduSize = 0;
  bool _ready = false;
  bool _manualDisconnect = true;
  bool _disposed = false;
  final _lock = _AsyncLock();

  String get _label => '$host:$port (rack $rack, slot $slot)';

  /// Estado da ligação — a tela usa para o selo "online/sem conexão".
  ValueListenable<ModbusLinkState> get state => _state;

  bool get isConnected => _state.value == ModbusLinkState.connected;

  /// Tamanho de PDU negociado com o CLP (0 antes de conectar).
  int get pduSize => _pduSize;

  static int _tsap(S7ConnectionType type, int rack, int slot) {
    if (rack < 0 || rack > 7) throw ArgumentError('o rack vai de 0 a 7');
    if (slot < 0 || slot > 31) throw ArgumentError('o slot vai de 0 a 31');
    return (type.code << 8) | (rack * 0x20 + slot);
  }

  /// O tipo com que [address] é lido: BOOL em endereço de bit; senão [type]
  /// (ou a sugestão do endereço), que precisa caber nele. Lança
  /// [S7RequestError] quando não cabe (ex.: REAL num DBW).
  static S7Type typeFor(S7Address address, [S7Type? type]) {
    if (address.isBit) {
      if (type != null && type != S7Type.boolean) {
        throw S7RequestError('$address é um bit; ${type.label} não cabe');
      }
      return S7Type.boolean;
    }
    final t = type ?? address.suggestedType;
    if (t == S7Type.boolean) throw S7RequestError('$address não é um bit (ex.: DB1.DBX0.0)');
    if (t == S7Type.string) {
      if (address.byteLength < 3) throw S7RequestError('$address: STRING precisa de ao menos 3 bytes');
      return t;
    }
    if (t.size != address.byteLength) {
      throw S7RequestError('$address: ${t.label} ocupa ${t.size} bytes; o endereço tem ${address.byteLength}');
    }
    return t;
  }

  // ── Conexão ──────────────────────────────────────────────────────────────────

  /// Abre a conexão: TCP, COTP e Setup Communication. Lança
  /// [S7ConnectionError] (com [S7Refusal] quando o CLP recusou),
  /// [S7Timeout] ou [S7ProtocolError].
  Future<void> connect() {
    _manualDisconnect = false;
    return _lock.synchronized(_open);
  }

  Future<void> _ensureConnected() async {
    if (_ready) return;
    if (_manualDisconnect) throw const S7ConnectionError('Cliente desconectado');
    await _open(); // reconexão automática após queda
  }

  Future<void> _open() async {
    if (_ready) return;
    _setState(ModbusLinkState.connecting);
    _log.info('Conectando a $_label...');
    final hook = beforeConnect;
    if (hook != null) {
      try {
        await hook(host);
      } catch (e) {
        _log.warning('$_label: preparo da rede falhou: $e');
      }
    }
    final Socket socket;
    try {
      socket = await Socket.connect(host, port, timeout: connectionTimeout);
    } catch (e) {
      _setState(ModbusLinkState.lost);
      throw S7ConnectionError('Falha ao conectar em $_label: $e', refusal: _isRefused(e) ? S7Refusal.port : null);
    }
    if (_manualDisconnect) {
      socket.destroy();
      throw const S7ConnectionError('Desconectado');
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
    _rx.clear();
    _fragment.clear();
    _sub = socket.listen(
      _onData,
      onError: (Object e) => _onClosed('Erro de socket: $e'),
      onDone: () => _onClosed('Conexão encerrada pelo CLP'),
      cancelOnError: true,
    );
    try {
      await _openIso(socket);
      final S7Message setup;
      try {
        setup = await _transact((ref) => S7Pdu.setupCommunication(ref, requestedPduSize), S7Pdu.fnSetup);
      } on S7RequestRefused catch (e) {
        throw S7ProtocolError('$_label: CLP recusou o Setup Communication (${e.message})');
      }
      final size = S7Pdu.negotiatedPduSize(setup);
      if (size < minPduSize) throw S7ProtocolError('$_label: PDU de $size bytes é pequena demais');
      _pduSize = math.min(size, requestedPduSize);
      _ready = true;
      _setState(ModbusLinkState.connected);
      _log.info('Conectado a $_label, PDU $_pduSize bytes');
    } catch (e) {
      await _abort();
      _setState(_manualDisconnect ? ModbusLinkState.disconnected : ModbusLinkState.lost);
      if (e is S7Error) rethrow;
      if (e is FormatException) throw S7ProtocolError('$_label: ${e.message}');
      throw S7ConnectionError('$_label: $e');
    }
  }

  /// COTP: pede a conexão ISO com os TSAPs e espera o CC. O CLP que não
  /// gosta do TSAP (rack/slot errados) responde DR ou simplesmente fecha.
  Future<void> _openIso(Socket socket) async {
    final waiter = Completer<bool>();
    waiter.future.ignore(); // ver _transact: a recusa pode chegar durante o flush
    _cotp = waiter;
    final timer = Timer(responseTimeout, () {
      if (!waiter.isCompleted) {
        waiter.completeError(S7Timeout('$_label: sem resposta à conexão ISO em ${responseTimeout.inMilliseconds} ms'));
      }
    });
    try {
      socket.add(S7Pdu.connectionRequest(localTsap: localTsap, remoteTsap: remoteTsap));
      await socket.flush();
      final accepted = await waiter.future;
      if (!accepted) {
        throw S7ConnectionError(
            '$_label: CLP recusou a conexão ISO (TSAP 0x${remoteTsap.toRadixString(16).padLeft(4, '0')})',
            refusal: S7Refusal.rackSlot);
      }
    } finally {
      timer.cancel();
      if (identical(_cotp, waiter)) _cotp = null;
    }
  }

  /// "Conexão recusada": errno 111 (Linux/Android), 61 (macOS/iOS), 10061
  /// (Windows) — o aparelho existe, mas nada escuta na porta.
  static bool _isRefused(Object e) {
    if (e is! SocketException) return false;
    final code = e.osError?.errorCode;
    if (code == 111 || code == 61 || code == 10061) return true;
    return '${e.osError?.message} ${e.message}'.toLowerCase().contains('refused');
  }

  /// Fecha de propósito (não reconecta sozinho).
  Future<void> disconnect() async {
    _manualDisconnect = true;
    await _abort();
    _fail(const S7ConnectionError('Desconectado'));
    _setState(ModbusLinkState.disconnected);
  }

  /// Fecha o socket e limpa o estado, sem decidir se foi queda ou pedido.
  Future<void> _abort() async {
    final socket = _socket;
    _socket = null;
    _ready = false;
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    try {
      await socket?.close();
      socket?.destroy();
    } catch (_) {}
    _rx.clear();
    _fragment.clear();
  }

  void _onClosed(String reason) {
    if (_socket == null) return;
    _log.warning('$_label: $reason');
    _socket?.destroy();
    _socket = null;
    _sub = null;
    _ready = false;
    _rx.clear();
    _fragment.clear();
    // Fechou durante a abertura ISO: é o jeito de muita CPU dizer "TSAP
    // errado" — rack/slot que não existem.
    final cotp = _cotp;
    _cotp = null;
    if (cotp != null && !cotp.isCompleted) {
      cotp.completeError(S7ConnectionError('$_label: $reason na abertura ISO', refusal: S7Refusal.rackSlot));
    }
    _failPending(S7ConnectionError('$_label: $reason'));
    if (!_manualDisconnect) _setState(ModbusLinkState.lost);
  }

  void _fail(S7Error error) {
    final cotp = _cotp;
    _cotp = null;
    if (cotp != null && !cotp.isCompleted) cotp.completeError(error);
    _failPending(error);
  }

  void _failPending(S7Error error) {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.completer.isCompleted) {
      pending.timer.cancel();
      pending.completer.completeError(error);
    }
  }

  void _setState(ModbusLinkState value) {
    if (!_disposed) _state.value = value;
  }

  /// Libera recursos. Depois disso a instância não pode ser reutilizada.
  Future<void> dispose() async {
    await disconnect();
    _disposed = true;
    _state.dispose();
  }

  // ── Transação ────────────────────────────────────────────────────────────────

  /// Um pedido completo dentro da trava: conecta se precisar, manda, espera.
  Future<S7Message> _request(Uint8List Function(int ref) build, int function) {
    return _lock.synchronized(() async {
      await _ensureConnected();
      return _transact(build, function);
    });
  }

  /// Manda a mensagem S7 e espera a resposta com a mesma referência. Sem
  /// trava: quem chama já está dentro dela.
  Future<S7Message> _transact(Uint8List Function(int ref) build, int function) async {
    final socket = _socket;
    if (socket == null) throw S7ConnectionError('$_label: não conectado');
    _ref = _ref >= 0xFFFF ? 1 : _ref + 1;
    final ref = _ref;
    final pdu = build(ref);
    if (_pduSize > 0 && pdu.length > _pduSize) {
      throw S7RequestError('$_label: pedido de ${pdu.length} bytes passa da PDU de $_pduSize');
    }

    final completer = Completer<Uint8List>();
    final timer = Timer(responseTimeout, () {
      if (_pending?.ref == ref) _pending = null;
      if (!completer.isCompleted) {
        completer.completeError(
            S7Timeout('$_label: sem resposta em ${responseTimeout.inMilliseconds} ms (ref $ref)'));
      }
    });
    _pending = _Pending(ref, completer, timer);
    // A resposta (ou a queda) pode chegar enquanto o envio ainda está no
    // flush, antes de alguém esperar: sem isto o erro sairia como "não
    // tratado". Quem espera logo abaixo recebe o erro do mesmo jeito.
    final reply = completer.future..ignore();
    try {
      socket.add(S7Pdu.dataFrame(pdu));
      await socket.flush();
    } catch (e) {
      _onClosed('Falha ao enviar: $e');
    }
    return _check(await reply, function);
  }

  S7Message _check(Uint8List reply, int function) {
    final S7Message m;
    try {
      m = S7Pdu.parse(reply);
    } on FormatException catch (e) {
      throw S7ProtocolError('$_label: ${e.message}');
    }
    if (m.rosctr != S7Pdu.ackData && m.rosctr != S7Pdu.ack) {
      throw S7ProtocolError('$_label: resposta do tipo ${m.rosctr}, esperado Ack_Data');
    }
    // Erro no cabeçalho vem antes dos parâmetros: o CLP que recusa o pedido
    // inteiro (PUT/GET desligado) às vezes nem manda parâmetros.
    if (m.hasError) throw S7RequestRefused(errorClass: m.errorClass, errorCode: m.errorCode, detail: _label);
    if (m.param.isEmpty || m.param[0] != function) {
      throw S7ProtocolError('$_label: resposta de outra função (0x${m.param.isEmpty ? '--' : m.param[0].toRadixString(16)})');
    }
    return m;
  }

  // ── Recepção ─────────────────────────────────────────────────────────────────

  void _onData(Uint8List data) {
    _rx.addAll(data);
    while (_rx.length >= 4) {
      final length = (_rx[2] << 8) | _rx[3];
      // Cabeçalho impossível → fluxo dessincronizado. Descarta tudo; o pedido
      // pendente estoura o tempo e o próximo recomeça limpo.
      if (_rx[0] != 0x03 || length < 5) {
        _log.warning('$_label: cabeçalho TPKT inválido, descartando buffer');
        _rx.clear();
        _fragment.clear();
        return;
      }
      if (_rx.length < length) return;
      final tpdu = Uint8List.fromList(_rx.sublist(4, length));
      _rx.removeRange(0, length);
      _onTpdu(tpdu);
    }
  }

  /// Uma TPDU COTP: CC/DR na abertura; DT com pedaços da mensagem S7.
  void _onTpdu(Uint8List t) {
    if (t.length < 2) return;
    final headerLength = t[0] + 1;
    if (headerLength > t.length) return;
    switch (t[1] & 0xF0) {
      case 0xF0: // DT: a mensagem S7 pode vir em vários pedaços; EOT fecha.
        if (t.length < 3) return;
        _fragment.add(Uint8List.sublistView(t, headerLength));
        if (t[2] & 0x80 != 0) _onMessage(_fragment.takeBytes());
      case 0xD0: // CC
        final cotp = _cotp;
        if (cotp != null && !cotp.isCompleted) cotp.complete(true);
      case 0x80: // DR
      case 0x70: // ER
        final cotp = _cotp;
        if (cotp != null && !cotp.isCompleted) {
          cotp.complete(false);
        } else {
          _onClosed('CLP pediu desconexão');
        }
    }
  }

  void _onMessage(Uint8List pdu) {
    if (pdu.length < 6 || pdu[0] != S7Pdu.protocolId) {
      _log.warning('$_label: mensagem que não é S7, descartada');
      return;
    }
    final ref = (pdu[4] << 8) | pdu[5];
    final pending = _pending;
    if (pending == null || pending.ref != ref) {
      _log.fine('$_label: resposta atrasada/órfã (ref $ref) descartada');
      return;
    }
    _pending = null;
    pending.timer.cancel();
    if (!pending.completer.isCompleted) pending.completer.complete(pdu);
  }

  // ── Leitura ──────────────────────────────────────────────────────────────────

  /// Lê vários endereços com o menor número de pedidos que cabe na PDU.
  /// Devolve um resultado por endereço, na mesma ordem; item recusado pelo
  /// CLP volta com [S7ReadResult.error] e não interrompe os outros. Falha de
  /// comunicação ou pedido recusado inteiro lança [S7Error].
  Future<List<S7ReadResult>> read(List<S7Address> addresses) async {
    if (addresses.isEmpty) return const [];
    await _lock.synchronized(_ensureConnected);
    final pdu = _pduSize;
    final maxChunk = pdu - S7Pdu.readResponseSize(const [0]);
    final chunks = <_Chunk>[];
    for (var i = 0; i < addresses.length; i++) {
      final a = addresses[i];
      if (a.isBit) {
        chunks.add(_Chunk(i, S7ItemSpec.of(a), 0, 1));
        continue;
      }
      // Maior que a PDU: lê em pedaços e remonta.
      for (var off = 0; off < a.byteLength; off += maxChunk) {
        final len = math.min(maxChunk, a.byteLength - off);
        chunks.add(_Chunk(i, _byteSpec(a, off, len), off, len));
      }
    }
    final plan = _pack(chunks, (lengths) => S7Pdu.readRequestSize(lengths.length) <= pdu && S7Pdu.readResponseSize(lengths) <= pdu);

    final buffers = [for (final a in addresses) Uint8List(a.byteLength)];
    final errors = List<S7ItemError?>.filled(addresses.length, null);
    for (final request in plan) {
      final m = await _request((ref) => S7Pdu.readRequest(ref, [for (final c in request) c.spec]), S7Pdu.fnRead);
      final List<S7ItemData> items;
      try {
        items = S7Pdu.parseReadData(m, request.length);
      } on FormatException catch (e) {
        throw S7ProtocolError('$_label: ${e.message}');
      }
      for (var k = 0; k < request.length; k++) {
        final c = request[k];
        final item = items[k];
        if (!item.ok) {
          errors[c.item] ??= S7ItemError(addresses[c.item], item.code);
          continue;
        }
        if (c.spec.transportSize == S7Pdu.tsBit && item.bytes.isNotEmpty) {
          // CPU de verdade devolve só o bit (transporte BIT, valor no bit 0);
          // alguns servidores (o do python-snap7, gateways) devolvem o byte
          // inteiro. Os dois viram 0 ou 1.
          final byte = item.bytes[0];
          buffers[c.item][0] = item.transportSize == S7Pdu.dataBit ? byte & 1 : (byte >> addresses[c.item].bitIndex!) & 1;
          continue;
        }
        if (item.bytes.length != c.length) {
          throw S7ProtocolError('$_label: ${addresses[c.item]} pediu ${c.length} bytes, vieram ${item.bytes.length}');
        }
        buffers[c.item].setRange(c.offset, c.offset + c.length, item.bytes);
      }
    }
    return [
      for (var i = 0; i < addresses.length; i++) S7ReadResult(addresses[i], errors[i] == null ? buffers[i] : null, errors[i]),
    ];
  }

  /// Lê um endereço. Item recusado lança [S7ItemError].
  Future<Uint8List> readBytes(S7Address address) async {
    final r = (await read([address])).single;
    final e = r.error;
    if (e != null) throw e;
    return r.bytes!;
  }

  /// Lê e decodifica ([typeFor] escolhe o tipo).
  Future<Object> readValue(S7Address address, [S7Type? type]) async {
    final t = typeFor(address, type);
    return S7Codec.decode(t, await readBytes(address));
  }

  // ── Escrita ──────────────────────────────────────────────────────────────────

  /// Grava vários endereços. Devolve o erro de cada item (`null` = gravou),
  /// na mesma ordem. Bit grava com transporte BIT — só aquele bit muda no
  /// CLP, sem ler e regravar o byte.
  ///
  /// Item maior que a PDU vai em mais de um pedido; se a rede cair no meio,
  /// parte dele pode ter sido gravada.
  Future<List<S7ItemError?>> write(List<S7WriteItem> items) async {
    if (items.isEmpty) return const [];
    await _lock.synchronized(_ensureConnected);
    final pdu = _pduSize;
    final maxChunk = pdu - S7Pdu.writeRequestSize(const [0]);
    final chunks = <_Chunk>[];
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      if (it.address.isBit) {
        chunks.add(_Chunk(i, S7ItemSpec.of(it.address), 0, 1, it.bytes));
        continue;
      }
      for (var off = 0; off < it.bytes.length; off += maxChunk) {
        final len = math.min(maxChunk, it.bytes.length - off);
        chunks.add(_Chunk(i, _byteSpec(it.address, off, len), off, len, Uint8List.sublistView(it.bytes, off, off + len)));
      }
    }
    final plan = _pack(chunks, (lengths) => S7Pdu.writeRequestSize(lengths) <= pdu && S7Pdu.ackHeader + 2 + lengths.length <= pdu);

    final errors = List<S7ItemError?>.filled(items.length, null);
    for (final request in plan) {
      final m = await _request(
          (ref) => S7Pdu.writeRequest(ref, [for (final c in request) c.spec], [for (final c in request) c.data!]),
          S7Pdu.fnWrite);
      final List<int> codes;
      try {
        codes = S7Pdu.parseWriteData(m, request.length);
      } on FormatException catch (e) {
        throw S7ProtocolError('$_label: ${e.message}');
      }
      for (var k = 0; k < request.length; k++) {
        if (codes[k] != S7Pdu.itemOk) errors[request[k].item] ??= S7ItemError(items[request[k].item].address, codes[k]);
      }
    }
    return errors;
  }

  /// Grava os bytes de um endereço. Item recusado lança [S7ItemError].
  Future<void> writeBytes(S7Address address, Uint8List bytes) => _writeOne(S7WriteItem(address, bytes));

  /// Liga/desliga um bit (endereço de bit, ex.: DB1.DBX0.3).
  Future<void> writeBit(S7Address address, bool value) {
    if (!address.isBit) throw S7RequestError('$address não é um bit (ex.: DB1.DBX0.0)');
    return _writeOne(S7WriteItem.bit(address, value));
  }

  /// Codifica e grava. Ver [S7WriteItem.value].
  Future<void> writeValue(S7Address address, S7Type type, Object value) =>
      _writeOne(S7WriteItem.value(address, type, value));

  Future<void> _writeOne(S7WriteItem item) async {
    final e = (await write([item])).single;
    if (e != null) throw e;
  }

  /// Prova mínima de que há um CLP S7 aceitando leitura: lê MB0. Item
  /// recusado por endereço ainda prova que ele respondeu; acesso negado e
  /// pedido recusado inteiro (PUT/GET desligado) sobem como erro — é o que
  /// o "Testar conexão" precisa mostrar.
  Future<void> ping() async {
    if (!_ready) await connect();
    final r = (await read([S7Address(area: S7Area.flags, byteOffset: 0)])).single;
    final e = r.error;
    if (e != null && e.isAccessDenied) throw e;
  }

  // ── Planejamento ─────────────────────────────────────────────────────────────

  static S7ItemSpec _byteSpec(S7Address a, int offset, int length) => S7ItemSpec(
        transportSize: S7Pdu.tsByte,
        count: length,
        dbNumber: a.dbNumber,
        areaCode: a.area.code,
        bitAddress: (a.byteOffset + offset) * 8,
      );

  /// Junta os pedaços em pedidos, na ordem, enquanto [fits] aceitar e houver
  /// lugar para mais um item. Um pedaço sozinho sempre cabe (o tamanho dele
  /// já saiu da PDU).
  List<List<_Chunk>> _pack(List<_Chunk> chunks, bool Function(List<int> lengths) fits) {
    final plan = <List<_Chunk>>[];
    var current = <_Chunk>[];
    var lengths = <int>[];
    for (final c in chunks) {
      if (current.isNotEmpty && (current.length >= maxItemsPerRequest || !fits([...lengths, c.length]))) {
        plan.add(current);
        current = <_Chunk>[];
        lengths = <int>[];
      }
      current.add(c);
      lengths.add(c.length);
    }
    if (current.isNotEmpty) plan.add(current);
    return plan;
  }
}

/// Pedaço de um endereço que vai num item do pedido.
class _Chunk {
  _Chunk(this.item, this.spec, this.offset, this.length, [this.data]);

  /// Índice do endereço na lista do chamador.
  final int item;
  final S7ItemSpec spec;

  /// Onde este pedaço começa dentro do endereço.
  final int offset;
  final int length;

  /// Bytes a gravar (só na escrita).
  final Uint8List? data;
}

class _Pending {
  _Pending(this.ref, this.completer, this.timer);
  final int ref;
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
