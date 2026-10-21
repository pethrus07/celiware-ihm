// Aba Projetos: a planta e a lista dos projetos dela (reunião de 19–20/10/2026
// — "vai ser só o projeto no lugar de tela e vai ficar uma lista de projetos;
// dentro da lista de projetos, vai ver a lista de telas"; decisões D6, D7 e
// D10: Planta > Projetos, uma máquina por projeto).
//
// Cada projeto é o mesmo de sempre — equipamentos, variáveis, telas, regras,
// registros, receitas e câmeras — guardado na sua pasta. Tocar abre o
// projeto (as telas dele); Equipamentos, Variáveis, Ferramentas e Alarmes
// passam a mostrar as coisas dele. Criar e importar um projeto sempre
// ACRESCENTAM (o "Começar do zero" antigo apagou um projeto do cliente).
// O título é o nome da planta; o menu dela (⋮) envia ou salva a planta
// inteira e cria uma planta nova — o único jeito de trocar tudo, com
// confirmação forte e cópia automática da planta atual antes. As cópias se
// abrem de novo em "Cópias de segurança", no mesmo menu (backups_page.dart).

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/app_info.dart';
import '../../app/app_scope.dart';
import '../../app/project_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../models/plant.dart';
import '../../models/project.dart';
import '../../services/demo/demo_project.dart';
import '../../services/storage/project_repository.dart';
import '../../widgets/common/common.dart';
import '../../widgets/hmi/write_actions.dart';
import '../../widgets/tour/tour.dart';
import '../screens_page.dart';
import '../settings_page.dart';
import '../tours.dart';
import 'backups_page.dart';

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
          title: c.manyProjects ? AdaptiveTitle(c.plantName) : const Text('Projetos'),
          actions: [
            KeyedSubtree(key: _settingsKey, child: const SettingsButton()),
            const HelpButton(),
            if (c.manyProjects) _PlantMenu(busy: _busy, onReplaced: widget.onOpened),
          ],
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
                ChoiceOption(value: 'arquivo', title: 'De um arquivo', subtitle: 'Projeto ou planta enviados por WhatsApp, e-mail ou Drive.', icon: Icons.file_open_outlined),
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

  /// Importar um projeto = acrescentar (nunca substitui o aberto). Arquivo
  /// de planta inteira: somar os projetos dela (o padrão) ou substituir a
  /// planta, com confirmação forte e cópia antes.
  Future<void> _import(BuildContext context) async {
    try {
      final files = await FilePicker.pickFiles(dialogTitle: 'Abrir projeto ou planta');
      if (files.isEmpty || !context.mounted) return;
      final file = ProjectRepository.decodeFile(await files.first.readAsBytes());
      if (!context.mounted) return;
      final c = AppScope.of(context).controller;
      if (file is PlantFile) {
        await _importPlant(context, file.plant);
        return;
      }
      await _run(() => c.importProject((file as ProjectFile).project));
      if (!context.mounted) return;
      WriteActions.toast(context, 'Projeto "${c.project.name}" acrescentado à planta.');
      widget.onOpened();
    } on ProjectFormatError catch (e) {
      if (context.mounted) WriteActions.toast(context, e.message, error: true);
    } catch (e) {
      if (context.mounted) WriteActions.toast(context, 'Não consegui abrir o arquivo.', error: true);
    }
  }
}

extension on _ProjectsPageState {
  Future<void> _importPlant(BuildContext context, Plant plant) async {
    final c = AppScope.of(context).controller;
    final n = plant.projects.length;
    final projetos = n == 1 ? '1 projeto' : '$n projetos';
    final choice = await showDialog<String>(
      context: context,
      builder: (_) => DecisionDialog<String>(
        title: 'Planta "${plant.name}" ($projetos)',
        body: 'Somar os projetos dela aos desta planta não apaga nada. Substituir troca a planta inteira.',
        actions: const [
          DialogAction(label: 'Cancelar', value: ''),
          DialogAction(label: 'Substituir', value: 'substituir', kind: DialogActionKind.destructive, key: ValueKey('substituir-planta')),
          DialogAction(label: 'Somar', value: 'somar', kind: DialogActionKind.primary, key: ValueKey('somar-planta')),
        ],
      ),
    );
    if (!context.mounted) return;
    if (choice == 'somar') {
      var added = 0;
      await _run(() async => added = await c.addPlantProjects(plant));
      if (context.mounted) WriteActions.toast(context, added == 1 ? '1 projeto somado à planta.' : '$added projetos somados à planta.');
    } else if (choice == 'substituir') {
      await _PlantMenu.replace(context, plant, onReplaced: widget.onOpened);
    }
  }
}

/// Menu da planta (⋮ do topo): renomear, enviar, salvar em arquivo e
/// "Nova planta".
class _PlantMenu extends StatelessWidget {
  const _PlantMenu({required this.busy, required this.onReplaced});
  final bool busy;
  final VoidCallback onReplaced;

  /// Troca a planta inteira, com a pergunta forte (diz quantos projetos
  /// saem e onde fica a cópia) e a cópia automática antes.
  static Future<void> replace(BuildContext context, Plant next, {required VoidCallback onReplaced, String title = 'Substituir a planta inteira?'}) async {
    final c = AppScope.of(context).controller;
    final n = c.projects.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => DecisionDialog<bool>(
        title: title,
        body: '${n == 1 ? 'O projeto desta planta sai do app, com os históricos e os registros gravados dele.' : 'Os $n projetos desta planta saem do app, com os históricos e os registros gravados deles.'} '
            'Antes, a planta inteira é guardada numa cópia no celular. Para abrir de novo: menu da planta (⋮) → Cópias de segurança.',
        actions: const [
          DialogAction(label: 'Cancelar', value: false),
          DialogAction(label: 'Substituir', value: true, kind: DialogActionKind.destructive, key: ValueKey('confirmar-substituir-planta')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await c.replacePlant(next);
    if (!context.mounted) return;
    WriteActions.toast(context, 'Pronto. A planta anterior está em Cópias de segurança.');
    onReplaced();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppScope.of(context).controller;
    return PopupMenuButton<String>(
      key: const ValueKey('menu-planta'),
      tooltip: 'Opções da planta',
      enabled: !busy,
      onSelected: (v) async {
        switch (v) {
          case 'rename':
            final name = await askText(context, title: 'Renomear planta', label: 'Nome da planta', initial: c.plantName);
            if (name != null) await c.renamePlant(name);
          case 'share':
            final p = await c.exportPlant();
            if (context.mounted) await ProjectFiles.sharePlant(context, p);
          case 'export':
            final p = await c.exportPlant();
            if (context.mounted) await ProjectFiles.savePlant(context, p);
          case 'backups':
            await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const BackupsPage()));
          case 'new':
            await replace(context, const Plant(), onReplaced: onReplaced, title: 'Começar uma planta nova?');
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'rename', child: ListTile(leading: Icon(Icons.drive_file_rename_outline), title: Text('Renomear planta'))),
        PopupMenuItem(value: 'share', child: ListTile(leading: Icon(Icons.share_rounded), title: Text('Enviar a planta'))),
        PopupMenuItem(value: 'export', child: ListTile(leading: Icon(Icons.save_alt_rounded), title: Text('Salvar a planta em arquivo'))),
        // As cópias automáticas ficam na área privada do app, que o
        // seletor de arquivos não vê: este é o caminho de volta a elas.
        PopupMenuItem(value: 'backups', child: ListTile(leading: Icon(Icons.history_rounded), title: Text('Cópias de segurança'))),
        PopupMenuItem(value: 'new', child: ListTile(leading: Icon(Icons.restart_alt_rounded), title: Text('Nova planta'))),
      ],
    );
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
            // Regras da planta que citam o projeto: desligadas ao apagar.
            final rules = c.plantRulesUsing(entry.id).length;
            final ok = await confirmDelete(
              context,
              title: 'Apagar "${entry.name}"?',
              body: 'Somem deste celular o projeto, os históricos de alarmes, '
                  'regras e receitas e os registros gravados dele. Os outros projetos não mudam. '
                  'Para guardar uma cópia, use "Salvar em arquivo" antes.'
                  '${rules == 0 ? '' : rules == 1 ? '\n\n1 regra da planta usa este projeto e será desligada.' : '\n\n$rules regras da planta usam este projeto e serão desligadas.'}',
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

  /// A planta inteira (todos os projetos e as regras da planta).
  static Future<void> sharePlant(BuildContext context, Plant p) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/${ProjectRepository.plantExportName(p)}');
      await file.writeAsBytes(ProjectRepository.encodePlant(p), flush: true);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path, mimeType: 'application/json')],
        subject: 'Planta ${p.name} — ${AppInfo.name}',
        text: 'Planta "${p.name}" do ${AppInfo.name} (${p.projects.length == 1 ? '1 projeto' : '${p.projects.length} projetos'}). Para abrir: Projetos → Novo projeto → De um arquivo.',
      ));
    } catch (e) {
      if (context.mounted) WriteActions.toast(context, 'Não consegui enviar: $e', error: true);
    }
  }

  static Future<void> savePlant(BuildContext context, Plant p) async {
    try {
      final uri = await FilePicker.saveFile(
        dialogTitle: 'Salvar planta',
        fileName: ProjectRepository.plantExportName(p),
        bytes: ProjectRepository.encodePlant(p),
        mimeType: 'application/json',
      );
      if (uri != null && context.mounted) WriteActions.toast(context, 'Planta salva.');
    } catch (e) {
      if (context.mounted) WriteActions.toast(context, 'Não consegui salvar: $e', error: true);
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
