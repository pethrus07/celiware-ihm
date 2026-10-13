import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../core/modbus/modbus_client_tcp.dart';
import '../../core/modbus/modbus_exception.dart';
import 'local_network.dart';

/// Um endereço que atendeu na procura.
@immutable
class DiscoveredDevice {
  const DiscoveredDevice({required this.host, required this.port, required this.modbus});

  final String host;
  final int port;

  /// Respondeu Modbus de verdade: a leitura do registrador 0 voltou com valor
  /// ou com **exceção Modbus** — a exceção também prova que do outro lado tem
  /// Modbus (só aquele endereço é que não existe, ou o gateway não achou o
  /// escravo). Falso = a porta abriu, mas o que atendeu não respondeu Modbus
  /// ao ID 1 (outro serviço nessa porta, ou equipamento que só aceita outro ID).
  final bool modbus;

  /// Ordem de IP e porta — a lista não fica pulando conforme as respostas chegam.
  static int compare(DiscoveredDevice a, DiscoveredDevice b) {
    final c = LocalNetwork.compareIPv4(a.host, b.host);
    return c != 0 ? c : a.port.compareTo(b.port);
  }

  @override
  bool operator ==(Object other) => other is DiscoveredDevice && other.host == host && other.port == port && other.modbus == modbus;

  @override
  int get hashCode => Object.hash(host, port, modbus);

  @override
  String toString() => '$host:$port${modbus ? ' · Modbus' : ''}';
}

/// Procura equipamentos Modbus TCP na rede local do celular (item 94).
///
/// **Onde procura.** Só na faixa do Wi-Fi do celular, e no máximo uma /24
/// ([LocalNetwork.neighbors]: 254 endereços). Nunca sai dela: máscara /16 não
/// vira 65 mil tentativas.
///
/// **Como procura.** Para cada endereço e cada porta ([defaultPorts]: 502 e
/// 5020, a do simulador do projeto), duas etapas:
///
///  1. **A porta abre?** Conexão TCP com prazo curto ([connectTimeout],
///     300 ms), no máximo [concurrency] (32) ao mesmo tempo. É barata e
///     cancelável na hora: quase todo endereço termina aqui, sem ninguém do
///     outro lado.
///  2. **Fala Modbus?** Só onde a porta abriu. O mesmo [ModbusClientTcp] que o
///     app usa para ler pede 1 holding register (endereço 0, ID 1). Resposta
///     com valor ou com exceção Modbus = fala Modbus. Silêncio, resposta que
///     não é Modbus ou conexão derrubada = abriu, mas não confirmou.
///
/// No pior caso (ninguém responde), 254 × 2 ÷ 32 × 300 ms ≈ 5 s.
///
/// Uma instância por procura: depois de [cancel], ela não volta a procurar.
class ModbusDiscovery {
  ModbusDiscovery({
    this.ports = defaultPorts,
    this.connectTimeout = const Duration(milliseconds: 300),
    this.replyTimeout = const Duration(milliseconds: 1000),
    this.concurrency = 32,
    this.unitId = 1,
  }) : assert(concurrency > 0);

  /// Modbus TCP (502) e o simulador do projeto (`sim/simulador.py`, 5020).
  static const defaultPorts = [502, 5020];

  final List<int> ports;

  /// Prazo para a porta abrir. Na rede local, quem existe atende em poucos
  /// milissegundos; quem não existe nunca atende.
  final Duration connectTimeout;

  /// Prazo para a resposta Modbus, depois que a porta abriu.
  final Duration replyTimeout;

  /// Tentativas ao mesmo tempo.
  final int concurrency;

  /// ID do escravo da leitura de confirmação.
  final int unitId;

  static final Logger _log = Logger('ModbusDiscovery');

  bool _cancelled = false;
  final _stop = Completer<void>();
  final Set<ConnectionTask<Socket>> _connecting = {};

  bool get cancelled => _cancelled;

  /// Testa [hosts] × [ports]. [onFound] chega a cada achado, na hora;
  /// [onProgress] a cada tentativa terminada (feitas, total). Devolve o que
  /// achou, em ordem de IP e porta. Cancelada, devolve o achado até ali, sem
  /// esperar as tentativas em andamento.
  Future<List<DiscoveredDevice>> scan(
    List<String> hosts, {
    void Function(DiscoveredDevice found)? onFound,
    void Function(int done, int total)? onProgress,
  }) async {
    final total = hosts.length * ports.length;
    final found = <DiscoveredDevice>[];
    var next = 0;
    var done = 0;

    // Endereço por endereço (as portas de um mesmo IP em seguida): os
    // achados aparecem mais ou menos na ordem da lista.
    Future<void> worker() async {
      while (!_cancelled && next < total) {
        final i = next++;
        DiscoveredDevice? hit;
        try {
          hit = await probe(hosts[i ~/ ports.length], ports[i % ports.length]);
        } catch (e) {
          _log.fine('Tentativa ${hosts[i ~/ ports.length]} falhou: $e');
        }
        if (_cancelled) return;
        done++;
        if (hit != null) {
          found.add(hit);
          onFound?.call(hit);
        }
        onProgress?.call(done, total);
      }
    }

    final workers = Future.wait([for (var w = 0; w < math.min(concurrency, total); w++) worker()]);
    await Future.any([workers, _stop.future]);
    return found..sort(DiscoveredDevice.compare);
  }

  /// Para a procura: nenhuma tentativa nova começa e as conexões abrindo são
  /// abandonadas na hora.
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final t in _connecting.toList()) {
      t.cancel();
    }
    _connecting.clear();
    _stop.complete();
  }

  /// Um endereço: nulo se a porta não abriu.
  @protected
  Future<DiscoveredDevice?> probe(String host, int port) async {
    if (!await _opens(host, port) || _cancelled) return null;
    return DiscoveredDevice(host: host, port: port, modbus: await _speaksModbus(host, port));
  }

  /// Etapa 1: só abre e fecha a conexão.
  Future<bool> _opens(String host, int port) async {
    ConnectionTask<Socket>? task;
    Timer? deadline;
    try {
      task = await Socket.startConnect(host, port);
      if (_cancelled) {
        task.cancel();
        return false;
      }
      _connecting.add(task);
      deadline = Timer(connectTimeout, task.cancel);
      final socket = await task.socket;
      socket.destroy();
      return true;
    } catch (_) {
      // Recusou, estourou o prazo, foi cancelada ou a rede não alcança: não
      // tem ninguém nesta porta.
      return false;
    } finally {
      deadline?.cancel();
      if (task != null) _connecting.remove(task);
    }
  }

  /// Etapa 2: o cliente Modbus do app lê 1 registrador. Cancelada a procura,
  /// devolve na hora; o cliente termina sozinho (no máximo [replyTimeout]) e
  /// se desfaz — fechar o socket dele por fora atropelaria a própria limpeza.
  Future<bool> _speaksModbus(String host, int port) {
    final client = ModbusClientTcp(host: host, port: port, unitId: unitId, connectionTimeout: replyTimeout, responseTimeout: replyTimeout);
    Future<bool> ask() async {
      try {
        await client.connect();
        await client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 1);
        return true;
      } on ModbusExceptionResponse {
        return true;
      } on ModbusError {
        return false;
      } finally {
        await client.dispose();
      }
    }

    return Future.any([ask(), _stop.future.then((_) => false)]);
  }

  // ── Que rede procurar ───────────────────────────────────────────────────────

  /// A rede a varrer: o Wi-Fi com IPv4 de rede local; sem Wi-Fi, o cabo
  /// (adaptador USB-C → Ethernet). Nulo quando o celular não está em nenhuma.
  static LocalNet? pickNetwork(List<LocalNet> nets) {
    LocalNet? cable;
    for (final n in nets) {
      if (!LocalNetwork.isPrivateIPv4(n.ip) || LocalNetwork.neighbors(n.ip, n.prefix).isEmpty) continue;
      if (n.type == 'wifi') return n;
      cable ??= n;
    }
    return cable;
  }

  // ── Peças trocáveis nos testes ──────────────────────────────────────────────
  //
  // Fora do Android o canal `celiware/rede` não existe: nos testes entram uma
  // rede de mentira e um procurador controlado.

  static Future<List<LocalNet>?> Function() _networks = LocalNetwork.list;
  static Future<void> Function(String ip) _bind = LocalNetwork.prepare;
  static ModbusDiscovery Function(List<int> ports) _create = _real;

  static ModbusDiscovery _real(List<int> ports) => ModbusDiscovery(ports: ports);

  /// Redes locais do celular; nulo quando a plataforma não informa.
  static Future<List<LocalNet>?> networks() => _networks();

  /// Prende as conexões do app à rede que vai ser varrida. Wi-Fi da máquina
  /// sem internet com os dados móveis ligados: sem isto, as tentativas sairiam
  /// pela operadora e nada responderia (ver `RedeLocal.kt`).
  static Future<void> bindTo(LocalNet net) => _bind(net.ip);

  /// Um procurador novo para [ports].
  static ModbusDiscovery create(List<int> ports) => _create(ports);

  @visibleForTesting
  static void debugOverride({
    Future<List<LocalNet>?> Function()? networks,
    Future<void> Function(String ip)? bind,
    ModbusDiscovery Function(List<int> ports)? create,
  }) {
    if (networks != null) _networks = networks;
    if (bind != null) _bind = bind;
    if (create != null) _create = create;
  }

  @visibleForTesting
  static void debugReset() {
    _networks = LocalNetwork.list;
    _bind = LocalNetwork.prepare;
    _create = _real;
  }
}
