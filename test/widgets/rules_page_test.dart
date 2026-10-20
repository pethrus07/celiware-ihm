import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/logic_rule.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/screens/rules/rule_editor_page.dart';
import 'package:ihm/screens/tags/tag_form_page.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mais → Regras pela interface (LG-4 a LG-7), com a máquina de demonstração
/// e o relógio simulado.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      // Todas as versões já vistas (a trilha de início está na v2).
      for (final (id, _, _) in Tours.catalog) for (final v in [1, 2]) 'tour:v$v:$id': true,
    });
    dir = await Directory.systemTemp.createTemp('ihm_rules');
  });

  tearDown(() async {
    DemoRegistry.discard(DemoProject.deviceId);
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {/* Windows ainda segurando o arquivo */}
  });

  Future<ProjectController> boot(WidgetTester tester) async {
    final runtime = HmiRuntime();
    final controller = ProjectController(repository: ProjectRepository(directory: dir), runtime: runtime);
    await tester.runAsync(controller.load);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CeliwareIhmApp(controller: controller, runtime: runtime));
    await live(tester, 600);
    return controller;
  }

  Future<void> shutdown(WidgetTester tester, ProjectController c) async {
    await tester.pumpWidget(const SizedBox());
    final done = c.runtime.dispose();
    await live(tester, 1200);
    await done;
    c.dispose();
  }

  Future<void> openRules(WidgetTester tester) async {
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Ferramentas')));
    await live(tester, 400);
    await tester.ensureVisible(find.byKey(const ValueKey('regras')));
    await live(tester, 200);
    await tester.tap(find.byKey(const ValueKey('regras')));
    await live(tester, 600);
  }

  Future<void> tapKey(WidgetTester tester, String key, {int wait = 400}) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await live(tester, 100);
    await tester.tap(find.byKey(ValueKey(key)));
    await live(tester, wait);
  }

  testWidgets('regra pela interface: pede permissão no destino, pergunta em qualquer tela e só grava com o toque', (tester) async {
    final c = await boot(tester);
    await openRules(tester);
    expect(find.byKey(const ValueKey('aviso-seguranca-regras')), findsOneWidget, reason: 'o aviso de segurança fica sempre à vista');
    await tapKey(tester, 'nova-regra', wait: 700);

    await tester.enterText(find.byKey(const ValueKey('campo-nome-regra')), 'Parar a cortadora');
    await tester.enterText(find.byKey(const ValueKey('campo-conta')), '[Temperatura do motor] > 20');
    await live(tester, 1500);
    expect(find.text('Agora: a condição está presente'), findsOneWidget);
    await tapKey(tester, 'durar-5');

    // Destino ainda sem "aceita escrita por regra": tocar pergunta antes de marcar.
    await tapKey(tester, 'destino-regra', wait: 600);
    await tester.tap(find.byKey(const ValueKey('destino-demo_liga')));
    await live(tester, 500);
    expect(find.byKey(const ValueKey('permitir-regra-dialogo')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('permitir-regra')));
    await live(tester, 500);
    expect(c.project.tag('demo_liga')!.ruleWritable, isTrue);
    expect(find.text('Liga máquina'), findsOneWidget);

    // Gravar sozinha pede o termo; com "Ligar" nem deixa.
    await tapKey(tester, 'opcao-1');
    await tapKey(tester, 'opcao-RuleMode.automatic');
    expect(find.byKey(const ValueKey('termo-automatico')), findsNothing);
    expect(find.text('Gravar sozinha só serve para parar: escolha Desligar ou o valor zero.'), findsOneWidget);
    await tapKey(tester, 'opcao-0');
    await tapKey(tester, 'opcao-RuleMode.automatic');
    expect(find.byKey(const ValueKey('termo-automatico')), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await live(tester, 400);

    await tapKey(tester, 'salvar-regra', wait: 700);
    // A demonstração já traz uma regra de exemplo, desligada.
    final rule = c.project.rules.singleWhere((r) => r.id != DemoProject.ruleId);
    expect((rule.name, rule.condition.expression, rule.holdSec, rule.targetTagId, rule.value, rule.mode),
        ('Parar a cortadora', '{demo_temp} > 20', 5, 'demo_liga', 0.0, RuleMode.propose));
    expect(find.byKey(ValueKey('regra-${rule.id}')), findsOneWidget);

    // Vai para outra tela; a máquina liga; a pergunta aparece lá, depois de 5 s.
    await tester.tap(find.byTooltip('Voltar'));
    await live(tester, 400);
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Projetos')));
    await live(tester, 400);
    final memory = DemoRegistry.forDevice(DemoProject.deviceId).memory;
    memory.pokeBit(ModbusArea.coil, DemoMap.coilRun, true);
    await live(tester, 2000);
    expect(find.byKey(const ValueKey('proposta-regra')), findsNothing, reason: 'ainda não durou 5 s');
    await live(tester, 5000);
    expect(find.byKey(const ValueKey('proposta-regra')), findsOneWidget);
    expect(find.text('Parar a cortadora?'), findsOneWidget);
    expect(find.text('Grava DESLIGADO em "Liga máquina" (Cortadora de rótulos)'), findsOneWidget);
    expect(memory.bit(ModbusArea.coil, DemoMap.coilRun), isTrue, reason: 'nada gravado sem o toque');

    // A pergunta mora na faixa do topo; tocar abre a decisão.
    await tester.tap(find.byKey(const ValueKey('proposta-regra')));
    await live(tester, 400);
    await tester.tap(find.byKey(const ValueKey('proposta-confirmar')));
    await live(tester, 800);
    expect(memory.bit(ModbusArea.coil, DemoMap.coilRun), isFalse);
    expect(find.byKey(const ValueKey('proposta-regra')), findsNothing);

    // Histórico: disparou, perguntou, gravou.
    await openRules(tester);
    await tapKey(tester, 'historico-regras', wait: 600);
    expect(find.text('Gravou · Parar a cortadora'), findsOneWidget);
    expect(find.text('Perguntou · Parar a cortadora'), findsOneWidget);
    await shutdown(tester, c);
  });

  testWidgets('regra que não pode rodar aparece parada na lista; desligar pela chave', (tester) async {
    final c = await boot(tester);
    c.saveRule(const LogicRule(id: 'r', name: 'Parar', targetTagId: 'demo_liga'));
    await live(tester, 300);
    await openRules(tester);
    await live(tester, 1200);
    expect(find.text('Parada: "Liga máquina" não aceita escrita por regra'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ligar-regra-r')));
    await live(tester, 1200);
    expect(c.project.rule('r')!.enabled, isFalse);
    // Só o estado desta regra: a de exemplo da demonstração também está desligada.
    expect(tester.widget<Text>(find.byKey(const ValueKey('estado-regra-r'))).data, 'Desligada');

    // Abrir e sair sem mexer não pergunta nada.
    await tester.tap(find.byKey(const ValueKey('regra-r')));
    await live(tester, 700);
    expect(find.byType(RuleEditorPage), findsOneWidget);
    await tester.tap(find.byTooltip('Voltar'));
    await live(tester, 1200);
    expect(find.byKey(const ValueKey('descartar-alteracoes')), findsNothing);
    expect(find.byType(RuleEditorPage), findsNothing);
    await shutdown(tester, c);
  });

  testWidgets('LG-5 no cadastro de variável: "Aceita escrita por regra" em Mais opções, e salvar outra coisa não apaga a marca', (tester) async {
    final c = await boot(tester);
    Future<void> openForm() async {
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      nav.push(MaterialPageRoute<Tag>(builder: (_) => TagFormPage(tag: c.project.tag('demo_liga'))));
      await live(tester, 900);
    }

    final scroll = find.descendant(of: find.byKey(const ValueKey('formulario-variavel')), matching: find.byType(Scrollable)).first;
    await openForm();
    await tester.scrollUntilVisible(find.text('Mais opções'), 200, scrollable: scroll);
    await tester.tap(find.text('Mais opções'));
    await live(tester, 800);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('aceita-regra')), 200, scrollable: scroll);
    await tester.tap(find.byKey(const ValueKey('aceita-regra')));
    await live(tester, 300);
    await tester.tap(find.byKey(const ValueKey('salvar-variavel')));
    await live(tester, 1200);
    expect(c.project.tag('demo_liga')!.acceptsRuleWrite, isTrue);

    await openForm();
    await tester.enterText(find.byKey(const ValueKey('campo-nome-variavel')), 'Liga a cortadora');
    await live(tester, 200);
    await tester.tap(find.byKey(const ValueKey('salvar-variavel')));
    await live(tester, 1200);
    expect(c.project.tag('demo_liga')!.name, 'Liga a cortadora');
    expect(c.project.tag('demo_liga')!.ruleWritable, isTrue, reason: 'o formulário guarda a marca que não mostrou');
    await shutdown(tester, c);
  });
}

Future<void> live(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
