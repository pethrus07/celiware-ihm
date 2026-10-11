import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'message_parser.dart';

/// "Arduino falso" em Dart — o que um sketch com `WiFiServer`/`WiFiUDP` faz,
/// por TCP ou UDP.
///
/// Existe para os testes: o [RawClient] real conversa com ele por socket de
/// verdade. Para testar o app à mão use `sim/arduino_falso.py` (ver
/// docs/SIMULACAO.md), que fala o mesmo protocolo.
///
/// O sketch imitado, em linhas de texto:
///   • transmite o estado (`T=25.3;P=1\n`) a cada [streamEvery] — nulo = só
///     quando pedem (polling);
///   • `?` → responde o estado na hora;
///   • `SET K=V` → muda o valor e responde o estado novo (é a confirmação
///     de que o comando pegou).
class FakeArduinoServer {
  FakeArduinoServer({this.udp = false, this.streamEvery, Map<String, Object>? values, this.encode = keyValueLine})
      : values = values ?? {'T': 25.3, 'P': 1};

  final bool udp;
  final Duration? streamEvery;

  /// O estado do "sketch". Os testes mexem direto para simular o processo.
  final Map<String, Object> values;

  /// Como o estado vira mensagem — troque para CSV, checksum, sem `\n`…
  List<int> Function(Map<String, Object> values) encode;

  /// Linhas recebidas (pedidos e comandos), na ordem.
  final List<String> received = [];

  /// Gancho de teste: para de transmitir e de responder (sketch travado).
  bool silent = false;

  ServerSocket? _tcp;
  final List<Socket> _clients = [];
  RawDatagramSocket? _udp;
  InternetAddress? _peer;
  int? _peerPort;
  Timer? _timer;

  int get port => udp ? _udp!.port : _tcp!.port;

  /// Conexões TCP abertas agora — o sketch comum atende uma só.
  int get connections => _clients.length;

  /// `T=25.3;P=1\n`.
  static List<int> keyValueLine(Map<String, Object> v) =>
      utf8.encode('${v.entries.map((e) => '${e.key}=${e.value}').join(';')}\n');

  Future<void> start({int port = 0, String address = '127.0.0.1'}) async {
    if (udp) {
      final s = await RawDatagramSocket.bind(address, port);
      _udp = s;
      s.listen((event) {
        if (event != RawSocketEvent.read) return;
        while (true) {
          final d = s.receive();
          if (d == null) break;
          // Como o sketch típico: responde e passa a transmitir para quem
          // falou por último.
          _peer = d.address;
          _peerPort = d.port;
          final text = utf8.decode(d.data, allowMalformed: true);
          for (final line in text.split('\n')) {
            _handle(line, (bytes) => s.send(bytes, d.address, d.port));
          }
        }
      });
    } else {
      _tcp = await ServerSocket.bind(address, port);
      _tcp!.listen(_onClient);
    }
    final every = streamEvery;
    if (every != null) _timer = Timer.periodic(every, (_) => sendState());
  }

  /// UDP: para onde transmitir antes de alguém falar (o IP:porta gravado no
  /// sketch).
  void streamTo(InternetAddress address, int port) {
    _peer = address;
    _peerPort = port;
  }

  void _onClient(Socket client) {
    _clients.add(client);
    final buf = <int>[];
    client.listen(
      (data) {
        buf.addAll(data);
        while (true) {
          final i = buf.indexOf(0x0A);
          if (i < 0) break;
          final line = utf8.decode(buf.sublist(0, i), allowMalformed: true);
          buf.removeRange(0, i + 1);
          _handle(line, client.add);
        }
      },
      onDone: () => _clients.remove(client),
      onError: (_) => _clients.remove(client),
      cancelOnError: true,
    );
  }

  static final RegExp _set = RegExp(r'^SET\s+(\w+)\s*=\s*(.+)$', caseSensitive: false);

  void _handle(String raw, void Function(List<int>) reply) {
    final line = raw.trim();
    if (line.isEmpty) return;
    received.add(line);
    if (silent) return;
    if (line == '?') {
      reply(encode(values));
      return;
    }
    final m = _set.firstMatch(line);
    if (m != null) {
      values[m.group(1)!] = MessageParser.toValue(m.group(2)!);
      reply(encode(values));
    }
  }

  /// Transmite o estado: para todos os clientes (TCP) ou para o último que
  /// falou (UDP).
  void sendState() {
    if (!silent) sendRaw(encode(values));
  }

  /// Bytes quaisquer — meia mensagem, lixo, checksum errado.
  void sendRaw(List<int> bytes) {
    final data = Uint8List.fromList(bytes);
    if (udp) {
      final peer = _peer, peerPort = _peerPort;
      if (peer != null && peerPort != null) _udp?.send(data, peer, peerPort);
      return;
    }
    for (final c in List.of(_clients)) {
      try {
        c.add(data);
      } catch (_) {}
    }
  }

  /// TCP: derruba as conexões abertas (o sketch reiniciou, cabo saiu).
  void dropClients() {
    for (final c in List.of(_clients)) {
      c.destroy();
    }
    _clients.clear();
  }

  Future<void> stop() async {
    _timer?.cancel();
    dropClients();
    await _tcp?.close();
    _tcp = null;
    _udp?.close();
    _udp = null;
  }
}
