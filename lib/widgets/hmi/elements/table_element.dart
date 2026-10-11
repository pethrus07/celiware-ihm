import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../app/app_scope.dart';
import '../../../core/theme/app_theme.dart';
import '../../../models/hmi_screen.dart';
import '../../../models/project.dart';
import '../../../models/tag.dart';
import '../../../services/alarms/alarm_engine.dart';
import '../../../services/runtime/tag_codec.dart';
import '../../../services/runtime/tag_store.dart';
import '../../alarms/alarm_widgets.dart';
import '../hmi_frame.dart';
import '../live_tags.dart';
import '../write_actions.dart';

/// Tabela de valores (GR-7): até [maxRows] variáveis, uma por linha — nome à
/// esquerda, valor com unidade à direita, em número tabular.
///
/// É o elemento da tela "de muitas variáveis": numa linha de ~28 dp cabe o
/// que um mostrador gasta um cartão inteiro para mostrar. As linhas se
/// espalham até [maxRow] quando sobra altura e só encolhem até [minRow]; dali
/// para baixo a tabela rola — e aí **só as linhas à vista são lidas** (a
/// tabela inscreve as próprias variáveis com [VisibleLiveTags]; a tela deixa
/// as dela de fora, ver [HmiScreen.liveTagIds]).
///
/// Cada linha trata a qualidade como os outros elementos: "---" esperando a
/// primeira leitura, valor esmaecido com o ícone de sem comunicação, motivo em
/// vermelho no endereço recusado, e a forma do alarme da variável ao lado do
/// nome. Liga/desliga mostra o texto de ligado/desligado da tabela.
///
/// Tocar numa linha numérica gravável abre o mesmo teclado do "Ajuste de
/// valor" (com a confirmação da tela). O toque só abre o teclado — quem grava
/// é o GRAVAR dele —, por isso a linha pode ser mais baixa que os 48 dp de um
/// botão. Liga/desliga fica só leitura na tabela: um toque de raspão numa
/// linha de 28 dp não pode ligar um motor; comando é com o Botão.
class TableElement extends StatefulWidget {
  const TableElement({super.key, required this.element});
  final HmiElement element;

  /// Mais que isso vira planilha: a tabela é para bater o olho.
  static const maxRows = 30;

  /// Linha mais baixa antes de rolar: número de 16 e nome de 12,5 ainda
  /// legíveis, e duas tabelas lado a lado mostram 40+ variáveis num celular
  /// em pé na grade fina (GR-8).
  static const minRow = 28.0;

  /// Linha mais alta: com poucas variáveis a tabela não vira uma lista de
  /// cartões espaçados.
  static const maxRow = 40.0;

  /// Variáveis das linhas, na ordem, só as que ainda existem no projeto
  /// (variável apagada some da tabela em vez de virar linha vazia).
  static List<Tag> rowsOf(HmiElement e, Project project) => [
        for (final id in e.tagIds.take(maxRows)) ?project.tag(id),
      ];

  /// Linha que abre o teclado ao tocar: número único que a tela pode gravar.
  static bool editableRow(Tag tag) => tag.canWrite && tag.dataType.isNumeric && !tag.isArray;

  @override
  State<TableElement> createState() => _TableElementState();
}

class _TableElementState extends State<TableElement> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.element;
    final project = AppScope.watch(context).controller.project;
    final rows = TableElement.rowsOf(e, project);
    final title = e.prop<String>('label', '');
    final onText = e.prop<String>('onText', 'LIGADO');
    final offText = e.prop<String>('offText', 'DESLIGADO');

    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < 220;
      final padH = narrow ? 8.0 : 12.0;
      const padV = 6.0;
      final titleH = title.isEmpty ? 0.0 : 22.0;

      if (rows.isEmpty) {
        return _panel(
          border: Ind.accent,
          padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (title.isNotEmpty) _Title(title, height: titleH),
            Expanded(
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.link_off_rounded, size: 16, color: Ind.accent),
                    const SizedBox(width: 6),
                    Text('Escolha as variáveis', style: TextStyle(color: Ind.accent, fontWeight: FontWeight.w600, fontSize: 13)),
                  ]),
                ),
              ),
            ),
          ]),
        );
      }

      final room = box.maxHeight - padV * 2 - titleH;
      final fit = room / rows.length;
      final scrolls = fit < TableElement.minRow;
      final extent = scrolls ? TableElement.minRow : fit.clamp(TableElement.minRow, TableElement.maxRow);
      // O valor fica com até 60% da linha; o nome cede e ganha reticências.
      final valueMax = (box.maxWidth - padH * 2 - (scrolls ? 19 : 12)) * 0.6;

      Widget list = ListView.builder(
        controller: _scroll,
        primary: false,
        // Rolando, o trilho ganha uma faixa própria e não cobre a unidade.
        padding: EdgeInsets.only(right: scrolls ? 7 : 0),
        // Cabe tudo: a tabela não captura o arrasto e a tela rola por cima dela.
        physics: scrolls ? const ClampingScrollPhysics() : const NeverScrollableScrollPhysics(),
        itemExtent: extent,
        // Uma linha de folga em cima e embaixo: o valor já está lá quando a
        // linha entra, e o resto da tabela continua sem ser lido.
        scrollCacheExtent: ScrollCacheExtent.pixels(extent),
        itemCount: rows.length,
        itemBuilder: (context, i) => LiveTagItem(
          key: ValueKey(rows[i].id),
          tagId: rows[i].id,
          child: TableValueRow(tag: rows[i], index: i, extent: extent, valueMax: valueMax, onText: onText, offText: offText),
        ),
      );
      if (scrolls) {
        // Trilho fino sempre à vista: sem ele ninguém descobre que há mais linhas.
        list = RawScrollbar(
          controller: _scroll,
          thumbVisibility: true,
          thickness: 3,
          radius: const Radius.circular(2),
          thumbColor: Ind.textMuted.withValues(alpha: 0.55),
          padding: EdgeInsets.zero,
          child: list,
        );
      }

      return _panel(
        padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (title.isNotEmpty) _Title(title, height: titleH),
          Expanded(child: VisibleLiveTags(child: list)),
        ]),
      );
    });
  }

  /// Mesmo cartão dos outros elementos ([HmiFrame]): camada, borda quase
  /// invisível, sombra e brilho no topo. Borda de cor só quando comunica algo.
  Widget _panel({required EdgeInsets padding, required Widget child, Color? border}) => CustomPaint(
        foregroundPainter: CardEdge(rev: Ind.revision),
        child: Container(
          decoration: Ind.card(border: border, width: border == null ? 1 : 1.6),
          padding: padding,
          child: child,
        ),
      );
}

class _Title extends StatelessWidget {
  const _Title(this.text, {required this.height});
  final String text;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(text.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: Ind.tag(size: 11)),
          ),
        ),
      );
}

/// Uma linha da tabela: nome, valor e o estado da leitura daquela variável.
/// Redesenha sozinha quando o valor dela muda (as outras linhas, não).
class TableValueRow extends StatelessWidget {
  const TableValueRow({
    super.key,
    required this.tag,
    required this.index,
    required this.extent,
    required this.valueMax,
    this.onText = 'LIGADO',
    this.offText = 'DESLIGADO',
  });

  final Tag tag;

  /// Posição na tabela: as ímpares ganham um tom de fundo (leitura em linha).
  final int index;

  /// Altura da linha.
  final double extent;

  /// Largura máxima do valor.
  final double valueMax;
  final String onText;
  final String offText;

  @override
  Widget build(BuildContext context) {
    final screen = HmiScreenContext.of(context);
    return TagBuilder(
      tagId: tag.id,
      builder: (context, current, r) {
        final t = current ?? tag;
        if (t.alarms.isEmpty) return _row(context, screen, t, r, null);
        // Variável com alarme: a linha ouve o motor e se marca quando ele
        // dispara — o alarme aparece onde o valor está, como nos cartões.
        final engine = AppScope.of(context).alarms;
        return ListenableBuilder(
          listenable: engine,
          builder: (context, _) => _row(context, screen, t, r, engine.forTag(t.id)),
        );
      },
    );
  }

  Widget _row(BuildContext context, HmiScreenContext screen, Tag t, TagReading r, AlarmEntry? alarm) {
    final big = extent >= 34;
    final lost = r.quality == TagQuality.commLost;
    final broken = r.quality == TagQuality.addressError || r.quality == TagQuality.configError;
    final editable = screen.canOperate && TableElement.editableRow(t);

    // Tom de fundo: alarme ativo pinta a linha na cor da prioridade; senão,
    // uma linha sim, outra não, levemente mais clara — separa sem borda.
    final tint = alarm != null && alarm.phase.active
        ? alarm.priority.color.withValues(alpha: Ind.isDark ? 0.18 : 0.14)
        : index.isOdd
            ? Ind.surfaceHigh.withValues(alpha: Ind.isDark ? 0.6 : 0.9)
            : null;

    Widget value;
    if (broken) {
      value = Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.error_outline_rounded, size: 13, color: Ind.alarm),
        const SizedBox(width: 4),
        Flexible(
          child: Text(r.message, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Ind.textFor(Ind.alarm), fontSize: 11.5, fontWeight: FontWeight.w600)),
        ),
      ]);
    } else {
      value = FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: _value(t, r.value, big));
      if (lost) value = Opacity(opacity: 0.38, child: value);
    }

    final row = Container(
      decoration: tint == null ? null : BoxDecoration(color: tint, borderRadius: BorderRadius.circular(6)),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(children: [
        if (alarm != null)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: AlarmShape(priority: alarm.priority, size: big ? 14 : 12, blinking: alarm.phase.unacked),
          ),
        Expanded(
          child: Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: big ? 13.5 : 12.5, color: Ind.textDim, fontWeight: FontWeight.w500, height: 1.15)),
        ),
        const SizedBox(width: 8),
        ConstrainedBox(constraints: BoxConstraints(maxWidth: valueMax), child: value),
        if (lost)
          Tooltip(
            message: 'Sem comunicação — mostrando o último valor',
            child: Padding(padding: const EdgeInsets.only(left: 4), child: Icon(Icons.wifi_off_rounded, size: 12, color: Ind.warn)),
          ),
        if (editable && !broken)
          Padding(padding: const EdgeInsets.only(left: 6), child: Icon(Icons.edit_rounded, size: big ? 15 : 13, color: Ind.accent)),
      ]),
    );

    if (!editable || broken) return row;
    return Semantics(
      button: true,
      label: 'Ajustar ${t.name}',
      child: GestureDetector(
        key: ValueKey('ajustar-${t.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => _adjust(context, t, r),
        child: row,
      ),
    );
  }

  /// O valor da linha: número com a unidade colada (menor e discreta),
  /// texto do ligado/desligado ou o texto lido do equipamento.
  Widget _value(Tag t, Object? raw, bool big) {
    final v = raw is List ? raw.firstOrNull : raw;
    if (v == null) return Text('---', style: Ind.number(big ? 19 : 16, color: Ind.textMuted));
    if (v is bool) {
      return Text(v ? onText : offText,
          style: TextStyle(
            fontFamily: Ind.condensed,
            fontWeight: v ? FontWeight.w700 : FontWeight.w600,
            fontSize: big ? 16 : 14,
            letterSpacing: 0.3,
            color: v ? Ind.text : Ind.textMuted,
          ));
    }
    if (v is num) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(TagCodec.format(t, v, withUnit: false), style: Ind.number(big ? 19 : 16)),
          if (t.unit.isNotEmpty) ...[
            const SizedBox(width: 3),
            Text(t.unit, style: TextStyle(color: Ind.textMuted, fontSize: big ? 12 : 11, fontWeight: FontWeight.w600)),
          ],
        ],
      );
    }
    return Text('$v', style: TextStyle(fontFamily: Ind.condensed, fontWeight: FontWeight.w600, fontSize: big ? 16 : 14, color: Ind.text));
  }

  /// O mesmo caminho do "Ajuste de valor": teclado grande → confirmação da
  /// tela → grava → a próxima leitura mostra o valor confirmado.
  Future<void> _adjust(BuildContext context, Tag t, TagReading r) async {
    final v = await NumberPad.show(context, tag: t, current: r.value);
    if (v == null || !context.mounted) return;
    await WriteActions.write(context, tag: t, value: v, description: 'De ${TagCodec.format(t, r.value)} para ${TagCodec.format(t, v)}?');
  }
}
