import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/modbus/modbus_client_simulated.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/s7_config.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/runtime/tag_codec.dart';
import 'package:ihm/services/runtime/tag_store.dart';

/// Runtime inteiro sobre memória simulada: varredura, agrupamento, isolamento
/// de endereço errado, escrita e soltura segura do botão de pulso.
void main() {
  late ModbusMemory memory;
  late SimulatedModbusClient client;
  late HmiRuntime runtime;

  const device = Device(id: 'd1', name: 'CLP', host: 'x', pollMs: 20);
  const speed = Tag(id: 'speed', name: 'Velocidade', deviceId: 'd1', address: 2, writable: true);
  const run = Tag(id: 'run', name: 'Liga', deviceId: 'd1', area: ModbusArea.coil, address: 0, dataType: TagDataType.bool, writable: true);
  // Memória tem 8 registradores (0..7): o 8 não existe, mas fica perto o
  // bastante do 2 para cair no MESMO bloco de leitura — o caso do isolamento.
  const wrong = Tag(id: 'wrong', name: 'Endereço errado', deviceId: 'd1', address: 8);

  setUp(() async {
    memory = ModbusMemory(holdingRegisters: 8, coils: 100);
    client = SimulatedModbusClient(memory: memory, latency: Duration.zero);
    runtime = HmiRuntime(clientFactory: (_) => client);
    await runtime.apply(const Project(devices: [device], tags: [speed, run, wrong]));
  });

  tearDown(() => runtime.dispose());

  Future<TagReading> until(String tagId, bool Function(TagReading) test) async {
    final n = runtime.watch(tagId);
    if (test(n.value)) return n.value;
    final c = Completer<TagReading>();
    void l() {
      if (test(n.value) && !c.isCompleted) c.complete(n.value);
    }
    n.addListener(l);
    try {
      return await c.future.timeout(const Duration(seconds: 3));
    } finally {
      n.removeListener(l);
    }
  }

  test('só lê variáveis inscritas; ao cancelar, a sessão para', () async {
    memory.pokeRegister(ModbusArea.holdingRegister, 2, 80);
    final sub = runtime.subscribe(['speed']);
    final r = await until('speed', (r) => r.isGood);
    expect(r.value, 80);
    expect(runtime.watch('run').value.quality, TagQuality.waiting); // nunca pedida
    sub.cancel();
  });

  test('endereço errado marca só a variável errada; as outras continuam', () async {
    memory.pokeRegister(ModbusArea.holdingRegister, 2, 42);
    runtime.subscribe(['speed', 'wrong']);
    expect((await until('wrong', (r) => r.quality == TagQuality.addressError)).message, contains('endereço'));
    expect((await until('speed', (r) => r.isGood)).value, 42);
  });

  test('escrita grava na memória e a leitura seguinte já traz o valor', () async {
    runtime.subscribe(['speed']);
    await until('speed', (r) => r.isGood);
    await runtime.write('speed', 123);
    expect(memory.register(ModbusArea.holdingRegister, 2), 123);
    expect((await until('speed', (r) => r.value == 123)).value, 123);
  });

  test('queda de comunicação mantém o último valor, marcado como perdido', () async {
    memory.pokeRegister(ModbusArea.holdingRegister, 2, 55);
    runtime.subscribe(['speed']);
    await until('speed', (r) => r.isGood);
    client.failureRate = 1;
    final lost = await until('speed', (r) => r.quality == TagQuality.commLost);
    expect(lost.value, 55);
  });

  test('botão de pulso: soltura que falha é repetida até gravar 0', () async {
    await runtime.press('run');
    expect(memory.bit(ModbusArea.coil, 0), isTrue);

    client.failureRate = 1; // rede cai com o dedo no botão
    await runtime.release('run');
    expect(memory.bit(ModbusArea.coil, 0), isTrue); // ainda preso

    client.failureRate = 0; // rede volta
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(memory.bit(ModbusArea.coil, 0), isFalse); // o runtime soltou sozinho
  });

  test('bit de registrador de entrada: lê pela FC04, na varredura e no "Lendo agora", e recusa gravar', () async {
    const status = Tag(id: 'st', name: 'Falha', deviceId: 'd1', area: ModbusArea.inputRegister, address: 3,
        dataType: TagDataType.bool, bitIndex: 2, writable: true);
    await runtime.apply(const Project(devices: [device], tags: [speed, run, wrong, status]));
    expect(status.normalized().canWrite, isFalse, reason: 'registrador de entrada é só leitura');
    memory.pokeRegister(ModbusArea.inputRegister, 3, 1 << 2);
    memory.pokeRegister(ModbusArea.holdingRegister, 3, 0); // mesmo número no holding: não pode confundir
    runtime.subscribe(['st']);
    expect((await until('st', (r) => r.isGood)).value, isTrue);
    memory.pokeRegister(ModbusArea.inputRegister, 3, 1 << 1); // outro bit da palavra
    expect((await until('st', (r) => r.value == false)).value, isFalse);
    expect(await runtime.readNow(status.normalized()), isFalse);
    await expectLater(runtime.write('st', true), throwsA(isA<TagValueError>()));
  });

  test('variável apagada vira erro de configuração, não trava', () async {
    runtime.subscribe(['speed']);
    await until('speed', (r) => r.isGood);
    await runtime.apply(const Project(devices: [device], tags: [run]));
    runtime.subscribe(['speed']);
    expect((await until('speed', (r) => r.quality == TagQuality.configError)).message, contains('apagada'));
  });

  // Revisão de 21/10/2026: regra da planta que cita um projeto duplicado
  // trazia o mesmo CLP com outro id — e abria uma segunda conexão TCP.
  test('dois equipamentos com o mesmo endereço dividem UMA conexão; outro escravo, outra', () async {
    final created = <String>[];
    final mem = ModbusMemory(holdingRegisters: 8, coils: 8)..pokeRegister(ModbusArea.holdingRegister, 2, 70);
    final rt = HmiRuntime(clientFactory: (d) {
      created.add(d.id);
      return SimulatedModbusClient(memory: mem, latency: Duration.zero);
    });
    addTearDown(rt.dispose);
    const a = Device(id: 'd1', name: 'CLP', host: '192.168.0.10', pollMs: 20);
    // Mesmo CLP vindo de outro projeto: id qualificado, IP escrito diferente.
    const b = Device(id: 'p2/d1', name: 'Cópia · CLP', host: ' 192.168.0.10 ', pollMs: 20);
    const ta = Tag(id: 'v', name: 'Velocidade', deviceId: 'd1', address: 2, writable: true);
    const tb = Tag(id: 'p2/v', name: 'Cópia · Velocidade', deviceId: 'p2/d1', address: 2, writable: true);
    Future<void> good(String id, [Object? value]) async {
      for (var i = 0; i < 150; i++) {
        final r = rt.watch(id).value;
        if (r.isGood && (value == null || r.value == value)) return;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      fail('$id não chegou a ${value ?? 'boa'}: ${rt.watch(id).value.quality}');
    }

    await rt.apply(const Project(devices: [a, b], tags: [ta, tb]));
    rt.subscribe(['v', 'p2/v']);
    await good('v', 70);
    await good('p2/v', 70);
    expect(created, ['d1'], reason: 'uma sessão só, a do primeiro equipamento');
    expect(rt.health('p2/d1'), same(rt.health('d1')), reason: 'o selo dos dois é o da mesma conexão');

    await rt.write('p2/v', 99);
    expect(mem.register(ModbusArea.holdingRegister, 2), 99);
    await good('v', 99);
    expect(created, ['d1'], reason: 'gravar também vai pela conexão que já existe');

    // Outro escravo atrás do mesmo IP é outro equipamento: sessão própria.
    await rt.apply(Project(devices: [a, b.copyWith(unitId: 2)], tags: const [ta, tb]));
    await good('p2/v');
    expect(created, ['d1', 'p2/d1']);
    expect(rt.health('p2/d1'), isNot(same(rt.health('d1'))));

    // Voltou a ser o mesmo endereço: a sessão própria fecha e a do dono lê os dois.
    await rt.apply(const Project(devices: [a, b], tags: [ta, tb]));
    mem.pokeRegister(ModbusArea.holdingRegister, 2, 33);
    await good('p2/v', 33);
    expect(created, ['d1', 'p2/d1']);
    expect(rt.health('p2/d1'), same(rt.health('d1')));
  });

  test('endereço da conexão: protocolo, IP, porta e escravo ou rack/slot; cabo USB nunca divide', () {
    const tcp = Device(id: 'a', name: 'A', host: '10.0.0.5');
    expect(HmiRuntime.linkKey(tcp), HmiRuntime.linkKey(const Device(id: 'b', name: 'B', host: '10.0.0.5', pollMs: 100, timeoutMs: 900)));
    expect(HmiRuntime.linkKey(tcp), isNot(HmiRuntime.linkKey(const Device(id: 'b', name: 'B', host: '10.0.0.5', port: 503))));
    expect(HmiRuntime.linkKey(tcp), isNot(HmiRuntime.linkKey(const Device(id: 'b', name: 'B', host: '10.0.0.5', unitId: 3))));
    expect(HmiRuntime.linkKey(tcp), isNot(HmiRuntime.linkKey(const Device(id: 'b', name: 'B', kind: DeviceKind.modbusRtuTcp, host: '10.0.0.5'))));
    const s7a = Device(id: 's1', name: 'S7', kind: DeviceKind.s7, host: '10.0.0.6', port: 102);
    const s7b = Device(id: 's2', name: 'S7', kind: DeviceKind.s7, host: '10.0.0.6', port: 102, s7: S7Config(family: S7Family.s7300));
    expect(HmiRuntime.linkKey(s7a), isNotNull);
    expect(HmiRuntime.linkKey(s7a), isNot(HmiRuntime.linkKey(s7b)), reason: 'slot 1 × slot 2: outra CPU');
    for (final k in [DeviceKind.usbSerial, DeviceKind.mqtt, DeviceKind.opcua, DeviceKind.raw, DeviceKind.demo, DeviceKind.calc]) {
      expect(HmiRuntime.linkKey(Device(id: 'x', name: 'X', kind: k, host: '10.0.0.5')), isNull, reason: k.name);
    }
    expect(HmiRuntime.linkKey(const Device(id: 'x', name: 'X')), isNull, reason: 'sem IP não se compara');
  });
}
