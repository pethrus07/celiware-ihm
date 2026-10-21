import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Um pedido que chegou ao [HttpTestServer].
class HttpTestRequest {
  HttpTestRequest(this.method, this.uri, this.headers, this.body);
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String body;

  String get path => uri.path;
}

/// Resposta de uma rota: código, corpo e o tipo do corpo.
typedef HttpTestReply = (int status, String body);

/// Equipamento HTTP de mentira para os testes: um `HttpServer` do `dart:io`
/// em 127.0.0.1, com rotas programadas ("GET /api/status"), autenticação
/// Basic ou por token opcional e atraso para provocar o tempo esgotado.
///
/// Escrito sem o código do app (nem o codec, nem a montagem da URL): se os
/// dois lados usassem o mesmo código, um erro de caminho passaria nos dois.
class HttpTestServer {
  final Map<String, FutureOr<HttpTestReply> Function(HttpTestRequest)> routes = {};
  final List<HttpTestRequest> requests = [];

  /// Atraso antes de responder (tempo esgotado no cliente).
  Duration delay = Duration.zero;

  /// Basic exigido em todo pedido (nulo = sem autenticação).
  String? user;
  String? password;

  /// Token exigido no cabeçalho [tokenHeader] (nulo = sem token).
  String? token;
  String tokenHeader = 'Authorization';

  HttpServer? _server;

  int get port => _server!.port;

  Future<void> start() async {
    final s = _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    s.listen(_handle);
  }

  Future<void> stop() async => _server?.close(force: true);

  /// Quantos pedidos com este método e caminho chegaram.
  int count(String method, String path) => requests.where((r) => r.method == method && r.path == path).length;

  void route(String key, FutureOr<HttpTestReply> Function(HttpTestRequest) handler) => routes[key] = handler;

  /// Rota que responde sempre o mesmo JSON.
  void json(String key, Object value, {int status = 200}) => routes[key] = (_) => (status, jsonEncode(value));

  Future<void> _handle(HttpRequest req) async {
    final String body;
    try {
      body = await utf8.decoder.bind(req).join();
    } catch (_) {
      return; // servidor fechado com o pedido no meio (fim do teste)
    }
    final headers = <String, String>{};
    req.headers.forEach((name, values) => headers[name.toLowerCase()] = values.join(','));
    final r = HttpTestRequest(req.method, req.uri, headers, body);
    requests.add(r);
    final res = req.response;
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (user != null) {
        final expected = 'Basic ${base64.encode(utf8.encode('$user:$password'))}';
        if (headers['authorization'] != expected) {
          res.statusCode = 401;
          res.headers.set('WWW-Authenticate', 'Basic realm="esp32"');
          res.write('senha errada');
          await res.close();
          return;
        }
      }
      if (token != null && headers[tokenHeader.toLowerCase()] != token) {
        res.statusCode = 403;
        res.write('token errado');
        await res.close();
        return;
      }
      final handler = routes['${req.method} ${req.uri.path}'];
      final (status, text) = handler == null ? (404, 'nao achei') : await handler(r);
      res.statusCode = status;
      res.headers.contentType = text.trimLeft().startsWith('{') || text.trimLeft().startsWith('[') ? ContentType.json : ContentType.text;
      res.write(text);
      await res.close();
    } catch (_) {
      // Cliente desistiu (tempo esgotado) e fechou o socket.
    }
  }
}
