import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/modbus/modbus_client_simulated.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/models/calc.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/logic_rule.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/alarms/alarm_engine.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/rules/rule_engine.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';

/// Regras entre máquinas (LG-4 a LG-7) pelo caminho de produção — runtime,
/// sessão e driver Modbus sobre memória simulada — com o relógio simulado
/// (`fake_async`): a duração da condição é contada sem esperar de verdade.
void main() {
  const device = Device(id: 'd1', name: 'Prensa', host: 'x', pollMs: 200);
  const temp = Tag(id: 'temp', name: 'Temperatura', deviceId: 'd1', address: 0);
  const liga = Tag(id: 'liga', name: 'Liga prensa', deviceId: 'd1', area: ModbusArea.coil, address: 0, dataType: TagDataType.bool, writable: true, ruleWritable: true);
  const semPermissao = Tag(id: 'liga2', name: 'Liga extrusora', deviceId: 'd1', area: ModbusArea.coil, address: 1, dataType: TagDataType.bool, writable: true);

  LogicRule rule({String target = 'liga', double value = 0, RuleMode mode = RuleMode.propose, int hold = 10}) => LogicRule(
        id: 'r1',
        name: 'Parar a prensa',
        condition: const CalcSpec(expression: '{temp} > 80', names: {'temp': 'Temperatura'}),
        holdSec: hold,
        targetTagId: target,
        value: value,
        mode: mode,
      );

  test('propõe só depois de a condição durar o tempo pedido; confirmar grava; uma vez por passagem', () {
    fakeAsync((fa) {
      final r = _Rig(fa, Project(devices: const [device], tags: const [temp, liga, semPermissao], rules: [rule()]));
      r.memory.pokeBit(ModbusArea.coil, 0, true);
      r.memory.pokeRegister(ModbusArea.holdingRegister, 0, 50);
      fa.elapse(const Duration(seconds: 2));
      expect(r.rules.proposals, isEmpty);
      expect(r.rules.status('r1').state, RuleState.watching);

      r.memory.pokeRegister(ModbusArea.holdingRegister, 0, 90);
      fa.elapse(const Duration(seconds: 5));
      expect(r.rules.status('r1').state, RuleState.counting);
      expect(r.rules.proposals, isEmpty, reason: 'ainda não durou 10 s');
      fa.elapse(const Duration(seconds: 6));
      final p = r.rules.proposals.single;
      expect((p.question, p.detail, p.action), ('Parar a prensa?', 'Grava DESLIGADO em "Liga prensa" (Prensa)', 'Desligar'));
      expect(r.memory.bit(ModbusArea.coil, 0), isTrue, reason: 'propor não grava nada');

      String? error = 'não respondeu';
      r.rules.confirm('r1').then((e) => error = e);
      fa.elapse(const Duration(milliseconds: 500));
      expect(error, isNull);
      expect(r.memory.bit(ModbusArea.coil, 0), isFalse, reason: 'confirmou: gravou');
      expect(r.rules.history.take(3).map((e) => e.type), [RuleEventType.written, RuleEventType.proposed, RuleEventType.fired]);
      expect(r.rules.history.first.text, contains('confirmado'));

      // Continua quente: não pergunta de novo (dispara na transição, nunca em laço).
      r.memory.pokeBit(ModbusArea.coil, 0, true);
      fa.elapse(const Duration(seconds: 30));
      expect(r.rules.proposals, isEmpty);
      expect(r.rules.status('r1').state, RuleState.acted);

      // Esfriou e esquentou de novo: vale outra vez. Ignorar não grava.
      r.memory.pokeRegister(ModbusArea.holdingRegister, 0, 50);
      fa.elapse(const Duration(seconds: 2));
      r.memory.pokeRegister(ModbusArea.holdingRegister, 0, 90);
      fa.elapse(const Duration(seconds: 11));
      expect(r.rules.proposals, hasLength(1));
      r.rules.ignore('r1');
      fa.elapse(const Duration(seconds: 1));
      expect(r.rules.proposals, isEmpty);
      expect(r.memory.bit(ModbusArea.coil, 0), isTrue);
      expect(r.rules.history.first.type, RuleEventType.ignored);

      // A condição passa antes de alguém responder: a pergunta sai sozinha.
      r.memory.pokeRegister(ModbusArea.holdingRegister, 0, 50);
      fa.elapse(const Duration(seconds: 2));
      r.memory.pokeRegister(ModbusArea.holdingRegister, 0, 90);
      fa.elapse(const Duration(seconds: 11));
      expect(r.rules.proposals, hasLength(1));
      r.memory.pokeRegister(ModbusArea.holdingRegister, 0, 50);
      fa.elapse(const Duration(seconds: 2));
      expect(r.rules.proposals, isEmpty);
      expect(r.rules.history.first.type, RuleEventType.withdrawn);
      r.dispose(fa);
    });
  });

  test('destino sem "aceita escrita por regra" é recusado e vira alarme; marcado, volta a valer', () {
    fakeAsync((fa) {
      final r = _Rig(fa, Project(devices: const [device], tags: const [temp, liga, semPermissao], rules: [rule(target: 'liga2')]));
      r.memory.pokeBit(ModbusArea.coil, 1, true);
      r.memory.pokeRegister(ModbusArea.holdingRegister, 0, 90);
      fa.elapse(const Duration(seconds: 20));
      expect(r.rules.status('r1').state, RuleState.blocked);
      expect(r.rules.status('r1').message, '"Liga extrusora" não aceita escrita por regra');
      expect(r.rules.proposals, isEmpty);
      expect(r.memory.bit(ModbusArea.coil, 1), isTrue);
      final a = r.alarms.entries.singleWhere((e) => e.key == RuleEngine.alarmKey('r1'));
      expect(a.message, 'Regra "Parar a prensa" parada: "Liga extrusora" não aceita escrita por regra');

      r.controller.saveTag(semPermissao.copyWith(ruleWritable: true));
      fa.elapse(const Duration(seconds: 11));
      expect(r.rules.proposals, hasLength(1));
      expect(r.alarms.entries.singleWhere((e) => e.key == RuleEngine.alarmKey('r1')).phase, AlarmPhase.returnedUnack);

      // Tiraram a permissão com a pergunta na tela: ela sai na hora, e um
      // toque atrasado não grava.
      r.controller.saveTag(semPermissao);
      fa.flushMicrotasks();
      expect(r.rules.proposals, isEmpty);
      expect(r.rules.history.take(2).map((e) => e.type), [RuleEventType.stopped, RuleEventType.withdrawn]);
      r.rules.confirm('r1');
      fa.elapse(const Duration(milliseconds: 500));
      expect(r.memory.bit(ModbusArea.coil, 1), isTrue);
      r.dispose(fa);
    });
  });

  test('automático grava sozinho, só para parar; para dar partida, sempre pergunta', () {
    fakeAsync((fa) {
      final r = _Rig(fa, Project(devices: const [device], tags: const [temp, liga], rules: [rule(mode: RuleMode.automatic, hold: 3)]));
      r.memory.pokeBit(ModbusArea.coil, 0, true);
      r.memory.pokeRegister(ModbusArea.holdingRegister, 0, 90);
      fa.elapse(const Duration(seconds: 2));
      expect(r.memory.bit(ModbusArea.coil, 0), isTrue);
      fa.elapse(const Duration(seconds: 3));
      expect(r.memory.bit(ModbusArea.coil, 0), isFalse);
      expect(r.rules.proposals, isEmpty);
      expect(r.rules.history.first.text, 'Grava DESLIGADO em "Liga prensa" (Prensa) · automático');

      // Automático que LIGARIA: o motor pergunta mesmo assim (e o arquivo
      // corrige para "propor").
      r.memory.pokeBit(ModbusArea.coil, 0, false);
      r.memory.pokeRegister(ModbusArea.holdingRegister, 0, 50);
      final start = rule(mode: RuleMode.automatic, value: 1, hold: 3);
      expect(start.normalized().mode, RuleMode.propose);
      r.controller.replace(r.controller.project.copyWith(rules: [start]));
      fa.elapse(const Duration(seconds: 2));
      r.memory.pokeRegister(ModbusArea.holdingRegister, 0, 90);
      fa.elapse(const Duration(seconds: 5));
      expect(r.memory.bit(ModbusArea.coil, 0), isFalse, reason: 'nunca dá partida sozinha');
      expect(r.rules.proposals.single.action, 'Ligar');
      r.dispose(fa);
    });
  });

  test('a regra de exemplo da demonstração: desligada não faz nada; ligada, propõe 65 m/min com o motor acima de 80 °C', () {
    fakeAsync((fa) {
      // A cortadora da demonstração sobre a memória do teste, sem o processo
      // simulado: os valores são os que o teste põe.
      final demo = DemoProject.build();
      const cortadora = Device(id: DemoProject.deviceId, name: 'Cortadora de rótulos', host: 'x', pollMs: 200);
      final r = _Rig(fa, demo.copyWith(devices: [cortadora, ...demo.devices.where((d) => d.isCalc)]));
      final example = r.controller.project.rule(DemoProject.ruleId)!;
      expect((example.enabled, example.mode, example.holdSec), (false, RuleMode.propose, 10));

      final motor = ByteData(4)..setFloat32(0, 82); // "Temperatura do motor": FLOAT32 em HR 6–7
      r.memory.pokeRegisters(ModbusArea.holdingRegister, 6, [motor.getUint16(0), motor.getUint16(2)]);
      r.memory.pokeRegister(ModbusArea.holdingRegister, 1, 80); // "Velocidade desejada"
      fa.elapse(const Duration(seconds: 15));
      expect(r.rules.status(DemoProject.ruleId).state, RuleState.off);
      expect(r.rules.proposals, isEmpty, reason: 'desligada não vigia nada');

      r.controller.saveRule(example.copyWith(enabled: true));
      fa.elapse(const Duration(seconds: 12));
      final p = r.rules.proposals.single;
      expect((p.question, p.action), ('Diminuir a velocidade?', 'Gravar'));
      expect(p.detail, 'Grava 65 m/min em "Velocidade desejada" (Cortadora de rótulos)');
      expect(r.memory.register(ModbusArea.holdingRegister, 1), 80, reason: 'propor não grava nada');
      r.rules.confirm(DemoProject.ruleId);
      fa.elapse(const Duration(milliseconds: 500));
      expect(r.memory.register(ModbusArea.holdingRegister, 1), 65);
      r.dispose(fa);
    });
  });

  test('sem comunicação a regra não roda e vira alarme; segundo plano retira a pergunta, nada grava e avisa na volta', () {
    fakeAsync((fa) {
      final r = _Rig(fa, Project(devices: const [device], tags: const [temp, liga], rules: [rule()]));
      r.memory.pokeBit(ModbusArea.coil, 0, true);
      r.memory.pokeRegister(ModbusArea.holdingRegister, 0, 90);
      fa.elapse(const Duration(seconds: 12));
      expect(r.rules.proposals, hasLength(1));

      // App vai para segundo plano: a pergunta sai e nada é gravado depois.
      r.rules.pause();
      expect(r.rules.proposals, isEmpty);
      expect(r.rules.history.first.type, RuleEventType.stopped);
      fa.elapse(const Duration(minutes: 2));
      expect(r.rules.proposals, isEmpty);
      expect(r.memory.bit(ModbusArea.coil, 0), isTrue);
      r.rules.resume();
      final paused = r.alarms.entries.singleWhere((e) => e.key == RuleEngine.pausedKey);
      expect(paused.message, 'As regras ficaram paradas 2 min: app em segundo plano');
      expect(paused.phase, AlarmPhase.returnedUnack, reason: 'a causa já passou; fica até alguém ver');
      fa.elapse(const Duration(seconds: 11));
      expect(r.rules.proposals, hasLength(1), reason: 'na volta, conta o tempo de novo e pergunta');

      // Sem comunicação: a pergunta sai, a regra para e vira alarme.
      r.client.failureRate = 1;
      fa.elapse(const Duration(seconds: 4));
      expect(r.rules.proposals, isEmpty);
      expect(r.rules.status('r1').state, RuleState.blocked);
      expect(r.rules.status('r1').message, 'sem comunicação com Prensa');
      expect(r.alarms.entries.singleWhere((e) => e.key == RuleEngine.alarmKey('r1')).message, 'Regra "Parar a prensa" parada: sem comunicação com Prensa');

      r.client.failureRate = 0;
      fa.elapse(const Duration(seconds: 20));
      expect(r.rules.status('r1').state, isNot(RuleState.blocked));
      expect(r.rules.proposals, hasLength(1));
      expect(r.alarms.entries.singleWhere((e) => e.key == RuleEngine.alarmKey('r1')).phase, AlarmPhase.returnedUnack);
      r.dispose(fa);
    });
  });
}

/// Projeto guardado só na memória: `fake_async` não espera disco de verdade.
class _MemoryRepository extends ProjectRepository {
  Project? saved;

  @override
  Future<Project?> load() async => saved;

  @override
  Future<void> save(Project project) async => saved = project;
}

class _Rig {
  _Rig(FakeAsync fa, Project project) {
    memory = ModbusMemory(holdingRegisters: 10, coils: 10);
    client = SimulatedModbusClient(memory: memory, latency: Duration.zero);
    runtime = HmiRuntime(clientFactory: (_) => client);
    controller = ProjectController(repository: _MemoryRepository(), runtime: runtime);
    controller.replace(project);
    fa.flushMicrotasks();
    alarms = AlarmEngine(controller: controller, runtime: runtime);
    rules = RuleEngine(controller: controller, runtime: runtime, alarms: alarms);
    fa.elapse(const Duration(milliseconds: 500));
  }

  late final ModbusMemory memory;
  late final SimulatedModbusClient client;
  late final HmiRuntime runtime;
  late final ProjectController controller;
  late final AlarmEngine alarms;
  late final RuleEngine rules;

  void dispose(FakeAsync fa) {
    rules.dispose();
    alarms.dispose();
    controller.dispose();
    runtime.dispose();
    fa.elapse(const Duration(seconds: 2));
  }
}
