import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../models/device.dart';
import '../../models/project.dart';
import '../../models/tag.dart';
import '../../services/runtime/tag_codec.dart';
import '../../services/runtime/tag_store.dart';
import '../../services/alarms/alarm_engine.dart';
import '../../widgets/alarms/alarm_widgets.dart';
import '../../widgets/common/adaptive.dart';
import '../../widgets/common/common.dart';
import '../../widgets/hmi/hmi_frame.dart';
import '../../widgets/hmi/live_tags.dart';
import '../../widgets/tour/tour.dart';
import '../tours.dart';
import 'bulk_tags_page.dart';
import 'tag_form_page.dart';

/// Lista de variáveis, agrupadas por equipamento, com o valor **ao vivo**.
///
/// Ver o valor ao lado do nome é o jeito mais rápido de conferir que um
/// endereço está certo: se "Velocidade" mostra 80 e a máquina está a 80, está.
///
/// Feita para milhares de variáveis (IF-3): a lista é montada sob demanda
/// (`ListView.builder`) e só as linhas à vista ficam sendo lidas
/// ([VisibleLiveTags]). Antes ela montava e inscrevia todas — com mil
/// variáveis, abrir a aba varria o CLP inteiro.
///
/// No tablet deitado o cadastro abre ao lado da lista ([ListDetail], TB-2):
/// dá para conferir o valor ao vivo na lista enquanto acerta o endereço.
class TagsPage extends StatefulWidget {
  const TagsPage({super.key, this.startTour = false});
  final bool startTour;

  @override
  State<TagsPage> createState() => _TagsPageState();
}

class _TagsPageState extends State<TagsPage> {
  final _listKey = GlobalKey();
  final _addKey = GlobalKey();
  final _panes = GlobalKey<ListDetailState>();

  /// Item do painel para o cadastro novo (não colide com id de variável).
  static const _nova = '+nova';

  Future<void> _createMany(BuildContext context) async {
    final message = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const BulkTagsPage()));
    if (message != null && context.mounted) {
      // O resultado novo troca o anterior em vez de entrar na fila.
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final project = AppScope.watch(context).controller.project;
    final rows = _rows(project);
    // A primeira linha de variável da tela (a linha 0 é o cabeçalho do equipamento).
    final firstId = rows.length > 1 ? rows[1].$2?.id : null;

    return VisibleLiveTags(
      child: TourHost(
        spec: Tours.variaveis(list: _listKey, add: _addKey),
        // Só pelo "?" ou por Mais → Tutoriais (ver DevicesPage).
        autoStart: false,
        forceStart: widget.startTour,
        child: ListDetail(
          key: _panes,
          placeholder: const Scaffold(
            body: EmptyState(
              icon: Icons.data_object_rounded,
              title: 'Escolha uma variável',
              body: 'Toque numa variável da lista para ver e editar, ou crie uma nova.',
            ),
          ),
          list: Scaffold(
            appBar: AppBar(title: const Text('Variáveis'), actions: [
              IconButton(
                key: const ValueKey('criar-varias'),
                tooltip: 'Criar várias',
                icon: const Icon(Icons.playlist_add_rounded),
                onPressed: project.devices.isEmpty ? null : () => _createMany(context),
              ),
              const HelpButton(),
            ]),
            floatingActionButton: FloatingActionButton.extended(
              key: _addKey,
              onPressed: () => _panes.currentState?.open(_nova, (_) => const TagFormPage()),
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
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 100),
                    itemCount: rows.length,
                    itemBuilder: (context, i) => switch (rows[i]) {
                      (final Device d, null) => SectionHeader(d.name, key: ValueKey('secao-${d.id}'), trailing: LinkChip(device: d)),
                      (_, final Tag t) => KeyedSubtree(
                          // O tutorial realça a primeira variável, não a lista inteira.
                          key: t.id == firstId ? _listKey : ValueKey('linha-${t.id}'),
                          child: LiveTagItem(tagId: t.id, child: _TagTile(tag: t)),
                        ),
                    },
                  ),
          ),
        ),
      ),
    );
  }

  /// Linhas já achatadas: cabeçalho do equipamento e as variáveis dele, na
  /// ordem de cadastro. Agrupar num mapa evita varrer a lista inteira uma vez
  /// por equipamento.
  static List<(Device, Tag?)> _rows(Project project) {
    final byDevice = <String, List<Tag>>{};
    for (final t in project.tags) {
      byDevice.putIfAbsent(t.deviceId, () => []).add(t);
    }
    return [
      for (final d in project.devices)
        if (byDevice[d.id] case final tags?) ...[
          (d, null),
          for (final t in tags) (d, t),
        ],
    ];
  }
}

class _TagTile extends StatelessWidget {
  const _TagTile({required this.tag});
  final Tag tag;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: ValueKey('var-${tag.id}'),
      // Aberta no painel ao lado (tablet): a linha fica marcada.
      selected: ListDetail.selectedOf(context) == tag.id,
      selectedTileColor: Ind.accent.withValues(alpha: 0.12),
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
          // Com perfil de fabricante, a memória do manual vem antes: "D200 · HR 200".
          Flexible(child: Text(tag.memoryLabel, overflow: TextOverflow.ellipsis, style: TextStyle(color: Ind.textMuted, fontSize: 13))),
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
            // Ligado não é "bom": "Alarme ativo · LIGADO" em verde dizia o
            // contrário. Cor só para o que pede atenção (erro), como na tela.
            _ => (TagCodec.format(tag, _scalar(r.value)), Ind.text),
          };
          return ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(text, overflow: TextOverflow.ellipsis, textAlign: TextAlign.right, style: Ind.number(15, color: color)),
          );
        },
      ),
      onTap: () => ListDetail.of(context).open(tag.id, (_) => TagFormPage(tag: tag)),
    );
  }

  static Object? _scalar(Object? v) => v is List ? '[${v.length} valores]' : v;
}
