import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/image_util.dart';
import '../../models/hmi_screen.dart';
import '../../models/project.dart';
import '../../models/tag.dart';
import '../../services/runtime/tag_codec.dart';
import '../../widgets/common/common.dart';
import '../../widgets/hmi/element_catalog.dart';
import '../../widgets/hmi/elements/control_elements.dart';
import '../../widgets/hmi/hmi_canvas.dart';
import '../../widgets/hmi/hmi_frame.dart';
import '../../widgets/hmi/live_tags.dart';
import '../../widgets/hmi/write_actions.dart';
import '../tags/tag_form_page.dart';

/// Configuração de um elemento: prévia ao vivo no topo, campos do tipo
/// embaixo. Tudo salva na hora (sem botão Salvar).
///
/// Só mostra o que faz sentido para o tipo — botão não pergunta mínimo e
/// máximo; medidor não pergunta cor de "ligado". A lista de variáveis mostra
/// só as compatíveis (o botão de pulso não oferece variável numérica) e tem
/// "Criar variável" ali mesmo, para não precisar sair do editor.
class ElementConfigSheet extends StatelessWidget {
  const ElementConfigSheet({super.key, required this.screenId, required this.elementId});

  final String screenId;
  final String elementId;

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
    return LiveTags(
      tagIds: {for (final t in project.tags) t.id},
      child: DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.86,
      maxChildSize: 0.96,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 40),
        children: [
          Row(children: [
            Icon(info.icon, color: Ind.accent),
            const SizedBox(width: 10),
            Expanded(child: Text(info.name, style: Theme.of(context).textTheme.titleLarge)),
          ]),
          const SizedBox(height: 12),
          _Preview(element: e),
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

    // ── Variável ──
    if (info.fit != TagFit.none) {
      if (info.multiTag) {
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
          onChanged: (t) {
            var next = e.withProp('tagId', t.id);
            // Rótulo vazio ou ainda igual ao nome da variável anterior → segue a nova.
            final label = e.props['label'] as String?;
            if (label == null || label.isEmpty || label == tag?.name) next = next.withProp('label', t.name);
            save(next);
          },
        ));
      }
    }

    // ── Texto do elemento ──
    if (e.type != ElementType.label && e.type != ElementType.image) {
      w.add(const SizedBox(height: 16));
      w.add(_TextProp(key: ValueKey('rotulo-${tag?.id}'), label: 'Rótulo', value: e.prop<String>('label', ''), onChanged: (v) => set('label', v)));
    }

    switch (e.type) {
      case ElementType.button:
        final mode = ButtonModeMeta.fromName(e.prop<String>('mode', 'toggle'));
        w.add(const SectionHeader('Como o botão age', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)));
        w.add(ChoiceCards<ButtonMode>(
          options: const [
            ChoiceOption(value: ButtonMode.toggle, title: 'Liga / desliga', icon: Icons.toggle_on_outlined),
            ChoiceOption(value: ButtonMode.momentary, title: 'Pulso', icon: Icons.touch_app_outlined),
            ChoiceOption(value: ButtonMode.set, title: 'Só liga', icon: Icons.power_settings_new_rounded),
            ChoiceOption(value: ButtonMode.reset, title: 'Só desliga', icon: Icons.power_off_outlined),
            ChoiceOption(value: ButtonMode.value, title: 'Grava valor', icon: Icons.onetwothree_rounded),
          ],
          selected: mode,
          onChanged: (m) {
            var next = e.withProp('mode', m.name);
            // Trocou entre modo de bit e modo numérico: a variável atual pode
            // não servir mais — solta para o usuário escolher de novo.
            if (tag != null && (m.needsNumber != mode.needsNumber)) next = next.withProp('tagId', null);
            save(next);
          },
        ));
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
        w.add(_ColorProp(label: 'Cor acesa', value: e.prop<String>('color', 'green'), onChanged: (v) => set('color', v)));
      case ElementType.input:
        w.add(const SectionHeader('Limites de segurança', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)));
        w.add(const Text('O operador não consegue digitar fora desta faixa.', style: TextStyle(color: Ind.textDim)));
        w.add(const SizedBox(height: 10));
        w.add(_MinMax(e: e, set: set));
      case ElementType.bar:
        w.add(const SectionHeader('Escala', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)));
        w.add(_MinMax(e: e, set: set, defaults: (0, 100)));
        w.add(_ColorProp(label: 'Cor da barra', value: e.prop<String>('color', 'blue'), onChanged: (v) => set('color', v)));
      case ElementType.gauge:
        w.add(const SectionHeader('Escala e faixas', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)));
        w.add(_MinMax(e: e, set: set, defaults: (0, 100)));
        w.add(const SizedBox(height: 10));
        w.add(Row(children: [
          Expanded(child: _NumProp(label: 'Atenção a partir de', value: e.props['warn'] as num?, onChanged: (v) => set('warn', v), color: Ind.warn)),
          const SizedBox(width: 10),
          Expanded(child: _NumProp(label: 'Alarme a partir de', value: e.props['alarm'] as num?, onChanged: (v) => set('alarm', v), color: Ind.alarm)),
        ]));
      case ElementType.multistate:
        w.add(const SectionHeader('Estados', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)));
        w.add(const Text('Para cada código que o equipamento manda, o texto e a cor que aparecem.', style: TextStyle(color: Ind.textDim)));
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
        w.add(const SizedBox(height: 12));
        w.add(FilledButton.icon(
          onPressed: () => _pickImage(context, set),
          icon: const Icon(Icons.photo_library_outlined),
          label: Text(e.props['data'] == null ? 'Escolher imagem' : 'Trocar imagem'),
        ));
        w.add(const SizedBox(height: 12));
        w.add(Wrap(spacing: 8, children: [
          for (final (v, t) in [('contain', 'Mostrar inteira'), ('cover', 'Preencher o espaço')])
            ChoiceChip(label: Text(t), selected: e.prop<String>('fit', 'contain') == v, onSelected: (_) => set('fit', v)),
        ]));
      case ElementType.value:
      case ElementType.barChart:
      case ElementType.unknown:
        break;
    }

    if (tag != null && info.writes && !tag.canWrite) {
      w.add(const SizedBox(height: 16));
      w.add(_Hint(icon: Icons.lock_outline_rounded, color: Ind.warn,
          text: '"${tag.name}" está como só leitura. Para este elemento gravar, abra a variável e marque "Pode ser alterada pela tela".'));
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
  const _Preview({required this.element});
  final HmiElement element;

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
              child: HmiScreenContext(editMode: true, readOnly: true, confirmWrites: true, child: HmiElementView(element: element)),
            ),
          ),
        ]),
      );
    });
  }
}

class _TagPicker extends StatelessWidget {
  const _TagPicker({required this.project, required this.fit, required this.selected, required this.onChanged, this.needsWritable = false});
  final Project project;
  final TagFit fit;
  final Tag? selected;
  final bool needsWritable;
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
              final picked = await _TagChooser.show(context, fit: fit, needsWritable: needsWritable, selectedId: t?.id);
              if (picked != null) onChanged(picked);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: Row(children: [
                Icon(t == null ? Icons.link_rounded : Icons.data_object_rounded, color: t == null ? Ind.accent : Ind.textDim),
                const SizedBox(width: 14),
                Expanded(
                  child: t == null
                      ? const Text('Escolher variável', style: TextStyle(color: Ind.accent, fontWeight: FontWeight.w700, fontSize: 16))
                      : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(t.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                          const SizedBox(height: 2),
                          Text(t.addressLabel, style: const TextStyle(color: Ind.textMuted, fontSize: 13)),
                        ]),
                ),
                const Icon(Icons.chevron_right_rounded, color: Ind.textMuted),
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
class _TagChooser extends StatelessWidget {
  const _TagChooser({required this.fit, required this.needsWritable, this.selectedId});
  final TagFit fit;
  final bool needsWritable;
  final String? selectedId;

  static Future<Tag?> show(BuildContext context, {required TagFit fit, required bool needsWritable, String? selectedId}) =>
      showModalBottomSheet<Tag>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => _TagChooser(fit: fit, needsWritable: needsWritable, selectedId: selectedId),
      );

  @override
  Widget build(BuildContext context) {
    final project = AppScope.watch(context).controller.project;
    final compatible = project.tags.where(fit.accepts).toList();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 32),
        children: [
          Text('Escolha a variável', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Ind.space),
          if (compatible.isEmpty)
            _Hint(icon: Icons.info_outline_rounded, color: Ind.info, text: 'Nenhuma ${fit.requirement} ainda.'),
          for (final t in compatible)
            _TagRow(tag: t, project: project, selected: t.id == selectedId, warnReadOnly: needsWritable && !t.canWrite, onTap: () => Navigator.pop(context, t)),
          const SizedBox(height: Ind.spaceSmall),
          OutlinedButton.icon(
            key: const ValueKey('criar-variavel-aqui'),
            onPressed: () async {
              final created = await Navigator.push<Tag>(
                context,
                MaterialPageRoute(builder: (_) => TagFormPage(fit: fit, preferWritable: needsWritable)),
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
        if (compatible.isEmpty) const _Hint(icon: Icons.info_outline_rounded, color: Ind.info, text: 'Nenhuma variável numérica ainda.'),
      ],
    );
  }
}

class _TagRow extends StatelessWidget {
  const _TagRow({required this.tag, required this.project, required this.selected, required this.onTap, this.warnReadOnly = false});
  final Tag tag;
  final Project project;
  final bool selected;
  final bool warnReadOnly;
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
                  Text('${project.device(tag.deviceId)?.name ?? '?'} · ${tag.addressLabel}${warnReadOnly ? ' · só leitura' : ''}',
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
  const _NumProp({required this.label, required this.value, required this.onChanged, this.color});
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
                child: value == c.name ? const Icon(Icons.check_rounded, color: Ind.bg) : null,
              ),
            ),
          ),
      ]),
      const SizedBox(height: 6),
      Text(StateColorMeta.fromName(value).label, style: const TextStyle(color: Ind.textDim, fontSize: 12.5)),
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
            SizedBox(
              width: 70,
              child: TextFormField(
                initialValue: '${states[i]['value'] ?? ''}',
                keyboardType: TextInputType.number,
                style: Ind.number(16),
                decoration: const InputDecoration(labelText: 'Código'),
                onChanged: (t) => update(i, 'value', int.tryParse(t.trim())),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextFormField(
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
              icon: const Icon(Icons.close_rounded, color: Ind.textMuted),
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
