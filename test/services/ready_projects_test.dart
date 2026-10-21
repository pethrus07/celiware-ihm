import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/models/alarm.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/hmi_screen.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:ihm/services/templates/ready_projects.dart';
import 'package:ihm/widgets/hmi/element_catalog.dart';

import '../support/screen_checks.dart';

/// Projetos prontos (reunião de 19/10/2026): cada um monta sem erro, com o
/// equipamento sem IP, nenhuma variável com endereço inventado, as telas na
/// régua dos modelos e o arquivo indo e voltando. O desenho de cada tela
/// (320 dp ao tablet, claro e escuro) está em
/// `test/widgets/screen_templates_render_test.dart`.
void main() {
  test('biblioteca: os cinco pedidos, ids únicos, achados pelo id, uma linha cada', () {
    final ids = ReadyProjects.all.map((p) => p.id).toList();
    expect(ids, ['diretoria', 'supervisao', 'operador', 'monitoramento', 'tex-g4']);
    for (final p in ReadyProjects.all) {
      expect(ReadyProjects.byId(p.id), same(p));
      expect(p.description, isNot(contains('\n')));
      expect(p.description.length, lessThanOrEqualTo(90), reason: '${p.title}: uma linha só');
    }
    expect(ReadyProjects.byId('nao-existe'), isNull);
  });

  for (final rp in ReadyProjects.all) {
    group(rp.title, () {
      late Project p;
      setUp(() => p = rp.build());

      test('monta sem erro: um equipamento Modbus TCP sem IP e as telas na grade fina', () {
        expect(p.name, rp.projectName);
        final d = p.devices.single;
        expect(d.kind, DeviceKind.modbusTcp);
        expect(d.host, isEmpty, reason: 'IP a configurar, nunca inventado');
        expect(d.port, 502);
        expect(d.addressLabel, 'IP a configurar');
        expect(p.screens.length, rp.screens.length);
        expect(p.screens.map((s) => s.name), rp.screens.map((s) => s.name));
        for (final s in p.screens) {
          expect(s.columns, HmiScreen.fineColumns);
          expect(s.elements, isNotEmpty);
        }
      });

      test('endereço desconhecido fica a configurar: nenhuma variável com endereço', () {
        expect(p.tags, isNotEmpty);
        for (final t in p.tags) {
          expect(t.addressPending, isTrue, reason: t.name);
          expect(t.address, 0, reason: '${t.name}: só o padrão — o runtime não lê');
          expect(t.memory, isNull);
          expect(t.deviceId, p.devices.single.id);
        }
        expect(p.tags.map((t) => t.id).toSet().length, p.tags.length, reason: 'id de variável repetido');
        final alarmIds = [for (final t in p.tags) ...t.alarms.map((a) => a.id)];
        expect(alarmIds.toSet().length, alarmIds.length, reason: 'id de alarme repetido');
      });

      test('cada tela na régua dos modelos; toda variável aparece em alguma tela', () {
        final tags = {for (final t in p.tags) t.id: t};
        for (final s in p.screens) {
          final problems = templateScreenProblems(s, tags);
          expect(problems, isEmpty, reason: '${s.name}:\n${problems.join('\n')}');
        }
        final used = {for (final s in p.screens) ...s.tagIds};
        for (final t in p.tags) {
          expect(used, contains(t.id), reason: '"${t.name}" sem elemento');
        }
      });

      test('vai e volta pelo arquivo do projeto', () {
        final back = (ProjectRepository.decodeFile(ProjectRepository.encode(p)) as ProjectFile).project;
        expect(back.name, p.name);
        expect(back.devices.single.host, isEmpty);
        expect(back.tags.length, p.tags.length);
        expect(back.tags.every((t) => t.addressPending), isTrue);
        expect([for (final s in back.screens) s.elements.length], [for (final s in p.screens) s.elements.length]);
        expect([for (final s in back.screens) s.readOnly], [for (final s in p.screens) s.readOnly]);
      });

      test('montar duas vezes dá ids novos (somar duas vezes à planta não colide)', () {
        final again = rp.build();
        expect(again.devices.single.id, isNot(p.devices.single.id));
        expect(again.tags.map((t) => t.id).toSet().intersection(p.tags.map((t) => t.id).toSet()), isEmpty);
        expect(again.screens.map((s) => s.id).toSet().intersection(p.screens.map((s) => s.id).toSet()), isEmpty);
      });
    });
  }

  bool writes(HmiScreen s) => s.elements.any((e) => ElementCatalog.of(e.type).writes);

  test('Diretoria: só acompanhamento — estado, produção, alarme e OEE, sem comando', () {
    final p = ReadyProjects.byId('diretoria')!.build();
    final s = p.screens.single;
    expect(s.readOnly, isTrue);
    expect(writes(s), isFalse);
    expect(s.elements.map((e) => e.type), containsAll([ElementType.multistate, ElementType.value, ElementType.lamp, ElementType.oee]));
  });

  test('Supervisão: estado, modo e produção com tendência, sem comando', () {
    final p = ReadyProjects.byId('supervisao')!.build();
    final s = p.screens.single;
    expect(s.readOnly, isTrue);
    expect(writes(s), isFalse);
    final trend = s.elements.singleWhere((e) => e.type == ElementType.trend);
    expect(trend.tagIds.map((id) => p.tag(id)!.name), ['Produção']);
    expect(s.elements.map((e) => e.props['label']), containsAll(['Estado', 'Modo', 'Alarme']));
  });

  test('Operador: o modelo Máquina — liga com retorno, reset, ajuste, alarme', () {
    final p = ReadyProjects.byId('operador')!.build();
    final s = p.screens.single;
    expect(s.readOnly, isFalse);
    final liga = s.elements.singleWhere((e) => e.props['label'] == 'Liga');
    expect(p.tag(liga.props['feedbackTagId'] as String)!.name, 'Máquina em operação');
    expect(s.elements.map((e) => e.props['label']), containsAll(['Reset', 'Ajuste', 'Alarme']));
  });

  test('Monitoramento rápido: tabela com muitas memórias e a tendência', () {
    final p = ReadyProjects.byId('monitoramento')!.build();
    final s = p.screens.single;
    final table = s.elements.singleWhere((e) => e.type == ElementType.table);
    expect(table.tagIds.length, greaterThanOrEqualTo(10));
    final trend = s.elements.singleWhere((e) => e.type == ElementType.trend);
    expect(trend.tagIds.every(table.tagIds.contains), isTrue);
  });

  group('Tex G4', () {
    late Project p;
    setUp(() => p = ReadyProjects.byId('tex-g4')!.build());
    Tag tag(String name) => p.tags.singleWhere((t) => t.name == name);

    test('os nomes reais do Padrão TEX, com a descrição do material', () {
      final names = p.tags.map((t) => t.name).toSet();
      expect(names, containsAll(['Connected', 'ReadyToTest', 'Busy', 'ActualBCD', 'ResultOK', 'ResultNOK', 'Rework', 'Pressure', 'Leak', 'ChamberNum', 'TestNum', 'Start', 'Stop', 'BlockExhaust', 'BCD']));
      expect(tag('ReadyToTest').description, 'O equipamento está pronto para iniciar um teste.');
      expect(tag('BCD').description, contains('Para testar a peça 3, coloque 3.'));
      for (final t in p.tags) {
        expect(t.description, isNotEmpty, reason: t.name);
      }
      // Comandos gravam; o resto só lê.
      expect([for (final t in p.tags) if (t.writable) t.name], unorderedEquals(['Start', 'Stop', 'BlockExhaust', 'BCD']));
    });

    test('duas telas: Operação (comandos, resultado, pressão, vazamento, BCD) e Entradas e saídas', () {
      expect(p.screens.map((s) => s.name), ['Operação', 'Entradas e saídas']);
      final op = p.screens.first;
      final labels = op.elements.map((e) => e.props['label']).toList();
      expect(labels, containsAll(['Iniciar', 'Parar', 'Bloquear escape', 'Peça (BCD)', 'OK', 'NOK', 'Retrabalho', 'Pressão', 'Vazamento', 'BCD atual', 'Câmara', 'Teste']));
      final io = p.screens.last;
      expect(writes(io), isFalse, reason: 'diagnóstico só lê');
      expect(io.elements.where((e) => e.type == ElementType.lamp).length, 16);
      expect(io.elements.singleWhere((e) => e.type == ElementType.table).tagIds.map((id) => p.tag(id)!.name),
          containsAll(['State', 'Status', 'TimeElapsed', 'AutoCheck', 'Diagnostic']));
    });

    test('alarme quando ResultNOK (prioridade média)', () {
      final nok = tag('ResultNOK');
      expect(nok.alarms.single.kind, AlarmKind.on);
      expect(nok.alarms.single.priority, AlarmPriority.medium);
      expect(p.tags.where((t) => t.alarms.isNotEmpty).map((t) => t.name), ['ResultNOK']);
    });

    test('a descrição manda conferir os endereços no manual Modbus do Tex G4; nada da marca', () {
      final rp = ReadyProjects.byId('tex-g4')!;
      expect(rp.description, contains('manual Modbus do Tex G4'));
      expect(rp.hint, contains('manual Modbus do Tex G4'));
      for (final s in p.screens) {
        expect(s.elements.where((e) => e.type == ElementType.image), isEmpty, reason: 'sem logo');
        for (final e in s.elements) {
          final color = e.props['color'];
          if (color != null) expect(['green', 'red', 'amber', 'blue', 'neutral'], contains(color));
        }
      }
    });
  });
}
