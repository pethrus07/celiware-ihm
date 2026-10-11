import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/modbus/modbus_framing.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/core/modbus/modbus_serial_server.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/runtime/tag_store.dart';

/// Equipamento atrás de um gateway RS-485 → Ethernet (RTU/ASCII cru no TCP),
/// pelo caminho de produção: fábrica padrão → ModbusDriver → sessão.
void main() {
  late ModbusMemory memory;
  late ModbusSerialTcpServer server;

  Future<Device> sobe(ModbusFraming framing) async {
    memory = ModbusMemory(holdingRegisters: 100, coils: 50);
    server = ModbusSerialTcpServer(memory, framing: framing, unitId: 3);
    await server.start();
    return Device(
      id: 'inv',
      name: 'Inversor',
      kind: DeviceKind.modbusRtuTcp,
      framing: framing,
      host: '127.0.0.1',
      port: server.port,
      unitId: 3,
      timeoutMs: 400,
      pollMs: 50,
    );
  }

  tearDown(() => server.stop());

  for (final framing in ModbusFraming.values) {
    test('${framing.label}: testar conexão, ler na varredura e gravar', () async {
      final device = await sobe(framing);
      const freq = Tag(id: 'f', deviceId: 'inv', name: 'Frequência', area: ModbusArea.holdingRegister, address: 1, writable: true);
      memory.pokeRegister(ModbusArea.holdingRegister, 1, 4500);

      final rt = HmiRuntime();
      expect((await rt.probe(device)).ok, isTrue);
      expect((await rt.probe(device, tag: freq)).value, 4500);

      await rt.apply(Project(devices: [device], tags: const [freq]));
      final sub = rt.subscribe(const ['f']);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(rt.watch('f').value.value, 4500);
      expect(rt.watch('f').value.quality, TagQuality.good);

      await rt.write('f', 6000);
      expect(memory.register(ModbusArea.holdingRegister, 1), 6000);

      sub.cancel();
      await rt.dispose();
    });
  }

  test('ID errado no gateway = sem resposta, com mensagem de operador', () async {
    final device = (await sobe(ModbusFraming.rtu)).copyWith(unitId: 9);
    final r = await HmiRuntime().probe(device);
    expect(r.ok, isFalse);
    expect(r.message, 'sem resposta do equipamento');
  });

  test('envelope vai no arquivo do projeto só quando é gateway', () {
    const rtu = Device(id: 'a', name: 'A', kind: DeviceKind.modbusRtuTcp, framing: ModbusFraming.ascii, host: '10.0.0.5');
    expect(Device.fromJson(rtu.toJson()).framing, ModbusFraming.ascii);
    expect(Device.fromJson(rtu.toJson()).kind, DeviceKind.modbusRtuTcp);
    expect(const Device(id: 'b', name: 'B', host: '10.0.0.6').toJson().containsKey('framing'), isFalse);
    expect(rtu.addressLabel, '10.0.0.5:502 · ASCII · ID 1');
    expect(rtu.sameLinkAs(rtu.copyWith(framing: ModbusFraming.rtu)), isFalse);
  });
}
