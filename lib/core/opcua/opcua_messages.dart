/// Mensagens do OPC UA: o envelope UA-TCP (Hello/Ack, pedaços OPN/MSG/CLO)
/// e os serviços que uma IHM usa — canal seguro, sessão, Read, Write, Browse.
///
/// Funções puras: montam bytes e leem bytes, sem rede. O cliente
/// (`opcua_client.dart`) só junta isto ao socket.
///
/// ```
///  TCP 4840 ─► HEL ─► ACK                       (tamanhos de buffer)
///           ─► OPN (OpenSecureChannel, None) ─► token do canal
///           ─► MSG CreateSession ─► ActivateSession (anônimo ou usuário)
///           ─► MSG Read / Write / Browse …
///           ─► MSG CloseSession ─► CLO
/// ```
library;

import 'dart:typed_data';

import 'opcua_binary.dart';
import 'opcua_types.dart';

/// Os NodeIds de codificação binária de cada mensagem (ObjectIds da norma,
/// `*_Encoding_DefaultBinary`; conferidos contra o asyncua 2.1.0).
abstract final class UaTypeIds {
  static const int anonymousIdentityToken = 321;
  static const int userNameIdentityToken = 324;
  static const int serviceFault = 397;
  static const int getEndpointsRequest = 428;
  static const int getEndpointsResponse = 431;
  static const int openSecureChannelRequest = 446;
  static const int openSecureChannelResponse = 449;
  static const int closeSecureChannelRequest = 452;
  static const int createSessionRequest = 461;
  static const int createSessionResponse = 464;
  static const int activateSessionRequest = 467;
  static const int activateSessionResponse = 470;
  static const int closeSessionRequest = 473;
  static const int closeSessionResponse = 476;
  static const int browseRequest = 527;
  static const int browseResponse = 530;
  static const int browseNextRequest = 533;
  static const int browseNextResponse = 536;
  static const int readRequest = 631;
  static const int readResponse = 634;
  static const int writeRequest = 673;
  static const int writeResponse = 676;
}

// ── UA-TCP ─────────────────────────────────────────────────────────────────────

/// Resposta ao Hello: os limites que valem nesta conexão.
class UaAck {
  const UaAck({required this.receiveBufferSize, required this.sendBufferSize, required this.maxMessageSize, required this.maxChunkCount});

  /// Maior pedaço que o **servidor** aceita receber (o que o cliente manda).
  final int receiveBufferSize;

  /// Maior pedaço que o servidor vai mandar.
  final int sendBufferSize;
  final int maxMessageSize;
  final int maxChunkCount;
}

/// Um pedaço (chunk) recebido, já sem os cabeçalhos.
class UaChunk {
  const UaChunk({
    required this.messageType,
    required this.chunkType,
    required this.channelId,
    required this.sequence,
    required this.requestId,
    required this.body,
    this.tokenId = 0,
    this.securityPolicyUri,
  });

  /// 'OPN', 'MSG' ou 'CLO'.
  final String messageType;

  /// 'F' (último), 'C' (continua) ou 'A' (abortado).
  final String chunkType;
  final int channelId;
  final int tokenId;
  final String? securityPolicyUri;
  final int sequence;
  final int requestId;
  final Uint8List body;
}

abstract final class UaTcp {
  /// Tipo (3) + pedaço (1) + tamanho (4).
  static const int headerSize = 8;

  /// Cabeçalho de segurança simétrico + sequência de um MSG/CLO:
  /// canal (4) + token (4) + número de sequência (4) + pedido (4).
  static const int messageOverhead = headerSize + 16;

  /// Hello do cliente: os tamanhos que ele aceita e o endpoint pedido.
  static Uint8List hello({
    required String endpointUrl,
    int receiveBufferSize = 65535,
    int sendBufferSize = 65535,
    int maxMessageSize = 16 << 20,
    int maxChunkCount = 0,
  }) {
    final w = UaWriter()
      ..uint32(0) // versão do protocolo
      ..uint32(receiveBufferSize)
      ..uint32(sendBufferSize)
      ..uint32(maxMessageSize)
      ..uint32(maxChunkCount)
      ..string(endpointUrl);
    return frame('HEL', 'F', w.takeBytes());
  }

  /// Envelope UA-TCP: tipo, pedaço e tamanho total na frente de [body].
  static Uint8List frame(String type, String chunk, List<int> body) {
    final w = UaWriter()
      ..bytes(type.codeUnits)
      ..bytes(chunk.codeUnits)
      ..uint32(headerSize + body.length)
      ..bytes(body);
    return w.takeBytes();
  }

  static UaAck parseAck(Uint8List body) {
    final r = UaReader(body);
    r.uint32(); // versão
    return UaAck(receiveBufferSize: r.uint32(), sendBufferSize: r.uint32(), maxMessageSize: r.uint32(), maxChunkCount: r.uint32());
  }

  /// ERR (ou pedaço abortado): o StatusCode e o motivo em texto.
  static (int, String?) parseError(Uint8List body) {
    final r = UaReader(body);
    final code = r.statusCode();
    return (code, r.atEnd ? null : r.string());
  }

  /// OPN com a política None: sem certificado nem assinatura.
  static Uint8List openChunk({required int channelId, required int sequence, required int requestId, required List<int> body}) {
    final w = UaWriter()
      ..uint32(channelId)
      ..string(UaSecurity.policyNone)
      ..byteString(null) // certificado do cliente
      ..byteString(null) // impressão digital do certificado do servidor
      ..uint32(sequence)
      ..uint32(requestId)
      ..bytes(body);
    return frame('OPN', 'F', w.takeBytes());
  }

  /// MSG ou CLO, dividido em pedaços de até [maxChunkSize] bytes (o
  /// ReceiveBufferSize do servidor). Cada pedaço gasta um número de sequência.
  static List<Uint8List> messageChunks(
    String type, {
    required int channelId,
    required int tokenId,
    required int requestId,
    required List<int> body,
    required int Function() nextSequence,
    int maxChunkSize = 65535,
  }) {
    final room = maxChunkSize - messageOverhead;
    if (room < 1) throw ArgumentError('pedaço de $maxChunkSize bytes não cabe nada');
    final chunks = <Uint8List>[];
    var off = 0;
    do {
      final end = off + room < body.length ? off + room : body.length;
      final last = end == body.length;
      final w = UaWriter()
        ..uint32(channelId)
        ..uint32(tokenId)
        ..uint32(nextSequence())
        ..uint32(requestId)
        ..bytes(body.sublist(off, end));
      chunks.add(frame(type, last ? 'F' : 'C', w.takeBytes()));
      off = end;
    } while (off < body.length);
    return chunks;
  }

  /// Lê um pedaço OPN/MSG/CLO inteiro (com o cabeçalho UA-TCP).
  static UaChunk parseChunk(Uint8List chunk) {
    if (chunk.length < headerSize) throw const FormatException('pedaço OPC UA menor que o cabeçalho');
    final type = String.fromCharCodes(chunk.sublist(0, 3));
    final kind = String.fromCharCode(chunk[3]);
    final r = UaReader(chunk, headerSize);
    final channel = r.uint32();
    if (type == 'OPN') {
      final policy = r.string();
      r.byteString(); // certificado do servidor
      r.byteString(); // impressão digital
      final seq = r.uint32();
      final req = r.uint32();
      return UaChunk(messageType: type, chunkType: kind, channelId: channel, securityPolicyUri: policy, sequence: seq, requestId: req, body: r.rest());
    }
    final token = r.uint32();
    final seq = r.uint32();
    final req = r.uint32();
    return UaChunk(messageType: type, chunkType: kind, channelId: channel, tokenId: token, sequence: seq, requestId: req, body: r.rest());
  }
}

// ── Serviços ───────────────────────────────────────────────────────────────────

/// Quem o cliente diz ser ao ativar a sessão.
sealed class UaIdentity {
  const UaIdentity(this.policyId);

  /// O id da regra oferecida pelo servidor no endpoint ([UaUserTokenPolicy]).
  final String policyId;
}

class UaAnonymousIdentity extends UaIdentity {
  const UaAnonymousIdentity(super.policyId);
}

/// Usuário e senha. [password] já vem pronto: o texto em UTF-8, ou cifrado
/// com o certificado do servidor quando ele pede ([algorithm] diz como).
class UaUserNameIdentity extends UaIdentity {
  const UaUserNameIdentity(super.policyId, {required this.user, required this.password, this.algorithm});

  final String user;
  final Uint8List password;
  final String? algorithm;
}

/// Cabeçalho de toda resposta.
class UaResponseHeader {
  const UaResponseHeader({required this.requestHandle, required this.serviceResult, this.timestamp});
  final int requestHandle;
  final int serviceResult;
  final DateTime? timestamp;
}

/// Resposta lida até o cabeçalho; o resto fica no [reader].
class UaResponse {
  const UaResponse(this.typeId, this.header, this.reader);

  /// NodeId numérico da codificação (ex.: [UaTypeIds.readResponse]).
  final int typeId;
  final UaResponseHeader header;
  final UaReader reader;

  bool get isFault => typeId == UaTypeIds.serviceFault;
}

/// Token do canal seguro.
class UaChannelToken {
  const UaChannelToken({required this.channelId, required this.tokenId, required this.lifetimeMs});
  final int channelId;
  final int tokenId;
  final int lifetimeMs;
}

/// O que a criação da sessão devolve e a ativação usa.
class UaSessionInfo {
  const UaSessionInfo({
    required this.sessionId,
    required this.authenticationToken,
    required this.timeoutMs,
    required this.serverNonce,
    required this.serverCertificate,
    required this.endpoints,
  });

  final NodeId sessionId;
  final NodeId authenticationToken;
  final double timeoutMs;
  final Uint8List? serverNonce;
  final Uint8List? serverCertificate;
  final List<UaEndpoint> endpoints;
}

/// Resultado da navegação de um nó.
class UaBrowseResult {
  const UaBrowseResult(this.status, this.continuationPoint, this.references);
  final int status;
  final Uint8List? continuationPoint;
  final List<UaReference> references;
}

abstract final class UaServices {
  /// Quem o cliente é, na criação da sessão.
  static const String applicationUri = 'urn:celiware:ware-iot';
  static const String productUri = 'urn:celiware:ware-iot';

  static void _requestHeader(UaWriter w, int typeId, {required NodeId token, required int handle, required DateTime now, required int timeoutHint}) {
    w
      ..nodeId(NodeId.numeric(0, typeId))
      ..nodeId(token)
      ..dateTime(now)
      ..uint32(handle)
      ..uint32(0) // ReturnDiagnostics: nenhum
      ..string(null) // AuditEntryId
      ..uint32(timeoutHint)
      ..extensionObject(NodeId.nullId);
  }

  static Uint8List openSecureChannel({required int handle, required DateTime now, required int lifetimeMs, bool renew = false, int timeoutHint = 0}) {
    final w = UaWriter();
    _requestHeader(w, UaTypeIds.openSecureChannelRequest, token: NodeId.nullId, handle: handle, now: now, timeoutHint: timeoutHint);
    w
      ..uint32(0) // versão do protocolo
      ..uint32(renew ? 1 : 0) // Issue / Renew
      ..uint32(UaSecurity.modeNone)
      ..byteString(const <int>[]) // nonce do cliente (None: vazio)
      ..uint32(lifetimeMs);
    return w.takeBytes();
  }

  static Uint8List closeSecureChannel({required int handle, required DateTime now}) {
    final w = UaWriter();
    _requestHeader(w, UaTypeIds.closeSecureChannelRequest, token: NodeId.nullId, handle: handle, now: now, timeoutHint: 0);
    return w.takeBytes();
  }

  static Uint8List getEndpoints({required int handle, required DateTime now, required String endpointUrl, int timeoutHint = 0}) {
    final w = UaWriter();
    _requestHeader(w, UaTypeIds.getEndpointsRequest, token: NodeId.nullId, handle: handle, now: now, timeoutHint: timeoutHint);
    w
      ..string(endpointUrl)
      ..array<String>(const [], w.string)
      ..array<String>(const [], w.string);
    return w.takeBytes();
  }

  static Uint8List createSession({
    required int handle,
    required DateTime now,
    required String endpointUrl,
    required String sessionName,
    required Uint8List clientNonce,
    required int sessionTimeoutMs,
    String applicationName = 'Ware IoT',
    int maxResponseSize = 16 << 20,
    int timeoutHint = 0,
  }) {
    final w = UaWriter();
    _requestHeader(w, UaTypeIds.createSessionRequest, token: NodeId.nullId, handle: handle, now: now, timeoutHint: timeoutHint);
    // ApplicationDescription do cliente.
    w
      ..string(applicationUri)
      ..string(productUri)
      ..localizedText(LocalizedText(applicationName))
      ..uint32(1) // Client
      ..string(null) // GatewayServerUri
      ..string(null) // DiscoveryProfileUri
      ..array<String>(null, w.string); // DiscoveryUrls
    w
      ..string(null) // ServerUri
      ..string(endpointUrl)
      ..string(sessionName)
      ..byteString(clientNonce)
      ..byteString(null) // certificado do cliente (None)
      ..float64(sessionTimeoutMs.toDouble())
      ..uint32(maxResponseSize);
    return w.takeBytes();
  }

  static Uint8List activateSession({required int handle, required DateTime now, required NodeId token, required UaIdentity identity, List<String> locales = const ['pt-BR', 'en'], int timeoutHint = 0}) {
    final w = UaWriter();
    _requestHeader(w, UaTypeIds.activateSessionRequest, token: token, handle: handle, now: now, timeoutHint: timeoutHint);
    w
      ..string(null) // ClientSignature.Algorithm
      ..byteString(null) // ClientSignature.Signature
      ..array<int>(const [], w.int32) // ClientSoftwareCertificates
      ..array<String>(locales, w.string);
    final t = UaWriter();
    switch (identity) {
      case UaAnonymousIdentity():
        t.string(identity.policyId);
        w.extensionObject(const NodeId.numeric(0, UaTypeIds.anonymousIdentityToken), t.takeBytes());
      case UaUserNameIdentity():
        t
          ..string(identity.policyId)
          ..string(identity.user)
          ..byteString(identity.password)
          ..string(identity.algorithm);
        w.extensionObject(const NodeId.numeric(0, UaTypeIds.userNameIdentityToken), t.takeBytes());
    }
    w
      ..string(null) // UserTokenSignature.Algorithm
      ..byteString(null);
    return w.takeBytes();
  }

  static Uint8List closeSession({required int handle, required DateTime now, required NodeId token}) {
    final w = UaWriter();
    _requestHeader(w, UaTypeIds.closeSessionRequest, token: token, handle: handle, now: now, timeoutHint: 0);
    w.boolean(true); // apagar assinaturas
    return w.takeBytes();
  }

  /// Read de vários nós (com o atributo de cada um), sem horários na resposta.
  static Uint8List read({required int handle, required DateTime now, required NodeId token, required List<(NodeId, int)> nodes, int timeoutHint = 0}) {
    final w = UaWriter();
    _requestHeader(w, UaTypeIds.readRequest, token: token, handle: handle, now: now, timeoutHint: timeoutHint);
    w
      ..float64(0) // MaxAge: valor atual
      ..uint32(3); // TimestampsToReturn: Neither
    w.array<(NodeId, int)>(nodes, (n) {
      w
        ..nodeId(n.$1)
        ..uint32(n.$2)
        ..string(null) // IndexRange
        ..qualifiedName(const QualifiedName(0, null)); // DataEncoding
    });
    return w.takeBytes();
  }

  /// Write do atributo Value; o DataValue leva só o valor.
  static Uint8List write({required int handle, required DateTime now, required NodeId token, required List<(NodeId, UaVariant)> values, int timeoutHint = 0}) {
    final w = UaWriter();
    _requestHeader(w, UaTypeIds.writeRequest, token: token, handle: handle, now: now, timeoutHint: timeoutHint);
    w.array<(NodeId, UaVariant)>(values, (v) {
      w
        ..nodeId(v.$1)
        ..uint32(UaAttribute.value)
        ..string(null)
        ..dataValue(UaDataValue(value: v.$2), valueOnly: true);
    });
    return w.takeBytes();
  }

  /// Browse para a frente pelas referências hierárquicas, só objetos e
  /// variáveis, com todos os campos da referência.
  static Uint8List browse({required int handle, required DateTime now, required NodeId token, required List<NodeId> nodes, int maxReferences = 1000, int timeoutHint = 0}) {
    final w = UaWriter();
    _requestHeader(w, UaTypeIds.browseRequest, token: token, handle: handle, now: now, timeoutHint: timeoutHint);
    w
      ..nodeId(NodeId.nullId) // View
      ..dateTime(null)
      ..uint32(0)
      ..uint32(maxReferences);
    w.array<NodeId>(nodes, (n) {
      w
        ..nodeId(n)
        ..uint32(0) // Forward
        ..nodeId(NodeId.hierarchicalReferences)
        ..boolean(true) // e subtipos
        ..uint32(UaNodeClass.object.code | UaNodeClass.variable.code)
        ..uint32(0x3F); // todos os campos
    });
    return w.takeBytes();
  }

  static Uint8List browseNext({required int handle, required DateTime now, required NodeId token, required List<Uint8List> continuationPoints, bool release = false, int timeoutHint = 0}) {
    final w = UaWriter();
    _requestHeader(w, UaTypeIds.browseNextRequest, token: token, handle: handle, now: now, timeoutHint: timeoutHint);
    w
      ..boolean(release)
      ..array<Uint8List>(continuationPoints, w.byteString);
    return w.takeBytes();
  }

  // ── Respostas ────────────────────────────────────────────────────────────────

  /// Lê o tipo e o cabeçalho. ServiceFault também passa por aqui (o
  /// [UaResponseHeader.serviceResult] diz o motivo).
  static UaResponse parse(Uint8List body) {
    final r = UaReader(body);
    final type = r.nodeId();
    if (type.namespace != 0 || type.kind != NodeIdKind.numeric) throw FormatException('tipo de resposta inesperado: $type');
    final timestamp = r.dateTime();
    final handle = r.uint32();
    final result = r.statusCode();
    r.diagnosticInfo();
    r.array(r.string); // StringTable
    r.extensionObject(); // AdditionalHeader
    return UaResponse(type.identifier as int, UaResponseHeader(requestHandle: handle, serviceResult: result, timestamp: timestamp), r);
  }

  static UaChannelToken parseOpenSecureChannel(UaReader r) {
    r.uint32(); // versão do servidor
    final channel = r.uint32();
    final token = r.uint32();
    r.dateTime(); // CreatedAt
    final lifetime = r.uint32();
    r.byteString(); // nonce do servidor
    return UaChannelToken(channelId: channel, tokenId: token, lifetimeMs: lifetime);
  }

  static void _applicationDescription(UaReader r) {
    r.string();
    r.string();
    r.localizedText();
    r.uint32();
    r.string();
    r.string();
    r.array(r.string);
  }

  static UaEndpoint _endpoint(UaReader r) {
    final url = r.string() ?? '';
    _applicationDescription(r);
    final cert = r.byteString();
    final mode = r.uint32();
    final policy = r.string() ?? '';
    final tokens = r.array(() {
      final id = r.string() ?? '';
      final type = r.uint32();
      r.string(); // IssuedTokenType
      r.string(); // IssuerEndpointUrl
      return UaUserTokenPolicy(policyId: id, tokenType: type, securityPolicyUri: r.string());
    });
    r.string(); // TransportProfileUri
    r.byte(); // SecurityLevel
    return UaEndpoint(endpointUrl: url, securityMode: mode, securityPolicyUri: policy, userTokens: tokens, serverCertificate: cert);
  }

  static List<UaEndpoint> parseGetEndpoints(UaReader r) => r.array(() => _endpoint(r));

  static UaSessionInfo parseCreateSession(UaReader r) {
    final sessionId = r.nodeId();
    final token = r.nodeId();
    final timeout = r.float64();
    final nonce = r.byteString();
    final cert = r.byteString();
    final endpoints = r.array(() => _endpoint(r));
    // Certificados de software, assinatura e tamanho máximo do pedido: o
    // modo None não usa. Servidor que corta a mensagem aqui ainda serve.
    return UaSessionInfo(sessionId: sessionId, authenticationToken: token, timeoutMs: timeout, serverNonce: nonce, serverCertificate: cert, endpoints: endpoints);
  }

  /// StatusCode de cada token/certificado na ativação.
  static List<int> parseActivateSession(UaReader r) {
    r.byteString(); // nonce novo
    return r.array(r.statusCode);
  }

  static List<UaDataValue> parseRead(UaReader r) => _withDiagnostics(r, r.array(r.dataValue));

  static List<int> parseWrite(UaReader r) => _withDiagnostics(r, r.array(r.statusCode));

  /// Os resultados e, depois deles, a lista de diagnósticos (que o app não
  /// usa, mas lê para a mensagem acabar onde deve).
  static T _withDiagnostics<T>(UaReader r, T results) {
    if (!r.atEnd) r.array(r.diagnosticInfo);
    return results;
  }

  static List<UaBrowseResult> parseBrowse(UaReader r) => _withDiagnostics(r, _browseResults(r));

  static List<UaBrowseResult> _browseResults(UaReader r) => r.array(() {
        final status = r.statusCode();
        final cp = r.byteString();
        final refs = r.array(() {
          final refType = r.nodeId();
          final forward = r.boolean();
          final (node, server) = r.expandedNodeId();
          final browseName = r.qualifiedName();
          final display = r.localizedText();
          final nodeClass = UaNodeClass.of(r.uint32());
          final (typeDef, _) = r.expandedNodeId();
          return UaReference(
            referenceTypeId: refType,
            isForward: forward,
            nodeId: node,
            serverIndex: server,
            browseName: browseName,
            displayName: display,
            nodeClass: nodeClass,
            typeDefinition: typeDef,
          );
        });
        return UaBrowseResult(status, cp, refs);
      });
}
