import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_scope.dart';
import '../../app/project_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/ids.dart';
import '../../models/hmi_screen.dart';
import '../../widgets/common/adaptive.dart';
import '../../widgets/common/common.dart';
import '../../widgets/hmi/element_catalog.dart';
import '../../widgets/hmi/hmi_canvas.dart';
import '../../widgets/hmi/live_tags.dart';
import '../../widgets/tour/tour.dart';
import '../screen_run_page.dart';
import '../tours.dart';
import 'element_config_sheet.dart';
import 'palette_sheet.dart';
import 'screen_background_section.dart';

/// Editor de tela.
///
/// Fluxo pensado para quem nunca montou IHM:
///   1. "+ Elemento" → paleta com ícone e explicação de cada tipo;
///   2. o elemento entra no primeiro espaço livre (ou onde a pessoa tocou)
///      e já abre a configuração — a primeira pergunta é "qual variável?";
///   3. tocar seleciona, arrastar move, a bolinha do canto redimensiona; na
///      grade extra-fina, setas na barra de baixo andam uma célula por toque;
///   4. não existe "salvar": cada mudança já está gravada.
///
/// Os valores aparecem ao vivo durante a edição (o elemento mostra o que vai
/// mostrar em operação), mas nada reage a toque — ninguém liga uma máquina
/// sem querer enquanto arruma a tela.
///
/// No tablet deitado (a partir de 840 dp) a configuração mora num painel fixo
/// ao lado da grade, em vez da folha que sobe e cobre a tela (TB-4): tocar
/// noutro elemento troca o painel sem fechar; sem seleção, ele mostra as
/// regras da tela.
class ScreenEditorPage extends StatefulWidget {
  const ScreenEditorPage({super.key, required this.screenId, this.startTour = false});
  final String screenId;
  final bool startTour;

  @override
  State<ScreenEditorPage> createState() => _ScreenEditorPageState();
}

class _ScreenEditorPageState extends State<ScreenEditorPage> {
  String? _selected;
  (int, int)? _lastEmptyCell;

  /// Setas de ajuste fino à vista no lugar da barra de baixo (extra-fina).
  bool _nudging = false;

  /// Linhas da grade à vista agora (a grade informa a cada desenho): a
  /// altura do encaixe "tela inteira" da imagem de fundo.
  int _viewRows = 0;

  final _paletteKey = GlobalKey();
  final _configKey = GlobalKey();
  final _settingsKey = GlobalKey();
  final _doneKey = GlobalKey();
  final _firstElementKey = GlobalKey();

  HmiScreen? _screen(BuildContext context) => AppScope.watch(context).controller.project.screen(widget.screenId);

  void _save(HmiScreen s) => AppScope.of(context).controller.saveScreen(s);

  void _replace(HmiScreen screen, HmiElement e) =>
      _save(screen.copyWith(elements: [for (final x in screen.elements) x.id == e.id ? e : x]));

  /// Primeira posição livre para um elemento w×h, varrendo linha a linha —
  /// começando pela célula que a pessoa tocou, se couber lá.
  (int, int) _freeSpot(HmiScreen s, int w, int h) {
    bool fits(int x, int y) {
      if (x < 0 || x + w > s.columns) return false;
      final probe = HmiElement(id: '_', type: ElementType.label, x: x, y: y, w: w, h: h);
      return !s.elements.any((o) => o.overlaps(probe));
    }

    final hint = _lastEmptyCell;
    if (hint != null && fits(hint.$1, hint.$2)) return hint;
    for (var y = 0; y < 1000; y++) {
      for (var x = 0; x + w <= s.columns; x++) {
        if (fits(x, y)) return (x, y);
      }
    }
    return (0, s.rows);
  }

  Future<void> _add(HmiScreen screen) async {
    final type = await PaletteSheet.show(context);
    if (type == null || !mounted) return;
    final (w, h) = ElementCatalog.defaultSize(type, screen.columns);
    final (x, y) = _freeSpot(screen, w, h);
    final e = HmiElement(id: newId('e'), type: type, x: x, y: y, w: w, h: h, props: ElementCatalog.defaultProps(type));
    _save(screen.copyWith(elements: [...screen.elements, e]));
    setState(() {
      _selected = e.id;
      _lastEmptyCell = null;
    });
    // Texto e imagem também começam pela configuração (o texto, a foto). No
    // tablet deitado o painel ao lado já mostra o elemento novo.
    if (!WindowClass.twoPane(context)) await ElementConfigSheet.show(context, screenId: screen.id, elementId: e.id);
  }

  void _duplicate(HmiScreen screen, HmiElement e) {
    final (x, y) = _freeSpot(screen, e.w, e.h);
    final copy = HmiElement(id: newId('e'), type: e.type, x: x, y: y, w: e.w, h: e.h, props: Map.of(e.props));
    _save(screen.copyWith(elements: [...screen.elements, copy]));
    setState(() => _selected = copy.id);
  }

  Future<void> _delete(HmiScreen screen, HmiElement e) async {
    final info = ElementCatalog.of(e.type);
    if (!await confirmDelete(context, title: 'Tirar este elemento?', body: '${info.name} "${e.prop<String>('label', e.prop<String>('text', ''))}" sai da tela. A variável continua cadastrada.')) return;
    _save(screen.copyWith(elements: screen.elements.where((x) => x.id != e.id).toList()));
    setState(() {
      _selected = null;
      _nudging = false;
    });
  }

  Future<void> _settings(HmiScreen screen) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ScreenSettingsSheet(screenId: screen.id, viewRows: () => _viewRows),
    );
  }

  void _done(HmiScreen screen) =>
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ScreenRunPage(screenId: screen.id)));

  @override
  Widget build(BuildContext context) {
    final screen = _screen(context);
    if (screen == null) {
      return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.search_off_rounded, title: 'Tela não encontrada', body: 'Ela pode ter sido apagada.'));
    }
    final selected = screen.elements.where((e) => e.id == _selected).firstOrNull;
    final firstId = screen.elements.firstOrNull?.id;
    final panel = WindowClass.twoPane(context);

    return LiveTags(
      tagIds: screen.liveTagIds,
      child: TourHost(
        spec: Tours.editor(palette: _paletteKey, element: _firstElementKey, config: _configKey, settings: _settingsKey, done: _doneKey),
        forceStart: widget.startTour,
        child: SupportingPaneScaffold(
          // Tablet deitado: configurar e regras ficam à vista no painel.
          panel: !panel
              ? null
              : selected == null
                  ? KeyedSubtree(key: _settingsKey, child: _ScreenSettingsSheet(screenId: screen.id, viewRows: () => _viewRows, panel: true))
                  : KeyedSubtree(
                      key: _configKey,
                      child: ElementConfigSheet(key: ValueKey('painel-${selected.id}'), screenId: screen.id, elementId: selected.id, panel: true),
                    ),
          appBar: AppBar(
            // Topo com o mínimo: nome, ajuda, concluir. As regras da tela
            // descem para a barra de baixo, junto das outras ferramentas.
            // O nome da tela inteiro (uma linha, ou duas menores) e o Concluir
            // na altura de botão da barra (40 dp de desenho, 48 de toque):
            // no celular, "Cortadora — operação" virava "Cortadora — o…".
            title: AdaptiveTitle(screen.name),
            actions: [
              const HelpButton(),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilledButton(
                  key: _doneKey,
                  onPressed: () => _done(screen),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(64, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    tapTargetSize: MaterialTapTargetSize.padded,
                  ),
                  child: const Text('Concluir'),
                ),
              ),
            ],
          ),
          body: Stack(children: [
            Positioned.fill(
              child: HmiCanvas(
                screen: screen,
                editMode: true,
                selectedId: _selected,
                onSelect: (id) => setState(() {
                  _selected = id;
                  if (id == null) _nudging = false;
                }),
                onChanged: (e) => _replace(screen, e),
                onEmptyCellTap: (x, y) => _lastEmptyCell = (x, y),
                keyFor: (e) => e.id == firstId ? _firstElementKey : null,
                onViewRows: (r) => _viewRows = r,
              ),
            ),
            // Grade vazia só com pontinhos não dizia o que fazer. A dica não
            // captura toque: tocar numa célula continua marcando o lugar.
            if (screen.elements.isEmpty)
              IgnorePointer(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 40),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.touch_app_outlined, size: 40, color: Ind.textMuted),
                      SizedBox(height: 14),
                      Text('Toque em  + Elemento  para começar', textAlign: TextAlign.center,
                          style: TextStyle(fontFamily: Ind.condensed, fontWeight: FontWeight.w700, fontSize: 20, color: Ind.textDim)),
                      SizedBox(height: 8),
                      Text('Quer escolher o lugar? Toque antes numa célula da grade.', textAlign: TextAlign.center,
                          style: TextStyle(color: Ind.textMuted, height: 1.4)),
                    ]),
                  ),
                ),
              ),
          ]),
          bottomNavigationBar: SafeArea(
            child: Container(
              // Sob a grade, com o painel ao lado: no máximo 640 dp de botões.
              padding: EdgeInsets.symmetric(horizontal: panel ? math.max(12.0, (MediaQuery.sizeOf(context).width - SupportingPaneScaffold.panelWidth(context) - FormWidth.maxWidth) / 2) : 12, vertical: 10),
              decoration: BoxDecoration(color: Ind.surface, border: Border(top: BorderSide(color: Ind.line))),
              child: selected != null && _nudging && screen.extraFine
                  ? _NudgeBar(
                      key: const ValueKey('ajuste-fino-barra'),
                      screen: screen,
                      element: selected,
                      onChanged: (e) => _replace(screen, e),
                      onDone: () => setState(() => _nudging = false),
                    )
                  : selected == null
                  ? Row(children: [
                      Expanded(
                        child: FilledButton.icon(
                          key: _paletteKey,
                          onPressed: () => _add(screen),
                          icon: const Icon(Icons.add_rounded),
                          label: const Text('Elemento'),
                        ),
                      ),
                      if (!panel) ...[
                        const SizedBox(width: 8),
                        KeyedSubtree(
                          key: _settingsKey,
                          child: _ToolButton(icon: Icons.tune_rounded, tooltip: 'Regras da tela', onTap: () => _settings(screen)),
                        ),
                      ],
                    ])
                  : Row(children: [
                      // Com o painel ao lado não há o que abrir: o botão
                      // principal volta a ser acrescentar.
                      if (panel)
                        Expanded(
                          child: FilledButton.icon(key: _paletteKey, onPressed: () => _add(screen), icon: const Icon(Icons.add_rounded), label: const Text('Elemento')),
                        )
                      else
                        Expanded(
                          flex: 3,
                          child: FilledButton.icon(
                            key: _configKey,
                            onPressed: () => ElementConfigSheet.show(context, screenId: screen.id, elementId: selected.id),
                            icon: const Icon(Icons.settings_outlined),
                            label: const Text('Configurar'),
                          ),
                        ),
                      const SizedBox(width: 8),
                      _ToolButton(icon: Icons.copy_all_outlined, tooltip: 'Duplicar', onTap: () => _duplicate(screen, selected)),
                      const SizedBox(width: 8),
                      _ToolButton(icon: Icons.delete_outline_rounded, tooltip: 'Tirar da tela', color: Ind.alarm, onTap: () => _delete(screen, selected)),
                      // Extra-fina: as setas de ajuste fino. No celular elas
                      // tomam o lugar do "+" (que continua sem seleção) — com
                      // cinco botões o "Configurar" não cabia em 320 dp.
                      if (screen.extraFine) ...[
                        const SizedBox(width: 8),
                        KeyedSubtree(
                          key: const ValueKey('ajuste-fino'),
                          child: _ToolButton(icon: Icons.open_with_rounded, tooltip: 'Ajustar com setas', onTap: () => setState(() => _nudging = true)),
                        ),
                      ] else if (!panel) ...[
                        const SizedBox(width: 8),
                        _ToolButton(icon: Icons.add_rounded, tooltip: 'Outro elemento', onTap: () => _add(screen)),
                      ],
                    ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Ajuste fino da grade extra-fina: quatro setas que andam **uma célula por
/// toque**, com a tela à vista em cima.
///
/// Na extra-fina a célula tem ~14 dp no celular: o dedo não acerta uma
/// célula arrastando, e a "Posição e tamanho" da configuração fica numa
/// folha que cobre a tela — não dá para ver o elemento chegando no lugar do
/// desenho. Aqui a barra de baixo vira as setas: "Mover" anda o elemento,
/// "Tamanho" puxa a borda da direita e a de baixo (como a alça do canto). A
/// seta que não cabe (borda da grade, outro elemento, tamanho mínimo) fica
/// apagada — a mesma regra do arrasto ([ElementCatalog.fits]).
class _NudgeBar extends StatefulWidget {
  const _NudgeBar({super.key, required this.screen, required this.element, required this.onChanged, required this.onDone});
  final HmiScreen screen;
  final HmiElement element;
  final ValueChanged<HmiElement> onChanged;
  final VoidCallback onDone;

  @override
  State<_NudgeBar> createState() => _NudgeBarState();
}

class _NudgeBarState extends State<_NudgeBar> {
  bool _resize = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.element;
    Widget arrow(IconData icon, int dx, int dy, String key, String move, String size) {
      final next = _resize ? e.copyWith(w: e.w + dx, h: e.h + dy) : e.copyWith(x: e.x + dx, y: e.y + dy);
      return StepButton(
        key: ValueKey(key),
        size: const Size(56, 52),
        icon: icon,
        tooltip: _resize ? size : move,
        onTap: ElementCatalog.fits(widget.screen, next)
            ? () {
                HapticFeedback.selectionClick();
                widget.onChanged(next);
              }
            : null,
      );
    }

    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Expanded(
          child: SegmentedButton<bool>(
            key: const ValueKey('ajuste-modo'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('Mover', key: ValueKey('ajuste-mover'))),
              ButtonSegment(value: true, label: Text('Tamanho', key: ValueKey('ajuste-tamanho'))),
            ],
            selected: {_resize},
            onSelectionChanged: (s) => setState(() => _resize = s.first),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(key: const ValueKey('ajuste-pronto'), onPressed: widget.onDone, child: const Text('Pronto')),
      ]),
      const SizedBox(height: 10),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        arrow(Icons.arrow_back_rounded, -1, 0, 'passo-esquerda', 'Para a esquerda', 'Menos largura'),
        arrow(Icons.arrow_upward_rounded, 0, -1, 'passo-cima', 'Para cima', 'Menos altura'),
        arrow(Icons.arrow_downward_rounded, 0, 1, 'passo-baixo', 'Para baixo', 'Mais altura'),
        arrow(Icons.arrow_forward_rounded, 1, 0, 'passo-direita', 'Para a direita', 'Mais largura'),
      ]),
    ]);
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({required this.icon, required this.tooltip, required this.onTap, this.color});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 52,
        height: 48,
        child: Tooltip(
          message: tooltip,
          child: OutlinedButton(
            onPressed: onTap,
            style: OutlinedButton.styleFrom(padding: EdgeInsets.zero, foregroundColor: color ?? Ind.text),
            child: Icon(icon),
          ),
        ),
      );
}

/// Regras da tela: nome, grade, imagem de fundo, só acompanhamento,
/// confirmação de escrita, apagar.
class _ScreenSettingsSheet extends StatelessWidget {
  const _ScreenSettingsSheet({required this.screenId, required this.viewRows, this.panel = false});
  final String screenId;

  /// Linhas da grade à vista no editor ([ScreenBackgroundSection]).
  final int Function() viewRows;

  /// No painel lateral do editor (tablet), quando nada está selecionado.
  final bool panel;

  /// Troca a grade. Voltar da extra-fina arredonda quem estava em meia
  /// célula da fina: antes, a pergunta diz quantos vão andar. (Pergunta e não
  /// aviso com desfazer: o aviso de baixo ficava escondido atrás desta folha.)
  static Future<void> _changeGrid(BuildContext context, ProjectController c, HmiScreen s, int target) async {
    String plural(int n, String one, String many) => n == 1 ? one : many;
    final grade = target == HmiScreen.defaultColumns ? 'normal' : 'fina';
    final next = s.withColumns(target);
    if (next == null) {
      final n = s.blockersFor(target);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(s.extraFine && target == HmiScreen.fineColumns
              ? '$n ${plural(n, 'elemento é menor', 'elementos são menores')} que uma célula da grade fina. Aumente o tamanho para voltar.'
              : '$n ${plural(n, 'elemento usa', 'elementos usam')} meia célula da grade $grade. Ajuste o tamanho ou a posição para voltar.')));
      return;
    }
    final moved = s.extraFine && target < s.columns ? s.oddElements : 0;
    if (moved > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => DecisionDialog<bool>(
          title: 'Voltar para a grade $grade?',
          body: '$moved ${plural(moved, 'elemento não encaixa', 'elementos não encaixam')} na grade $grade e '
              '${plural(moved, 'vai para a célula', 'vão para a célula')} mais próxima. Nenhum fica por cima de outro.',
          actions: const [
            DialogAction(label: 'Cancelar', value: false),
            DialogAction(label: 'Arredondar', value: true, kind: DialogActionKind.primary, key: ValueKey('arredondar-grade')),
          ],
        ),
      );
      if (ok != true) return;
    }
    c.saveScreen(next);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppScope.watch(context).controller;
    final s = c.project.screen(screenId);
    if (s == null) return const SizedBox(height: 80);
    final children = [
            if (panel) ...[
              Text('Toque num elemento para configurar.', style: TextStyle(color: Ind.textMuted, height: 1.4)),
              const SizedBox(height: Ind.spaceLarge),
            ],
            Text('Regras da tela', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            TextFormField(
              initialValue: s.name,
              decoration: const InputDecoration(labelText: 'Nome da tela'),
              onChanged: (v) {
                if (v.trim().isNotEmpty) c.saveScreen(s.copyWith(name: v.trim()));
              },
            ),
            const SizedBox(height: 16),
            // Grade fina: mais variáveis por tela e encaixe mais preciso;
            // extra-fina: encaixe preciso (sinótico). Ir para uma mais fina não
            // mexe em nada na tela (ver HmiScreen.withColumns). Sem ícones: com
            // três opções, ícone e nome não cabiam no celular de 320 dp.
            const SectionHeader('Grade', padding: EdgeInsets.zero),
            const SizedBox(height: 8),
            SegmentedButton<int>(
              key: const ValueKey('grade-da-tela'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: HmiScreen.defaultColumns, label: Text('Normal', key: ValueKey('grade-normal'))),
                ButtonSegment(value: HmiScreen.fineColumns, label: Text('Fina', key: ValueKey('grade-fina'))),
                ButtonSegment(value: HmiScreen.extraFineColumns, label: Text('Extra-fina', key: ValueKey('grade-extra-fina'))),
              ],
              selected: {s.extraFine ? HmiScreen.extraFineColumns : s.fine ? HmiScreen.fineColumns : HmiScreen.defaultColumns},
              onSelectionChanged: (sel) => _changeGrid(context, c, s, sel.first),
            ),
            const SizedBox(height: 6),
            Text(
                s.extraFine
                    ? 'Para encaixar com precisão, como sobre o desenho da máquina. Selecione um elemento e use as setas.'
                    : s.fine
                        ? 'Cabe o dobro de elementos em cada direção. Bom para telas com muitas variáveis.'
                        : 'Elementos maiores, fáceis de tocar.',
                style: TextStyle(color: Ind.textMuted, fontSize: 13)),
            const SizedBox(height: 20),
            ScreenBackgroundSection(screenId: s.id, viewRows: viewRows),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: s.readOnly,
              onChanged: (v) => c.saveScreen(s.copyWith(readOnly: v)),
              title: const Text('Só acompanhamento'),
              subtitle: const Text('Ninguém grava por esta tela.'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: s.confirmWrites,
              onChanged: s.readOnly ? null : (v) => c.saveScreen(s.copyWith(confirmWrites: v)),
              title: const Text('Confirmar antes de gravar'),
              subtitle: const Text('Pergunta antes de ligar ou mudar um valor.'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(foregroundColor: Ind.alarm, side: BorderSide(color: Ind.alarm)),
              onPressed: () async {
                if (!await confirmDelete(context, title: 'Apagar "${s.name}"?', body: 'A tela e seus ${s.elements.length} elementos somem. Equipamentos e variáveis continuam.')) return;
                c.deleteScreen(s.id);
                if (!context.mounted) return;
                // Na folha: fecha a folha e o editor. No painel: só o editor.
                if (panel) {
                  Navigator.of(context).pop();
                } else {
                  Navigator.of(context)..pop()..pop();
                }
              },
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('Apagar a tela'),
            ),
          ];
    if (panel) return ListView(primary: false, padding: const EdgeInsets.all(Ind.page), children: children);
    // Rola: com a imagem de fundo e os ajustes dela, no celular de 320 dp a
    // folha passa da altura da tela.
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}
