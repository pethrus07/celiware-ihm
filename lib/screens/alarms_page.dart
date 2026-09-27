import 'package:flutter/material.dart';

import '../app/app_scope.dart';
import '../core/theme/app_theme.dart';
import '../models/alarm.dart';
import '../services/alarms/alarm_engine.dart';
import '../services/runtime/tag_codec.dart';
import '../widgets/alarms/alarm_widgets.dart';
import '../widgets/common/common.dart';
import '../widgets/hmi/hmi_frame.dart';

/// Lista de alarmes (ISA-18.2 §11.6): **Ativos** — o mais grave em cima,
/// reconhecer um a um — e **Histórico** — o que aconteceu, com hora.
class AlarmsPage extends StatelessWidget {
  const AlarmsPage({super.key});

  static const routeName = 'alarmes';

  static Route<void> route() => MaterialPageRoute(settings: const RouteSettings(name: routeName), builder: (_) => const AlarmsPage());

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.of(context).alarms;
    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) {
        final entries = engine.entries;
        final unack = engine.unackCount;
        return DefaultTabController(
          length: 2,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Alarmes'),
              actions: [
                // Reconhecer todos só com mais de um — com um, o botão do
                // próprio cartão resolve e fica mais claro o que se viu.
                if (unack > 1)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: TextButton(
                      key: const ValueKey('reconhecer-todos'),
                      onPressed: () => _ackAll(context, engine, unack),
                      child: const Text('Reconhecer todos'),
                    ),
                  ),
              ],
              bottom: TabBar(
                indicatorColor: Ind.accent,
                labelColor: Ind.text,
                unselectedLabelColor: Ind.textMuted,
                labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                tabs: [
                  Tab(text: entries.isEmpty ? 'Ativos' : 'Ativos (${entries.length})'),
                  const Tab(text: 'Histórico'),
                ],
              ),
            ),
            body: TabBarView(children: [
              _ActiveList(entries: entries),
              _HistoryList(events: engine.history),
            ]),
          ),
        );
      },
    );
  }

  static Future<void> _ackAll(BuildContext context, AlarmEngine engine, int n) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Reconhecer os $n alarmes?'),
        content: const Text('Reconhecer é confirmar que você viu. O alarme continua na lista enquanto a condição existir.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reconhecer todos')),
        ],
      ),
    );
    if (ok == true) engine.acknowledgeAll();
  }
}

class _ActiveList extends StatelessWidget {
  const _ActiveList({required this.entries});
  final List<AlarmEntry> entries;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const EmptyState(
        icon: Icons.check_circle_outline_rounded,
        title: 'Tudo normal',
        body: 'Nenhum alarme ativo. Quando um disparar, ele aparece aqui e numa faixa no topo do app.',
      );
    }
    return MinuteTicker(
      builder: (context) => ListView.separated(
        padding: const EdgeInsets.fromLTRB(Ind.page, Ind.space, Ind.page, 40),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, i) => _AlarmCard(entry: entries[i]),
      ),
    );
  }
}

class _AlarmCard extends StatelessWidget {
  const _AlarmCard({required this.entry});
  final AlarmEntry entry;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final project = scope.controller.project;
    final tag = entry.tagId == null ? null : project.tag(entry.tagId!);
    final c = entry.priority.color;
    final returned = entry.phase == AlarmPhase.returnedUnack;
    final rule = entry.rule;
    return Container(
      key: ValueKey('alarme-${entry.key}'),
      decoration: Ind.card(border: entry.phase.unacked ? c.withValues(alpha: returned ? 0.35 : 0.7) : null, width: 1.5),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: AlarmShape(priority: entry.priority, size: 34, blinking: entry.phase.unacked)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(entry.message,
                  style: TextStyle(fontFamily: Ind.condensed, fontWeight: FontWeight.w700, fontSize: 19, color: returned ? Ind.textDim : Ind.text, height: 1.15)),
              const SizedBox(height: 6),
              // O que a variável marca AGORA + a regra — o operador decide
              // sem abrir outra tela.
              if (tag != null)
                TagBuilder(
                  tagId: tag.id,
                  builder: (context, t, r) => Text(
                    [
                      tag.name,
                      'agora ${TagCodec.format(tag, r.value)}',
                      if (rule != null && rule.kind.isAnalog) '${rule.kind.label.toLowerCase()} ${TagCodec.format(tag, rule.limit)}',
                    ].join(' · '),
                    style: TextStyle(color: Ind.textDim, fontSize: 13.5, height: 1.35),
                  ),
                ),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                _Pill(text: '${entry.priority.label} · ${entry.phase.label}', color: entry.phase.unacked ? c : Ind.textMuted),
                Text('desde ${_hhmm(entry.since)} · ${_ago(entry.since)}', style: TextStyle(color: Ind.textMuted, fontSize: 12.5)),
              ]),
            ]),
          ),
        ]),
        if (entry.phase.unacked) ...[
          const SizedBox(height: 14),
          FilledButton.tonalIcon(
            key: ValueKey('reconhecer-${entry.key}'),
            onPressed: () => scope.alarms.acknowledge(entry.key),
            icon: const Icon(Icons.done_rounded),
            label: Text(returned ? 'Reconhecer (já normalizou)' : 'Reconhecer'),
          ),
        ],
      ]),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: TextStyle(color: Ind.textFor(color), fontWeight: FontWeight.w700, fontSize: 12.5)),
      );
}

class _HistoryList extends StatelessWidget {
  const _HistoryList({required this.events});
  final List<AlarmEvent> events;

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return const EmptyState(
        icon: Icons.history_rounded,
        title: 'Sem histórico ainda',
        body: 'Cada alarme que ativar, for reconhecido ou normalizar fica registrado aqui, com a hora.',
      );
    }
    // Agrupado por dia: "Hoje", "Ontem", "25/09".
    final items = <Widget>[];
    String? day;
    for (final ev in events) {
      final d = _dayLabel(ev.at);
      if (d != day) {
        day = d;
        items.add(SectionHeader(d, padding: const EdgeInsets.fromLTRB(0, 20, 0, 8)));
      }
      items.add(_HistoryRow(event: ev));
    }
    return ListView(padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 40), children: items);
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.event});
  final AlarmEvent event;

  @override
  Widget build(BuildContext context) {
    final typeColor = switch (event.type) {
      AlarmEventType.activated => event.priority.textColor,
      AlarmEventType.acknowledged => Ind.textDim,
      AlarmEventType.returned => Ind.textFor(Ind.ok),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        SizedBox(
          width: 74,
          child: Text(_hhmmss(event.at), style: TextStyle(fontFamily: Ind.mono, fontSize: 12.5, color: Ind.textMuted)),
        ),
        AlarmShape(priority: event.priority, size: 18),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(event.message, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, color: Ind.text)),
            const SizedBox(height: 2),
            Text([event.type.label, if (event.valueText.isNotEmpty && event.type == AlarmEventType.activated) event.valueText].join(' · '),
                style: TextStyle(color: typeColor, fontSize: 12.5, fontWeight: FontWeight.w600)),
          ]),
        ),
      ]),
    );
  }
}

String _two(int n) => n.toString().padLeft(2, '0');
String _hhmm(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';
String _hhmmss(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return 'agora';
  if (d.inMinutes < 60) return 'há ${d.inMinutes} min';
  if (d.inHours < 24) return 'há ${d.inHours} h';
  return 'há ${d.inDays} d';
}

String _dayLabel(DateTime t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Hoje';
  if (diff == 1) return 'Ontem';
  return '${_two(t.day)}/${_two(t.month)}';
}
