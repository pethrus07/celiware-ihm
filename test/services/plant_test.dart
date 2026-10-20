import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/modbus/modbus_client_simulated.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/models/calc.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/logic_rule.dart';
import 'package:ihm/models/plant.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/alarms/alarm_engine.dart';
import 'package:ihm/services/cameras/camera_vault.dart';
import 'package:ihm/services/plant/plant_view.dart';
import 'package:ihm/services/rules/rule_engine.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';

/// A planta (reunião de 19–20/10/2026, D6/D7): Planta > Projetos, regras da
/// planta que cruzam projetos, arquivo da planta com a lista de projetos
/// (`schemaVersion` 2) e o projeto avulso de sempre (1).
void main() {
  const prensaDev = Device(id: 'd1', name: 'CLP', host: 'prensa', pollMs: 100);
  const liga = Tag(id: 'liga', name: 'Liga', deviceId: 'd1', area: ModbusArea.coil, address: 0, dataType: TagDataType.bool, writable: true, ruleWritable: true);
  const fornoDev = Device(id: 'd1', name: 'CLP', host: 'forno', pollMs: 100);
  const temp = Tag(id: 'temp', name: 'Temperatura', deviceId: 'd1', address: 0);
  const dobro = Tag(id: 'dobro', name: 'Dobro', deviceId: CalcDevice.id, dataType: TagDataType.float32, calc: CalcSpec(expression: '{temp} * 2'));

  final prensa = const Project(name: 'Prensa', devices: [prensaDev], tags: [liga]);
  final forno = const Project(name: 'Forno', devices: [fornoDev, CalcDevice.device], tags: [temp, dobro]);

  group('arquivo', () {
    test('projeto avulso das versões antigas vira planta com UM projeto, com as regras dele', () {
      const local = LogicRule(id: 'r1', name: 'Local', condition: CalcSpec(expression: '{liga} == 1'), targetTagId: 'liga');
      final bytes = ProjectRepository.encode(prensa.copyWith(rules: const [local]));
      expect(jsonDecode(utf8.decode(bytes))['schemaVersion'], 1, reason: 'projeto avulso continua no formato da 1.4.0');

      final plant = ProjectRepository.decodePlant(bytes, newProjectId: () => 'p_1');
      expect(plant.name, Plant.defaultName);
      expect(plant.projects.single.id, 'p_1');
      expect(plant.projects.single.project.rules.single.id, 'r1', reason: 'regra de antes fica no projeto: comportamento igual');
      expect(plant.rules, isEmpty);
    });

    test('planta: ida e volta com a lista de projetos e as regras da planta; decode() de projeto recusa planta', () {
      const global = LogicRule(id: 'g1', name: 'Forno quente para a prensa', condition: CalcSpec(expression: '{pf/temp} > 80'), targetTagId: 'pp/liga');
      final plant = Plant(name: 'Fábrica', projects: [PlantProject('pp', prensa), PlantProject('pf', forno)], rules: const [global]);
      final bytes = ProjectRepository.encodePlant(plant);
      final raw = jsonDecode(utf8.decode(bytes)) as Map;
      expect((raw['schemaVersion'], raw['kind']), (2, 'planta'));
      expect((raw['projects'] as List).map((p) => (p as Map)['id']), ['pp', 'pf']);
      expect((raw['projects'] as List).first, isNot(contains('format')));

      final back = ProjectRepository.decodeFile(bytes);
      expect(back, isA<PlantFile>());
      final p = (back as PlantFile).plant;
      expect(p.name, 'Fábrica');
      expect(p.projects.map((e) => e.project.name), ['Prensa', 'Forno']);
      expect(p.rules.single.targetTagId, 'pp/liga');
      expect(utf8.decode(ProjectRepository.encodePlant(p)), utf8.decode(bytes));
      expect(() => ProjectRepository.decode(bytes), throwsA(isA<ProjectFormatError>()));

      final newer = utf8.encode(jsonEncode({...raw, 'schemaVersion': 3}));
      expect(() => ProjectRepository.decodeFile(newer), throwsA(isA<ProjectFormatError>()));
    });
  });

  group('referências e visão', () {
    test('regra da planta guardada qualificada; na visão, o projeto aberto sem prefixo', () {
      const view = LogicRule(id: 'g', name: 'G', condition: CalcSpec(expression: '{pf/temp} > 80 and {liga} == 1', names: {'liga': 'Liga'}), targetTagId: 'liga');
      final stored = PlantRef.ruleToStored(view, 'pp');
      expect(stored.condition.expression, '{pf/temp} > 80 and {pp/liga} == 1');
      expect(stored.condition.names.keys, ['pp/liga']);
      expect(stored.targetTagId, 'pp/liga');
      expect(PlantRef.ruleToView(stored, 'pp').condition.expression, view.condition.expression);
      expect(PlantRef.ruleToView(stored, 'pf').condition.expression, '{temp} > 80 and {pp/liga} == 1');
      expect(PlantRef.projectsOf(stored), {'pf', 'pp'});
    });

    test('motor: só o que as regras ligadas citam dos outros projetos, com a calculada e as entradas dela', () {
      const global = LogicRule(id: 'g1', name: 'G', condition: CalcSpec(expression: '{pf/dobro} > 160'), targetTagId: 'pp/liga');
      final live = PlantView.runtime(openId: 'pp', open: prensa, others: {'pf': forno}, rules: const [global]);
      expect(live.tags.map((t) => t.id), ['liga', 'pf/temp', 'pf/dobro']);
      expect(live.tag('pf/dobro')!.calc!.expression, '{pf/temp} * 2');
      expect(live.tag('pf/temp')!.name, 'Forno · Temperatura');
      expect(live.tag('pf/temp')!.deviceId, 'pf/d1');
      expect(live.devices.map((d) => d.id), ['d1', 'pf/d1', CalcDevice.id]);
      expect(live.rules.single.targetTagId, 'liga');

      // Regra desligada não conecta máquina nenhuma.
      final off = PlantView.runtime(openId: 'pp', open: prensa, others: {'pf': forno}, rules: [global.copyWith(enabled: false)]);
      expect(identical(off, prensa), isTrue);
    });
  });

  group('controlador', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('ihm_planta');
      CameraVault.instance = MemoryCameraVault();
    });

    tearDown(() async {
      try {
        await root.delete(recursive: true);
      } on FileSystemException {/* Windows ainda segurando o arquivo */}
    });

    Future<void> until(bool Function() ok, {Duration max = const Duration(seconds: 5)}) async {
      final end = DateTime.now().add(max);
      while (!ok() && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }

    test('regra da planta liga máquinas de projetos diferentes, com o projeto que for aberto', () async {
      final memPrensa = ModbusMemory(holdingRegisters: 4, coils: 4)..pokeBit(ModbusArea.coil, 0, true);
      final memForno = ModbusMemory(holdingRegisters: 4, coils: 4)..pokeRegister(ModbusArea.holdingRegister, 0, 50);
      final runtime = HmiRuntime(
        clientFactory: (d) => SimulatedModbusClient(memory: d.host == 'prensa' ? memPrensa : memForno, latency: Duration.zero),
      );
      final c = ProjectController(library: PlantStore(root: root), runtime: runtime);
      await c.load();
      final demo = c.openId!;
      final pp = await c.createProject(prensa);
      final pf = await c.createProject(forno);
      await c.deleteProject(demo);
      await c.open(pp);
      final alarms = AlarmEngine(controller: c, runtime: runtime);
      final rules = RuleEngine(controller: c, runtime: runtime, alarms: alarms, tick: const Duration(milliseconds: 100));
      addTearDown(() async {
        rules.dispose();
        alarms.dispose();
        c.dispose();
        await runtime.dispose();
      });

      // Escrita no editor com a prensa aberta: o forno vem qualificado.
      await c.savePlantRule(LogicRule(id: 'g1', name: 'Forno quente: parar a prensa', condition: CalcSpec(expression: '{${PlantRef.of(pf, 'temp')}} > 80'), targetTagId: 'liga'));
      expect(c.plantRules.single.targetTagId, PlantRef.of(pp, 'liga'), reason: 'guardada qualificada');
      expect(c.project.tags.map((t) => t.id), ['liga'], reason: 'as telas só veem o projeto aberto');
      expect(c.liveProject.tag(PlantRef.of(pf, 'temp')), isNotNull, reason: 'o motor lê o forno');

      memForno.pokeRegister(ModbusArea.holdingRegister, 0, 90);
      await until(() => rules.proposals.isNotEmpty);
      expect(rules.proposals.single.question, 'Forno quente: parar a prensa?');
      expect(await rules.confirm('g1'), isNull);
      await until(() => !memPrensa.bit(ModbusArea.coil, 0));
      expect(memPrensa.bit(ModbusArea.coil, 0), isFalse, reason: 'gravou na prensa por causa do forno');

      // Com o forno aberto, a mesma regra vale (agora o destino é de fora).
      await c.open(pf);
      expect(c.liveProject.tag(PlantRef.of(pp, 'liga')), isNotNull);
      expect(c.liveProject.rule('g1')!.targetTagId, PlantRef.of(pp, 'liga'));
      memPrensa.pokeBit(ModbusArea.coil, 0, true);
      memForno.pokeRegister(ModbusArea.holdingRegister, 0, 50);
      await until(() => rules.status('g1').state == RuleState.watching);
      memForno.pokeRegister(ModbusArea.holdingRegister, 0, 95);
      await until(() => rules.proposals.isNotEmpty);
      expect(rules.proposals, hasLength(1));
    });

    test('exportar a planta; importar soma os projetos (regras apontando para os novos) ou substitui com cópia antes', () async {
      final c = ProjectController(library: PlantStore(root: root), runtime: HmiRuntime());
      addTearDown(() async {
        c.dispose();
        await c.runtime.dispose();
      });
      await c.load();
      final demo = c.openId!;
      final pf = await c.createProject(forno);
      await c.open(demo);
      await c.savePlantRule(LogicRule(id: 'g1', name: 'G', condition: CalcSpec(expression: '{${PlantRef.of(pf, 'temp')}} > 80'), targetTagId: ''));
      await c.renamePlant('Fábrica');

      final file = await c.exportPlant();
      expect(file.name, 'Fábrica');
      expect(file.projects, hasLength(2));
      final bytes = ProjectRepository.encodePlant(file);

      // Somar: 2 + 2 projetos, nada substituído; a regra copiada aponta para o forno novo.
      final added = await c.addPlantProjects(ProjectRepository.decodePlant(bytes));
      expect(added, 2);
      expect(c.projects, hasLength(4));
      expect(c.projects.where((e) => e.name.startsWith('Forno')), hasLength(2));
      expect(c.plantRules, hasLength(2));
      final copied = c.plantRules.last;
      expect(copied.id, isNot('g1'));
      final newForno = c.projects.firstWhere((e) => e.name == 'Forno (2)').id;
      expect(copied.condition.inputIds, {PlantRef.of(newForno, 'temp')});

      // Substituir: cópia da planta atual em copias/ antes, depois só a nova.
      final backup = await c.replacePlant(ProjectRepository.decodePlant(ProjectRepository.encodePlant(const Plant(name: 'Outra', projects: [PlantProject('x', Project(name: 'Linha 9'))]))));
      expect(backup.existsSync(), isTrue);
      expect(backup.path, contains('copias'));
      final saved = ProjectRepository.decodePlant(backup.readAsBytesSync());
      expect(saved.projects, hasLength(4), reason: 'a cópia tem a planta inteira de antes');
      expect(c.plantName, 'Outra');
      expect(c.projects.map((e) => e.name), ['Linha 9']);
      expect(c.project.name, 'Linha 9');
      expect(c.plantRules, isEmpty);
      expect(Directory('${root.path}${Platform.pathSeparator}projetos').listSync().whereType<Directory>(), hasLength(1), reason: 'as pastas dos projetos que saíram também');

      // Nova planta: um projeto vazio, com cópia antes.
      final again = await c.newPlant();
      expect(again.existsSync(), isTrue);
      expect(c.projects.single.name, 'Meu projeto');
      expect(c.project.isEmpty, isTrue);
    });
  });
}
