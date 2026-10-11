import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app/app_info.dart';
import '../app/app_scope.dart';
import '../app/appearance.dart';
import '../core/theme/app_theme.dart';
import '../models/project.dart';
import '../services/demo/demo_project.dart';
import '../services/storage/project_repository.dart';
import '../widgets/common/common.dart';
import '../widgets/hmi/write_actions.dart';
import '../widgets/tour/tour.dart';
import 'devices/devices_page.dart';
import 'editor/screen_editor_page.dart';
import 'logs/logs_page.dart';
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
            leading: Icon(Icons.folder_open_outlined, color: Ind.accent),
            title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('${p.screens.length} telas · ${p.tags.length} variáveis'),
            trailing: const Icon(Icons.edit_outlined, size: 20),
            onTap: () async {
              final name = await askText(context, title: 'Nome do projeto', label: 'Nome', initial: p.name);
              if (name != null) c.rename(name);
            },
          ),
          // Enviar é o caso comum (o projeto vai por WhatsApp para outro
          // celular); salvar em arquivo fica para backup.
          ListTile(
            key: const ValueKey('enviar'),
            leading: const Icon(Icons.share_rounded),
            title: const Text('Enviar projeto'),
            subtitle: const Text('WhatsApp, e-mail, Drive…'),
            onTap: () => _share(context, p),
          ),
          ListTile(
            key: const ValueKey('exportar'),
            leading: const Icon(Icons.save_alt_rounded),
            title: const Text('Salvar em arquivo'),
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
          const SectionHeader('Dados'),
          ListTile(
            key: const ValueKey('registros'),
            leading: const Icon(Icons.timeline_rounded),
            title: const Text('Registros'),
            subtitle: Text(_logsSummary(p)),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LogsPage())),
          ),
          const SectionHeader('Aparência'),
          Padding(
            padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 4),
            child: ValueListenableBuilder<Appearance>(
              valueListenable: AppearanceController.instance,
              builder: (context, a, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ChoiceCards<Appearance>(
                  options: const [
                    ChoiceOption(value: Appearance.auto, title: 'Auto', icon: Icons.brightness_auto_outlined),
                    ChoiceOption(value: Appearance.claro, title: 'Claro', icon: Icons.light_mode_outlined),
                    ChoiceOption(value: Appearance.escuro, title: 'Escuro', icon: Icons.dark_mode_outlined),
                  ],
                  selected: a,
                  columns: 3,
                  onChanged: AppearanceController.instance.set,
                ),
                const SizedBox(height: 10),
                Text(
                  'Claro lê melhor de dia e no sol; escuro, à noite e em sala fechada. Auto segue o claro/escuro do celular. Vale só para este aparelho.',
                  style: TextStyle(color: Ind.textMuted, fontSize: 13, height: 1.4),
                ),
              ]),
            ),
          ),
          const SectionHeader('Tutoriais'),
          for (final (id, title, _) in Tours.catalog)
            ListTile(
              key: ValueKey('tutorial-$id'),
              leading: const Icon(Icons.school_outlined),
              title: Text(title),
              trailing: Icon(Icons.play_circle_outline_rounded, color: Ind.accent),
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
          // Sem seção "Vídeos · Em breve": numa demonstração, item que não
          // faz nada parece coisa inacabada. Volta quando houver vídeo.
          const SectionHeader('Sobre'),
          ListTile(
            leading: const Icon(Icons.info_outline_rounded),
            title: const Text('${AppInfo.name} · versão ${AppInfo.version}'),
            subtitle: const Text('Powered by ${AppInfo.company}'),
            onTap: () => showLicensePage(context: context, applicationName: AppInfo.name, applicationVersion: AppInfo.version),
          ),
        ],
      ),
    );
  }

  /// "Histórico em gráfico e planilha" ou "2 registros · 1 ligado".
  static String _logsSummary(Project p) {
    final n = p.logGroups.length, on = p.logGroups.where((g) => g.enabled).length;
    if (n == 0) return 'Histórico em gráfico e planilha';
    return '${n == 1 ? '1 registro' : '$n registros'} · ${on == 0 ? 'nenhum ligado' : on == 1 ? '1 ligado' : '$on ligados'}';
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

  /// Grava o projeto num arquivo temporário e abre a folha de compartilhar do
  /// Android. Quem recebe abre o arquivo em "Importar projeto".
  static Future<void> _share(BuildContext context, Project p) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/${ProjectRepository.exportName(p)}');
      await file.writeAsBytes(ProjectRepository.encode(p), flush: true);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'application/json')],
        subject: 'Projeto ${p.name} — ${AppInfo.name}',
        text: 'Projeto "${p.name}" do ${AppInfo.name}. Para abrir: Mais → Importar projeto.',
      ));
    } catch (e) {
      if (context.mounted) WriteActions.toast(context, 'Não consegui enviar: $e', error: true);
    }
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
        icon: Icon(Icons.swap_horiz_rounded, color: Ind.accent),
        title: Text(question),
        content: const Text('O projeto atual será substituído. Se quiser guardar uma cópia dele, use "Salvar em arquivo" antes.', style: TextStyle(height: 1.4)),
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
