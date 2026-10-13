import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../services/recipes/recipe_applier.dart';
import '../../services/recipes/recipe_history.dart';
import '../../widgets/common/adaptive.dart';
import '../../widgets/common/common.dart';

/// Histórico de aplicações (RC-7): quem aplicou qual receita, onde, quando e
/// como terminou — por dia, o mais novo em cima. Tocar abre o "de → para".
class RecipeHistoryPage extends StatefulWidget {
  const RecipeHistoryPage({super.key});

  @override
  State<RecipeHistoryPage> createState() => _RecipeHistoryPageState();
}

class _RecipeHistoryPageState extends State<RecipeHistoryPage> {
  Future<List<RecipeApplyRecord>>? _load;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load ??= RecipeHistoryStore.beside(AppScope.of(context).controller.repository).load();
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _day(DateTime at) {
    final l = at.toLocal(), n = clock.now();
    final days = DateTime(n.year, n.month, n.day).difference(DateTime(l.year, l.month, l.day)).inDays;
    if (days == 0) return 'Hoje';
    if (days == 1) return 'Ontem';
    return '${_two(l.day)}/${_two(l.month)}/${l.year}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const AdaptiveTitle('Histórico de aplicações')),
        body: FutureBuilder<List<RecipeApplyRecord>>(
          future: _load,
          builder: (context, snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final list = snap.data!;
            if (list.isEmpty) {
              return const EmptyState(
                icon: Icons.history_rounded,
                title: 'Nenhuma aplicação ainda',
                body: 'Cada receita aplicada neste aparelho aparece aqui: quem, quando, em qual máquina e o que mudou.',
              );
            }
            final children = <Widget>[];
            String? day;
            for (final (i, r) in list.indexed) {
              final d = _day(r.at);
              if (d != day) {
                children.add(SectionHeader(d));
                day = d;
              }
              children.add(_RecordTile(key: ValueKey('aplicacao-$i'), record: r));
            }
            children.add(Padding(
              padding: const EdgeInsets.fromLTRB(Ind.page, 20, Ind.page, 0),
              child: Text('Fica só neste aparelho; não vai junto com o projeto.', style: TextStyle(color: Ind.textMuted, fontSize: 13)),
            ));
            // No tablet, a coluna não estica até a borda (TB-3).
            return FormWidth(child: ListView(padding: const EdgeInsets.only(bottom: 32), children: children));
          },
        ),
      );
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({super.key, required this.record});
  final RecipeApplyRecord record;

  @override
  Widget build(BuildContext context) {
    final r = record;
    final l = r.at.toLocal();
    final (icon, color) = switch (r.outcome) {
      RecipeOutcome.applied => (Icons.check_circle_rounded, Ind.textFor(Ind.ok)),
      RecipeOutcome.divergent => (Icons.warning_amber_rounded, Ind.textFor(Ind.warn)),
      RecipeOutcome.partial || RecipeOutcome.notApplied => (Icons.error_rounded, Ind.textFor(Ind.alarm)),
    };
    final who = r.operator.isEmpty ? '' : ' · ${r.operator}';
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        leading: Icon(icon, color: color),
        title: Text('${r.recipeName} · versão ${r.version}', style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('${_RecipeHistoryPageState._two(l.hour)}:${_RecipeHistoryPageState._two(l.minute)} · ${r.machineName}$who\n${r.headline}',
            style: const TextStyle(height: 1.35)),
        childrenPadding: const EdgeInsets.fromLTRB(72, 0, Ind.page, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (r.changes.isEmpty) Text('Nenhum valor precisou mudar.', style: TextStyle(color: Ind.textDim)),
          for (final c in r.changes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${c.name}: ${c.from} → ${c.to}', style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(c.result, style: TextStyle(color: Ind.textDim, height: 1.35)),
              ]),
            ),
        ],
      ),
    );
  }
}
