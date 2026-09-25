import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../models/hmi_screen.dart';
import 'element_catalog.dart';
import 'elements/chart_elements.dart';
import 'elements/control_elements.dart';
import 'elements/indicator_elements.dart';
import 'elements/static_elements.dart';
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
    this.padding = const EdgeInsets.fromLTRB(14, 14, 14, 110),
  });

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
  /// cada elemento sem desperdiçar a célula.
  static const double gap = 12;

  @override
  Widget build(BuildContext context) {
    return HmiScreenContext(
      editMode: editMode,
      readOnly: screen.readOnly,
      confirmWrites: screen.confirmWrites,
      child: LayoutBuilder(builder: (context, box) {
        final width = box.maxWidth - padding.horizontal;
        final cell = width / screen.columns;
        final rows = math.max(screen.rows + (editMode ? 4 : 0), editMode ? 8 : 1);
        final height = rows * cell;

        return SingleChildScrollView(
          padding: padding,
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
                          selected: e.id == selectedId,
                          onSelect: () => onSelect?.call(e.id),
                          onChanged: onChanged,
                          tourKey: keyFor?.call(e),
                        )
                      : Positioned(
                          key: ValueKey('el-${e.id}'),
                          left: e.x * cell + gap / 2,
                          top: e.y * cell + gap / 2,
                          width: e.w * cell - gap,
                          height: e.h * cell - gap,
                          child: KeyedSubtree(key: keyFor?.call(e), child: HmiElementView(element: e)),
                        ),
              ],
            ),
          ),
        );
      }),
    );
  }
}

class _EditableElement extends StatefulWidget {
  const _EditableElement({
    super.key,
    required this.element,
    required this.screen,
    required this.cell,
    required this.selected,
    required this.onSelect,
    required this.onChanged,
    this.tourKey,
  });

  final HmiElement element;
  final HmiScreen screen;
  final double cell;
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
  bool _fits(HmiElement c) {
    if (c.x < 0 || c.y < 0 || c.right > widget.screen.columns) return false;
    final info = ElementCatalog.of(c.type);
    if (c.w < info.minW || c.h < info.minH) return false;
    return !widget.screen.elements.any((o) => o.id != c.id && o.overlaps(c));
  }

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
    const g = HmiCanvas.gap;
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
                    child: const Icon(Icons.open_in_full_rounded, size: 13, color: Ind.onAccent),
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
  bool shouldRepaint(_GridPainter o) => o.cell != cell || o.columns != columns || o.rows != rows;
}
