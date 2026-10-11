import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/ids.dart';
import '../../models/hmi_screen.dart';
import '../../widgets/common/common.dart';
import '../../widgets/hmi/element_catalog.dart';
import '../../widgets/hmi/hmi_canvas.dart';
import '../../widgets/hmi/live_tags.dart';
import '../../widgets/tour/tour.dart';
import '../screen_run_page.dart';
import '../tours.dart';
import 'element_config_sheet.dart';
import 'palette_sheet.dart';

/// Editor de tela.
///
/// Fluxo pensado para quem nunca montou IHM:
///   1. "+ Elemento" → paleta com ícone e explicação de cada tipo;
///   2. o elemento entra no primeiro espaço livre (ou onde a pessoa tocou)
///      e já abre a configuração — a primeira pergunta é "qual variável?";
///   3. tocar seleciona, arrastar move, a bolinha do canto redimensiona;
///   4. não existe "salvar": cada mudança já está gravada.
///
/// Os valores aparecem ao vivo durante a edição (o elemento mostra o que vai
/// mostrar em operação), mas nada reage a toque — ninguém liga uma máquina
/// sem querer enquanto arruma a tela.
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
    // Texto e imagem também começam pela configuração (o texto, a foto).
    await ElementConfigSheet.show(context, screenId: screen.id, elementId: e.id);
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
    setState(() => _selected = null);
  }

  Future<void> _settings(HmiScreen screen) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ScreenSettingsSheet(screenId: screen.id),
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

    return LiveTags(
      tagIds: screen.liveTagIds,
      child: TourHost(
        spec: Tours.editor(palette: _paletteKey, element: _firstElementKey, config: _configKey, settings: _settingsKey, done: _doneKey),
        forceStart: widget.startTour,
        child: Scaffold(
          appBar: AppBar(
            // Topo com o mínimo: nome, ajuda, concluir. As regras da tela
            // descem para a barra de baixo, junto das outras ferramentas.
            title: Text(screen.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              const HelpButton(),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilledButton(key: _doneKey, onPressed: () => _done(screen), child: const Text('Concluir')),
              ),
            ],
          ),
          body: Stack(children: [
            Positioned.fill(
              child: HmiCanvas(
                screen: screen,
                editMode: true,
                selectedId: _selected,
                onSelect: (id) => setState(() => _selected = id),
                onChanged: (e) => _replace(screen, e),
                onEmptyCellTap: (x, y) => _lastEmptyCell = (x, y),
                keyFor: (e) => e.id == firstId ? _firstElementKey : null,
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
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(color: Ind.surface, border: Border(top: BorderSide(color: Ind.line))),
              child: selected == null
                  ? Row(children: [
                      Expanded(
                        child: FilledButton.icon(
                          key: _paletteKey,
                          onPressed: () => _add(screen),
                          icon: const Icon(Icons.add_rounded),
                          label: const Text('Elemento'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      KeyedSubtree(
                        key: _settingsKey,
                        child: _ToolButton(icon: Icons.tune_rounded, tooltip: 'Regras da tela', onTap: () => _settings(screen)),
                      ),
                    ])
                  : Row(children: [
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
                      const SizedBox(width: 8),
                      _ToolButton(icon: Icons.add_rounded, tooltip: 'Outro elemento', onTap: () => _add(screen)),
                    ]),
            ),
          ),
        ),
      ),
    );
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

/// Regras da tela: nome, só acompanhamento, confirmação de escrita, apagar.
class _ScreenSettingsSheet extends StatelessWidget {
  const _ScreenSettingsSheet({required this.screenId});
  final String screenId;

  @override
  Widget build(BuildContext context) {
    final c = AppScope.watch(context).controller;
    final s = c.project.screen(screenId);
    if (s == null) return const SizedBox(height: 80);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
            // Grade fina: mais variáveis por tela e encaixe mais preciso. A troca
            // não mexe em nada na tela (ver HmiScreen.withColumns).
            Text('Grade', style: TextStyle(color: Ind.textDim, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            SegmentedButton<int>(
              key: const ValueKey('grade-da-tela'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: HmiScreen.defaultColumns, label: Text('Normal'), icon: Icon(Icons.grid_view_rounded)),
                ButtonSegment(value: HmiScreen.fineColumns, label: Text('Fina'), icon: Icon(Icons.apps_rounded)),
              ],
              selected: {s.fine ? HmiScreen.fineColumns : HmiScreen.defaultColumns},
              onSelectionChanged: (sel) {
                final next = s.withColumns(sel.first);
                if (next != null) {
                  c.saveScreen(next);
                } else {
                  final n = s.oddElements;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('$n elemento${n == 1 ? '' : 's'} usa${n == 1 ? '' : 'm'} meia célula da grade normal. Ajuste o tamanho ou a posição para voltar.')));
                }
              },
            ),
            const SizedBox(height: 6),
            Text(s.fine ? 'Cabe o dobro de elementos em cada direção. Bom para telas com muitas variáveis.' : 'Elementos maiores, fáceis de tocar.',
                style: TextStyle(color: Ind.textMuted, fontSize: 13)),
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
                if (context.mounted) Navigator.of(context)..pop()..pop();
              },
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('Apagar a tela'),
            ),
          ],
        ),
      ),
    );
  }
}
