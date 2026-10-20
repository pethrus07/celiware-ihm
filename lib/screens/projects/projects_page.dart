// Aba Projetos: a lista dos projetos guardados no aparelho (reunião de
// 19–20/10/2026 — "vai ser só o projeto no lugar de tela e vai ficar uma
// lista de projetos; dentro da lista de projetos, vai ver a lista de telas").
//
// Cada projeto é o mesmo de sempre — equipamentos, variáveis, telas, regras,
// registros, receitas e câmeras — guardado na sua pasta. Tocar abre o
// projeto (as telas dele); Equipamentos, Variáveis, Ferramentas e Alarmes
// passam a mostrar as coisas dele. Criar e importar sempre ACRESCENTAM: nada
// substitui outro projeto (o "Começar do zero" antigo apagou um projeto do
// cliente). Apagar pergunta antes e diz o que vai junto.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/app_info.dart';
import '../../app/app_scope.dart';
import '../../app/project_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../models/project.dart';
import '../../services/demo/demo_project.dart';
import '../../services/storage/project_repository.dart';
import '../../widgets/common/common.dart';
import '../../widgets/hmi/write_actions.dart';
import '../../widgets/tour/tour.dart';
import '../screens_page.dart';
import '../settings_page.dart';
import '../tours.dart';

/// Lista de projetos. [onOpened] mostra as telas do projeto que acabou de
/// abrir (a casca troca a aba para "dentro do projeto").
class ProjectsPage extends StatefulWidget {
  const ProjectsPage({super.key, required this.onOpened});

  final VoidCallback onOpened;

  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends State<ProjectsPage> {
  final _listKey = GlobalKey();
  final _addKey = GlobalKey();
  final _settingsKey = GlobalKey();

  /// Um toque por vez: abrir um projeto religa as conexões.
  bool _busy = false;

  Future<void> _run(Future<void> Function() f) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await f();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(String id) => _run(() async {
        await AppScope.of(context).controller.open(id);
        if (mounted) widget.onOpened();
      });

  @override
  Widget build(BuildContext context) {
    final c = AppScope.watch(context).controller;
    final projects = c.projects;
    return TourHost(
      spec: Tours.projetos(list: _listKey, add: _addKey, settings: _settingsKey),
      autoStart: false,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Projetos'),
          actions: [KeyedSubtree(key: _settingsKey, child: const SettingsButton()), const HelpButton()],
        ),
        floatingActionButton: c.manyProjects
            ? FloatingActionButton.extended(
                key: _addKey,
                onPressed: _busy ? null : () => _create(context),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Novo projeto'),
              )
            : null,
        body: ListView.separated(
          padding: const EdgeInsets.fromLTRB(Ind.page, 8, Ind.page, 110),
          itemCount: projects.length,
          separatorBuilder: (_, _) => const SizedBox(height: Ind.space),
          itemBuilder: (context, i) => KeyedSubtree(
            key: i == 0 ? _listKey : null,
            child: _ProjectCard(
              entry: projects[i],
              open: projects[i].id == c.openId || !c.manyProjects,
              onTap: _busy ? null : () => _open(projects[i].id),
            ),
          ),
        ),
      ),
    );
  }

  /// "Novo projeto": em branco, a demonstração ou de um arquivo.
  Future<void> _create(BuildContext context) async {
    final kind = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, Ind.space),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Novo projeto', style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: Ind.space),
            ChoiceCards<String>(
              columns: 1,
              selected: '',
              onChanged: (v) => Navigator.pop(ctx, v),
              options: const [
                ChoiceOption(value: 'branco', title: 'Em branco', subtitle: 'Equipamentos, variáveis e telas do zero.', icon: Icons.note_add_outlined),
                ChoiceOption(value: 'demonstracao', title: 'Demonstração', subtitle: 'A cortadora simulada, para mexer à vontade.', icon: Icons.smart_toy_outlined),
                ChoiceOption(value: 'arquivo', title: 'De um arquivo', subtitle: 'Projeto recebido por WhatsApp, e-mail ou Drive.', icon: Icons.file_open_outlined),
              ],
            ),
          ]),
        ),
      ),
    );
    if (kind == null || !context.mounted) return;
    final c = AppScope.of(context).controller;
    switch (kind) {
      case 'branco':
        final name = await askText(context, title: 'Novo projeto', label: 'Nome do projeto', hint: 'Ex.: Linha 2');
        if (name == null || !context.mounted) return;
        await _run(() => c.createProject(Project(name: name)));
      case 'demonstracao':
        await _run(() => c.createProject(DemoProject.build()));
      case 'arquivo':
        await _import(context);
        return;
    }
    if (context.mounted) widget.onOpened();
  }

  /// Importar = acrescentar um projeto (nunca substitui o aberto).
  Future<void> _import(BuildContext context) async {
    try {
      final files = await FilePicker.pickFiles(dialogTitle: 'Abrir projeto');
      if (files.isEmpty || !context.mounted) return;
      final project = ProjectRepository.decode(await files.first.readAsBytes());
      if (!context.mounted) return;
      final c = AppScope.of(context).controller;
      await _run(() => c.importProject(project));
      if (!context.mounted) return;
      WriteActions.toast(context, 'Projeto "${c.project.name}" acrescentado à lista.');
      widget.onOpened();
    } on ProjectFormatError catch (e) {
      if (context.mounted) WriteActions.toast(context, e.message, error: true);
    } catch (e) {
      if (context.mounted) WriteActions.toast(context, 'Não consegui abrir o arquivo.', error: true);
    }
  }
}

/// Um projeto na lista: nome e o resumo do que tem. O aberto tem o fundo na
/// cor de seleção (o mesmo sinal do item aberto nas outras listas).
class _ProjectCard extends StatelessWidget {
  const _ProjectCard({required this.entry, required this.open, required this.onTap});
  final ProjectEntry entry;
  final bool open;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      color: open ? Ind.accent.withValues(alpha: Ind.isDark ? 0.14 : 0.10) : null,
      child: InkWell(
        key: ValueKey('projeto-${entry.id}'),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 76),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 4, 14),
            child: Row(children: [
              Semantics(
                label: open ? 'Projeto aberto' : null,
                child: Icon(open ? Icons.folder_open_rounded : Icons.folder_outlined, color: open ? Ind.accent : Ind.textDim),
              ),
              const SizedBox(width: Ind.space),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(entry.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
                  const SizedBox(height: 4),
                  Text(entry.summary, key: ValueKey('resumo-${entry.id}'), style: TextStyle(color: Ind.textMuted, fontSize: 13)),
                ]),
              ),
              _ProjectMenu(entry: entry),
            ]),
          ),
        ),
      ),
    );
  }
}

class _ProjectMenu extends StatelessWidget {
  const _ProjectMenu({required this.entry});
  final ProjectEntry entry;

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context).controller;
    final canDelete = c.manyProjects && c.projects.length > 1;
    return PopupMenuButton<String>(
      key: ValueKey('menu-projeto-${entry.id}'),
      tooltip: 'Opções do projeto',
      onSelected: (v) async {
        switch (v) {
          case 'rename':
            final name = await askText(context, title: 'Renomear projeto', label: 'Nome do projeto', initial: entry.name);
            if (name == null) return;
            if (c.manyProjects) {
              await c.renameProject(entry.id, name);
            } else {
              c.rename(name);
            }
          case 'duplicate':
            await c.duplicateProject(entry.id);
            if (context.mounted) WriteActions.toast(context, 'Cópia de "${entry.name}" criada.');
          case 'share':
            final p = await c.exportProject(entry.id);
            if (p != null && context.mounted) await ProjectFiles.share(context, p);
          case 'export':
            final p = await c.exportProject(entry.id);
            if (p != null && context.mounted) await ProjectFiles.save(context, p);
          case 'delete':
            final ok = await confirmDelete(
              context,
              title: 'Apagar "${entry.name}"?',
              body: 'Somem deste celular o projeto, os históricos de alarmes, '
                  'regras e receitas e os registros gravados dele. Os outros projetos não mudam. '
                  'Para guardar uma cópia, use "Salvar em arquivo" antes.',
            );
            if (ok) await c.deleteProject(entry.id);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'rename', child: ListTile(leading: Icon(Icons.drive_file_rename_outline), title: Text('Renomear'))),
        if (c.manyProjects) const PopupMenuItem(value: 'duplicate', child: ListTile(leading: Icon(Icons.copy_all_outlined), title: Text('Duplicar'))),
        // Enviar é o caso comum (o projeto vai por WhatsApp para outro
        // celular); salvar em arquivo fica para backup.
        const PopupMenuItem(value: 'share', child: ListTile(leading: Icon(Icons.share_rounded), title: Text('Enviar'))),
        const PopupMenuItem(value: 'export', child: ListTile(leading: Icon(Icons.save_alt_rounded), title: Text('Salvar em arquivo'))),
        if (canDelete) PopupMenuItem(value: 'delete', child: ListTile(leading: Icon(Icons.delete_outline, color: Ind.alarm), title: const Text('Apagar'))),
      ],
    );
  }
}

/// Enviar e salvar um projeto como arquivo (`.ihm.json`, o mesmo formato
/// guardado no aparelho).
class ProjectFiles {
  ProjectFiles._();

  /// Grava num arquivo temporário e abre a folha de compartilhar do Android.
  /// Quem recebe abre em Projetos → Novo projeto → De um arquivo.
  static Future<void> share(BuildContext context, Project p) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/${ProjectRepository.exportName(p)}');
      await file.writeAsBytes(ProjectRepository.encode(p), flush: true);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'application/json')],
        subject: 'Projeto ${p.name} — ${AppInfo.name}',
        text: 'Projeto "${p.name}" do ${AppInfo.name}. Para abrir: Projetos → Novo projeto → De um arquivo.',
      ));
    } catch (e) {
      if (context.mounted) WriteActions.toast(context, 'Não consegui enviar: $e', error: true);
    }
  }

  static Future<void> save(BuildContext context, Project p) async {
    try {
      final uri = await FilePicker.saveFile(
        dialogTitle: 'Salvar projeto',
        fileName: ProjectRepository.exportName(p),
        bytes: ProjectRepository.encode(p),
        mimeType: 'application/json',
      );
      if (uri != null && context.mounted) WriteActions.toast(context, 'Projeto salvo.');
    } catch (e) {
      if (context.mounted) WriteActions.toast(context, 'Não consegui salvar: $e', error: true);
    }
  }
}
