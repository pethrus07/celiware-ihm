import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Uma mensagem que passou pelo broker.
class BrokerMessage {
  const BrokerMessage(this.topic, this.payload, {this.qos = 0, this.retain = false, this.clientId});
  final String topic;
  final String payload;
  final int qos;
  final bool retain;

  /// Quem publicou (nulo = o próprio teste, fazendo o papel do equipamento).
  final String? clientId;

  @override
  String toString() => '$topic = $payload (QoS $qos${retain ? ', retain' : ''})';
}

/// Broker MQTT 3.1.1 mínimo, em Dart, para os testes.
///
/// Mesma ideia do `ModbusTcpServer`: sobe numa porta local e o cliente de
/// verdade (`mqtt_client`, por baixo do `MqttDriver`) conversa com ele por
/// socket — CONNECT/CONNACK (com usuário e senha opcionais), SUBSCRIBE/SUBACK
/// com curingas `+` e `#`, UNSUBSCRIBE, PUBLISH QoS 0 e 1 com PUBACK, retain
/// (inclusive apagar com mensagem vazia), PINGREQ, DISCONNECT e o testamento
/// (LWT) de quem cai sem se despedir. QoS 2 fica de fora (o app não usa).
///
/// Mora em `test/` e não em `lib/` (como o escravo Modbus): nada do app usa
/// um broker, e ele foi escrito **sem** o código do app — codificação e
/// casamento de tópico próprios. Se os dois lados dividissem o mesmo
/// `matches`, um erro de curinga passaria nos testes dos dois lados.
///
/// [stop] derruba conexões e porta mas guarda as mensagens com retain, como
/// um Mosquitto com persistência: [start] na mesma porta é o broker voltando.
class MqttTestBroker {
  MqttTestBroker({this.username, this.password});

  /// Com usuário definido, CONNECT com outro usuário/senha leva CONNACK 4.
  final String? username;
  final String? password;

  ServerSocket? _server;
  int _port = 0;
  final List<_Client> _clients = [];

  /// Mensagens guardadas por tópico (retain).
  final Map<String, BrokerMessage> retained = {};

  /// Tudo que os clientes publicaram, na ordem.
  final List<BrokerMessage> received = [];
  final StreamController<BrokerMessage> _onPublish = StreamController.broadcast();

  int pings = 0;
  int connects = 0;

  int get port => _port;
  Stream<BrokerMessage> get onPublish => _onPublish.stream;

  /// Filtros assinados agora, somando todos os clientes.
  Set<String> get subscriptions => {for (final c in _clients) ...c.subs.keys};
  List<String> get clientIds => [for (final c in _clients) if (c.id != null) c.id!];

  /// Porta 0 = o sistema escolhe uma livre.
  Future<void> start({int port = 0}) async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    _port = _server!.port;
    _server!.listen(_accept);
  }

  /// Broker caiu: fecha a porta e derruba todos sem testamento (quem caiu foi
  /// o broker, não o equipamento).
  Future<void> stop() async {
    await _server?.close();
    _server = null;
    for (final c in List.of(_clients)) {
      c.clean = true;
      c.socket.destroy();
    }
    _clients.clear();
  }

  Future<void> close() async {
    await stop();
    await _onPublish.close();
  }

  /// Publica como se fosse o equipamento.
  void publish(String topic, String payload, {bool retain = false, int qos = 0}) =>
      _route(BrokerMessage(topic, payload, qos: qos, retain: retain));

  /// Derruba um cliente como se a rede dele tivesse caído: o broker publica
  /// o testamento (LWT), se houver.
  void drop(String clientId) {
    for (final c in _clients.where((c) => c.id == clientId).toList()) {
      c.socket.destroy();
      _gone(c);
    }
  }

  // ── Conexões ────────────────────────────────────────────────────────────────

  void _accept(Socket socket) {
    final c = _Client(socket);
    _clients.add(c);
    socket.listen(
      (data) => _onData(c, data),
      onDone: () => _gone(c),
      onError: (_) => _gone(c),
      cancelOnError: true,
    );
  }

  /// Conexão fechada. Sem DISCONNECT antes = queda: vale o testamento.
  void _gone(_Client c) {
    if (!_clients.remove(c)) return;
    final will = c.will;
    if (!c.clean && will != null) _route(will);
  }

  void _onData(_Client c, Uint8List data) {
    c.buffer.addAll(data);
    while (c.buffer.length >= 2) {
      // Comprimento restante: 1 a 4 bytes, 7 bits cada (MQTT 3.1.1 §2.2.3).
      var length = 0, mult = 1, i = 1;
      while (true) {
        if (i >= c.buffer.length) return;
        final b = c.buffer[i++];
        length += (b & 0x7F) * mult;
        mult *= 128;
        if (b & 0x80 == 0) break;
        if (i > 4) {
          c.socket.destroy();
          return;
        }
      }
      if (c.buffer.length < i + length) return;
      final type = c.buffer[0] >> 4, flags = c.buffer[0] & 0x0F;
      final body = Uint8List.fromList(c.buffer.sublist(i, i + length));
      c.buffer.removeRange(0, i + length);
      _handle(c, type, flags, body);
    }
  }

  void _handle(_Client c, int type, int flags, Uint8List body) {
    final r = _Reader(body);
    switch (type) {
      case 1: // CONNECT
        final protocol = r.string();
        final level = r.byte();
        final cf = r.byte();
        r.u16(); // keep-alive: este broker não derruba ninguém por silêncio
        c.id = r.string();
        if (cf & 0x04 != 0) {
          final topic = r.string();
          final message = utf8.decode(r.binary());
          c.will = BrokerMessage(topic, message, qos: (cf >> 3) & 0x03, retain: cf & 0x20 != 0, clientId: c.id);
        }
        final user = cf & 0x80 != 0 ? r.string() : null;
        final pass = cf & 0x40 != 0 ? utf8.decode(r.binary()) : null;
        if (protocol != 'MQTT' || level != 4) {
          _refuse(c, 1);
          return;
        }
        if (username != null && (user != username || pass != password)) {
          _refuse(c, 4);
          return;
        }
        // Mesmo ID conectado de novo: a norma manda derrubar o antigo.
        for (final old in _clients.where((o) => o != c && o.id == c.id).toList()) {
          old.clean = true;
          old.socket.destroy();
          _clients.remove(old);
        }
        connects++;
        c.send([0x20, 0x02, 0x00, 0x00]);
      case 3: // PUBLISH
        final qos = (flags >> 1) & 0x03;
        final retain = flags & 0x01 != 0;
        final topic = r.string();
        final id = qos > 0 ? r.u16() : 0;
        final m = BrokerMessage(topic, utf8.decode(r.rest()), qos: qos, retain: retain, clientId: c.id);
        if (qos > 0) c.send([0x40, 0x02, id >> 8, id & 0xFF]);
        received.add(m);
        _onPublish.add(m);
        _route(m);
      case 8: // SUBSCRIBE
        final id = r.u16();
        final codes = <int>[];
        final added = <String, int>{};
        while (!r.done) {
          final filter = r.string();
          final qos = r.byte();
          if (!_validFilter(filter)) {
            codes.add(0x80);
            continue;
          }
          final granted = qos > 1 ? 1 : qos;
          c.subs[filter] = granted;
          added[filter] = granted;
          codes.add(granted);
        }
        c.send([0x90, ..._length(2 + codes.length), id >> 8, id & 0xFF, ...codes]);
        // Assinatura nova recebe na hora o que está guardado (retain = 1).
        for (final e in added.entries) {
          for (final m in retained.values.where((m) => _matches(e.key, m.topic))) {
            _deliver(c, m, qos: m.qos < e.value ? m.qos : e.value, retain: true);
          }
        }
      case 10: // UNSUBSCRIBE
        final id = r.u16();
        while (!r.done) {
          c.subs.remove(r.string());
        }
        c.send([0xB0, 0x02, id >> 8, id & 0xFF]);
      case 12: // PINGREQ
        pings++;
        c.send([0xD0, 0x00]);
      case 14: // DISCONNECT
        c.clean = true;
        c.socket.destroy();
        _gone(c);
      default: // PUBACK do cliente e o resto: nada a fazer
        break;
    }
  }

  void _refuse(_Client c, int code) {
    c.send([0x20, 0x02, 0x00, code]);
    c.clean = true;
    Future<void>.delayed(const Duration(milliseconds: 50), c.socket.destroy);
  }

  void _route(BrokerMessage m) {
    if (m.retain) {
      if (m.payload.isEmpty) {
        retained.remove(m.topic);
      } else {
        retained[m.topic] = m;
      }
    }
    for (final c in List.of(_clients)) {
      // Várias assinaturas do mesmo cliente casando: entrega uma vez, no
      // maior QoS concedido.
      int? granted;
      for (final e in c.subs.entries) {
        if (_matches(e.key, m.topic) && (granted == null || e.value > granted)) granted = e.value;
      }
      if (granted != null) _deliver(c, m, qos: m.qos < granted ? m.qos : granted, retain: false);
    }
  }

  void _deliver(_Client c, BrokerMessage m, {required int qos, required bool retain}) {
    final topic = utf8.encode(m.topic);
    final payload = utf8.encode(m.payload);
    final body = <int>[topic.length >> 8, topic.length & 0xFF, ...topic];
    if (qos > 0) {
      final id = c.nextId();
      body.addAll([id >> 8, id & 0xFF]);
    }
    body.addAll(payload);
    c.send([0x30 | (qos << 1) | (retain ? 1 : 0), ..._length(body.length), ...body]);
  }

  static List<int> _length(int n) {
    final out = <int>[];
    do {
      var b = n % 128;
      n ~/= 128;
      if (n > 0) b |= 0x80;
      out.add(b);
    } while (n > 0);
    return out;
  }

  static bool _validFilter(String f) {
    if (f.isEmpty) return false;
    final levels = f.split('/');
    for (var i = 0; i < levels.length; i++) {
      if (levels[i].contains('#') && (levels[i] != '#' || i != levels.length - 1)) return false;
      if (levels[i].contains('+') && levels[i] != '+') return false;
    }
    return true;
  }

  /// Casamento escrito à parte do app, de propósito (ver a classe).
  static bool _matches(String filter, String topic) {
    if (topic.startsWith(r'$') && (filter.startsWith('#') || filter.startsWith('+'))) return false;
    if (filter == '#') return true;
    final f = filter.split('/');
    final t = topic.split('/');
    var i = 0;
    for (; i < f.length; i++) {
      if (f[i] == '#') return i <= t.length;
      if (i == t.length) return false;
      if (f[i] != '+' && f[i] != t[i]) return false;
    }
    return i == t.length;
  }
}

class _Client {
  _Client(this.socket);
  final Socket socket;
  final List<int> buffer = [];
  final Map<String, int> subs = {};
  String? id;
  BrokerMessage? will;

  /// Saiu com DISCONNECT (ou o broker derrubou): sem testamento.
  bool clean = false;
  int _id = 0;

  int nextId() => _id = _id % 65535 + 1;

  void send(List<int> bytes) {
    try {
      socket.add(bytes);
    } catch (_) {/* já fechou */}
  }
}

class _Reader {
  _Reader(this._b);
  final Uint8List _b;
  int _i = 0;

  bool get done => _i >= _b.length;
  int byte() => _b[_i++];
  int u16() => (_b[_i++] << 8) | _b[_i++];
  List<int> binary() {
    final n = u16();
    final out = _b.sublist(_i, _i + n);
    _i += n;
    return out;
  }

  String string() => utf8.decode(binary());
  List<int> rest() {
    final out = _b.sublist(_i);
    _i = _b.length;
    return out;
  }
}
