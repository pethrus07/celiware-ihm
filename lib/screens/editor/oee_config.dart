import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../models/hmi_screen.dart';
import '../../models/project.dart';
import '../../models/tag.dart';
import '../../widgets/common/common.dart';
import '../../widgets/hmi/elements/oee_element.dart';

/// Escolha de uma variável numa vaga do OEE. A folha passa o seletor dela —
/// o mesmo dos outros elementos, com o valor ao vivo e "Criar variável".
typedef OeeTagPicker = Widget Function(Tag? selected, ValueChanged<Tag> onChanged);

const _section = EdgeInsets.fromLTRB(0, 28, 0, 12);

/// Configuração do OEE, na folha do elemento: de onde vem o OEE, a escala das
/// variáveis, uma variável por vaga e as faixas. Como o resto da folha, tudo
/// grava na hora.
///
/// Mora fora de `element_config_sheet.dart` de propósito (como a tabela): a
/// folha só chama [oeeFields].
List<Widget> oeeFields(Project project, HmiElement e, void Function(HmiElement next) save, {required OeeTagPicker picker}) {
  final source = Oee.sourceOf(e);
  final scale = Oee.scaleOf(e);
  final ids = Oee.slots(e);

  Widget slot(int i, String title) => Column(
        key: ValueKey('oee-vaga-$i'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(title, padding: i == 0 ? _section : const EdgeInsets.fromLTRB(0, 18, 0, 10)),
          picker(ids[i] == null ? null : project.tag(ids[i]!), (t) => save(e.withProp('tagIds', Oee.withSlot(ids, i, t.id)))),
        ],
      );

  return [
    const SectionHeader('De onde vem o OEE', padding: _section),
    ChoiceCards<OeeSource>(
      options: const [
        ChoiceOption(value: OeeSource.calc, title: 'Calculado no app', subtitle: 'Disponibilidade × desempenho × qualidade', icon: Icons.calculate_outlined),
        ChoiceOption(value: OeeSource.tag, title: 'Pronto do equipamento', subtitle: 'Uma variável a mais, já com o OEE', icon: Icons.memory_rounded),
      ],
      selected: source,
      onChanged: (s) {
        var next = e.withProp('source', s.name);
        // Voltou para o calculado: a vaga do OEE pronto se solta — senão a
        // tela seguiria lendo uma variável que não mostra.
        if (s == OeeSource.calc) next = next.withProp('tagIds', Oee.withSlot(ids, Oee.oeeSlot, null));
        save(next);
      },
    ),
    const SectionHeader('Escala das variáveis', padding: _section),
    Text('Como o equipamento manda os números. Vale para todas as variáveis do OEE.', style: TextStyle(color: Ind.textDim, height: 1.35)),
    const SizedBox(height: 10),
    ChoiceCards<OeeScale>(
      options: const [
        ChoiceOption(value: OeeScale.percent, title: 'De 0 a 100', subtitle: '85 quer dizer 85 %', icon: Icons.percent_rounded),
        ChoiceOption(value: OeeScale.fraction, title: 'De 0 a 1', subtitle: '0,85 quer dizer 85 %', icon: Icons.exposure_rounded),
      ],
      selected: scale,
      onChanged: (s) => save(e.withProp('scale', s.name)),
    ),
    for (var i = 0; i < 3; i++) slot(i, Oee.titles[i]),
    if (source == OeeSource.tag) slot(Oee.oeeSlot, 'OEE pronto'),
    const SectionHeader('Faixas do OEE', padding: _section),
    // "Abaixo de" vai na frase: no rótulo, metade da largura do celular,
    // virava "Atenção abaixo…" (o mesmo cuidado do medidor).
    Text('O OEE fica amarelo abaixo da atenção e vermelho abaixo do alarme. Vazio = sem faixa.', style: TextStyle(color: Ind.textDim, height: 1.35)),
    const SizedBox(height: 10),
    Row(children: [
      Expanded(
        child: _PercentField(
          key: const ValueKey('faixa-atencao-oee'),
          label: 'Atenção',
          value: e.props['warn'] as num?,
          color: Ind.warn,
          onChanged: (v) => save(e.withProp('warn', v)),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: _PercentField(
          key: const ValueKey('faixa-alarme-oee'),
          label: 'Alarme',
          value: e.props['alarm'] as num?,
          color: Ind.alarm,
          onChanged: (v) => save(e.withProp('alarm', v)),
        ),
      ),
    ]),
  ];
}

/// Limite em % (aceita vírgula). Vazio = sem faixa.
class _PercentField extends StatelessWidget {
  const _PercentField({super.key, required this.label, required this.value, required this.onChanged, required this.color});
  final String label;
  final num? value;
  final ValueChanged<num?> onChanged;
  final Color color;

  @override
  Widget build(BuildContext context) => TextFormField(
        initialValue: value == null ? '' : value.toString().replaceAll('.', ','),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        // A versão "texto" da cor de estado: o amarelo puro não se lê no claro.
        style: Ind.number(17, color: Ind.textFor(color)),
        decoration: InputDecoration(labelText: label, suffixText: '%'),
        onChanged: (t) => onChanged(t.trim().isEmpty ? null : num.tryParse(t.trim().replaceAll(',', '.'))),
      );
}
