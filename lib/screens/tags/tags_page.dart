import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../models/tag.dart';
import '../../services/runtime/tag_codec.dart';
import '../../services/runtime/tag_store.dart';
import '../../services/alarms/alarm_engine.dart';
import '../../widgets/alarms/alarm_widgets.dart';
import '../../widgets/common/common.dart';
import '../../widgets/hmi/hmi_frame.dart';
import '../../widgets/hmi/live_tags.dart';
import '../../widgets/tour/tour.dart';
import '../tours.dart';
import 'tag_form_page.dart';

/// Lista de variáveis, agrupadas por equipamento, com o valor **ao vivo**.
///
/// Ver o valor ao lado do nome é o jeito mais rápido de conferir que um
/// endereço está certo: se "Velocidade" mostra 80 e a máquina está a 80, está.
class TagsPage extends StatefulWidget {
  const TagsPage({super.key, this.startTour = false});
  final bool startTour;

  @override
  State<TagsPage> createState() => _TagsPageState();
}

class _TagsPageState extends State<TagsPage> {
  final _listKey = GlobalKey();
  final _addKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final project = AppScope.watch(context).controller.project;

    return LiveTags(
      tagIds: {for (final t in project.tags) t.id},
      child: TourHost(
        spec: Tours.variaveis(list: _listKey, add: _addKey),
        // Só pelo "?" ou por Mais → Tutoriais (ver DevicesPage).
        autoStart: false,
        forceStart: widget.startTour,
        child: Scaffold(
          appBar: AppBar(title: const Text('Variáveis'), actions: const [HelpButton()]),
          floatingActionButton: FloatingActionButton.extended(
            key: _addKey,
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TagFormPage())),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Nova variável'),
          ),
          body: project.tags.isEmpty
              ? KeyedSubtree(
                  key: _listKey,
                  child: EmptyState(
                    icon: Icons.data_object_rounded,
                    title: 'Nenhuma variável',
                    body: project.devices.isEmpty
                        ? 'Primeiro cadastre um equipamento (aba Equipamentos). Depois dê nome às memórias dele aqui.'
                        : 'Dê nome a uma memória do equipamento: "Velocidade" = registrador 2.',
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 100),
                  children: [
                    for (final d in project.devices)
                      if (project.tagsOf(d.id).isNotEmpty) ...[
                        SectionHeader(d.name, trailing: LinkChip(device: d)),
                        for (final t in project.tagsOf(d.id))
                          // O tutorial realça a primeira variável, não a lista inteira.
                          KeyedSubtree(key: t.id == project.tags.first.id ? _listKey : null, child: _TagTile(tag: t)),
                      ],
                  ],
                ),
        ),
      ),
    );
  }
}

class _TagTile extends StatelessWidget {
  const _TagTile({required this.tag});
  final Tag tag;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: ValueKey('var-${tag.id}'),
      leading: Icon(
        tag.dataType == TagDataType.bool
            ? Icons.toggle_on_outlined
            : tag.isText
                ? Icons.text_fields_rounded
                : (tag.isArray ? Icons.view_week_outlined : Icons.pin_outlined),
        color: Ind.textDim,
      ),
      title: Text(tag.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
      // Só o endereço: tipo e permissão ficam no cadastro — na lista, o que
      // importa é "qual memória" e "quanto vale agora".
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Row(children: [
          Text(tag.addressLabel, style: TextStyle(color: Ind.textMuted, fontSize: 13)),
          // Tem alarme configurado: sino discreto; em alarme agora: a forma
          // da prioridade (piscando se ninguém reconheceu).
          if (tag.alarms.isNotEmpty) ...[
            const SizedBox(width: 8),
            ListenableBuilder(
              listenable: AppScope.of(context).alarms,
              builder: (context, _) {
                final a = AppScope.of(context).alarms.forTag(tag.id);
                return a == null
                    ? Icon(Icons.notifications_none_rounded, size: 15, color: Ind.textMuted)
                    : AlarmShape(priority: a.priority, size: 16, blinking: a.phase.unacked);
              },
            ),
          ],
        ]),
      ),
      trailing: TagBuilder(
        tagId: tag.id,
        builder: (context, _, r) {
          final (text, color) = switch (r.quality) {
            TagQuality.addressError || TagQuality.configError => ('erro', Ind.alarm),
            TagQuality.commLost => (TagCodec.format(tag, _scalar(r.value)), Ind.textMuted),
            _ => (TagCodec.format(tag, _scalar(r.value)), r.value == true ? Ind.ok : Ind.text),
          };
          return ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(text, overflow: TextOverflow.ellipsis, textAlign: TextAlign.right, style: Ind.number(15, color: color)),
          );
        },
      ),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TagFormPage(tag: tag))),
    );
  }

  static Object? _scalar(Object? v) => v is List ? '[${v.length} valores]' : v;
}
