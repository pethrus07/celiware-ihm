import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../models/camera.dart';
import '../../models/project.dart';
import '../../screens/cameras/camera_form_page.dart';

/// Escolha da câmera do botão "Abrir câmera": as da máquina da tela primeiro
/// e "Nova câmera" ali mesmo, para não sair do editor.
class CameraPick extends StatelessWidget {
  const CameraPick({super.key, required this.project, required this.selected, required this.preferDevices, required this.onChanged});
  final Project project;
  final String? selected;

  /// Máquinas que a tela já usa: as câmeras delas vêm primeiro.
  final Set<String> preferDevices;
  final ValueChanged<String> onChanged;

  Future<void> _create(BuildContext context) async {
    final id = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => CameraFormPage(deviceId: preferDevices.length == 1 ? preferDevices.single : null)),
    );
    if (id != null) onChanged(id);
  }

  @override
  Widget build(BuildContext context) {
    final cams = [
      ...project.cameras.where((c) => preferDevices.contains(c.deviceId)),
      ...project.cameras.where((c) => !preferDevices.contains(c.deviceId)),
    ];
    final newButton = ActionChip(
      key: const ValueKey('nova-camera-botao'),
      avatar: Icon(Icons.add_rounded, size: 18, color: Ind.accent),
      label: const Text('Nova câmera'),
      onPressed: () => _create(context),
    );
    if (cams.isEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Nenhuma câmera cadastrada ainda.', style: TextStyle(color: Ind.textDim)),
        const SizedBox(height: 10),
        newButton,
      ]);
    }
    String machine(IpCamera c) => c.deviceId == null ? '' : (project.device(c.deviceId!)?.name ?? '');
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final c in cams)
        ChoiceChip(
          key: ValueKey('escolher-camera-${c.id}'),
          avatar: const Icon(Icons.videocam_outlined, size: 18),
          label: Text(machine(c).isEmpty || preferDevices.length <= 1 ? c.name : '${c.name} · ${machine(c)}'),
          selected: selected == c.id,
          onSelected: (_) => onChanged(c.id),
        ),
      newButton,
    ]);
  }
}
