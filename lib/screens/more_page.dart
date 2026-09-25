import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app/app_info.dart';
import '../app/app_scope.dart';
import '../core/theme/app_theme.dart';
import '../models/project.dart';
import '../services/demo/demo_project.dart';
import '../services/storage/project_repository.dart';
import '../widgets/common/common.dart';
import '../widgets/hmi/write_actions.dart';
import '../widgets/tour/tour.dart';
import 'devices/devices_page.dart';
import 'editor/screen_editor_page.dart';
import 'screen_run_page.dart';
import 'screens_page.dart';
import 'shell.dart';
import 'tags/tags_page.dart';
import 'tours.dart';

/// Aba "Mais": projeto (exportar/importar), tutoriais e sobre.
class MorePage extends StatelessWidget {
  const MorePage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppScope.watch(context).controller;
    final p = c.project;

    return Scaffold(
      appBar: AppBar(title: const Text('Mais')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const SectionHeader('Projeto'),
          ListTile(
            leading: const Icon(Icons.folder_open_outlined, color: Ind.accent),
            title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('${p.screens.length} telas · ${p.tags.length} variáveis'),
            trailing: const Icon(Icons.edit_outlined, size: 20),
            onTap: () async {
              final name = await askText(context, title: 'Nome do projeto', label: 'Nome', initial: p.name);
              if (name != null) c.rename(name);
            },
          ),
          ListTile(
            key: const ValueKey('exportar'),
            leading: const Icon(Icons.ios_share_rounded),
            title: const Text('Exportar projeto'),
            onTap: () => _export(context, p),
          ),
          ListTile(
            key: const ValueKey('importar'),
            leading: const Icon(Icons.file_open_outlined),
            title: const Text('Importar projeto'),
            onTap: () => _import(context),
          ),
          ListTile(
            leading: const Icon(Icons.smart_toy_outlined),
            title: const Text('Restaurar a demonstração'),
            onTap: () => _replace(context, DemoProject.build(), 'Restaurar a demonstração?'),
          ),
          ListTile(
            leading: const Icon(Icons.note_add_outlined),
            title: const Text('Começar do zero'),
            onTap: () => _replace(context, const Project(name: 'Meu projeto'), 'Começar um projeto vazio?'),
          ),
          const SectionHeader('Tutoriais'),
          for (final (id, title, _) in Tours.catalog)
            ListTile(
              key: ValueKey('tutorial-$id'),
              leading: const Icon(Icons.school_outlined),
              title: Text(title),
              trailing: const Icon(Icons.play_circle_outline_rounded, color: Ind.accent),
              onTap: () => _openTour(context, id),
            ),
          ListTile(
            leading: const Icon(Icons.replay_rounded),
            title: const Text('Rever todos os tutoriais'),
            onTap: () async {
              await TourMemory.resetAll();
              if (context.mounted) WriteActions.toast(context, 'Pronto: os tutoriais vão aparecer de novo.');
            },
          ),
          const SectionHeader('Vídeos'),
          const ListTile(
            leading: Icon(Icons.ondemand_video_outlined),
            title: Text('Vídeos'),
            subtitle: Text('Em breve'),
            enabled: AppInfo.videosUrl != null,
          ),
          const SectionHeader('Sobre'),
          ListTile(
            leading: const Icon(Icons.info_outline_rounded),
            title: const Text('${AppInfo.name} · versão ${AppInfo.version}'),
            onTap: () => showLicensePage(context: context, applicationName: AppInfo.name, applicationVersion: AppInfo.version),
          ),
        ],
      ),
    );
  }

  static void _openTour(BuildContext context, String id) {
    final project = AppScope.of(context).controller.project;
    final screen = project.screen(DemoProject.operationScreenId) ?? project.screens.firstOrNull;
    Widget? page;
    switch (id) {
      case 'inicio':
        Shell.of(context)?.startIntroTour();
        return;
      case 'operar':
        if (screen != null) page = ScreenRunPage(screenId: screen.id, startTour: true);
      case 'editor':
        if (screen != null) page = ScreenEditorPage(screenId: screen.id, startTour: true);
      case 'equipamentos':
        page = const DevicesPage(startTour: true);
      case 'variaveis':
        page = const TagsPage(startTour: true);
    }
    if (page == null) {
      WriteActions.toast(context, 'Crie uma tela primeiro — ou restaure a demonstração.');
      return;
    }
    Navigator.push(context, MaterialPageRoute(builder: (_) => page!));
  }

  static Future<void> _export(BuildContext context, Project p) async {
    try {
      final uri = await FilePicker.saveFile(
        dialogTitle: 'Exportar projeto',
        fileName: ProjectRepository.exportName(p),
        bytes: ProjectRepository.encode(p),
        mimeType: 'application/json',
      );
      if (uri != null && context.mounted) WriteActions.toast(context, 'Projeto exportado.');
    } catch (e) {
      if (context.mounted) WriteActions.toast(context, 'Não consegui exportar: $e', error: true);
    }
  }

  static Future<void> _import(BuildContext context) async {
    try {
      final files = await FilePicker.pickFiles(dialogTitle: 'Importar projeto');
      if (files.isEmpty || !context.mounted) return;
      final project = ProjectRepository.decode(await files.first.readAsBytes());
      if (!context.mounted) return;
      await _replace(context, project,
          'Importar "${project.name}"? (${project.devices.length} equipamentos · ${project.tags.length} variáveis · ${project.screens.length} telas)');
    } on ProjectFormatError catch (e) {
      if (context.mounted) WriteActions.toast(context, e.message, error: true);
    } catch (e) {
      if (context.mounted) WriteActions.toast(context, 'Não consegui abrir o arquivo.', error: true);
    }
  }

  static Future<void> _replace(BuildContext context, Project next, String question) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.swap_horiz_rounded, color: Ind.accent),
        title: Text(question),
        content: const Text('O projeto atual será substituído. Se quiser guardar uma cópia dele, exporte antes.', style: TextStyle(height: 1.4)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Substituir')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await AppScope.of(context).controller.replace(next);
    if (context.mounted) WriteActions.toast(context, 'Projeto "${next.name}" aberto.');
  }
}
