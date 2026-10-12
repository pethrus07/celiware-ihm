import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/calc.dart';
import 'package:ihm/models/hmi_screen.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/screens/tags/calc_tag_form_page.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:ihm/widgets/common/common.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cadastro de variável calculada pela interface (LG-1 a LG-3), com a máquina
/// de demonstração e o relógio simulado (mesmo arranjo de tag_form_test).
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      for (final (id, _, _) in Tours.catalog) 'tour:v1:$id': true,
    });
    dir = await Directory.systemTemp.createTemp('ihm_calc_form');
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

  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
    await live(tester, 600);
  }

  String exprText(WidgetTester tester) => tester.widget<TextField>(find.byKey(const ValueKey('campo-conta'))).controller!.text;
  String result(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('resultado-conta'))).data!;

  /// Cita uma variável pela folha (com busca), sem digitar o nome.
  Future<void> cite(WidgetTester tester, String search, String tagId) async {
    await tester.tap(find.byKey(const ValueKey('inserir-variavel')));
    await live(tester, 500);
    await tester.enterText(find.byKey(const ValueKey('buscar-variavel-conta')), search);
    await live(tester, 200);
    await tester.tap(find.byKey(ValueKey('citar-$tagId')));
    await live(tester, 500);
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const ValueKey('campo-conta')), text);
    await live(tester, 300);
  }

  testWidgets('calculada nova: cita por toque, resultado ao vivo, erro com o trecho; salva e aparece na lista com o valor', (tester) async {
    final c = await boot(tester);
    await openTab(tester, 'Variáveis');
    await tester.tap(find.byKey(const ValueKey('nova-calculada')));
    await live(tester, 700);
    expect(find.text('Nova variável calculada'), findsOneWidget);
    expect(result(tester), 'Escreva a conta');

    await tester.enterText(find.byKey(const ValueKey('campo-nome-calculada')), 'Rótulos por minuto');
    await cite(tester, 'desejada', 'demo_sp');
    expect(exprText(tester), '[Velocidade desejada]');
    await type(tester, '${exprText(tester)} * 1000 / ');
    await cite(tester, 'comprimento', 'demo_comp');
    expect(exprText(tester), '[Velocidade desejada] * 1000 / [Comprimento do rótulo]');
    await live(tester, 1500);
    expect(result(tester), '666,7', reason: '80 m/min × 1000 ÷ 120 mm, com 1 casa');
    expect(find.byKey(const ValueKey('erro-conta')), findsNothing);

    // Erro aparece na hora, com o trecho marcado, e o painel para de mostrar número.
    await type(tester, '[Velocidade desejada] * (1000 / [Comprimento do rótulo]');
    expect(find.descendant(of: find.byKey(const ValueKey('erro-conta')), matching: find.text('Falta fechar o parêntese')), findsOneWidget);
    expect(result(tester), 'Corrija a conta');
    await type(tester, 'Temp * 2');
    expect(find.descendant(of: find.byKey(const ValueKey('erro-conta')), matching: find.text('Não existe variável "Temp"')), findsOneWidget);

    // Função por toque: entra com o cursor dentro do parêntese.
    await type(tester, '');
    await tester.tap(find.byKey(const ValueKey('inserir-funcao')));
    await live(tester, 500);
    await tester.tap(find.byKey(const ValueKey('funcao-arred')));
    await live(tester, 500);
    expect(exprText(tester), 'arred()');
    expect(tester.widget<TextField>(find.byKey(const ValueKey('campo-conta'))).controller!.selection.baseOffset, 6);

    await type(tester, '[Velocidade desejada] * 1000 / [Comprimento do rótulo]');
    await tester.tap(find.byKey(const ValueKey('salvar-calculada')));
    await live(tester, 900);

    // A demonstração já traz uma "Rótulos por minuto" (com a velocidade de
    // verdade): a salva agora é a última.
    final saved = c.project.tags.lastWhere((t) => t.name == 'Rótulos por minuto');
    expect(saved.calc!.expression, '{demo_sp} * 1000 / {demo_comp}');
    expect(saved.calc!.names, {'demo_sp': 'Velocidade desejada', 'demo_comp': 'Comprimento do rótulo'});
    expect((saved.deviceId, saved.dataType, saved.canWrite), (CalcDevice.id, TagDataType.float32, false));
    expect(c.project.device(CalcDevice.id)!.isCalc, isTrue, reason: 'o equipamento virtual nasce com a primeira calculada');

    // Na lista: grupo "Cálculos", a conta com os nomes e o valor ao vivo.
    await tester.scrollUntilVisible(find.byKey(ValueKey('var-${saved.id}')), 300, scrollable: find.byType(Scrollable).last);
    await live(tester, 1500);
    expect(find.byKey(const ValueKey('secao-${CalcDevice.id}')), findsOneWidget);
    expect(find.text('= [Velocidade desejada] * 1000 / [Comprimento do rótulo]'), findsOneWidget);
    expect(find.descendant(of: find.byKey(ValueKey('var-${saved.id}')), matching: find.text('666,7')), findsOneWidget);

    // Equipamentos continua só com a cortadora.
    await openTab(tester, 'Equipamentos');
    expect(find.byKey(const ValueKey('equip-${CalcDevice.id}')), findsNothing);
    await shutdown(tester, c);
  });

  testWidgets('editar mostra a conta com o nome de agora; círculo é recusado; resultado liga/desliga', (tester) async {
    final c = await boot(tester);
    c.saveDevice(CalcDevice.device);
    const a = Tag(id: 'calc_a', name: 'Ajuste mais um', deviceId: CalcDevice.id, dataType: TagDataType.float32, calc: CalcSpec(expression: '{demo_sp} + 1'));
    const b = Tag(id: 'calc_b', name: 'Dobro', deviceId: CalcDevice.id, dataType: TagDataType.float32, calc: CalcSpec(expression: '{calc_a} * 2'));
    c.saveTag(a);
    c.saveTag(b);
    c.saveTag(c.project.tag('demo_sp')!.copyWith(name: 'Ajuste de velocidade'));
    await live(tester, 300);

    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(nav.push(MaterialPageRoute<Tag>(builder: (_) => CalcTagFormPage(tag: c.project.tag('calc_a')))));
    await live(tester, 900);
    expect(exprText(tester), '[Ajuste de velocidade] + 1', reason: 'renomear a entrada não quebra a conta');
    expect(result(tester), '81', reason: 'casas decimais da variável (0)');

    await type(tester, '[Dobro] + 1');
    expect(find.descendant(of: find.byKey(const ValueKey('erro-conta')), matching: find.text('A conta fica em círculo: Ajuste mais um → Dobro → Ajuste mais um')),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('salvar-calculada')));
    await live(tester, 600);
    expect(c.project.tag('calc_a')!.calc!.expression, '{demo_sp} + 1', reason: 'não salvou');
    expect(find.byType(CalcTagFormPage), findsOneWidget);

    // Comparação dá liga/desliga: sem unidade nem casas em Mais opções.
    await type(tester, '[Temperatura do motor] > 20');
    await live(tester, 1200);
    expect(result(tester), 'LIGADO');
    expect(find.text('liga/desliga'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('salvar-calculada')));
    await live(tester, 600);
    expect(c.project.tag('calc_a')!.dataType, TagDataType.bool);
    expect(c.project.tag('calc_a')!.calc!.expression, '{demo_temp} > 20');
    await shutdown(tester, c);
  });

  testWidgets('calculada num elemento de tela mostra o valor ao vivo; voltar com alteração pergunta', (tester) async {
    final c = await boot(tester);
    c.saveDevice(CalcDevice.device);
    c.saveTag(const Tag(id: 'calc_f', name: 'Motor em °F', deviceId: CalcDevice.id, dataType: TagDataType.float32, decimals: 0, unit: '°F',
        calc: CalcSpec(expression: '{demo_temp} * 1,8 + 32')));
    final leader = c.project.screen(DemoProject.leaderScreenId)!;
    c.saveScreen(leader.copyWith(elements: [
      ...leader.elements,
      const HmiElement(id: 'el_f', type: ElementType.value, x: 0, y: 7, w: 6, h: 1, props: {'tagId': 'calc_f', 'label': 'Motor'}),
    ]));
    await live(tester, 300);
    await tester.tap(find.byKey(const ValueKey('tela-${DemoProject.leaderScreenId}')));
    await live(tester, 1500);
    // ~32 °C da demonstração (89,6 °F); a unidade só aparece com número de
    // verdade. A temperatura simulada tem ruído: 89 ou 90.
    expect(find.text('°F'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^(89|90)$')), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is LinkChip && w.device.isCalc), findsNothing, reason: 'o selo é o da cortadora, não o de "Cálculos"');

    // Cadastro com alteração pendente: voltar pergunta.
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(nav.push(MaterialPageRoute<Tag>(builder: (_) => CalcTagFormPage(tag: c.project.tag('calc_f')))));
    await live(tester, 900);
    await type(tester, '[Temperatura do motor] * 2');
    await tester.pageBack();
    await live(tester, 400);
    expect(find.byKey(const ValueKey('descartar-alteracoes')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('descartar')));
    await live(tester, 600);
    expect(c.project.tag('calc_f')!.calc!.expression, '{demo_temp} * 1,8 + 32');
    await shutdown(tester, c);
  });
}

Future<void> live(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
