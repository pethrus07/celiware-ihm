// O cano HTTP/HTTPS de um equipamento: o `HttpClient` do `dart:io`, sem
// pacote novo (a foto da câmera já usa o mesmo, §6.14).
//
// **Rede local sem internet (§4.14).** O vínculo do app ao Wi-Fi da máquina é
// do processo inteiro (`bindProcessToNetwork`, `RedeLocal.kt`): todo socket
// criado depois sai por ele, inclusive os do `HttpClient`, que abre sockets
// comuns do Dart. Mas o cliente guarda conexões abertas (keep-alive): uma
// conexão aberta antes do vínculo continuaria pela rede antiga. Por isso
// [beforeRequest] (= `LocalNetwork.prepare`) roda antes de cada pedido e,
// quando o vínculo muda ou um pedido falha, o cliente é trocado por um novo.
//
// **HTTP sem criptografia no Android.** A política de texto claro do Android
// (`network_security_config`, `usesCleartextTraffic`) vale para as pilhas
// HTTP da plataforma (HttpURLConnection, OkHttp, WebView); os sockets do
// Dart não passam por ela, e o motor do Flutter 3.47 não a repassa ao Dart
// (sem `--disallow-insecure-connections`). Quem decide é o app: `http://` só
// para a rede local ([HttpConfig.cleartextProblem]). O pedido roda numa zona
// com `#flutter.io.allow_http` para essa decisão continuar valendo se uma
// versão futura do Flutter voltar a ler a política da plataforma.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'http_error.dart';

/// Uma resposta HTTP, já lida inteira.
class HttpReply {
  const HttpReply({required this.status, required this.body, required this.elapsedMs, this.contentType = ''});
  final int status;
  final String body;
  final int elapsedMs;
  final String contentType;

  bool get ok => status >= 200 && status < 300;
}

/// Cliente HTTP de um equipamento: um pedido por vez (ESP32 e gateways
/// pequenos atendem uma conexão de cada vez), tempo-limite no pedido inteiro
/// (conectar, mandar e ler a resposta), resposta limitada a [maxBytes].
class HttpLink {
  HttpLink({
    required this.timeout,
    this.acceptSelfSigned = false,
    this.beforeRequest,
  });

  /// Resposta maior que isto não é de equipamento (proteção contra baixar
  /// um arquivo grande por engano a cada ciclo).
  static const int maxBytes = 1024 * 1024;

  final Duration timeout;
  final bool acceptSelfSigned;

  /// Antes de cada pedido, com o host: vincula as conexões ao Wi-Fi da
  /// máquina (`LocalNetwork.prepare`). Devolve algo que muda quando o
  /// vínculo muda (a rede escolhida), para o cliente ser trocado.
  final Future<Object?> Function(String host)? beforeRequest;

  HttpClient? _client;
  Object? _route;
  Future<void> _queue = Future.value();

  /// Pedidos feitos (o selo conta as idas e voltas).
  int requests = 0;

  /// Faz um pedido. Lança [HttpCommError] em falha de comunicação; resposta
  /// com qualquer código volta como [HttpReply] (quem chama decide).
  Future<HttpReply> send(String method, Uri uri, {Map<String, String> headers = const {}, String? body}) {
    final done = Completer<HttpReply>();
    _queue = _queue.then((_) async {
      try {
        done.complete(await runZoned(() => _send(method, uri, headers, body), zoneValues: {#flutter.io.allow_http: true}));
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  Future<HttpReply> _send(String method, Uri uri, Map<String, String> headers, String? body) async {
    final route = await beforeRequest?.call(uri.host);
    if (route != _route) {
      // Mudou a rede vinculada: conexões guardadas sairiam pela antiga.
      _drop();
      _route = route;
    }
    final client = _client ??= _newClient();
    final sw = Stopwatch()..start();
    requests++;
    try {
      return await _exchange(client, method, uri, headers, body, sw).timeout(timeout);
    } on TimeoutException {
      _drop();
      throw HttpCommError.timeout('$method $uri: ${timeout.inMilliseconds} ms');
    } on SocketException catch (e) {
      _drop();
      if (_isRefused(e)) throw HttpCommError.refusedPort('$method $uri: $e');
      throw HttpCommError.noConnection('$method $uri: $e');
    } on HandshakeException catch (e) {
      _drop();
      throw HttpCommError.tlsFailure('$method $uri: $e');
    } on TlsException catch (e) {
      _drop();
      throw HttpCommError.tlsFailure('$method $uri: $e');
    } on HttpException catch (e) {
      _drop();
      throw HttpCommError.notHttp('$method $uri: $e');
    }
  }

  Future<HttpReply> _exchange(HttpClient client, String method, Uri uri, Map<String, String> headers, String? body, Stopwatch sw) async {
    final req = await client.openUrl(method, uri);
    req.followRedirects = false;
    headers.forEach(req.headers.set);
    if (body != null) {
      final bytes = utf8.encode(body);
      req.contentLength = bytes.length;
      req.add(bytes);
    }
    final res = await req.close();
    final buf = BytesBuilder(copy: false);
    await for (final chunk in res) {
      buf.add(chunk);
      if (buf.length > maxBytes) {
        _drop();
        throw HttpCommError('$method $uri: resposta com mais de $maxBytes bytes', 'a resposta do equipamento é grande demais (mais de 1 MB): confira o caminho');
      }
    }
    final bytes = buf.takeBytes();
    final type = res.headers.contentType;
    final text = type?.charset?.toLowerCase() == 'iso-8859-1' ? latin1.decode(bytes) : utf8.decode(bytes, allowMalformed: true);
    return HttpReply(status: res.statusCode, body: text, elapsedMs: sw.elapsedMilliseconds, contentType: type?.mimeType ?? '');
  }

  HttpClient _newClient() {
    final c = HttpClient()
      ..connectionTimeout = timeout
      // Conexão parada fecha logo: o vínculo à rede pode mudar entre ciclos.
      ..idleTimeout = const Duration(seconds: 5)
      // Um pedido por vez de qualquer jeito; ESP32 aceita poucas conexões.
      ..maxConnectionsPerHost = 1
      ..autoUncompress = true
      ..userAgent = 'WareIoT';
    if (acceptSelfSigned) c.badCertificateCallback = (cert, host, port) => true;
    return c;
  }

  /// "Conexão recusada": errno 111 no Linux/Android, 61 no macOS/iOS, 10061
  /// no Windows (como no Modbus TCP).
  static bool _isRefused(SocketException e) {
    final code = e.osError?.errorCode;
    if (code == 111 || code == 61 || code == 10061) return true;
    return '${e.osError?.message} ${e.message}'.toLowerCase().contains('refused');
  }

  void _drop() {
    _client?.close(force: true);
    _client = null;
  }

  void close() => _drop();
}
