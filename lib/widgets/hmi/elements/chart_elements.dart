import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../core/theme/app_theme.dart';
import '../../../models/alarm.dart';
import '../../../models/hmi_screen.dart';
import '../../../models/tag.dart';
import '../../../services/runtime/tag_codec.dart';
import '../../../services/runtime/tag_store.dart';
import '../../common/common.dart';
import '../hmi_frame.dart';

/// Gráfico de tendência: curva dos últimos [windowSec] segundos de até 3
/// variáveis numéricas.
///
/// Usa o histórico curto do [TagStore] (que já vinha sendo gravado enquanto a
/// variável estava em uso), então abrir a tela mostra a curva recente em vez
/// de começar vazio. Redesenha 2× por segundo — o olho não pede mais que isso
/// e poupa bateria.
class TrendElement extends StatefulWidget {
  const TrendElement({super.key, required this.element});
  final HmiElement element;

  @override
  State<TrendElement> createState() => _TrendElementState();
}

class _TrendElementState extends State<TrendElement> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.element;
    final scope = AppScope.watch(context);
    final project = scope.controller.project;
    final ids = e.tagIds.take(3).toList();
    final tags = [for (final id in ids) project.tag(id)];
    final window = Duration(seconds: e.prop<num>('windowSec', 120).toInt().clamp(10, 600));
    final now = DateTime.now();

    final series = <_Series>[];
    for (var i = 0; i < ids.length; i++) {
      final t = tags[i];
      if (t == null) continue;
      series.add(_Series(
        tag: t,
        // Cores de dados da paleta, nunca de estado: curva verde parecia "ok" e amarela, alarme.
        color: Ind.series[i % Ind.series.length],
        samples: scope.runtime.store.history(ids[i]).where((s) => now.difference(s.at) <= window).toList(),
        reading: scope.runtime.store.read(ids[i]),
      ));
    }

    final lost = series.isNotEmpty && series.every((s) => s.reading.quality == TagQuality.commLost);

    return HmiFrame(
      label: e.prop<String>('label', ''),
      tag: series.isEmpty ? null : series.first.tag,
      reading: lost ? series.first.reading : const TagReading(quality: TagQuality.good),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 2,
            children: [
              // Nome longo encolhe com reticências em vez de transbordar
              // (pego pelo teste de widget com "Temperatura do motor").
              for (final s in series)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 12, height: 3, decoration: BoxDecoration(color: s.color, borderRadius: BorderRadius.circular(2))),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(text: '${s.tag.name}: ', style: TextStyle(color: Ind.textMuted, fontSize: 12)),
                        TextSpan(text: TagCodec.format(s.tag, s.reading.value), style: Ind.number(12.5, color: s.color)),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ]),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: CustomPaint(
              painter: _TrendPainter(
                series: series,
                now: now,
                window: window,
                fixedMin: (e.props['min'] as num?)?.toDouble(),
                fixedMax: (e.props['max'] as num?)?.toDouble(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Eixo da direita do gráfico de tendência — exposto só para os testes.
@visibleForTesting
(double, double) trendAlignedRange(double dataLo, double dataHi, int steps) => TrendScale.alignedRange(dataLo, dataHi, steps);

/// Régua dos gráficos de linha. A tendência da tela e o histórico do
/// registro desenham poço, grade e eixos por aqui, para os dois lerem igual
/// (mesmos passos redondos, mesmo eixo duplo, mesmos números).
class TrendScale {
  const TrendScale._(this.lo, this.hi, this.rLo, this.rHi);

  /// Eixo da esquerda.
  final double lo, hi;

  /// Eixo da direita (unidade diferente da 1ª curva); 0..1 quando não há.
  final double rLo, rHi;

  /// Valor → y dentro de [plot], no eixo pedido.
  double y(Rect plot, double v, {bool right = false}) {
    final a = right ? rLo : lo, b = right ? rHi : hi;
    return plot.bottom - plot.height * ((v - a) / (b - a));
  }

  /// Calcula as faixas e desenha poço, grade e números dos dois eixos.
  /// [leftData]/[rightData] = (mín., máx.) dos dados de cada lado (infinitos
  /// se vazio); sem [rightData], eixo só à esquerda.
  ///
  /// [leftLimits] = limites de alarme das variáveis do eixo da esquerda (dão
  /// a faixa quando a curva está parada); [leftResolution]/[rightResolution]
  /// = o menor passo que a variável mostra (1 sem casa decimal, 0,1 com uma):
  /// a régua nunca é mais fina que isso.
  static TrendScale paint(
    Canvas canvas,
    Rect plot, {
    required (double, double) leftData,
    (double, double)? rightData,
    double? fixedMin,
    double? fixedMax,
    required Color leftColor,
    required Color rightColor,
    List<double> leftLimits = const [],
    double? leftResolution,
    double? rightResolution,
  }) {
    final (lo, hi, step) = range(leftData, fixedMin: fixedMin, fixedMax: fixedMax, limits: leftLimits, resolution: leftResolution);

    // Grade discreta: serve de régua, não compete com a curva.
    final grid = Paint()
      ..color = Ind.line.withValues(alpha: 0.7)
      ..strokeWidth = 1;
    // Fundo do gráfico rebaixado, como a face de um instrumento.
    canvas.drawRRect(RRect.fromRectAndRadius(plot.inflate(2), const Radius.circular(6)), Paint()..color = Ind.well.withValues(alpha: Ind.isDark ? 0.55 : 0.45));
    final tp = TextPainter(textDirection: TextDirection.ltr);
    // Linhas nos múltiplos do passo redondo (0 · 50 · 100 · 150), não em
    // quartos da faixa — quartos de 0..150 davam "37,5 · 75 · 113".
    final ticks = ticksOf(lo, hi, step);
    final dual = rightData != null;
    final steps = ((hi - lo) / step).round().clamp(1, 12);
    final (rLo, rHi) = dual ? alignedRange(rightData.$1, rightData.$2, steps, resolution: rightResolution) : (0.0, 1.0);
    final rStep = (rHi - rLo) / steps;
    for (final v in ticks) {
      final frac = (v - lo) / (hi - lo);
      final y = plot.bottom - plot.height * frac;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      tp.text = TextSpan(text: short(v, step: step), style: TextStyle(fontFamily: Ind.mono, fontSize: 10, color: leftColor));
      tp.layout();
      tp.paint(canvas, Offset(plot.left - tp.width - 5, y - tp.height / 2));
      if (dual) {
        tp.text = TextSpan(text: short(rLo + frac * (rHi - rLo), step: rStep), style: TextStyle(fontFamily: Ind.mono, fontSize: 10, color: rightColor));
        tp.layout();
        tp.paint(canvas, Offset(plot.right + 5, y - tp.height / 2));
      }
    }
    return TrendScale._(lo, hi, rLo, rHi);
  }

  /// Faixa e passo do eixo da esquerda: fixa se configurada; senão
  /// automática, arredondada para números "redondos" (0, 25, 50...) — eixo
  /// com 87,2 e -6,46 ninguém lê de relance. Grandeza que nunca foi
  /// negativa não ganha eixo negativo.
  static (double lo, double hi, double step) range((double, double) data,
      {double? fixedMin, double? fixedMax, List<double> limits = const [], double? resolution}) {
    final (dataMin, dataMax) = data;
    var lo = fixedMin ?? dataMin, hi = fixedMax ?? dataMax;
    if (!lo.isFinite || !hi.isFinite) {
      lo = fixedMin ?? 0;
      hi = fixedMax ?? 100;
    }
    if (hi - lo < 1e-9) {
      final (a, b) = flatRange(lo, limits: limits);
      lo = fixedMin ?? a;
      hi = fixedMax ?? b;
      if (hi - lo < 1e-9) hi = lo + 10;
    }
    var step = niceStep((hi - lo) / 4, resolution: resolution);
    if (fixedMin == null || fixedMax == null) {
      if (fixedMin == null) lo = (lo / step).floor() * step;
      if (fixedMax == null) hi = (hi / step).ceil() * step;
      if (fixedMin == null && dataMin >= 0 && lo < 0) lo = 0;
      if (hi - lo < step) hi = lo + step;
      step = niceStep((hi - lo) / 4, resolution: resolution);
    }
    return (lo, hi, step);
  }

  /// Marcas da régua: os múltiplos de [step] entre [lo] e [hi].
  static List<double> ticksOf(double lo, double hi, double step) =>
      [for (var i = (lo / step - 1e-9).ceil(); i * step <= hi + step * 1e-6; i++) i * step];

  /// Curva parada num valor só. Antes era ±1 em volta dele, e o 0 virava a
  /// régua "0 · 0,50 · 1" — casas decimais que a variável nem tem. Agora:
  /// do zero até um número redondo além do valor (0 → 0 a 10), alargada até
  /// os [limits] de alarme da variável quando houver (a curva aparece junto
  /// do limite que importa).
  static (double, double) flatRange(double v, {List<double> limits = const []}) {
    var lo = v < 0 ? v * 1.25 : 0.0;
    var hi = v > 0 ? v * 1.25 : 0.0;
    if (v == 0) hi = 10;
    for (final l in limits) {
      if (!l.isFinite) continue;
      lo = math.min(lo, l);
      hi = math.max(hi, l);
    }
    return (lo, hi);
  }

  /// Eixo da direita com o MESMO número de passos do da esquerda, para as
  /// marcas das duas escalas caírem nas mesmas linhas de grade — e ainda em
  /// números redondos dos dois lados.
  static (double, double) alignedRange(double dataLo, double dataHi, int steps, {double? resolution}) {
    if (!dataLo.isFinite || !dataHi.isFinite) return (0, 100);
    // Decidido ANTES de alargar a faixa: valor constante 0 virava -1..1 e
    // ganhava eixo negativo.
    final nonNegative = dataLo >= 0;
    if (dataHi - dataLo < 1e-9) (dataLo, dataHi) = flatRange(dataLo);
    var step = niceStep((dataHi - dataLo) / steps, resolution: resolution);
    var lo = (dataLo / step).floor() * step;
    if (nonNegative && lo < 0) lo = 0;
    while (lo + steps * step < dataHi - 1e-9) {
      step = niceStep(step * 1.0001, resolution: resolution);
      lo = (dataLo / step).floor() * step;
      if (nonNegative && lo < 0) lo = 0;
    }
    return (lo, lo + steps * step);
  }

  /// Passo "redondo" (1, 2, 2,5 ou 5 × 10ⁿ) mais próximo acima de [raw].
  ///
  /// Sem 2,5 abaixo de 10 (2,5 · 0,25): dariam "2,5 · 7,5" num eixo de
  /// inteiros. Com [resolution] (o menor passo que a variável mostra), o
  /// passo é múltiplo dela — inteiro nunca ganha régua de 0,5.
  static double niceStep(double raw, {double? resolution}) {
    final res = resolution != null && resolution > 0 && resolution.isFinite ? resolution : null;
    if (raw <= 0 || !raw.isFinite) return res ?? 1;
    if (res != null && raw < res) raw = res;
    var exp = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    for (var guard = 0; guard < 4; guard++, exp *= 10) {
      for (final n in const [1.0, 2.0, 2.5, 5.0, 10.0]) {
        final c = n * exp;
        if (c < raw * (1 - 1e-9)) continue;
        if (n == 2.5 && exp < 10) continue;
        if (res != null && ((c / res) - (c / res).roundToDouble()).abs() > 1e-6) continue;
        return c;
      }
    }
    return raw;
  }

  /// Número curto para eixo, com só as casas decimais que o [step] pede
  /// (passo 0,5 → "0,5", não "0,50"; passo inteiro → sem vírgula).
  static String short(double v, {double? step}) {
    if (v.abs() < 1e-9) return '0';
    // Marca redonda sai sem casa decimal.
    if (v == v.roundToDouble()) return v.round().toString();
    final a = v.abs();
    if (a >= 10000) return '${(v / 1000).toStringAsFixed(0)}k';
    if (step != null && step > 0) {
      var dec = 0;
      while (dec < 4 && ((step * math.pow(10, dec)) - (step * math.pow(10, dec)).roundToDouble()).abs() > 1e-6) {
        dec++;
      }
      return v.toStringAsFixed(dec).replaceAll('.', ',');
    }
    if (a >= 100) return v.toStringAsFixed(0);
    if (a >= 10) return v.toStringAsFixed(1).replaceAll('.', ',');
    return v.toStringAsFixed(2).replaceAll(RegExp(r'0+$'), '').replaceAll('.', ',');
  }
}

class _Series {
  _Series({required this.tag, required this.color, required this.samples, required this.reading});
  final Tag tag;
  final Color color;
  final List<TrendSample> samples;
  final TagReading reading;
}

class _TrendPainter extends CustomPainter {
  _TrendPainter({required this.series, required this.now, required this.window, this.fixedMin, this.fixedMax});
  final List<_Series> series;
  final DateTime now;
  final Duration window;
  final double? fixedMin, fixedMax;

  /// Faixa de dados de um grupo de curvas (min, max; infinitos se vazio).
  static (double, double) _dataRange(List<_Series> group) {
    var lo = double.infinity, hi = -double.infinity;
    for (final s in group) {
      for (final p in s.samples) {
        lo = math.min(lo, p.value);
        hi = math.max(hi, p.value);
      }
    }
    return (lo, hi);
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Unidades diferentes (m/min × °C) numa escala só achatavam uma das
    // curvas numa linha reta. A 1ª unidade fica no eixo da esquerda; as
    // demais, no da direita, com os números na cor da curva.
    final leftGroup = [for (final s in series) if (s.tag.unit == series.first.tag.unit) s];
    final rightGroup = [for (final s in series) if (!leftGroup.contains(s)) s];
    final dual = rightGroup.isNotEmpty;

    const left = 38.0, bottom = 16.0;
    final right = dual ? 40.0 : 4.0;
    final plot = Rect.fromLTRB(left, 4, size.width - right, size.height - bottom);
    if (plot.width <= 10 || plot.height <= 10) return;

    final scale = TrendScale.paint(
      canvas,
      plot,
      leftData: _dataRange(leftGroup),
      rightData: dual ? _dataRange(rightGroup) : null,
      fixedMin: fixedMin,
      fixedMax: fixedMax,
      leftColor: dual ? leftGroup.first.color : Ind.textMuted,
      rightColor: dual ? rightGroup.first.color : Ind.textMuted,
      leftLimits: [
        for (final s in leftGroup)
          for (final a in s.tag.alarms)
            if (a.kind.isAnalog) a.limit,
      ],
      leftResolution: _resolution(leftGroup),
      rightResolution: dual ? _resolution(rightGroup) : null,
    );
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (final (label, frac) in [('-${_dur(window)}', 0.0), ('agora', 1.0)]) {
      // Família explícita: texto pintado não herda a letra do tema.
      tp.text = TextSpan(text: label, style: TextStyle(fontFamily: Ind.sans, fontSize: 10, color: Ind.textMuted));
      tp.layout();
      final x = plot.left + plot.width * frac - (frac == 1 ? tp.width : 0);
      tp.paint(canvas, Offset(x, plot.bottom + 3));
    }

    final ms = window.inMilliseconds.toDouble();
    for (final s in series) {
      if (s.samples.length < 2) continue;
      final onRight = rightGroup.contains(s);
      final path = Path();
      var first = true;
      var firstX = 0.0;
      var last = Offset.zero;
      for (final p in s.samples) {
        final x = plot.right - plot.width * (now.difference(p.at).inMilliseconds / ms);
        final y = scale.y(plot, p.value, right: onRight);
        if (first) {
          path.moveTo(x, y);
          firstX = x;
          first = false;
        } else {
          path.lineTo(x, y);
        }
        last = Offset(x, y);
      }
      canvas.save();
      canvas.clipRect(plot);
      // Área em degradê só sob a 1ª curva: dá corpo ao gráfico sem virar
      // mancha quando há três curvas.
      if (identical(s, series.first)) {
        final area = Path.from(path)
          ..lineTo(last.dx, plot.bottom)
          ..lineTo(firstX, plot.bottom)
          ..close();
        canvas.drawPath(
            area,
            Paint()
              ..shader = LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [s.color.withValues(alpha: 0.26), s.color.withValues(alpha: 0)],
              ).createShader(plot));
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = s.color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..strokeJoin = StrokeJoin.round);
      canvas.restore();
      // Ponto no valor atual: diz "é aqui agora" sem precisar ler o eixo.
      canvas.drawCircle(last, 4.5, Paint()..color = Ind.surface);
      canvas.drawCircle(last, 3, Paint()..color = s.color);
    }
  }

  static String _dur(Duration d) => d.inSeconds >= 60 ? '${d.inMinutes} min' : '${d.inSeconds} s';

  /// O menor passo que as variáveis do grupo mostram: 1 sem casa decimal,
  /// 0,1 com uma — a régua não fica mais fina que o próprio valor.
  static double? _resolution(List<_Series> group) {
    if (group.isEmpty) return null;
    final d = group.map((s) => s.tag.decimals).reduce(math.max).clamp(0, 6);
    return 1 / math.pow(10, d);
  }

  @override
  bool shouldRepaint(_TrendPainter old) => true;
}

/// Gráfico de barras: uma barra por posição de uma variável do tipo lista
/// (ex.: 8 registradores seguidos com a produção de cada hora do turno).
///
/// Embaixo de cada barra, a **hora real** (`axis` = `hour`, o padrão): a
/// última posição é a hora de agora e as anteriores voltam de hora em hora
/// ("07h … 14h") — "1 … 8" obrigava a contar para trás. `axis` = `index`
/// numera 1..n, para lista que não é por hora.
class BarChartElement extends StatelessWidget {
  const BarChartElement({super.key, required this.element, this.now});
  final HmiElement element;

  /// Relógio dos rótulos (nulo = agora). Só os testes mudam.
  final DateTime Function()? now;

  /// Rótulos das [n] barras: horas terminando em [last] ("08h"), ou 1..n.
  static List<String> labels(int n, {required bool hours, required DateTime last}) => [
        for (var i = 0; i < n; i++)
          hours ? '${((last.hour - (n - 1 - i)) % 24).toString().padLeft(2, '0')}h' : '${i + 1}',
      ];

  @override
  Widget build(BuildContext context) {
    final e = element;
    final hours = e.prop<String>('axis', 'hour') != 'index';
    return TagBuilder(
      tagId: e.tagId,
      builder: (context, tag, r) {
        final values = [
          for (final v in (r.value is List ? r.value as List : const []))
            if (v is num) v.toDouble(),
        ];
        final names = labels(values.length, hours: hours, last: (now ?? DateTime.now)());
        return HmiFrame(
          label: e.prop<String>('label', tag?.name ?? ''),
          tag: tag,
          reading: r,
          child: values.isEmpty
              ? Center(child: Text('---', style: TextStyle(color: Ind.textMuted)))
              : LayoutBuilder(builder: (context, box) {
                  // Com muitas barras (24 h), um rótulo a cada k, contando da
                  // última (a hora de agora sempre aparece).
                  final slot = box.maxWidth / values.length;
                  final style = TextStyle(fontSize: 10, color: Ind.textMuted, height: 1.2);
                  // Medido com a letra que o Text vai usar (a herdada + esta).
                  final shown = DefaultTextStyle.of(context).style.merge(style);
                  final widest = names.map((t) => TextFit.width(t, shown, scaler: MediaQuery.textScalerOf(context))).fold(0.0, math.max);
                  final every = math.max(1, ((widest + 4) / slot).ceil());
                  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(child: CustomPaint(painter: _BarsPainter(values, tag))),
                    SizedBox(
                      height: 14,
                      child: Row(children: [
                        for (var i = 0; i < values.length; i++)
                          Expanded(
                            child: (values.length - 1 - i) % every == 0
                                ? Text(names[i], key: ValueKey('barra-rotulo-$i'), textAlign: TextAlign.center, maxLines: 1, softWrap: false, overflow: TextOverflow.visible, style: style)
                                : const SizedBox.shrink(),
                          ),
                      ]),
                    ),
                  ]);
                }),
        );
      },
    );
  }
}

class _BarsPainter extends CustomPainter {
  /// Paleta com que foi criado: troca de tema força redesenho.
  final int rev = Ind.revision;

  _BarsPainter(this.values, this.tag);
  final List<double> values;
  final Tag? tag;

  @override
  void paint(Canvas canvas, Size size) {
    // Os rótulos de baixo (hora ou posição) são texto de verdade, logo abaixo
    // desta área; aqui ficam as barras, os valores e a linha de base.
    const labelH = 0.0, valueH = 14.0;
    final maxV = values.fold<double>(0, math.max);
    final n = values.length;
    final slot = size.width / n;
    final barW = slot * 0.64;
    final plotH = size.height - labelH - valueH;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    canvas.drawLine(Offset(0, size.height - labelH - 0.5), Offset(size.width, size.height - labelH - 0.5),
        Paint()..color = Ind.line);

    // Cor de dado (não de estado nem de interação); a última posição — a
    // hora em curso — em cor cheia, as anteriores esmaecidas.
    final c = Ind.series.first;
    for (var i = 0; i < n; i++) {
      final v = values[i];
      final h = maxV <= 0 ? 0.0 : plotH * (v / maxV);
      final x = slot * i + (slot - barW) / 2;
      final last = i == n - 1;
      final rect = Rect.fromLTWH(x, size.height - labelH - h, barW, h);
      canvas.drawRRect(RRect.fromRectAndCorners(rect, topLeft: const Radius.circular(4), topRight: const Radius.circular(4)),
          Paint()..color = last ? c : c.withValues(alpha: 0.42));

      if (slot >= 26) {
        tp.text = TextSpan(
            text: _short(v),
            style: TextStyle(fontFamily: Ind.condensed, fontWeight: last ? FontWeight.w700 : FontWeight.w600, fontSize: 11, color: last ? Ind.text : Ind.textMuted, fontFeatures: const [FontFeature.tabularFigures()]));
        tp.layout(maxWidth: slot);
        tp.paint(canvas, Offset(slot * i + (slot - tp.width) / 2, rect.top - tp.height - 1));
      }
    }
  }

  static String _short(double v) => v >= 10000 ? '${(v / 1000).toStringAsFixed(1).replaceAll('.', ',')}k' : v.round().toString();

  @override
  bool shouldRepaint(_BarsPainter o) => o.values != values || o.rev != rev;
}
