import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/core/modbus/modbus_tcp_server.dart';
import 'package:ihm/services/net/local_network.dart';
import 'package:ihm/services/net/modbus_discovery.dart';

/// Procurar na rede (item 94): faixa varrida, rede escolhida, confirmação
/// Modbus contra servidores de verdade em portas locais e cancelamento.
void main() {
  group('faixa varrida: no máximo a /24 do celular', () {
    test('/24: os 253 vizinhos, sem a rede, a difusão e o próprio celular', () {
      final hosts = LocalNetwork.neighbors('192.168.1.23', 24);
      expect(hosts, hasLength(253));
      expect(hosts.first, '192.168.1.1');
      expect(hosts.last, '192.168.1.254');
      expect(hosts, isNot(contains('192.168.1.23')));
      expect(hosts, isNot(contains('192.168.1.0')));
      expect(hosts, isNot(contains('192.168.1.255')));
    });

    test('/16 e /8 não alargam a procura: fica na /24 em volta do celular', () {
      for (final prefix in [8, 16, 22]) {
        final hosts = LocalNetwork.neighbors('10.0.5.40', prefix);
        expect(hosts, hasLength(253), reason: '/$prefix');
        expect(hosts.every((h) => h.startsWith('10.0.5.')), isTrue, reason: '/$prefix');
      }
    });

    test('rede menor que /24 encolhe junto', () {
      expect(LocalNetwork.neighbors('192.168.1.20', 28), [
        for (var i = 17; i <= 30; i++)
          if (i != 20) '192.168.1.$i',
      ]);
      expect(LocalNetwork.neighbors('127.0.0.2', 30), ['127.0.0.1']);
      expect(LocalNetwork.neighbors('10.0.0.4', 31), ['10.0.0.5'], reason: '/31 não tem rede nem difusão');
      expect(LocalNetwork.neighbors('10.0.0.4', 32), isEmpty);
    });

    test('lixo não vira faixa', () {
      expect(LocalNetwork.neighbors('clp.local', 24), isEmpty);
      expect(LocalNetwork.neighbors('192.168.1.300', 24), isEmpty);
      expect(LocalNetwork.neighbors('192.168.1.3', 0), isEmpty);
    });

    test('rótulo da faixa e ordem de IP', () {
      expect(LocalNetwork.scanLabel('192.168.1.23', 24), '192.168.1.x');
      expect(LocalNetwork.scanLabel('10.0.5.40', 16), '10.0.5.x');
      expect(LocalNetwork.scanLabel('192.168.1.20', 28), '192.168.1.16/28');
      final ips = ['192.168.1.10', '192.168.1.9', 'clp.local', '10.0.0.1']..sort(LocalNetwork.compareIPv4);
      expect(ips, ['10.0.0.1', '192.168.1.9', '192.168.1.10', 'clp.local']);
    });
  });

  group('que rede procurar', () {
    const wifi = LocalNet(type: 'wifi', ip: '192.168.1.23', prefix: 24);
    const cabo = LocalNet(type: 'cabo', ip: '10.0.0.5', prefix: 24);

    test('Wi-Fi antes do cabo; sem Wi-Fi, o cabo', () {
      expect(ModbusDiscovery.pickNetwork(const [cabo, wifi]), wifi);
      expect(ModbusDiscovery.pickNetwork(const [cabo]), cabo);
    });

    test('nenhuma rede local: nulo (a folha explica o que fazer)', () {
      expect(ModbusDiscovery.pickNetwork(const []), isNull);
      expect(ModbusDiscovery.pickNetwork(const [LocalNet(type: 'wifi', ip: '8.8.4.20', prefix: 24)]), isNull, reason: 'IP público não se varre');
      expect(ModbusDiscovery.pickNetwork(const [LocalNet(type: 'wifi', ip: '192.168.1.23', prefix: 32)]), isNull, reason: 'faixa sem vizinhos');
    });
  });

  group('contra servidores Modbus falsos em portas locais', () {
    final stops = <Future<void> Function()>[];
    tearDown(() async {
      for (final s in stops.reversed) {
        await s();
      }
      stops.clear();
    });

    Future<int> modbus({ModbusMemory? memory, int? unitId, Duration delay = Duration.zero}) async {
      final s = ModbusTcpServer(memory ?? ModbusMemory(holdingRegisters: 10), unitId: unitId)..responseDelay = delay;
      await s.start();
      stops.add(s.stop);
      return s.port;
    }

    /// Porta aberta que não fala Modbus: responde texto (um servidor web, por exemplo).
    Future<int> notModbus() async {
      final s = await ServerSocket.bind('127.0.0.1', 0);
      s.listen((c) => c.listen((_) => c.add('HTTP/1.1 400 Bad Request\r\n\r\n'.codeUnits), onError: (_) {}));
      stops.add(s.close);
      return s.port;
    }

    /// Porta em que nada escuta.
    Future<int> closed() async {
      final s = await ServerSocket.bind('127.0.0.1', 0);
      final port = s.port;
      await s.close();
      return port;
    }

    test('acha quem abriu a porta e separa quem fala Modbus', () async {
      final ok = await modbus();
      // Leitura do registrador 0 numa memória sem registradores: exceção 02
      // — que também é Modbus.
      final exception = await modbus(memory: ModbusMemory(holdingRegisters: 0));
      // Só atende o ID 7: ao ID 1 fica em silêncio.
      final otherId = await modbus(unitId: 7);
      final web = await notModbus();
      final nobody = await closed();

      final found = <DiscoveredDevice>[];
      final progress = <(int, int)>[];
      final scan = ModbusDiscovery(ports: [ok, exception, otherId, web, nobody], replyTimeout: const Duration(milliseconds: 400));
      final result = await scan.scan(['127.0.0.1'], onFound: found.add, onProgress: (d, t) => progress.add((d, t)));

      expect(result, [
        for (final (port, modbus) in [(ok, true), (exception, true), (otherId, false), (web, false)]..sort((a, b) => a.$1.compareTo(b.$1)))
          DiscoveredDevice(host: '127.0.0.1', port: port, modbus: modbus),
      ]);
      expect(found.toSet(), result.toSet(), reason: 'cada achado avisado na hora');
      expect(progress.last, (5, 5));
      expect(progress.map((p) => p.$1), [1, 2, 3, 4, 5]);
    });

    test('a leitura de confirmação fecha a conexão depois', () async {
      final memory = ModbusMemory(holdingRegisters: 10);
      final s = ModbusTcpServer(memory);
      await s.start();
      stops.add(s.stop);
      await ModbusDiscovery(ports: [s.port]).scan(['127.0.0.1']);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(s.clientCount, 0, reason: 'nada fica pendurado no equipamento');
    });

    test('cancelar no meio da confirmação devolve na hora, e o cliente se desfaz sozinho', () async {
      final memory = ModbusMemory(holdingRegisters: 10);
      final slow = ModbusTcpServer(memory)..responseDelay = const Duration(seconds: 5);
      await slow.start();
      stops.add(slow.stop);
      final scan = ModbusDiscovery(ports: [slow.port], replyTimeout: const Duration(milliseconds: 600));
      final progress = <int>[];
      final sw = Stopwatch()..start();
      final running = scan.scan(['127.0.0.1'], onProgress: (d, _) => progress.add(d));
      // A porta abre na hora (etapa 1 já fechou a dela); a resposta Modbus
      // da etapa 2 é que demora.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(slow.clientCount, 1, reason: 'na etapa 2, esperando a resposta');
      final cancelledAt = sw.elapsedMilliseconds;
      scan.cancel();
      expect(await running, isEmpty, reason: 'o que não terminou não conta');
      expect(sw.elapsedMilliseconds - cancelledAt, lessThan(200));
      expect(progress, isEmpty);
      expect(scan.cancelled, isTrue);
      // O cliente da confirmação estoura o próprio prazo e fecha a conexão.
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(slow.clientCount, 0);
    });
  });

  group('agenda das tentativas', () {
    test('no máximo [concurrency] ao mesmo tempo; progresso até o fim', () async {
      final scan = _Scripted(concurrency: 4, ports: const [502, 5020]);
      final progress = <(int, int)>[];
      final hosts = [for (var i = 1; i <= 20; i++) '10.0.0.$i'];
      final done = scan.scan(hosts, onProgress: (d, t) => progress.add((d, t)));
      for (var round = 0; round < 40; round++) {
        await pumpEventQueue();
        if (scan.inFlight == 0) break;
        expect(scan.inFlight, lessThanOrEqualTo(4));
        scan.answerAll((host, port) => host == '10.0.0.7' && port == 502 ? true : null);
      }
      final result = await done;
      expect(scan.maxInFlight, 4);
      expect(scan.started, 40, reason: '20 IPs × 2 portas');
      expect(progress.last, (40, 40));
      expect(result, const [DiscoveredDevice(host: '10.0.0.7', port: 502, modbus: true)]);
      expect(scan.order.take(4), ['10.0.0.1:502', '10.0.0.1:5020', '10.0.0.2:502', '10.0.0.2:5020'], reason: 'as portas de um IP em seguida');
    });

    test('cancelar: nenhuma tentativa nova, devolve o achado até ali e o progresso para', () async {
      final scan = _Scripted(concurrency: 8, ports: const [502]);
      final found = <DiscoveredDevice>[];
      final progress = <int>[];
      final hosts = [for (var i = 1; i <= 254; i++) '192.168.0.$i'];
      final done = scan.scan(hosts, onFound: found.add, onProgress: (d, _) => progress.add(d));
      await pumpEventQueue();
      scan.answerAll((host, _) => host == '192.168.0.3' ? false : null);
      await pumpEventQueue();
      final startedBefore = scan.started;
      expect(startedBefore, 16, reason: 'duas levas de 8');

      scan.cancel();
      final result = await done;
      expect(result, const [DiscoveredDevice(host: '192.168.0.3', port: 502, modbus: false)]);
      expect(found, result);
      final progressBefore = List.of(progress);

      // As que estavam no ar terminam depois: não contam e nada novo começa.
      scan.answerAll((_, _) => true);
      await pumpEventQueue();
      expect(scan.started, startedBefore);
      expect(progress, progressBefore);
      expect(found, result);
    });
  });
}

/// Procurador com as tentativas na mão do teste: cada endereço espera até o
/// teste responder (achado com/sem Modbus, ou nada).
class _Scripted extends ModbusDiscovery {
  _Scripted({super.concurrency, super.ports});

  final Map<String, Completer<DiscoveredDevice?>> _pending = {};
  final List<String> order = [];
  int started = 0;
  int maxInFlight = 0;

  int get inFlight => _pending.length;

  @override
  Future<DiscoveredDevice?> probe(String host, int port) {
    final key = '$host:$port';
    order.add(key);
    started++;
    final c = _pending[key] = Completer<DiscoveredDevice?>();
    if (_pending.length > maxInFlight) maxInFlight = _pending.length;
    return c.future;
  }

  /// Responde todas as pendentes: verdadeiro = fala Modbus, falso = só abriu, nulo = nada.
  void answerAll(bool? Function(String host, int port) answer) {
    final now = Map.of(_pending);
    _pending.clear();
    now.forEach((key, c) {
      final i = key.lastIndexOf(':');
      final host = key.substring(0, i), port = int.parse(key.substring(i + 1));
      final modbus = answer(host, port);
      c.complete(modbus == null ? null : DiscoveredDevice(host: host, port: port, modbus: modbus));
    });
  }
}
