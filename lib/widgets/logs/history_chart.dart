import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../models/tag.dart';
import '../../services/logging/log_store.dart';
import '../hmi/elements/chart_elements.dart';

/// Uma curva do histórico: a variável, a cor e a posição dela na consulta.
class HistorySeries {
  const HistorySeries({required this.tag, required this.color, required this.index});
  final Tag tag;
  final Color color;

  /// Posição nas listas de [LogBucket] (ordem pedida ao banco).
  final int index;
}

/// Gráfico do histórico do registro (RG-5).
///
/// Mesma régua, poço, grade e eixo duplo da tendência da tela ([TrendScale])
/// — a pessoa lê os dois do mesmo jeito. Muda o que chega: fatias de tempo
/// já reduzidas (mínimo e máximo por pixel, do banco), buracos e o cursor do
/// "valor sob o dedo". Cada fatia vira um traço vertical do mínimo ao máximo,
/// ligado à vizinha pelo extremo mais próximo: um pico de um segundo numa
/// semana inteira continua aparecendo, sem desenhar 600 mil pontos.
class HistoryPainter extends CustomPainter {
  HistoryPainter({
    required this.window,
    required this.series,
    required this.fromMs,
    required this.toMs,
    required this.gapMs,
    this.cursorMs,
  });

  final LogWindow window;
  final List<HistorySeries> series;

  /// Janela visível (pode diferir da consulta durante o gesto: as fatias se
  /// reposicionam na hora e a consulta nova chega logo depois).
  final int fromMs, toMs;

  /// Distância entre linhas acima da qual a curva é interrompida (app
  /// fechado, registro desligado) — nunca ligar dois pontos que não se
  /// conhecem.
  final int gapMs;
  final int? cursorMs;

  /// Paleta com que foi criado: troca de tema força redesenho.
  final int rev = Ind.revision;

  static const _left = 38.0, _bottom = 18.0;

  /// Área das curvas. O gesto usa a mesma conta para virar dedo em instante.
  static Rect plotFor(Size size, {required bool dual}) => Rect.fromLTRB(_left, 4, size.width - (dual ? 40.0 : 4.0), size.height - _bottom);

  /// Unidades diferentes ganham eixo à direita, como na tendência.
  static bool isDual(List<HistorySeries> series) => series.any((s) => s.tag.unit != series.first.tag.unit);

  double _x(Rect plot, num ms) => plot.left + plot.width * ((ms - fromMs) / (toMs - fromMs));

  List<LogBucket> get _visible => [for (final b in window.buckets) if (b.lastMs >= fromMs && b.firstMs <= toMs) b];

  @override
  void paint(Canvas canvas, Size size) {
    if (series.isEmpty || toMs <= fromMs) return;
    final leftGroup = [for (final s in series) if (s.tag.unit == series.first.tag.unit) s];
    final rightGroup = [for (final s in series) if (!leftGroup.contains(s)) s];
    final dual = rightGroup.isNotEmpty;
    final plot = plotFor(size, dual: dual);
    if (plot.width <= 10 || plot.height <= 10) return;
    final visible = _visible;

    final scale = TrendScale.paint(
      canvas,
      plot,
      leftData: _range(visible, leftGroup),
      rightData: dual ? _range(visible, rightGroup) : null,
      leftColor: dual ? leftGroup.first.color : Ind.textMuted,
      rightColor: dual ? rightGroup.first.color : Ind.textMuted,
    );
    _timeLabels(canvas, plot);

    canvas.save();
    canvas.clipRect(plot.inflate(2));
    for (final s in series) {
      _drawSeries(canvas, plot, scale, visible, s, right: rightGroup.contains(s), area: identical(s, series.first));
    }
    canvas.restore();
    _drawCursor(canvas, plot, scale, rightGroup);
  }

  static (double, double) _range(List<LogBucket> buckets, List<HistorySeries> group) {
    var lo = double.infinity, hi = -double.infinity;
    for (final b in buckets) {
      for (final s in group) {
        final a = b.min[s.index], c = b.max[s.index];
        if (a != null) lo = math.min(lo, a);
        if (c != null) hi = math.max(hi, c);
      }
    }
    return (lo, hi);
  }

  void _drawSeries(Canvas canvas, Rect plot, TrendScale scale, List<LogBucket> buckets, HistorySeries s, {required bool right, required bool area}) {
    final i = s.index;
    final segments = <List<Offset>>[];
    var seg = <Offset>[];
    LogBucket? prev;
    for (final b in buckets) {
      // Buraco: linhas longe demais (nada gravado entre elas) ou fatia
      // inteira nula para esta variável (sem comunicação).
      final broken = prev != null && b.firstMs - prev.lastMs > gapMs;
      if (broken || b.counts[i] == 0) {
        if (seg.isNotEmpty) segments.add(seg);
        seg = [];
      }
      prev = b;
      if (b.counts[i] == 0) continue;
      final x = _x(plot, b.midMs);
      final yLo = scale.y(plot, b.min[i]!, right: right), yHi = scale.y(plot, b.max[i]!, right: right);
      // Do extremo mais perto do ponto anterior para o outro: o traço não
      // vira um zigue-zague que não existe nos dados.
      final loFirst = seg.isEmpty || (seg.last.dy - yLo).abs() <= (seg.last.dy - yHi).abs();
      seg.add(Offset(x, loFirst ? yLo : yHi));
      if ((yHi - yLo).abs() > 0.5) seg.add(Offset(x, loFirst ? yHi : yLo));
    }
    if (seg.isNotEmpty) segments.add(seg);

    final line = Paint()
      ..color = s.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round;
    for (final pts in segments) {
      if (pts.length == 1) {
        // Ponto solto entre dois buracos: aparece como ponto, não some.
        canvas.drawCircle(pts.first, 2.5, Paint()..color = s.color);
        continue;
      }
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (final p in pts.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      // Área em degradê só sob a 1ª curva, como na tendência da tela.
      if (area) {
        final fill = Path.from(path)
          ..lineTo(pts.last.dx, plot.bottom)
          ..lineTo(pts.first.dx, plot.bottom)
          ..close();
        canvas.drawPath(
            fill,
            Paint()
              ..shader = LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [s.color.withValues(alpha: 0.22), s.color.withValues(alpha: 0)],
              ).createShader(plot));
      }
      canvas.drawPath(path, line);
    }
  }

  void _timeLabels(Canvas canvas, Rect plot) {
    final tp = TextPainter(textDirection: TextDirection.ltr);
    final span = toMs - fromMs;
    for (final (frac, align) in const [(0.0, 0.0), (0.5, 0.5), (1.0, 1.0)]) {
      // Mesma letra dos números do eixo (sem família, o pintor caía na letra
      // do sistema e a régua de baixo destoava da do lado).
      tp.text = TextSpan(text: axisTime(fromMs + (span * frac).round(), span), style: TextStyle(fontFamily: Ind.mono, fontSize: 10, color: Ind.textMuted));
      tp.layout();
      tp.paint(canvas, Offset(plot.left + plot.width * frac - tp.width * align, plot.bottom + 4));
    }
  }

  void _drawCursor(Canvas canvas, Rect plot, TrendScale scale, List<HistorySeries> rightGroup) {
    final c = cursorMs;
    if (c == null || c < fromMs || c > toMs) return;
    final b = nearBucket(window, c, gapMs);
    // Encaixa na fatia de verdade (a linha fica sobre o ponto lido); sem
    // fatia perto, o cursor fica onde o dedo está, sobre o buraco.
    final x = _x(plot, b?.midMs ?? c);
    canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), Paint()
      ..color = Ind.textDim
      ..strokeWidth = 1);
    if (b == null) return;
    for (final s in series) {
      final v = b.avg[s.index];
      if (b.counts[s.index] == 0 || v == null) continue;
      final p = Offset(x, scale.y(plot, v, right: rightGroup.contains(s)));
      canvas.drawCircle(p, 5, Paint()..color = Ind.surface);
      canvas.drawCircle(p, 3.5, Paint()..color = s.color);
    }
  }

  /// Fatia sob o dedo, desde que perto o bastante: no meio de um buraco não
  /// há valor para mostrar.
  static LogBucket? nearBucket(LogWindow window, int ms, int gapMs) {
    final b = window.nearest(ms);
    if (b == null) return null;
    final d = ms < b.firstMs ? b.firstMs - ms : (ms > b.lastMs ? ms - b.lastMs : 0);
    return d <= gapMs ~/ 2 ? b : null;
  }

  /// Hora no eixo: com segundos em janelas curtas, com o dia em janelas
  /// de mais de um dia.
  static String axisTime(int utcMs, int spanMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(utcMs);
    String two(int n) => n.toString().padLeft(2, '0');
    final hm = '${two(d.hour)}:${two(d.minute)}';
    if (spanMs <= 10 * 60 * 1000) return '$hm:${two(d.second)}';
    if (spanMs <= 24 * 3600 * 1000) return hm;
    return '${two(d.day)}/${two(d.month)} $hm';
  }

  @override
  bool shouldRepaint(HistoryPainter old) =>
      old.window != window || old.fromMs != fromMs || old.toMs != toMs || old.cursorMs != cursorMs || old.rev != rev || old.gapMs != gapMs || !_sameSeries(old.series);

  bool _sameSeries(List<HistorySeries> o) {
    if (o.length != series.length) return false;
    for (var i = 0; i < o.length; i++) {
      if (o[i].tag.id != series[i].tag.id || o[i].color != series[i].color || o[i].index != series[i].index) return false;
    }
    return true;
  }
}
