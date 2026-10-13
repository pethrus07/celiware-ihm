import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../models/alarm.dart';
import '../../screens/alarms_page.dart';
import '../../services/alarms/alarm_engine.dart';
import '../../services/rules/rule_engine.dart';
import '../rules/rule_proposal_host.dart';
import 'silence_button.dart';
import 'top_band.dart';

/// Cor reservada de cada prioridade (ISA-18.2 §11.4.3): vermelho, laranja,
/// amarelo — em ordem de urgência, e só alarme usa laranja.
extension AlarmPriorityColor on AlarmPriority {
  Color get color => switch (this) {
        AlarmPriority.high => Ind.alarm,
        AlarmPriority.medium => Ind.alarmMid,
        AlarmPriority.low => Ind.warn,
      };

  Color get textColor => Ind.textFor(color);
}

/// Forma da prioridade com o número dentro: **losango** (alta), **triângulo**
/// (média), **quadrado** (baixa). Forma + número + cor — nenhum depende só da
/// cor (daltônico, visão periférica).
///
/// [blinking]: não reconhecido. Alterna cheio ↔ contorno a 1 Hz pelo relógio
/// único do [AlarmEngine] (todos piscam juntos; timer, não animação — 2
/// quadros/s). O texto ao lado nunca pisca (Rockwell §9.2).
class AlarmShape extends StatelessWidget {
  const AlarmShape({super.key, required this.priority, this.size = 28, this.blinking = false});

  final AlarmPriority priority;
  final double size;
  final bool blinking;

  @override
  Widget build(BuildContext context) {
    if (!blinking) return _paint(true);
    return ValueListenableBuilder<bool>(
      valueListenable: AppScope.of(context).alarms.blink,
      builder: (context, on, _) => _paint(on),
    );
  }

  Widget _paint(bool filled) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _ShapePainter(priority, filled, Ind.revision)),
      );
}

class _ShapePainter extends CustomPainter {
  _ShapePainter(this.priority, this.filled, this.rev);
  final AlarmPriority priority;
  final bool filled;
  final int rev;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final c = size.center(Offset.zero);
    final color = priority.color;
    final path = Path();
    switch (priority) {
      case AlarmPriority.high: // losango
        path
          ..moveTo(c.dx, c.dy - s / 2)
          ..lineTo(c.dx + s / 2, c.dy)
          ..lineTo(c.dx, c.dy + s / 2)
          ..lineTo(c.dx - s / 2, c.dy)
          ..close();
      case AlarmPriority.medium: // triângulo
        final h = s * math.sqrt(3) / 2;
        path
          ..moveTo(c.dx, c.dy - h / 2 - s * 0.04)
          ..lineTo(c.dx + s / 2, c.dy + h / 2)
          ..lineTo(c.dx - s / 2, c.dy + h / 2)
          ..close();
      case AlarmPriority.low: // quadrado de cantos suaves
        path.addRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: c, width: s * 0.82, height: s * 0.82), Radius.circular(s * 0.14)));
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = filled ? color : Colors.transparent
          ..style = PaintingStyle.fill);
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.5, s * 0.07)
          ..strokeJoin = StrokeJoin.round);
    // Número: escuro sobre o laranja/amarelo, claro sobre o vermelho.
    final onColor = color.computeLuminance() > 0.35 ? const Color(0xFF15181C) : Colors.white;
    final tp = TextPainter(
      text: TextSpan(
        text: '${priority.number}',
        style: TextStyle(
          fontFamily: Ind.condensed,
          fontWeight: FontWeight.w700,
          fontSize: s * (priority == AlarmPriority.medium ? 0.42 : 0.5),
          color: filled ? onColor : color,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final dy = priority == AlarmPriority.medium ? s * 0.12 : 0.0;
    tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2 - dy));
  }

  @override
  bool shouldRepaint(_ShapePainter o) => o.priority != priority || o.filled != filled || o.rev != rev;
}

/// Faixa de atenção no topo do app, acima de todas as telas e **sempre no
/// mesmo lugar** (ISA-101: a área de alarme é fixa em toda tela). Mostra,
/// nesta ordem:
///   1. o alarme mais grave **não reconhecido** (ISA-18.2 §11.3.4: alarme só
///      na tela que ninguém está olhando não é alarme);
///   2. a pergunta de uma regra (LG-6): "Parar a prensa?";
///   3. o alarme já reconhecido que continua ativo, discreto;
///   4. "Sem alarmes", quieta.
/// O que fica atrás vira marca na própria faixa: a pergunta esperando atrás
/// de um alarme novo, o alarme reconhecido atrás da pergunta.
///
/// **O espaço é reservado o tempo todo**, com altura fixa ([TopBand]): o que
/// entra ou sai troca o que está dentro da faixa, nunca a posição das telas.
/// Antes a faixa só ocupava espaço com alarme: quando ele chegava, a tela
/// descia ~70 dp e o toque seguinte (Liga, Confirmar, Salvar) caía em outro
/// lugar — o "pulo da tela" do QA. A outra saída, faixa por cima sem
/// reservar, não desloca nada, mas cobre a barra de título (voltar, editar,
/// ajuda) justo quando há alarme. Reservar custa 56 dp em pé (48 deitado) em
/// toda tela; em troca, nenhum alvo de toque muda de lugar nem fica coberto
/// por causa de um alarme ou de uma pergunta — com ou sem diálogo aberto.
///
/// Toque abre a lista de alarmes (ou a pergunta). Vibra quando um alarme novo
/// entra (no chão de fábrica o som não funciona).
class AlarmBannerHost extends StatefulWidget {
  const AlarmBannerHost({super.key, required this.navigator, required this.child});
  final GlobalKey<NavigatorState> navigator;
  final Widget child;

  @override
  State<AlarmBannerHost> createState() => _AlarmBannerHostState();
}

class _AlarmBannerHostState extends State<AlarmBannerHost> {
  AlarmEngine? _engine;

  /// A pergunta já está aberta (dois toques seguidos não abrem duas).
  bool _asking = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final e = AppScope.of(context).alarms;
    if (!identical(e, _engine)) {
      _engine?.newAlarm.removeListener(_buzz);
      _engine = e..newAlarm.addListener(_buzz);
    }
  }

  @override
  void dispose() {
    _engine?.newAlarm.removeListener(_buzz);
    super.dispose();
  }

  void _buzz() {
    HapticFeedback.heavyImpact();
    Future.delayed(const Duration(milliseconds: 160), HapticFeedback.heavyImpact);
  }

  void _open() {
    final nav = widget.navigator.currentState;
    if (nav == null) return;
    // Já está na lista? Não empilha outra.
    var onPage = false;
    nav.popUntil((r) {
      onPage = r.settings.name == AlarmsPage.routeName;
      return true;
    });
    if (!onPage) nav.push(AlarmsPage.route());
  }

  Future<void> _ask(RuleEngine rules) async {
    final nav = widget.navigator.currentState;
    final p = rules.proposals.firstOrNull;
    if (nav == null || p == null || _asking) return;
    _asking = true;
    try {
      await RuleProposalDialog.open(nav, rules: rules, proposal: p);
    } finally {
      _asking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final engine = scope.alarms;
    final rules = scope.rules;
    return ListenableBuilder(
      listenable: Listenable.merge([engine, ?rules]),
      builder: (context, _) {
        final list = engine.entries;
        final proposals = rules?.proposals ?? const <RuleProposal>[];
        final Widget band;
        if (list.isNotEmpty && (engine.unackCount > 0 || proposals.isEmpty)) {
          // Na faixa vai o que PEDE AÇÃO: o não reconhecido mais grave; só
          // depois o mais grave já reconhecido.
          final top = list.firstWhere((e) => e.phase.unacked, orElse: () => list.first);
          band = _Banner(
            top: top,
            count: list.length,
            unack: engine.unackCount,
            onTap: _open,
            waiting: proposals.length,
            onAsk: rules == null ? null : () => _ask(rules),
          );
        } else if (proposals.isNotEmpty) {
          band = RuleProposalBand(
            key: const ValueKey('proposta-regra'),
            proposal: proposals.first,
            more: proposals.length - 1,
            onTap: () => _ask(rules!),
            // Alarme reconhecido e ainda ativo: continua à vista (ISA-18.2),
            // como marca ao lado da pergunta.
            behind: list.isEmpty ? null : ElementAlarmBadge(entry: list.first),
          );
        } else {
          band = _Quiet(onTap: _open);
        }
        // Estrutura fixa (coluna → faixa + telas): a faixa trocar de conteúdo
        // nunca recria nem move as telas de baixo.
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(height: TopBand.slotOf(context), child: band),
          // A faixa já ocupou a área da barra de status: as telas abaixo
          // não podem reservá-la de novo.
          Expanded(child: MediaQuery.removePadding(context: context, removeTop: true, child: widget.child)),
        ]);
      },
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.top, required this.count, required this.unack, required this.onTap, this.waiting = 0, this.onAsk});
  final AlarmEntry top;
  final int count;
  final int unack;
  final VoidCallback onTap;

  /// Perguntas de regra esperando atrás deste alarme.
  final int waiting;
  final VoidCallback? onAsk;

  @override
  Widget build(BuildContext context) {
    final c = top.priority.color;
    final returned = top.phase == AlarmPhase.returnedUnack;
    // Grita só quando pede ação: tudo reconhecido = faixa discreta (continua
    // à vista enquanto a condição existir, como manda a ISA-18.2).
    final loud = unack > 0;
    // Sem o valor do disparo: congelado na faixa, ele desmentia o elemento
    // da tela, que mostra o valor de agora.
    final sub = '${top.phase.label} · desde ${_hhmm(top.since)}';
    final compact = TopBand.compact(context);
    const h = TopBand.lineHeight;
    return TopBand(
      key: const ValueKey('faixa-alarme'),
      color: Color.alphaBlend(c.withValues(alpha: !loud || returned ? 0.07 : (Ind.isDark ? 0.18 : 0.14)), Ind.raised),
      line: c.withValues(alpha: loud && !returned ? 0.8 : 0.35),
      lineWidth: loud ? 2 : 1,
      onTap: onTap,
      child: Row(children: [
        AlarmShape(priority: top.priority, size: TopBandLead.sizeOf(context), blinking: top.phase.unacked),
        const SizedBox(width: 14),
        Expanded(
          child: compact
              ? Text.rich(
                  TextSpan(children: [
                    TextSpan(text: top.message, style: TextStyle(fontFamily: Ind.condensed, fontWeight: FontWeight.w700, fontSize: 17, height: h, color: returned ? Ind.textDim : Ind.text)),
                    TextSpan(text: '   $sub', style: TextStyle(color: Ind.textDim, fontSize: 12.5, height: h)),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )
              : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(top.message,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: Ind.condensed, fontWeight: FontWeight.w700, fontSize: 18, height: h, color: returned ? Ind.textDim : Ind.text)),
                  const SizedBox(height: 2),
                  Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Ind.textDim, fontSize: 12.5, height: h)),
                ]),
        ),
        SilenceButton(entry: top, compact: true),
        if (count > 1)
          Container(
            margin: const EdgeInsets.only(left: 8),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(color: Ind.surfaceHigh, borderRadius: BorderRadius.circular(20)),
            child: Text('+${count - 1}', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Ind.text)),
          ),
        if (waiting > 0 && onAsk != null) RuleProposalMarker(count: waiting, onTap: onAsk!),
        Icon(Icons.chevron_right_rounded, color: Ind.textMuted),
      ]),
    );
  }

  static String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// A faixa sem nada a mostrar: o lugar continua reservado e diz, em cinza,
/// que está tudo quieto (ISA-101: o normal não chama atenção). Toque abre a
/// lista de alarmes — e dela o histórico.
class _Quiet extends StatelessWidget {
  const _Quiet({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TopBand(
      key: const ValueKey('faixa-quieta'),
      color: Ind.bg,
      onTap: onTap,
      child: Row(children: [
        TopBandLead(child: Icon(Icons.notifications_none_rounded, size: 20, color: Ind.textMuted)),
        const SizedBox(width: 14),
        Expanded(
          child: Text('Sem alarmes', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Ind.textMuted, fontSize: 14, height: TopBand.lineHeight)),
        ),
        Icon(Icons.chevron_right_rounded, color: Ind.textMuted),
      ]),
    );
  }
}

/// Sino no topo das telas: abre a lista de alarmes (também o histórico,
/// quando está tudo normal). O número é dos que esperam reconhecimento.
class AlarmBell extends StatelessWidget {
  const AlarmBell({super.key});

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.of(context).alarms;
    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) {
        final n = engine.unackCount;
        final top = engine.entries.firstOrNull;
        return IconButton(
          key: const ValueKey('sino-alarmes'),
          tooltip: 'Alarmes',
          onPressed: () => Navigator.push(context, AlarmsPage.route()),
          icon: Badge(
            isLabelVisible: n > 0,
            label: Text('$n'),
            backgroundColor: top?.priority.color ?? Ind.alarm,
            textColor: (top?.priority.color ?? Ind.alarm).computeLuminance() > 0.35 ? const Color(0xFF15181C) : Colors.white,
            child: Icon(engine.hasAny ? Icons.notifications_active_outlined : Icons.notifications_none_rounded),
          ),
        );
      },
    );
  }
}

/// Marca de alarme no próprio elemento da tela: o alarme aparece **onde o
/// valor está** (PAS: indicador ao lado do valor), não só na faixa.
class ElementAlarmBadge extends StatelessWidget {
  const ElementAlarmBadge({super.key, required this.entry});
  final AlarmEntry entry;

  @override
  Widget build(BuildContext context) => AlarmShape(priority: entry.priority, size: 20, blinking: entry.phase.unacked);
}

/// Atualiza "há 3 min" sem depender de outra mudança.
class MinuteTicker extends StatefulWidget {
  const MinuteTicker({super.key, required this.builder});
  final WidgetBuilder builder;

  @override
  State<MinuteTicker> createState() => _MinuteTickerState();
}

class _MinuteTickerState extends State<MinuteTicker> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
