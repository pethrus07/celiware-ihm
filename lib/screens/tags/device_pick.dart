import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../models/device.dart';
import '../../widgets/common/common.dart';

/// Escolha do equipamento da variável.
///
/// Até 3 equipamentos: cartões à vista, como sempre (todas as opções sem
/// tocar em nada). Com 4 ou mais, os cartões viravam uma pilha que empurrava
/// o formulário para baixo — vira uma linha só, que abre a lista; a busca
/// (nome ou IP, sem acento) aparece a partir de 8, como na escolha de
/// variável do editor.
class DevicePick extends StatelessWidget {
  const DevicePick({super.key, required this.devices, required this.selectedId, required this.onChanged});

  final List<Device> devices;
  final String? selectedId;
  final ValueChanged<String> onChanged;

  /// A partir de quantos equipamentos os cartões viram uma linha.
  static const listFrom = 4;

  /// A partir de quantos a lista ganha busca.
  static const searchFrom = 8;

  static IconData _icon(Device d) => d.isDemo ? Icons.smart_toy_outlined : Icons.router_outlined;

  @override
  Widget build(BuildContext context) {
    if (devices.length < listFrom) {
      return ChoiceCards<String>(
        options: [for (final d in devices) ChoiceOption(value: d.id, title: d.name, icon: _icon(d))],
        selected: selectedId ?? '',
        onChanged: onChanged,
      );
    }
    final d = devices.where((x) => x.id == selectedId).firstOrNull;
    return Material(
      color: Ind.surfaceHigh,
      borderRadius: BorderRadius.circular(Ind.radiusSmall),
      child: InkWell(
        key: const ValueKey('escolher-equipamento'),
        borderRadius: BorderRadius.circular(Ind.radiusSmall),
        onTap: () async {
          final picked = await _DeviceChooser.show(context, devices: devices, selectedId: selectedId);
          if (picked != null) onChanged(picked);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Row(children: [
            Icon(d == null ? Icons.router_outlined : _icon(d), color: Ind.textDim),
            const SizedBox(width: 14),
            Expanded(
              child: d == null
                  ? Text('Escolher equipamento', style: TextStyle(color: Ind.accent, fontWeight: FontWeight.w700, fontSize: 16))
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(d.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      const SizedBox(height: 2),
                      Text(d.addressLabel, style: TextStyle(color: Ind.textMuted, fontSize: 13)),
                    ]),
            ),
            Icon(Icons.chevron_right_rounded, color: Ind.textMuted),
          ]),
        ),
      ),
    );
  }
}

/// Folha com os equipamentos (e a busca, a partir de [DevicePick.searchFrom]).
/// Devolve o id do escolhido.
class _DeviceChooser extends StatefulWidget {
  const _DeviceChooser({required this.devices, required this.selectedId});
  final List<Device> devices;
  final String? selectedId;

  static Future<String?> show(BuildContext context, {required List<Device> devices, String? selectedId}) =>
      showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => _DeviceChooser(devices: devices, selectedId: selectedId),
      );

  @override
  State<_DeviceChooser> createState() => _DeviceChooserState();
}

class _DeviceChooserState extends State<_DeviceChooser> {
  String _query = '';

  static String _plain(String s) => s
      .toLowerCase()
      .replaceAll(RegExp('[áàâã]'), 'a')
      .replaceAll(RegExp('[éê]'), 'e')
      .replaceAll('í', 'i')
      .replaceAll(RegExp('[óôõ]'), 'o')
      .replaceAll('ú', 'u')
      .replaceAll('ç', 'c');

  bool _matches(Device d) {
    final q = _plain(_query.trim());
    return q.isEmpty || _plain(d.name).contains(q) || _plain(d.host).contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final shown = widget.devices.where(_matches).toList();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 32),
        children: [
          Text('Escolha o equipamento', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Ind.space),
          if (widget.devices.length >= DevicePick.searchFrom) ...[
            TextField(
              key: const ValueKey('buscar-equipamento'),
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Buscar por nome ou IP'),
            ),
            const SizedBox(height: Ind.space),
          ],
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text('Nenhum equipamento com "$_query".', style: TextStyle(color: Ind.textDim)),
            ),
          for (final d in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _DeviceRow(device: d, selected: d.id == widget.selectedId, onTap: () => Navigator.pop(context, d.id)),
            ),
        ],
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.device, required this.selected, required this.onTap});
  final Device device;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: selected ? Ind.accent.withValues(alpha: 0.14) : Ind.surfaceHigh,
        borderRadius: BorderRadius.circular(Ind.radiusSmall),
        child: InkWell(
          key: ValueKey('equipamento-${device.id}'),
          borderRadius: BorderRadius.circular(Ind.radiusSmall),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Ind.radiusSmall),
              border: selected ? Border.all(color: Ind.accent, width: 2) : null,
            ),
            child: Row(children: [
              Icon(DevicePick._icon(device), color: selected ? Ind.accent : Ind.textDim),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(device.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(device.addressLabel, style: TextStyle(color: Ind.textMuted, fontSize: 12)),
                ]),
              ),
            ]),
          ),
        ),
      );
}
