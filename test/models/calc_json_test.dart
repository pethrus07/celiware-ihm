import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/models/calc.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/logic_rule.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/storage/project_repository.dart';

/// Calculadas, "aceita escrita por regra" e regras no arquivo do projeto:
/// campos novos e opcionais, no arquivo só quando existem — projeto antigo
/// abre e grava igual, `schemaVersion` continua 1 (ARQUITETURA §10.4).
void main() {
  group('Tag.calc', () {
    test('ida e volta: conta canônica, nomes, tipo, unidade', () {
      const t = Tag(
        id: 'c',
        name: 'Rótulos por minuto',
        deviceId: CalcDevice.id,
        dataType: TagDataType.float32,
        unit: 'un/min',
        decimals: 1,
        calc: CalcSpec(expression: '{demo_sp} * 1000 / {demo_comp}', names: {'demo_sp': 'Velocidade desejada', 'demo_comp': 'Comprimento'}),
      );
      final back = Tag.fromJson(jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>);
      expect(back.calc, t.calc);
      expect(back.calc!.inputIds, {'demo_sp', 'demo_comp'});
      expect((back.dataType, back.unit, back.decimals, back.deviceId), (TagDataType.float32, 'un/min', 1, CalcDevice.id));
      expect(back.toJson(), t.normalized().toJson());
    });

    test('calculada é só leitura, sem escala, um valor só', () {
      const t = Tag(id: 'c', name: 'x', deviceId: CalcDevice.id, dataType: TagDataType.uint16, writable: true, scale: 0.1, length: 4,
          calc: CalcSpec(expression: '1 + 1'));
      final n = t.normalized();
      expect((n.writable, n.canWrite, n.scale, n.length, n.dataType), (false, false, 1.0, 1, TagDataType.float32));
      expect(n.addressLabel, 'Calculada');
      expect(const Tag(id: 'b', name: 'b', deviceId: CalcDevice.id, dataType: TagDataType.bool, calc: CalcSpec(expression: '1 > 0')).normalized().dataType,
          TagDataType.bool);
    });

    test('"aceita escrita por regra" só vai para o arquivo quando marcada, e só vale em variável gravável', () {
      const t = Tag(id: 't', name: 'Liga', deviceId: 'd', writable: true, ruleWritable: true);
      expect(t.toJson()['ruleWritable'], isTrue);
      expect(Tag.fromJson(t.toJson()).acceptsRuleWrite, isTrue);
      expect(const Tag(id: 't', name: 'Liga', deviceId: 'd', writable: true).toJson().containsKey('ruleWritable'), isFalse);
      expect(const Tag(id: 't', name: 'x', deviceId: 'd', ruleWritable: true).acceptsRuleWrite, isFalse, reason: 'sem "pode ser alterada"');
      expect(t.copyWith(name: 'y').ruleWritable, isTrue);
      expect(t.withMemory('D1').ruleWritable, isTrue);
    });

    test('o equipamento das calculadas: tipo novo no arquivo, fora de "equipment"', () {
      final j = CalcDevice.device.toJson();
      expect(j['kind'], 'calc');
      expect(Device.fromJson(j).isCalc, isTrue);
      final p = Project(devices: [const Device(id: 'd', name: 'CLP', host: 'x'), CalcDevice.device]);
      expect(p.equipment.map((d) => d.id), ['d']);
    });
  });

  group('LogicRule', () {
    test('ida e volta; padrão (propor, ligada, sem espera) não vai para o arquivo', () {
      const r = LogicRule(
        id: 'r',
        name: 'Parar a prensa',
        condition: CalcSpec(expression: '{temp} > 85', names: {'temp': 'Temperatura'}),
        holdSec: 10,
        targetTagId: 'liga_prensa',
        value: 0,
        mode: RuleMode.automatic,
      );
      final back = LogicRule.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>);
      expect((back.name, back.condition, back.holdSec, back.targetTagId, back.value, back.mode, back.enabled),
          (r.name, r.condition, 10, 'liga_prensa', 0.0, RuleMode.automatic, true));
      final plain = const LogicRule(id: 'r', name: 'x').toJson();
      expect(plain.containsKey('mode') || plain.containsKey('enabled') || plain.containsKey('holdSec'), isFalse);
    });

    test('automático que daria partida volta a propor; modo desconhecido é propor; tempo fora da faixa corrigido', () {
      expect(const LogicRule(id: 'r', name: 'x', value: 1, mode: RuleMode.automatic).normalized().mode, RuleMode.propose);
      expect(LogicRule.fromJson({'id': 'r', 'name': 'x', 'mode': 'turbo'}).mode, RuleMode.propose);
      expect(LogicRule.fromJson({'id': 'r', 'name': 'x', 'holdSec': 99999}).holdSec, LogicRule.maxHoldSec);
    });
  });

  test('projeto antigo (sem calculada nem regra) abre e grava igual, schemaVersion 1', () {
    // A demonstração de hoje traz uma calculada e uma regra de exemplo: sem
    // elas, é o projeto de antes da etapa 4.
    final demo = DemoProject.build();
    final before = demo.copyWith(
      devices: demo.equipment,
      tags: [for (final t in demo.tags) if (!t.isCalc) t.copyWith(ruleWritable: false)],
      rules: const [],
    );
    final old = jsonDecode(utf8.decode(ProjectRepository.encode(before))) as Map<String, dynamic>;
    expect(old.containsKey('rules'), isFalse);
    expect(jsonEncode(old).contains('"calc"'), isFalse);
    expect(jsonEncode(old).contains('ruleWritable'), isFalse);
    final again = jsonDecode(utf8.decode(ProjectRepository.encode(ProjectRepository.decode(utf8.encode(jsonEncode(old)))))) as Map<String, dynamic>;
    expect(again, old);
    expect(again['schemaVersion'], 1);
  });

  test('projeto com calculada e regra passa pelo arquivo', () {
    final demo = DemoProject.build();
    final p = demo.copyWith(
      devices: [...demo.equipment, CalcDevice.device],
      tags: [
        ...demo.tags,
        const Tag(id: 'c', name: 'Dobro', deviceId: CalcDevice.id, dataType: TagDataType.float32, calc: CalcSpec(expression: '{demo_vel} * 2')),
      ],
      rules: const [LogicRule(id: 'r', name: 'Parar', condition: CalcSpec(expression: '{c} > 100'), targetTagId: 'demo_liga')],
    );
    final back = ProjectRepository.decode(ProjectRepository.encode(p));
    expect(back.tag('c')!.calc!.expression, '{demo_vel} * 2');
    expect(back.rule('r')!.condition.expression, '{c} > 100');
    expect(back.device(CalcDevice.id)!.isCalc, isTrue);
    expect(ProjectRepository.encode(back), ProjectRepository.encode(p));
  });
}
