import 'package:flutter/material.dart';

import '../../core/opcua/opcua_client.dart' show OpcUaClient;
import '../../core/opcua/opcua_error.dart';
import '../../core/theme/app_theme.dart';
import '../../models/opcua_config.dart';
import '../../services/runtime/hmi_runtime.dart';
import '../../widgets/common/common.dart';

/// Estado dos campos OPC UA do cadastro de equipamento: o caminho do
/// endpoint, usuário e senha. Fica fora do formulário para ele só ganhar
/// ganchos, como os do S7.
class OpcUaDeviceFields {
  OpcUaDeviceFields(OpcUaConfig? c)
      : path = TextEditingController(text: c?.path ?? ''),
        user = TextEditingController(text: c?.username ?? ''),
        pass = TextEditingController(text: c?.password ?? '');

  final TextEditingController path;
  final TextEditingController user;
  final TextEditingController pass;

  OpcUaConfig build() => OpcUaConfig(path: OpcUaClient.normalizePath(path.text), username: user.text.trim(), password: pass.text);

  /// Colaram o endereço inteiro ("opc.tcp://192.168.0.10:4840/caminho") no
  /// campo do IP — é como o servidor mostra: separa IP, porta e caminho.
  bool takeEndpoint(TextEditingController host, TextEditingController port) {
    final e = OpcUaConfig.parseEndpoint(host.text);
    if (e == null) return false;
    host.text = e.host;
    port.text = '${e.port}';
    path.text = e.path;
    return true;
  }

  /// Resumo de "Mais opções" fechado: "OPC UA · Porta 4840 · anônimo".
  String summary(String port) => [
        'OPC UA · Porta $port',
        if (OpcUaClient.normalizePath(path.text).isNotEmpty) OpcUaClient.normalizePath(path.text),
        user.text.trim().isEmpty ? 'anônimo' : user.text.trim(),
      ].join(' · ');

  void dispose() {
    path.dispose();
    user.dispose();
    pass.dispose();
  }

  /// O que conferir quando o teste falha, conforme o que o servidor disse.
  static List<String> checks(ProbeResult r) {
    switch (r.message) {
      case OpcUaHint.security:
        return const [
          'No servidor, habilite o modo de segurança None (sem criptografia) no endereço (endpoint). Esta versão ainda não assina nem cifra as mensagens (Sign e SignAndEncrypt).',
          'No S7-1500 (TIA Portal): propriedades da CPU → OPC UA → Servidor → Segurança → Canal seguro: marque a política "No security" e carregue no CLP.',
        ];
      case OpcUaHint.user:
        return const [
          'Usuário e senha estão iguais aos cadastrados no servidor? Maiúsculas contam — confira em "Mais opções".',
          'O usuário tem permissão de acesso no servidor?',
        ];
      case OpcUaHint.needsUser:
        return const ['O servidor não aceita conexão anônima: informe usuário e senha em "Mais opções".'];
      case OpcUaHint.noUserName:
        return const ['Este servidor não aceita usuário e senha: deixe o usuário vazio (anônimo) em "Mais opções".'];
      case OpcUaHint.endpoint:
        return const [
          'O caminho está certo? Copie o endereço opc.tcp://… da tela do servidor e cole no campo do IP: o app separa IP, porta e caminho.',
        ];
      case OpcUaHint.license:
        return const ['O servidor OPC UA do CLP pede licença de runtime (no S7-1500, a licença "OPC UA" no TIA Portal).'];
    }
    if (r.message.startsWith('o servidor pede a senha cifrada')) {
      return const ['Deixe o usuário vazio (anônimo), se o servidor aceitar, ou habilite no servidor a política Basic256Sha256 para o usuário.'];
    }
    if (r.refused) {
      return const [
        'A porta é 4840? É a padrão do OPC UA (o Kepware usa 49320) — confira em "Mais opções".',
        'O servidor OPC UA está ligado? No S7-1500 ele vem desligado de fábrica.',
      ];
    }
    return [
      if (r.hint == null) 'O celular está no mesmo Wi-Fi do servidor?',
      'O IP está certo? (um número trocado é o erro mais comum)',
      'A porta é 4840?',
    ];
  }
}

/// "Mais opções" do OPC UA: porta, caminho, usuário e senha, segurança e
/// tempos. Sem ID do escravo, que é coisa de Modbus.
class OpcUaDeviceOptions extends StatefulWidget {
  const OpcUaDeviceOptions({super.key, required this.fields, required this.host, required this.port, required this.timeout, required this.poll, required this.onChanged});

  final OpcUaDeviceFields fields;
  final TextEditingController host;
  final TextEditingController port;
  final TextEditingController timeout;
  final TextEditingController poll;
  final VoidCallback onChanged;

  @override
  State<OpcUaDeviceOptions> createState() => _OpcUaDeviceOptionsState();
}

class _OpcUaDeviceOptionsState extends State<OpcUaDeviceOptions> {
  bool _showPass = false;

  @override
  Widget build(BuildContext context) {
    final f = widget.fields;
    final host = widget.host.text.trim().isEmpty ? 'IP' : widget.host.text.trim();
    final url = 'opc.tcp://$host:${widget.port.text}${OpcUaClient.normalizePath(f.path.text)}';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 6),
      Text('Para servidor OPC UA na rede: CLP com OPC UA (S7-1500, CODESYS), Kepware, gateway, Node-RED. O IP acima é o do servidor.',
          style: TextStyle(color: Ind.textMuted, fontSize: 13, height: 1.35)),
      const SizedBox(height: Ind.space),
      StepperField(label: 'Porta', controller: widget.port, min: 1, max: 65535, helper: 'OPC UA usa 4840.', onChanged: widget.onChanged),
      const SizedBox(height: Ind.space),
      TextFormField(
        key: const ValueKey('campo-caminho-opcua'),
        controller: f.path,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(
          labelText: 'Caminho (endpoint)',
          hintText: 'Vazio na maioria dos CLPs',
          helperText: 'O que vem depois da porta no endereço (ex.: /OPCUA/SimulationServer).',
          helperMaxLines: 2,
        ),
        onChanged: (_) => widget.onChanged(),
      ),
      const SizedBox(height: 8),
      Text('Endereço: $url', key: const ValueKey('opcua-endereco'), style: Ind.number(13, color: Ind.textDim)),
      const SizedBox(height: Ind.space),
      TextFormField(
        key: const ValueKey('campo-usuario-opcua'),
        controller: f.user,
        autocorrect: false,
        enableSuggestions: false,
        decoration: const InputDecoration(labelText: 'Usuário', hintText: 'Vazio = anônimo'),
        onChanged: (_) => widget.onChanged(),
      ),
      if (f.user.text.trim().isNotEmpty) ...[
        const SizedBox(height: Ind.space),
        TextFormField(
          key: const ValueKey('campo-senha-opcua'),
          controller: f.pass,
          obscureText: !_showPass,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Senha',
            helperText: 'Vai cifrada quando o servidor pede; senão, como está.',
            suffixIcon: IconButton(
              tooltip: _showPass ? 'Esconder' : 'Mostrar',
              icon: Icon(_showPass ? Icons.visibility_off_outlined : Icons.visibility_outlined),
              onPressed: () => setState(() => _showPass = !_showPass),
            ),
          ),
        ),
      ],
      const SectionHeader('Segurança', padding: EdgeInsets.fromLTRB(0, 24, 0, 6)),
      Text('Sem criptografia (modo None). Esta versão ainda não assina nem cifra as mensagens (Sign e SignAndEncrypt): se o servidor exigir, habilite nele o modo None.',
          key: const ValueKey('opcua-seguranca'), style: TextStyle(color: Ind.textDim, height: 1.35)),
      const SizedBox(height: Ind.space),
      StepperField(label: 'Tempo de resposta (ms)', controller: widget.timeout, min: 200, max: 10000),
      const SizedBox(height: Ind.space),
      StepperField(label: 'Ler a cada (ms)', controller: widget.poll, min: 100, max: 60000),
    ]);
  }
}
