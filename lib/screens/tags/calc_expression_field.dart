import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../models/project.dart';
import '../../models/tag.dart';
import '../../services/calc/calc_expression.dart';
import '../../services/calc/calc_graph.dart';
import '../../services/runtime/tag_codec.dart';
import '../../services/runtime/tag_store.dart';
import '../../widgets/common/common.dart';
import '../../widgets/hmi/hmi_frame.dart';
import '../../widgets/hmi/live_tags.dart';

/// O campo da conta (variável calculada e condição de regra): o texto, o erro
/// com o trecho marcado e dois atalhos — **Variável**, que cita por toque (sem
/// precisar digitar o nome exato), e **Função**, com as funções e os sinais que
/// o teclado do celular esconde.
class CalcExpressionField extends StatelessWidget {
  const CalcExpressionField({
    super.key,
    required this.controller,
    required this.error,
    required this.onChanged,
    this.excludeTagId,
    this.label = 'Conta',
    this.hint = 'Ex.: [Velocidade] * 60',
    this.source,
  });

  /// De onde vêm as variáveis para citar; nulo = o projeto aberto. As
  /// regras da planta passam a visão da planta (variáveis de todos os
  /// projetos).
  final Project? source;

  final TextEditingController controller;

  /// O problema da conta agora (nulo = está certa).
  final CalcError? error;
  final VoidCallback onChanged;

  /// A própria variável não entra na lista de citar.
  final String? excludeTagId;
  final String label;
  final String hint;

  /// Põe [text] onde está o cursor (ou no fim), com um espaço antes quando
  /// encostaria em outra palavra. [caretBack] recua o cursor (para dentro do
  /// parêntese de uma função).
  static void insert(TextEditingController c, String text, {int caretBack = 0}) {
    final v = c.value;
    var sel = v.selection;
    if (!sel.isValid || sel.start > v.text.length) sel = TextSelection.collapsed(offset: v.text.length);
    final before = v.text.substring(0, sel.start), after = v.text.substring(sel.end);
    final space = before.isNotEmpty && !RegExp(r'[\s(;]$').hasMatch(before) ? ' ' : '';
    final ins = '$space$text';
    c.value = TextEditingValue(text: '$before$ins$after', selection: TextSelection.collapsed(offset: before.length + ins.length - caretBack));
  }

  Future<void> _pickVariable(BuildContext context) async {
    final tag = await CalcVariableSheet.show(context, excludeTagId: excludeTagId, source: source);
    if (tag == null || !context.mounted) return;
    insert(controller, CalcGraph.reference(tag, source ?? AppScope.of(context).controller.project));
    onChanged();
  }

  Future<void> _pickFunction(BuildContext context) async {
    final pick = await CalcFunctionSheet.show(context);
    if (pick == null) return;
    insert(controller, pick.$1, caretBack: pick.$2);
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final e = error;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        key: const ValueKey('campo-conta'),
        controller: controller,
        minLines: 1,
        maxLines: 4,
        autocorrect: false,
        enableSuggestions: false,
        style: TextStyle(fontSize: 18, height: 1.35, color: Ind.text),
        decoration: InputDecoration(labelText: label, hintText: hint),
        onChanged: (_) => onChanged(),
      ),
      if (e != null) ...[
        const SizedBox(height: 8),
        CalcErrorLine(source: controller.text, error: e),
      ],
      const SizedBox(height: 4),
      Wrap(spacing: 8, children: [
        TextButton.icon(
          key: const ValueKey('inserir-variavel'),
          onPressed: () => _pickVariable(context),
          icon: const Icon(Icons.data_object_rounded),
          label: const Text('Variável'),
        ),
        TextButton.icon(
          key: const ValueKey('inserir-funcao'),
          onPressed: () => _pickFunction(context),
          icon: const Icon(Icons.functions_rounded),
          label: const Text('Função ou sinal'),
        ),
      ]),
    ]);
  }
}

/// O erro da conta: a mensagem e, embaixo, o texto com o trecho do problema
/// marcado em vermelho — "aponta onde", sem número de posição para contar.
class CalcErrorLine extends StatelessWidget {
  const CalcErrorLine({super.key, required this.source, required this.error});
  final String source;
  final CalcError error;

  @override
  Widget build(BuildContext context) {
    final color = Ind.textFor(Ind.alarm);
    final s = error.start.clamp(0, source.length), e = error.end.clamp(s, source.length);
    final mark = TextStyle(color: color, fontWeight: FontWeight.w700, backgroundColor: Ind.alarm.withValues(alpha: 0.16));
    return Row(key: const ValueKey('erro-conta'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: 1), child: Icon(Icons.error_outline_rounded, size: 18, color: color)),
      const SizedBox(width: 8),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(error.message, style: TextStyle(color: color, fontWeight: FontWeight.w600, height: 1.3)),
          if (source.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text.rich(
              TextSpan(style: Ind.number(13, color: Ind.textDim), children: [
                TextSpan(text: source.substring(0, s)),
                // Trecho vazio (faltou algo no fim): um traço onde falta.
                TextSpan(text: e > s ? source.substring(s, e) : ' _ ', style: mark),
                TextSpan(text: source.substring(e)),
              ]),
            ),
          ],
        ]),
      ),
    ]);
  }
}

/// Folha "citar variável": as que podem entrar numa conta (número e
/// liga/desliga), agrupadas por equipamento, com o valor de agora. Busca a
/// partir de 8. Devolve a escolhida.
class CalcVariableSheet extends StatefulWidget {
  const CalcVariableSheet({super.key, this.excludeTagId, this.source});
  final String? excludeTagId;

  /// Nulo = o projeto aberto (ver [CalcExpressionField.source]).
  final Project? source;

  static Future<Tag?> show(BuildContext context, {String? excludeTagId, Project? source}) => showModalBottomSheet<Tag>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => CalcVariableSheet(excludeTagId: excludeTagId, source: source),
      );

  @override
  State<CalcVariableSheet> createState() => _CalcVariableSheetState();
}

class _CalcVariableSheetState extends State<CalcVariableSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final open = AppScope.watch(context).controller.project;
    final project = widget.source ?? open;
    final usable = [
      for (final t in project.tags)
        if (t.id != widget.excludeTagId && !t.isText && !t.isArray) t,
    ];
    final q = CalcScope.plain(_query);
    final shown = q.isEmpty ? usable : usable.where((t) => CalcScope.plain(t.name).contains(q)).toList();
    final grouped = usable.map((t) => t.deviceId).toSet().length > 1;
    return VisibleLiveTags(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (context, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 32),
          children: [
            Text('Qual variável entra na conta?', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Ind.space),
            if (usable.length >= 8) ...[
              TextField(
                key: const ValueKey('buscar-variavel-conta'),
                onChanged: (v) => setState(() => _query = v),
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Buscar pelo nome'),
              ),
              const SizedBox(height: Ind.space),
            ],
            if (usable.isEmpty)
              Text('Nenhuma variável de número ou liga/desliga ainda. Cadastre as do equipamento primeiro.', style: TextStyle(color: Ind.textDim, height: 1.4)),
            for (final d in project.devices) ...[
              if (grouped && shown.any((t) => t.deviceId == d.id)) SectionHeader(d.name, padding: const EdgeInsets.fromLTRB(4, 12, 0, 10)),
              for (final t in shown.where((t) => t.deviceId == d.id))
                LiveTagItem(
                  tagId: t.id,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Material(
                      color: Ind.surfaceHigh,
                      borderRadius: BorderRadius.circular(Ind.radiusSmall),
                      child: InkWell(
                        key: ValueKey('citar-${t.id}'),
                        borderRadius: BorderRadius.circular(Ind.radiusSmall),
                        onTap: () => Navigator.pop(context, t),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          child: Row(children: [
                            Expanded(child: Text(t.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                            TagBuilder(
                              tagId: t.id,
                              builder: (context, _, r) => Text(
                                r.quality == TagQuality.good || r.quality == TagQuality.commLost ? TagCodec.format(t, r.value) : '---',
                                style: Ind.number(14, color: r.isGood ? Ind.text : Ind.textMuted),
                              ),
                            ),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Folha "função ou sinal": as seis funções, cada uma com uma frase, e os
/// sinais que o teclado do celular esconde. Devolve (texto, recuo do cursor).
class CalcFunctionSheet extends StatelessWidget {
  const CalcFunctionSheet({super.key});

  static Future<(String, int)?> show(BuildContext context) => showModalBottomSheet<(String, int)>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => const CalcFunctionSheet(),
      );

  static const _functions = [
    ('se', 'Escolhe entre dois valores', 'se(condição; se sim; se não)'),
    ('mín', 'O menor de vários valores', 'mín(a; b)'),
    ('máx', 'O maior de vários valores', 'máx(a; b)'),
    ('abs', 'Tira o sinal: abs(−5) = 5', 'abs(x)'),
    ('arred', 'Arredonda, com as casas que quiser', 'arred(x; 1)'),
    ('taxa', 'Quanto um contador sobe por hora', 'taxa([Peças])'),
  ];

  static const _signs = ['+', '−', '×', '÷', '(', ')', ';', '=', '≠', '>', '<', '≥', '≤', 'e', 'ou', 'não'];

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (context, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 32),
          children: [
            Text('Função ou sinal', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            for (final (name, what, example) in _functions)
              ListTile(
                key: ValueKey('funcao-$name'),
                contentPadding: EdgeInsets.zero,
                title: Text(what),
                subtitle: Text(example, style: Ind.number(13, color: Ind.textMuted)),
                onTap: () => Navigator.pop(context, ('$name()', 1)),
              ),
            const SectionHeader('Sinais', padding: EdgeInsets.fromLTRB(0, 16, 0, 10)),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final s in _signs)
                ActionChip(
                  key: ValueKey('sinal-$s'),
                  label: Text(s, style: const TextStyle(fontSize: 16)),
                  onPressed: () => Navigator.pop(context, (s == '(' || s == ')' ? s : '$s ', 0)),
                ),
            ]),
            const SizedBox(height: Ind.space),
            Text(
              'Vírgula é decimal (0,5). Entre os valores de uma função vai ponto e vírgula: máx(a; b). '
              'Nome com espaço vai entre colchetes: [Velocidade da faca].',
              style: TextStyle(color: Ind.textMuted, fontSize: 13, height: 1.4),
            ),
          ],
        ),
      );
}
