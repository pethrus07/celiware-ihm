import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../models/alarm.dart';
import '../../screens/alarms_page.dart';
import '../../services/alarms/alarm_engine.dart';

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

/// Faixa fixa no topo do app, acima de todas as telas, enquanto houver
/// alarme ativo ou esperando reconhecimento. Mostra o mais grave; toque abre
/// a lista. Vibra quando um alarme novo entra (no chão de fábrica o som não
/// funciona — ISA-18.2 §11.3.4 pede indicação visual sempre à vista).
class AlarmBannerHost extends StatefulWidget {
  const AlarmBannerHost({super.key, required this.navigator, required this.child});
  final GlobalKey<NavigatorState> navigator;
  final Widget child;

  /// Vai em `MaterialApp.navigatorObservers`: sabe quando a página de
  /// alarmes está no topo (a faixa se esconde lá).
  static final observer = AlarmsRouteObserver();

  @override
  State<AlarmBannerHost> createState() => _AlarmBannerHostState();
}

class _AlarmBannerHostState extends State<AlarmBannerHost> {
  AlarmEngine? _engine;

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
    // O Navigator some sem avisar o observador: zera para o próximo app/teste.
    AlarmBannerHost.observer.onAlarmsPage.value = false;
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

  @override
  Widget build(BuildContext context) {
    final engine = AppScope.of(context).alarms;
    return ListenableBuilder(
      listenable: Listenable.merge([engine, AlarmBannerHost.observer.onAlarmsPage]),
      builder: (context, _) {
        final list = engine.entries;
        // Na própria página de alarmes a faixa só repetiria o que está na tela.
        if (list.isEmpty || AlarmBannerHost.observer.onAlarmsPage.value) return widget.child;
        // Na faixa vai o que PEDE AÇÃO: o não reconhecido mais grave; só
        // depois o mais grave já reconhecido.
        final top = list.firstWhere((e) => e.phase.unacked, orElse: () => list.first);
        return Column(children: [
          _Banner(top: top, count: list.length, unack: engine.unackCount, onTap: _open),
          // A faixa já ocupou a área da barra de status: as telas abaixo não
          // podem reservá-la de novo.
          Expanded(child: MediaQuery.removePadding(context: context, removeTop: true, child: widget.child)),
        ]);
      },
    );
  }
}

/// Observa a pilha de telas para saber se a página de alarmes está no topo.
class AlarmsRouteObserver extends NavigatorObserver {
  final ValueNotifier<bool> onAlarmsPage = ValueNotifier(false);

  void _top(Route<dynamic>? r) {
    // Adiado: a troca de rota acontece no meio de um build.
    final v = r?.settings.name == AlarmsPage.routeName;
    if (v != onAlarmsPage.value) scheduleMicrotask(() => onAlarmsPage.value = v);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _top(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _top(previousRoute);
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _top(previousRoute);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => _top(newRoute);
}

class _Banner extends StatelessWidget {
  const _Banner({required this.top, required this.count, required this.unack, required this.onTap});
  final AlarmEntry top;
  final int count;
  final int unack;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = top.priority.color;
    final returned = top.phase == AlarmPhase.returnedUnack;
    // Grita só quando pede ação: tudo reconhecido = faixa discreta (continua
    // à vista enquanto a condição existir, como manda a ISA-18.2).
    final loud = unack > 0;
    final sub = [
      top.phase.label,
      if (top.valueText.isNotEmpty && !returned) top.valueText,
      'desde ${_hhmm(top.since)}',
    ].join(' · ');
    return Material(
      key: const ValueKey('faixa-alarme'),
      color: Color.alphaBlend(c.withValues(alpha: !loud || returned ? 0.07 : (Ind.isDark ? 0.18 : 0.14)), Ind.raised),
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.withValues(alpha: loud && !returned ? 0.8 : 0.35), width: loud ? 2 : 1))),
          child: SafeArea(
            bottom: false,
            child: Padding(
              // Mais alta que o necessário: o alto da tela é a área mais
              // difícil de acertar com o dedo (e o toque no alto demais cai
              // na barra de status do Android).
              padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
              child: Row(children: [
                AlarmShape(priority: top.priority, size: 30, blinking: top.phase.unacked),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(top.message,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontFamily: Ind.condensed, fontWeight: FontWeight.w700, fontSize: 18, color: returned ? Ind.textDim : Ind.text)),
                    const SizedBox(height: 2),
                    Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Ind.textDim, fontSize: 12.5)),
                  ]),
                ),
                if (count > 1)
                  Container(
                    margin: const EdgeInsets.only(left: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(color: Ind.surfaceHigh, borderRadius: BorderRadius.circular(20)),
                    child: Text('+${count - 1}', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Ind.text)),
                  ),
                Icon(Icons.chevron_right_rounded, color: Ind.textMuted),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  static String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
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
