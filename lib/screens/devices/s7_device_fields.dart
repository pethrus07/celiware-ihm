import 'package:flutter/material.dart';

import '../../core/s7/s7_error.dart';
import '../../core/theme/app_theme.dart';
import '../../models/s7_config.dart';
import '../../services/runtime/hmi_runtime.dart';
import '../../widgets/common/common.dart';

/// Estado dos campos Siemens S7 do cadastro de equipamento: a família do CLP
/// e, em "Outro", rack e slot. Fica fora do formulário para ele só ganhar
/// ganchos, como os do MQTT.
class S7DeviceFields {
  S7DeviceFields(S7Config? c)
      : family = c?.family ?? S7Family.s71200,
        rack = TextEditingController(text: '${c?.rack ?? 0}'),
        slot = TextEditingController(text: '${c?.slot ?? 1}');

  S7Family family;
  final TextEditingController rack;
  final TextEditingController slot;

  S7Config build() => S7Config(
        family: family,
        rack: (int.tryParse(rack.text) ?? 0).clamp(0, 7),
        slot: (int.tryParse(slot.text) ?? 1).clamp(0, 31),
      );

  /// Escolheu a família: rack e slot passam a ser os dela — e "Outro" começa
  /// do último escolhido (S7-400 com a CPU noutro slot: só mexer no slot).
  void setFamily(S7Family f) {
    family = f;
    final cpu = f.cpu;
    if (cpu != null) {
      rack.text = '${cpu.rack}';
      slot.text = '${cpu.slot}';
    }
  }

  void dispose() {
    rack.dispose();
    slot.dispose();
  }

  /// O que conferir quando o teste falha. Rack/slot e PUT/GET são os dois
  /// tropeços do S7: o primeiro aparece como "recusou a conexão", o segundo
  /// como "conectou e recusou a leitura" (vem assim de fábrica no 1200/1500).
  static List<String> checks(ProbeResult r) {
    if (r.message == S7Hint.rackSlot) {
      return const [
        'A família do CLP está certa? Ela define rack e slot — confira em "Mais opções".',
        'CPU fora do slot de fábrica (comum no S7-400): escolha "Outro" e use o rack e o slot da configuração de hardware do TIA Portal.',
      ];
    }
    if (r.message == S7Hint.putGet || r.message == S7Hint.accessDenied) {
      return const [
        'No TIA Portal, propriedades da CPU → Proteção e segurança → Mecanismos de conexão: marque "Permitir acesso com comunicação PUT/GET".',
        'Em cada DB que o app lê: Propriedades → Atributos → desmarque "Acesso otimizado ao bloco".',
        'Carregue (download) no CLP e teste de novo.',
      ];
    }
    if (r.refused) {
      return const [
        'A porta é 102? É a do S7 — confira em "Mais opções".',
        'O aparelho neste IP é um CLP Siemens com rede (PROFINET)?',
      ];
    }
    return [
      if (r.hint == null) 'O celular está no mesmo Wi-Fi do CLP?',
      'O IP está certo? (um número trocado é o erro mais comum)',
      'A porta é 102?',
    ];
  }
}

/// "Mais opções" do S7: família do CLP (rack e slot só em "Outro"), porta e
/// tempos. Sem ID do escravo, que é coisa de Modbus.
class S7DeviceOptions extends StatelessWidget {
  const S7DeviceOptions({super.key, required this.fields, required this.port, required this.timeout, required this.poll, required this.onChanged});

  final S7DeviceFields fields;
  final TextEditingController port;
  final TextEditingController timeout;
  final TextEditingController poll;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final other = fields.family == S7Family.other;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 6),
      Text('Para CLP Siemens com rede: S7-300, 400, 1200 e 1500. No 1200/1500, habilite PUT/GET no TIA Portal.',
          style: TextStyle(color: Ind.textMuted, fontSize: 13, height: 1.35)),
      const SizedBox(height: Ind.space),
      const SectionHeader('Família do CLP', padding: EdgeInsets.zero),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final f in S7Family.values)
          ChoiceChip(
            key: ValueKey('s7-familia-${f.name}'),
            label: Text(f.label),
            selected: fields.family == f,
            onSelected: (_) {
              fields.setFamily(f);
              onChanged();
            },
          ),
      ]),
      if (other) ...[
        const SizedBox(height: Ind.space),
        StepperField(fieldKey: const ValueKey('campo-rack'), label: 'Bastidor (rack)', controller: fields.rack, min: 0, max: 7, onChanged: onChanged),
        const SizedBox(height: Ind.space),
        StepperField(
          fieldKey: const ValueKey('campo-slot'),
          label: 'Posição da CPU',
          controller: fields.slot,
          min: 0,
          max: 31,
          helper: 'O slot da CPU, na configuração de hardware do TIA Portal.',
          onChanged: onChanged,
        ),
      ] else ...[
        const SizedBox(height: 6),
        Text('Rack ${fields.rack.text}, slot ${fields.slot.text}', key: const ValueKey('s7-rack-slot'), style: TextStyle(color: Ind.textMuted, fontSize: 13)),
      ],
      const SizedBox(height: Ind.space),
      StepperField(label: 'Porta', controller: port, min: 1, max: 65535, helper: 'S7 usa 102.', onChanged: onChanged),
      const SizedBox(height: Ind.space),
      StepperField(label: 'Tempo de resposta (ms)', controller: timeout, min: 200, max: 10000),
      const SizedBox(height: Ind.space),
      StepperField(label: 'Ler a cada (ms)', controller: poll, min: 100, max: 60000),
    ]);
  }
}
