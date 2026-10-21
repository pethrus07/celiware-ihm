import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../models/device.dart';
import '../../widgets/common/adaptive.dart';
import '../../widgets/common/common.dart';
import '../../widgets/tour/tour.dart';
import '../tours.dart';
import 'device_form_page.dart';

/// Lista de equipamentos.
///
/// No tablet deitado o cadastro abre ao lado da lista ([ListDetail], TB-2).
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key, this.startTour = false});
  final bool startTour;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  final _listKey = GlobalKey();
  final _addKey = GlobalKey();
  final _panes = GlobalKey<ListDetailState>();

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.watch(context).controller;
    final project = controller.project;
    // O equipamento virtual das calculadas não se cadastra nem se testa.
    final devices = project.equipment;

    return TourHost(
      spec: Tours.equipamentos(list: _listKey, add: _addKey),
      // Não abre sozinho: no QA o 1º minuto do app tinha cinco tutoriais
      // seguidos. Ficam automáticos só início, operar e montar; este está no
      // "?" e em Ajustes → Tutoriais.
      autoStart: false,
      forceStart: widget.startTour,
      child: ListDetail(
        key: _panes,
        // Trocou de projeto (pelo trilho, no tablet): o cadastro aberto ao
        // lado era do outro projeto e fecha.
        owner: controller.openId,
        placeholder: const Scaffold(
          body: EmptyState(
            icon: Icons.router_outlined,
            title: 'Escolha um equipamento',
            body: 'Toque num equipamento da lista para ver e editar, ou cadastre um novo.',
          ),
        ),
        list: Scaffold(
          appBar: AppBar(title: const Text('Equipamentos'), actions: const [HelpButton()]),
          floatingActionButton: FloatingActionButton.extended(
            key: _addKey,
            onPressed: () => _panes.currentState?.open(_novo, (_) => const DeviceFormPage()),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Novo equipamento'),
          ),
          body: devices.isEmpty
              ? KeyedSubtree(
                  key: _listKey,
                  child: const EmptyState(
                    icon: Icons.router_outlined,
                    title: 'Nenhum equipamento',
                    body: 'Cadastre o CLP, inversor ou IHM que o app vai ler. Você vai precisar do IP dele.',
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(Ind.page, 8, Ind.page, 110),
                  itemCount: devices.length,
                  separatorBuilder: (_, _) => const SizedBox(height: Ind.space),
                  // O tutorial realça o primeiro equipamento, não a lista inteira.
                  itemBuilder: (context, i) => KeyedSubtree(
                    key: i == 0 ? _listKey : null,
                    child: _DeviceCard(device: devices[i]),
                  ),
                ),
        ),
      ),
    );
  }

  /// Item do painel para o cadastro novo (não colide com id de equipamento).
  static const _novo = '+novo';
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.device});
  final Device device;

  @override
  Widget build(BuildContext context) {
    // Aberto no painel ao lado (tablet): fundo e contorno na cor de seleção.
    final selected = ListDetail.selectedOf(context) == device.id;
    return Card(
      color: selected ? Color.alphaBlend(Ind.accent.withValues(alpha: 0.12), Ind.surface) : null,
      shape: selected ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(Ind.radius), side: BorderSide(color: Ind.accent, width: 1.5)) : null,
      child: InkWell(
        key: ValueKey('equip-${device.id}'),
        borderRadius: BorderRadius.circular(Ind.radius),
        onTap: () => ListDetail.of(context).open(device.id, (_) => DeviceFormPage(device: device)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: Ind.surfaceHigh, borderRadius: BorderRadius.circular(12)),
                child: Icon(device.isDemo ? Icons.smart_toy_outlined : device.isUsb ? Icons.usb_rounded : Icons.router_outlined, color: Ind.accent),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(device.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
                    const SizedBox(height: 4),
                    Text(device.addressLabel, style: TextStyle(color: Ind.textMuted, fontSize: 13)),
                    const SizedBox(height: 10),
                    LinkChip(device: device),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
