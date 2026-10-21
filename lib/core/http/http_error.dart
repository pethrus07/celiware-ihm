// Falhas do HTTP, em português de quem opera. As de comunicação são
// `CommError` (a sessão trata igual às dos outros protocolos: sem
// comunicação, último valor esmaecido, espera crescente).

import '../comm/comm_error.dart';

/// Falha de comunicação com um equipamento HTTP.
class HttpCommError extends CommError {
  const HttpCommError(super.message, this.userMessage, {this.refused = false, this.status});

  @override
  final String userMessage;

  /// O equipamento foi achado e disse não (porta sem servidor, usuário ou
  /// senha recusados). A rede está certa — não adianta mandar conferir o
  /// Wi-Fi e o IP.
  @override
  final bool refused;

  /// O código HTTP, quando a falha é uma resposta (401, 403, 500…).
  final int? status;

  static const String timeoutText = 'tempo esgotado: o equipamento não respondeu';
  static const String refusedText = 'o equipamento recusou a conexão nesta porta';
  static const String badCredentials = '401: o equipamento recusou o usuário ou a senha';
  static const String needsCredentials = '401: o equipamento pede usuário e senha';
  static const String forbidden = '403: o equipamento não deixou (sem permissão)';
  static const String tls = 'o certificado HTTPS do equipamento não é confiável';
  static const String missingSecret = 'a senha deste equipamento não está neste aparelho: abra o equipamento e digite de novo';

  const HttpCommError.timeout(String detail) : this(detail, timeoutText);
  const HttpCommError.refusedPort(String detail) : this(detail, refusedText, refused: true);
  const HttpCommError.noConnection(String detail) : this(detail, 'sem conexão com o equipamento');
  const HttpCommError.tlsFailure(String detail) : this(detail, tls, refused: true);
  const HttpCommError.notHttp(String detail) : this(detail, 'o equipamento respondeu algo que não é HTTP: confira a porta e o http/https', refused: true);
  const HttpCommError.secretMissing() : this('segredo fora do cofre', missingSecret);
  const HttpCommError.cleartext(String detail, String text) : this(detail, text);

  /// Resposta 401/403: o equipamento existe e recusou quem perguntou.
  factory HttpCommError.auth(int status, {required bool sentCredentials}) => HttpCommError(
        'HTTP $status',
        status == 403 ? forbidden : (sentCredentials ? badCredentials : needsCredentials),
        refused: true,
        status: status,
      );

  /// Resposta 5xx: o equipamento está de pé, mas falhou ao atender.
  factory HttpCommError.server(int status) => HttpCommError('HTTP $status', statusText(status), status: status);

  /// O que um código HTTP quer dizer, curto, com o número na frente
  /// ("404: caminho não existe").
  static String statusText(int status) => switch (status) {
        400 => '400: o equipamento não entendeu o pedido (confira o corpo)',
        401 => needsCredentials,
        403 => forbidden,
        404 => '404: caminho não existe',
        405 => '405: o caminho não aceita este método (GET/POST/PUT)',
        408 => '408: o equipamento cansou de esperar o pedido',
        415 => '415: o equipamento não aceita este formato de corpo',
        429 => '429: perguntas demais; aumente o "ler a cada"',
        500 => '500: erro interno do equipamento',
        502 || 504 => '$status: o gateway não alcançou o equipamento',
        503 => '503: o equipamento está ocupado ou reiniciando',
        _ when status >= 500 => '$status: o equipamento falhou ao responder',
        _ when status >= 300 && status < 400 => '$status: o equipamento mandou para outro endereço (confira o caminho e o http/https)',
        _ => '$status: o equipamento recusou o pedido',
      };
}

/// Resposta com código que não é 2xx num pedido que o equipamento entendeu
/// (404, 400, 405…): é problema da variável (caminho, método, corpo), não da
/// comunicação. Na leitura marca só as variáveis daquela requisição; ao
/// gravar, sobe com o texto do código.
class HttpStatusError extends CommError {
  const HttpStatusError(this.status) : super('HTTP $status');

  final int status;

  @override
  String get userMessage => HttpCommError.statusText(status);

  /// O equipamento respondeu: está na rede.
  @override
  bool get refused => true;
}
