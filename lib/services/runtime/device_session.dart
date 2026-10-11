import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../core/modbus/modbus_client.dart';
import '../../core/modbus/modbus_client_simulated.dart';
import '../../core/modbus/modbus_client_tcp.dart';
import '../../core/modbus/modbus_exception.dart';
import '../../core/modbus/modbus_memory.dart';
import '../../models/device.dart';
import '../../models/tag.dart';
import '../demo/demo_process.dart';
import '../net/local_network.dart';
import 'scan_planner.dart';
import 'tag_codec.dart';
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

  /// Quantas leituras Modbus cada varredura faz (depois do agrupamento).
  final int blocks;

  bool get online => link == ModbusLinkState.connected && message.isEmpty;
}

/// Varredura contínua de **um** equipamento.
///
/// Laço: planeja os blocos das variáveis em uso → lê um bloco por vez →
/// decodifica e publica no [TagStore] → espera [Device.pollMs] → repete.
/// Sem variável em uso, o laço dorme (não gera tráfego à toa).
///
/// Falhas, cada uma com o seu tratamento:
///   • **endereço inexistente** num bloco com várias variáveis → as variáveis
///     do bloco passam a ser lidas uma a uma no próximo ciclo; só a errada
///     fica marcada ([TagQuality.addressError]). Um endereço errado nunca
///     apaga a tela inteira;
///   • **sem resposta / sem conexão** → todas ficam [TagQuality.commLost]
///     mantendo o último valor, e o laço tenta de novo com espera crescente
///     (1 s, 2 s, 4 s… até 10 s) para não martelar uma rede que caiu;
///   • **pedido inválido** (ex.: lista maior que 125 registradores) →
///     [TagQuality.configError] só naquela variável.
///
/// Escritas passam pelo mesmo cliente (o transporte serializa com as
/// leituras) e acordam o laço para o resultado aparecer na hora.
class DeviceSession {
  DeviceSession({
    required Device device,
    required this.store,
    ModbusClient Function(Device)? clientFactory,
    this.planner = const ScanPlanner(),
  })  : _device = device,
        _clientFactory = clientFactory ?? defaultClientFactory {
    _client = _clientFactory(device);
  }

  static final Logger _log = Logger('DeviceSession');

  final TagStore store;
  final ScanPlanner planner;
  final ModbusClient Function(Device) _clientFactory;

  Device _device;
  late ModbusClient _client;
  List<Tag> _tags = const [];
  final Set<String> _isolated = {};

  bool _running = false;
  bool _disposed = false;
  int _generation = 0;
  Completer<void>? _wake;
  int _failures = 0;

  final ValueNotifier<DeviceHealth> health = ValueNotifier(const DeviceHealth());

  Device get device => _device;

  /// Cliente real ou simulado conforme o tipo de equipamento.
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

  // ── Configuração ─────────────────────────────────────────────────────────────

  /// Define quais variáveis deste equipamento estão em uso agora.
  void setTags(List<Tag> tags) {
    final before = {for (final t in _tags) t.id: t};
    _tags = List.unmodifiable(tags);
    // Variável sumiu ou teve o endereço corrigido → volta ao agrupamento.
    _isolated.removeWhere((id) {
      final now = tags.where((t) => t.id == id).firstOrNull;
      final old = before[id];
      return now == null || old == null || now.area != old.area || now.address != old.address || now.span != old.span;
    });
    if (tags.isEmpty) {
      _setHealth(link: _client.state.value, blocks: 0);
    }
    wake();
  }

  /// Troca a configuração do equipamento; reabre a conexão só se precisar.
  Future<void> updateDevice(Device next) async {
    final relink = !next.sameLinkAs(_device);
    _device = next;
    if (relink) {
      final old = _client;
      _client = _clientFactory(next);
      await old.dispose();
      _isolated.clear();
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
    await _client.disconnect();
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
    final client = _client;
    final tags = _tags;
    final sw = Stopwatch()..start();
    try {
      if (!client.isConnected) await client.connect();
      final blocks = planner.plan(tags, isolated: _isolated);
      for (final block in blocks) {
        if (!current() || !identical(client, _client)) break;
        await _readBlock(client, block);
      }
      _failures = 0;
      _setHealth(link: client.state.value, lastScanMs: sw.elapsedMilliseconds, blocks: blocks.length);
      return Duration(milliseconds: _device.pollMs);
    } on ModbusError catch (e) {
      _failures++;
      _log.warning('${_device.name}: ${e.message}');
      for (final t in tags) {
        final current = store.read(t.id);
        if (current.quality == TagQuality.addressError || current.quality == TagQuality.configError) continue;
        store.publish(t.id, current.degrade(TagQuality.commLost, e.userMessage));
      }
      _setHealth(link: client.state.value, message: e.userMessage);
      final seconds = [1, 2, 4, 8, 10][(_failures - 1).clamp(0, 4)];
      return Duration(seconds: seconds);
    }
  }

  Future<void> _readBlock(ModbusClient client, ScanBlock block) async {
    try {
      final now = DateTime.now();
      if (block.area.isBit) {
        final bits = block.area == ModbusArea.coil
            ? await client.fn01ReadCoils(startAddress: block.start, count: block.count)
            : await client.fn02ReadDiscreteInputs(startAddress: block.start, count: block.count);
        for (final t in block.tags) {
          final off = t.address - block.start;
          store.publish(t.id, TagReading(value: TagCodec.decodeBits(t, bits.sublist(off, off + t.span)), quality: TagQuality.good, at: now));
        }
      } else {
        final regs = block.area == ModbusArea.holdingRegister
            ? await client.fn03ReadHoldingRegisters(startAddress: block.start, quantity: block.count)
            : await client.fn04ReadInputRegisters(startAddress: block.start, quantity: block.count);
        for (final t in block.tags) {
          final off = t.address - block.start;
          store.publish(t.id, TagReading(value: TagCodec.decodeRegisters(t, regs.sublist(off, off + t.span)), quality: TagQuality.good, at: now));
        }
      }
    } on ModbusExceptionResponse catch (e) {
      if (e.code == ModbusExceptionResponse.illegalDataAddress && block.tags.length > 1) {
        // Algum endereço do bloco não existe: separa para achar qual.
        _isolated.addAll(block.tags.map((t) => t.id));
        wake();
        return;
      }
      final q = e.code == ModbusExceptionResponse.illegalDataAddress ? TagQuality.addressError : TagQuality.configError;
      for (final t in block.tags) {
        store.publish(t.id, TagReading(quality: q, message: e.userMessage, at: DateTime.now()));
      }
    } on ModbusRequestError catch (e) {
      for (final t in block.tags) {
        store.publish(t.id, TagReading(quality: TagQuality.configError, message: e.message, at: DateTime.now()));
      }
    }
  }

  // ── Leitura avulsa ───────────────────────────────────────────────────────────

  /// Lê uma variável agora, fora da varredura, pela mesma conexão — é o
  /// "lendo agora" do cadastro de variável. Serializa com a varredura (o
  /// transporte faz um pedido por vez), então não disputa o socket.
  Future<Object> readOnce(Tag tag) async {
    final client = _client;
    if (!client.isConnected) await client.connect();
    switch (tag.area) {
      case ModbusArea.coil:
        return TagCodec.decodeBits(tag, await client.fn01ReadCoils(startAddress: tag.address, count: tag.span));
      case ModbusArea.discreteInput:
        return TagCodec.decodeBits(tag, await client.fn02ReadDiscreteInputs(startAddress: tag.address, count: tag.span));
      case ModbusArea.holdingRegister:
        return TagCodec.decodeRegisters(tag, await client.fn03ReadHoldingRegisters(startAddress: tag.address, quantity: tag.span));
      case ModbusArea.inputRegister:
        return TagCodec.decodeRegisters(tag, await client.fn04ReadInputRegisters(startAddress: tag.address, quantity: tag.span));
    }
  }

  // ── Escrita ──────────────────────────────────────────────────────────────────

  /// Grava [value] na variável. Lança [TagValueError] (valor inválido) ou
  /// [ModbusError] (equipamento recusou / sem conexão) — a tela mostra.
  Future<void> write(Tag tag, Object value) async {
    if (!tag.canWrite) throw TagValueError('"${tag.name}" é só leitura');
    if (tag.isArray) throw TagValueError('"${tag.name}" é uma lista; não é gravável pela tela');
    final client = _client;
    if (!client.isConnected) await client.connect();

    if (tag.area == ModbusArea.coil) {
      await client.fn05WriteSingleCoil(address: tag.address, value: _asBool(value));
    } else if (tag.isBitOfRegister) {
      // Leitura-modificação-escrita: o CLP pode mudar outro bit da mesma
      // palavra entre a leitura e a escrita. Documentado em ARQUITETURA.md;
      // para comando crítico, prefira coil.
      final current = await client.fn03ReadHoldingRegisters(startAddress: tag.address, quantity: 1);
      final raw = TagCodec.encodeBitIntoRegister(tag, current.first, _asBool(value));
      await client.fn06WriteSingleRegister(address: tag.address, value: raw);
    } else {
      final number = value is num ? value : throw TagValueError('"${tag.name}" espera um número');
      final regs = TagCodec.encodeRegisters(tag, number);
      if (regs.length == 1) {
        await client.fn06WriteSingleRegister(address: tag.address, value: regs.first);
      } else {
        await client.fn16WriteMultipleRegisters(startAddress: tag.address, values: regs);
      }
    }
    wake();
  }

  static bool _asBool(Object v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    throw const TagValueError('Esperado liga/desliga');
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
    await _client.dispose();
    health.dispose();
  }
}
