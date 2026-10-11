import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../core/comm/comm_error.dart';
import '../../core/modbus/modbus_client.dart';
import '../../core/modbus/modbus_client_simulated.dart';
import '../../core/modbus/modbus_client_tcp.dart';
import '../../models/device.dart';
import '../../models/tag.dart';
import '../demo/demo_process.dart';
import '../net/local_network.dart';
import 'drivers/device_driver.dart';
import 'tag_store.dart';

/// Saúde da comunicação com um equipamento, para o selo na interface.
@immutable
class DeviceHealth {
  const DeviceHealth({
    this.link = ModbusLinkState.disconnected,
    this.message = '',
    this.lastScanMs,
    this.blocks = 0,
  });

  final ModbusLinkState link;

  /// Último erro de comunicação (vazio quando está tudo bem).
  final String message;

  /// Quanto levou a última varredura completa — mede a rede de verdade.
  final int? lastScanMs;

  /// Quantas leituras cada varredura faz (depois do agrupamento).
  final int blocks;

  bool get online => link == ModbusLinkState.connected && message.isEmpty;
}

/// Varredura contínua de **um** equipamento, qualquer que seja o protocolo.
///
/// Laço: pede ao [DeviceDriver] para ler as variáveis em uso e publicar no
/// [TagStore] → espera [Device.pollMs] → repete. Sem variável em uso, o laço
/// dorme (não gera tráfego à toa).
///
/// O que é de protocolo (agrupar leituras, decodificar, achar o endereço
/// errado de um bloco) mora no driver. Aqui fica o que vale para todos:
///   • **sem resposta / sem conexão** (`CommError`) → todas as variáveis
///     ficam [TagQuality.commLost] mantendo o último valor, e o laço tenta de
///     novo com espera crescente (1 s, 2 s, 4 s… até 10 s) para não martelar
///     uma rede que caiu;
///   • saúde da conexão para o selo (online, tempo da varredura, leituras).
///
/// Escritas passam pelo mesmo driver (o transporte serializa com as leituras)
/// e acordam o laço para o resultado aparecer na hora.
class DeviceSession {
  DeviceSession({
    required Device device,
    required this.store,
    ModbusClient Function(Device)? clientFactory,
    DeviceDriver Function(Device)? driverFactory,
  })  : _device = device,
        _driverFactory = driverFactory ??
            ((d) => DeviceDriver.forDevice(d, clientFactory: clientFactory ?? defaultClientFactory)) {
    _driver = _newDriver(device);
  }

  static final Logger _log = Logger('DeviceSession');

  final TagStore store;
  final DeviceDriver Function(Device) _driverFactory;

  Device _device;
  late DeviceDriver _driver;
  List<Tag> _tags = const [];

  bool _running = false;
  bool _disposed = false;
  int _generation = 0;
  Completer<void>? _wake;
  int _failures = 0;

  final ValueNotifier<DeviceHealth> health = ValueNotifier(const DeviceHealth());

  Device get device => _device;

  /// Cliente Modbus real ou simulado conforme o tipo de equipamento.
  static ModbusClient defaultClientFactory(Device d) {
    if (d.isDemo) {
      return SimulatedModbusClient(memory: DemoRegistry.forDevice(d.id).memory, unitId: d.unitId);
    }
    return ModbusClientTcp(
      host: d.host,
      port: d.port,
      unitId: d.unitId,
      responseTimeout: Duration(milliseconds: d.timeoutMs),
      // Wi-Fi da máquina sem internet + dados móveis ligados: sem isto a
      // conexão sairia pelo 4G (ver LocalNetwork).
      beforeConnect: LocalNetwork.prepare,
    );
  }

  DeviceDriver _newDriver(Device d) => _driverFactory(d)..onWake = wake;

  // ── Configuração ─────────────────────────────────────────────────────────────

  /// Define quais variáveis deste equipamento estão em uso agora.
  void setTags(List<Tag> tags) {
    final before = _tags;
    _tags = List.unmodifiable(tags);
    _driver.tagsChanged(before, _tags);
    if (tags.isEmpty) {
      _setHealth(link: _driver.state.value, blocks: 0);
    }
    wake();
  }

  /// Troca a configuração do equipamento; reabre a conexão só se precisar.
  Future<void> updateDevice(Device next) async {
    final relink = !next.sameLinkAs(_device);
    _device = next;
    if (relink) {
      final old = _driver;
      _driver = _newDriver(next);
      await old.dispose();
      _failures = 0;
    }
    wake();
  }

  // ── Laço ─────────────────────────────────────────────────────────────────────

  void start() {
    if (_running || _disposed) return;
    _running = true;
    if (_device.isDemo) DemoRegistry.forDevice(_device.id).start();
    // Cada start ganha uma geração; um laço antigo que ainda esteja no meio
    // de uma leitura percebe que foi substituído e termina sozinho — sem isso
    // um stop()+start() rápido deixaria dois laços varrendo juntos.
    unawaited(_loop(++_generation));
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _generation++;
    wake();
    if (_device.isDemo) DemoRegistry.forDevice(_device.id).stop();
    await _driver.disconnect();
    _setHealth(link: ModbusLinkState.disconnected);
  }

  /// Interrompe a espera e faz uma varredura já.
  void wake() {
    final w = _wake;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<void> _loop(int generation) async {
    bool current() => _running && !_disposed && generation == _generation;
    while (current()) {
      if (_tags.isEmpty) {
        await _sleep(null);
        continue;
      }
      final delay = await _scanOnce(current);
      if (!current()) break;
      await _sleep(delay);
    }
  }

  Future<void> _sleep(Duration? d) async {
    _wake = Completer<void>();
    if (d == null) {
      await _wake!.future;
    } else {
      await Future.any([_wake!.future, Future<void>.delayed(d)]);
    }
    _wake = null;
  }

  /// Uma varredura completa. Devolve quanto esperar até a próxima.
  Future<Duration> _scanOnce(bool Function() current) async {
    final driver = _driver;
    final tags = _tags;
    final sw = Stopwatch()..start();
    try {
      final reads = await driver.scan(tags, store, stillCurrent: () => current() && identical(driver, _driver));
      _failures = 0;
      _setHealth(link: driver.state.value, lastScanMs: sw.elapsedMilliseconds, blocks: reads);
      return Duration(milliseconds: _device.pollMs);
    } on CommError catch (e) {
      _failures++;
      _log.warning('${_device.name}: ${e.message}');
      for (final t in tags) {
        final current = store.read(t.id);
        if (current.quality == TagQuality.addressError || current.quality == TagQuality.configError) continue;
        store.publish(t.id, current.degrade(TagQuality.commLost, e.userMessage));
      }
      _setHealth(link: driver.state.value, message: e.userMessage);
      final seconds = [1, 2, 4, 8, 10][(_failures - 1).clamp(0, 4)];
      return Duration(seconds: seconds);
    }
  }

  // ── Leitura avulsa ───────────────────────────────────────────────────────────

  /// Lê uma variável agora, fora da varredura, pela mesma conexão — é o
  /// "lendo agora" do cadastro de variável. Serializa com a varredura (o
  /// transporte faz um pedido por vez), então não disputa a conexão.
  Future<Object> readOnce(Tag tag) => _driver.readOnce(tag);

  // ── Escrita ──────────────────────────────────────────────────────────────────

  /// Grava [value] na variável. Lança [TagValueError] (valor inválido) ou
  /// [CommError] (equipamento recusou / sem conexão) — a tela mostra.
  Future<void> write(Tag tag, Object value) async {
    await _driver.write(tag, value);
    wake();
  }

  void _setHealth({required ModbusLinkState link, String message = '', int? lastScanMs, int? blocks}) {
    if (_disposed) return;
    final prev = health.value;
    health.value = DeviceHealth(
      link: link,
      message: message,
      lastScanMs: lastScanMs ?? prev.lastScanMs,
      blocks: blocks ?? prev.blocks,
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    await _driver.dispose();
    health.dispose();
  }
}
