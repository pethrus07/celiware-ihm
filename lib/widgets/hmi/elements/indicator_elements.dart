import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../models/hmi_screen.dart';
import '../../../services/runtime/tag_codec.dart';
import '../../common/common.dart';
import '../hmi_frame.dart';

/// Estilo da lâmpada (`props.style`).
///
/// **Alto desempenho** (padrão, ISA-101): ligado = brilho + palavra, sem
/// cor — cor fica só para o anormal. Por isso vermelho e amarelo continuam
/// coloridos também neste estilo ("Alarme ativo" tem que gritar); verde,
/// azul e cinza viram brilho.
///
/// **Painel clássico** (IEC 60073, sinaleiro físico): a cor escolhida acende
/// sempre — para quem espera o verde do painel da máquina.
enum LampStyle { hp, classic }

extension LampStyleMeta on LampStyle {
  static LampStyle fromName(String? n) => n == 'classic' ? LampStyle.classic : LampStyle.hp;
}

/// Lâmpada: LED num poço rebaixado. Apagada = poço vazio com anel; acesa =
/// núcleo sólido com halo. Sempre com a palavra do estado — cor sozinha
/// falha para daltônico (ISA-18.2 §11.3.3.3).
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
        final chosen = StateColorMeta.fromName(e.prop<String>('color', 'green'));
        final style = LampStyleMeta.fromName(e.props['style'] as String?);
        final abnormal = chosen == StateColor.red || chosen == StateColor.amber;
        // Cor de fato no LED aceso: a escolhida no clássico ou no anormal;
        // senão o "brilho" da paleta.
        final colored = style == LampStyle.classic || abnormal;
        final ledColor = colored ? chosen.color : Ind.lampOn;
        final onText = e.prop<String>('onText', 'LIGADO'), offText = e.prop<String>('offText', 'DESLIGADO');
        final text = on ? onText : offText;
        final textColor = !on ? Ind.textMuted : (colored ? chosen.textColor : Ind.text);
        return HmiFrame(
          label: e.prop<String>('label', tag?.name ?? ''),
          tag: tag,
          reading: r,
          // Rótulo ao lado só se sobrar para LED + a palavra mais longa do
          // estado a 14 pt; senão o rótulo sobe e o estado fica legível.
          minBodyWidth: stateMinWidth([onText, offText], context),
          child: LayoutBuilder(builder: (context, box) {
            // Proporcional à altura: grande num 2×2, discreta numa linha só —
            // e nunca mais alta que o espaço (rótulo em cima deixa ~17 dp).
            final d = math.min(math.min((box.maxHeight * 0.46).clamp(16.0, 40.0), box.maxWidth), box.maxHeight);
            final word = r.value == null ? '---' : text;
            final wordStyle = TextStyle(fontFamily: Ind.condensed, fontWeight: on ? FontWeight.w700 : FontWeight.w600, fontSize: 20, color: textColor, letterSpacing: 0.4, height: 1.0);
            // Sem largura para LED + palavra lado a lado (2×2 no celular):
            // palavra embaixo do LED. Só o LED, sem a palavra, falhava para
            // daltônico — o estado sempre vai escrito.
            final showText = box.maxWidth >= d + 44;
            if (!showText && box.maxHeight >= 44) {
              final led = math.min(d, box.maxHeight - 24);
              return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                _Led(size: led, on: on, color: ledColor, glow: colored || Ind.isDark),
                const SizedBox(height: 6),
                Flexible(child: FitText(word, style: wordStyle)),
              ]);
            }
            return Row(
              children: [
                if (!showText) const Spacer(),
                // Sem animação, como lâmpada de painel: acende e apaga na hora
                // (sinal que pisca a cada 400 ms deixava a tela desenhando).
                _Led(size: d, on: on, color: ledColor, glow: colored || Ind.isDark),
                if (showText) ...[
                  SizedBox(width: d < 20 ? 8 : 12),
                  Expanded(child: FitText(word, alignment: Alignment.centerLeft, style: wordStyle)),
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

/// Largura que o corpo de lâmpada/indicador pede ao [HmiFrame] para o
/// rótulo ficar ao lado: ícone (ou LED) + respiro + o texto de estado mais
/// longo a 14 pt — abaixo disso a palavra do estado fica miúda (era 7 pt num
/// 3×1 de 360 dp) e o arranjo com o rótulo em cima lê melhor.
double stateMinWidth(Iterable<String> texts, BuildContext context, {double icon = 20}) {
  const style = TextStyle(fontFamily: Ind.condensed, fontWeight: FontWeight.w700, fontSize: 14, letterSpacing: 0.4);
  final scaler = MediaQuery.textScalerOf(context);
  var w = 0.0;
  for (final t in texts) {
    w = math.max(w, TextFit.width(t.toUpperCase(), style, scaler: scaler));
  }
  return icon + 12 + w;
}

/// LED de painel. O poço (anel rebaixado) existe aceso ou apagado — é o que
/// faz a lâmpada parecer uma peça, não uma bolinha chapada.
class _Led extends StatelessWidget {
  const _Led({required this.size, required this.on, required this.color, required this.glow});
  final double size;
  final bool on;
  final Color color;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final core = size * 0.64;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Ind.well,
        border: Border.all(color: Ind.isDark ? const Color(0x14FFFFFF) : const Color(0x1A101828)),
      ),
      alignment: Alignment.center,
      child: Container(
        width: core,
        height: core,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          // Aceso: núcleo com um reflexo claro no alto (lente); apagado: some.
          gradient: on
              ? RadialGradient(
                  center: const Alignment(-0.3, -0.4),
                  radius: 0.9,
                  colors: [Color.lerp(color, Colors.white, 0.45)!, color],
                )
              : null,
          color: on ? null : Colors.transparent,
          boxShadow: on && glow ? [BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: core * 0.9, spreadRadius: core * 0.05)] : null,
        ),
      ),
    );
  }
}

/// Mostrador: o valor é o herói — número grande tabular, unidade menor na
/// mesma linha, discreta.
///
/// Liga/desliga aparece como "LIGADO/DESLIGADO"; lista, como o 1º valor.
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
          child: LayoutBuilder(builder: (context, box) {
            // Numa linha fina a unidade encolhe junto, senão ela rouba o espaço do número.
            final tight = box.maxHeight < 32;
            return Row(
            crossAxisAlignment: tight ? CrossAxisAlignment.center : CrossAxisAlignment.end,
            children: [
              Expanded(
                // Texto (nome da máquina, receita) na letra de título mais
                // leve que o número — texto grande em bloco "grita".
                child: FitText(tag == null ? '---' : TagCodec.format(tag, v, withUnit: false),
                    alignment: v is String ? Alignment.centerLeft : Alignment.bottomLeft,
                    style: v is String
                        ? TextStyle(fontFamily: Ind.condensed, fontWeight: FontWeight.w600, fontSize: 30, color: Ind.text, letterSpacing: 0.3)
                        : Ind.number(52)),
              ),
              if (tag != null && tag.unit.isNotEmpty && v is num)
                Padding(
                  padding: EdgeInsets.only(left: tight ? 4 : 6, bottom: tight ? 0 : 3),
                  child: Text(tag.unit, style: TextStyle(color: Ind.textMuted, fontSize: tight ? 11 : 15, fontWeight: FontWeight.w600)),
                ),
            ],
          );
          }),
        );
      },
    );
  }
}

/// Indicador de estado: código numérico → texto, cor **e ícone**
/// (0 = PARADA, 1 = EM CICLO, 2 = ALARME...). O ícone vem da cor escolhida:
/// verde = em marcha, vermelho = alarme, amarelo = atenção, azul = informação,
/// cinza = parado — forma além da cor (ISA-18.2 §11.4.4.2).
///
/// Código sem cadastro aparece como "CÓDIGO n" em amarelo — nunca em branco,
/// para o operador saber que o equipamento mandou algo que a tela não prevê.
class MultistateElement extends StatelessWidget {
  const MultistateElement({super.key, required this.element});
  final HmiElement element;

  static IconData _iconFor(StateColor c) => switch (c) {
        StateColor.green => Icons.play_arrow_rounded,
        StateColor.red => Icons.error_rounded,
        StateColor.amber => Icons.warning_amber_rounded,
        StateColor.blue => Icons.info_outline_rounded,
        StateColor.neutral => Icons.pause_rounded,
      };

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
        final sc = match != null ? StateColorMeta.fromName(match['color'] as String?) : StateColor.amber;
        final color = sc.color;
        final text = code == null ? '---' : (match?['text'] as String? ?? 'CÓDIGO $code');
        final strong = code != null && sc != StateColor.neutral;
        final fg = code == null ? Ind.textMuted : (strong ? sc.textColor : Ind.text);

        return HmiFrame(
          label: e.prop<String>('label', tag?.name ?? ''),
          tag: tag,
          reading: r,
          // Pelos textos cadastrados (não pelo de agora): o arranjo não muda
          // a cada troca de estado.
          minBodyWidth: stateMinWidth([for (final s in states) '${s['text'] ?? ''}'], context, icon: 30),
          // Tinta de ~14% da cor no cartão + borda: o estado ocupa o cartão
          // inteiro, visível de longe; neutro fica neutro.
          color: strong ? Color.alphaBlend(color.withValues(alpha: Ind.isDark ? 0.14 : 0.12), Ind.surface) : null,
          border: strong ? color.withValues(alpha: 0.55) : null,
          child: LayoutBuilder(builder: (context, box) {
            // O círculo nunca passa da altura (com o rótulo em cima sobram
            // ~17 dp); o ícone acompanha.
            var ring = (box.maxHeight * 0.5).clamp(18.0, 30.0) + 12;
            var icon = ring - 12;
            if (ring > box.maxHeight) {
              ring = box.maxHeight;
              icon = ring * 0.66;
            }
            return Row(
              children: [
                Container(
                  width: ring,
                  height: ring,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: code == null ? Ind.well : (strong ? color.withValues(alpha: 0.18) : Ind.well),
                  ),
                  child: Icon(code == null ? Icons.more_horiz_rounded : _iconFor(sc), size: icon, color: fg),
                ),
                SizedBox(width: ring < 24 ? 8 : 12),
                Expanded(
                  child: FitText(text.toUpperCase(),
                      alignment: Alignment.centerLeft,
                      style: TextStyle(fontFamily: Ind.condensed, fontWeight: FontWeight.w700, fontSize: 26, color: fg, letterSpacing: 0.4, height: 1.0)),
                ),
              ],
            );
          }),
        );
      },
    );
  }
}

/// Barra de nível entre [min] e [max]: trilho rebaixado, régua de quartos e
/// um **ponteiro** na ponta do preenchimento (ISA-101: o olho acha presença
/// melhor que ausência — só a barra "some" quando o valor cai).
///
/// Preenchimento **neutro**, como o do medidor: cor só quando o valor entra
/// na faixa de atenção (`warn`, amarelo) ou de alarme (`alarm`, vermelho) —
/// as faixas aparecem como um traço fino sob a régua. A barra nascia azul, a
/// cor de informação, e azul parado na tela parecia um estado.
class BarElement extends StatelessWidget {
  const BarElement({super.key, required this.element});
  final HmiElement element;

  /// Cor do preenchimento para o valor [v]: neutra fora das faixas.
  static Color fillFor(double? v, {double? warn, double? alarm}) {
    final z = zoneFor(v, warn: warn, alarm: alarm);
    return z ?? Ind.text.withValues(alpha: Ind.isDark ? 0.82 : 0.75);
  }

  /// Faixa em que o valor está (nulo = normal) — a mesma regra do medidor.
  static Color? zoneFor(double? v, {double? warn, double? alarm}) => v == null
      ? null
      : (alarm != null && v >= alarm)
          ? Ind.alarm
          : (warn != null && v >= warn)
              ? Ind.warn
              : null;

  @override
  Widget build(BuildContext context) {
    final e = element;
    final min = e.prop<num>('min', 0).toDouble();
    final max = e.prop<num>('max', 100).toDouble();
    final warn = (e.props['warn'] as num?)?.toDouble();
    final alarm = (e.props['alarm'] as num?)?.toDouble();
    double frac(double x) => max <= min ? 0.0 : ((x - min) / (max - min)).clamp(0.0, 1.0);
    return TagBuilder(
      tagId: e.tagId,
      builder: (context, tag, r) {
        final v = r.value is num ? (r.value as num).toDouble() : null;
        final f = v == null ? 0.0 : frac(v);
        final zone = zoneFor(v, warn: warn, alarm: alarm);
        final color = fillFor(v, warn: warn, alarm: alarm);
        return HmiFrame(
          label: e.prop<String>('label', tag?.name ?? ''),
          tag: tag,
          reading: r,
          child: Row(
            children: [
              Expanded(
                child: LayoutBuilder(builder: (context, box) {
                  final h = (box.maxHeight * 0.34).clamp(8.0, 16.0);
                  return Center(
                    child: SizedBox(
                      height: h + 8,
                      child: Stack(clipBehavior: Clip.none, children: [
                        Positioned(
                          left: 0,
                          right: 0,
                          top: 0,
                          height: h,
                          child: Container(
                            decoration: Ind.wellBox(radius: h / 2),
                            child: Align(alignment: Alignment.centerLeft, child: _BarFill(key: const ValueKey('barra-preenchimento'), frac: f, color: color, radius: h / 2)),
                          ),
                        ),
                        // Régua: marcas em 0, 25, 50, 75 e 100%, e as faixas.
                        Positioned.fill(
                          top: h + 3,
                          child: CustomPaint(painter: _TicksPainter(warn: warn == null ? null : frac(warn), alarm: alarm == null ? null : frac(alarm))),
                        ),
                      ]),
                    ),
                  );
                }),
              ),
              const SizedBox(width: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 56),
                child: FitText(tag == null ? '---' : TagCodec.format(tag, v),
                    alignment: Alignment.centerRight, style: Ind.number(22, color: zone == null ? Ind.text : Ind.textFor(zone))),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TicksPainter extends CustomPainter {
  _TicksPainter({this.warn, this.alarm});

  /// Início das faixas, em fração da escala (nulo = sem faixa).
  final double? warn, alarm;
  final int rev = Ind.revision;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Ind.textMuted.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final x = (size.width - 1) * i / 4 + 0.5;
      canvas.drawLine(Offset(x, 0), Offset(x, i.isEven ? 4 : 2.5), p);
    }
    // Faixas como no medidor: traço fino de onde começam até o fim da escala.
    final band = Paint()..strokeWidth = 2;
    final w = size.width;
    if (warn != null) {
      canvas.drawLine(Offset(w * warn!, 5.5), Offset(w * (alarm ?? 1), 5.5), band..color = Ind.warn);
    }
    if (alarm != null) {
      canvas.drawLine(Offset(w * alarm!, 5.5), Offset(w, 5.5), band..color = Ind.alarm);
    }
  }

  @override
  bool shouldRepaint(_TicksPainter o) => o.rev != rev || o.warn != warn || o.alarm != alarm;
}

/// Preenchimento da barra com ponteiro na ponta. Anima só quando o valor
/// **anda** (mais de 3% da faixa): a animação a cada leitura deixava a tela
/// desenhando sem parar — bateria indo embora pela oscilação de ±1%.
class _BarFill extends StatefulWidget {
  const _BarFill({super.key, required this.frac, required this.color, required this.radius});
  final double frac;
  final Color color;
  final double radius;

  @override
  State<_BarFill> createState() => _BarFillState();
}

class _BarFillState extends State<_BarFill> {
  Duration _duration = Duration.zero;

  @override
  void didUpdateWidget(_BarFill old) {
    super.didUpdateWidget(old);
    _duration = (widget.frac - old.frac).abs() > 0.03 ? const Duration(milliseconds: 250) : Duration.zero;
  }

  @override
  Widget build(BuildContext context) => AnimatedFractionallySizedBox(
        duration: _duration,
        curve: Curves.easeOutCubic,
        widthFactor: widget.frac,
        heightFactor: 1,
        alignment: Alignment.centerLeft,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: LinearGradient(colors: [widget.color.withValues(alpha: 0.75), widget.color]),
          ),
          alignment: Alignment.centerRight,
          // Ponteiro: traço na cor do cartão na ponta, visível mesmo com barra
          // curta — e no escuro, onde o preenchimento neutro é claro.
          child: widget.frac <= 0
              ? null
              : Container(width: 3, margin: const EdgeInsets.symmetric(vertical: 1.5, horizontal: 2), decoration: BoxDecoration(color: Ind.surface.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(2))),
        ),
      );
}

/// Medidor de ponteiro (arco de 240°): arco rebaixado, régua de marcas,
/// faixas de atenção/alarme **por fora** do arco (como o "thresholds" do
/// Grafana) e preenchimento **neutro** que só ganha cor quando o valor entra
/// numa faixa — cor só para o anormal (ISA-101).
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
            ? null
            : (alarm != null && v >= alarm)
                ? Ind.alarm
                : (warn != null && v >= warn)
                    ? Ind.warn
                    : null;
        return HmiFrame(
          label: e.prop<String>('label', tag?.name ?? ''),
          tag: tag,
          reading: r,
          child: LayoutBuilder(
            builder: (context, box) => Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(painter: _GaugePainter(min: min, max: max, value: v, warn: warn, alarm: alarm, zone: zone)),
                ),
                // Valor no miolo do anel, numa caixa medida pelo próprio anel
                // (e não pela largura do elemento): cabe inteira dentro das
                // marcas da régua — "31,7 °C" encostava nelas no celular.
                Positioned.fromRect(
                  key: const ValueKey('valor-medidor'),
                  rect: _GaugePainter.valueBox(box.biggest),
                  child: FitText(tag == null ? '---' : TagCodec.format(tag, v),
                      style: Ind.number(28, color: zone == null ? Ind.text : Ind.textFor(zone))),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _GaugePainter extends CustomPainter {
  /// Paleta com que foi criado: troca de tema força redesenho.
  final int rev = Ind.revision;

  _GaugePainter({required this.min, required this.max, required this.value, this.warn, this.alarm, this.zone});
  final double min, max;
  final double? value, warn, alarm;
  final Color? zone;

  static const _start = math.pi * 5 / 6; // 150°
  static const _sweep = math.pi * 4 / 3; // 240°

  double _frac(double v) => max <= min ? 0 : ((v - min) / (max - min)).clamp(0.0, 1.0);

  /// Centro, raio e espessura do arco num quadro deste tamanho — o mesmo
  /// cálculo para pintar e para posicionar o valor.
  static (Offset, double, double) _geometry(Size size) {
    final side = math.min(size.width, size.height * 1.15);
    final stroke = (side * 0.085).clamp(5.0, 13.0);
    return (Offset(size.width / 2, size.height * 0.56), side / 2 - stroke * 1.6, stroke);
  }

  /// Caixa do valor: logo abaixo do centro e inteira dentro do círculo livre
  /// que as marcas da régua deixam (com 2 dp de folga).
  static Rect valueBox(Size size) {
    final (c, radius, stroke) = _geometry(size);
    final free = math.max(0.0, radius - stroke * 1.2 - 3 - 2);
    final halfH = free * 0.28;
    final top = c.dy + free * 0.12 - halfH;
    // Canto de baixo da caixa no limite do círculo livre.
    final dy = top + 2 * halfH - c.dy;
    final halfW = math.sqrt(math.max(0.0, free * free - dy * dy));
    return Rect.fromLTRB(c.dx - halfW, top, c.dx + halfW, top + 2 * halfH);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final (c, radius, stroke) = _geometry(size);
    final rect = Rect.fromCircle(center: c, radius: radius);
    Paint arc(Color color, double w, {StrokeCap cap = StrokeCap.round}) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = cap;

    // Arco rebaixado.
    canvas.drawArc(rect, _start, _sweep, false, arc(Ind.well, stroke));

    // Faixas por fora do arco: fina, para não disputar com o valor.
    final band = Rect.fromCircle(center: c, radius: radius + stroke * 0.95);
    final bw = (stroke * 0.32).clamp(2.0, 4.0);
    if (warn != null) {
      final from = _frac(warn!), to = alarm != null ? _frac(alarm!) : 1.0;
      canvas.drawArc(band, _start + _sweep * from, _sweep * (to - from), false, arc(Ind.warn, bw, cap: StrokeCap.butt));
    }
    if (alarm != null) {
      final from = _frac(alarm!);
      canvas.drawArc(band, _start + _sweep * from, _sweep * (1 - from), false, arc(Ind.alarm, bw, cap: StrokeCap.butt));
    }

    // Régua: 10 divisões, as de 25% mais longas — dentro do arco.
    final tick = Paint()..color = Ind.textMuted.withValues(alpha: 0.7);
    for (var i = 0; i <= 20; i++) {
      final major = i % 5 == 0;
      if (!major && i.isOdd) continue;
      final a = _start + _sweep * i / 20;
      final dir = Offset(math.cos(a), math.sin(a));
      final r0 = radius - stroke * 0.5 - 3;
      final r1 = r0 - (major ? stroke * 0.7 : stroke * 0.35);
      tick.strokeWidth = major ? 1.6 : 1;
      canvas.drawLine(c + dir * r0, c + dir * r1, tick);
    }

    if (value != null) {
      final f = _frac(value!);
      final fill = zone ?? Ind.text.withValues(alpha: Ind.isDark ? 0.82 : 0.75);
      if (f > 0.001) canvas.drawArc(rect, _start, _sweep * f, false, arc(fill, stroke));
      // Ponteiro: agulha curta atravessando o arco, com a ponta na cor.
      final a = _start + _sweep * f;
      final dir = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + dir * (radius - stroke * 1.3), c + dir * (radius + stroke * 0.95),
          Paint()
            ..color = zone ?? Ind.text
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round);
    }
  }

  @override
  bool shouldRepaint(_GaugePainter o) =>
      o.rev != rev || o.value != value || o.min != min || o.max != max || o.warn != warn || o.alarm != alarm || o.zone != zone;
}
