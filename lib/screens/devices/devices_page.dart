import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../models/device.dart';
import '../../widgets/common/common.dart';
import '../../widgets/tour/tour.dart';
import '../tours.dart';
import 'device_form_page.dart';

/// Lista de equipamentos.
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key, this.startTour = false});
  final bool startTour;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  final _listKey = GlobalKey();
  final _addKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final project = AppScope.watch(context).controller.project;
    final devices = project.devices;

    return TourHost(
      spec: Tours.equipamentos(list: _listKey, add: _addKey),
      // Não abre sozinho: no QA o 1º minuto do app tinha cinco tutoriais
      // seguidos. Ficam automáticos só início, operar e montar; este está no
      // "?" e em Mais → Tutoriais.
      autoStart: false,
      forceStart: widget.startTour,
      child: Scaffold(
        appBar: AppBar(title: const Text('Equipamentos'), actions: const [HelpButton()]),
        floatingActionButton: FloatingActionButton.extended(
          key: _addKey,
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DeviceFormPage())),
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
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.device});
  final Device device;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        key: ValueKey('equip-${device.id}'),
        borderRadius: BorderRadius.circular(Ind.radius),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DeviceFormPage(device: device))),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: Ind.surfaceHigh, borderRadius: BorderRadius.circular(12)),
                child: Icon(device.isDemo ? Icons.smart_toy_outlined : Icons.router_outlined, color: Ind.accent),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(device.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
                    const SizedBox(height: 4),
                    Text(device.addressLabel, style: const TextStyle(color: Ind.textMuted, fontSize: 13)),
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
