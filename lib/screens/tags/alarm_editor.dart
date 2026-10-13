import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/ids.dart';
import '../../models/alarm.dart';
import '../../models/tag.dart';
import '../../services/alarms/alarm_engine.dart';
import '../../services/runtime/tag_codec.dart';
import '../../widgets/alarms/alarm_widgets.dart';
import '../../widgets/common/common.dart';

/// Linha "Alarmes" do cadastro de variável: resumo do que está valendo e
/// toque para editar. Uma linha só — o cadastro continua enxuto.
class AlarmsRow extends StatelessWidget {
  const AlarmsRow({super.key, required this.tag, required this.alarms, required this.onChanged});
  final Tag tag;
  final List<AlarmRule> alarms;
  final ValueChanged<List<AlarmRule>> onChanged;

  static String describe(Tag tag, AlarmRule r) =>
      r.kind.isAnalog ? '${r.kind.label} ${TagCodec.format(tag, r.limit)}' : r.kind.label;

  @override
  Widget build(BuildContext context) {
    // Espaço inseparável dentro de cada alarme: a linha quebra entre eles,
    // nunca no meio ("85,0" numa linha e "°C" sozinho na outra).
    final summary = alarms.isEmpty
        ? 'Nenhum · toque para criar'
        : alarms.map((r) => describe(tag, r).replaceAll(' ', ' ')).join(' · ');
    return Material(
      color: Ind.surfaceHigh,
      borderRadius: BorderRadius.circular(Ind.radiusSmall),
      child: InkWell(
        key: const ValueKey('alarmes-da-variavel'),
        borderRadius: BorderRadius.circular(Ind.radiusSmall),
        onTap: () async {
          final next = await AlarmsEditor.show(context, tag: tag, alarms: alarms);
          if (next != null) onChanged(next);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Row(children: [
            Icon(alarms.isEmpty ? Icons.notifications_none_rounded : Icons.notifications_active_outlined, color: Ind.textDim),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Alarmes', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: Ind.text)),
                const SizedBox(height: 2),
                Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: Ind.textMuted, fontSize: 13)),
              ]),
            ),
            for (final r in alarms.take(3))
              Padding(padding: const EdgeInsets.only(left: 6), child: AlarmShape(priority: r.priority, size: 20)),
            Icon(Icons.chevron_right_rounded, color: Ind.textMuted),
          ]),
        ),
      ),
    );
  }
}

/// Folha de edição dos alarmes de uma variável. Devolve a lista nova em
/// "Pronto" (ou nulo se a pessoa sair sem confirmar).
class AlarmsEditor extends StatefulWidget {
  const AlarmsEditor({super.key, required this.tag, required this.alarms});
  final Tag tag;
  final List<AlarmRule> alarms;

  static Future<List<AlarmRule>?> show(BuildContext context, {required Tag tag, required List<AlarmRule> alarms}) =>
      showModalBottomSheet<List<AlarmRule>>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => AlarmsEditor(tag: tag, alarms: alarms),
      );

  @override
  State<AlarmsEditor> createState() => _AlarmsEditorState();
}

class _AlarmsEditorState extends State<AlarmsEditor> {
  late final List<AlarmRule> _rules = [...widget.alarms];
  String? _open;

  Tag get tag => widget.tag;
  bool get _analog => tag.dataType != TagDataType.bool;

  void _add() {
    // Sugestão pronta: número → "acima de" com prioridade média; liga/desliga
    // → "quando ligar". O técnico só ajusta.
    final r = AlarmRule(id: newId('al'), kind: _analog ? AlarmKind.above : AlarmKind.on, limit: 0, priority: AlarmPriority.medium);
    setState(() {
      _rules.add(r);
      _open = r.id;
    });
  }

  void _update(AlarmRule r) => setState(() => _rules[_rules.indexWhere((x) => x.id == r.id)] = r);

  @override
  Widget build(BuildContext context) {
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
              Text('Alarmes', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(tag.name, style: TextStyle(color: Ind.textMuted)),
              const SizedBox(height: 12),
              Text(
                'Quando a condição durar 1 segundo, o alarme aparece numa faixa no topo do app, no elemento da tela e na lista de alarmes — até alguém reconhecer.',
                style: TextStyle(color: Ind.textDim, height: 1.4),
              ),
              const SizedBox(height: Ind.space),
              for (final r in _rules) ...[
                _RuleCard(
                  key: ValueKey('regra-${r.id}'),
                  tag: tag,
                  rule: r,
                  open: _open == r.id,
                  onToggle: () => setState(() => _open = _open == r.id ? null : r.id),
                  onChanged: _update,
                  onRemove: () => setState(() {
                    _rules.removeWhere((x) => x.id == r.id);
                    if (_open == r.id) _open = null;
                  }),
                ),
                const SizedBox(height: 12),
              ],
              OutlinedButton.icon(
                key: const ValueKey('acrescentar-alarme'),
                onPressed: _add,
                icon: const Icon(Icons.add_rounded),
                label: Text(_rules.isEmpty ? 'Criar alarme' : 'Acrescentar outro alarme'),
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
                key: const ValueKey('alarmes-pronto'),
                onPressed: () => Navigator.pop(context, _rules),
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

class _RuleCard extends StatelessWidget {
  const _RuleCard({super.key, required this.tag, required this.rule, required this.open, required this.onToggle, required this.onChanged, required this.onRemove});
  final Tag tag;
  final AlarmRule rule;
  final bool open;
  final VoidCallback onToggle;
  final ValueChanged<AlarmRule> onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final analog = rule.kind.isAnalog;
    final message = rule.message.trim().isEmpty ? AlarmLogic.defaultMessage(tag, rule) : rule.message;
    return Container(
      decoration: Ind.card(border: open ? rule.priority.color.withValues(alpha: 0.6) : null, width: 1.5, shadow: false),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          borderRadius: BorderRadius.circular(Ind.radius),
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
            child: Row(children: [
              AlarmShape(priority: rule.priority, size: 28),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(AlarmsRow.describe(tag, rule), style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: Ind.text)),
                  const SizedBox(height: 2),
                  Text('$message · ${rule.priority.label}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Ind.textMuted, fontSize: 13)),
                ]),
              ),
              Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: Ind.textMuted),
            ]),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Divider(color: Ind.line),
              const SizedBox(height: 12),
              const SectionHeader('Quando', padding: EdgeInsets.zero),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final k in analog ? const [AlarmKind.above, AlarmKind.below] : const [AlarmKind.on, AlarmKind.off])
                  ChoiceChip(label: Text(k.label), selected: rule.kind == k, onSelected: (_) => onChanged(rule.copyWith(kind: k))),
              ]),
              if (analog) ...[
                const SizedBox(height: 14),
                TextFormField(
                  key: ValueKey('limite-${rule.id}'),
                  initialValue: rule.limit == 0 ? '' : _num(rule.limit),
                  keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                  style: Ind.number(20),
                  decoration: InputDecoration(labelText: 'Limite', suffixText: tag.unit.isEmpty ? null : tag.unit, hintText: 'Ex.: 85'),
                  onChanged: (t) {
                    final v = double.tryParse(t.trim().replaceAll(',', '.'));
                    if (v != null) onChanged(rule.copyWith(limit: v));
                  },
                ),
              ],
              const SizedBox(height: 16),
              const SectionHeader('Prioridade', padding: EdgeInsets.zero),
              const SizedBox(height: 8),
              Row(children: [
                for (final p in AlarmPriority.values) ...[
                  if (p != AlarmPriority.high) const SizedBox(width: 8),
                  Expanded(child: _PriorityChoice(priority: p, selected: rule.priority == p, onTap: () => onChanged(rule.copyWith(priority: p)))),
                ],
              ]),
              const SizedBox(height: 16),
              TextFormField(
                key: ValueKey('mensagem-${rule.id}'),
                initialValue: rule.message,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(labelText: 'Mensagem para o operador', hintText: AlarmLogic.defaultMessage(tag, rule)),
                onChanged: (t) => onChanged(rule.copyWith(message: t)),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: onRemove,
                  style: TextButton.styleFrom(foregroundColor: Ind.textFor(Ind.alarm)),
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Tirar este alarme'),
                ),
              ),
            ]),
          ),
      ]),
    );
  }

  static String _num(double v) => (v == v.roundToDouble() ? v.round().toString() : v.toString()).replaceAll('.', ',');
}

/// Prioridade como cartão com a forma de verdade: o técnico escolhe vendo
/// exatamente o que o operador vai ver.
class _PriorityChoice extends StatelessWidget {
  const _PriorityChoice({required this.priority, required this.selected, required this.onTap});
  final AlarmPriority priority;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = priority.color;
    return Material(
      color: selected ? Color.alphaBlend(c.withValues(alpha: 0.14), Ind.surfaceHigh) : Ind.surfaceHigh,
      borderRadius: BorderRadius.circular(Ind.radiusSmall),
      child: InkWell(
        key: ValueKey('prioridade-${priority.name}'),
        borderRadius: BorderRadius.circular(Ind.radiusSmall),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Ind.radiusSmall),
            border: Border.all(color: selected ? c : Colors.transparent, width: 2),
          ),
          child: Column(children: [
            AlarmShape(priority: priority, size: 26),
            const SizedBox(height: 6),
            Text(priority.label, style: TextStyle(fontWeight: FontWeight.w700, color: Ind.text)),
            Text(priority.hint, textAlign: TextAlign.center, style: TextStyle(fontSize: 11.5, color: Ind.textMuted)),
          ]),
        ),
      ),
    );
  }
}
