import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../models/hmi_screen.dart';
import '../../models/project.dart';
import '../../models/tag.dart';
import '../../services/runtime/tag_codec.dart';
import '../../widgets/common/common.dart';
import '../../widgets/hmi/element_catalog.dart';
import '../../widgets/hmi/elements/table_element.dart';
import '../../widgets/hmi/hmi_frame.dart';
import '../../widgets/hmi/write_actions.dart';
import '../tags/tag_form_page.dart';

/// Configuração da tabela de valores, na folha do elemento: as variáveis na
/// ordem das linhas, a escolha de várias de uma vez e o texto das linhas
/// liga/desliga. Como o resto da folha, tudo grava na hora.
///
/// Mora fora de `element_config_sheet.dart` de propósito: a folha só chama
/// [TableRowsEditor] e [tableTextFields].
class TableRowsEditor extends StatelessWidget {
  const TableRowsEditor({
    super.key,
    required this.project,
    required this.element,
    required this.onChanged,
    this.preferDevices = const {},
  });

  final Project project;
  final HmiElement element;
  final ValueChanged<List<String>> onChanged;

  /// Equipamentos que a tela já usa: vêm primeiro na escolha.
  final Set<String> preferDevices;

  @override
  Widget build(BuildContext context) {
    final rows = TableElement.rowsOf(element, project);
    final ids = [for (final t in rows) t.id];

    // `onReorderItem` já entrega o destino descontando a linha que saiu.
    void reorder(int from, int to) {
      final next = [...ids];
      next.insert(to, next.removeAt(from));
      onChanged(next);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (rows.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text.rich(
              TextSpan(children: [
                const TextSpan(text: 'Arraste '),
                WidgetSpan(alignment: PlaceholderAlignment.middle, child: Icon(Icons.drag_handle_rounded, size: 16, color: Ind.textMuted)),
                const TextSpan(text: ' para mudar a ordem das linhas.'),
              ]),
              style: TextStyle(color: Ind.textMuted, fontSize: 13),
            ),
          ),
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: rows.length,
          onReorderItem: reorder,
          // Linha arrastada sem a sombra quadrada padrão (o cartão já tem canto).
          proxyDecorator: (child, _, _) => Material(color: Colors.transparent, child: child),
          itemBuilder: (context, i) => _ChosenRow(
            key: ValueKey('linha-${rows[i].id}'),
            tag: rows[i],
            index: i,
            onRemove: () => onChanged([...ids]..removeAt(i)),
          ),
        ),
        Material(
          color: rows.isEmpty ? Ind.accent.withValues(alpha: 0.12) : Ind.surfaceHigh,
          borderRadius: BorderRadius.circular(Ind.radiusSmall),
          child: InkWell(
            key: const ValueKey('escolher-variaveis'),
            borderRadius: BorderRadius.circular(Ind.radiusSmall),
            onTap: () => TableTagChooser.show(context, selected: ids, preferDevices: preferDevices, onChanged: onChanged),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: Row(children: [
                Icon(rows.isEmpty ? Icons.link_rounded : Icons.playlist_add_rounded, color: Ind.accent),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(rows.isEmpty ? 'Escolher variáveis' : 'Escolher mais ou tirar',
                      style: TextStyle(color: Ind.accent, fontWeight: FontWeight.w700, fontSize: 16)),
                ),
                Text('${rows.length} de ${TableElement.maxRows}', style: TextStyle(color: Ind.textMuted, fontSize: 13)),
              ]),
            ),
          ),
        ),
      ],
    );
  }
}

/// Uma variável já escolhida: nome, endereço, valor ao vivo, tirar e a alça
/// de arrastar.
class _ChosenRow extends StatelessWidget {
  const _ChosenRow({super.key, required this.tag, required this.index, required this.onRemove});
  final Tag tag;
  final int index;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Ind.surfaceHigh,
        borderRadius: BorderRadius.circular(Ind.radiusSmall),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tag.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(tag.addressLabel, style: TextStyle(color: Ind.textMuted, fontSize: 12)),
              ]),
            ),
            TagBuilder(
              tagId: tag.id,
              builder: (_, t, r) => Text(TagCodec.format(tag, r.value), style: Ind.number(13, color: Ind.textDim)),
            ),
            IconButton(
              key: ValueKey('tirar-${tag.id}'),
              tooltip: 'Tirar da tabela',
              onPressed: onRemove,
              icon: Icon(Icons.close_rounded, color: Ind.textMuted),
            ),
            ReorderableDragStartListener(
              index: index,
              child: SizedBox(
                key: ValueKey('arrastar-${tag.id}'),
                width: 44,
                height: 48,
                child: Icon(Icons.drag_handle_rounded, color: Ind.textDim),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Escolha de várias variáveis de uma vez: tocar marca ou desmarca, e a
/// tabela muda na hora (a ordem é a dos toques; dá para arrumar depois).
///
/// Agrupada por equipamento — os da tela primeiro — e com busca a partir de 8
/// variáveis, como a escolha de uma variável só.
class TableTagChooser extends StatefulWidget {
  const TableTagChooser({super.key, required this.selected, required this.onChanged, this.preferDevices = const {}});

  final List<String> selected;
  final ValueChanged<List<String>> onChanged;
  final Set<String> preferDevices;

  static Future<void> show(BuildContext context,
          {required List<String> selected, required ValueChanged<List<String>> onChanged, Set<String> preferDevices = const {}}) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => TableTagChooser(selected: selected, onChanged: onChanged, preferDevices: preferDevices),
      );

  @override
  State<TableTagChooser> createState() => _TableTagChooserState();
}

class _TableTagChooserState extends State<TableTagChooser> {
  late final List<String> _selected = [...widget.selected];
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

  void _toggle(Tag t) {
    setState(() {
      if (_selected.contains(t.id)) {
        _selected.remove(t.id);
      } else if (_selected.length < TableElement.maxRows) {
        _selected.add(t.id);
      } else {
        WriteActions.toast(context, 'A tabela mostra até ${TableElement.maxRows} variáveis.');
        return;
      }
    });
    widget.onChanged([..._selected]);
  }

  @override
  Widget build(BuildContext context) {
    final project = AppScope.watch(context).controller.project;
    final compatible = project.tags.where(TagFit.any.accepts).toList();
    final shown = compatible.where(_matches).toList();
    final devices = [
      ...project.devices.where((d) => widget.preferDevices.contains(d.id)),
      ...project.devices.where((d) => !widget.preferDevices.contains(d.id)),
    ];
    final grouped = devices.length > 1;
    final n = _selected.where((id) => project.tag(id) != null).length;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 16),
              children: [
                Text('Escolha as variáveis', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text('Toque para marcar. Cada uma vira uma linha da tabela.', style: TextStyle(color: Ind.textDim)),
                const SizedBox(height: Ind.space),
                if (compatible.length >= 8) ...[
                  TextField(
                    key: const ValueKey('buscar-variaveis'),
                    onChanged: (v) => setState(() => _query = v),
                    decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Buscar por nome ou endereço'),
                  ),
                  const SizedBox(height: Ind.space),
                ],
                if (compatible.isEmpty)
                  Text('Nenhuma variável ainda. Crie a primeira abaixo.', style: TextStyle(color: Ind.textDim))
                else if (shown.isEmpty)
                  Text('Nenhuma variável com "$_query".', style: TextStyle(color: Ind.textDim)),
                for (final d in devices) ...[
                  if (grouped && shown.any((t) => t.deviceId == d.id))
                    SectionHeader(d.name, padding: const EdgeInsets.fromLTRB(4, 12, 0, 10)),
                  for (final t in shown.where((t) => t.deviceId == d.id))
                    _CheckRow(
                      tag: t,
                      detail: '${grouped ? '' : '${d.name} · '}${t.addressLabel}',
                      checked: _selected.contains(t.id),
                      onTap: () => _toggle(t),
                    ),
                ],
                const SizedBox(height: Ind.spaceSmall),
                OutlinedButton.icon(
                  key: const ValueKey('criar-variavel-tabela'),
                  onPressed: () async {
                    final created = await Navigator.push<Tag>(
                      context,
                      MaterialPageRoute(builder: (_) => TagFormPage(fit: TagFit.any, preferDeviceId: widget.preferDevices.firstOrNull)),
                    );
                    if (created != null && mounted && !_selected.contains(created.id)) _toggle(created);
                  },
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Criar variável'),
                ),
              ],
            ),
          ),
          // "Pronto" sempre à vista: a lista pode ser longa e já está gravada.
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Ind.page, 8, Ind.page, 12),
              child: FilledButton(
                key: const ValueKey('pronto-variaveis'),
                onPressed: () => Navigator.pop(context),
                child: Text(n == 0 ? 'Pronto' : 'Pronto · $n ${n == 1 ? 'variável' : 'variáveis'}'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.tag, required this.detail, required this.checked, required this.onTap});
  final Tag tag;
  final String detail;
  final bool checked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: checked ? Ind.accent.withValues(alpha: 0.14) : Ind.surfaceHigh,
        borderRadius: BorderRadius.circular(Ind.radiusSmall),
        child: InkWell(
          key: ValueKey('marcar-${tag.id}'),
          borderRadius: BorderRadius.circular(Ind.radiusSmall),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              Icon(checked ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded, color: checked ? Ind.accent : Ind.textMuted, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(tag.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(detail, style: TextStyle(color: Ind.textMuted, fontSize: 12)),
                ]),
              ),
              TagBuilder(
                tagId: tag.id,
                builder: (_, t, r) => Text(TagCodec.format(tag, r.value), style: Ind.number(13, color: Ind.textDim)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Texto das linhas liga/desliga — só aparece quando a tabela tem alguma.
List<Widget> tableTextFields(Project project, HmiElement e, void Function(String key, Object? value) set) {
  final hasBool = TableElement.rowsOf(e, project).any((t) => t.dataType == TagDataType.bool);
  if (!hasBool) return const [];
  return [
    const SectionHeader('Linhas liga / desliga', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)),
    Row(children: [
      Expanded(child: _TextField(label: 'Texto ligado', value: e.prop<String>('onText', 'LIGADO'), onChanged: (v) => set('onText', v))),
      const SizedBox(width: 10),
      Expanded(child: _TextField(label: 'Texto desligado', value: e.prop<String>('offText', 'DESLIGADO'), onChanged: (v) => set('offText', v))),
    ]),
  ];
}

class _TextField extends StatelessWidget {
  const _TextField({required this.label, required this.value, required this.onChanged});
  final String label;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => TextFormField(
        initialValue: value,
        decoration: InputDecoration(labelText: label),
        textCapitalization: TextCapitalization.characters,
        onChanged: onChanged,
      );
}
