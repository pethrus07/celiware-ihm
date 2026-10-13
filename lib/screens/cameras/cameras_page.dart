import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../models/camera.dart';
import '../../models/project.dart';
import '../../services/cameras/camera_vault.dart';
import '../../widgets/common/adaptive.dart';
import '../../widgets/common/common.dart';
import '../../widgets/tour/tour.dart';
import '../tours.dart';
import 'camera_form_page.dart';
import 'camera_view_page.dart';

/// Mais → Câmeras (CM-1, CM-2): as câmeras agrupadas por máquina. Tocar abre
/// em tela cheia; o lápis abre o cadastro.
class CamerasPage extends StatelessWidget {
  const CamerasPage({super.key});

  /// "Ver a máquina ao vivo" ou "2 câmeras".
  static String summary(Project p) {
    final n = p.cameras.length;
    if (n == 0) return 'Ver a máquina ao vivo, em tela cheia';
    return n == 1 ? '1 câmera' : '$n câmeras';
  }

  @override
  Widget build(BuildContext context) {
    final project = AppScope.watch(context).controller.project;
    // Agrupadas por máquina, na ordem dos equipamentos; sem máquina no fim.
    final groups = <(String, List<IpCamera>)>[
      for (final d in project.equipment)
        if (project.camerasOf(d.id).isNotEmpty) (d.name, project.camerasOf(d.id)),
    ];
    final loose = project.cameras.where((c) => c.deviceId == null || project.device(c.deviceId!) == null).toList();
    if (loose.isNotEmpty) groups.add((groups.isEmpty ? '' : 'Sem máquina', loose));

    // "?" explica a página (não abre sozinho), como Registros, Receitas e Regras.
    return TourHost(
      spec: Tours.cameras(),
      autoStart: false,
      child: Scaffold(
        appBar: AppBar(title: const Text('Câmeras'), actions: const [HelpButton()]),
        floatingActionButton: FloatingActionButton.extended(
          key: const ValueKey('nova-camera'),
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CameraFormPage())),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Nova câmera'),
        ),
        body: project.cameras.isEmpty
            ? const EmptyState(
                icon: Icons.videocam_outlined,
                title: 'Nenhuma câmera',
                body: 'Cadastre a câmera IP da máquina para ver ao vivo, em tela cheia. '
                    'Na tela de operação, um Botão no modo "Abrir câmera" abre direto.',
              )
            : FormWidth(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 110),
                  children: [
                    for (final (title, cams) in groups) ...[
                      if (title.isNotEmpty) SectionHeader(title) else const SizedBox(height: 12),
                      for (final c in cams) _CameraTile(camera: c),
                    ],
                  ],
                ),
              ),
      ),
    );
  }
}

class _CameraTile extends StatelessWidget {
  const _CameraTile({required this.camera});
  final IpCamera camera;

  @override
  Widget build(BuildContext context) {
    final ref = camera.secretRef;
    return ListTile(
      key: ValueKey('camera-${camera.id}'),
      leading: Icon(Icons.videocam_outlined, color: Ind.accent),
      title: Text(camera.name, style: const TextStyle(fontWeight: FontWeight.w600)),
      // Projeto importado: a senha não veio. Avisa aqui, antes de abrir.
      subtitle: ref == null
          ? Text(camera.host)
          : FutureBuilder<String?>(
              future: CameraVault.instance.read(ref),
              builder: (context, snap) => snap.connectionState == ConnectionState.done && snap.data == null
                  ? Text('${camera.host} · falta a senha neste aparelho', style: TextStyle(color: Ind.textFor(Ind.warn)))
                  : Text(camera.host),
            ),
      trailing: IconButton(
        key: ValueKey('editar-camera-${camera.id}'),
        tooltip: 'Editar',
        icon: const Icon(Icons.edit_outlined),
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CameraFormPage(camera: camera))),
      ),
      onTap: () => CameraViewPage.open(context, camera.id),
    );
  }
}
