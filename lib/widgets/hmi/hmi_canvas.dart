import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../models/hmi_screen.dart';
import '../common/adaptive.dart';
import 'element_catalog.dart';
import 'elements/chart_elements.dart';
import 'elements/control_elements.dart';
import 'elements/indicator_elements.dart';
import 'elements/oee_element.dart';
import 'elements/static_elements.dart';
import 'elements/table_element.dart';
import 'hmi_frame.dart';

/// Desenha um elemento conforme o tipo.
class HmiElementView extends StatelessWidget {
  const HmiElementView({super.key, required this.element});
  final HmiElement element;

  @override
  Widget build(BuildContext context) {
    final e = element;
    switch (e.type) {
      case ElementType.button:
        return ButtonElement(element: e);
      case ElementType.lamp:
        return LampElement(element: e);
      case ElementType.value:
        return ValueElement(element: e);
      case ElementType.input:
        return InputElement(element: e);
      case ElementType.multistate:
        return MultistateElement(element: e);
      case ElementType.bar:
        return BarElement(element: e);
      case ElementType.gauge:
        return GaugeElement(element: e);
      case ElementType.trend:
        return TrendElement(element: e);
      case ElementType.barChart:
        return BarChartElement(element: e);
      case ElementType.label:
        return LabelElement(element: e);
      case ElementType.image:
        return ImageElement(element: e);
      case ElementType.table:
        return TableElement(element: e);
      case ElementType.oee:
        return OeeElement(element: e);
      case ElementType.unknown:
        return UnknownElement(element: e);
    }
  }
}

/// A grade da tela — em operação ou em edição.
///
/// Geometria: [HmiScreen.columns] colunas de células **quadradas**; a célula
/// mede `largura ÷ colunas`. Assim a tela montada num celular fica
/// proporcional num tablet (tudo cresce junto) e nada depende de pixel.
///
/// Em edição:
///   • pontos marcam as células; sobram linhas vazias embaixo para crescer;
///   • tocar seleciona; arrastar o **selecionado** move; a alça do canto
///     redimensiona — tudo encaixando na célula;
///   • o elemento não pode sobrepor outro nem sair da grade (a posição
///     inválida simplesmente não é aceita, e o elemento fica onde estava);
///   • só o selecionado captura o arrasto: nos outros, arrastar rola a tela.
class HmiCanvas extends StatelessWidget {
  const HmiCanvas({
    super.key,
    required this.screen,
    this.editMode = false,
    this.selectedId,
    this.onSelect,
    this.onChanged,
    this.onEmptyCellTap,
    this.keyFor,
    this.onNavigate,
    this.padding = const EdgeInsets.fromLTRB(14, 14, 14, 110),
  });

  /// Tela em operação: abre outra tela (botão "Ir para tela" e elementos com
  /// "ao tocar, abrir").
  final void Function(String screenId)? onNavigate;

  final HmiScreen screen;
  final bool editMode;
  final String? selectedId;
  final ValueChanged<String?>? onSelect;
  final ValueChanged<HmiElement>? onChanged;

  /// Toque numa célula vazia (editor: "adicionar aqui").
  final void Function(int x, int y)? onEmptyCellTap;

  /// Chave de tutorial para um elemento, quando a página quer realçá-lo.
  final GlobalKey? Function(HmiElement e)? keyFor;
  final EdgeInsets padding;

  /// Respiro entre elementos. Com 6 px a tela parecia um bloco só; 12 separa
  /// cada elemento sem desperdiçar a célula. Na grade fina a célula é a
  /// metade, então o respiro acompanha (20% da célula, entre 4 e 12).
  static const double gap = 12;
  static double gapFor(double cell) => (cell * 0.2).clamp(4.0, gap);

  /// Maior célula aceita (dp) na grade normal. Sem teto, a célula cresce com a
  /// largura: no celular deitado ou no tablet cabiam só dois elementos
  /// gigantes na tela. 96 dp dá, num tablet, a mesma tela do celular 1,5×
  /// maior e centralizada.
  static const double maxCell = 96;

  /// Na grade fina o teto é a largura (até 1.200 dp): é a grade de quem quer
  /// muita variável, e no tablet ela usa a tela inteira (TB-5). Por isso o
  /// teto pela altura não vale para ela fora do celular deitado: no tablet
  /// deitado ele encolhia a grade para ~850 dp e sobrava um terço da tela.
  static const double maxFineWidth = 1200;

  static double maxCellFor(int columns) => columns >= HmiScreen.fineColumns ? maxFineWidth / columns : maxCell;

  @override
  Widget build(BuildContext context) {
    return HmiScreenContext(
      editMode: editMode,
      readOnly: screen.readOnly,
      confirmWrites: screen.confirmWrites,
      onNavigate: editMode ? null : onNavigate,
      child: LayoutBuilder(builder: (context, box) {
        final available = box.maxWidth - padding.horizontal;
        // Segundo teto, pela altura: celular deitado tem ~290 dp úteis, e com
        // 96 dp por célula só apareciam duas linhas e meia. Pelo menos ~4,5
        // linhas à vista; tablet e celular em pé nem chegam nesse limite na
        // grade normal. Na fina ele só vale no celular deitado (TB-5).
        final k = HmiScreen.scaleOf(screen.columns);
        final heightCap = box.maxHeight.isFinite && (k == 1 || WindowClass.isCompactHeight(context));
        final byHeight = heightCap ? math.max(56.0 / k, box.maxHeight / (4.5 * k)) : maxCellFor(screen.columns);
        final cell = math.min(math.min(available / screen.columns, maxCellFor(screen.columns)), byHeight);
        final g = gapFor(cell);
        final width = cell * screen.columns;
        final rows = math.max(screen.rows + (editMode ? 4 : 0), editMode ? 8 : 1);
        final height = rows * cell;

        return _GridScroll(
          cell: cell,
          padding: padding,
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
            width: width,
            height: height,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                if (editMode)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (d) {
                        onSelect?.call(null);
                        onEmptyCellTap?.call((d.localPosition.dx / cell).floor(), (d.localPosition.dy / cell).floor());
                      },
                      child: CustomPaint(painter: _GridPainter(cell: cell, columns: screen.columns, rows: rows)),
                    ),
                  ),
                for (final e in screen.elements)
                  editMode
                      ? _EditableElement(
                          key: ValueKey('ed-${e.id}'),
                          element: e,
                          screen: screen,
                          cell: cell,
                          gap: g,
                          selected: e.id == selectedId,
                          onSelect: () => onSelect?.call(e.id),
                          onChanged: onChanged,
                          tourKey: keyFor?.call(e),
                        )
                      : Positioned(
                          key: ValueKey('el-${e.id}'),
                          left: e.x * cell + g / 2,
                          top: e.y * cell + g / 2,
                          width: e.w * cell - g,
                          height: e.h * cell - g,
                          // Uma camada por elemento: o valor que muda redesenha só
                          // o próprio cartão, não a tela (sombras e bordas saem de cache).
                          child: RepaintBoundary(child: KeyedSubtree(key: keyFor?.call(e), child: _Linked(element: e, onNavigate: onNavigate))),
                        ),
              ],
            ),
            ),
          ),
        );
      }),
    );
  }
}

/// Rolagem da grade que atravessa girar e redimensionar (TB-6): quando a
/// célula muda de tamanho, a posição é refeita em linhas da grade — a mesma
/// linha continua no topo, em vez de a tela pular para outro trecho.
class _GridScroll extends StatefulWidget {
  const _GridScroll({required this.cell, required this.padding, required this.child});
  final double cell;
  final EdgeInsets padding;
  final Widget child;

  @override
  State<_GridScroll> createState() => _GridScrollState();
}

class _GridScrollState extends State<_GridScroll> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(_GridScroll old) {
    super.didUpdateWidget(old);
    if (old.cell == widget.cell || old.cell <= 0 || !_scroll.hasClients) return;
    final rows = _scroll.offset / old.cell;
    // Depois do quadro: só então a altura nova da grade está medida.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final p = _scroll.position;
      _scroll.jumpTo((rows * widget.cell).clamp(p.minScrollExtent, p.maxScrollExtent));
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(controller: _scroll, padding: widget.padding, child: widget.child);
}

/// Elemento em operação com "ao tocar, abrir tela" (`goTo`): o toque abre a
/// tela e uma seta discreta no canto avisa que ele leva a algum lugar — sem
/// ela, o operador não descobre que o mostrador é tocável.
///
/// Botão e ajuste de valor ficam de fora: neles o toque já grava. O botão
/// tem o próprio modo "Ir para tela".
class _Linked extends StatelessWidget {
  const _Linked({required this.element, required this.onNavigate});
  final HmiElement element;
  final void Function(String screenId)? onNavigate;

  @override
  Widget build(BuildContext context) {
    final view = HmiElementView(element: element);
    final target = element.props['goTo'];
    final nav = onNavigate;
    if (target is! String || nav == null || element.type == ElementType.button || element.type == ElementType.input) {
      return view;
    }
    return GestureDetector(
      key: ValueKey('ir-${element.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => nav(target),
      child: Stack(children: [
        Positioned.fill(child: view),
        Positioned(top: 6, right: 6, child: Icon(Icons.arrow_outward_rounded, size: 16, color: Ind.textMuted)),
      ]),
    );
  }
}

class _EditableElement extends StatefulWidget {
  const _EditableElement({
    super.key,
    required this.element,
    required this.screen,
    required this.cell,
    required this.gap,
    required this.selected,
    required this.onSelect,
    required this.onChanged,
    this.tourKey,
  });

  final HmiElement element;
  final HmiScreen screen;
  final double cell;
  final double gap;
  final bool selected;
  final VoidCallback onSelect;
  final ValueChanged<HmiElement>? onChanged;
  final GlobalKey? tourKey;

  @override
  State<_EditableElement> createState() => _EditableElementState();
}

class _EditableElementState extends State<_EditableElement> {
  // Deslocamento acumulado do arrasto em curso, em pixels.
  Offset _drag = Offset.zero;
  Offset _resize = Offset.zero;

  HmiElement get e => widget.element;

  /// Posição/tamanho aceitos: dentro da grade e sem sobrepor ninguém.
  bool _fits(HmiElement c) => ElementCatalog.fits(widget.screen, c);

  void _moveBy(Offset delta) {
    _drag += delta;
    final dx = (_drag.dx / widget.cell).round(), dy = (_drag.dy / widget.cell).round();
    if (dx == 0 && dy == 0) return;
    final c = e.copyWith(x: e.x + dx, y: e.y + dy);
    if (_fits(c)) {
      _drag -= Offset(dx * widget.cell, dy * widget.cell);
      HapticFeedback.selectionClick();
      widget.onChanged?.call(c);
    }
  }

  void _resizeBy(Offset delta) {
    _resize += delta;
    final dw = (_resize.dx / widget.cell).round(), dh = (_resize.dy / widget.cell).round();
    if (dw == 0 && dh == 0) return;
    final c = e.copyWith(w: e.w + dw, h: e.h + dh);
    if (_fits(c)) {
      _resize -= Offset(dw * widget.cell, dh * widget.cell);
      HapticFeedback.selectionClick();
      widget.onChanged?.call(c);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cell = widget.cell;
    final g = widget.gap;
    final sel = widget.selected;

    final body = Container(
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Ind.radius + 2),
        border: Border.all(color: sel ? Ind.accent : Colors.transparent, width: 2.5),
      ),
      // Em edição o elemento mostra o valor ao vivo, mas não reage ao toque.
      child: IgnorePointer(child: HmiElementView(element: e)),
    );

    return AnimatedPositioned(
      duration: const Duration(milliseconds: 90),
      left: e.x * cell + g / 2,
      top: e.y * cell + g / 2,
      width: e.w * cell - g,
      height: e.h * cell - g,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: GestureDetector(
              key: widget.tourKey,
              behavior: HitTestBehavior.opaque,
              onTap: widget.onSelect,
              onPanStart: sel ? (_) => _drag = Offset.zero : null,
              onPanUpdate: sel ? (d) => _moveBy(d.delta) : null,
              child: body,
            ),
          ),
          if (sel)
            Positioned(
              right: -14,
              bottom: -14,
              child: GestureDetector(
                key: const ValueKey('alca-redimensionar'),
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => _resize = Offset.zero,
                onPanUpdate: (d) => _resizeBy(d.delta),
                child: Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: Ind.accent,
                      shape: BoxShape.circle,
                      border: Border.all(color: Ind.bg, width: 2),
                    ),
                    child: Icon(Icons.open_in_full_rounded, size: 13, color: Ind.onAccent),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  /// Paleta com que foi criado: troca de tema força redesenho.
  final int rev = Ind.revision;

  _GridPainter({required this.cell, required this.columns, required this.rows});
  final double cell;
  final int columns;
  final int rows;

  @override
  void paint(Canvas canvas, Size size) {
    final dot = Paint()..color = Ind.lineStrong;
    for (var y = 0; y <= rows; y++) {
      for (var x = 0; x <= columns; x++) {
        canvas.drawCircle(Offset(x * cell, y * cell), 1.4, dot);
      }
    }
  }

  @override
  bool shouldRepaint(_GridPainter o) => o.cell != cell || o.columns != columns || o.rows != rows || o.rev != rev;
}
