import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/app_scope.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/ids.dart';
import '../models/device.dart';
import '../models/hmi_screen.dart';
import '../models/project.dart';
import '../models/vendor_profiles.dart';
import '../services/templates/screen_templates.dart';
import '../services/templates/template_builder.dart';
import '../widgets/common/common.dart';
import '../widgets/hmi/element_catalog.dart';
import '../widgets/tour/tour.dart';
import 'editor/screen_editor_page.dart';
import 'screen_run_page.dart';
import 'settings_page.dart';

/// Lista de telas do projeto aberto — dentro da aba Projetos, e onde o app
/// abre (no último projeto aberto).
///
/// Cada cartão mostra a **planta** da tela (miniatura com os blocos de cada
/// elemento no lugar), para reconhecer a tela de olho. O título é o nome do
/// projeto; a seta à esquerda volta para a lista de projetos.
class ScreensPage extends StatelessWidget {
  const ScreensPage({super.key, required this.screensKey, required this.addKey, required this.helpKey, this.backKey, this.onBack});

  final GlobalKey screensKey;
  final GlobalKey addKey;
  final GlobalKey helpKey;

  /// Volta para a lista de projetos; nulo = sem lista (um projeto só).
  final VoidCallback? onBack;
  final GlobalKey? backKey;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.watch(context);
    final project = scope.controller.project;
    final screens = project.screens;

    return Scaffold(
      appBar: AppBar(
        leading: onBack == null
            ? null
            : IconButton(
                key: backKey ?? const ValueKey('voltar-projetos'),
                tooltip: 'Projetos',
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: onBack,
              ),
        title: AdaptiveTitle(project.name),
        actions: [const SettingsButton(), KeyedSubtree(key: helpKey, child: const HelpButton())],
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

  /// Pergunta o nome e por onde começar — em branco ou de um modelo pronto
  /// num equipamento — e abre o editor já na tela nova.
  static Future<void> createScreen(BuildContext context) async {
    final choice = await _NewScreenDialog.show(context);
    if (choice == null || !context.mounted) return;
    final c = AppScope.of(context).controller;
    final screenId = newId('s');
    final device = choice.deviceId == null ? null : c.project.device(choice.deviceId!);
    if (choice.template.isBlank || device == null) {
      c.saveScreen(HmiScreen(id: screenId, name: choice.name));
    } else {
      final result = TemplateBuilder.build(choice.template, project: c.project, device: device, screenId: screenId, name: choice.name);
      c.saveTags(result.created);
      c.saveScreen(result.screen);
      // O aviso aparece já no editor (o mensageiro é o do app).
      final pending = result.pending;
      if (pending > 0) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            key: const ValueKey('aviso-a-configurar'),
            content: Text('${pending == 1 ? '1 variável' : '$pending variáveis'} com o endereço a configurar — preencha em Variáveis.'),
          ));
      }
    }
    await Navigator.push(context, MaterialPageRoute(builder: (_) => ScreenEditorPage(screenId: screenId)));
  }
}

/// O que a pessoa escolheu em "Nova tela".
class _NewScreenChoice {
  const _NewScreenChoice(this.name, this.template, this.deviceId);
  final String name;
  final ScreenTemplate template;
  final String? deviceId;
}

/// "Nova tela": o nome (com o teclado já aberto, como sempre) e, numa linha,
/// por onde começar. Em branco é o padrão — Enter no nome cria a tela vazia
/// de antes. Escolhido um modelo, aparece a linha do equipamento e uma frase
/// com o que vai ser criado; o resto (endereços, faixas) se ajusta depois.
class _NewScreenDialog extends StatefulWidget {
  const _NewScreenDialog();

  static Future<_NewScreenChoice?> show(BuildContext context) =>
      showDialog<_NewScreenChoice>(context: context, builder: (_) => const _NewScreenDialog());

  @override
  State<_NewScreenDialog> createState() => _NewScreenDialogState();
}

class _NewScreenDialogState extends State<_NewScreenDialog> {
  final _name = TextEditingController();
  ScreenTemplate _template = ScreenTemplates.blank;
  String? _deviceId;

  /// O equipamento foi escolhido pela pessoa (trocar de modelo não mexe).
  bool _deviceChosen = false;

  /// Nome que o modelo pôs no campo: troca junto com o modelo; o que a
  /// pessoa digitou, não.
  String? _autoName;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Equipamento sugerido: no modelo de inversor, o último com perfil de
  /// inversor (é onde o mapa dá endereço); senão, o último cadastrado — quem
  /// acabou de cadastrar a prensa quer a tela dela.
  static String? _suggested(Project project, ScreenTemplate t) {
    final equipment = project.equipment;
    if (t.driveMap) {
      final drive = equipment.where((d) => VendorProfiles.of(d)?.kind == ProfileKind.drive).lastOrNull;
      if (drive != null) return drive.id;
    }
    return equipment.lastOrNull?.id;
  }

  Device? _device(Project project) {
    final id = _deviceId;
    return id == null || _template.isBlank ? null : project.device(id);
  }

  Future<void> _pickTemplate(Project project) async {
    final picked = await showModalBottomSheet<ScreenTemplate>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _TemplateChooser(selected: _template),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _template = picked;
      if (!_deviceChosen || project.device(_deviceId ?? '') == null) _deviceId = _suggested(project, picked);
      final typed = _name.text.trim();
      if (typed.isEmpty || typed == _autoName) {
        _autoName = picked.isBlank ? null : picked.name;
        _name.text = _autoName ?? '';
      }
    });
  }

  Future<void> _pickDevice(Project project) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _TemplateDeviceChooser(devices: project.equipment, selectedId: _deviceId),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _deviceId = picked;
      _deviceChosen = true;
    });
  }

  void _done(Project project) {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    if (!_template.isBlank && _device(project) == null) return;
    Navigator.pop(context, _NewScreenChoice(name, _template, _template.isBlank ? null : _deviceId));
  }

  /// "Cria 11 variáveis: 4 com o mapa do Inovance MD500 e 7 a configurar."
  static String _summary(TemplateResult r) {
    String vars(int n) => n == 1 ? '1 variável' : '$n variáveis';
    final created = r.created.length, mapped = r.mapped, open = r.created.length - mapped;
    final parts = <String>[
      if (created > 0)
        mapped == 0
            ? 'Cria ${vars(created)} com o endereço a configurar'
            : open == 0
                ? 'Cria ${vars(created)} com o mapa do ${r.profile!.name}'
                : 'Cria ${vars(created)}: $mapped com o mapa do ${r.profile!.name} e $open a configurar',
      if (r.reused.isNotEmpty) '${created > 0 ? 'usa' : 'Usa'} ${r.reused.length == 1 ? '1 que já existe' : '${r.reused.length} que já existem'}',
    ];
    return '${parts.join('; ')}.';
  }

  @override
  Widget build(BuildContext context) {
    final project = AppScope.watch(context).controller.project;
    final device = _device(project);
    final noEquipment = project.equipment.isEmpty;
    final preview = _template.isBlank || device == null
        ? null
        : TemplateBuilder.build(_template, project: project, device: device, screenId: 'previa', name: '');
    final ready = _template.isBlank || device != null;

    return AlertDialog(
      // Margem menor que a padrão (40): no celular de 320 dp, com 40, o nome
      // do modelo quebrava em três linhas e "Criar" caía para baixo de "Cancelar".
      insetPadding: const EdgeInsets.symmetric(horizontal: Ind.page, vertical: 24),
      title: const Text('Nova tela'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('campo-nome'),
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              // Exemplo curto: "Ex.: Cortadora — operação" saía cortado no celular de 320 dp.
              decoration: const InputDecoration(labelText: 'Nome da tela', hintText: 'Ex.: Prensa 2'),
              onSubmitted: (_) => _done(project),
            ),
            const SizedBox(height: Ind.space),
            _PickRow(
              key: const ValueKey('escolher-modelo'),
              icon: _template.icon,
              caption: 'Começar de',
              value: _template.name,
              onTap: () => _pickTemplate(project),
            ),
            if (!_template.isBlank) ...[
              const SizedBox(height: Ind.spaceSmall),
              _PickRow(
                key: const ValueKey('escolher-equipamento-modelo'),
                icon: Icons.router_outlined,
                caption: 'Equipamento',
                value: device?.name ?? 'Nenhum cadastrado',
                onTap: noEquipment ? null : () => _pickDevice(project),
              ),
              const SizedBox(height: 12),
              Text(
                key: const ValueKey('resumo-modelo'),
                preview == null ? 'Cadastre o equipamento primeiro (aba Equipamentos): as variáveis do modelo moram nele.' : _summary(preview),
                style: TextStyle(color: Ind.textMuted, fontSize: 13, height: 1.4),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(key: const ValueKey('ok-nome'), onPressed: ready ? () => _done(project) : null, child: Text(_template.isBlank ? 'OK' : 'Criar')),
      ],
    );
  }
}

/// Linha de escolha dentro do diálogo: rótulo pequeno, o escolhido e a seta.
class _PickRow extends StatelessWidget {
  const _PickRow({super.key, required this.icon, required this.caption, required this.value, required this.onTap});
  final IconData icon;
  final String caption;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Ind.surfaceHigh,
        borderRadius: BorderRadius.circular(Ind.radiusSmall),
        child: InkWell(
          borderRadius: BorderRadius.circular(Ind.radiusSmall),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: Ind.minTouch + 8),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
              child: Row(children: [
                Icon(icon, color: Ind.textDim, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(caption, style: TextStyle(color: Ind.textMuted, fontSize: 12.5)),
                    const SizedBox(height: 2),
                    Text(value, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5, height: 1.25)),
                  ]),
                ),
                if (onTap != null) Icon(Icons.chevron_right_rounded, color: Ind.textMuted),
              ]),
            ),
          ),
        ),
      );
}

/// Folha com os modelos: ícone, nome e uma frase do que vem na tela.
class _TemplateChooser extends StatelessWidget {
  const _TemplateChooser({required this.selected});
  final ScreenTemplate selected;

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        maxChildSize: 0.95,
        builder: (context, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 32),
          children: [
            Text('Começar de', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Ind.space),
            for (final t in ScreenTemplates.all)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _ChooserRow(
                  key: ValueKey('modelo-${t.id}'),
                  icon: t.icon,
                  title: t.name,
                  subtitle: t.description,
                  selected: t.id == selected.id,
                  onTap: () => Navigator.pop(context, t),
                ),
              ),
          ],
        ),
      );
}

/// Folha com os equipamentos para o modelo. O perfil de fabricante aparece
/// no lugar do endereço: é ele que decide se o endereço vem do mapa.
class _TemplateDeviceChooser extends StatelessWidget {
  const _TemplateDeviceChooser({required this.devices, required this.selectedId});
  final List<Device> devices;
  final String? selectedId;

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.95,
        builder: (context, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 32),
          children: [
            Text('Em qual equipamento', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: Ind.space),
            for (final d in devices)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _ChooserRow(
                  key: ValueKey('equipamento-modelo-${d.id}'),
                  icon: d.isDemo ? Icons.smart_toy_outlined : Icons.router_outlined,
                  title: d.name,
                  subtitle: VendorProfiles.of(d)?.name ?? d.addressLabel,
                  selected: d.id == selectedId,
                  onTap: () => Navigator.pop(context, d.id),
                ),
              ),
          ],
        ),
      );
}

class _ChooserRow extends StatelessWidget {
  const _ChooserRow({super.key, required this.icon, required this.title, required this.subtitle, required this.selected, required this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: selected ? Ind.accent.withValues(alpha: 0.14) : Ind.surfaceHigh,
        borderRadius: BorderRadius.circular(Ind.radiusSmall),
        child: InkWell(
          borderRadius: BorderRadius.circular(Ind.radiusSmall),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Ind.radiusSmall),
              border: selected ? Border.all(color: Ind.accent, width: 2) : null,
            ),
            child: Row(children: [
              Icon(icon, color: selected ? Ind.accent : Ind.textDim),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(color: Ind.textMuted, fontSize: 12.5, height: 1.3)),
                ]),
              ),
            ]),
          ),
        ),
      );
}

class _ScreenCard extends StatelessWidget {
  const _ScreenCard({required this.screen, required this.project});
  final HmiScreen screen;
  final Project project;

  /// Variáveis da tela com o endereço a configurar.
  int get _pending => screen.tagIds.where((id) => project.tag(id)?.addressPending ?? false).length;

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
                            Tooltip(message: 'Só acompanhamento', child: Icon(Icons.visibility_outlined, size: 15, color: Ind.textMuted)),
                            const SizedBox(width: 6),
                          ],
                          Text(
                              switch (screen.elements.length) { 0 => 'Só acompanhamento', 1 => '1 elemento', final n => '$n elementos' },
                              style: TextStyle(color: Ind.textMuted, fontSize: 13)),
                          // Tela de modelo com variável sem endereço: ainda não
                          // funciona inteira — o que falta, na cor de "configurar".
                          if (_pending > 0)
                            Flexible(
                              child: Text(' · $_pending a configurar',
                                  key: ValueKey('a-configurar-${screen.id}'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: Ind.accent, fontSize: 13, fontWeight: FontWeight.w600)),
                            ),
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
            // A imagem de fundo e as chaves de versão mais nova vão junto.
            c.saveScreen(screen.duplicate(id: newId('s'), name: '${screen.name} (cópia)', elementId: () => newId('e')));
          case 'delete':
            if (await confirmDelete(context, title: 'Apagar "${screen.name}"?', body: 'A tela e seus ${screen.elements.length} elementos somem. Equipamentos e variáveis continuam.')) {
              c.deleteScreen(screen.id);
            }
        }
      },
      itemBuilder: (_) => [
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
      return Center(child: Text('Tela vazia — toque para montar', style: TextStyle(color: Ind.textMuted, fontSize: 12)));
    }
    // Mostra o topo da tela (~5 linhas), centralizado e cortando embaixo.
    // Encolher a tela inteira deixava a planta minúscula num canto; usar a
    // largura cheia mostrava só o título.
    return LayoutBuilder(builder: (context, box) {
      // Grade fina: a célula é a metade, então são 10 linhas finas — o mesmo
      // pedaço da tela (com 5, a planta mostrava só metade do topo).
      final rows = 5 * HmiScreen.scaleOf(screen.columns);
      final cell = math.min(box.maxWidth / screen.columns, box.maxHeight / rows);
      final visibleRows = (box.maxHeight / cell).ceil();
      final left = (box.maxWidth - cell * screen.columns) / 2;
      return ClipRect(
        child: Stack(children: [
          for (final e in screen.elements.where((e) => e.y < visibleRows))
            Positioned(
              key: ValueKey('miniatura-${e.id}'),
              left: left + e.x * cell + 1.5,
              top: e.y * cell + 1.5,
              width: e.w * cell - 3,
              height: e.h * cell - 3,
              child: Container(
                // Bloco na cor do cartão, com contorno firme: no escuro, bloco
                // e fundo no mesmo tom com linha quase invisível sumiam.
                decoration: BoxDecoration(color: Ind.surface, borderRadius: BorderRadius.circular(3), border: Border.all(color: Ind.lineStrong)),
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
Future<String?> askText(BuildContext context, {required String title, required String label, String? hint, String initial = '', TextInputType? keyboardType}) {
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
          keyboardType: keyboardType,
          textCapitalization: keyboardType == null ? TextCapitalization.sentences : TextCapitalization.none,
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
