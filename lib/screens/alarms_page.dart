import 'package:flutter/material.dart';

import '../app/app_scope.dart';
import '../core/theme/app_theme.dart';
import '../models/alarm.dart';
import '../services/alarms/alarm_engine.dart';
import '../services/runtime/tag_codec.dart';
import '../widgets/alarms/alarm_widgets.dart';
import '../widgets/alarms/silence_button.dart';
import '../widgets/common/adaptive.dart';
import '../widgets/common/common.dart';
import '../widgets/hmi/hmi_frame.dart';

/// Lista de alarmes (ISA-18.2 §11.6): **Ativos** — o mais grave em cima,
/// reconhecer um a um — e **Histórico** — o que aconteceu, com hora.
///
/// No tablet deitado (TB-2) a lista fica à esquerda e o alarme tocado abre ao
/// lado: o valor de agora em letra grande e o que já aconteceu com ele. Sem
/// toque, o detalhe mostra o mais grave.
class AlarmsPage extends StatefulWidget {
  const AlarmsPage({super.key});

  static const routeName = 'alarmes';

  static Route<void> route() => MaterialPageRoute(settings: const RouteSettings(name: routeName), builder: (_) => const AlarmsPage());

  @override
  State<AlarmsPage> createState() => _AlarmsPageState();
}

/// Alarme aberto no detalhe: pela chave quando veio da lista de ativos; só
/// pelo texto quando veio do histórico (o evento não guarda a chave).
typedef _Pick = ({String? key, String message});

class _AlarmsPageState extends State<AlarmsPage> {
  _Pick? _pick;

  /// As abas mudam de lugar na árvore ao girar o tablet: a chave leva junto
  /// a rolagem das listas.
  final _tabsKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.of(context).alarms;
    final two = WindowClass.twoPane(context);
    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) {
        final entries = engine.entries;
        final unack = engine.unackCount;
        final first = entries.firstOrNull;
        final pick = _pick ?? (first == null ? null : (key: first.key, message: first.message));
        void select(_Pick p) => setState(() => _pick = p);
        final tabs = KeyedSubtree(
          key: _tabsKey,
          child: TabBarView(children: [
            _ActiveList(
              entries: entries,
              selectedKey: two ? pick?.key : null,
              onSelect: two ? (e) => select((key: e.key, message: e.message)) : null,
            ),
            _HistoryList(
              events: engine.history,
              selectedMessage: two && pick?.key == null ? pick?.message : null,
              onSelect: two ? (ev) => select((key: null, message: ev.message)) : null,
            ),
          ]),
        );
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
                // Com dois painéis, as abas ficam sobre a lista.
                isScrollable: two,
                tabAlignment: two ? TabAlignment.start : null,
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
            body: two
                ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    SizedBox(width: 360, child: tabs),
                    // Tom de cartão: separa da lista pelo fundo, sem linha.
                    Expanded(child: Material(color: Ind.surface, child: FormWidth(child: _AlarmDetail(pick: pick, entries: entries, history: engine.history)))),
                  ])
                : tabs,
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
  const _ActiveList({required this.entries, this.selectedKey, this.onSelect});
  final List<AlarmEntry> entries;

  /// Com dois painéis: o alarme aberto no detalhe e o toque que abre outro.
  final String? selectedKey;
  final ValueChanged<AlarmEntry>? onSelect;

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
        itemBuilder: (context, i) => _AlarmCard(
          entry: entries[i],
          selected: entries[i].key == selectedKey,
          onTap: onSelect == null ? null : () => onSelect!(entries[i]),
        ),
      ),
    );
  }
}

class _AlarmCard extends StatelessWidget {
  const _AlarmCard({required this.entry, this.selected = false, this.onTap});
  final AlarmEntry entry;

  /// Aberto no detalhe ao lado (tablet): fundo na cor de seleção. A borda
  /// continua sendo do estado do alarme.
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final project = scope.controller.project;
    final tag = entry.tagId == null ? null : project.tag(entry.tagId!);
    final c = entry.priority.color;
    final returned = entry.phase == AlarmPhase.returnedUnack;
    final rule = entry.rule;
    final card = Container(
      key: ValueKey('alarme-${entry.key}'),
      decoration: Ind.card(
        color: selected ? Color.alphaBlend(Ind.accent.withValues(alpha: 0.12), Ind.surface) : null,
        border: entry.phase.unacked ? c.withValues(alpha: returned ? 0.35 : 0.7) : null,
        width: 1.5,
      ),
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
          // Silenciar ao lado, discreto: cala a voz sem reconhecer (VZ-3).
          Row(children: [
            Expanded(
              child: FilledButton.tonalIcon(
                key: ValueKey('reconhecer-${entry.key}'),
                onPressed: () => scope.alarms.acknowledge(entry.key),
                icon: const Icon(Icons.done_rounded),
                label: Text(returned ? 'Reconhecer (já normalizou)' : 'Reconhecer'),
              ),
            ),
            SilenceButton(entry: entry),
          ]),
        ],
      ]),
    );
    final tap = onTap;
    return tap == null ? card : GestureDetector(behavior: HitTestBehavior.opaque, onTap: tap, child: card);
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
  const _HistoryList({required this.events, this.selectedMessage, this.onSelect});
  final List<AlarmEvent> events;

  /// Com dois painéis: o alarme aberto no detalhe e o toque que abre outro.
  final String? selectedMessage;
  final ValueChanged<AlarmEvent>? onSelect;

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
      final tap = onSelect;
      final row = _HistoryRow(event: ev);
      items.add(tap == null
          ? row
          : Material(
              // Linha do alarme aberto no detalhe: fundo na cor de seleção.
              color: ev.message == selectedMessage ? Ind.accent.withValues(alpha: 0.12) : Colors.transparent,
              borderRadius: BorderRadius.circular(Ind.radiusSmall),
              child: InkWell(
                borderRadius: BorderRadius.circular(Ind.radiusSmall),
                onTap: () => tap(ev),
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: row),
              ),
            ));
    }
    return ListView(padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 40), children: items);
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.event});
  final AlarmEvent event;

  @override
  Widget build(BuildContext context) {
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
            _EventType(event: event),
          ]),
        ),
      ]),
    );
  }
}

/// "Ativou · 88,2 °C", "Reconhecido", "Normalizou" — na cor do que aconteceu.
class _EventType extends StatelessWidget {
  const _EventType({required this.event});
  final AlarmEvent event;

  @override
  Widget build(BuildContext context) {
    final color = switch (event.type) {
      AlarmEventType.activated => event.priority.textColor,
      AlarmEventType.acknowledged => Ind.textDim,
      AlarmEventType.returned => Ind.textFor(Ind.ok),
      AlarmEventType.silenced => Ind.textMuted,
    };
    return Text([event.type.label, if (event.valueText.isNotEmpty && event.type == AlarmEventType.activated) event.valueText].join(' · '),
        style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w600));
  }
}

/// Detalhe do alarme no tablet deitado: o que é, quanto marca agora (em letra
/// grande, para ler de longe), o que fazer e o que já aconteceu com ele.
/// Alarme que saiu da lista (reconhecido e normalizado) continua aberto, só
/// com o histórico — o detalhe não pula sozinho para outro.
class _AlarmDetail extends StatelessWidget {
  const _AlarmDetail({required this.pick, required this.entries, required this.history});
  final _Pick? pick;
  final List<AlarmEntry> entries;
  final List<AlarmEvent> history;

  @override
  Widget build(BuildContext context) {
    final p = pick;
    if (p == null) {
      return const EmptyState(
        icon: Icons.notifications_none_rounded,
        title: 'Nenhum alarme aberto',
        body: 'Toque num alarme da lista para ver o valor de agora e o que já aconteceu com ele.',
      );
    }
    final scope = AppScope.of(context);
    final entry = entries.where((e) => p.key != null ? e.key == p.key : e.message == p.message).firstOrNull;
    final message = entry?.message ?? p.message;
    final events = history.where((ev) => ev.message == message).take(20).toList();
    final priority = entry?.priority ?? events.firstOrNull?.priority ?? AlarmPriority.medium;
    final tag = entry?.tagId == null ? null : scope.controller.project.tag(entry!.tagId!);
    final rule = entry?.rule;

    return ListView(
      key: const ValueKey('detalhe-alarme'),
      padding: const EdgeInsets.fromLTRB(Ind.spaceLarge, Ind.spaceLarge, Ind.spaceLarge, 40),
      children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AlarmShape(priority: priority, size: 40, blinking: entry?.phase.unacked ?? false),
          const SizedBox(width: Ind.space),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(message, style: TextStyle(fontFamily: Ind.condensed, fontWeight: FontWeight.w700, fontSize: 24, color: Ind.text, height: 1.15)),
              const SizedBox(height: 10),
              entry == null
                  ? Text('Normal agora', style: TextStyle(color: Ind.textFor(Ind.ok), fontWeight: FontWeight.w600))
                  : Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      _Pill(text: '${entry.priority.label} · ${entry.phase.label}', color: entry.phase.unacked ? entry.priority.color : Ind.textMuted),
                      Text('desde ${_hhmm(entry.since)} · ${_ago(entry.since)}', style: TextStyle(color: Ind.textMuted, fontSize: 12.5)),
                    ]),
            ]),
          ),
        ]),
        if (tag != null) ...[
          const SectionHeader('Agora', padding: EdgeInsets.fromLTRB(0, 36, 0, 10)),
          TagBuilder(
            tagId: tag.id,
            builder: (context, t, r) => Text(TagCodec.format(tag, r.value), key: const ValueKey('detalhe-alarme-valor'), style: Ind.number(56)),
          ),
          const SizedBox(height: 8),
          Text(
            [tag.name, if (rule != null && rule.kind.isAnalog) '${rule.kind.label.toLowerCase()} ${TagCodec.format(tag, rule.limit)}'].join(' · '),
            style: TextStyle(color: Ind.textDim, height: 1.35),
          ),
        ],
        if (entry != null && entry.phase.unacked) ...[
          const SizedBox(height: Ind.spaceLarge),
          Row(children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: () => scope.alarms.acknowledge(entry.key),
                icon: const Icon(Icons.done_rounded),
                label: Text(entry.phase == AlarmPhase.returnedUnack ? 'Reconhecer (já normalizou)' : 'Reconhecer'),
              ),
            ),
            SilenceButton(entry: entry),
          ]),
        ],
        if (events.isNotEmpty) ...[
          const SectionHeader('O que aconteceu', padding: EdgeInsets.fromLTRB(0, 36, 0, 4)),
          for (final ev in events)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                SizedBox(
                  width: 120,
                  child: Text('${_dayLabel(ev.at)} ${_hhmmss(ev.at)}', style: TextStyle(fontFamily: Ind.mono, fontSize: 12.5, color: Ind.textMuted)),
                ),
                Expanded(child: _EventType(event: ev)),
              ]),
            ),
        ],
      ],
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
