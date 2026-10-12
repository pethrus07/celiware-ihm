import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

// O estado da ligação é o mesmo para todos os protocolos (o contrato do
// DeviceDriver usa este enum); o nome ficou da época em que só havia Modbus.
import '../modbus/modbus_client.dart' show ModbusLinkState;
import 'opcua_crypto.dart';
import 'opcua_error.dart';
import 'opcua_messages.dart';
import 'opcua_status.dart';
import 'opcua_types.dart';

/// Cliente OPC UA (UA-TCP, OPC UA Binary) em Dart puro, no modo de
/// segurança **None**.
///
/// Por que próprio: o único pacote Dart que fala OPC UA de verdade
/// (`open62541`, FFI) compila C com CMake na hora do build, baixa fontes
/// pela rede e acrescenta ~8 MB por ABI ao APK; os outros do pub.dev são GPL
/// ou param no Hello (spike em docs/pesquisa-etapa4/7-spike-opcua.md). O
/// subconjunto de uma IHM é pequeno: abrir o canal, criar e ativar a sessão,
/// ler, gravar e navegar.
///
/// ```
///  TCP 4840 ─► HEL/ACK ─► OPN (None) ─► CreateSession ─► ActivateSession
///           ─► Read / Write / Browse (MSG) … ─► CloseSession ─► CLO
/// ```
///
/// **Um pedido por vez**, como no `S7Client`: o próximo só sai quando o
/// anterior respondeu ou estourou o tempo. A resposta é casada pelo RequestId;
/// resposta atrasada de um pedido que já estourou é descartada. Resposta
/// grande vem em vários pedaços ('C' … 'F') e é remontada; pedido grande sai
/// em pedaços do tamanho que o servidor aceita.
///
/// **Sessão que cai** (servidor reiniciou, sessão venceu por falta de uso): o
/// pedido reabre canal e sessão e é repetido uma vez. Depois de uma queda de
/// rede, o próximo pedido reconecta sozinho. O token do canal é renovado aos
/// 75% da vida que o servidor deu.
///
/// **Usuário e senha**: num canal None a senha vai como está — a não ser que
/// o servidor peça cifrada com o certificado dele (RSA-OAEP), o que muito
/// servidor com endpoint seguro faz; aí ela vai cifrada.
///
/// **Limite conhecido:** só o modo None. Servidor que só aceita Sign ou
/// SignAndEncrypt é recusado com [OpcUaSecurityRequired].
class OpcUaClient {
  OpcUaClient({
    required this.host,
    this.port = 4840,
    String path = '',
    this.username = '',
    this.password = '',
    this.responseTimeout = const Duration(seconds: 2),
    this.connectionTimeout = const Duration(seconds: 5),
    this.sessionTimeout = const Duration(minutes: 1),
    this.channelLifetime = const Duration(hours: 1),
    this.maxNodesPerRequest = 500,
    this.receiveBufferSize = 65535,
    this.beforeConnect,
    math.Random? random,
  })  : path = normalizePath(path),
        _random = random ?? math.Random.secure();

  static final Logger _log = Logger('OpcUaClient');

  /// Maior mensagem aceita (16 MB): o que vier maior é recusado.
  static const int maxMessageSize = 16 << 20;

  final String host;
  final int port;

  /// O que vem depois da porta no endereço (`/OPCUA/SimulationServer`); vazio
  /// na maioria dos CLPs.
  final String path;
  final String username;
  final String password;

  Duration responseTimeout;
  Duration connectionTimeout;
  final Duration sessionTimeout;
  final Duration channelLifetime;

  /// Teto de nós por Read/Write; o servidor pode baixar (OperationLimits).
  final int maxNodesPerRequest;

  /// Maior pedaço que o cliente aceita receber (o servidor divide respostas
  /// maiores). A norma pede ao menos 8192.
  final int receiveBufferSize;

  /// Chamado antes de abrir o socket — o app usa para a conexão sair pela
  /// rede local certa no Android (ver `LocalNetwork.prepare`). Falha aqui não
  /// impede a tentativa: só fica no log.
  final Future<void> Function(String host)? beforeConnect;

  final math.Random _random;

  /// "/x" com a barra na frente; vazio continua vazio.
  static String normalizePath(String p) {
    final t = p.trim();
    if (t.isEmpty || t == '/') return '';
    return t.startsWith('/') ? t : '/$t';
  }

  /// O endereço completo, como o servidor mostra.
  String get endpointUrl => 'opc.tcp://$host:$port$path';

  final ValueNotifier<ModbusLinkState> _state = ValueNotifier(ModbusLinkState.disconnected);

  Socket? _socket;
  StreamSubscription<Uint8List>? _sub;
  final List<int> _rx = [];
  Completer<UaAck>? _hello;
  final Map<int, _Pending> _pending = {};
  final Map<int, BytesBuilder> _partial = {};
  UaAck? _ack;
  UaChannelToken? _token;
  DateTime _tokenAt = DateTime.fromMillisecondsSinceEpoch(0);
  NodeId _authToken = NodeId.nullId;
  int _requestId = 0;
  int _handle = 0;
  int _sequence = 0;
  int _requests = 0;
  int _sessions = 0;
  int _maxNodes = 0;
  int _partialChunks = 0;
  bool _ready = false;
  bool _manualDisconnect = true;
  bool _disposed = false;
  final _lock = _AsyncLock();

  String get _label => endpointUrl;

  /// Estado da ligação — a tela usa para o selo "online/sem conexão".
  ValueListenable<ModbusLinkState> get state => _state;

  bool get isConnected => _state.value == ModbusLinkState.connected;

  /// Pedidos de Read/Write/Browse enviados até agora — o driver mostra
  /// quantos uma varredura custou.
  int get requests => _requests;

  /// Pedaços intermediários ('C') recebidos: resposta que veio dividida.
  int get partialChunks => _partialChunks;

  /// Sessões criadas (sobe a cada reconexão).
  int get sessions => _sessions;

  /// Nós por pedido valendo nesta sessão (o menor entre o teto do app e o do
  /// servidor).
  int get maxNodesPerCall => _maxNodes > 0 ? _maxNodes : maxNodesPerRequest;

  // ── Conexão ──────────────────────────────────────────────────────────────────

  /// Abre canal e sessão. Lança [OpcUaConnectionError] (com [OpcUaRefusal]
  /// quando o servidor recusou), [OpcUaTimeout], [OpcUaSecurityRequired],
  /// [OpcUaAuthError], [OpcUaServiceError] ou [OpcUaProtocolError].
  Future<void> connect() {
    _manualDisconnect = false;
    return _lock.synchronized(_open);
  }

  Future<void> _ensureConnected() async {
    if (_ready) return;
    if (_manualDisconnect) throw const OpcUaConnectionError('Cliente desconectado');
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
      throw OpcUaConnectionError('Falha ao conectar em $_label: $e', refusal: _isRefused(e) ? OpcUaRefusal.port : null);
    }
    if (_manualDisconnect) {
      socket.destroy();
      throw const OpcUaConnectionError('Desconectado');
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
    _rx.clear();
    _partial.clear();
    _sub = socket.listen(
      _onData,
      onError: (Object e) => _onClosed('Erro de socket: $e'),
      onDone: () => _onClosed('Conexão encerrada pelo servidor'),
      cancelOnError: true,
    );
    try {
      _ack = await _helloAck(socket);
      await _openChannel(renew: false);
      final info = await _createSession();
      await _activate(info);
      await _readLimits();
      _ready = true;
      _sessions++;
      _setState(ModbusLinkState.connected);
      _log.info('Conectado a $_label (sessão ${info.sessionId})');
    } catch (e) {
      await _abort();
      _setState(_manualDisconnect ? ModbusLinkState.disconnected : ModbusLinkState.lost);
      if (e is OpcUaError) rethrow;
      if (e is FormatException) throw OpcUaProtocolError('$_label: ${e.message}');
      throw OpcUaConnectionError('$_label: $e');
    }
  }

  Future<UaAck> _helloAck(Socket socket) async {
    final waiter = Completer<UaAck>();
    waiter.future.ignore(); // ver _call: a recusa pode chegar durante o flush
    _hello = waiter;
    final timer = Timer(responseTimeout, () {
      if (!waiter.isCompleted) waiter.completeError(OpcUaTimeout('$_label: sem resposta ao Hello em ${responseTimeout.inMilliseconds} ms'));
    });
    try {
      socket.add(UaTcp.hello(endpointUrl: endpointUrl, receiveBufferSize: receiveBufferSize, maxMessageSize: maxMessageSize));
      await socket.flush();
      return await waiter.future;
    } finally {
      timer.cancel();
      if (identical(_hello, waiter)) _hello = null;
    }
  }

  Future<void> _openChannel({required bool renew}) async {
    final r = await _call(
      UaTypeIds.openSecureChannelResponse,
      UaServices.openSecureChannel(handle: ++_handle, now: DateTime.now(), lifetimeMs: channelLifetime.inMilliseconds, renew: renew, timeoutHint: responseTimeout.inMilliseconds),
      'OpenSecureChannel',
      open: true,
    );
    _token = UaServices.parseOpenSecureChannel(r.reader);
    _tokenAt = DateTime.now();
  }

  /// Renova o token do canal aos 75% da vida (o servidor derruba o canal no
  /// fim dela).
  Future<void> _renewIfDue() async {
    final t = _token;
    if (t == null || t.lifetimeMs <= 0) return;
    if (DateTime.now().difference(_tokenAt).inMilliseconds < t.lifetimeMs * 3 ~/ 4) return;
    try {
      await _openChannel(renew: true);
    } on OpcUaServiceError catch (e) {
      // Canal vencido ou esquecido pelo servidor: reabre tudo.
      throw _SessionLost('renovação do canal recusada (${UaStatus.name(e.code)})');
    }
  }

  Future<UaSessionInfo> _createSession() async {
    final nonce = Uint8List.fromList([for (var i = 0; i < 32; i++) _random.nextInt(256)]);
    final UaResponse r;
    try {
      r = await _call(
        UaTypeIds.createSessionResponse,
        UaServices.createSession(
          handle: ++_handle,
          now: DateTime.now(),
          endpointUrl: endpointUrl,
          sessionName: 'Ware IoT ${_random.nextInt(1 << 20)}',
          clientNonce: nonce,
          sessionTimeoutMs: sessionTimeout.inMilliseconds,
          timeoutHint: responseTimeout.inMilliseconds,
        ),
        'CreateSession',
      );
    } on OpcUaServiceError catch (e) {
      final c = e.code & 0xFFFF0000;
      if (c == UaStatus.badSecurityPolicyRejected || c == UaStatus.badSecurityModeRejected) {
        throw OpcUaSecurityRequired(await _offered());
      }
      rethrow;
    }
    final info = UaServices.parseCreateSession(r.reader);
    _authToken = info.authenticationToken;
    return info;
  }

  /// Endpoints que o servidor oferece, em texto, para a mensagem de
  /// segurança exigida.
  Future<List<String>> _offered() async {
    try {
      return {for (final e in await _getEndpoints()) e.label}.toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<UaEndpoint>> _getEndpoints() async {
    final r = await _call(UaTypeIds.getEndpointsResponse, UaServices.getEndpoints(handle: ++_handle, now: DateTime.now(), endpointUrl: endpointUrl, timeoutHint: responseTimeout.inMilliseconds), 'GetEndpoints');
    return UaServices.parseGetEndpoints(r.reader);
  }

  Future<void> _activate(UaSessionInfo info) async {
    var endpoints = info.endpoints;
    if (endpoints.isEmpty) endpoints = await _getEndpoints();
    final none = endpoints.where((e) => e.isNone).toList();
    if (endpoints.isNotEmpty && none.isEmpty) {
      throw OpcUaSecurityRequired({for (final e in endpoints) e.label}.toList());
    }
    // O endpoint None com o mesmo caminho, se houver; senão o primeiro None.
    final ep = none.where((e) => e.endpointUrl.endsWith('$port$path') || e.endpointUrl.endsWith('$port$path/')).firstOrNull ?? none.firstOrNull;
    final identity = _identity(ep, info);
    try {
      final r = await _call(
        UaTypeIds.activateSessionResponse,
        UaServices.activateSession(handle: ++_handle, now: DateTime.now(), token: _authToken, identity: identity, timeoutHint: responseTimeout.inMilliseconds),
        'ActivateSession',
      );
      UaServices.parseActivateSession(r.reader);
    } on OpcUaServiceError catch (e) {
      const auth = {
        UaStatus.badIdentityTokenInvalid,
        UaStatus.badIdentityTokenRejected,
        UaStatus.badUserAccessDenied,
        UaStatus.badUserSignatureInvalid,
      };
      if (auth.contains(e.code & 0xFFFF0000)) {
        throw OpcUaAuthError(
            username.isEmpty ? OpcUaAuthProblem.needsUser : OpcUaAuthProblem.rejected, '$_label: ActivateSession recusada (${UaStatus.name(e.code)})');
      }
      rethrow;
    }
  }

  /// O token de identificação que o endpoint aceita: anônimo sem usuário;
  /// usuário e senha com ele — a senha cifrada quando o servidor pede.
  UaIdentity _identity(UaEndpoint? ep, UaSessionInfo info) {
    final tokens = ep?.userTokens ?? const <UaUserTokenPolicy>[];
    if (username.isEmpty) {
      final t = tokens.where((t) => t.tokenType == UaUserTokenPolicy.anonymous).firstOrNull;
      if (ep != null && t == null) throw OpcUaAuthError(OpcUaAuthProblem.needsUser, '$_label: o endpoint não tem token anônimo');
      return UaAnonymousIdentity(t?.policyId ?? 'anonymous');
    }
    final t = tokens.where((t) => t.tokenType == UaUserTokenPolicy.userName).firstOrNull;
    if (ep != null && t == null) throw OpcUaAuthError(OpcUaAuthProblem.noUserName, '$_label: o endpoint não tem token de usuário e senha');
    final policy = t?.securityPolicyUri;
    final id = t?.policyId ?? 'username';
    if (UaSecurity.isNone(policy)) {
      return UaUserNameIdentity(id, user: username, password: Uint8List.fromList(utf8.encode(password)));
    }
    const oaep = {UaSecurity.policyBasic256Sha256, UaSecurity.policyBasic256, UaSecurity.policyAes128Sha256RsaOaep};
    if (!oaep.contains(policy)) throw OpcUaAuthError(OpcUaAuthProblem.cipher, '$_label: cifra da senha $policy', policy: policy);
    final cert = (ep?.serverCertificate?.isNotEmpty ?? false) ? ep!.serverCertificate! : info.serverCertificate;
    final nonce = info.serverNonce;
    if (cert == null || cert.isEmpty || nonce == null || nonce.isEmpty) {
      throw OpcUaProtocolError('$_label: o servidor pede a senha cifrada, mas não mandou certificado e nonce');
    }
    final RsaPublicKey key;
    try {
      key = RsaPublicKey.fromCertificate(cert);
    } on FormatException catch (e) {
      throw OpcUaProtocolError('$_label: ${e.message}');
    }
    return UaUserNameIdentity(id, user: username, password: key.encryptOaep(uaPasswordSecret(password, nonce), random: _random), algorithm: uaRsaOaepUri);
  }

  /// Quantos nós o servidor aceita por leitura (ServerCapabilities →
  /// OperationLimits). Servidor que não diz fica com o teto do app.
  Future<void> _readLimits() async {
    _maxNodes = maxNodesPerRequest;
    try {
      final r = await _call(
        UaTypeIds.readResponse,
        UaServices.read(handle: ++_handle, now: DateTime.now(), token: _authToken, nodes: const [(NodeId.maxNodesPerRead, UaAttribute.value)], timeoutHint: responseTimeout.inMilliseconds),
        'Read',
      );
      final v = UaServices.parseRead(r.reader).firstOrNull;
      final n = v != null && UaStatus.isGood(v.status) ? v.value.value : null;
      if (n is int && n > 0) _maxNodes = math.min(n, maxNodesPerRequest);
    } on OpcUaServiceError {
      // Servidor sem OperationLimits: vale o teto do app.
    } on FormatException {
      // Idem: resposta estranha aqui não impede a sessão.
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

  /// Fecha de propósito (não reconecta sozinho). Com a sessão de pé e nada em
  /// andamento, avisa o servidor (CloseSession + CLO) antes de fechar o
  /// socket — servidor de CLP tem poucas sessões e libera na hora. Não espera
  /// a resposta do CloseSession: o app indo para segundo plano não pode ficar
  /// preso a um servidor lento, e a resposta não muda nada.
  Future<void> disconnect() async {
    _manualDisconnect = true;
    final socket = _socket;
    if (_ready && socket != null && _pending.isEmpty) {
      try {
        _send('MSG', UaServices.closeSession(handle: ++_handle, now: DateTime.now(), token: _authToken), ++_requestId);
        _send('CLO', UaServices.closeSecureChannel(handle: ++_handle, now: DateTime.now()), ++_requestId);
        await socket.flush();
      } catch (_) {/* fechando de qualquer jeito */}
    }
    await _abort();
    _fail(const OpcUaConnectionError('Desconectado'));
    _setState(ModbusLinkState.disconnected);
  }

  /// Fecha o socket e limpa o estado, sem decidir se foi queda ou pedido.
  Future<void> _abort() async {
    final socket = _socket;
    _socket = null;
    _ready = false;
    _token = null;
    _authToken = NodeId.nullId;
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    try {
      await socket?.close();
      socket?.destroy();
    } catch (_) {}
    _rx.clear();
    _partial.clear();
  }

  void _onClosed(String reason) {
    if (_socket == null) return;
    _log.warning('$_label: $reason');
    _socket?.destroy();
    _socket = null;
    _sub = null;
    _ready = false;
    _token = null;
    _rx.clear();
    _partial.clear();
    _fail(OpcUaConnectionError('$_label: $reason'));
    if (!_manualDisconnect) _setState(ModbusLinkState.lost);
  }

  void _fail(OpcUaError error) {
    final hello = _hello;
    _hello = null;
    if (hello != null && !hello.isCompleted) hello.completeError(error);
    for (final p in _pending.values.toList()) {
      p.timer.cancel();
      if (!p.completer.isCompleted) p.completer.completeError(error);
    }
    _pending.clear();
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

  /// Um pedido completo dentro da trava: conecta se precisar, renova o canal,
  /// manda e espera. Sessão que o servidor esqueceu é reaberta e o pedido
  /// repetido uma vez.
  Future<UaResponse> _request(int expectedType, Uint8List Function(int handle) build, String service) {
    return _lock.synchronized(() async {
      for (var attempt = 0;; attempt++) {
        await _ensureConnected();
        try {
          await _renewIfDue();
          _requests++;
          return await _call(expectedType, build(++_handle), service);
        } on _SessionLost catch (e) {
          await _abort();
          if (attempt > 0 || _manualDisconnect) {
            _setState(_manualDisconnect ? ModbusLinkState.disconnected : ModbusLinkState.lost);
            throw OpcUaConnectionError('$_label: $service: ${e.message}');
          }
          _log.info('$_label: ${e.message}; reabrindo a sessão');
        }
      }
    });
  }

  /// Manda a mensagem e espera a resposta com o mesmo RequestId. Sem trava:
  /// quem chama já está dentro dela.
  Future<UaResponse> _call(int expectedType, Uint8List body, String service, {bool open = false, Duration? timeout}) async {
    final socket = _socket;
    if (socket == null) throw OpcUaConnectionError('$_label: não conectado');
    final id = ++_requestId;
    final limit = timeout ?? responseTimeout;
    final completer = Completer<Uint8List>();
    final timer = Timer(limit, () {
      _pending.remove(id);
      _partial.remove(id);
      if (!completer.isCompleted) completer.completeError(OpcUaTimeout('$_label: $service sem resposta em ${limit.inMilliseconds} ms (pedido $id)'));
    });
    _pending[id] = _Pending(completer, timer);
    // A resposta (ou a queda) pode chegar enquanto o envio ainda está no
    // flush, antes de alguém esperar: sem isto o erro sairia como "não
    // tratado". Quem espera logo abaixo recebe o erro do mesmo jeito.
    final reply = completer.future..ignore();
    try {
      if (open) {
        socket.add(UaTcp.openChunk(channelId: _token?.channelId ?? 0, sequence: _nextSequence(), requestId: id, body: body));
      } else {
        _send('MSG', body, id);
      }
      await socket.flush();
    } catch (e) {
      _onClosed('Falha ao enviar: $e');
    }
    final bytes = await reply;
    final UaResponse r;
    try {
      r = UaServices.parse(bytes);
    } on FormatException catch (e) {
      throw OpcUaProtocolError('$_label: $service: ${e.message}');
    }
    final result = r.header.serviceResult;
    if (r.isFault || UaStatus.isBad(result)) {
      if (UaStatus.killsSession(result) && !open) throw _SessionLost('${UaStatus.name(result)} em $service');
      throw OpcUaServiceError(result, service);
    }
    if (r.typeId != expectedType) throw OpcUaProtocolError('$_label: $service respondido com o tipo ${r.typeId}');
    return r;
  }

  int _nextSequence() {
    // A norma manda recomeçar abaixo de 1024 antes de estourar 32 bits.
    _sequence = _sequence >= 0xFFFFFBFF ? 1 : _sequence + 1;
    return _sequence;
  }

  void _send(String type, Uint8List body, int requestId) {
    final socket = _socket;
    final token = _token;
    if (socket == null || token == null) throw OpcUaConnectionError('$_label: canal fechado');
    final room = _ack?.receiveBufferSize ?? 65535;
    for (final chunk in UaTcp.messageChunks(type,
        channelId: token.channelId, tokenId: token.tokenId, requestId: requestId, body: body, nextSequence: _nextSequence, maxChunkSize: room == 0 ? 65535 : room)) {
      socket.add(chunk);
    }
  }

  // ── Recepção ─────────────────────────────────────────────────────────────────

  void _onData(Uint8List data) {
    _rx.addAll(data);
    while (_rx.length >= UaTcp.headerSize) {
      final size = _rx[4] | (_rx[5] << 8) | (_rx[6] << 16) | (_rx[7] << 24);
      if (size < UaTcp.headerSize || size > maxMessageSize) {
        _log.warning('$_label: cabeçalho UA-TCP inválido (tamanho $size)');
        _failProtocol('cabeçalho UA-TCP inválido');
        return;
      }
      if (_rx.length < size) return;
      final chunk = Uint8List.fromList(_rx.sublist(0, size));
      _rx.removeRange(0, size);
      _onChunk(chunk);
      if (_socket == null) return;
    }
  }

  void _failProtocol(String reason) {
    _fail(OpcUaProtocolError('$_label: $reason'));
    _onClosed(reason);
  }

  void _onChunk(Uint8List chunk) {
    final type = String.fromCharCodes(chunk.sublist(0, 3));
    final body = Uint8List.sublistView(chunk, UaTcp.headerSize);
    switch (type) {
      case 'ACK':
        final hello = _hello;
        if (hello == null || hello.isCompleted) return;
        try {
          hello.complete(UaTcp.parseAck(body));
        } on FormatException catch (e) {
          hello.completeError(OpcUaProtocolError('$_label: ACK ${e.message}'));
        }
      case 'ERR':
        final (code, reason) = _safeError(body);
        _log.warning('$_label: ERR ${UaStatus.name(code)} ${reason ?? ''}');
        final OpcUaError error = switch (code & 0xFFFF0000) {
          UaStatus.badTcpEndpointUrlInvalid => OpcUaConnectionError('$_label: ${reason ?? 'endpoint inválido'}', refusal: OpcUaRefusal.endpoint),
          UaStatus.badSecurityPolicyRejected || UaStatus.badSecurityModeRejected => OpcUaSecurityRequired(const []),
          _ => OpcUaServiceError(code, 'conexão${reason == null || reason.isEmpty ? '' : ' ($reason)'}'),
        };
        _fail(error);
        _onClosed('servidor mandou ERR (${UaStatus.name(code)})');
      case 'OPN' || 'MSG' || 'CLO':
        final UaChunk c;
        try {
          c = UaTcp.parseChunk(chunk);
        } on FormatException catch (e) {
          _failProtocol(e.message);
          return;
        }
        _onSecureChunk(c);
      default:
        _log.warning('$_label: mensagem "$type" ignorada');
    }
  }

  (int, String?) _safeError(Uint8List body) {
    try {
      return UaTcp.parseError(body);
    } on FormatException {
      return (UaStatus.badUnexpectedError, null);
    }
  }

  void _onSecureChunk(UaChunk c) {
    final pending = _pending[c.requestId];
    switch (c.chunkType) {
      case 'C':
        if (pending == null) return; // resposta atrasada/órfã
        _partialChunks++;
        final part = _partial.putIfAbsent(c.requestId, BytesBuilder.new)..add(c.body);
        if (part.length > maxMessageSize) {
          _partial.remove(c.requestId);
          _pending.remove(c.requestId);
          pending.timer.cancel();
          if (!pending.completer.isCompleted) pending.completer.completeError(OpcUaProtocolError('$_label: resposta maior que $maxMessageSize bytes'));
        }
      case 'A':
        _partial.remove(c.requestId);
        if (pending == null) return;
        _pending.remove(c.requestId);
        pending.timer.cancel();
        final (code, reason) = _safeError(c.body);
        if (!pending.completer.isCompleted) pending.completer.completeError(OpcUaServiceError(code, 'resposta abortada${reason == null ? '' : ' ($reason)'}'));
      default:
        final part = _partial.remove(c.requestId);
        if (pending == null) {
          _log.fine('$_label: resposta atrasada/órfã (pedido ${c.requestId}) descartada');
          return;
        }
        _pending.remove(c.requestId);
        pending.timer.cancel();
        final whole = part == null ? Uint8List.fromList(c.body) : (part..add(c.body)).takeBytes();
        if (!pending.completer.isCompleted) pending.completer.complete(whole);
    }
  }

  // ── Serviços ─────────────────────────────────────────────────────────────────

  /// Lê o valor (ou outro atributo) de vários nós, no menor número de
  /// pedidos que o servidor aceita. Devolve um [UaDataValue] por nó, na mesma
  /// ordem; nó recusado volta com o StatusCode dele, sem interromper os
  /// outros. Falha de comunicação ou pedido recusado inteiro lança
  /// [OpcUaError].
  Future<List<UaDataValue>> read(List<NodeId> nodes, {int attribute = UaAttribute.value}) =>
      readAttributes([for (final n in nodes) (n, attribute)]);

  Future<List<UaDataValue>> readAttributes(List<(NodeId, int)> items) async {
    if (items.isEmpty) return const [];
    final out = <UaDataValue>[];
    var off = 0;
    while (off < items.length) {
      // O tamanho do lote só se sabe depois de conectar (OperationLimits).
      await _lock.synchronized(_ensureConnected);
      final batch = items.sublist(off, math.min(off + maxNodesPerCall, items.length));
      final r = await _request(
        UaTypeIds.readResponse,
        (h) => UaServices.read(handle: h, now: DateTime.now(), token: _authToken, nodes: batch, timeoutHint: responseTimeout.inMilliseconds),
        'Read',
      );
      final List<UaDataValue> values;
      try {
        values = UaServices.parseRead(r.reader);
      } on FormatException catch (e) {
        throw OpcUaProtocolError('$_label: Read: ${e.message}');
      }
      if (values.length != batch.length) throw OpcUaProtocolError('$_label: Read pediu ${batch.length} nós, vieram ${values.length}');
      out.addAll(values);
      off += batch.length;
    }
    return out;
  }

  /// Grava o valor de vários nós. Devolve o StatusCode de cada um (0 =
  /// gravou), na mesma ordem.
  Future<List<int>> write(List<(NodeId, UaVariant)> values) async {
    if (values.isEmpty) return const [];
    final r = await _request(
      UaTypeIds.writeResponse,
      (h) => UaServices.write(handle: h, now: DateTime.now(), token: _authToken, values: values, timeoutHint: responseTimeout.inMilliseconds),
      'Write',
    );
    final List<int> codes;
    try {
      codes = UaServices.parseWrite(r.reader);
    } on FormatException catch (e) {
      throw OpcUaProtocolError('$_label: Write: ${e.message}');
    }
    if (codes.length != values.length) throw OpcUaProtocolError('$_label: Write pediu ${values.length} nós, vieram ${codes.length}');
    return codes;
  }

  /// Os filhos (objetos e variáveis) de [node], seguindo as continuações até
  /// o fim. Nó que não existe lança [OpcUaNodeError].
  Future<List<UaReference>> browse(NodeId node) async {
    final refs = <UaReference>[];
    var r = await _request(
      UaTypeIds.browseResponse,
      (h) => UaServices.browse(handle: h, now: DateTime.now(), token: _authToken, nodes: [node], timeoutHint: responseTimeout.inMilliseconds),
      'Browse',
    );
    for (var round = 0;; round++) {
      final UaBrowseResult result;
      try {
        final results = UaServices.parseBrowse(r.reader);
        if (results.length != 1) throw const FormatException('Browse sem resultado');
        result = results.single;
      } on FormatException catch (e) {
        throw OpcUaProtocolError('$_label: Browse: ${e.message}');
      }
      if (UaStatus.isBad(result.status)) throw OpcUaNodeError(node, result.status);
      refs.addAll(result.references);
      final cp = result.continuationPoint;
      if (cp == null || cp.isEmpty) return refs;
      if (round >= 100) {
        _log.warning('$_label: navegação de $node parou em ${refs.length} referências');
        return refs;
      }
      r = await _request(
        UaTypeIds.browseNextResponse,
        (h) => UaServices.browseNext(handle: h, now: DateTime.now(), token: _authToken, continuationPoints: [cp], timeoutHint: responseTimeout.inMilliseconds),
        'BrowseNext',
      );
    }
  }

  /// Prova mínima de que há um servidor OPC UA aceitando sessão e leitura:
  /// abre canal e sessão e lê o estado do servidor.
  Future<void> ping() async {
    if (!_ready) await connect();
    await read(const [NodeId.serverState]);
  }
}

/// A sessão ou o canal sumiram no servidor: o pedido reabre e repete.
class _SessionLost implements Exception {
  const _SessionLost(this.message);
  final String message;
}

class _Pending {
  _Pending(this.completer, this.timer);
  final Completer<Uint8List> completer;
  final Timer timer;
}

/// Trava assíncrona FIFO: uma ação por vez, na ordem de chegada. Reentrante
/// não é: quem já está dentro chama as funções sem trava (`_call`, `_open`).
class _AsyncLock {
  Future<void> _tail = Future.value();

  Future<T> synchronized<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }
}
