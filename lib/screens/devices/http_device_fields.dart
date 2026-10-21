import 'package:flutter/material.dart';

import '../../core/http/http_error.dart';
import '../../core/theme/app_theme.dart';
import '../../models/http_config.dart';
import '../../services/net/device_vault.dart';
import '../../services/runtime/hmi_runtime.dart';
import '../../widgets/common/common.dart';

/// Estado dos campos HTTP do cadastro de equipamento: a URL base (no lugar
/// do IP), a autenticação e os cabeçalhos extras. Fica fora do formulário
/// para ele só ganhar ganchos, como os do OPC UA.
///
/// A senha (Basic) ou o token vão para o cofre do Android no Salvar
/// ([commit]); até lá, o "Testar conexão" usa o que foi digitado
/// ([HttpConfig.pendingSecret]), sem gravar nada.
class HttpDeviceFields {
  HttpDeviceFields(HttpConfig? c, {String host = '', int port = HttpConfig.defaultPort})
      : _original = c,
        auth = c?.auth ?? HttpAuth.none,
        acceptSelfSigned = c?.acceptSelfSigned ?? false,
        url = TextEditingController(text: c == null || host.trim().isEmpty ? '' : c.baseUrl(host, port)),
        user = TextEditingController(text: c?.username ?? ''),
        secret = TextEditingController(),
        tokenHeader = TextEditingController(text: c?.tokenHeader ?? HttpConfig.defaultTokenHeader),
        headers = TextEditingController(text: HttpHeader.toLines(c?.headers ?? const []));

  final HttpConfig? _original;
  HttpAuth auth;
  bool acceptSelfSigned;
  final TextEditingController url;
  final TextEditingController user;
  final TextEditingController secret;
  final TextEditingController tokenHeader;
  final TextEditingController headers;

  /// O campo da URL, para o "Testar" validar só ele.
  final urlKey = GlobalKey<FormFieldState<String>>();

  /// O que o cofre tinha ao abrir (vazio = nada).
  String _loaded = '';

  /// Lê a senha guardada para mostrar no campo (escondida). Chamar ao abrir.
  Future<void> load() async {
    final ref = _original?.secretRef;
    if (ref == null) return;
    _loaded = await DeviceVault.instance.read(ref) ?? '';
    if (secret.text.isEmpty) secret.text = _loaded;
  }

  /// A senha mudou (o Salvar grava no cofre; sair pergunta antes).
  bool get secretChanged => auth != HttpAuth.none && secret.text != _loaded;

  /// A URL lida; nula enquanto não fecha.
  ({String host, int port, bool https, String path})? get parsed => HttpConfig.parseUrl(url.text);

  /// O que está errado na URL, curto. Nulo = certa.
  String? urlError() {
    if (url.text.trim().isEmpty) return 'Informe o endereço (ex.: http://192.168.0.50)';
    final p = parsed;
    if (p == null) return 'Endereço inválido: http:// ou https://, o IP e, se tiver, porta e caminho';
    return HttpConfig.cleartextProblem(p.host, https: p.https);
  }

  /// Leva IP e porta da URL para os campos de sempre do cadastro.
  void syncTo(TextEditingController host, TextEditingController port) {
    final p = parsed;
    if (p == null) return;
    host.text = p.host;
    port.text = '${p.port}';
  }

  /// Trocou para HTTP com um IP já digitado: a URL nasce dele.
  void startFrom(String host) {
    if (url.text.trim().isEmpty && host.trim().isNotEmpty) url.text = 'http://${host.trim()}';
  }

  /// Como está nos campos, com a senha digitada pendente (só para testar).
  HttpConfig build() {
    final p = parsed;
    return HttpConfig(
      https: p?.https ?? false,
      basePath: p?.path ?? '',
      auth: auth,
      username: auth == HttpAuth.basic ? user.text.trim() : '',
      tokenHeader: auth == HttpAuth.token && tokenHeader.text.trim().isNotEmpty ? tokenHeader.text.trim() : HttpConfig.defaultTokenHeader,
      secretRef: auth == HttpAuth.none ? null : _original?.secretRef,
      headers: HttpHeader.parseLines(headers.text),
      acceptSelfSigned: (p?.https ?? false) && acceptSelfSigned,
      pendingSecret: auth == HttpAuth.none || secret.text.isEmpty ? null : secret.text,
    );
  }

  /// No Salvar: a senha vai para o cofre e o equipamento guarda só a chave.
  /// [keep] falso (deixou de ser HTTP, ou sem autenticação) apaga a senha
  /// antiga do cofre.
  Future<HttpConfig> commit({required bool keep}) async {
    final c = build();
    final old = _original?.secretRef;
    if (!keep || auth == HttpAuth.none) {
      if (old != null) await DeviceVault.instance.delete(old);
      return c.copyWith(clearSecretRef: true, clearPending: true);
    }
    final ref = old ?? HttpConfig.newSecretRef();
    if (secret.text.isEmpty) {
      if (old != null && _loaded.isNotEmpty) await DeviceVault.instance.delete(ref);
    } else if (secret.text != _loaded || old == null) {
      await DeviceVault.instance.write(ref, secret.text);
    }
    _loaded = secret.text;
    return c.copyWith(secretRef: ref, clearPending: true);
  }

  /// Resumo de "Mais opções" fechado: "HTTP · sem senha" / "HTTPS · admin".
  String summary() {
    final p = parsed;
    final h = HttpHeader.parseLines(headers.text).length;
    return [
      p?.https ?? false ? 'HTTPS' : 'HTTP',
      switch (auth) {
        HttpAuth.none => 'sem senha',
        HttpAuth.basic => user.text.trim().isEmpty ? 'usuário e senha' : user.text.trim(),
        HttpAuth.token => 'token',
      },
      if (h > 0) h == 1 ? '1 cabeçalho' : '$h cabeçalhos',
    ].join(' · ');
  }

  void dispose() {
    for (final c in [url, user, secret, tokenHeader, headers]) {
      c.dispose();
    }
  }

  /// O que conferir quando o teste falha, conforme o que o equipamento disse.
  static List<String> checks(ProbeResult r) {
    switch (r.message) {
      case HttpCommError.missingSecret:
        return const ['A senha fica no cofre deste celular e não vem no arquivo do projeto: digite de novo em "Mais opções".'];
      case HttpCommError.badCredentials:
        return const ['Usuário e senha estão iguais aos do equipamento? Maiúsculas contam — confira em "Mais opções".'];
      case HttpCommError.needsCredentials:
        return const ['O equipamento pede usuário e senha: escolha em "Mais opções" → Autenticação.'];
      case HttpCommError.forbidden:
        return const ['O token está certo? E o nome do cabeçalho (Authorization, X-API-Key)? Confira no manual do equipamento.'];
      case HttpCommError.tls:
        return const [
          'O equipamento usa certificado próprio (autoassinado)? Ligue "Aceitar certificado próprio" em "Mais opções" — só na rede da fábrica.',
          'Ou use http:// se o equipamento também atende sem criptografia.',
        ];
    }
    if (r.message.contains('use https://')) {
      return const ['Endereço da internet só com https://. Na rede da fábrica (192.168.x.x, 10.x.x.x), http:// funciona.'];
    }
    if (r.message.startsWith('o equipamento respondeu algo que não é HTTP')) {
      return const ['É http ou https? Confira o começo do endereço e a porta (80 no http, 443 no https).'];
    }
    if (r.refused) {
      return const [
        'A porta está certa? HTTP usa 80; HTTPS, 443; muito ESP32 e gateway usa 8080 — vai no endereço (http://IP:8080).',
        'O servidor web do equipamento está ligado?',
      ];
    }
    return [
      if (r.hint == null) 'O celular está no mesmo Wi-Fi do equipamento?',
      'O IP está certo? (um número trocado é o erro mais comum)',
      'Abre no navegador do celular? Se abre, o endereço está certo.',
    ];
  }
}

/// A URL base no lugar do IP: `http://192.168.0.50`, com porta e caminho
/// quando o equipamento usa (`http://192.168.0.50:8080/api`).
class HttpUrlField extends StatelessWidget {
  const HttpUrlField({super.key, required this.fields, required this.autovalidate, required this.onChanged});

  final HttpDeviceFields fields;
  final AutovalidateMode autovalidate;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => TextFormField(
        key: fields.urlKey,
        controller: fields.url,
        validator: (_) => fields.urlError(),
        autovalidateMode: autovalidate,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.url,
        style: Ind.number(18),
        decoration: const InputDecoration(
          labelText: 'Endereço do equipamento',
          hintText: 'http://192.168.0.50',
          errorMaxLines: 2,
        ),
        onChanged: (_) => onChanged(),
      );
}

/// "Mais opções" do HTTP: autenticação (a senha vai para o cofre),
/// cabeçalhos extras, certificado próprio e tempos.
class HttpDeviceOptions extends StatefulWidget {
  const HttpDeviceOptions({super.key, required this.fields, required this.timeout, required this.poll, required this.onChanged});

  final HttpDeviceFields fields;
  final TextEditingController timeout;
  final TextEditingController poll;
  final VoidCallback onChanged;

  @override
  State<HttpDeviceOptions> createState() => _HttpDeviceOptionsState();
}

class _HttpDeviceOptionsState extends State<HttpDeviceOptions> {
  bool _show = false;

  void _changed([VoidCallback? fn]) {
    setState(fn ?? () {});
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.fields;
    final https = f.parsed?.https ?? false;
    Widget secretField(String label, String key, {String? helper}) => TextFormField(
          key: ValueKey(key),
          controller: f.secret,
          obscureText: !_show,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: label,
            helperText: helper,
            helperMaxLines: 2,
            suffixIcon: IconButton(
              tooltip: _show ? 'Esconder' : 'Mostrar',
              icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined),
              onPressed: () => setState(() => _show = !_show),
            ),
          ),
          onChanged: (_) => widget.onChanged(),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 6),
      Text('Para equipamento com servidor web na rede: gateway, ESP32, controlador com API REST. Cada variável diz qual caminho ler.',
          style: TextStyle(color: Ind.textMuted, fontSize: 13, height: 1.35)),
      const SectionHeader('Autenticação', padding: EdgeInsets.fromLTRB(0, 20, 0, 8)),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final a in HttpAuth.values)
          ChoiceChip(
            key: ValueKey('http-auth-${a.name}'),
            label: Text(a.label),
            selected: f.auth == a,
            onSelected: (_) => _changed(() => f.auth = a),
          ),
      ]),
      if (f.auth == HttpAuth.basic) ...[
        const SizedBox(height: Ind.space),
        TextFormField(
          key: const ValueKey('campo-usuario-http'),
          controller: f.user,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'Usuário'),
          onChanged: (_) => widget.onChanged(),
        ),
        const SizedBox(height: Ind.space),
        secretField('Senha', 'campo-senha-http', helper: 'Fica no cofre do Android, fora do arquivo do projeto.'),
      ],
      if (f.auth == HttpAuth.token) ...[
        const SizedBox(height: Ind.space),
        TextFormField(
          key: const ValueKey('campo-cabecalho-token'),
          controller: f.tokenHeader,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'Nome do cabeçalho', hintText: 'Authorization'),
          onChanged: (_) => widget.onChanged(),
        ),
        const SizedBox(height: Ind.space),
        secretField('Token', 'campo-token-http', helper: 'O valor inteiro, como o manual pede (ex.: Bearer abc123). Fica no cofre do Android.'),
      ],
      const SizedBox(height: Ind.spaceLarge),
      TextFormField(
        key: const ValueKey('campo-cabecalhos-http'),
        controller: f.headers,
        minLines: 1,
        maxLines: 4,
        autocorrect: false,
        enableSuggestions: false,
        decoration: const InputDecoration(
          labelText: 'Cabeçalhos extras',
          hintText: 'Nome: valor',
          helperText: 'Um por linha. Vão no arquivo do projeto: senha e token, só no campo de cima.',
          helperMaxLines: 2,
        ),
        onChanged: (_) => _changed(),
      ),
      if (https)
        SwitchListTile(
          key: const ValueKey('http-certificado-proprio'),
          contentPadding: EdgeInsets.zero,
          value: f.acceptSelfSigned,
          onChanged: (v) => _changed(() => f.acceptSelfSigned = v),
          title: const Text('Aceitar certificado próprio do equipamento'),
          subtitle: const Text('Para equipamento com certificado autoassinado. Só na rede da fábrica.'),
        ),
      const SizedBox(height: Ind.space),
      StepperField(label: 'Tempo de resposta (ms)', controller: widget.timeout, min: 200, max: 10000),
      const SizedBox(height: Ind.space),
      StepperField(label: 'Ler a cada (ms)', controller: widget.poll, min: HttpConfig.minPollMs, max: 60000, helper: 'Mínimo de 500 ms: servidor web pequeno atende uma pergunta de cada vez.'),
    ]);
  }
}
