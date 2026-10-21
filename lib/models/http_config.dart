// Configuração HTTP: a do equipamento (URL base, autenticação, cabeçalhos) e a
// da variável (a requisição, o seletor do valor na resposta e o comando para
// gravar). Itens 56, 169 e 173 da lista do cliente.
//
// Como no OPC UA e no S7, fica fora de Device e Tag para os dois continuarem
// com cara de Modbus no arquivo de quem não usa HTTP: os campos daqui só vão
// para o JSON quando o equipamento é HTTP ou a variável tem requisição.
//
// **A senha e o token nunca vão para o arquivo do projeto.** O projeto guarda
// só uma referência ([HttpConfig.secretRef]) para o cofre do aparelho
// (`DeviceVault`, Android Keystore), como a senha da câmera (§5.7).

import 'package:flutter/foundation.dart';

import '../core/utils/ids.dart';
import 'device.dart';
import 'mqtt_config.dart' show MqttBoolFormat;
import 'project.dart';

/// Como o equipamento confere quem pergunta.
enum HttpAuth {
  /// Sem autenticação (o caso comum de ESP32 e gateway na rede local).
  none('Nenhuma'),

  /// Usuário e senha no cabeçalho `Authorization: Basic …`.
  basic('Usuário e senha'),

  /// Um cabeçalho com o token (`Authorization: Bearer …`, `X-API-Key: …`).
  token('Token no cabeçalho');

  const HttpAuth(this.label);
  final String label;

  static HttpAuth fromName(String? n) => HttpAuth.values.firstWhere((a) => a.name == n, orElse: () => HttpAuth.none);
}

/// Método da requisição.
enum HttpMethod {
  get('GET'),
  post('POST'),
  put('PUT');

  const HttpMethod(this.verb);
  final String verb;

  /// Leva corpo (POST e PUT).
  bool get hasBody => this != HttpMethod.get;

  static HttpMethod fromName(String? n, {HttpMethod fallback = HttpMethod.get}) =>
      HttpMethod.values.firstWhere((m) => m.name == n, orElse: () => fallback);
}

/// Um cabeçalho extra mandado em toda requisição do equipamento. Vai no
/// arquivo do projeto: segredo vai no token (cofre), não aqui.
@immutable
class HttpHeader {
  const HttpHeader(this.name, this.value);
  final String name;
  final String value;

  /// "Nome: valor" por linha, como no manual do equipamento. Linha sem ":"
  /// ou com nome vazio é ignorada.
  static List<HttpHeader> parseLines(String text) => [
        for (final line in text.split('\n'))
          if (line.indexOf(':') > 0 && line.substring(0, line.indexOf(':')).trim().isNotEmpty)
            HttpHeader(line.substring(0, line.indexOf(':')).trim(), line.substring(line.indexOf(':') + 1).trim()),
      ];

  static String toLines(List<HttpHeader> headers) => headers.map((h) => '${h.name}: ${h.value}').join('\n');

  @override
  bool operator ==(Object other) => other is HttpHeader && other.name == name && other.value == value;

  @override
  int get hashCode => Object.hash(name, value);
}

/// Como o app fala com um equipamento HTTP. O IP (ou nome) e a porta
/// continuam em `Device.host` / `Device.port`; o resto da URL base fica aqui
/// ([https] e [basePath]): `http://192.168.0.50:8080/api`.
@immutable
class HttpConfig {
  const HttpConfig({
    this.https = false,
    this.basePath = '',
    this.auth = HttpAuth.none,
    this.username = '',
    this.tokenHeader = defaultTokenHeader,
    this.secretRef,
    this.headers = const [],
    this.acceptSelfSigned = false,
    this.pendingSecret,
  });

  static const int defaultPort = 80;
  static const int httpsPort = 443;

  /// Intervalo mínimo de leitura: um ESP32 atende uma conexão de cada vez e
  /// uma API REST não é feita para ser perguntada a cada 100 ms.
  static const int minPollMs = 500;

  static const String defaultTokenHeader = 'Authorization';

  final bool https;

  /// O que vem depois da porta na URL base ("/api"); vazio = raiz. Sempre
  /// começa com "/" e nunca termina com "/" (ver [normalizePath]).
  final String basePath;

  final HttpAuth auth;

  /// Usuário do Basic.
  final String username;

  /// Nome do cabeçalho do token ("Authorization", "X-API-Key").
  final String tokenHeader;

  /// Chave da senha (Basic) ou do token no cofre do aparelho; nula = nada
  /// guardado. **A senha nunca vai para o arquivo.**
  final String? secretRef;

  final List<HttpHeader> headers;

  /// Aceitar o certificado próprio (autoassinado) do equipamento no HTTPS.
  /// Desligado, só certificado em que o celular confia.
  final bool acceptSelfSigned;

  /// Senha/token digitado no cadastro e ainda não guardado no cofre — só
  /// para o "Testar conexão" de um cadastro aberto. Nunca vai para o JSON e
  /// não conta na igualdade.
  final String? pendingSecret;

  bool get needsSecret => auth != HttpAuth.none;

  int get standardPort => https ? httpsPort : defaultPort;

  /// "/api/" → "/api"; "api" → "/api"; "/" e "" → "".
  static String normalizePath(String path) {
    var p = path.trim();
    if (p.isEmpty || p == '/') return '';
    if (!p.startsWith('/')) p = '/$p';
    while (p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  /// "http://192.168.0.50/api" (porta só quando não é a padrão).
  String baseUrl(String host, int port) {
    final h = host.trim().isEmpty ? 'IP' : host.trim();
    final p = port == standardPort ? '' : ':$port';
    return '${https ? 'https' : 'http'}://$h$p$basePath';
  }

  /// A URL de uma requisição: a base mais o caminho da variável ("/status",
  /// "dados?canal=2"). Caminho que já é uma URL inteira é recusado: o
  /// equipamento é um só, e o cadastro dele diz onde fica.
  Uri resolve(String host, int port, String path) {
    var rel = path.trim();
    if (rel.isNotEmpty && !rel.startsWith('/') && !rel.startsWith('?')) rel = '/$rel';
    return Uri.parse('${https ? 'https' : 'http'}://${_hostForUri(host.trim())}:$port$basePath$rel');
  }

  static String _hostForUri(String h) => h.contains(':') && !h.startsWith('[') ? '[$h]' : h;

  /// Lê a URL base digitada ("http://192.168.0.50:8080/api", "192.168.0.50",
  /// "https://gw.local"). Sem esquema = http. Nulo se não dá para tirar um
  /// endereço dela.
  static ({String host, int port, bool https, String path})? parseUrl(String text) {
    var t = text.trim();
    if (t.isEmpty) return null;
    var secure = false;
    final lower = t.toLowerCase();
    if (lower.startsWith('https://')) {
      secure = true;
      t = t.substring(8);
    } else if (lower.startsWith('http://')) {
      t = t.substring(7);
    } else if (lower.contains('://')) {
      return null;
    }
    final slash = t.indexOf('/');
    final authority = slash < 0 ? t : t.substring(0, slash);
    final path = slash < 0 ? '' : t.substring(slash);
    if (authority.isEmpty || authority.contains('@') || authority.contains(' ')) return null;
    final colon = authority.lastIndexOf(':');
    int? port;
    var host = authority;
    if (colon >= 0) {
      port = int.tryParse(authority.substring(colon + 1));
      if (port == null || port < 1 || port > 65535) return null;
      host = authority.substring(0, colon);
    }
    if (host.isEmpty) return null;
    return (host: host, port: port ?? (secure ? httpsPort : defaultPort), https: secure, path: normalizePath(path.split('?').first));
  }

  /// HTTP sem criptografia só para a rede local: IP privado, de enlace ou do
  /// próprio aparelho, ou um nome (o DNS da fábrica). Um IP público literal
  /// por `http://` é recusado — a senha e os dados iriam abertos pela
  /// internet. Nulo = pode.
  static String? cleartextProblem(String host, {required bool https}) {
    if (https) return null;
    final p = _ipv4(host.trim());
    if (p == null) return null; // nome: o DNS da rede diz onde fica
    final private = p[0] == 10 ||
        p[0] == 127 ||
        (p[0] == 172 && p[1] >= 16 && p[1] <= 31) ||
        (p[0] == 192 && p[1] == 168) ||
        (p[0] == 169 && p[1] == 254) ||
        (p[0] == 100 && p[1] >= 64 && p[1] <= 127);
    return private ? null : 'endereço da internet sem criptografia: use https://';
  }

  static List<int>? _ipv4(String host) {
    final s = host.split('.');
    if (s.length != 4) return null;
    final out = <int>[];
    for (final x in s) {
      final v = int.tryParse(x);
      if (v == null || v < 0 || v > 255) return null;
      out.add(v);
    }
    return out;
  }

  HttpConfig copyWith({
    bool? https,
    String? basePath,
    HttpAuth? auth,
    String? username,
    String? tokenHeader,
    String? secretRef,
    bool clearSecretRef = false,
    List<HttpHeader>? headers,
    bool? acceptSelfSigned,
    String? pendingSecret,
    bool clearPending = false,
  }) =>
      HttpConfig(
        https: https ?? this.https,
        basePath: basePath ?? this.basePath,
        auth: auth ?? this.auth,
        username: username ?? this.username,
        tokenHeader: tokenHeader ?? this.tokenHeader,
        secretRef: clearSecretRef ? null : (secretRef ?? this.secretRef),
        headers: headers ?? this.headers,
        acceptSelfSigned: acceptSelfSigned ?? this.acceptSelfSigned,
        pendingSecret: clearPending ? null : (pendingSecret ?? this.pendingSecret),
      );

  /// Só o que difere do padrão: equipamento HTTP sem senha na raiz não grava
  /// nada além do tipo. Nunca a senha nem o token ([pendingSecret]).
  Map<String, dynamic> toJson() => {
        if (https) 'https': true,
        if (basePath.isNotEmpty) 'basePath': basePath,
        if (auth != HttpAuth.none) 'auth': auth.name,
        if (auth == HttpAuth.basic && username.isNotEmpty) 'username': username,
        if (auth == HttpAuth.token && tokenHeader != defaultTokenHeader) 'tokenHeader': tokenHeader,
        if (auth != HttpAuth.none && secretRef != null) 'secretRef': secretRef,
        if (headers.isNotEmpty) 'headers': [for (final h in headers) {'name': h.name, 'value': h.value}],
        if (acceptSelfSigned) 'acceptSelfSigned': true,
      };

  /// Arquivo editado à mão com `password` ou `token` dentro: o segredo é
  /// descartado (nunca fica no projeto) e o equipamento passa a pedir.
  factory HttpConfig.fromJson(Map<String, dynamic> j) {
    final auth = HttpAuth.fromName(j['auth'] as String?);
    return HttpConfig(
      https: j['https'] == true,
      basePath: normalizePath((j['basePath'] as String?) ?? ''),
      auth: auth,
      username: (j['username'] as String?) ?? '',
      tokenHeader: (j['tokenHeader'] as String?)?.trim().isNotEmpty ?? false ? (j['tokenHeader'] as String).trim() : defaultTokenHeader,
      secretRef: auth == HttpAuth.none ? null : j['secretRef'] as String?,
      headers: [
        for (final h in (j['headers'] as List? ?? const []))
          if (h is Map && h['name'] is String && (h['name'] as String).trim().isNotEmpty) HttpHeader((h['name'] as String).trim(), '${h['value'] ?? ''}'),
      ],
      acceptSelfSigned: j['acceptSelfSigned'] == true,
    );
  }

  /// Chave nova para o cofre ("hs_lz3k9q_4f2a").
  static String newSecretRef() => newId('hs');

  @override
  bool operator ==(Object other) =>
      other is HttpConfig &&
      other.https == https &&
      other.basePath == basePath &&
      other.auth == auth &&
      other.username == username &&
      other.tokenHeader == tokenHeader &&
      other.secretRef == secretRef &&
      listEquals(other.headers, headers) &&
      other.acceptSelfSigned == acceptSelfSigned;

  @override
  int get hashCode => Object.hash(https, basePath, auth, username, tokenHeader, secretRef, Object.hashAll(headers), acceptSelfSigned);
}

/// Onde o valor está na resposta.
enum HttpExtract {
  /// Caminho JSON simples: `data.temperatura`, `itens[0].valor`. Vazio = a
  /// resposta inteira (equipamento que responde só "25.3").
  json,

  /// Expressão regular: o grupo `valor` (`(?<valor>…)`), senão o primeiro
  /// grupo, senão o trecho inteiro que casou. Para resposta que não é JSON
  /// (`T=25.3C`, uma página HTML).
  regex;

  static HttpExtract fromName(String? n) => HttpExtract.values.firstWhere((e) => e.name == n, orElse: () => HttpExtract.json);
}

/// Onde mora uma variável HTTP: a requisição que a lê, o seletor do valor na
/// resposta e, se ela pode ser gravada, o comando.
///
/// Variáveis com a mesma requisição (método, caminho e corpo) são lidas
/// **numa requisição só** por ciclo ([requestKey]).
@immutable
class HttpTagAddress {
  const HttpTagAddress({
    this.method = HttpMethod.get,
    this.path = '',
    this.body = '',
    this.extract = HttpExtract.json,
    this.select = '',
    this.writeMethod = HttpMethod.post,
    this.writePath = '',
    this.writeBody = '',
    this.boolFormat = MqttBoolFormat.oneZero,
  });

  /// Marcador do valor no comando de gravar.
  static const String valueMarker = '{valor}';

  final HttpMethod method;

  /// Caminho relativo à URL base ("/status", "dados?canal=2").
  final String path;

  /// Corpo da leitura (só POST/PUT).
  final String body;

  final HttpExtract extract;

  /// O caminho JSON ou a expressão regular, conforme [extract].
  final String select;

  /// Comando para gravar: método, caminho (vazio = o da leitura) e corpo,
  /// com `{valor}` onde o valor entra (no corpo ou na URL).
  final HttpMethod writeMethod;
  final String writePath;
  final String writeBody;

  /// Liga/desliga ao gravar: 1/0, true/false ou ON/OFF.
  final MqttBoolFormat boolFormat;

  /// Mesma chave = mesma requisição: lida uma vez por ciclo para todas.
  String get requestKey => '${method.verb} ${path.trim()}\n${method.hasBody ? body : ''}';

  /// "GET /status · data.temperatura" para a lista de variáveis.
  String get label {
    final p = path.trim().isEmpty ? '/' : path.trim();
    final s = select.trim();
    return [
      '${method.verb} $p',
      if (s.isNotEmpty) extract == HttpExtract.regex ? 'regex' : s,
    ].join(' · ');
  }

  /// O que está errado na leitura, curto. Nulo = certo.
  String? get problem {
    final p = path.trim();
    if (p.contains('://')) return 'só o caminho (ex.: /status): o endereço do equipamento fica no cadastro dele';
    if (p.contains(' ')) return 'caminho com espaço: use %20';
    if (extract == HttpExtract.regex) {
      if (select.trim().isEmpty) return 'escreva a expressão regular';
      try {
        RegExp(select);
      } on FormatException catch (e) {
        return 'expressão regular inválida: ${e.message}';
      }
    }
    return null;
  }

  HttpTagAddress copyWith({
    HttpMethod? method,
    String? path,
    String? body,
    HttpExtract? extract,
    String? select,
    HttpMethod? writeMethod,
    String? writePath,
    String? writeBody,
    MqttBoolFormat? boolFormat,
  }) =>
      HttpTagAddress(
        method: method ?? this.method,
        path: path ?? this.path,
        body: body ?? this.body,
        extract: extract ?? this.extract,
        select: select ?? this.select,
        writeMethod: writeMethod ?? this.writeMethod,
        writePath: writePath ?? this.writePath,
        writeBody: writeBody ?? this.writeBody,
        boolFormat: boolFormat ?? this.boolFormat,
      );

  /// Só o que difere do padrão (GET, seletor JSON, gravar com POST, 1/0).
  Map<String, dynamic> toJson() => {
        if (method != HttpMethod.get) 'method': method.name,
        'path': path,
        if (method.hasBody && body.isNotEmpty) 'body': body,
        if (extract != HttpExtract.json) 'extract': extract.name,
        if (select.isNotEmpty) 'select': select,
        if (writeMethod != HttpMethod.post) 'writeMethod': writeMethod.name,
        if (writePath.isNotEmpty) 'writePath': writePath,
        if (writeBody.isNotEmpty) 'writeBody': writeBody,
        if (boolFormat != MqttBoolFormat.oneZero) 'boolFormat': boolFormat.name,
      };

  factory HttpTagAddress.fromJson(Map<String, dynamic> j) => HttpTagAddress(
        method: HttpMethod.fromName(j['method'] as String?),
        path: (j['path'] as String?) ?? '',
        body: (j['body'] as String?) ?? '',
        extract: HttpExtract.fromName(j['extract'] as String?),
        select: (j['select'] as String?) ?? '',
        writeMethod: HttpMethod.fromName(j['writeMethod'] as String?, fallback: HttpMethod.post),
        writePath: (j['writePath'] as String?) ?? '',
        writeBody: (j['writeBody'] as String?) ?? '',
        boolFormat: MqttBoolFormat.fromName(j['boolFormat'] as String?),
      );

  @override
  bool operator ==(Object other) =>
      other is HttpTagAddress &&
      other.method == method &&
      other.path == path &&
      other.body == body &&
      other.extract == extract &&
      other.select == select &&
      other.writeMethod == writeMethod &&
      other.writePath == writePath &&
      other.writeBody == writeBody &&
      other.boolFormat == boolFormat;

  @override
  int get hashCode => Object.hash(method, path, body, extract, select, writeMethod, writePath, writeBody, boolFormat);
}

/// Segredos dos equipamentos HTTP no projeto, como os das câmeras
/// (`ProjectCameras`): o que o cofre guarda e a troca de chaves ao importar.
extension ProjectDeviceSecrets on Project {
  /// As chaves do cofre que os equipamentos deste projeto usam.
  Set<String> get deviceSecretRefs => {
        for (final d in devices)
          if (d.kind == DeviceKind.http && d.http.needsSecret) ?d.http.secretRef,
      };

  /// Projeto vindo de um arquivo (importar): todo equipamento HTTP com senha
  /// ganha uma chave nova, que o cofre ainda não tem — a senha é pedida de
  /// novo. A chave antiga podia existir aqui (o mesmo projeto exportado e
  /// importado de volta) e daria a senha de outro equipamento.
  Project withFreshDeviceSecrets() {
    if (!devices.any((d) => d.kind == DeviceKind.http && d.http.secretRef != null)) return this;
    return copyWith(devices: [
      for (final d in devices)
        d.kind == DeviceKind.http && d.http.secretRef != null ? d.copyWith(http: d.http.copyWith(secretRef: HttpConfig.newSecretRef())) : d,
    ]);
  }
}
