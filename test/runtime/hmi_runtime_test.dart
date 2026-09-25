import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/modbus/modbus_client_simulated.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
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

  test('variável apagada vira erro de configuração, não trava', () async {
    runtime.subscribe(['speed']);
    await until('speed', (r) => r.isGood);
    await runtime.apply(const Project(devices: [device], tags: [run]));
    runtime.subscribe(['speed']);
    expect((await until('speed', (r) => r.quality == TagQuality.configError)).message, contains('apagada'));
  });
}
