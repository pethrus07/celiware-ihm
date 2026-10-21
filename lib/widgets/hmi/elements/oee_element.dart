import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/app_scope.dart';
import '../../../core/theme/app_theme.dart';
import '../../../models/hmi_screen.dart';
import '../../../models/tag.dart';
import '../../../services/alarms/alarm_engine.dart';
import '../../../services/runtime/tag_store.dart';
import '../../alarms/alarm_widgets.dart';
import '../hmi_frame.dart';

/// De onde vem o número do OEE (`props.source`).
enum OeeSource {
  /// Calculado no app: disponibilidade × desempenho × qualidade.
  calc,

  /// Pronto do equipamento, numa quarta variável (vaga [Oee.oeeSlot]) — para
  /// o CLP que já calcula com as regras dele (paradas planejadas, turno).
  tag,
}

/// Escala em que o equipamento manda **as quatro** variáveis (`props.scale`).
///
/// Escolha explícita na configuração, e não detecção: a variável do app não
/// declara faixa (só unidade, escala e casas), e adivinhar pelo valor lido
/// erra justo onde importa — um "1" pode ser 1 % (máquina quase parada) ou
/// 100 %. Valor que não cabe na escala escolhida aparece marcado "fora de 0 a
/// 100 %", o que denuncia a escala trocada já na prévia da configuração.
enum OeeScale {
  /// 0 a 100 (85 = 85 %). Padrão: registrador de CLP é inteiro, e de 0 a 1 em
  /// inteiro só existem dois valores.
  percent,

  /// 0 a 1 (0,85 = 85 %): número com vírgula, comum em OPC UA e MQTT.
  fraction,
}

/// Situação de uma parcela (ou do próprio OEE) — decide como ela se desenha.
enum OeeState {
  /// Vaga sem variável (ou com variável apagada): "Escolha".
  missing,

  /// Esperando a primeira leitura: "---", nunca zero.
  waiting,

  /// Leitura boa.
  good,

  /// Sem comunicação: o último valor, esmaecido (ou "---" se nunca leu).
  stale,

  /// Endereço recusado, erro de configuração ou valor que não é número.
  error,
}

/// Faixa do OEE pelas faixas do elemento: "abaixo de" atenção ou alarme.
enum OeeZone { normal, warn, alarm }

/// Uma parcela já convertida para fração (0,85 = 85 %).
@immutable
class OeePart {
  const OeePart(this.state, {this.fraction, this.message = '', this.blocked = false});

  final OeeState state;

  /// O valor como fração, **sem cortar**: 1,2 continua 1,2 (e aparece marcado
  /// como fora da faixa). Nulo quando não há número para mostrar.
  final double? fraction;

  /// Motivo, quando [state] é erro (texto do runtime, para o operador).
  final String message;

  /// OEE que o app se recusa a calcular porque uma parcela saiu de 0–100 %:
  /// o produto daria um número com cara de verdadeiro e sem sentido.
  final bool blocked;

  /// Fora de 0–100 % (com folga de arredondamento): escala trocada na
  /// configuração, ou tempo de ciclo ideal mal ajustado no CLP (desempenho de
  /// 103 %).
  bool get outOfRange {
    final f = fraction;
    return blocked || (f != null && (f < -Oee.tolerance || f > 1 + Oee.tolerance));
  }

  @override
  bool operator ==(Object other) =>
      other is OeePart && other.state == state && other.fraction == fraction && other.message == message && other.blocked == blocked;

  @override
  int get hashCode => Object.hash(state, fraction, message, blocked);

  @override
  String toString() => 'OeePart(${state.name}, $fraction${blocked ? ', bloqueado' : ''})';
}

/// Regras do OEE — puras, sem tela, para o teste conferir a conta.
///
/// **Onde moram as variáveis**: `props.tagIds` com posição fixa —
/// `[disponibilidade, desempenho, qualidade, oee pronto]`, vaga vazia = nulo.
/// Usar a mesma chave das outras listas faz o resto do app enxergar o OEE de
/// graça: a tela inscreve as variáveis ([HmiScreen.liveTagIds]), "usada em"
/// acha o elemento e pede variável numérica, o selo do equipamento conta. E
/// uma versão antiga do app, que não conhece o tipo, preserva tudo.
abstract final class Oee {
  static const availabilitySlot = 0;
  static const performanceSlot = 1;
  static const qualitySlot = 2;
  static const oeeSlot = 3;

  /// Nome de cada vaga, na ordem de `tagIds`.
  static const titles = ['Disponibilidade', 'Desempenho', 'Qualidade', 'OEE'];

  /// Aviso da parcela cuja variável está com o endereço a configurar.
  static const pendingText = 'A configurar';

  /// Abreviação para quando o nome inteiro não cabe na linha.
  static const shortTitles = ['Disp.', 'Desemp.', 'Qual.', 'OEE'];

  /// Folga de 0,01 % nas pontas: float32 de 100 vira 100,0000001 numa conta
  /// do CLP, e isso não é "fora da faixa".
  static const double tolerance = 1e-4;

  /// As quatro vagas, sempre com 4 posições (arquivo com lista menor ou sem
  /// lista → vagas vazias).
  static List<String?> slots(HmiElement e) {
    final raw = e.props['tagIds'];
    return [
      for (var i = 0; i < 4; i++)
        if (raw is List && i < raw.length && raw[i] is String) raw[i] as String else null,
    ];
  }

  /// [slots] com a vaga [i] trocada — lista nova, sempre com 4 posições.
  static List<String?> withSlot(List<String?> slots, int i, String? id) => [
        for (var j = 0; j < 4; j++) j == i ? id : (j < slots.length ? slots[j] : null),
      ];

  static OeeSource sourceOf(HmiElement e) => e.props['source'] == OeeSource.tag.name ? OeeSource.tag : OeeSource.calc;

  static OeeScale scaleOf(HmiElement e) => e.props['scale'] == OeeScale.fraction.name ? OeeScale.fraction : OeeScale.percent;

  /// As vagas que o elemento lê: no calculado, a do OEE pronto fica de fora.
  static List<String?> liveSlots(HmiElement e) {
    final s = slots(e);
    if (sourceOf(e) == OeeSource.calc) s[oeeSlot] = null;
    return s;
  }

  /// Uma leitura → parcela em fração. Nunca inventa número: sem leitura é
  /// "esperando"; sem comunicação guarda o último valor como "parado".
  static OeePart part(Tag? tag, TagReading r, OeeScale scale) {
    if (tag == null) return const OeePart(OeeState.missing);
    // Endereço a configurar (variável de modelo de tela ou de projeto
    // pronto): falta configurar, na cor de interação como nos outros
    // elementos — não o erro vermelho, que nem caberia na linha do celular.
    if (tag.addressPending) return const OeePart(OeeState.missing, message: pendingText);
    if (r.quality == TagQuality.addressError || r.quality == TagQuality.configError) {
      return OeePart(OeeState.error, message: r.message);
    }
    final stale = r.quality == TagQuality.commLost;
    final raw = r.value is List ? (r.value as List).firstOrNull : r.value;
    if (raw == null) return OeePart(stale ? OeeState.stale : OeeState.waiting);
    if (raw is! num) return const OeePart(OeeState.error, message: 'Não é número');
    final v = raw.toDouble();
    if (!v.isFinite) return const OeePart(OeeState.error, message: 'Valor inválido');
    return OeePart(stale ? OeeState.stale : OeeState.good, fraction: scale == OeeScale.percent ? v / 100 : v);
  }

  /// OEE = disponibilidade × desempenho × qualidade.
  ///
  /// Falta variável → falta; erro em qualquer uma → erro; alguma sem número
  /// → sem número ("---", nunca zero); alguma fora de 0–100 % → bloqueado
  /// (não calcula). Uma parada (sem comunicação) deixa o resultado parado
  /// também — ele foi feito com um valor velho.
  static OeePart product(List<OeePart> parts) {
    if (parts.any((p) => p.state == OeeState.missing)) return const OeePart(OeeState.missing);
    final broken = parts.where((p) => p.state == OeeState.error).firstOrNull;
    if (broken != null) return OeePart(OeeState.error, message: broken.message);
    final stale = parts.any((p) => p.state == OeeState.stale);
    if (parts.any((p) => p.fraction == null)) return OeePart(stale ? OeeState.stale : OeeState.waiting);
    final state = stale ? OeeState.stale : OeeState.good;
    if (parts.any((p) => p.outOfRange)) return OeePart(state, blocked: true);
    // Dentro da folga, 100,00001 % conta como 100 %.
    return OeePart(state, fraction: parts.fold<double>(1, (m, p) => m * p.fraction!.clamp(0.0, 1.0)));
  }

  /// O OEE que a tela mostra: o calculado ou o pronto, conforme [source].
  static OeePart compute(OeeSource source, List<OeePart> parts, OeePart ready) =>
      source == OeeSource.tag ? ready : product(parts);

  /// "74,9" — sempre em %, uma casa, vírgula.
  static String format(double fraction) {
    final t = (fraction * 100).toStringAsFixed(1);
    return (t == '-0.0' ? '0.0' : t).replaceAll('.', ',');
  }

  /// Faixa do OEE. Os limites são em % e valem **abaixo de** (OEE baixo é o
  /// problema). Compara o número que a tela mostra, com uma casa: 59,96
  /// aparece "60,0" e não pode estar "abaixo de 60".
  static OeeZone zone(OeePart oee, {num? warn, num? alarm}) {
    final f = oee.fraction;
    if (f == null || oee.outOfRange) return OeeZone.normal;
    final shown = double.parse((f * 100).toStringAsFixed(1));
    if (alarm != null && shown < alarm) return OeeZone.alarm;
    if (warn != null && shown < warn) return OeeZone.warn;
    return OeeZone.normal;
  }
}

/// OEE (item 8 da lista do cliente): o OEE em destaque à esquerda e as três
/// parcelas — disponibilidade, desempenho e qualidade — empilhadas à direita.
///
/// Mesma linguagem dos outros elementos: número tabular grande, placa em caixa
/// alta, cor só para estado (ISA-101). O OEE fica amarelo ou vermelho abaixo
/// das faixas, com ícone além da cor; a barrinha embaixo mostra onde ele está
/// entre 0 e 100 % e onde começam as faixas.
///
/// Qualidade da leitura por parcela, como na tabela: "---" esperando,
/// esmaecido com ícone sem comunicação, motivo em vermelho no erro, "Escolha"
/// na vaga vazia. O OEE calculado herda: parcela parada → OEE esmaecido;
/// parcela sem número → "---". Nunca um zero falso.
///
/// Estreito (menos de [wideMin] dp de miolo) o OEE vai para cima e as
/// parcelas viram linhas embaixo. Menor que o mínimo de cada arranjo, o
/// conjunto inteiro encolhe junto em vez de cortar texto.
class OeeElement extends StatelessWidget {
  const OeeElement({super.key, required this.element});
  final HmiElement element;

  /// Miolo a partir do qual OEE e parcelas ficam lado a lado.
  static const wideMin = 220.0;

  @override
  Widget build(BuildContext context) {
    final ids = Oee.liveSlots(element);
    // Uma leitura por vaga, aninhadas: qualquer uma que mude refaz o elemento
    // (o OEE depende das três).
    Widget nest(int i, List<(Tag?, TagReading)> got) => i == ids.length
        ? _OeeView(element: element, readings: got)
        : TagBuilder(tagId: ids[i], builder: (context, tag, r) => nest(i + 1, [...got, (tag, r)]));
    return nest(0, const []);
  }
}

class _OeeView extends StatelessWidget {
  const _OeeView({required this.element, required this.readings});
  final HmiElement element;
  final List<(Tag?, TagReading)> readings;

  @override
  Widget build(BuildContext context) {
    final tags = [for (final (t, _) in readings) t];
    if (!tags.any((t) => t != null && t.alarms.isNotEmpty)) return _build(context, const [null, null, null, null]);
    // Variável com alarme: o elemento ouve o motor e marca a linha dela — o
    // alarme aparece onde o valor está, como nos cartões e na tabela.
    final engine = AppScope.of(context).alarms;
    return ListenableBuilder(
      listenable: engine,
      builder: (context, _) => _build(context, [for (final t in tags) t == null ? null : engine.forTag(t.id)]),
    );
  }

  Widget _build(BuildContext context, List<AlarmEntry?> alarms) {
    final e = element;
    final source = Oee.sourceOf(e);
    final scale = Oee.scaleOf(e);
    final parts = [for (var i = 0; i < 3; i++) Oee.part(readings[i].$1, readings[i].$2, scale)];
    final ready = source == OeeSource.tag ? Oee.part(readings[Oee.oeeSlot].$1, readings[Oee.oeeSlot].$2, scale) : const OeePart(OeeState.missing);
    final oee = Oee.compute(source, parts, ready);
    final warn = e.props['warn'] as num?;
    final alarm = e.props['alarm'] as num?;
    final zone = Oee.zone(oee, warn: warn, alarm: alarm);

    // Borda só quando comunica algo (como no HmiFrame): falta configurar,
    // erro de leitura, ou alarme ativo de alguma das variáveis.
    final shown = [...parts, if (source == OeeSource.tag) ready];
    final missing = shown.any((p) => p.state == OeeState.missing);
    final broken = shown.any((p) => p.state == OeeState.error);
    AlarmEntry? worst;
    for (final a in alarms) {
      if (a != null && a.phase.active && (worst == null || a.priority.index < worst.priority.index)) worst = a;
    }
    final border = missing ? Ind.accent : (broken ? Ind.alarm : worst?.priority.color);
    final bw = missing || broken ? 1.6 : 2.0;

    final label = e.prop<String>('label', '').trim();
    final hero = _Hero(
      label: label.isEmpty ? 'OEE' : label,
      oee: oee,
      // No calculado, falta e erro já aparecem na linha da parcela: o OEE só
      // mostra que não tem número.
      prompt: source == OeeSource.tag,
      zone: zone,
      warn: warn,
      alarm: alarm,
      alarmEntry: source == OeeSource.tag ? alarms[Oee.oeeSlot] : null,
    );

    return CustomPaint(
      foregroundPainter: CardEdge(rev: Ind.revision),
      child: Container(
        decoration: Ind.card(border: border, width: border == null ? 1 : bw),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: LayoutBuilder(builder: (context, box) {
          final wide = box.maxWidth >= OeeElement.wideMin;
          // Abaixo do mínimo do arranjo, desenha no mínimo e encolhe tudo
          // junto: número menor, mas nada cortado nem transbordando.
          final minW = wide ? OeeElement.wideMin : 116.0;
          final minH = wide ? 102.0 : 150.0;
          final w = math.max(box.maxWidth, minW);
          final h = box.hasBoundedHeight ? math.max(box.maxHeight, minH) : minH;
          // Nomes: os três inteiros ou os três abreviados — misturar "DISP."
          // com "QUALIDADE" parece erro. A largura do nome é a mesma nas três
          // linhas (com lugar para a forma do alarme, se alguma tiver).
          final shape = alarms.take(3).any((a) => a != null) ? _PartLine.shapeW : 0.0;
          final big = wide && h / 3 >= 56;
          final labelW = wide ? (w - 16) * 10 / 19 - shape : (w - shape - _PartLine.gap) * 11 / 20;
          final short = !_PartLine.namesFit(context, labelW, _PartLine.labelStyle(big));
          final lines = [
            for (var i = 0; i < 3; i++)
              _PartLine(key: ValueKey('oee-parcela-$i'), slot: i, part: parts[i], alarm: alarms[i], stacked: wide, big: big, short: short),
          ];
          Widget body = SizedBox(
            width: w,
            height: h,
            child: wide
                ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(flex: 9, child: hero),
                    const SizedBox(width: 16),
                    Expanded(flex: 10, child: Column(children: [for (final l in lines) Expanded(child: l)])),
                  ])
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(child: hero),
                    const SizedBox(height: 8),
                    for (final l in lines) SizedBox(height: 24, child: l),
                  ]),
          );
          if (w > box.maxWidth || h > box.maxHeight) {
            body = FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.topLeft, child: body);
          }
          return body;
        }),
      ),
    );
  }
}

/// O OEE em destaque: placa, número grande com "%" discreto e a barrinha com
/// as faixas.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.label,
    required this.oee,
    required this.prompt,
    required this.zone,
    this.warn,
    this.alarm,
    this.alarmEntry,
  });

  final String label;
  final OeePart oee;

  /// OEE pronto: vaga vazia pede a variável e erro mostra o motivo aqui.
  final bool prompt;
  final OeeZone zone;
  final num? warn;
  final num? alarm;
  final AlarmEntry? alarmEntry;

  @override
  Widget build(BuildContext context) {
    final f = oee.fraction;
    final stale = oee.state == OeeState.stale;
    final zoneColor = switch (zone) {
      OeeZone.alarm => Ind.alarm,
      OeeZone.warn => Ind.warn,
      OeeZone.normal => null,
    };
    final a = alarmEntry;

    return LayoutBuilder(builder: (context, box) {
      final size = math.min(box.maxHeight * 0.5, box.maxWidth * 0.42).clamp(26.0, 84.0);
      final room = box.maxHeight;

      Widget value;
      if (prompt && oee.state == OeeState.missing) {
        value = const _Prompt();
      } else if (prompt && oee.state == OeeState.error) {
        value = _ErrorText(oee.message);
      } else {
        final color = f == null
            ? Ind.textMuted
            : oee.outOfRange
                ? Ind.textFor(Ind.warn)
                : zoneColor == null
                    ? Ind.text
                    : Ind.textFor(zoneColor);
        value = FittedBox(
          key: const ValueKey('oee-valor'),
          fit: BoxFit.scaleDown,
          alignment: Alignment.bottomLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(f == null ? '---' : Oee.format(f), maxLines: 1, style: Ind.number(size, color: color)),
              if (f != null) ...[
                SizedBox(width: size * 0.08),
                Text('%', maxLines: 1, style: TextStyle(color: Ind.textMuted, fontSize: size * 0.36, fontWeight: FontWeight.w600)),
              ],
            ],
          ),
        );
        if (stale) value = Opacity(opacity: 0.38, child: value);
      }

      // Barrinha só com altura de sobra; fora da faixa, no lugar dela, o aviso
      // em palavras (a barra cheia mentiria).
      final note = oee.outOfRange ? (oee.blocked ? 'Confira a escala' : 'Fora de 0 a 100 %') : null;
      final showBar = note == null && room >= 84 && !(prompt && (oee.state == OeeState.missing || oee.state == OeeState.error));

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            if (a != null)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: AlarmShape(priority: a.priority, size: 14, blinking: a.phase.unacked),
              ),
            Expanded(child: Text(label.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: Ind.tag(size: 11))),
            if (stale)
              Tooltip(
                message: 'Sem comunicação — mostrando o último valor',
                child: Padding(padding: const EdgeInsets.only(left: 4), child: Icon(Icons.wifi_off_rounded, size: 14, color: Ind.warn)),
              ),
            // Forma além da cor: quem não distingue amarelo de vermelho vê o ícone.
            if (zoneColor != null)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(zone == OeeZone.alarm ? Icons.error_rounded : Icons.warning_amber_rounded,
                    key: ValueKey('oee-faixa-${zone.name}'), size: 16, color: Ind.textFor(zoneColor)),
              ),
          ]),
          Expanded(child: Align(alignment: Alignment.bottomLeft, child: value)),
          if (note != null) ...[
            const SizedBox(height: 6),
            SizedBox(
              height: 16,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.warning_amber_rounded, size: 14, color: Ind.textFor(Ind.warn)),
                  const SizedBox(width: 4),
                  Text(note, style: TextStyle(color: Ind.textFor(Ind.warn), fontSize: 12, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ],
          if (showBar) ...[
            const SizedBox(height: 10),
            Opacity(
              opacity: stale ? 0.38 : 1,
              child: SizedBox(
                height: 10,
                child: CustomPaint(
                  painter: _OeeBarPainter(
                    fraction: f?.clamp(0.0, 1.0),
                    warn: warn?.toDouble(),
                    alarm: alarm?.toDouble(),
                    zone: zoneColor,
                  ),
                ),
              ),
            ),
          ],
        ],
      );
    });
  }
}

/// Uma parcela: nome em placa e o valor em %. Empilhada (nome em cima) ao
/// lado do OEE; em linha (nome à esquerda) no arranjo estreito. Os nomes saem
/// inteiros quando cabem e abreviados quando não ("DISP."), nunca com "…" —
/// quem decide é o elemento, para as três linhas ([namesFit]).
class _PartLine extends StatelessWidget {
  const _PartLine({
    super.key,
    required this.slot,
    required this.part,
    required this.alarm,
    required this.stacked,
    required this.big,
    required this.short,
  });

  final int slot;
  final OeePart part;
  final AlarmEntry? alarm;
  final bool stacked;

  /// Linha alta (tablet): placa um pouco maior.
  final bool big;

  /// Nome abreviado.
  final bool short;

  /// Respiro entre nome e valor na linha do arranjo estreito.
  static const gap = 8.0;

  /// Largura da forma do alarme antes do nome.
  static const shapeW = 17.0;

  static TextStyle labelStyle(bool big) => Ind.tag(size: big ? 12 : 10.5);

  /// Os três nomes inteiros cabem em [width]? Mede com a fonte e o tamanho
  /// de letra de verdade (inclusive o do sistema), com 1 dp de folga.
  static bool namesFit(BuildContext context, double width, TextStyle style) {
    final base = DefaultTextStyle.of(context).style.merge(style);
    final scaler = MediaQuery.textScalerOf(context);
    for (final t in Oee.titles.take(3)) {
      final tp = TextPainter(
        text: TextSpan(text: t.toUpperCase(), style: base),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final fits = tp.width <= width - 1;
      tp.dispose();
      if (!fits) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final a = alarm;
    return LayoutBuilder(builder: (context, box) {
      final name = (short ? Oee.shortTitles[slot] : Oee.titles[slot]).toUpperCase();
      final label = Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: labelStyle(big));
      final shape = a == null
          ? null
          : Padding(padding: const EdgeInsets.only(right: 5), child: AlarmShape(priority: a.priority, size: 12, blinking: a.phase.unacked));

      if (!stacked) {
        return Row(children: [
          ?shape,
          Expanded(flex: 11, child: label),
          const SizedBox(width: gap),
          Expanded(flex: 9, child: _PartValue(part: part, size: 18, alignment: Alignment.centerRight)),
        ]);
      }
      // O número ocupa o que sobra da linha; com letra do sistema maior, ele
      // encolhe em vez de a linha transbordar.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [?shape, Expanded(child: label)]),
          const SizedBox(height: 3),
          Expanded(child: _PartValue(part: part, size: (box.maxHeight - 17).clamp(14.0, 40.0), alignment: Alignment.centerLeft)),
        ],
      );
    });
  }
}

/// O valor da parcela: número com "%", ou "---", ou o pedido de variável, ou
/// o motivo do erro — com os ícones de sem comunicação e de fora da faixa.
class _PartValue extends StatelessWidget {
  const _PartValue({required this.part, required this.size, required this.alignment});
  final OeePart part;
  final double size;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    if (part.state == OeeState.missing) return Align(alignment: alignment, child: _Prompt(short: true, text: part.message.isEmpty ? null : part.message));
    if (part.state == OeeState.error) return Align(alignment: alignment, child: _ErrorText(part.message));
    final f = part.fraction;
    final stale = part.state == OeeState.stale;
    final out = part.outOfRange;
    Widget number = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(f == null ? '---' : Oee.format(f),
            maxLines: 1, style: Ind.number(size, color: f == null ? Ind.textMuted : (out ? Ind.textFor(Ind.warn) : Ind.text))),
        if (f != null) ...[
          const SizedBox(width: 3),
          Text('%', maxLines: 1, style: TextStyle(color: Ind.textMuted, fontSize: math.max(11, size * 0.5), fontWeight: FontWeight.w600)),
        ],
      ],
    );
    if (stale) number = Opacity(opacity: 0.38, child: number);
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: alignment,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        number,
        if (out)
          Tooltip(
            message: 'Fora de 0 a 100 % — confira a escala na configuração',
            child: Padding(padding: const EdgeInsets.only(left: 5), child: Icon(Icons.warning_amber_rounded, size: 15, color: Ind.textFor(Ind.warn))),
          ),
        if (stale)
          Tooltip(
            message: 'Sem comunicação — mostrando o último valor',
            child: Padding(padding: const EdgeInsets.only(left: 5), child: Icon(Icons.wifi_off_rounded, size: 13, color: Ind.warn)),
          ),
      ]),
    );
  }
}

/// Vaga sem variável: o mesmo aviso dos outros elementos, na cor de interação.
class _Prompt extends StatelessWidget {
  const _Prompt({this.short = false, this.text});
  final bool short;

  /// No lugar do "Escolha" (ex.: [Oee.pendingText]).
  final String? text;

  @override
  Widget build(BuildContext context) => FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.link_off_rounded, size: 15, color: Ind.accent),
          const SizedBox(width: 5),
          Text(text ?? (short ? 'Escolha' : 'Escolha a variável'), style: TextStyle(color: Ind.accent, fontWeight: FontWeight.w600, fontSize: 13)),
        ]),
      );
}

/// Motivo do erro de leitura, em vermelho (como na linha da tabela).
class _ErrorText extends StatelessWidget {
  const _ErrorText(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.error_outline_rounded, size: 13, color: Ind.alarm),
        const SizedBox(width: 4),
        Flexible(
          child: Text(message, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Ind.textFor(Ind.alarm), fontSize: 11.5, fontWeight: FontWeight.w600)),
        ),
      ]);
}

/// Barrinha do OEE de 0 a 100 %: trilho rebaixado, preenchimento neutro que
/// só ganha cor na faixa (como o medidor) e, por baixo, as faixas de alarme
/// (de 0 até o alarme) e de atenção (do alarme até a atenção).
class _OeeBarPainter extends CustomPainter {
  _OeeBarPainter({required this.fraction, this.warn, this.alarm, this.zone});

  /// Paleta com que foi criado: troca de tema força redesenho.
  final int rev = Ind.revision;
  final double? fraction;
  final double? warn;
  final double? alarm;
  final Color? zone;

  @override
  void paint(Canvas canvas, Size size) {
    const track = 6.0;
    final r = Radius.circular(track / 2);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, size.width, track), r), Paint()..color = Ind.well);
    final f = fraction;
    if (f != null && f > 0.001) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, size.width * f, track), r),
        Paint()..color = zone ?? Ind.text.withValues(alpha: Ind.isDark ? 0.82 : 0.75),
      );
    }
    // Faixas finas por baixo do trilho: não disputam com o valor.
    double x(double pct) => size.width * (pct / 100).clamp(0.0, 1.0);
    final top = track + 2;
    final band = size.height - top;
    final a = alarm, w = warn;
    if (a != null && a > 0) canvas.drawRect(Rect.fromLTWH(0, top, x(a), band), Paint()..color = Ind.alarm);
    if (w != null) {
      final from = a == null ? 0.0 : x(a);
      final to = x(w);
      if (to > from) canvas.drawRect(Rect.fromLTRB(from, top, to, top + band), Paint()..color = Ind.warn);
    }
  }

  @override
  bool shouldRepaint(_OeeBarPainter o) => o.rev != rev || o.fraction != fraction || o.warn != warn || o.alarm != alarm || o.zone != zone;
}
