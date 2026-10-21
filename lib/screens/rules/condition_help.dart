// "Como escrever" a condição de uma regra (pedido do cliente: exemplos e
// ajuda na tela de nova regra). Uma folha com poucos exemplos curtos, cada
// um com a frase em português e o modelo; tocar põe o modelo no campo.
//
// Só o que a linguagem das contas aceita de verdade
// (`lib/services/calc/calc_expression.dart`): comparação (> < >= <= = <>),
// "e", "ou", "não" e a variável liga/desliga sozinha. Não há "entre": a faixa
// é duas comparações juntas com "e". O tempo ("por quanto tempo") é outro
// campo da regra e não entra na condição. O teste confere que cada modelo é
// uma condição válida.

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../models/project.dart';
import '../../models/tag.dart';
import '../../services/calc/calc_expression.dart';
import '../../services/calc/calc_graph.dart';

/// Um exemplo: a frase ("Passa de 85") e o modelo (`[Temperatura] > 85`).
class ConditionExample {
  const ConditionExample(this.phrase, this.text);
  final String phrase;
  final String text;
}

/// A folha de exemplos. Devolve o modelo escolhido.
class ConditionHelpSheet extends StatelessWidget {
  const ConditionHelpSheet({super.key, required this.source});

  /// De onde vêm as variáveis dos exemplos: o projeto aberto ou, na regra da
  /// planta, a visão da planta.
  final Project source;

  /// Quando a pessoa ainda não tem a variável do tipo certo.
  static const placeholder = '[Variável]';

  static Future<String?> show(BuildContext context, Project source) => showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => ConditionHelpSheet(source: source),
      );

  /// Os exemplos com as variáveis da pessoa: a primeira de número (de
  /// preferência uma medida, com unidade: "passa de 85" não combina com um
  /// código de status) e a primeira liga/desliga; sem uma delas,
  /// [placeholder] para trocar.
  static List<ConditionExample> examples(Project p) {
    Iterable<Tag> of(CalcRefKind kind) => p.tags.where((t) => CalcGraph.kindOf(t) == kind);
    final numbers = of(CalcRefKind.number);
    final number = numbers.where((t) => t.unit.trim().isNotEmpty).firstOrNull ?? numbers.firstOrNull;
    final flag = of(CalcRefKind.boolean).firstOrNull;
    final n = number == null ? placeholder : CalcGraph.reference(number, p);
    final b = flag == null ? placeholder : CalcGraph.reference(flag, p);
    return [
      ConditionExample('Passa de 85', '$n > 85'),
      ConditionExample('Fica abaixo de 10', '$n < 10'),
      ConditionExample('Chega a 100 ou mais', '$n >= 100'),
      ConditionExample('Entre 20 e 30', '$n >= 20 e $n <= 30'),
      ConditionExample('Fora de 20 a 30', '$n < 20 ou $n > 30'),
      ConditionExample('Ligado', b),
      ConditionExample('Desligado', 'não $b'),
      ConditionExample('Passa de 85 e está ligado', '$n > 85 e $b'),
    ];
  }

  /// O trecho da primeira variável do modelo — fica selecionado no campo,
  /// e o botão "Variável" troca por outra.
  static TextSelection selectionFor(String text) {
    final m = RegExp(r'\[[^\]]*\]|\{[^}]*\}').firstMatch(text);
    return m == null ? TextSelection.collapsed(offset: text.length) : TextSelection(baseOffset: m.start, extentOffset: m.end);
  }

  @override
  Widget build(BuildContext context) {
    final list = examples(source);
    final generic = list.any((e) => e.text.contains(placeholder));
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        key: const ValueKey('exemplos-condicao'),
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 32),
        children: [
          Text('Como escrever a condição', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('Toque num exemplo para usar.', style: TextStyle(color: Ind.textMuted, height: 1.4)),
          const SizedBox(height: 8),
          for (final (i, e) in list.indexed)
            ListTile(
              key: ValueKey('exemplo-condicao-$i'),
              contentPadding: EdgeInsets.zero,
              title: Text(e.phrase),
              subtitle: Text(e.text, style: Ind.number(13, color: Ind.textMuted)),
              onTap: () => Navigator.pop(context, e.text),
            ),
          const SizedBox(height: Ind.space),
          Text(
            '${generic ? 'Troque $placeholder pela sua variável. ' : ''}'
            'Quanto tempo a condição precisa durar fica em "Por quanto tempo", logo abaixo.',
            style: TextStyle(color: Ind.textMuted, fontSize: 13, height: 1.4),
          ),
        ],
      ),
    );
  }
}
