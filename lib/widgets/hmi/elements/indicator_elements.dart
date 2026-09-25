import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../models/hmi_screen.dart';
import '../../../services/runtime/tag_codec.dart';
import '../hmi_frame.dart';

/// Lâmpada: círculo que acende (com brilho) quando o sinal está ligado.
class LampElement extends StatelessWidget {
  const LampElement({super.key, required this.element});
  final HmiElement element;

  @override
  Widget build(BuildContext context) {
    final e = element;
    return TagBuilder(
      tagId: e.tagId,
      builder: (context, tag, r) {
        final on = r.value == true;
        final color = StateColorMeta.fromName(e.prop<String>('color', 'green')).color;
        final text = on ? e.prop<String>('onText', 'LIGADO') : e.prop<String>('offText', 'DESLIGADO');
        return HmiFrame(
          label: e.prop<String>('label', tag?.name ?? ''),
          tag: tag,
          reading: r,
          child: LayoutBuilder(builder: (context, box) {
            // Proporcional à altura: grande num 2×2, discreta numa linha só.
            final d = math.min((box.maxHeight * 0.42).clamp(14.0, 40.0), box.maxWidth);
            // Sem largura para bolinha + texto (lâmpada estreita com rótulo ao
            // lado): só a bolinha — acesa/apagada já comunica o estado.
            final showText = box.maxWidth >= d + 44;
            return Row(
              children: [
                if (!showText) const Spacer(),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: d,
                  height: d,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: on ? color : Ind.off,
                    border: Border.all(color: on ? color : Ind.lineStrong, width: 2),
                    boxShadow: on ? [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: d * 0.6, spreadRadius: 1)] : null,
                  ),
                ),
                if (showText) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: FitText(r.value == null ? '---' : text,
                        alignment: Alignment.centerLeft,
                        style: TextStyle(
                          fontFamily: Ind.condensed,
                          fontWeight: FontWeight.w700,
                          fontSize: 20,
                          color: on ? color : Ind.textDim,
                        )),
                  ),
                ] else
                  const Spacer(),
              ],
            );
          }),
        );
      },
    );
  }
}

/// Mostrador: o valor em número grande, unidade ao lado.
///
/// Liga/desliga aparece como "LIGADO/DESLIGADO"; lista, como o 1º valor e a
/// contagem (para lista inteira, use o gráfico de barras).
class ValueElement extends StatelessWidget {
  const ValueElement({super.key, required this.element});
  final HmiElement element;

  @override
  Widget build(BuildContext context) {
    final e = element;
    return TagBuilder(
      tagId: e.tagId,
      builder: (context, tag, r) {
        final v = r.value is List ? (r.value as List).firstOrNull : r.value;
        return HmiFrame(
          label: e.prop<String>('label', tag?.name ?? ''),
          tag: tag,
          reading: r,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: FitText(tag == null ? '---' : TagCodec.format(tag, v, withUnit: false),
                    alignment: Alignment.bottomLeft, style: Ind.number(44)),
              ),
              if (tag != null && tag.unit.isNotEmpty && v is num)
                Padding(
                  padding: const EdgeInsets.only(left: 6, bottom: 2),
                  child: Text(tag.unit, style: const TextStyle(color: Ind.textDim, fontSize: 15, fontWeight: FontWeight.w600)),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Indicador de estado: código numérico → texto e cor
/// (0 = PARADA cinza, 1 = EM CICLO verde, 2 = ALARME vermelho...).
///
/// Código sem cadastro aparece como "CÓDIGO n" em âmbar — nunca em branco,
/// para o operador saber que o equipamento mandou algo que a tela não prevê.
class MultistateElement extends StatelessWidget {
  const MultistateElement({super.key, required this.element});
  final HmiElement element;

  @override
  Widget build(BuildContext context) {
    final e = element;
    final states = [
      for (final s in (e.props['states'] as List? ?? const []))
        if (s is Map) s,
    ];
    return TagBuilder(
      tagId: e.tagId,
      builder: (context, tag, r) {
        final raw = r.value;
        final code = raw is bool ? (raw ? 1 : 0) : (raw is num ? raw.round() : null);
        final match = states.where((s) => s['value'] == code).firstOrNull;
        final color = match != null ? StateColorMeta.fromName(match['color'] as String?).color : Ind.warn;
        final text = code == null ? '---' : (match?['text'] as String? ?? 'CÓDIGO $code');
        final strong = match != null && match['color'] != 'neutral';

        return HmiFrame(
          label: e.prop<String>('label', tag?.name ?? ''),
          tag: tag,
          reading: r,
          color: strong ? color.withValues(alpha: 0.16) : Ind.surface,
          border: strong ? color.withValues(alpha: 0.7) : null,
          child: Row(
            children: [
              Container(width: 6, decoration: BoxDecoration(color: code == null ? Ind.off : color, borderRadius: BorderRadius.circular(3))),
              const SizedBox(width: 10),
              Expanded(
                child: FitText(text.toUpperCase(),
                    alignment: Alignment.centerLeft,
                    style: TextStyle(fontFamily: Ind.condensed, fontWeight: FontWeight.w700, fontSize: 24, color: code == null ? Ind.textDim : color == Ind.textDim ? Ind.text : color)),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Barra de nível entre [min] e [max], com o valor escrito.
class BarElement extends StatelessWidget {
  const BarElement({super.key, required this.element});
  final HmiElement element;

  @override
  Widget build(BuildContext context) {
    final e = element;
    final min = e.prop<num>('min', 0).toDouble();
    final max = e.prop<num>('max', 100).toDouble();
    final color = StateColorMeta.fromName(e.prop<String>('color', 'blue'), StateColor.blue).color;
    return TagBuilder(
      tagId: e.tagId,
      builder: (context, tag, r) {
        final v = r.value is num ? (r.value as num).toDouble() : null;
        final frac = v == null || max <= min ? 0.0 : ((v - min) / (max - min)).clamp(0.0, 1.0);
        return HmiFrame(
          label: e.prop<String>('label', tag?.name ?? ''),
          tag: tag,
          reading: r,
          child: Row(
            children: [
              Expanded(
                child: LayoutBuilder(builder: (context, box) {
                  final h = box.maxHeight.clamp(8.0, 28.0);
                  return Center(
                    child: Container(
                      height: h,
                      decoration: BoxDecoration(color: Ind.bg, borderRadius: BorderRadius.circular(h / 2), border: Border.all(color: Ind.line)),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: AnimatedFractionallySizedBox(
                          duration: const Duration(milliseconds: 250),
                          widthFactor: frac,
                          heightFactor: 1,
                          child: Container(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(h / 2))),
                        ),
                      ),
                    ),
                  );
                }),
              ),
              const SizedBox(width: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 56),
                child: FitText(tag == null ? '---' : TagCodec.format(tag, v), alignment: Alignment.centerRight, style: Ind.number(18)),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Medidor de ponteiro (arco de 240°) com faixas de atenção e alarme.
class GaugeElement extends StatelessWidget {
  const GaugeElement({super.key, required this.element});
  final HmiElement element;

  @override
  Widget build(BuildContext context) {
    final e = element;
    final min = e.prop<num>('min', 0).toDouble();
    final max = e.prop<num>('max', 100).toDouble();
    final warn = (e.props['warn'] as num?)?.toDouble();
    final alarm = (e.props['alarm'] as num?)?.toDouble();
    return TagBuilder(
      tagId: e.tagId,
      builder: (context, tag, r) {
        final v = r.value is num ? (r.value as num).toDouble() : null;
        final zone = v == null
            ? Ind.textDim
            : (alarm != null && v >= alarm)
                ? Ind.alarm
                : (warn != null && v >= warn)
                    ? Ind.warn
                    : Ind.text;
        return HmiFrame(
          label: e.prop<String>('label', tag?.name ?? ''),
          tag: tag,
          reading: r,
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(painter: _GaugePainter(min: min, max: max, value: v, warn: warn, alarm: alarm)),
              ),
              // Valor no miolo do anel (não em cima do fim do arco).
              Align(
                alignment: const Alignment(0, 0.28),
                child: FractionallySizedBox(
                  widthFactor: 0.5,
                  child: FitText(tag == null ? '---' : TagCodec.format(tag, v), style: Ind.number(26, color: zone)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({required this.min, required this.max, required this.value, this.warn, this.alarm});
  final double min, max;
  final double? value, warn, alarm;

  static const _start = math.pi * 5 / 6; // 150°
  static const _sweep = math.pi * 4 / 3; // 240°

  double _frac(double v) => max <= min ? 0 : ((v - min) / (max - min)).clamp(0.0, 1.0);

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height * 1.15);
    final stroke = (side * 0.09).clamp(5.0, 14.0);
    final radius = side / 2 - stroke;
    final c = Offset(size.width / 2, size.height * 0.56);
    final rect = Rect.fromCircle(center: c, radius: radius);
    Paint arc(Color color) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;

    canvas.drawArc(rect, _start, _sweep, false, arc(Ind.surfaceHigher));
    if (warn != null) {
      final from = _frac(warn!), to = alarm != null ? _frac(alarm!) : 1.0;
      canvas.drawArc(rect, _start + _sweep * from, _sweep * (to - from), false, arc(Ind.warn.withValues(alpha: 0.55)));
    }
    if (alarm != null) {
      final from = _frac(alarm!);
      canvas.drawArc(rect, _start + _sweep * from, _sweep * (1 - from), false, arc(Ind.alarm.withValues(alpha: 0.6)));
    }
    if (value != null) {
      final f = _frac(value!);
      canvas.drawArc(rect, _start, _sweep * f, false, arc(Ind.info.withValues(alpha: 0.85)));
      final a = _start + _sweep * f;
      final tip = c + Offset(math.cos(a), math.sin(a)) * (radius + stroke * 0.2);
      canvas.drawLine(c + Offset(math.cos(a), math.sin(a)) * (radius * 0.55), tip,
          Paint()
            ..color = Ind.text
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round);
    }
  }

  @override
  bool shouldRepaint(_GaugePainter o) =>
      o.value != value || o.min != min || o.max != max || o.warn != warn || o.alarm != alarm;
}
