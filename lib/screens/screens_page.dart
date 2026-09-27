import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/app_scope.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/ids.dart';
import '../models/hmi_screen.dart';
import '../models/project.dart';
import '../widgets/common/common.dart';
import '../widgets/hmi/element_catalog.dart';
import '../widgets/tour/tour.dart';
import 'editor/screen_editor_page.dart';
import 'screen_run_page.dart';

/// Lista de telas — a página inicial do app.
///
/// Cada cartão mostra a **planta** da tela (miniatura com os blocos de cada
/// elemento no lugar), para reconhecer a tela de olho, e os equipamentos que
/// ela usa com o selo de comunicação.
class ScreensPage extends StatelessWidget {
  const ScreensPage({super.key, required this.screensKey, required this.addKey, required this.helpKey});

  final GlobalKey screensKey;
  final GlobalKey addKey;
  final GlobalKey helpKey;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.watch(context);
    final project = scope.controller.project;
    final screens = project.screens;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Telas'),
        actions: [KeyedSubtree(key: helpKey, child: const HelpButton())],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: addKey,
        onPressed: () => createScreen(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Nova tela'),
      ),
      body: screens.isEmpty
          ? KeyedSubtree(
              key: screensKey,
              child: EmptyState(
                icon: Icons.dashboard_customize_outlined,
                title: 'Nenhuma tela ainda',
                body: 'Crie a primeira tela e coloque nela botões, mostradores e gráficos ligados às variáveis da máquina.',
                action: FilledButton.icon(onPressed: () => createScreen(context), icon: const Icon(Icons.add_rounded), label: const Text('Criar tela')),
              ),
            )
          : LayoutBuilder(builder: (context, box) {
              final cols = (box.maxWidth / 340).floor().clamp(1, 4);
              return GridView.builder(
                padding: const EdgeInsets.fromLTRB(Ind.page, 8, Ind.page, 110),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  mainAxisSpacing: Ind.space,
                  crossAxisSpacing: Ind.space,
                  mainAxisExtent: 220,
                ),
                itemCount: screens.length,
                itemBuilder: (context, i) => KeyedSubtree(
                  key: i == 0 ? screensKey : null,
                  child: _ScreenCard(screen: screens[i], project: project),
                ),
              );
            }),
    );
  }

  /// Pergunta o nome e abre o editor já na tela nova.
  static Future<void> createScreen(BuildContext context) async {
    final name = await askText(context, title: 'Nova tela', label: 'Nome da tela', hint: 'Ex.: Cortadora — operação');
    if (name == null || !context.mounted) return;
    final screen = HmiScreen(id: newId('s'), name: name);
    AppScope.of(context).controller.saveScreen(screen);
    await Navigator.push(context, MaterialPageRoute(builder: (_) => ScreenEditorPage(screenId: screen.id)));
  }
}

class _ScreenCard extends StatelessWidget {
  const _ScreenCard({required this.screen, required this.project});
  final HmiScreen screen;
  final Project project;

  // Cartão enxuto: planta + nome + uma linha discreta. O estado de conexão
  // mora na própria tela (quem abre, vê); aqui só atrapalhava a leitura.
  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('tela-${screen.id}'),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ScreenRunPage(screenId: screen.id))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                color: Ind.surfaceHigh,
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                child: _ScreenThumb(screen: screen),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 14),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(screen.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
                        // Tela vazia: a miniatura já diz "Tela vazia — toque
                        // para montar"; "0 elementos" embaixo só repetia.
                        if (screen.elements.isNotEmpty || screen.readOnly) ...[
                        const SizedBox(height: 4),
                        Row(children: [
                          if (screen.readOnly) ...[
                            const Tooltip(message: 'Só acompanhamento', child: Icon(Icons.visibility_outlined, size: 15, color: Ind.textMuted)),
                            const SizedBox(width: 6),
                          ],
                          Text(
                              switch (screen.elements.length) { 0 => 'Só acompanhamento', 1 => '1 elemento', final n => '$n elementos' },
                              style: const TextStyle(color: Ind.textMuted, fontSize: 13)),
                        ]),
                        ],
                      ],
                    ),
                  ),
                  _ScreenMenu(screen: screen),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScreenMenu extends StatelessWidget {
  const _ScreenMenu({required this.screen});
  final HmiScreen screen;

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context).controller;
    return PopupMenuButton<String>(
      tooltip: 'Opções da tela',
      onSelected: (v) async {
        switch (v) {
          case 'edit':
            await Navigator.push(context, MaterialPageRoute(builder: (_) => ScreenEditorPage(screenId: screen.id)));
          case 'rename':
            final name = await askText(context, title: 'Renomear tela', label: 'Nome da tela', initial: screen.name);
            if (name != null) c.saveScreen(screen.copyWith(name: name));
          case 'duplicate':
            c.saveScreen(HmiScreen(
              id: newId('s'),
              name: '${screen.name} (cópia)',
              columns: screen.columns,
              readOnly: screen.readOnly,
              confirmWrites: screen.confirmWrites,
              elements: [
                for (final e in screen.elements)
                  HmiElement(id: newId('e'), type: e.type, x: e.x, y: e.y, w: e.w, h: e.h, props: Map.of(e.props)),
              ],
            ));
          case 'delete':
            if (await confirmDelete(context, title: 'Apagar "${screen.name}"?', body: 'A tela e seus ${screen.elements.length} elementos somem. Equipamentos e variáveis continuam.')) {
              c.deleteScreen(screen.id);
            }
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'edit', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Editar'))),
        PopupMenuItem(value: 'rename', child: ListTile(leading: Icon(Icons.drive_file_rename_outline), title: Text('Renomear'))),
        PopupMenuItem(value: 'duplicate', child: ListTile(leading: Icon(Icons.copy_all_outlined), title: Text('Duplicar'))),
        PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline, color: Ind.alarm), title: Text('Apagar'))),
      ],
    );
  }
}

/// Planta da tela: um bloco por elemento, com o ícone do tipo.
class _ScreenThumb extends StatelessWidget {
  const _ScreenThumb({required this.screen});
  final HmiScreen screen;

  @override
  Widget build(BuildContext context) {
    if (screen.elements.isEmpty) {
      return const Center(child: Text('Tela vazia — toque para montar', style: TextStyle(color: Ind.textMuted, fontSize: 12)));
    }
    // Mostra o topo da tela (~5 linhas), centralizado e cortando embaixo.
    // Encolher a tela inteira deixava a planta minúscula num canto; usar a
    // largura cheia mostrava só o título.
    return LayoutBuilder(builder: (context, box) {
      final cell = math.min(box.maxWidth / screen.columns, box.maxHeight / 5);
      final visibleRows = (box.maxHeight / cell).ceil();
      final left = (box.maxWidth - cell * screen.columns) / 2;
      return ClipRect(
        child: Stack(children: [
          for (final e in screen.elements.where((e) => e.y < visibleRows))
            Positioned(
              left: left + e.x * cell + 1.5,
              top: e.y * cell + 1.5,
              width: e.w * cell - 3,
              height: e.h * cell - 3,
              child: Container(
                decoration: BoxDecoration(color: Ind.surfaceHigh, borderRadius: BorderRadius.circular(3), border: Border.all(color: Ind.line)),
                child: cell * e.h > 14 && cell * e.w > 14
                    ? Icon(ElementCatalog.of(e.type).icon, size: (cell * 0.5).clamp(8.0, 18.0), color: e.type == ElementType.button ? Ind.accent : Ind.textMuted)
                    : null,
              ),
            ),
        ]),
      );
    });
  }
}

/// Pergunta um texto curto (nome de tela, de equipamento...).
Future<String?> askText(BuildContext context, {required String title, required String label, String? hint, String initial = ''}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      void done() {
        final t = ctrl.text.trim();
        if (t.isNotEmpty) Navigator.pop(ctx, t);
      }

      return AlertDialog(
        title: Text(title),
        content: TextField(
          key: const ValueKey('campo-nome'),
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: label, hintText: hint),
          onSubmitted: (_) => done(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(key: const ValueKey('ok-nome'), onPressed: done, child: const Text('OK')),
        ],
      );
    },
  );
}
