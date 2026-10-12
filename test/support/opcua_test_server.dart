import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ihm/core/opcua/opcua_crypto.dart' show Sha1;

import 'opcua_test_keys.dart';

/// Um nó do espaço de endereços do servidor de teste.
class TestUaNode {
  TestUaNode(this.id, this.name, {this.type, this.value, this.isArray = false, this.writable = false, this.isFolder = false, this.readStatus = 0});

  /// NodeId no texto da norma (`ns=2;s=Maquina.Temperatura`, `i=85`).
  final String id;
  final String name;

  /// Tipo embutido do valor (1 Boolean, 5 UInt16, 6 Int32, 10 Float, 11
  /// Double, 12 String…); nulo = objeto/pasta.
  final int? type;
  Object? value;
  final bool isArray;
  bool writable;
  final bool isFolder;

  /// StatusCode forçado na leitura (ex.: 0x80310000 BadNoCommunication).
  int readStatus;
  final List<String> children = [];

  bool get isVariable => type != null;
}

/// Servidor OPC UA mínimo, em Dart — um "servidor" para os testes de
/// integração do cliente.
///
/// Fala só o subconjunto que o cliente usa: Hello/Ack, OpenSecureChannel
/// (None, Issue e Renew), CreateSession, ActivateSession (anônimo, usuário e
/// senha, senha cifrada com RSA-OAEP), Read, Write, Browse/BrowseNext,
/// GetEndpoints, CloseSession e CLO. Sobe numa porta local e o cliente de
/// produção conversa com ele por socket de verdade.
///
/// Escrito à parte, com codificação própria (sem `opcua_binary.dart` nem
/// `opcua_messages.dart`), para que um erro de formato de um lado não seja
/// "confirmado" pelo outro. Do app só usa o SHA-1, que tem vetores próprios
/// no teste. A conferência contra um servidor de mercado é o asyncua (ver
/// docs/ARQUITETURA.md, §4.19).
///
/// Ganchos de teste: [allowAnonymous], [users], [passwordEncrypted],
/// [onlySecureEndpoints], [strictPath], [maxNodesPerRead],
/// [maxReferencesPerBrowse], [chunkSize] (resposta em vários pedaços),
/// [channelLifetimeMs], [responseDelay], [dropNextRequests],
/// [forgetSessions] (o servidor "reiniciou") e [closeAllClients].
class OpcUaTestServer {
  OpcUaTestServer({this.path = '/ware'});

  /// Caminho do endpoint (`opc.tcp://127.0.0.1:porta/ware`).
  final String path;

  bool allowAnonymous = true;
  final Map<String, String> users = {'operador': '1234'};

  /// O token de usuário pede a senha cifrada com o certificado (como o
  /// asyncua com certificado, o S7-1500...).
  bool passwordEncrypted = false;

  /// Só oferece Basic256Sha256 · SignAndEncrypt (o app não fala).
  bool onlySecureEndpoints = false;

  /// Hello com outro caminho volta ERR BadTcpEndpointUrlInvalid.
  bool strictPath = false;

  /// OperationLimits.MaxNodesPerRead (0 = não diz).
  int maxNodesPerRead = 0;

  /// Referências por Browse antes de mandar ponto de continuação.
  int maxReferencesPerBrowse = 1000;

  /// Divide cada resposta em pedaços ('C' … 'F') deste tamanho.
  int? chunkSize;

  /// Vida do token do canal (o cliente renova aos 75%).
  int channelLifetimeMs = 600000;

  Duration responseDelay = Duration.zero;
  int dropNextRequests = 0;

  // Contadores para os testes.
  int sessionsCreated = 0;
  int renewals = 0;
  int readRequests = 0;
  int writeRequests = 0;
  int browseNextRequests = 0;
  int closedSessions = 0;
  final List<int> readNodeCounts = [];
  final List<String> writtenTypes = [];

  /// Última senha recebida (já decifrada) e se veio cifrada.
  String? lastPassword;
  bool? lastPasswordWasEncrypted;

  final Map<String, TestUaNode> nodes = {};
  final Set<String> _validTokens = {};
  final Set<String> _activeTokens = {};
  int _nextChannel = 1;
  int _nextToken = 1;
  int _nextSession = 1;

  ServerSocket? _server;
  final List<Socket> _clients = [];

  int get port => _server!.port;
  int get clientCount => _clients.length;
  String get endpointUrl => 'opc.tcp://127.0.0.1:$port$path';

  /// Pasta Objects com o objeto Server (que a navegação esconde).
  void _baseNodes() {
    nodes['i=85'] = TestUaNode('i=85', 'Objects', isFolder: true)..children.add('i=2253');
    nodes['i=2253'] = TestUaNode('i=2253', 'Server');
    nodes['i=2259'] = TestUaNode('i=2259', 'State', type: 6, value: 0);
    nodes['i=11705'] = TestUaNode('i=11705', 'MaxNodesPerRead', type: 7, value: 0);
  }

  /// Acrescenta um nó sob [parent] (padrão: Objects).
  TestUaNode add(TestUaNode node, {String parent = 'i=85'}) {
    if (nodes.isEmpty) _baseNodes();
    nodes[node.id] = node;
    nodes[parent]!.children.add(node.id);
    return node;
  }

  TestUaNode node(String id) => nodes[id]!;

  /// Porta 0 = o sistema escolhe uma livre (testes em paralelo).
  Future<void> start({int port = 0}) async {
    if (nodes.isEmpty) _baseNodes();
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
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

  /// O servidor "reiniciou" sem derrubar o TCP: as sessões deixam de valer.
  void forgetSessions() {
    _validTokens.clear();
    _activeTokens.clear();
  }

  void _onClient(Socket socket) {
    _clients.add(socket);
    final conn = _Conn(socket);
    socket.listen(
      (data) {
        conn.rx.addAll(data);
        while (conn.rx.length >= 8) {
          final size = conn.rx[4] | (conn.rx[5] << 8) | (conn.rx[6] << 16) | (conn.rx[7] << 24);
          if (size < 8) {
            socket.destroy();
            return;
          }
          if (conn.rx.length < size) break;
          final msg = Uint8List.fromList(conn.rx.sublist(0, size));
          conn.rx.removeRange(0, size);
          // Uma mensagem por vez por conexão, na ordem.
          conn.queue = conn.queue.then((_) => _onMessage(conn, msg)).catchError((Object e) {
            stderr.writeln('OpcUaTestServer: $e');
          });
        }
      },
      onDone: () => _clients.remove(socket),
      onError: (_) => _clients.remove(socket),
      cancelOnError: true,
    );
  }

  Future<void> _onMessage(_Conn conn, Uint8List msg) async {
    final type = String.fromCharCodes(msg.sublist(0, 3));
    final r = _R(msg, 8);
    switch (type) {
      case 'HEL':
        r.u32();
        r.u32(); // ReceiveBufferSize do cliente
        r.u32();
        r.u32();
        r.u32();
        final url = r.str() ?? '';
        if (strictPath && !url.endsWith(path)) {
          final w = _W()
            ..u32(0x80830000)
            ..str('endpoint inexistente: $url');
          _send(conn, 'ERR', 'F', w.bytes());
          return;
        }
        final w = _W()
          ..u32(0)
          ..u32(65535) // o que este servidor aceita receber
          ..u32(chunkSize ?? 65535) // o maior pedaço que ele manda
          ..u32(0)
          ..u32(0);
        _send(conn, 'ACK', 'F', w.bytes());
      case 'OPN':
        final channel = r.u32();
        r.str(); // política
        r.bstr();
        r.bstr();
        r.u32(); // sequência
        final req = r.u32();
        final typeId = r.nodeNumeric();
        final handle = _requestHeader(r);
        r.u32(); // versão
        final kind = r.u32(); // 0 Issue, 1 Renew
        r.u32(); // modo
        r.bstr();
        r.u32(); // vida pedida
        if (typeId != 446) return;
        if (kind == 1) {
          renewals++;
          if (channel != conn.channel) {
            await _fault(conn, req, handle, 0x80220000, open: true);
            return;
          }
        } else {
          conn.channel = _nextChannel++;
        }
        conn.token = _nextToken++;
        final w = _W()..nodeNumeric(449);
        _responseHeader(w, handle);
        w
          ..u32(0)
          ..u32(conn.channel)
          ..u32(conn.token)
          ..i64(0)
          ..u32(channelLifetimeMs)
          ..bstr(const []);
        await _reply(conn, 'OPN', req, w.bytes());
      case 'CLO':
        // Quem destrói o próprio socket não recebe o onDone: sai da lista aqui.
        _clients.remove(conn.socket);
        conn.socket.destroy();
      case 'MSG':
        r.u32(); // canal
        r.u32(); // token
        r.u32(); // sequência
        final req = r.u32();
        final chunk = String.fromCharCode(msg[3]);
        conn.partial.add(r.rest());
        if (chunk == 'C') return;
        final body = conn.partial.takeBytes();
        await _onService(conn, req, _R(body, 0));
    }
  }

  Future<void> _onService(_Conn conn, int req, _R r) async {
    final typeId = r.nodeNumeric();
    final token = r.nodeText();
    r.i64(); // horário
    final handle = r.u32();
    r.u32();
    r.str();
    r.u32();
    r.extObj();
    if (dropNextRequests > 0 && (typeId == 631 || typeId == 673)) {
      dropNextRequests--;
      return;
    }
    switch (typeId) {
      case 428: // GetEndpoints
        final w = _W()..nodeNumeric(431);
        _responseHeader(w, handle);
        _endpoints(w);
        await _reply(conn, 'MSG', req, w.bytes());
      case 461: // CreateSession
        sessionsCreated++;
        final session = _nextSession++;
        final auth = 'ns=1;i=${100000 + session}';
        _validTokens.add(auth);
        final w = _W()..nodeNumeric(464);
        _responseHeader(w, handle);
        w
          ..nodeFourByte(1, session) // SessionId
          ..nodeNumericFull(1, 100000 + session) // AuthenticationToken
          ..f64(60000)
          ..bstr(conn.nonce = Uint8List.fromList(List.generate(32, (i) => (i * 7 + session) & 0xFF)))
          ..bstr(_certificate);
        _endpoints(w);
        w
          ..i32(0) // certificados de software
          ..str(null) // assinatura
          ..bstr(null)
          ..u32(0);
        await _reply(conn, 'MSG', req, w.bytes());
      case 467: // ActivateSession
        if (!_validTokens.contains(token)) {
          await _fault(conn, req, handle, 0x80250000);
          return;
        }
        r.str();
        r.bstr();
        final certs = r.i32();
        for (var i = 0; i < certs; i++) {
          r.bstr();
          r.bstr();
        }
        final locales = r.i32();
        for (var i = 0; i < locales; i++) {
          r.str();
        }
        final identityType = r.nodeNumeric();
        r.u8(); // codificação
        r.i32(); // tamanho do corpo
        final policy = r.str();
        var ok = false;
        if (identityType == 321) {
          ok = allowAnonymous && policy == 'anonymous';
        } else if (identityType == 324) {
          final user = r.str();
          final pass = r.bstr() ?? Uint8List(0);
          final algorithm = r.str();
          String? clear;
          if (algorithm == null || algorithm.isEmpty) {
            lastPasswordWasEncrypted = false;
            clear = passwordEncrypted ? null : utf8.decode(pass);
          } else {
            lastPasswordWasEncrypted = true;
            clear = _decryptPassword(pass, conn.nonce);
          }
          lastPassword = clear;
          ok = policy == 'username' && user != null && clear != null && users[user] == clear;
        }
        if (!ok) {
          await _fault(conn, req, handle, 0x80210000); // BadIdentityTokenRejected
          return;
        }
        _activeTokens.add(token);
        final w = _W()..nodeNumeric(470);
        _responseHeader(w, handle);
        w
          ..bstr(const [9, 9, 9])
          ..i32(0)
          ..i32(0);
        await _reply(conn, 'MSG', req, w.bytes());
      case 473: // CloseSession
        closedSessions++;
        _validTokens.remove(token);
        _activeTokens.remove(token);
        final w = _W()..nodeNumeric(476);
        _responseHeader(w, handle);
        await _reply(conn, 'MSG', req, w.bytes());
      case 631 || 673 || 527 || 533:
        if (!_validTokens.contains(token)) {
          await _fault(conn, req, handle, 0x80250000); // BadSessionIdInvalid
          return;
        }
        if (!_activeTokens.contains(token)) {
          await _fault(conn, req, handle, 0x80270000); // BadSessionNotActivated
          return;
        }
        final w = switch (typeId) {
          631 => _read(r, handle),
          673 => _write(r, handle),
          527 => _browse(r, handle, conn),
          _ => _browseNext(r, handle, conn),
        };
        await _reply(conn, 'MSG', req, w.bytes());
      default:
        await _fault(conn, req, handle, 0x800B0000); // BadServiceUnsupported
    }
  }

  void _endpoints(_W w) {
    final list = onlySecureEndpoints
        ? [(3, 'http://opcfoundation.org/UA/SecurityPolicy#Basic256Sha256')]
        : [(1, 'http://opcfoundation.org/UA/SecurityPolicy#None')];
    w.i32(list.length);
    for (final (mode, policy) in list) {
      w
        ..str(endpointUrl)
        ..str('urn:ware-iot:servidor-de-teste') // ApplicationDescription
        ..str('urn:ware-iot')
        ..u8(0x02)
        ..str('Servidor de teste')
        ..u32(0)
        ..str(null)
        ..str(null)
        ..i32(-1)
        ..bstr(_certificate)
        ..u32(mode)
        ..str(policy);
      final tokens = <(String, int, String?)>[
        if (allowAnonymous) ('anonymous', 0, null),
        ('username', 1, passwordEncrypted ? 'http://opcfoundation.org/UA/SecurityPolicy#Basic256Sha256' : null),
      ];
      w.i32(tokens.length);
      for (final (id, type, sec) in tokens) {
        w
          ..str(id)
          ..u32(type)
          ..str(null)
          ..str(null)
          ..str(sec);
      }
      w
        ..str('http://opcfoundation.org/UA-Profile/Transport/uatcp-uasc-uabinary')
        ..u8(0);
    }
  }

  _W _read(_R r, int handle) {
    readRequests++;
    r.f64();
    r.u32();
    final n = r.i32();
    readNodeCounts.add(n);
    final w = _W()..nodeNumeric(634);
    final results = <void Function(_W)>[];
    var tooMany = false;
    if (maxNodesPerRead > 0 && n > maxNodesPerRead) tooMany = true;
    for (var i = 0; i < n; i++) {
      final id = r.nodeText();
      final attr = r.u32();
      r.str();
      r.u16();
      r.str();
      results.add((w) => _dataValue(w, id, attr));
    }
    _responseHeader(w, handle, result: tooMany ? 0x80100000 : 0);
    if (tooMany) {
      w
        ..i32(-1)
        ..i32(-1);
      return w;
    }
    w.i32(results.length);
    for (final f in results) {
      f(w);
    }
    w.i32(0);
    return w;
  }

  void _dataValue(_W w, String id, int attr) {
    if (id == 'i=11705') nodes[id]!.value = maxNodesPerRead;
    final node = nodes[id];
    if (node == null) {
      w
        ..u8(0x02)
        ..u32(0x80340000); // BadNodeIdUnknown
      return;
    }
    if (attr == 18 || attr == 17) {
      w
        ..u8(0x01)
        ..u8(3)
        ..u8(node.writable ? 0x03 : 0x01);
      return;
    }
    if (attr == 4) {
      w
        ..u8(0x01)
        ..u8(21)
        ..u8(0x02)
        ..str(node.name);
      return;
    }
    if (attr != 13 || !node.isVariable) {
      w
        ..u8(0x02)
        ..u32(0x80350000); // BadAttributeIdInvalid
      return;
    }
    if (node.readStatus != 0) {
      w
        ..u8(0x02)
        ..u32(node.readStatus);
      return;
    }
    w.u8(0x01);
    _variant(w, node.type!, node.value, node.isArray);
  }

  _W _write(_R r, int handle) {
    writeRequests++;
    final n = r.i32();
    final codes = <int>[];
    for (var i = 0; i < n; i++) {
      final id = r.nodeText();
      r.u32(); // atributo
      r.str();
      final mask = r.u8();
      int? type;
      Object? value;
      if (mask & 0x01 != 0) {
        final vt = r.u8();
        type = vt & 0x3F;
        value = _readScalar(r, type);
      }
      if (mask & 0x02 != 0) r.u32();
      if (mask & 0x04 != 0) r.i64();
      if (mask & 0x08 != 0) r.i64();
      writtenTypes.add('$type');
      final node = nodes[id];
      if (node == null) {
        codes.add(0x80340000);
      } else if (mask != 0x01) {
        codes.add(0x80730000); // BadWriteNotSupported (status/horário junto)
      } else if (!node.writable) {
        codes.add(0x803B0000); // BadNotWritable
      } else if (type != node.type) {
        codes.add(0x80740000); // BadTypeMismatch
      } else {
        node.value = value;
        codes.add(0);
      }
    }
    final w = _W()..nodeNumeric(676);
    _responseHeader(w, handle);
    w.i32(codes.length);
    for (final c in codes) {
      w.u32(c);
    }
    w.i32(0);
    return w;
  }

  _W _browse(_R r, int handle, _Conn conn) {
    r.nodeText(); // View
    r.i64();
    r.u32();
    r.u32(); // máximo pedido pelo cliente
    final n = r.i32();
    final w = _W()..nodeNumeric(530);
    _responseHeader(w, handle);
    w.i32(n);
    for (var i = 0; i < n; i++) {
      final id = r.nodeText();
      r.u32();
      r.nodeText();
      r.u8();
      r.u32();
      r.u32();
      final node = nodes[id];
      if (node == null) {
        w
          ..u32(0x80340000)
          ..bstr(null)
          ..i32(0);
        continue;
      }
      _browseResult(w, node.children, conn);
    }
    w.i32(0);
    return w;
  }

  _W _browseNext(_R r, int handle, _Conn conn) {
    browseNextRequests++;
    r.u8(); // liberar
    final n = r.i32();
    final w = _W()..nodeNumeric(536);
    _responseHeader(w, handle);
    w.i32(n);
    for (var i = 0; i < n; i++) {
      final cp = r.bstr();
      final rest = cp == null ? null : conn.continuations.remove(cp.first);
      if (rest == null) {
        w
          ..u32(0x804A0000)
          ..bstr(null)
          ..i32(0);
        continue;
      }
      _browseResult(w, rest, conn);
    }
    w.i32(0);
    return w;
  }

  void _browseResult(_W w, List<String> children, _Conn conn) {
    final now = children.take(maxReferencesPerBrowse).toList();
    final rest = children.skip(maxReferencesPerBrowse).toList();
    w.u32(0);
    if (rest.isEmpty) {
      w.bstr(null);
    } else {
      final cp = conn.nextContinuation++ & 0xFF;
      conn.continuations[cp] = rest;
      w.bstr([cp]);
    }
    w.i32(now.length);
    for (final id in now) {
      final c = nodes[id]!;
      w
        ..u8(0x00)
        ..u8(c.isVariable ? 47 : 35) // HasComponent / Organizes
        ..u8(1);
      _nodeIdFromText(w, c.id);
      w
        ..u16(_ns(c.id))
        ..str(c.name)
        ..u8(0x02)
        ..str(c.name)
        ..u32(c.isVariable ? 2 : 1)
        ..u8(0x00)
        ..u8(c.isVariable ? 63 : 61);
    }
  }

  // ── Decifrar a senha (RSA-OAEP, SHA-1) ──────────────────────────────────────

  static final Uint8List _certificate = _hex(opcUaTestCertificate);
  static final BigInt _n = BigInt.parse(opcUaTestModulus, radix: 16);
  static final BigInt _d = BigInt.parse(opcUaTestPrivateExponent, radix: 16);

  /// Decifra a senha (formato da norma: tamanho + senha + nonce) com a chave
  /// privada de teste; nulo se o formato não fecha ou o nonce não confere.
  static String? decryptPasswordWith(Uint8List cipher, Uint8List nonce) {
    final m = oaepDecrypt(cipher);
    if (m == null || m.length < 4) return null;
    final len = m[0] | (m[1] << 8) | (m[2] << 16) | (m[3] << 24);
    if (len != m.length - 4 || len < nonce.length) return null;
    final pwd = m.sublist(4, m.length - nonce.length);
    final got = m.sublist(m.length - nonce.length);
    for (var i = 0; i < nonce.length; i++) {
      if (got[i] != nonce[i]) return null;
    }
    return utf8.decode(pwd);
  }

  String? _decryptPassword(Uint8List cipher, Uint8List nonce) => decryptPasswordWith(cipher, nonce);

  /// RSA-OAEP (SHA-1, MGF1-SHA1, rótulo vazio) com a chave privada de teste.
  static Uint8List? oaepDecrypt(Uint8List cipher) {
    const k = 256, hLen = 20;
    if (cipher.length % k != 0 || cipher.isEmpty) return null;
    final out = BytesBuilder();
    for (var off = 0; off < cipher.length; off += k) {
      var c = BigInt.zero;
      for (final b in cipher.sublist(off, off + k)) {
        c = (c << 8) | BigInt.from(b);
      }
      final mInt = c.modPow(_d, _n);
      final em = Uint8List(k);
      var x = mInt;
      for (var i = k - 1; i >= 0; i--) {
        em[i] = (x & BigInt.from(0xFF)).toInt();
        x = x >> 8;
      }
      if (em[0] != 0) return null;
      final maskedSeed = em.sublist(1, 1 + hLen);
      final maskedDb = em.sublist(1 + hLen);
      final seed = _xor(maskedSeed, _mgf1(maskedDb, hLen));
      final db = _xor(maskedDb, _mgf1(seed, maskedDb.length));
      final lHash = Sha1.hash(const []);
      for (var i = 0; i < hLen; i++) {
        if (db[i] != lHash[i]) return null;
      }
      var p = hLen;
      while (p < db.length && db[p] == 0) {
        p++;
      }
      if (p >= db.length || db[p] != 1) return null;
      out.add(db.sublist(p + 1));
    }
    return out.takeBytes();
  }

  static Uint8List _mgf1(List<int> seed, int len) {
    final out = BytesBuilder();
    for (var c = 0; out.length < len; c++) {
      out.add(Sha1.hash([...seed, (c >> 24) & 0xFF, (c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF]));
    }
    return Uint8List.fromList(out.takeBytes().sublist(0, len));
  }

  static Uint8List _xor(List<int> a, List<int> b) => Uint8List.fromList([for (var i = 0; i < a.length; i++) a[i] ^ b[i]]);

  static Uint8List _hex(String h) => Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

  // ── Envio ──────────────────────────────────────────────────────────────────

  int _requestHeader(_R r) {
    r.nodeText();
    r.i64();
    final handle = r.u32();
    r.u32();
    r.str();
    r.u32();
    r.extObj();
    return handle;
  }

  void _responseHeader(_W w, int handle, {int result = 0}) {
    w
      ..i64(0)
      ..u32(handle)
      ..u32(result)
      ..u8(0) // diagnóstico
      ..i32(0) // StringTable
      ..u8(0)
      ..u8(0)
      ..u8(0); // AdditionalHeader nulo
  }

  Future<void> _fault(_Conn conn, int req, int handle, int code, {bool open = false}) async {
    final w = _W()..nodeFourByte(0, 397);
    _responseHeader(w, handle, result: code);
    await _reply(conn, open ? 'OPN' : 'MSG', req, w.bytes());
  }

  Future<void> _reply(_Conn conn, String type, int req, Uint8List body) async {
    if (responseDelay > Duration.zero) await Future<void>.delayed(responseDelay);
    if (type == 'OPN') {
      final w = _W()
        ..u32(conn.channel)
        ..str('http://opcfoundation.org/UA/SecurityPolicy#None')
        ..bstr(null)
        ..bstr(null)
        ..u32(conn.sequence++)
        ..u32(req)
        ..raw(body);
      _send(conn, 'OPN', 'F', w.bytes());
      return;
    }
    // Pedaços de até [chunkSize] bytes (cabeçalho de 24 incluso).
    final room = (chunkSize ?? 65535) - 24;
    var off = 0;
    do {
      final end = off + room < body.length ? off + room : body.length;
      final w = _W()
        ..u32(conn.channel)
        ..u32(conn.token)
        ..u32(conn.sequence++)
        ..u32(req)
        ..raw(body.sublist(off, end));
      _send(conn, type, end == body.length ? 'F' : 'C', w.bytes());
      off = end;
      if (chunkSize != null) {
        try {
          await conn.socket.flush();
        } catch (_) {}
      }
    } while (off < body.length);
  }

  void _send(_Conn conn, String type, String chunk, Uint8List body) {
    final w = _W()
      ..raw(type.codeUnits)
      ..raw(chunk.codeUnits)
      ..u32(body.length + 8)
      ..raw(body);
    try {
      conn.socket.add(w.bytes());
    } catch (_) {}
  }

  // ── Codificação própria (só o que o servidor precisa) ──────────────────────

  static int _ns(String id) => id.startsWith('ns=') ? int.parse(id.substring(3, id.indexOf(';'))) : 0;

  static void _nodeIdFromText(_W w, String id) {
    final ns = _ns(id);
    final rest = id.startsWith('ns=') ? id.substring(id.indexOf(';') + 1) : id;
    if (rest.startsWith('i=')) {
      w.nodeNumericFull(ns, int.parse(rest.substring(2)));
    } else {
      w
        ..u8(0x03)
        ..u16(ns)
        ..str(rest.substring(2));
    }
  }

  static void _variant(_W w, int type, Object? value, bool isArray) {
    if (isArray) {
      final list = value as List;
      w
        ..u8(type | 0x80)
        ..i32(list.length);
      for (final v in list) {
        _scalar(w, type, v);
      }
      return;
    }
    w.u8(type);
    _scalar(w, type, value);
  }

  static void _scalar(_W w, int type, Object? v) {
    final b = ByteData(8);
    switch (type) {
      case 1:
        w.u8(v == true ? 1 : 0);
      case 2 || 3:
        w.u8(v as int);
      case 4:
        b.setInt16(0, v as int, Endian.little);
        w.raw(b.buffer.asUint8List(0, 2));
      case 5:
        w.u16(v as int);
      case 6:
        w.i32(v as int);
      case 7:
        w.u32(v as int);
      case 8 || 9:
        w.i64(v as int);
      case 10:
        b.setFloat32(0, (v as num).toDouble(), Endian.little);
        w.raw(b.buffer.asUint8List(0, 4));
      case 11:
        w.f64((v as num).toDouble());
      case 12:
        w.str(v as String?);
      default:
        throw ArgumentError('tipo $type não usado no servidor de teste');
    }
  }

  static Object? _readScalar(_R r, int type) => switch (type) {
        1 => r.u8() != 0,
        2 => r.u8().toSigned(8),
        3 => r.u8(),
        4 => r.u16().toSigned(16),
        5 => r.u16(),
        6 => r.i32(),
        7 => r.u32(),
        8 || 9 => r.i64(),
        10 => r.f32(),
        11 => r.f64(),
        12 => r.str(),
        _ => throw ArgumentError('tipo $type não lido no servidor de teste'),
      };
}

class _Conn {
  _Conn(this.socket);
  final Socket socket;
  final List<int> rx = [];
  final BytesBuilder partial = BytesBuilder();
  Future<void> queue = Future.value();
  int channel = 0;
  int token = 0;
  int sequence = 1;
  Uint8List nonce = Uint8List(0);
  int nextContinuation = 1;
  final Map<int, List<String>> continuations = {};
}

class _W {
  final BytesBuilder _b = BytesBuilder();
  final ByteData _s = ByteData(8);

  Uint8List bytes() => _b.toBytes();
  void raw(List<int> v) => _b.add(v);
  void u8(int v) => _b.addByte(v & 0xFF);
  void u16(int v) {
    _s.setUint16(0, v, Endian.little);
    _b.add(_s.buffer.asUint8List(0, 2));
  }

  void u32(int v) {
    _s.setUint32(0, v, Endian.little);
    _b.add(_s.buffer.asUint8List(0, 4));
  }

  void i32(int v) {
    _s.setInt32(0, v, Endian.little);
    _b.add(_s.buffer.asUint8List(0, 4));
  }

  void i64(int v) {
    _s.setInt64(0, v, Endian.little);
    _b.add(_s.buffer.asUint8List(0, 8));
  }

  void f64(double v) {
    _s.setFloat64(0, v, Endian.little);
    _b.add(_s.buffer.asUint8List(0, 8));
  }

  void str(String? v) {
    if (v == null) {
      i32(-1);
      return;
    }
    final e = utf8.encode(v);
    i32(e.length);
    _b.add(e);
  }

  void bstr(List<int>? v) {
    if (v == null) {
      i32(-1);
      return;
    }
    i32(v.length);
    _b.add(v);
  }

  void nodeNumeric(int id) => nodeFourByte(0, id);

  void nodeFourByte(int ns, int id) {
    u8(0x01);
    u8(ns);
    u16(id);
  }

  void nodeNumericFull(int ns, int id) {
    u8(0x02);
    u16(ns);
    u32(id);
  }
}

class _R {
  _R(this._b, this._p) : _d = ByteData.sublistView(_b);
  final Uint8List _b;
  final ByteData _d;
  int _p;

  int u8() => _b[_p++];
  int u16() {
    final v = _d.getUint16(_p, Endian.little);
    _p += 2;
    return v;
  }

  int u32() {
    final v = _d.getUint32(_p, Endian.little);
    _p += 4;
    return v;
  }

  int i32() {
    final v = _d.getInt32(_p, Endian.little);
    _p += 4;
    return v;
  }

  int i64() {
    final v = _d.getInt64(_p, Endian.little);
    _p += 8;
    return v;
  }

  double f32() {
    final v = _d.getFloat32(_p, Endian.little);
    _p += 4;
    return v;
  }

  double f64() {
    final v = _d.getFloat64(_p, Endian.little);
    _p += 8;
    return v;
  }

  String? str() {
    final n = i32();
    if (n < 0) return null;
    final s = utf8.decode(_b.sublist(_p, _p + n));
    _p += n;
    return s;
  }

  Uint8List? bstr() {
    final n = i32();
    if (n < 0) return null;
    final s = Uint8List.fromList(_b.sublist(_p, _p + n));
    _p += n;
    return s;
  }

  Uint8List rest() => Uint8List.fromList(_b.sublist(_p));

  /// NodeId numérico (qualquer forma), só o número.
  int nodeNumeric() {
    final t = u8();
    return switch (t & 0x3F) {
      0 => u8(),
      1 => (() {
          u8();
          return u16();
        })(),
      2 => (() {
          u16();
          return u32();
        })(),
      _ => throw ArgumentError('NodeId numérico esperado (forma $t)'),
    };
  }

  /// NodeId no texto da norma.
  String nodeText() {
    final t = u8() & 0x3F;
    String text(int ns, String id) => ns == 0 ? id : 'ns=$ns;$id';
    switch (t) {
      case 0:
        return text(0, 'i=${u8()}');
      case 1:
        final ns = u8();
        return text(ns, 'i=${u16()}');
      case 2:
        final ns = u16();
        return text(ns, 'i=${u32()}');
      case 3:
        final ns = u16();
        return text(ns, 's=${str()}');
      case 4:
        final ns = u16();
        final g = _b.sublist(_p, _p + 16);
        _p += 16;
        return text(ns, 'g=${g.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
      default:
        throw ArgumentError('forma de NodeId $t');
    }
  }

  void extObj() {
    nodeText();
    final enc = u8();
    if (enc != 0) bstr();
  }
}
