import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/ids.dart';
import '../../models/hmi_screen.dart';
import '../../models/narration.dart';
import '../../models/project.dart';
import '../../models/tag.dart';
import '../../services/runtime/tag_codec.dart';
import '../../services/voice/voice_prefs.dart';

/// Linha "Narração por voz" do cadastro de variável (VZ-5): resumo e toque
/// para editar — uma linha só, como a de Alarmes.
class NarrationsRow extends StatelessWidget {
  const NarrationsRow({super.key, required this.tag, required this.narrations, required this.onChanged});
  final Tag tag;
  final List<EventNarration> narrations;
  final ValueChanged<List<EventNarration>> onChanged;

  /// "Valer 1", "Passar de 80,0 °C", "Ao ligar".
  static String describe(Tag tag, EventNarration n) {
    if (tag.dataType == TagDataType.bool) return n.value == 1 ? 'Ao ligar' : 'Ao desligar';
    return '${n.kind.label} ${TagCodec.format(tag, n.value)}';
  }

  @override
  Widget build(BuildContext context) {
    // Uma só: mostra o que fala. Várias (estados de uma máquina): só as
    // condições — o texto inteiro de cada uma não cabe numa linha.
    final summary = narrations.isEmpty
        ? 'Nenhuma · toque para criar'
        : narrations.length == 1
            ? '${describe(tag, narrations.first)}: “${narrations.first.text}”'
            : narrations.map((n) => describe(tag, n).replaceAll(' ', ' ')).join(' · ');
    return Material(
      color: Ind.surfaceHigh,
      borderRadius: BorderRadius.circular(Ind.radiusSmall),
      child: InkWell(
        key: const ValueKey('narracao-da-variavel'),
        borderRadius: BorderRadius.circular(Ind.radiusSmall),
        onTap: () async {
          final next = await NarrationsEditor.show(context, tag: tag, narrations: narrations);
          if (next != null) onChanged(next);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Row(children: [
            Icon(narrations.isEmpty ? Icons.voice_over_off_outlined : Icons.record_voice_over_outlined, color: Ind.textDim),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Narração por voz', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: Ind.text)),
                const SizedBox(height: 2),
                Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: Ind.textMuted, fontSize: 13)),
              ]),
            ),
            Icon(Icons.chevron_right_rounded, color: Ind.textMuted),
          ]),
        ),
      ),
    );
  }
}

/// Folha de edição das narrações de uma variável. Devolve a lista nova em
/// "Pronto" (ou nulo se a pessoa sair sem confirmar). Narração sem texto é
/// descartada — não há o que falar.
class NarrationsEditor extends StatefulWidget {
  const NarrationsEditor({super.key, required this.tag, required this.narrations});
  final Tag tag;
  final List<EventNarration> narrations;

  static Future<List<EventNarration>?> show(BuildContext context, {required Tag tag, required List<EventNarration> narrations}) =>
      showModalBottomSheet<List<EventNarration>>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => NarrationsEditor(tag: tag, narrations: narrations),
      );

  /// Textos de um indicador de estado que já mostra esta variável: o técnico
  /// já escreveu "1 = EM CICLO" lá; não precisa digitar de novo.
  static (String, List<(num, String)>)? fromIndicator(Project project, String tagId) {
    for (final s in project.screens) {
      for (final e in s.elements) {
        if (e.type != ElementType.multistate || e.tagId != tagId) continue;
        final states = [
          for (final st in (e.props['states'] as List? ?? const []))
            if (st is Map && st['value'] is num && '${st['text'] ?? ''}'.trim().isNotEmpty) (st['value'] as num, '${st['text']}'.trim()),
        ];
        if (states.isNotEmpty) return (e.prop<String>('label', s.name), states);
      }
    }
    return null;
  }

  @override
  State<NarrationsEditor> createState() => _NarrationsEditorState();
}

class _NarrationsEditorState extends State<NarrationsEditor> {
  late final List<EventNarration> _rules = [...widget.narrations];

  Tag get tag => widget.tag;
  bool get _bool => tag.dataType == TagDataType.bool;

  void _add() {
    // Sugestão pronta: liga/desliga começa por "ao ligar" e depois "ao
    // desligar"; número segue a sequência de estados (1, 2, 3...).
    final double value;
    if (_bool) {
      value = _rules.any((r) => r.value == 1) ? 0 : 1;
    } else {
      final used = [for (final r in _rules) if (r.kind == NarrationKind.equals) r.value];
      value = used.isEmpty ? 1 : used.reduce((a, b) => a > b ? a : b) + 1;
    }
    setState(() => _rules.add(EventNarration(id: newId('nr'), value: value)));
  }

  void _update(EventNarration n) => setState(() => _rules[_rules.indexWhere((x) => x.id == n.id)] = n);

  /// "EM CICLO" (como aparece no indicador) → "Em ciclo" (como se fala).
  static String _sentence(String t) => t.isEmpty ? t : t[0].toUpperCase() + t.substring(1).toLowerCase();

  @override
  Widget build(BuildContext context) {
    final gap = VoicePrefsController.instance.value.narrationGapSec;
    final indicator = _rules.isEmpty && !_bool ? NarrationsEditor.fromIndicator(AppScope.of(context).controller.project, tag.id) : null;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.86,
      maxChildSize: 0.96,
      builder: (context, scroll) => Column(children: [
        Expanded(
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 24),
            children: [
              Text('Narração por voz', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(tag.name, style: TextStyle(color: Ind.textMuted)),
              const SizedBox(height: 12),
              Text(
                'Quando a variável chegar à condição, o fone fala o texto. Fala depois dos alarmes, e o mesmo aviso no máximo uma vez a cada $gap s.',
                style: TextStyle(color: Ind.textDim, height: 1.4),
              ),
              const SizedBox(height: Ind.space),
              if (indicator != null) ...[
                OutlinedButton.icon(
                  key: const ValueKey('narracao-do-indicador'),
                  onPressed: () => setState(() {
                    for (final (v, t) in indicator.$2) {
                      _rules.add(EventNarration(id: newId('nr'), value: v.toDouble(), text: _sentence(t)));
                    }
                  }),
                  icon: const Icon(Icons.auto_fix_high_rounded),
                  label: Text('Usar os ${indicator.$2.length} textos do indicador “${indicator.$1}”'),
                ),
                const SizedBox(height: 12),
              ],
              for (final r in _rules) ...[
                _NarrationCard(
                  key: ValueKey('narracao-${r.id}'),
                  tag: tag,
                  rule: r,
                  onChanged: _update,
                  onRemove: () => setState(() => _rules.removeWhere((x) => x.id == r.id)),
                ),
                const SizedBox(height: 12),
              ],
              OutlinedButton.icon(
                key: const ValueKey('acrescentar-narracao'),
                onPressed: _add,
                icon: const Icon(Icons.add_rounded),
                label: Text(_rules.isEmpty ? 'Criar narração' : 'Acrescentar outra'),
              ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Ind.page, 8, Ind.page, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const ValueKey('narracao-pronto'),
                onPressed: () => Navigator.pop(context, [for (final r in _rules) if (r.text.trim().isNotEmpty) r]),
                icon: const Icon(Icons.check_rounded),
                label: const Text('Pronto'),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Uma narração: condição, valor e o que falar — tudo à vista (na lista de
/// estados de uma máquina, abrir um por um seria lento), em duas linhas.
class _NarrationCard extends StatelessWidget {
  const _NarrationCard({super.key, required this.tag, required this.rule, required this.onChanged, required this.onRemove});
  final Tag tag;
  final EventNarration rule;
  final ValueChanged<EventNarration> onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final isBool = tag.dataType == TagDataType.bool;
    // Condição num menu compacto (e não em três chips): na lista de estados
    // de uma máquina quase tudo é "Valer", e o cartão fica com duas linhas.
    final options = isBool
        ? const [(NarrationKind.equals, 1.0, 'Ao ligar'), (NarrationKind.equals, 0.0, 'Ao desligar')]
        : [for (final k in NarrationKind.values) (k, rule.value, k.label)];
    final current = isBool ? (rule.value == 1 ? 'Ao ligar' : 'Ao desligar') : rule.kind.label;
    return Container(
      decoration: Ind.card(shadow: false),
      padding: const EdgeInsets.fromLTRB(8, 8, 4, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          PopupMenuButton<int>(
            key: ValueKey('condicao-${rule.id}'),
            tooltip: 'Quando falar',
            onSelected: (i) => onChanged(rule.copyWith(kind: options[i].$1, value: options[i].$2)),
            itemBuilder: (_) => [for (var i = 0; i < options.length; i++) PopupMenuItem(value: i, child: Text(options[i].$3))],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(current, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: Ind.text)),
                Icon(Icons.arrow_drop_down_rounded, color: Ind.textMuted),
              ]),
            ),
          ),
          if (!isBool) ...[
            const SizedBox(width: 4),
            SizedBox(
              width: 104,
              child: TextFormField(
                key: ValueKey('valor-${rule.id}'),
                initialValue: _num(rule.value),
                keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                style: Ind.number(20),
                decoration: InputDecoration(isDense: true, suffixText: tag.unit.isEmpty ? null : tag.unit),
                onChanged: (t) {
                  final v = double.tryParse(t.trim().replaceAll(',', '.'));
                  if (v != null) onChanged(rule.copyWith(value: v));
                },
              ),
            ),
          ],
          const Spacer(),
          IconButton(
            tooltip: 'Tirar esta narração',
            onPressed: onRemove,
            icon: Icon(Icons.close_rounded, color: Ind.textMuted),
          ),
        ]),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 10, 0),
          child: TextFormField(
            key: ValueKey('texto-${rule.id}'),
            initialValue: rule.text,
            textCapitalization: TextCapitalization.sentences,
            // Fala longa vira ruído no fone e atrasa o alarme seguinte.
            inputFormatters: [LengthLimitingTextInputFormatter(EventNarration.maxText)],
            decoration: const InputDecoration(labelText: 'Falar', hintText: 'Ex.: A máquina está iniciando'),
            onChanged: (t) => onChanged(rule.copyWith(text: t)),
          ),
        ),
      ]),
    );
  }

  static String _num(double v) => (v == v.roundToDouble() ? v.round().toString() : v.toString()).replaceAll('.', ',');
}
