import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/modbus/modbus_client_simulated.dart';
import 'package:ihm/core/modbus/modbus_exception.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/recipe.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/recipes/recipe_applier.dart';
import 'package:ihm/services/recipes/recipe_logic.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';

/// Aplicar receita pelo caminho de produção (RC-3, RC-5, RC-6, RC-7):
/// `HmiRuntime.readNow`/`write` → sessão → driver Modbus → a memória da
/// máquina de demonstração, com o "programa do CLP" rodando. Quando o teste
/// precisa de um defeito (comunicação que cai na 3ª escrita, CLP que limita
/// o valor), só o cliente Modbus é trocado — o resto do caminho é o mesmo.
void main() {
  const demo = DemoProject.deviceId;
  const hr = ModbusArea.holdingRegister;
  const coil = ModbusArea.coil;

  const loaded = Tag(id: 't_carregada', name: 'Receita carregada', deviceId: demo, area: coil, address: 20, dataType: TagDataType.bool, writable: true);
  const outOfMap = Tag(id: 't_fora', name: 'Fora do mapa', deviceId: demo, address: 5000, writable: true); // a demo tem 1000 registradores
  const tension = Tag(id: 't_tensao', name: 'Tensão desejada', deviceId: demo, address: 100, writable: true, unit: '%');
  const temp10 = Tag(id: 't_temp10', name: 'Temperatura alvo', deviceId: demo, address: 101, writable: true, unit: '°C', scale: 0.1);
  const knife = Tag(id: 't_faca', name: 'Faca dupla', deviceId: demo, area: coil, address: 21, dataType: TagDataType.bool, writable: true);

  late Project project;
  late HmiRuntime runtime;
  late RecipeType rotulo;

  ModbusMemory memory([String id = demo]) => DemoRegistry.forDevice(id).memory;

  setUp(() async {
    DemoRegistry.discard(demo);
    final p = DemoProject.build();
    project = p.copyWith(tags: [...p.tags, loaded, outOfMap, tension, temp10, knife]);
    rotulo = project.recipeType(DemoProject.recipeTypeId)!;
    runtime = HmiRuntime();
    await runtime.apply(project);
  });

  tearDown(() async {
    await runtime.dispose();
    DemoRegistry.discard(demo);
    DemoRegistry.discard('demo_b');
  });

  /// Troca o cliente Modbus (a memória continua a da demonstração).
  Future<void> faulty(_FaultyClient Function(ModbusMemory) make) async {
    await runtime.dispose();
    runtime = HmiRuntime(clientFactory: (d) => make(memory(d.id)));
    await runtime.apply(project);
  }

  /// Liga a cortadora (porta fechada, sem alarme): "Em ciclo" acende.
  void startMachine() {
    memory().pokeBit(coil, DemoMap.coilRun, true);
    DemoRegistry.forDevice(demo).step(0.2);
  }

  RecipeType withLoaded(RecipeType t) => t.upsertMachine(t.machines.single.withLoaded(loaded.id));

  test('aplica: grava só o que difere, relê, confere e liga o bit de receita carregada', () async {
    final applier = RecipeApplier(runtime); // com a espera de verdade antes de reler
    final type = withLoaded(rotulo);
    final recipe = project.recipe('demo_receita_60')!; // 65 m/min, 60 mm; a máquina abre com 80 e 120
    memory().pokeBit(coil, loaded.address, true);

    final plan = await applier.prepare(type: type, machine: type.machines.single, recipe: recipe);
    expect(plan.blockers, isEmpty);
    expect(plan.condition!.ok, isTrue, reason: 'máquina parada: "Em ciclo" desligado');
    expect(plan.writes.map((w) => (w.param.key, w.current, w.target)), [('vel', 80.0, 65.0), ('comp', 120.0, 60.0)]);

    final progress = <int>[];
    final r = await applier.apply(plan, onProgress: (done, _) => progress.add(done));
    expect(r.outcome, RecipeOutcome.applied);
    expect(r.headline, 'Receita aplicada');
    expect(r.results.map((x) => x.outcome), [RecipeItemOutcome.verified, RecipeItemOutcome.verified]);
    expect(r.results.first.label, 'Gravado e conferido');
    expect(r.loadedSet, isTrue);
    expect(progress, [0, 1, 2]);
    expect(memory().register(hr, DemoMap.hrSpeedSetpoint), 65);
    expect(memory().register(hr, DemoMap.hrLabelLength), 60);
    expect(memory().bit(coil, loaded.address), isTrue);

    // De novo: nada muda, e isso também é dito.
    final again = await applier.apply(await applier.prepare(type: type, machine: type.machines.single, recipe: recipe));
    expect(again.headline, 'Receita confirmada: nada precisou mudar');
    expect(again.results, isEmpty);
  });

  test('ler da máquina: valores na unidade de engenharia, e gravar desfaz a escala', () async {
    final applier = RecipeApplier(runtime, verifyDelay: Duration.zero);
    final type = RecipeType(
      id: 'rt_forno',
      name: 'Forno',
      params: [RecipeParam.fromTag('temp', temp10), RecipeParam.fromTag('faca', knife)],
      machines: const [RecipeMachine(deviceId: demo, tags: {'temp': 't_temp10', 'faca': 't_faca'})],
    );
    memory().pokeRegister(hr, temp10.address, 752);

    final snap = await applier.read(type, type.machines.single);
    expect(snap.ok, isTrue);
    expect(snap.values, {'temp': 75.2, 'faca': 0.0}, reason: 'o equipamento manda 752; a receita guarda 75,2 °C');

    final r = await applier.apply(await applier.prepare(
      type: type,
      machine: type.machines.single,
      recipe: const Recipe(id: 'r', typeId: 'rt_forno', values: {'temp': 80.5, 'faca': 1}),
    ));
    expect(r.outcome, RecipeOutcome.applied);
    expect(memory().register(hr, temp10.address), 805, reason: 'gravar 80,5 °C manda 805');
    expect(memory().bit(coil, knife.address), isTrue);
  });

  test('condição: com a máquina em ciclo não aplica — a confirmação já diz por quê', () async {
    final applier = RecipeApplier(runtime, verifyDelay: Duration.zero);
    startMachine();
    final plan = await applier.prepare(type: rotulo, machine: rotulo.machines.single, recipe: project.recipe('demo_receita_60')!);
    expect(plan.canApply, isFalse);
    expect(plan.blockers.single, 'Só aplica com "Em ciclo (bit da palavra)" DESLIGADO. Agora está LIGADO.');
    expect(plan.writes.length, 2, reason: 'o "de → para" continua à vista');

    final r = await applier.apply(plan);
    expect(r.outcome, RecipeOutcome.notApplied);
    expect(r.writtenCount, 0);
    expect(memory().register(hr, DemoMap.hrSpeedSetpoint), 80);
  });

  test('a máquina partiu entre a confirmação e o toque em Aplicar: nada é gravado', () async {
    final applier = RecipeApplier(runtime, verifyDelay: Duration.zero);
    final type = withLoaded(rotulo);
    memory().pokeBit(coil, loaded.address, true);
    final plan = await applier.prepare(type: type, machine: type.machines.single, recipe: project.recipe('demo_receita_60')!);
    expect(plan.canApply, isTrue);

    startMachine();
    final r = await applier.apply(plan);
    expect(r.outcome, RecipeOutcome.notApplied);
    expect(r.headline, 'Não aplicada: só aplica com "Em ciclo (bit da palavra)" DESLIGADO');
    expect(r.results.map((x) => x.outcome), everyElement(RecipeItemOutcome.notTried));
    expect(memory().register(hr, DemoMap.hrSpeedSetpoint), 80);
    expect(memory().register(hr, DemoMap.hrLabelLength), 120);
    expect(memory().bit(coil, loaded.address), isTrue, reason: 'nem o bit foi mexido');
  });

  test('falha parcial: o equipamento recusa o 2º valor — o 1º fica, o 3º nem é tentado, e o bit fica desligado', () async {
    final applier = RecipeApplier(runtime, verifyDelay: Duration.zero);
    const type = RecipeType(
      id: 'rt3',
      name: 'Teste',
      params: [
        RecipeParam(key: 'a', name: 'Velocidade', unit: 'm/min'),
        RecipeParam(key: 'b', name: 'Fora do mapa'),
        RecipeParam(key: 'c', name: 'Comprimento', unit: 'mm'),
      ],
      machines: [RecipeMachine(deviceId: demo, tags: {'a': 'demo_sp', 'b': 't_fora', 'c': 'demo_comp'}, loadedTagId: 't_carregada')],
    );
    memory().pokeBit(coil, loaded.address, true);
    final plan = await applier.prepare(type: type, machine: type.machines.single, recipe: const Recipe(id: 'r3', typeId: 'rt3', values: {'a': 90, 'b': 5, 'c': 150}));
    expect(plan.canApply, isTrue, reason: 'leitura recusada de um parâmetro não impede: a gravação vai dizer');
    expect(plan.writes.map((w) => w.param.key), ['a', 'b', 'c']);
    expect(plan.writes[1].readProblem, 'endereço inexistente no equipamento');

    final r = await applier.apply(plan);
    expect(r.outcome, RecipeOutcome.partial);
    expect(r.headline, 'Parou no 2º de 3 valores: endereço inexistente no equipamento');
    expect(r.results.map((x) => x.outcome), [RecipeItemOutcome.verified, RecipeItemOutcome.refused, RecipeItemOutcome.notTried]);
    expect(r.results[1].label, 'Recusado: endereço inexistente no equipamento');
    expect(r.results[2].label, 'Não gravado: a aplicação parou antes');
    expect(r.loadedSet, isFalse);
    expect(memory().register(hr, DemoMap.hrSpeedSetpoint), 90);
    expect(memory().register(hr, DemoMap.hrLabelLength), 120);
    expect(memory().bit(coil, loaded.address), isFalse, reason: 'desligado no começo; não religa com a receita pela metade');
  });

  test('sem comunicação na 3ª gravação: para, diz onde parou, não relê no escuro e não liga o bit', () async {
    late _FaultyClient client;
    await faulty((m) => client = _FaultyClient(memory: m, failOnWrite: 4)); // 1ª gravação é o bit
    final applier = RecipeApplier(runtime, verifyDelay: Duration.zero);
    final type = RecipeType(
      id: 'rt4',
      name: 'Teste',
      params: [RecipeParam.fromTag('a', project.tag('demo_sp')!), RecipeParam.fromTag('b', project.tag('demo_comp')!), RecipeParam.fromTag('c', tension)],
      machines: const [RecipeMachine(deviceId: demo, tags: {'a': 'demo_sp', 'b': 'demo_comp', 'c': 't_tensao'}, loadedTagId: 't_carregada')],
    );
    final plan = await applier.prepare(type: type, machine: type.machines.single, recipe: const Recipe(id: 'r4', typeId: 'rt4', values: {'a': 90, 'b': 150, 'c': 40}));
    expect(plan.canApply, isTrue);

    final r = await applier.apply(plan);
    expect(r.outcome, RecipeOutcome.partial);
    expect(r.headline, 'Parou no 3º de 3 valores: sem resposta do equipamento');
    expect(r.results.map((x) => x.outcome), [RecipeItemOutcome.unverified, RecipeItemOutcome.unverified, RecipeItemOutcome.commLost]);
    expect(r.results.first.label, 'Gravado, sem conferência: a comunicação caiu logo depois');
    expect(r.results.last.label, 'Sem comunicação: sem resposta do equipamento');
    expect(client.log, ['coil 20 = 0', 'reg 1 = 90', 'reg 5 = 150'], reason: 'bit desligado primeiro; nada depois da queda');
    expect(memory().register(hr, tension.address), 0);
  });

  test('o CLP limitou o valor: aplicada com divergência, e o bit não liga', () async {
    await faulty((m) => _FaultyClient(memory: m, clamp: (DemoMap.hrSpeedSetpoint, 120)));
    final applier = RecipeApplier(runtime, verifyDelay: Duration.zero);
    final type = withLoaded(rotulo);
    final plan = await applier.prepare(
      type: type,
      machine: type.machines.single,
      recipe: const Recipe(id: 'r5', typeId: DemoProject.recipeTypeId, values: {'vel': 140, 'comp': 120}),
    );
    expect(plan.writes.single.param.key, 'vel', reason: 'o comprimento já está igual');

    final r = await applier.apply(plan);
    expect(r.outcome, RecipeOutcome.divergent);
    expect(r.headline, 'Aplicada com 1 divergência');
    expect(r.results.single.label, 'Gravou 140 m/min, a máquina ficou com 120 m/min');
    expect(r.loadedSet, isFalse);
    expect(r.loadedProblem, 'não ligado: algum valor não conferiu');
  });

  test('sem comunicação ao preparar: nem a confirmação deixa aplicar', () async {
    await faulty((m) => _FaultyClient(memory: m)..failureRate = 1);
    final plan = await RecipeApplier(runtime).prepare(type: rotulo, machine: rotulo.machines.single, recipe: project.recipe('demo_receita_60')!);
    expect(plan.blockers.single, 'Sem comunicação com Cortadora de rótulos: sem resposta do equipamento');
  });

  test('transferir para outra máquina compatível: mesma receita, variáveis da outra máquina', () async {
    const b = Device(id: 'demo_b', name: 'Cortadora 2', kind: DeviceKind.demo);
    project = project.copyWith(devices: [...project.devices, b], tags: [
      ...project.tags,
      const Tag(id: 'b_sp', name: 'Velocidade desejada', deviceId: 'demo_b', address: 200, writable: true, unit: 'm/min'),
      const Tag(id: 'b_comp', name: 'Comprimento do rótulo', deviceId: 'demo_b', address: 201, writable: true, unit: 'mm'),
    ]);
    await runtime.apply(project);
    final from = rotulo.machines.single;
    final suggested = RecipeLogic.suggestBinding(rotulo, project, toDeviceId: 'demo_b', from: from);
    expect(suggested, {'vel': 'b_sp', 'comp': 'b_comp'});
    final type = rotulo.upsertMachine(RecipeMachine(deviceId: 'demo_b', tags: suggested));
    final machineB = type.machine('demo_b')!;
    expect(RecipeLogic.machineProblems(type, machineB, project), isEmpty);

    final applier = RecipeApplier(runtime, verifyDelay: Duration.zero);
    final r = await applier.apply(await applier.prepare(type: type, machine: machineB, recipe: project.recipe('demo_receita_60')!));
    expect(r.outcome, RecipeOutcome.applied);
    expect(r.plan.device.name, 'Cortadora 2');
    expect(memory('demo_b').register(hr, 200), 65);
    expect(memory('demo_b').register(hr, 201), 60);
    expect(memory().register(hr, DemoMap.hrSpeedSetpoint), 80, reason: 'a primeira máquina não foi tocada');
  });
}

/// A memória da demonstração com defeitos sob encomenda: perde a comunicação
/// na N-ésima gravação, ou "o CLP" limita um registrador depois de gravado.
/// Guarda as gravações que chegaram, na ordem.
class _FaultyClient extends SimulatedModbusClient {
  _FaultyClient({required super.memory, this.failOnWrite, this.clamp}) : super(latency: Duration.zero);

  final int? failOnWrite;
  final (int, int)? clamp;
  final List<String> log = [];
  int _writes = 0;

  @override
  Future<Uint8List> transact(Uint8List requestPdu) async {
    final fn = requestPdu[0];
    final write = fn == 0x05 || fn == 0x06 || fn == 0x10;
    if (write && ++_writes == failOnWrite) throw const ModbusTimeout('falha injetada');
    final response = await super.transact(requestPdu);
    if (write) {
      final address = (requestPdu[1] << 8) | requestPdu[2];
      final value = (requestPdu[3] << 8) | requestPdu[4];
      log.add(fn == 0x05 ? 'coil $address = ${value == 0xFF00 ? 1 : 0}' : 'reg $address = ${fn == 0x06 ? value : '…'}');
      final c = clamp;
      if (c != null && memory.register(ModbusArea.holdingRegister, c.$1) > c.$2) memory.pokeRegister(ModbusArea.holdingRegister, c.$1, c.$2);
    }
    return response;
  }
}
