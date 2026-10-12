import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../models/logic_rule.dart';
import '../../models/project.dart';
import '../../services/calc/calc_graph.dart';
import '../../services/rules/rule_engine.dart';
import '../../services/runtime/tag_codec.dart';
import '../../widgets/common/adaptive.dart';
import 'rule_editor_page.dart';

/// Mais → Regras (LG-4 a LG-7): "quando [condição] durar [T s], então gravar
/// [valor] em [variável]". Cada regra numa linha com o que ela vigia, o que
/// faz e como está agora; a chave liga e desliga sem abrir.
///
/// O aviso de segurança fica sempre no topo: regra ajuda, não protege.
class RulesPage extends StatelessWidget {
  const RulesPage({super.key});

  /// "na hora", "10 s", "5 min".
  static String holdLabel(int s) => s == 0 ? 'na hora' : (s < 60 ? '$s s' : '${s ~/ 60} min');

  /// 'grava DESLIGADO em "Liga prensa", perguntando antes'.
  static String actionText(LogicRule r, Project p) {
    final t = p.tag(r.targetTagId);
    if (t == null) return r.targetTagId.isEmpty ? 'falta escolher onde gravar' : 'a variável de destino foi apagada';
    final how = r.mode == RuleMode.automatic ? 'sozinha' : 'perguntando antes';
    return 'grava ${TagCodec.format(t, RuleEngine.valueFor(r, t))} em "${t.name}", $how';
  }

  static (String, Color, IconData) statusLine(RuleStatus s) => switch (s.state) {
        RuleState.off => ('Desligada', Ind.textMuted, Icons.pause_circle_outline_rounded),
        RuleState.watching => (s.message.isEmpty ? 'Vigiando' : 'Vigiando · ${s.message}', Ind.textMuted, Icons.visibility_outlined),
        RuleState.counting => ('Condição presente · ${s.message}', Ind.textFor(Ind.warn), Icons.timer_outlined),
        RuleState.acted => ('Agiu · espera a condição passar', Ind.textFor(Ind.info), Icons.check_circle_outline_rounded),
        RuleState.blocked => ('Parada: ${s.message}', Ind.textFor(Ind.alarm), Icons.error_outline_rounded),
      };

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.watch(context);
    final engine = scope.rules;
    final project = scope.controller.project;
    return Scaffold(
      appBar: AppBar(title: const Text('Regras'), actions: [
        IconButton(
          key: const ValueKey('historico-regras'),
          tooltip: 'Histórico',
          icon: const Icon(Icons.history_rounded),
          onPressed: engine == null ? null : () => _showHistory(context, engine),
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        key: const ValueKey('nova-regra'),
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RuleEditorPage())),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Nova regra'),
      ),
      // No tablet, a coluna das regras não estica até a borda (TB-3, como Mais).
      body: FormWidth(child: ListenableBuilder(
        listenable: engine ?? scope.controller,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(Ind.page, 8, Ind.page, 110),
          children: [
            const _SafetyNote(),
            const SizedBox(height: Ind.space),
            if (project.rules.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  'Nenhuma regra ainda. Exemplo: quando a temperatura da prensa passar de 85 °C por 10 s, perguntar "Parar a prensa?" e desligar se você tocar.',
                  style: TextStyle(color: Ind.textDim, height: 1.45),
                ),
              ),
            for (final r in project.rules) ...[
              _RuleCard(rule: r, project: project, status: engine?.status(r.id) ?? (r.enabled ? RuleStatus.watching : RuleStatus.off)),
              const SizedBox(height: Ind.space),
            ],
          ],
        ),
      )),
    );
  }

  static void _showHistory(BuildContext context, RuleEngine engine) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.95,
          builder: (context, scroll) {
            final events = engine.history;
            String two(int n) => n.toString().padLeft(2, '0');
            return ListView(
              key: const ValueKey('lista-historico-regras'),
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 32),
              children: [
                Text('Histórico das regras', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                if (events.isEmpty) Text('Nada aconteceu ainda.', style: TextStyle(color: Ind.textDim)),
                for (final e in events)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('${e.type.label} · ${e.rule}', style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: e.text.isEmpty ? null : Text(e.text),
                    trailing: Text('${two(e.at.day)}/${two(e.at.month)} ${two(e.at.hour)}:${two(e.at.minute)}:${two(e.at.second)}',
                        style: Ind.number(12, color: Ind.textMuted)),
                  ),
              ],
            );
          },
        ),
      );
}

/// Regra ajuda, não protege — escrito no app, como pede o ROADMAP.
class _SafetyNote extends StatelessWidget {
  const _SafetyNote();

  @override
  Widget build(BuildContext context) => Container(
        key: const ValueKey('aviso-seguranca-regras'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: Ind.info.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(Ind.radiusSmall)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.shield_outlined, color: Ind.textFor(Ind.info)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Regra avisa e ajuda — não é segurança. O celular pode demorar ou parar de ler (Wi-Fi, bateria, app fechado). '
              'Intertravamento e parada de emergência ficam no CLP.',
              style: TextStyle(height: 1.4, color: Ind.text),
            ),
          ),
        ]),
      );
}

class _RuleCard extends StatelessWidget {
  const _RuleCard({required this.rule, required this.project, required this.status});
  final LogicRule rule;
  final Project project;
  final RuleStatus status;

  @override
  Widget build(BuildContext context) {
    final (text, color, icon) = RulesPage.statusLine(status);
    final hold = rule.holdSec == 0 ? '' : ' por ${RulesPage.holdLabel(rule.holdSec)}';
    return Card(
      child: InkWell(
        key: ValueKey('regra-${rule.id}'),
        borderRadius: BorderRadius.circular(Ind.radius),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => RuleEditorPage(rule: rule))),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 8, 16),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(rule.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
                const SizedBox(height: 4),
                Text('Quando ${CalcGraph.display(rule.condition, project)}$hold', style: TextStyle(color: Ind.textDim, height: 1.3)),
                Text('Então ${RulesPage.actionText(rule, project)}', style: TextStyle(color: Ind.textDim, height: 1.3)),
                const SizedBox(height: 8),
                Row(children: [
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: 6),
                  Expanded(child: Text(text, key: ValueKey('estado-regra-${rule.id}'), style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 13))),
                ]),
              ]),
            ),
            Switch(
              key: ValueKey('ligar-regra-${rule.id}'),
              value: rule.enabled,
              onChanged: (v) => AppScope.of(context).controller.saveRule(rule.copyWith(enabled: v)),
            ),
          ]),
        ),
      ),
    );
  }
}
