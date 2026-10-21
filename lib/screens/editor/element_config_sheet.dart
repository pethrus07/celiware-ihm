import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/image_util.dart';
import '../../models/camera.dart';
import '../../models/hmi_screen.dart';
import '../../models/project.dart';
import '../../models/tag.dart';
import '../../services/runtime/tag_codec.dart';
import '../../widgets/cameras/camera_pick.dart';
import '../../widgets/common/common.dart';
import '../../widgets/hmi/element_catalog.dart';
import '../../widgets/hmi/elements/control_elements.dart';
import '../../widgets/hmi/elements/indicator_elements.dart';
import '../../widgets/hmi/elements/table_element.dart';
import '../../widgets/hmi/hmi_canvas.dart';
import '../../widgets/hmi/hmi_frame.dart';
import '../../widgets/hmi/live_tags.dart';
import '../../widgets/hmi/write_actions.dart';
import '../tags/tag_form_page.dart';
import 'oee_config.dart';
import 'table_config.dart';

/// Configuração de um elemento: prévia ao vivo no topo, campos do tipo
/// embaixo. Tudo salva na hora (sem botão Salvar).
///
/// Só mostra o que faz sentido para o tipo — botão não pergunta mínimo e
/// máximo; medidor não pergunta cor de "ligado". A lista de variáveis mostra
/// só as compatíveis (o botão de pulso não oferece variável numérica) e tem
/// "Criar variável" ali mesmo, para não precisar sair do editor.
class ElementConfigSheet extends StatelessWidget {
  const ElementConfigSheet({super.key, required this.screenId, required this.elementId, this.panel = false});

  final String screenId;
  final String elementId;

  /// No painel lateral fixo do editor (tablet, TB-4) em vez da folha que sobe.
  final bool panel;

  static Future<void> show(BuildContext context, {required String screenId, required String elementId}) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => ElementConfigSheet(screenId: screenId, elementId: elementId),
      );

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.watch(context);
    final project = scope.controller.project;
    final screen = project.screen(screenId);
    final e = screen?.elements.where((x) => x.id == elementId).firstOrNull;
    if (screen == null || e == null) return const SizedBox(height: 120);
    final info = ElementCatalog.of(e.type);

    void save(HmiElement next) {
      scope.controller.saveScreen(screen.copyWith(elements: [
        for (final x in screen.elements) x.id == next.id ? next : x,
      ]));
    }

    void set(String key, Object? value) => save(e.withProp(key, value));

    // Todas as variáveis ao vivo enquanto a folha está aberta: a lista de
    // escolha mostra o valor de cada uma, o que ajuda a achar a certa.
    // No painel lateral (tablet) a folha fica parada, do tamanho do painel.
    return LiveTags(
      tagIds: {for (final t in project.tags) t.id},
      child: DraggableScrollableSheet(
      expand: panel,
      initialChildSize: panel ? 1 : 0.86,
      minChildSize: panel ? 1 : 0.25,
      maxChildSize: panel ? 1 : 0.96,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: EdgeInsets.fromLTRB(Ind.page, panel ? Ind.page : 0, Ind.page, 40),
        children: [
          Row(children: [
            Icon(info.icon, color: Ind.accent),
            const SizedBox(width: 10),
            Expanded(child: Text(info.name, style: Theme.of(context).textTheme.titleLarge)),
          ]),
          const SizedBox(height: 12),
          _Preview(element: e, bare: ElementCatalog.drawnBare(screen, e)),
          const SizedBox(height: 8),
          ..._fields(context, project, e, info, set, save),
        ],
      ),
      ),
    );
  }

  List<Widget> _fields(BuildContext context, Project project, HmiElement e, ElementInfo info,
      void Function(String, Object?) set, void Function(HmiElement) save) {
    final w = <Widget>[];
    final tag = e.tagId == null ? null : project.tag(e.tagId!);

    final buttonMode = e.type == ElementType.button ? ButtonModeMeta.fromName(e.prop<String>('mode', 'toggle')) : null;
    // Equipamentos que a tela já usa: vêm primeiro na lista de variáveis.
    final screenDevices = {for (final id in project.screen(screenId)?.tagIds ?? const <String>{}) ?project.tag(id)?.deviceId};

    // ── Variável ── ("Ir para tela" e "Abrir câmera" não gravam: não pedem variável)
    if (info.fit != TagFit.none && (buttonMode?.needsTag ?? true)) {
      if (e.type == ElementType.table) {
        w.add(const SectionHeader('Variáveis (até ${TableElement.maxRows})', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)));
        w.add(TableRowsEditor(project: project, element: e, preferDevices: screenDevices, onChanged: (ids) => set('tagIds', ids)));
      } else if (info.multiTag) {
        w.add(const SectionHeader('Variáveis (até 3)', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)));
        w.add(_MultiTagPicker(project: project, selected: e.tagIds.toList(), onChanged: (ids) => set('tagIds', ids)));
      } else {
        final fit = e.type == ElementType.button
            ? (ButtonModeMeta.fromName(e.prop<String>('mode', 'toggle')).needsNumber ? TagFit.number : TagFit.boolean)
            : info.fit;
        w.add(SectionHeader('Variável', padding: const EdgeInsets.fromLTRB(0, 28, 0, 12)));
        w.add(_TagPicker(
          project: project,
          fit: fit,
          selected: tag,
          needsWritable: info.writes,
          preferDevices: screenDevices,
          onChanged: (t) {
            var next = e.withProp('tagId', t.id);
            // Rótulo vazio ou ainda igual ao nome da variável anterior → segue a nova.
            final label = e.props['label'] as String?;
            // "Botão" é o rótulo padrão de quem ainda não tem variável — também é substituído.
            final padrao = ElementCatalog.defaultProps(e.type)['label'];
            if (label == null || label.isEmpty || label == tag?.name || label == padrao) {
              next = next.withProp('label', t.name);
            }
            save(next);
          },
        ));
      }
    }

    // ── Texto do elemento ──
    if (e.type != ElementType.label && e.type != ElementType.image) {
      w.add(const SizedBox(height: 16));
      w.add(_TextProp(key: ValueKey('rotulo-${tag?.id}'), label: e.type == ElementType.table ? 'Título (opcional)' : 'Rótulo', value: e.prop<String>('label', ''), onChanged: (v) => set('label', v)));
    }

    switch (e.type) {
      case ElementType.button:
        final mode = buttonMode!;
        w.add(const SectionHeader('Como o botão age', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)));
        w.add(ChoiceCards<ButtonMode>(
          options: const [
            ChoiceOption(value: ButtonMode.toggle, title: 'Liga / desliga', icon: Icons.toggle_on_outlined),
            ChoiceOption(value: ButtonMode.momentary, title: 'Pulso', icon: Icons.touch_app_outlined),
            ChoiceOption(value: ButtonMode.set, title: 'Só liga', icon: Icons.power_settings_new_rounded),
            ChoiceOption(value: ButtonMode.reset, title: 'Só desliga', icon: Icons.power_off_outlined),
            ChoiceOption(value: ButtonMode.value, title: 'Grava valor', icon: Icons.onetwothree_rounded),
            ChoiceOption(value: ButtonMode.screen, title: 'Ir para tela', icon: Icons.arrow_forward_rounded),
            ChoiceOption(value: ButtonMode.camera, title: 'Abrir câmera', icon: Icons.videocam_outlined),
          ],
          selected: mode,
          onChanged: (m) {
            var next = e.withProp('mode', m.name);
            // Trocou entre modo de bit, numérico e "ir para tela": a variável
            // atual pode não servir mais — solta para escolher de novo.
            if (tag != null && (m.needsNumber != mode.needsNumber || !m.needsTag)) next = next.withProp('tagId', null);
            if (!m.isBit) next = next.withProp('feedbackTagId', null);
            if (!m.needsTag && next.props['label'] == tag?.name) next = next.withProp('label', '');
            if (m != ButtonMode.camera) next = next.withProp('cameraId', null);
            save(next);
          },
        ));
        if (mode == ButtonMode.camera) {
          w.add(const SectionHeader('Abre a câmera', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)));
          w.add(CameraPick(
            project: project,
            selected: e.props['cameraId'] as String?,
            preferDevices: {...screenDevices.whereType<String>()},
            onChanged: (id) {
              var next = e.withProp('cameraId', id);
              final label = e.props['label'] as String?;
              final old = project.camera(e.props['cameraId'] as String? ?? '')?.name;
              // A câmera pode ter acabado de nascer ("Nova câmera"): o nome vem do projeto de agora.
              final name = AppScope.of(context).controller.project.camera(id)?.name;
              if (name != null && (label == null || label.isEmpty || label == old || label == 'Botão')) next = next.withProp('label', name);
              save(next);
            },
          ));
          break;
        }
        if (mode == ButtonMode.screen) {
          w.add(const SectionHeader('Abre a tela', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)));
          w.add(_ScreenPick(
            project: project,
            currentScreenId: screenId,
            selected: e.props['goTo'] as String?,
            onChanged: (id) {
              var next = e.withProp('goTo', id);
              final label = e.props['label'] as String?;
              final old = project.screen(e.props['goTo'] as String? ?? '')?.name;
              if (id != null && (label == null || label.isEmpty || label == old || label == 'Botão')) {
                next = next.withProp('label', project.screen(id)?.name ?? '');
              }
              save(next);
            },
          ));
          break;
        }
        if (mode.isBit) {
          w.add(const SectionHeader('Retorno da máquina', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)));
          w.add(_FeedbackPick(project: project, selectedId: e.props['feedbackTagId'] as String?, commandId: tag?.id, onChanged: (id) => set('feedbackTagId', id)));
        }
        if (mode == ButtonMode.value) {
          w.add(const SizedBox(height: 12));
          w.add(_NumProp(label: 'Valor gravado ao tocar', value: e.props['value'] as num?, onChanged: (v) => set('value', v)));
        }
        w.add(_ColorProp(label: 'Cor quando ligado', value: e.prop<String>('color', 'green'), onChanged: (v) => set('color', v)));
      case ElementType.lamp:
        w.add(const SizedBox(height: 12));
        w.add(Row(children: [
          Expanded(child: _TextProp(label: 'Texto ligado', value: e.prop<String>('onText', 'LIGADO'), onChanged: (v) => set('onText', v))),
          const SizedBox(width: 10),
          Expanded(child: _TextProp(label: 'Texto desligado', value: e.prop<String>('offText', 'DESLIGADO'), onChanged: (v) => set('offText', v))),
        ]));
        final lampStyle = LampStyleMeta.fromName(e.props['style'] as String?);
        w.add(const SectionHeader('Como acende', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)));
        w.add(ChoiceCards<LampStyle>(
          options: const [
            ChoiceOption(value: LampStyle.hp, title: 'Alto desempenho', subtitle: 'Brilho e palavra; cor só no anormal', icon: Icons.brightness_high_outlined),
            ChoiceOption(value: LampStyle.classic, title: 'Painel clássico', subtitle: 'Acende na cor escolhida', icon: Icons.circle),
          ],
          selected: lampStyle,
          onChanged: (s) => set('style', s == LampStyle.classic ? 'classic' : null),
        ));
        w.add(_ColorProp(
          label: lampStyle == LampStyle.hp ? 'Cor (vermelho e amarelo acendem na cor)' : 'Cor acesa',
          value: e.prop<String>('color', 'green'),
          onChanged: (v) => set('color', v),
        ));
      case ElementType.input:
        w.add(const SectionHeader('Limites de segurança', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)));
        w.add(Text('O operador não consegue digitar fora desta faixa.', style: TextStyle(color: Ind.textDim)));
        w.add(const SizedBox(height: 10));
        w.add(_MinMax(e: e, set: set));
      case ElementType.bar:
        // Sem "cor da barra": neutra, como o arco do medidor; cor só nas faixas.
        w.add(const SectionHeader('Escala e faixas', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)));
        w.add(_MinMax(e: e, set: set, defaults: (0, 100)));
        w.add(const SizedBox(height: Ind.space));
        w.add(Text('A barra fica amarela e vermelha a partir destes valores. Vazio = sem faixa.', style: TextStyle(color: Ind.textDim)));
        w.add(const SizedBox(height: 10));
        w.add(Row(children: [
          Expanded(child: _NumProp(key: const ValueKey('faixa-atencao-barra'), label: 'Atenção', value: e.props['warn'] as num?, onChanged: (v) => set('warn', v), color: Ind.warn)),
          const SizedBox(width: 10),
          Expanded(child: _NumProp(key: const ValueKey('faixa-alarme-barra'), label: 'Alarme', value: e.props['alarm'] as num?, onChanged: (v) => set('alarm', v), color: Ind.alarm)),
        ]));
      case ElementType.gauge:
        w.add(const SectionHeader('Escala e faixas', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)));
        w.add(_MinMax(e: e, set: set, defaults: (0, 100)));
        // "A partir de" vai na frase: no rótulo, metade da largura do
        // celular, virava "Atenção a partir…".
        w.add(const SizedBox(height: Ind.space));
        w.add(Text('O arco fica amarelo e vermelho a partir destes valores. Vazio = sem faixa.', style: TextStyle(color: Ind.textDim)));
        w.add(const SizedBox(height: 10));
        w.add(Row(children: [
          Expanded(child: _NumProp(key: const ValueKey('faixa-atencao'), label: 'Atenção', value: e.props['warn'] as num?, onChanged: (v) => set('warn', v), color: Ind.warn)),
          const SizedBox(width: 10),
          Expanded(child: _NumProp(key: const ValueKey('faixa-alarme-medidor'), label: 'Alarme', value: e.props['alarm'] as num?, onChanged: (v) => set('alarm', v), color: Ind.alarm)),
        ]));
      case ElementType.multistate:
        w.add(const SectionHeader('Estados', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)));
        w.add(Text('Para cada código que o equipamento manda, o texto e a cor que aparecem.', style: TextStyle(color: Ind.textDim)));
        w.add(const SizedBox(height: 10));
        w.add(_StatesEditor(states: [for (final s in (e.props['states'] as List? ?? const [])) if (s is Map) Map<String, dynamic>.from(s)], onChanged: (v) => set('states', v)));
      case ElementType.trend:
        final win = e.prop<num>('windowSec', 120).toInt();
        w.add(const SectionHeader('Janela de tempo', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)));
        w.add(Wrap(spacing: 8, children: [
          for (final (s, t) in [(30, '30 s'), (60, '1 min'), (120, '2 min'), (300, '5 min'), (600, '10 min')])
            ChoiceChip(label: Text(t), selected: win == s, onSelected: (_) => set('windowSec', s)),
        ]));
        w.add(const SectionHeader('Escala vertical (vazio = automática)', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)));
        w.add(_MinMax(e: e, set: set));
      case ElementType.label:
        w.add(const SizedBox(height: 12));
        w.add(_TextProp(label: 'Texto', value: e.prop<String>('text', ''), onChanged: (v) => set('text', v), maxLines: 3));
        w.add(const SectionHeader('Tamanho', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)));
        w.add(Wrap(spacing: 8, children: [
          for (final (v, t) in [('s', 'Pequeno'), ('m', 'Médio'), ('l', 'Grande')])
            ChoiceChip(label: Text(t), selected: e.prop<String>('size', 'm') == v, onSelected: (_) => set('size', v)),
          const SizedBox(width: 12),
          for (final (v, t) in [('left', 'À esquerda'), ('center', 'Centralizado')])
            ChoiceChip(label: Text(t), selected: e.prop<String>('align', 'left') == v, onSelected: (_) => set('align', v)),
        ]));
      case ElementType.image:
        final byValue = e.prop<String>('source', 'fixed') == 'byValue';
        w.add(const SizedBox(height: 12));
        w.add(ChoiceCards<bool>(
          options: const [
            ChoiceOption(value: false, title: 'Fixa', subtitle: 'Foto, esquema, logotipo', icon: Icons.image_outlined),
            ChoiceOption(value: true, title: 'Muda com a variável', subtitle: 'Uma imagem por etapa', icon: Icons.burst_mode_outlined),
          ],
          selected: byValue,
          onChanged: (v) => set('source', v ? 'byValue' : 'fixed'),
        ));
        if (byValue) {
          w.add(const SectionHeader('Variável da etapa', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)));
          w.add(_TagPicker(project: project, fit: TagFit.scalar, selected: tag, preferDevices: screenDevices, onChanged: (t) => set('tagId', t.id)));
          w.add(const SectionHeader('Imagens', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)));
          w.add(Text('Quando a variável vale o código, a tela mostra a imagem dele. Um PDF vira uma imagem por página: página 1 = código 1.',
              style: TextStyle(color: Ind.textDim, height: 1.35)));
          w.add(const SizedBox(height: 12));
          w.add(_ImagesEditor(
            images: [for (final i in (e.props['images'] as List? ?? const [])) if (i is Map) Map<String, dynamic>.from(i)],
            onChanged: (v) => set('images', v),
          ));
        } else {
          w.add(const SizedBox(height: 16));
          w.add(FilledButton.icon(
            onPressed: () => _pickImage(context, set),
            icon: const Icon(Icons.photo_library_outlined),
            label: Text(e.props['data'] == null ? 'Escolher imagem' : 'Trocar imagem'),
          ));
        }
        w.add(const SizedBox(height: 12));
        w.add(Wrap(spacing: 8, children: [
          for (final (v, t) in [('contain', 'Mostrar inteira'), ('cover', 'Preencher o espaço')])
            ChoiceChip(label: Text(t), selected: e.prop<String>('fit', 'contain') == v, onSelected: (_) => set('fit', v)),
        ]));
      case ElementType.table:
        w.addAll(tableTextFields(project, e, set));
      case ElementType.oee:
        // Origem, escala, uma variável por vaga e faixas: oee_config.dart.
        w.addAll(oeeFields(project, e, save,
            picker: (selected, onChanged) =>
                _TagPicker(project: project, fit: TagFit.number, selected: selected, preferDevices: screenDevices, onChanged: onChanged)));
      case ElementType.barChart:
        final axis = e.prop<String>('axis', 'hour');
        w.add(const SectionHeader('Embaixo de cada barra', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)));
        w.add(Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (v, t) in [('hour', 'Hora · a última é a de agora'), ('index', 'Posição · 1, 2, 3…')])
            ChoiceChip(key: ValueKey('eixo-$v'), label: Text(t), selected: axis == v, onSelected: (_) => set('axis', v)),
        ]));
      case ElementType.value:
      case ElementType.unknown:
        break;
    }

    if (tag != null && info.writes && !tag.canWrite && (buttonMode?.needsTag ?? true)) {
      w.add(const SizedBox(height: 16));
      w.add(_Hint(icon: Icons.lock_outline_rounded, color: Ind.warn,
          text: '"${tag.name}" está como só leitura. Para este elemento gravar, abra a variável e marque "Pode ser alterada pela tela".'));
    }

    // ── Ao tocar, abrir tela ── (botão e ajuste: o toque já grava)
    if (e.type != ElementType.button && e.type != ElementType.input && project.screens.length > 1) {
      w.add(const SectionHeader('Ao tocar, abrir a tela', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)));
      w.add(_ScreenPick(
        project: project,
        currentScreenId: screenId,
        selected: e.props['goTo'] as String?,
        allowNone: true,
        onChanged: (id) => set('goTo', id),
      ));
    }

    // ── Posição e tamanho ── (ajuste fino sem arrastar: na grade fina a célula
    // tem ~30 dp e o arrasto fica impreciso). Recolhido: quase nunca precisa.
    // Na extra-fina o editor tem também as setas na barra de baixo, com a
    // tela à vista (_NudgeBar em screen_editor_page.dart).
    final screen = project.screen(screenId);
    // ── Mais opções ── "Fundo transparente": só numa tela com imagem de
    // fundo (sem ela não há o que ver através) e só nos tipos que mostram um
    // estado ou um número (ElementCatalog.transparentTypes).
    if (screen?.background != null && ElementCatalog.transparentTypes.contains(e.type)) {
      w.add(const SizedBox(height: 20));
      w.add(_MoreOptions(element: e, onTransparent: (v) => set('transparent', v ? true : null)));
    }
    if (screen != null) {
      w.add(SizedBox(height: screen.background != null && ElementCatalog.transparentTypes.contains(e.type) ? 0 : 20));
      w.add(_GeometryEditor(screen: screen, element: e, onChanged: save));
    }
    return w;
  }

  static Future<void> _pickImage(BuildContext context, void Function(String, Object?) set) async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.image);
      if (files.isEmpty) return;
      final b64 = await shrinkToBase64Png(await files.first.readAsBytes());
      set('data', b64);
    } catch (e) {
      if (context.mounted) WriteActions.toast(context, 'Não consegui abrir a imagem.', error: true);
    }
  }
}

/// A prévia usa a própria célula da grade, na proporção real do elemento.
class _Preview extends StatelessWidget {
  const _Preview({required this.element, this.bare = false});
  final HmiElement element;

  /// Sem cartão, como fica sobre a imagem de fundo ([HmiSurface]).
  final bool bare;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final cell = (box.maxWidth / 6).clamp(40.0, 72.0);
      final w = (element.w * cell).clamp(0.0, box.maxWidth);
      final h = (element.h * cell).clamp(40.0, 220.0);
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Ind.bg, borderRadius: BorderRadius.circular(Ind.radius)),
        child: Column(children: [
          Center(
            child: SizedBox(
              width: w - 24 > 0 ? w - 24 : w,
              height: h,
              child: HmiScreenContext(editMode: true, readOnly: true, confirmWrites: true, child: HmiSurface.wrap(bare: bare, child: HmiElementView(element: element))),
            ),
          ),
        ]),
      );
    });
  }
}

class _TagPicker extends StatelessWidget {
  const _TagPicker({required this.project, required this.fit, required this.selected, required this.onChanged, this.needsWritable = false, this.preferDevices = const {}});
  final Project project;
  final TagFit fit;
  final Tag? selected;
  final bool needsWritable;
  final Set<String> preferDevices;
  final ValueChanged<Tag> onChanged;

  // Uma linha só com a variável escolhida; a lista completa abre numa folha
  // própria ao tocar. Listar tudo aqui ocupava a tela inteira.
  @override
  Widget build(BuildContext context) {
    final t = selected;
    final wrongFit = t != null && !fit.accepts(t);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (wrongFit)
          _Hint(icon: Icons.warning_amber_rounded, color: Ind.warn, text: '"${t.name}" não serve aqui: este elemento precisa de ${fit.requirement}.'),
        Material(
          color: t == null ? Ind.accent.withValues(alpha: 0.12) : Ind.surfaceHigh,
          borderRadius: BorderRadius.circular(Ind.radiusSmall),
          child: InkWell(
            key: const ValueKey('escolher-variavel'),
            borderRadius: BorderRadius.circular(Ind.radiusSmall),
            onTap: () async {
              final picked = await _TagChooser.show(context, fit: fit, needsWritable: needsWritable, selectedId: t?.id, preferDevices: preferDevices);
              if (picked != null) onChanged(picked);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: Row(children: [
                Icon(t == null ? Icons.link_rounded : Icons.data_object_rounded, color: t == null ? Ind.accent : Ind.textDim),
                const SizedBox(width: 14),
                Expanded(
                  child: t == null
                      ? Text('Escolher variável', style: TextStyle(color: Ind.accent, fontWeight: FontWeight.w700, fontSize: 16))
                      : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(t.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                          const SizedBox(height: 2),
                          Text(t.addressLabel, style: TextStyle(color: Ind.textMuted, fontSize: 13)),
                        ]),
                ),
                Icon(Icons.chevron_right_rounded, color: Ind.textMuted),
              ]),
            ),
          ),
        ),
      ],
    );
  }
}

/// Folha com a lista de variáveis compatíveis (valor ao vivo em cada uma) e
/// o atalho "Criar variável". Devolve a escolhida.
///
/// Agrupada por equipamento — os da tela que está sendo montada primeiro — e
/// com busca por nome ou endereço a partir de 8 variáveis: numa máquina de
/// verdade são 100+, e uma lista corrida vira caça ao tesouro.
class _TagChooser extends StatefulWidget {
  const _TagChooser({required this.fit, required this.needsWritable, this.selectedId, this.preferDevices = const {}});
  final TagFit fit;
  final bool needsWritable;
  final String? selectedId;
  final Set<String> preferDevices;

  static Future<Tag?> show(BuildContext context,
          {required TagFit fit, required bool needsWritable, String? selectedId, Set<String> preferDevices = const {}}) =>
      showModalBottomSheet<Tag>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => _TagChooser(fit: fit, needsWritable: needsWritable, selectedId: selectedId, preferDevices: preferDevices),
      );

  @override
  State<_TagChooser> createState() => _TagChooserState();
}

class _TagChooserState extends State<_TagChooser> {
  String _query = '';

  static String _plain(String s) => s
      .toLowerCase()
      .replaceAll(RegExp('[áàâã]'), 'a')
      .replaceAll(RegExp('[éê]'), 'e')
      .replaceAll('í', 'i')
      .replaceAll(RegExp('[óôõ]'), 'o')
      .replaceAll('ú', 'u')
      .replaceAll('ç', 'c');

  bool _matches(Tag t) {
    if (_query.isEmpty) return true;
    final q = _plain(_query.trim());
    return _plain(t.name).contains(q) || _plain(t.addressLabel).contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final project = AppScope.watch(context).controller.project;
    final compatible = project.tags.where(widget.fit.accepts).toList();
    final shown = compatible.where(_matches).toList();
    // Equipamentos da tela primeiro, depois os outros na ordem do projeto.
    final devices = [
      ...project.devices.where((d) => widget.preferDevices.contains(d.id)),
      ...project.devices.where((d) => !widget.preferDevices.contains(d.id)),
    ];
    final grouped = devices.length > 1;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 32),
        children: [
          Text('Escolha a variável', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Ind.space),
          if (compatible.length >= 8) ...[
            TextField(
              key: const ValueKey('buscar-variavel'),
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Buscar por nome ou endereço'),
            ),
            const SizedBox(height: Ind.space),
          ],
          if (compatible.isEmpty)
            _Hint(icon: Icons.info_outline_rounded, color: Ind.info, text: 'Nenhuma ${widget.fit.requirement} ainda.')
          else if (shown.isEmpty)
            _Hint(icon: Icons.search_off_rounded, color: Ind.info, text: 'Nenhuma variável com "$_query".'),
          for (final d in devices) ...[
            if (grouped && shown.any((t) => t.deviceId == d.id))
              SectionHeader(d.name, padding: const EdgeInsets.fromLTRB(4, 12, 0, 10)),
            for (final t in shown.where((t) => t.deviceId == d.id))
              _TagRow(tag: t, project: project, selected: t.id == widget.selectedId, showDevice: !grouped,
                  warnReadOnly: widget.needsWritable && !t.canWrite, onTap: () => Navigator.pop(context, t)),
          ],
          const SizedBox(height: Ind.spaceSmall),
          OutlinedButton.icon(
            key: const ValueKey('criar-variavel-aqui'),
            onPressed: () async {
              final created = await Navigator.push<Tag>(
                context,
                MaterialPageRoute(builder: (_) => TagFormPage(
                      fit: widget.fit,
                      preferWritable: widget.needsWritable,
                      preferDeviceId: widget.preferDevices.firstOrNull,
                    )),
              );
              if (created != null && context.mounted) Navigator.pop(context, created);
            },
            icon: const Icon(Icons.add_rounded),
            label: const Text('Criar variável'),
          ),
        ],
      ),
    );
  }
}

class _MultiTagPicker extends StatelessWidget {
  const _MultiTagPicker({required this.project, required this.selected, required this.onChanged});
  final Project project;
  final List<String> selected;
  final ValueChanged<List<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    final compatible = project.tags.where(TagFit.number.accepts).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final t in compatible)
          _TagRow(
            tag: t,
            project: project,
            selected: selected.contains(t.id),
            onTap: () {
              final next = [...selected];
              if (next.contains(t.id)) {
                next.remove(t.id);
              } else if (next.length < 3) {
                next.add(t.id);
              } else {
                WriteActions.toast(context, 'O gráfico mostra até 3 curvas.');
                return;
              }
              onChanged(next);
            },
          ),
        if (compatible.isEmpty) _Hint(icon: Icons.info_outline_rounded, color: Ind.info, text: 'Nenhuma variável numérica ainda.'),
      ],
    );
  }
}

class _TagRow extends StatelessWidget {
  const _TagRow({required this.tag, required this.project, required this.selected, required this.onTap, this.warnReadOnly = false, this.showDevice = true});
  final Tag tag;
  final Project project;
  final bool selected;
  final bool warnReadOnly;

  /// Lista agrupada por equipamento já diz de qual é: não repete na linha.
  final bool showDevice;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: selected ? Ind.accent.withValues(alpha: 0.14) : Ind.surfaceHigh,
        borderRadius: BorderRadius.circular(Ind.radiusSmall),
        child: InkWell(
          key: ValueKey('escolher-${tag.id}'),
          borderRadius: BorderRadius.circular(Ind.radiusSmall),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Ind.radiusSmall),
              border: selected ? Border.all(color: Ind.accent, width: 2) : null,
            ),
            child: Row(children: [
              Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded, color: selected ? Ind.accent : Ind.textMuted, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tag.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text('${showDevice ? '${project.device(tag.deviceId)?.name ?? '?'} · ' : ''}${tag.addressLabel}${warnReadOnly ? ' · só leitura' : ''}',
                      style: TextStyle(color: warnReadOnly ? Ind.warn : Ind.textMuted, fontSize: 12)),
                ]),
              ),
              TagBuilder(tagId: tag.id, builder: (_, t, r) => Text(TagCodec.format(tag, r.value is List ? '[${(r.value as List).length}]' : r.value), style: Ind.number(13, color: Ind.textDim))),
            ]),
          ),
        ),
      ),
    );
  }
}

class _TextProp extends StatelessWidget {
  const _TextProp({super.key, required this.label, required this.value, required this.onChanged, this.maxLines = 1});
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final int maxLines;

  @override
  Widget build(BuildContext context) => TextFormField(
        initialValue: value,
        maxLines: maxLines,
        decoration: InputDecoration(labelText: label),
        textCapitalization: TextCapitalization.sentences,
        onChanged: onChanged,
      );
}

class _NumProp extends StatelessWidget {
  const _NumProp({super.key, required this.label, required this.value, required this.onChanged, this.color});
  final String label;
  final num? value;
  final ValueChanged<num?> onChanged;
  final Color? color;

  @override
  Widget build(BuildContext context) => TextFormField(
        initialValue: value == null ? '' : value.toString().replaceAll('.', ','),
        keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
        style: Ind.number(17, color: color ?? Ind.text),
        decoration: InputDecoration(labelText: label),
        onChanged: (t) {
          final v = num.tryParse(t.trim().replaceAll(',', '.'));
          onChanged(t.trim().isEmpty ? null : v);
        },
      );
}

class _MinMax extends StatelessWidget {
  const _MinMax({required this.e, required this.set, this.defaults});
  final HmiElement e;
  final void Function(String, Object?) set;
  final (num, num)? defaults;

  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(child: _NumProp(label: 'Mínimo', value: (e.props['min'] as num?) ?? defaults?.$1, onChanged: (v) => set('min', v))),
        const SizedBox(width: 10),
        Expanded(child: _NumProp(label: 'Máximo', value: (e.props['max'] as num?) ?? defaults?.$2, onChanged: (v) => set('max', v))),
      ]);
}

class _ColorProp extends StatelessWidget {
  const _ColorProp({required this.label, required this.value, required this.onChanged});
  final String label;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionHeader(label, padding: const EdgeInsets.fromLTRB(0, 28, 0, 12)),
      Wrap(spacing: 10, runSpacing: 10, children: [
        for (final c in StateColor.values)
          Tooltip(
            message: c.label,
            child: InkWell(
              key: ValueKey('cor-${c.name}'),
              onTap: () => onChanged(c.name),
              borderRadius: BorderRadius.circular(24),
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.color,
                  border: Border.all(color: value == c.name ? Ind.text : Colors.transparent, width: 3),
                ),
                child: value == c.name ? Icon(Icons.check_rounded, color: Ind.bg) : null,
              ),
            ),
          ),
      ]),
      const SizedBox(height: 6),
      Text(StateColorMeta.fromName(value).label, style: TextStyle(color: Ind.textDim, fontSize: 12.5)),
    ]);
  }
}

class _StatesEditor extends StatelessWidget {
  const _StatesEditor({required this.states, required this.onChanged});
  final List<Map<String, dynamic>> states;
  final ValueChanged<List<Map<String, dynamic>>> onChanged;

  @override
  Widget build(BuildContext context) {
    void update(int i, String k, Object? v) {
      final next = [for (final s in states) Map<String, dynamic>.of(s)];
      next[i][k] = v;
      onChanged(next);
    }

    return Column(children: [
      for (var i = 0; i < states.length; i++)
        Padding(
          key: ValueKey('estado-$i-${states.length}'),
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            // Largo o bastante para "Código" não virar "Có…", e na mesma
            // altura de linha do campo de texto ao lado (os dois alinhados).
            SizedBox(
              width: 88,
              child: TextFormField(
                key: ValueKey('estado-codigo-$i'),
                initialValue: '${states[i]['value'] ?? ''}',
                keyboardType: TextInputType.number,
                style: Ind.number(16).copyWith(height: 1.5),
                decoration: const InputDecoration(labelText: 'Código', contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 18)),
                onChanged: (t) => update(i, 'value', int.tryParse(t.trim())),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextFormField(
                key: ValueKey('estado-texto-$i'),
                initialValue: '${states[i]['text'] ?? ''}',
                decoration: const InputDecoration(labelText: 'Texto'),
                textCapitalization: TextCapitalization.characters,
                onChanged: (t) => update(i, 'text', t),
              ),
            ),
            const SizedBox(width: 6),
            PopupMenuButton<String>(
              tooltip: 'Cor',
              initialValue: states[i]['color'] as String?,
              onSelected: (c) => update(i, 'color', c),
              itemBuilder: (_) => [
                for (final c in StateColor.values)
                  PopupMenuItem(value: c.name, child: Row(children: [CircleAvatar(radius: 9, backgroundColor: c.color), const SizedBox(width: 10), Text(c.label)])),
              ],
              child: CircleAvatar(radius: 16, backgroundColor: StateColorMeta.fromName(states[i]['color'] as String?).color),
            ),
            IconButton(
              tooltip: 'Tirar estado',
              onPressed: () => onChanged([...states]..removeAt(i)),
              icon: Icon(Icons.close_rounded, color: Ind.textMuted),
            ),
          ]),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () {
            final nextCode = states.isEmpty ? 0 : states.map((s) => (s['value'] as int?) ?? 0).reduce((a, b) => a > b ? a : b) + 1;
            onChanged([...states, {'value': nextCode, 'text': 'ESTADO $nextCode', 'color': 'neutral'}]);
          },
          icon: const Icon(Icons.add_rounded),
          label: const Text('Acrescentar estado'),
        ),
      ),
    ]);
  }
}

/// Escolha de uma das outras telas do projeto.
class _ScreenPick extends StatelessWidget {
  const _ScreenPick({required this.project, required this.currentScreenId, required this.selected, required this.onChanged, this.allowNone = false});
  final Project project;
  final String currentScreenId;
  final String? selected;
  final bool allowNone;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final others = project.screens.where((s) => s.id != currentScreenId).toList();
    if (others.isEmpty) {
      return _Hint(icon: Icons.info_outline_rounded, color: Ind.info, text: 'Crie outra tela para este botão abrir.');
    }
    return Wrap(spacing: 8, runSpacing: 8, children: [
      if (allowNone) ChoiceChip(label: const Text('Nada'), selected: selected == null, onSelected: (_) => onChanged(null)),
      for (final s in others)
        ChoiceChip(key: ValueKey('tela-${s.id}'), label: Text(s.name), selected: selected == s.id, onSelected: (_) => onChanged(s.id)),
    ]);
  }
}

/// Retorno do botão: por padrão acende pela própria variável do comando; com
/// retorno, acende pelo que a máquina confirma.
class _FeedbackPick extends StatelessWidget {
  const _FeedbackPick({required this.project, required this.selectedId, required this.commandId, required this.onChanged});
  final Project project;
  final String? selectedId;
  final String? commandId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = selectedId == null ? null : project.tag(selectedId!);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(
        t == null
            ? 'O botão acende pela própria variável do comando.'
            : 'O botão grava no comando e só acende quando "${t.name}" confirmar. Comando sem confirmação aparece como aguardando.',
        style: TextStyle(color: Ind.textDim, height: 1.35),
      ),
      const SizedBox(height: 10),
      Material(
        color: Ind.surfaceHigh,
        borderRadius: BorderRadius.circular(Ind.radiusSmall),
        child: InkWell(
          key: const ValueKey('escolher-retorno'),
          borderRadius: BorderRadius.circular(Ind.radiusSmall),
          onTap: () async {
            final picked = await _TagChooser.show(context, fit: TagFit.boolean, needsWritable: false, selectedId: selectedId,
                preferDevices: {if (commandId != null) ?project.tag(commandId!)?.deviceId});
            if (picked != null) onChanged(picked.id == commandId ? null : picked.id);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Row(children: [
              Icon(Icons.keyboard_return_rounded, color: Ind.textDim),
              const SizedBox(width: 14),
              Expanded(
                child: Text(t == null ? 'Mesma variável do comando' : t.name,
                    style: TextStyle(fontWeight: FontWeight.w600, color: t == null ? Ind.textDim : Ind.text)),
              ),
              if (t != null)
                IconButton(tooltip: 'Usar a mesma do comando', onPressed: () => onChanged(null), icon: Icon(Icons.close_rounded, color: Ind.textMuted))
              else
                Icon(Icons.chevron_right_rounded, color: Ind.textMuted),
            ]),
          ),
        ),
      ),
    ]);
  }
}

/// Lista "código → imagem" da imagem por etapa, com importação de fotos
/// (várias de uma vez) e de PDF (uma imagem por página).
class _ImagesEditor extends StatefulWidget {
  const _ImagesEditor({required this.images, required this.onChanged});
  final List<Map<String, dynamic>> images;
  final ValueChanged<List<Map<String, dynamic>>> onChanged;

  /// Acima disso o arquivo do projeto passa de ~10 MB e vai mal por WhatsApp.
  static const maxPages = 40;

  @override
  State<_ImagesEditor> createState() => _ImagesEditorState();
}

class _ImagesEditorState extends State<_ImagesEditor> {
  bool _busy = false;
  String _progress = '';

  List<Map<String, dynamic>> get _images => widget.images;

  int get _nextCode => _images.isEmpty ? 1 : _images.map((s) => (s['value'] as num?)?.toInt() ?? 0).reduce((a, b) => a > b ? a : b) + 1;

  void _update(int i, String k, Object? v) {
    final next = [for (final s in _images) Map<String, dynamic>.of(s)];
    next[i][k] = v;
    widget.onChanged(next);
  }

  Future<void> _addImages() async {
    try {
      // pickFiles (file_picker 13) já aceita várias; pickFile é o de uma só.
      final files = await FilePicker.pickFiles(type: FileType.image);
      if (files.isEmpty) return;
      setState(() => _busy = true);
      var code = _nextCode;
      final added = <Map<String, dynamic>>[];
      for (final f in files) {
        setState(() => _progress = 'Preparando imagem ${added.length + 1} de ${files.length}…');
        added.add({'value': code++, 'data': await shrinkToBase64Png(await f.readAsBytes(), maxSide: 1200)});
      }
      widget.onChanged([..._images, ...added]);
    } catch (_) {
      if (mounted) WriteActions.toast(context, 'Não consegui abrir as imagens.', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// PDF → uma imagem por página, na ordem, com código = número da página.
  /// A página é desenhada pelo próprio Android (pacote printing); a tela não
  /// precisa de leitor de PDF, e o projeto continua um arquivo só.
  Future<void> _importPdf() async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['pdf']);
      if (files.isEmpty) return;
      final bytes = await files.first.readAsBytes();
      setState(() {
        _busy = true;
        _progress = 'Abrindo o PDF…';
      });
      final pages = <Map<String, dynamic>>[];
      var truncated = false;
      await for (final page in Printing.raster(bytes, dpi: 110)) {
        if (pages.length >= _ImagesEditor.maxPages) {
          truncated = true;
          break;
        }
        if (mounted) setState(() => _progress = 'Página ${pages.length + 1}…');
        pages.add({'value': pages.length + 1, 'data': await shrinkToBase64Png(await page.toPng(), maxSide: 1200)});
      }
      if (pages.isEmpty) throw const FormatException('PDF sem páginas');
      // PDF substitui a lista: página N = código N só vale se a lista for a do PDF.
      widget.onChanged(pages);
      if (mounted) {
        WriteActions.toast(context, truncated
            ? 'Importei as ${_ImagesEditor.maxPages} primeiras páginas (limite para o projeto não ficar pesado).'
            : '${pages.length} páginas importadas.');
      }
    } catch (_) {
      if (mounted) WriteActions.toast(context, 'Não consegui abrir o PDF.', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _images.fold<int>(0, (n, s) => n + ((s['data'] as String?)?.length ?? 0));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < _images.length; i++)
        Padding(
          key: ValueKey('imagem-$i-${_images.length}'),
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 56,
                height: 56,
                color: Ind.bg,
                child: _images[i]['data'] is String
                    ? Image.memory(base64Decode(_images[i]['data'] as String), fit: BoxFit.cover, gaplessPlayback: true)
                    : Icon(Icons.image_not_supported_outlined, color: Ind.textMuted),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 90,
              child: TextFormField(
                initialValue: '${_images[i]['value'] ?? ''}',
                keyboardType: TextInputType.number,
                style: Ind.number(16),
                decoration: const InputDecoration(labelText: 'Código'),
                onChanged: (t) => _update(i, 'value', int.tryParse(t.trim())),
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Tirar imagem',
              onPressed: () => widget.onChanged([..._images]..removeAt(i)),
              icon: Icon(Icons.close_rounded, color: Ind.textMuted),
            ),
          ]),
        ),
      if (_busy)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(children: [
            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4)),
            const SizedBox(width: 12),
            Text(_progress, style: TextStyle(color: Ind.textDim)),
          ]),
        )
      else
        Wrap(spacing: 10, runSpacing: 10, children: [
          FilledButton.tonalIcon(onPressed: _addImages, icon: const Icon(Icons.add_photo_alternate_outlined), label: const Text('Acrescentar imagens')),
          FilledButton.tonalIcon(onPressed: _importPdf, icon: const Icon(Icons.picture_as_pdf_outlined), label: const Text('Importar PDF')),
        ]),
      if (_images.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text('${_images.length} ${_images.length == 1 ? 'imagem' : 'imagens'} · ${(bytes * 0.75 / 1048576).toStringAsFixed(1).replaceAll('.', ',')} MB no projeto',
            style: TextStyle(color: Ind.textMuted, fontSize: 12.5)),
      ],
    ]);
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(Ind.radiusSmall), border: Border.all(color: color.withValues(alpha: 0.4))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
        ]),
      );
}

/// "Mais opções" do elemento numa tela com imagem de fundo: **Fundo
/// transparente** — sem cartão, pousado no desenho, com o texto contornado
/// para ler sobre qualquer cor. Fechado, o resumo diz como está.
class _MoreOptions extends StatelessWidget {
  const _MoreOptions({required this.element, required this.onTransparent});
  final HmiElement element;
  final ValueChanged<bool> onTransparent;

  @override
  Widget build(BuildContext context) => Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: const ValueKey('mais-opcoes-elemento'),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          title: const Text('Mais opções'),
          subtitle: Text(element.transparent ? 'Fundo transparente' : 'Com cartão', style: TextStyle(color: Ind.textMuted, fontSize: 13)),
          children: [
            SwitchListTile(
              key: const ValueKey('fundo-transparente'),
              contentPadding: EdgeInsets.zero,
              value: element.transparent,
              onChanged: onTransparent,
              title: const Text('Fundo transparente'),
              subtitle: const Text('Sem cartão, direto sobre a imagem de fundo.'),
            ),
          ],
        ),
      );
}

/// Mover e redimensionar com toques (−/+ e setas), sempre dentro da grade e
/// sem sobrepor outro elemento — a mesma regra do arrasto.
class _GeometryEditor extends StatelessWidget {
  const _GeometryEditor({required this.screen, required this.element, required this.onChanged});
  final HmiScreen screen;
  final HmiElement element;
  final void Function(HmiElement) onChanged;

  void _try(HmiElement next) {
    if (ElementCatalog.fits(screen, next)) onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final e = element;
    // O mesmo − / + (e as setas no mesmo botão) dos campos numéricos.
    Widget step(String label, int value, HmiElement Function(int delta) change, String key) => StepperCounter(
          label: label,
          value: value,
          keyPrefix: key,
          onDecrease: ElementCatalog.fits(screen, change(-1)) ? () => _try(change(-1)) : null,
          onIncrease: ElementCatalog.fits(screen, change(1)) ? () => _try(change(1)) : null,
        );
    Widget arrow(IconData icon, int dx, int dy, String key) {
      final next = e.copyWith(x: e.x + dx, y: e.y + dy);
      return StepButton(key: ValueKey(key), size: const Size(52, 52), onTap: ElementCatalog.fits(screen, next) ? () => _try(next) : null, icon: icon);
    }

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: const ValueKey('posicao-e-tamanho'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        title: const Text('Posição e tamanho'),
        subtitle: Text('${e.w} × ${e.h} células · coluna ${e.x + 1}, linha ${e.y + 1}', style: TextStyle(color: Ind.textMuted, fontSize: 13)),
        children: [
          step('Largura', e.w, (d) => e.copyWith(w: e.w + d), 'largura'),
          const SizedBox(height: 8),
          step('Altura', e.h, (d) => e.copyWith(h: e.h + d), 'altura'),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: Text('Mover', style: TextStyle(color: Ind.text, fontSize: 16))),
            arrow(Icons.arrow_back_rounded, -1, 0, 'mover-esquerda'),
            const SizedBox(width: 6),
            arrow(Icons.arrow_upward_rounded, 0, -1, 'mover-cima'),
            const SizedBox(width: 6),
            arrow(Icons.arrow_downward_rounded, 0, 1, 'mover-baixo'),
            const SizedBox(width: 6),
            arrow(Icons.arrow_forward_rounded, 1, 0, 'mover-direita'),
          ]),
        ],
      ),
    );
  }
}
