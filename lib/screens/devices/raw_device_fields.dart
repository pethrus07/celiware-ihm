import 'package:flutter/material.dart';

import '../../core/rawlink/message_profile.dart';
import '../../core/theme/app_theme.dart';
import '../../models/device.dart';
import '../../models/raw_config.dart';
import '../../services/runtime/drivers/raw_driver.dart';
import '../../services/runtime/hmi_runtime.dart';
import '../../widgets/common/common.dart';
import 'raw_profile_page.dart';

/// Estado dos campos do protocolo cru no cadastro de equipamento (TCP ou UDP,
/// porta deste celular e o perfil da mensagem). Fica fora do formulário para
/// ele só trocar o bloco do Modbus por este, como no MQTT.
class RawDeviceFields {
  RawDeviceFields(RawConfig c)
      : transport = c.transport,
        localPort = TextEditingController(text: '${c.localPort}'),
        profile = c.profile;

  RawTransport transport;
  final TextEditingController localPort;
  MessageProfile profile;

  bool get isUdp => transport == RawTransport.udp;

  RawConfig build() => RawConfig(
        transport: transport,
        localPort: isUdp ? (int.tryParse(localPort.text) ?? 0).clamp(0, 65535) : 0,
        profile: profile,
      );

  /// Resumo de "Mais opções" fechado.
  String summary(String port) {
    final local = int.tryParse(localPort.text) ?? 0;
    return [
      'Arduino · ${transport.label} · Porta $port',
      if (isUdp && local != 0) 'porta deste celular $local',
    ].join(' · ');
  }

  void dispose() => localPort.dispose();

  /// "Linha chave=valor · o equipamento manda sozinho".
  static String describe(MessageProfile p) => [
        RawTemplates.describe(p),
        p.mode == RawMode.polling ? 'o app pergunta' : 'o equipamento manda sozinho',
        if (p.checksum.enabled) 'com checksum',
      ].join(' · ');
}

/// "Mensagem do equipamento" — à vista no cadastro: sem o perfil certo nada
/// funciona. Tocar abre o editor com a prévia ao vivo.
class RawProfileRow extends StatelessWidget {
  const RawProfileRow({super.key, required this.fields, required this.device, required this.onChanged});

  final RawDeviceFields fields;

  /// O equipamento como está no formulário — onde a prévia vai ouvir.
  final Device Function() device;
  final VoidCallback onChanged;

  Future<void> _edit(BuildContext context) async {
    final p = await RawProfilePage.open(context, device());
    if (p == null) return;
    fields.profile = p;
    onChanged();
  }

  @override
  Widget build(BuildContext context) => Material(
        color: Ind.surfaceHigh,
        borderRadius: BorderRadius.circular(Ind.radiusSmall),
        child: ListTile(
          key: const ValueKey('mensagem-equipamento'),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Ind.radiusSmall)),
          leading: Icon(Icons.subject_rounded, color: Ind.accent),
          title: const Text('Mensagem do equipamento'),
          subtitle: Text(RawDeviceFields.describe(fields.profile), style: TextStyle(color: Ind.textMuted, fontSize: 13)),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _edit(context),
        ),
      );
}

/// O que é do protocolo cru em "Mais opções": TCP ou UDP, porta, porta deste
/// celular (UDP) e tempo de resposta.
class RawDeviceMoreOptions extends StatelessWidget {
  const RawDeviceMoreOptions({super.key, required this.fields, required this.port, required this.timeout, required this.onChanged});

  final RawDeviceFields fields;
  final TextEditingController port;
  final TextEditingController timeout;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SizedBox(height: 6),
        Text('Para Arduino, ESP, balança ou leitor que manda a própria mensagem, sem Modbus. Como ler a mensagem fica em "Mensagem do equipamento".',
            style: TextStyle(color: Ind.textMuted, fontSize: 13, height: 1.35)),
        const SizedBox(height: Ind.space),
        Text('Por onde', style: TextStyle(color: Ind.textDim, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final t in RawTransport.values)
            ChoiceChip(
              key: ValueKey('transporte-${t.name}'),
              label: Text(t == RawTransport.tcp ? 'TCP · conexão' : 'UDP · pacotes'),
              selected: fields.transport == t,
              onSelected: (_) {
                fields.transport = t;
                onChanged();
              },
            ),
        ]),
        const SizedBox(height: Ind.space),
        StepperField(label: 'Porta', controller: port, min: 1, max: 65535, helper: 'A do programa do equipamento (WiFiServer ou WiFiUDP).', onChanged: onChanged),
        if (fields.isUdp) ...[
          const SizedBox(height: Ind.space),
          StepperField(
            fieldKey: const ValueKey('porta-local'),
            label: 'Porta deste celular',
            controller: fields.localPort,
            min: 0,
            max: 65535,
            helper: 'Para onde o equipamento manda. 0 = qualquer uma: serve quando ele responde a quem pergunta. Se ele manda sozinho, use a porta gravada no programa dele.',
            onChanged: onChanged,
          ),
        ],
        const SizedBox(height: Ind.space),
        StepperField(label: 'Tempo de resposta (ms)', controller: timeout, min: 200, max: 10000),
      ]);
}

// ── Testar conexão ─────────────────────────────────────────────────────────────

/// Título do cartão do teste: no cru, "respondeu" não basta — o que importa é
/// a mensagem ter chegado e o perfil ter entendido.
String rawProbeTitle(ProbeResult r) {
  if (r.ok) return 'Chegou mensagem e o perfil entendeu${r.elapsedMs != null ? ' (${r.elapsedMs} ms)' : ''}';
  // Conectou e o problema é a mensagem: "Não conectou" seria mentira.
  if (_reached(r)) return capitalized(r.message);
  return 'Não conectou: ${r.message}';
}

bool _reached(ProbeResult r) => r.message.startsWith(RawProbeError.notUnderstood) || RawProbeError.isSilent(r.message);

/// A frase antes da lista do que conferir.
String rawProbeHeader(ProbeResult r) {
  if (_reached(r)) return 'O equipamento está na rede. Confira:';
  return r.refused ? 'O equipamento está na rede, mas não aceitou:' : 'Confira, nesta ordem:';
}

/// O que conferir quando o teste falha, na ordem em que os problemas
/// costumam acontecer.
List<String> rawProbeChecks(ProbeResult r, {required bool udp}) {
  if (r.message.startsWith(RawProbeError.notUnderstood)) {
    return const ['A mensagem chegou: abra "Mensagem do equipamento" e ajuste até a prévia mostrar os campos.'];
  }
  if (RawProbeError.isSilent(r.message)) {
    return [
      'O equipamento manda sozinho? Se ele só responde quando perguntam, escolha "O app pergunta" em "Mensagem do equipamento".',
      if (udp) 'UDP: o equipamento manda para o IP deste celular e para a "Porta deste celular" (Mais opções)?',
    ];
  }
  if (r.refused) {
    return const [
      'A porta está certa? É a do programa do equipamento — confira em "Mais opções".',
      'O programa está rodando e esperando conexão nessa porta (WiFiServer)?',
    ];
  }
  return [
    if (r.hint == null) 'O celular está no mesmo Wi-Fi do equipamento?',
    'O IP está certo? (um número trocado é o erro mais comum)',
    'A porta é a do programa do equipamento?',
  ];
}
