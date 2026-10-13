import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../services/net/local_network.dart';
import '../../services/net/modbus_discovery.dart';
import '../../widgets/common/adaptive.dart';

/// "Procurar na rede" (item 94): varre o Wi-Fi do celular atrás de
/// equipamento Modbus TCP. Devolve o escolhido, ou nulo se a pessoa fechou
/// sem escolher (fechar também para a procura).
///
/// [port] é a porta que está no cadastro: entra na procura junto com a 502 e
/// a 5020 (para quem já sabe que o equipamento usa outra). [known] dá nome ao
/// que já está cadastrado ("192.168.1.10:502" → "CLP da cortadora"): com dois
/// equipamentos na mesma rede, é o que diz qual dos dois é o novo.
Future<DiscoveredDevice?> showNetworkScanSheet(BuildContext context, {int? port, Map<String, String> known = const {}}) =>
    showModalBottomSheet<DiscoveredDevice>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => NetworkScanSheet(port: port, known: known),
    );

enum _Phase {
  /// Perguntando ao Android em que rede o celular está.
  network,
  scanning,
  done,
  stopped,

  /// Nenhum Wi-Fi (nem cabo) com IP de rede local.
  noWifi,

  /// A plataforma não informa a rede (fora do Android).
  unknown,
}

class NetworkScanSheet extends StatefulWidget {
  const NetworkScanSheet({super.key, this.port, this.known = const {}});
  final int? port;
  final Map<String, String> known;

  @override
  State<NetworkScanSheet> createState() => _NetworkScanSheetState();
}

class _NetworkScanSheetState extends State<NetworkScanSheet> {
  _Phase _phase = _Phase.network;
  ModbusDiscovery? _scan;
  LocalNet? _net;
  final List<DiscoveredDevice> _found = [];
  int _done = 0;
  int _total = 0;

  bool get _busy => _phase == _Phase.network || _phase == _Phase.scanning;

  List<int> get _ports {
    final p = widget.port;
    return {...ModbusDiscovery.defaultPorts, if (p != null && p > 0 && p <= 65535) p}.toList();
  }

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _scan?.cancel();
    super.dispose();
  }

  /// Cada procura tem um número: parar ou recomeçar invalida a anterior, que
  /// ainda pode estar esperando o Android ou terminando tentativas.
  int _run = 0;

  Future<void> _start() async {
    final run = ++_run;
    _scan?.cancel();
    setState(() {
      _phase = _Phase.network;
      _net = null;
      _found.clear();
      _done = 0;
      _total = 0;
    });
    final nets = await ModbusDiscovery.networks();
    if (!mounted || run != _run) return;
    final net = nets == null ? null : ModbusDiscovery.pickNetwork(nets);
    if (net == null) {
      setState(() => _phase = nets == null ? _Phase.unknown : _Phase.noWifi);
      return;
    }
    await ModbusDiscovery.bindTo(net);
    if (!mounted || run != _run) return;
    final hosts = LocalNetwork.neighbors(net.ip, net.prefix);
    final scan = _scan = ModbusDiscovery.create(_ports);
    setState(() {
      _net = net;
      _phase = _Phase.scanning;
      _total = hosts.length * scan.ports.length;
    });
    await scan.scan(
      hosts,
      onFound: (d) {
        if (mounted && run == _run) setState(() => _found..add(d)..sort(DiscoveredDevice.compare));
      },
      onProgress: (done, total) {
        if (!mounted || run != _run) return;
        setState(() {
          _done = done;
          _total = total;
        });
      },
    );
    if (!mounted || run != _run) return;
    setState(() => _phase = _Phase.done);
  }

  void _stop() {
    _run++;
    _scan?.cancel();
    setState(() => _phase = _Phase.stopped);
  }

  /// "no Wi-Fi 192.168.1.x" / "na rede do cabo 10.0.0.x".
  String get _where {
    final n = _net;
    if (n == null) return '';
    final range = LocalNetwork.scanLabel(n.ip, n.prefix);
    return n.type == 'cabo' ? 'na rede do cabo $range' : 'no Wi-Fi $range';
  }

  String get _status => switch (_phase) {
        _Phase.network => 'Procurando a rede do celular…',
        _Phase.scanning => 'Procurando $_where…',
        _Phase.done when _found.isEmpty => 'Nada respondeu $_where.',
        _Phase.done => 'Achados $_where. Toque para usar.',
        _Phase.stopped when _net == null => 'Procura parada.',
        _Phase.stopped => 'Procura parada $_where.',
        _Phase.noWifi => 'O celular não está em nenhum Wi-Fi. Conecte ao Wi-Fi da máquina e procure de novo.',
        _Phase.unknown => 'Este aparelho não informa a rede. Digite o IP do equipamento.',
      };

  @override
  Widget build(BuildContext context) {
    final ports = _ports;
    final portsLabel = ports.length == 1 ? 'Porta ${ports.single}' : 'Portas ${ports.sublist(0, ports.length - 1).join(', ')} e ${ports.last}';
    final height = MediaQuery.sizeOf(context).height;
    return SizedBox(
      // Celular deitado: 60% da altura não deixaria lugar nem para um achado.
      height: height * (WindowClass.isCompactHeight(context) ? 0.9 : 0.6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Ind.page, 20, Ind.page, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Procurar na rede', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(_status, key: const ValueKey('procura-status'), style: TextStyle(color: Ind.textDim, height: 1.35)),
            if (_busy) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(key: const ValueKey('procura-progresso'), value: _total == 0 ? null : _done / _total),
            ],
          ]),
        ),
        Expanded(
          child: _phase == _Phase.done && _found.isEmpty
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(Ind.page, 8, Ind.page, 0),
                  child: Text('Confira se o equipamento está ligado, ${_net?.type == 'cabo' ? 'na mesma rede' : 'no mesmo Wi-Fi'} do celular e com o Modbus TCP ativo. $portsLabel.',
                      style: TextStyle(color: Ind.textDim, height: 1.4)),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(Ind.page, 4, Ind.page, 16),
                  children: [for (final d in _found) _row(d)],
                ),
        ),
        if (_phase != _Phase.unknown)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Ind.page, 4, Ind.page, 12),
              child: _busy
                  ? OutlinedButton.icon(key: const ValueKey('parar-procura'), onPressed: _stop, icon: const Icon(Icons.stop_rounded), label: const Text('Parar'))
                  : OutlinedButton.icon(key: const ValueKey('procurar-de-novo'), onPressed: _start, icon: const Icon(Icons.refresh_rounded), label: const Text('Procurar de novo')),
            ),
          ),
      ]),
    );
  }

  Widget _row(DiscoveredDevice d) {
    final name = widget.known['${d.host}:${d.port}'];
    return ListTile(
      key: ValueKey('achado-${d.host}:${d.port}'),
      contentPadding: EdgeInsets.zero,
      // Cor só para estado: verde = confirmou Modbus.
      leading: Icon(d.modbus ? Icons.check_circle_rounded : Icons.help_outline_rounded, color: d.modbus ? Ind.ok : Ind.textMuted),
      title: Text(d.host, style: Ind.number(17, color: Ind.text)),
      subtitle: Text(
        [
          d.modbus ? 'Responde Modbus · porta ${d.port}' : 'Porta ${d.port} aberta, sem resposta Modbus',
          if (name != null) 'Já cadastrado: $name',
        ].join('\n'),
        style: TextStyle(color: Ind.textMuted, fontSize: 13, height: 1.35),
      ),
      onTap: () => Navigator.pop(context, d),
    );
  }
}
