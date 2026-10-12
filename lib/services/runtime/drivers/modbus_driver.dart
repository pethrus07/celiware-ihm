import 'package:flutter/foundation.dart';

import '../../../core/modbus/modbus_client.dart';
import '../../../core/modbus/modbus_client_simulated.dart';
import '../../../core/modbus/modbus_exception.dart';
import '../../../core/modbus/modbus_memory.dart';
import '../../../models/tag.dart';
import '../scan_planner.dart';
import '../tag_codec.dart';
import '../tag_store.dart';
import 'device_driver.dart';

/// Modbus (TCP hoje; RTU/ASCII entram pelo mesmo cliente) atrás do contrato
/// de [DeviceDriver].
///
/// Agrupa as leituras ([ScanPlanner]) e trata o endereço errado: quando um
/// bloco com várias variáveis recebe "endereço inexistente", elas passam a
/// ser lidas uma a uma no próximo ciclo e só a errada fica marcada — um
/// endereço errado nunca apaga a tela inteira.
class ModbusDriver extends DeviceDriver {
  ModbusDriver(this.client, {this.planner = const ScanPlanner()});

  final ModbusClient client;
  final ScanPlanner planner;
  final Set<String> _isolated = {};

  @override
  ValueListenable<ModbusLinkState> get state => client.state;

  @override
  bool get isConnected => client.isConnected;

  @override
  Future<void> connect() => client.connect();

  @override
  Future<void> disconnect() => client.disconnect();

  @override
  void tagsChanged(List<Tag> previous, List<Tag> current) {
    final before = {for (final t in previous) t.id: t};
    // Variável sumiu ou teve o endereço corrigido → volta ao agrupamento.
    _isolated.removeWhere((id) {
      final now = current.where((t) => t.id == id).firstOrNull;
      final old = before[id];
      return now == null || old == null || now.area != old.area || now.address != old.address || now.span != old.span;
    });
  }

  @override
  Future<int> scan(List<Tag> tags, TagStore store, {required bool Function() stillCurrent}) async {
    if (!client.isConnected) await client.connect();
    // Variável com tópico MQTT, endereço S7, campo de mensagem crua ou NodeId (o
    // equipamento mudou de protocolo): não tem endereço Modbus de verdade —
    // ler o HR 0 no lugar dela mostraria um número qualquer como se fosse o dado.
    bool foreign(Tag t) => t.mqtt != null || t.s7 != null || t.raw != null || t.opcua != null;
    for (final t in tags.where(foreign)) {
      if (store.read(t.id).quality != TagQuality.configError) {
        final what = t.mqtt != null ? 'MQTT' : t.s7 != null ? 'Siemens S7' : t.opcua != null ? 'OPC UA' : 'mensagem crua (Arduino)';
        store.publish(t.id, TagReading(quality: TagQuality.configError, message: 'variável de $what num equipamento Modbus', at: DateTime.now()));
      }
    }
    final blocks = planner.plan(tags.where((t) => !foreign(t)).toList(), isolated: _isolated);
    for (final block in blocks) {
      if (!stillCurrent()) break;
      await _readBlock(block, store);
    }
    return blocks.length;
  }

  Future<void> _readBlock(ScanBlock block, TagStore store) async {
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
        onWake?.call();
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

  @override
  Future<Object> readOnce(Tag tag) async {
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

  @override
  Future<void> write(Tag tag, Object value) async {
    if (!tag.canWrite) throw TagValueError('"${tag.name}" é só leitura');
    if (tag.isArray) throw TagValueError('"${tag.name}" é uma lista; não é gravável pela tela');
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
  }

  @override
  Future<void> ping() async {
    if (!client.isConnected) await client.connect();
    // Rede de verdade: uma leitura mínima confirma que há Modbus do outro lado
    // (e não só uma porta aberta). Exceção de endereço também prova que o
    // equipamento respondeu. O simulado está sempre vivo.
    if (client is SimulatedModbusClient) return;
    try {
      await client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 1);
    } on ModbusExceptionResponse {/* respondeu: está vivo */}
  }

  static bool _asBool(Object v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    throw const TagValueError('Esperado liga/desliga');
  }

  @override
  Future<void> dispose() => client.dispose();
}
