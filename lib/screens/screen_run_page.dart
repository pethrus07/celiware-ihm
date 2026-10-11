import 'package:flutter/material.dart';

import '../app/app_scope.dart';
import '../core/theme/app_theme.dart';
import '../models/device.dart';
import '../models/hmi_screen.dart';
import '../models/project.dart';
import '../widgets/common/common.dart';
import '../widgets/hmi/hmi_canvas.dart';
import '../widgets/hmi/live_tags.dart';
import '../widgets/hmi/write_actions.dart';
import '../widgets/tour/tour.dart';
import 'editor/screen_editor_page.dart';
import 'tours.dart';

/// Tela em operação — o que o operador usa no dia a dia.
///
/// Ao abrir, inscreve no [HmiRuntime] as variáveis dos elementos (é isso que
/// liga a varredura dos equipamentos envolvidos). Se a tela for editada,
/// refaz a inscrição com o conjunto novo. Ao sair, cancela a inscrição e
/// **solta todos os botões de pulso** — nenhum comando fica preso.
class ScreenRunPage extends StatefulWidget {
  const ScreenRunPage({super.key, required this.screenId, this.startTour = false});
  final String screenId;
  final bool startTour;

  @override
  State<ScreenRunPage> createState() => _ScreenRunPageState();
}

class _ScreenRunPageState extends State<ScreenRunPage> {
  final _linkKey = GlobalKey();
  final _editKey = GlobalKey();
  final _statusKey = GlobalKey();
  final _buttonKey = GlobalKey();
  final _inputKey = GlobalKey();

  /// Troca de tela **substitui** esta (como numa IHM de painel): só a tela à
  /// vista fica sendo lida, e o "voltar" leva à lista de telas, não a uma
  /// pilha de telas visitadas.
  void _open(Project project, String id) {
    if (id == widget.screenId) return;
    if (project.screen(id) == null) {
      WriteActions.toast(context, 'A tela deste atalho foi apagada.', error: true);
      return;
    }
    Navigator.pushReplacement(context, PageRouteBuilder(
      pageBuilder: (_, _, _) => ScreenRunPage(screenId: id),
      transitionDuration: const Duration(milliseconds: 160),
      transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final project = AppScope.watch(context).controller.project;
    final screen = project.screen(widget.screenId);
    if (screen == null) {
      return Scaffold(appBar: AppBar(), body: const EmptyState(icon: Icons.search_off_rounded, title: 'Tela não encontrada', body: 'Ela pode ter sido apagada.'));
    }

    final devices = <Device>[
      for (final id in {for (final t in screen.tagIds) project.tag(t)?.deviceId}.whereType<String>())
        ?project.device(id),
    ];

    // Alvos do tutorial: o primeiro elemento de cada tipo relevante.
    String? firstOf(ElementType t) => screen.elements.where((e) => e.type == t).firstOrNull?.id;
    final targets = {
      firstOf(ElementType.multistate): _statusKey,
      firstOf(ElementType.button): _buttonKey,
      firstOf(ElementType.input): _inputKey,
    }..remove(null);

    return LiveTags(
      tagIds: screen.liveTagIds,
      releaseOnDispose: true,
      child: TourHost(
      spec: Tours.operar(status: _statusKey, button: _buttonKey, input: _inputKey, link: _linkKey, edit: _editKey),
      forceStart: widget.startTour,
      child: Scaffold(
        appBar: AppBar(
          title: Text(screen.name),
          actions: [
            IconButton(
              key: _editKey,
              tooltip: 'Editar esta tela',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ScreenEditorPage(screenId: screen.id))),
            ),
            const HelpButton(),
          ],
          bottom: devices.isEmpty
              ? null
              : PreferredSize(
                  preferredSize: const Size.fromHeight(40),
                  child: Container(
                    key: _linkKey,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(children: [
                        if (screen.readOnly) ...[
                          Icon(Icons.visibility_outlined, size: 16, color: Ind.textDim),
                          const SizedBox(width: 4),
                          Text('Só acompanhamento', style: TextStyle(color: Ind.textDim, fontSize: 12)),
                          const SizedBox(width: 10),
                        ],
                        for (final d in devices) Padding(padding: const EdgeInsets.only(right: 6), child: LinkChip(device: d)),
                      ]),
                    ),
                  ),
                ),
        ),
        body: screen.elements.isEmpty
            ? EmptyState(
                icon: Icons.widgets_outlined,
                title: 'Tela vazia',
                body: 'Toque no lápis para colocar botões, mostradores e gráficos.',
                action: FilledButton.icon(
                  onPressed: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ScreenEditorPage(screenId: screen.id))),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Montar a tela'),
                ),
              )
            : HmiCanvas(screen: screen, keyFor: (e) => targets[e.id], onNavigate: (id) => _open(project, id)),
      ),
      ),
    );
  }
}
