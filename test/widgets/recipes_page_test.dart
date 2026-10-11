import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/recipe.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Receitas pela interface, com a máquina de demonstração: criar lendo da
/// máquina, comparar mostrando só a diferença, aplicar com uma confirmação e
/// ver no histórico; condição que impede; tipo novo com faixa, tolerância e
/// condição; atualizar pela máquina e restaurar uma versão.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  late Directory dir;
  const hr = ModbusArea.holdingRegister;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      for (final (id, _, _) in Tours.catalog) 'tour:v1:$id': true,
    });
    dir = await Directory.systemTemp.createTemp('ihm_receitas_ui');
  });

  tearDown(() async {
    DemoRegistry.discard(DemoProject.deviceId);
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {/* Windows ainda segurando o arquivo — é só a pasta temporária */}
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

  Future<void> openRecipes(WidgetTester tester) async {
    await tester.tap(find.text('Mais'));
    await live(tester, 400);
    await tester.ensureVisible(find.byKey(const ValueKey('receitas')));
    await live(tester, 200);
    await tester.tap(find.byKey(const ValueKey('receitas')));
    await live(tester, 600);
  }

  ModbusMemory memory() => DemoRegistry.forDevice(DemoProject.deviceId).memory;

  testWidgets('Mais → Receitas: criar lendo da máquina, comparar só a diferença, aplicar com uma confirmação e ver no histórico', (tester) async {
    final c = await boot(tester);
    await openRecipes(tester);
    expect(find.text('Rótulo 120 mm'), findsOneWidget);
    expect(find.text('Rótulo 60 mm'), findsOneWidget);

    // Criar: nome + "Ler da máquina" (a máquina abre com 80 m/min e 120 mm).
    await tester.tap(find.byKey(const ValueKey('nova-receita')));
    await live(tester, 400);
    await tester.enterText(find.byKey(const ValueKey('nome-receita')), 'Produto teste');
    await tester.tap(find.byKey(const ValueKey('receita-ler')));
    await live(tester, 1500);
    final created = c.project.recipes.firstWhere((r) => r.name == 'Produto teste');
    expect(created.values, {'vel': 80.0, 'comp': 120.0});
    expect(created.version, 1, reason: 'receita nova só se preenche, sem versão nova');
    expect(find.text('80 m/min'), findsOneWidget);
    expect(find.text('120 mm'), findsOneWidget);

    // Alguém mexeu na máquina: a velocidade foi para 100.
    memory().pokeRegister(hr, DemoMap.hrSpeedSetpoint, 100);

    // Comparar: só a diferença à vista.
    await tester.tap(find.byKey(const ValueKey('comparar')));
    await live(tester, 1000);
    expect(find.text('1 DIFERENÇA'), findsOneWidget);
    expect(find.byKey(const ValueKey('diferenca-vel')), findsOneWidget);
    expect(find.byKey(const ValueKey('diferenca-comp')), findsNothing);
    expect(find.text('O outro está igual.'), findsOneWidget);

    // Aplicar a partir da comparação: UMA confirmação, com o "de → para".
    await tester.tap(find.byKey(const ValueKey('comparar-aplicar')));
    await live(tester, 1500);
    expect(find.text('VAI GRAVAR 1 VALOR'), findsOneWidget);
    final fromTo = find.byKey(const ValueKey('de-para-vel'));
    expect(find.descendant(of: fromTo, matching: find.text('100 m/min')), findsOneWidget);
    expect(find.descendant(of: fromTo, matching: find.text('80 m/min')), findsOneWidget);
    expect(find.text('Conferido: "Em ciclo (bit da palavra)" DESLIGADO'), findsOneWidget);
    expect(memory().register(hr, DemoMap.hrSpeedSetpoint), 100, reason: 'nada grava antes de confirmar');
    await tester.enterText(find.byKey(const ValueKey('quem-aplica')), 'Pedro');
    await tester.tap(find.byKey(const ValueKey('confirmar-aplicar')));
    await live(tester, 2000);
    expect(find.text('Receita aplicada'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('resultado-vel')), matching: find.text('Gravado e conferido')), findsOneWidget);
    expect(memory().register(hr, DemoMap.hrSpeedSetpoint), 80);
    await tester.tap(find.byKey(const ValueKey('fechar-relatorio')));
    await live(tester, 600);

    // Histórico de aplicações, no aparelho: quem, qual receita, como terminou.
    await tester.pageBack();
    await live(tester, 600);
    await tester.tap(find.byKey(const ValueKey('historico-receitas')));
    await live(tester, 2500);
    expect(find.text('Produto teste · versão 1'), findsOneWidget);
    expect(find.textContaining('Pedro'), findsOneWidget);
    expect(find.textContaining('Receita aplicada'), findsOneWidget);

    // Na próxima, o nome já vem escrito; e Cancelar não grava nada.
    await tester.pageBack();
    await live(tester, 600);
    final created2 = c.project.recipes.firstWhere((r) => r.name == 'Produto teste');
    memory().pokeRegister(hr, DemoMap.hrLabelLength, 200);
    await tester.tap(find.byKey(ValueKey('receita-${created2.id}')));
    await live(tester, 600);
    await tester.tap(find.byKey(const ValueKey('aplicar')));
    await live(tester, 3000);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('quem-aplica'))).controller!.text, 'Pedro');
    await tester.tap(find.byKey(const ValueKey('cancelar-aplicar')));
    await live(tester, 600);
    expect(find.byKey(const ValueKey('confirmar-aplicar')), findsNothing);
    expect(memory().register(hr, DemoMap.hrLabelLength), 200);
    await shutdown(tester, c);
  });

  testWidgets('com a máquina em ciclo, a confirmação diz por quê e não oferece aplicar', (tester) async {
    final c = await boot(tester);
    memory().pokeBit(ModbusArea.coil, DemoMap.coilRun, true);
    await live(tester, 600);
    await openRecipes(tester);
    await tester.tap(find.byKey(const ValueKey('receita-demo_receita_60')));
    await live(tester, 600);
    await tester.tap(find.byKey(const ValueKey('aplicar')));
    await live(tester, 1500);
    expect(find.text('Só aplica com "Em ciclo (bit da palavra)" DESLIGADO. Agora está LIGADO.'), findsOneWidget);
    expect(find.byKey(const ValueKey('confirmar-aplicar')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('fechar-aplicar')));
    await live(tester, 600);
    expect(memory().register(hr, DemoMap.hrSpeedSetpoint), 80);
    await shutdown(tester, c);
  });

  testWidgets('tipo novo pela tela: variável, faixa e tolerância do parâmetro, condição da máquina', (tester) async {
    final c = await boot(tester);
    await openRecipes(tester);
    await tester.tap(find.byKey(const ValueKey('novo-tipo')));
    await live(tester, 600);
    await tester.enterText(find.byKey(const ValueKey('nome-tipo')), 'Corte');
    await tester.tap(find.byKey(const ValueKey('salvar-tipo')));
    await live(tester, 300);
    expect(find.text('Escolha ao menos uma variável.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('param-demo_comp')));
    await tester.tap(find.byKey(const ValueKey('salvar-tipo')));
    await live(tester, 600);
    final t = c.project.recipeTypes.firstWhere((t) => t.name == 'Corte');
    expect((t.params.single.name, t.params.single.unit), ('Comprimento do rótulo', 'mm'));
    expect(t.machines.single.tags.values, ['demo_comp']);
    expect(find.text('Nenhuma receita deste tipo ainda.'), findsOneWidget);

    // Faixa e tolerância.
    await tester.tap(find.byKey(ValueKey('tipo-${t.id}')));
    await live(tester, 600);
    await tester.tap(find.byKey(ValueKey('parametro-${t.params.single.key}')));
    await live(tester, 600);
    await tester.enterText(find.byKey(const ValueKey('param-min')), '30');
    await tester.enterText(find.byKey(const ValueKey('param-max')), '10');
    await tester.tap(find.byKey(const ValueKey('salvar-parametro')));
    await live(tester, 300);
    expect(find.text('O mínimo passa do máximo.'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('param-max')), '400');
    await tester.enterText(find.byKey(const ValueKey('param-tolerancia')), '0,5');
    await tester.tap(find.byKey(const ValueKey('salvar-parametro')));
    await live(tester, 600);
    expect(find.text('De 30 a 400 mm · tolerância 0,5'), findsOneWidget);

    // "Só com a máquina parada": "Em ciclo" desligado.
    await tester.tap(find.byKey(const ValueKey('maquina-${DemoProject.deviceId}')));
    await live(tester, 600);
    await tester.tap(find.text('Mais opções'));
    await live(tester, 800);
    await tester.tap(find.byKey(const ValueKey('condicao')));
    await live(tester, 600);
    // A folha de escolha é a de cima; a linha pode estar abaixo da dobra.
    final picker = find.descendant(of: find.byType(DraggableScrollableSheet).last, matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.byKey(const ValueKey('escolher-demo_bit_ciclo')), 150, scrollable: picker);
    await live(tester, 300);
    await tester.tap(find.byKey(const ValueKey('escolher-demo_bit_ciclo')));
    await live(tester, 600);
    expect(find.byKey(const ValueKey('condicao-desligado')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('salvar-maquina')));
    await live(tester, 600);
    final m = c.project.recipeType(t.id)!.machines.single;
    expect((m.conditionTagId, m.conditionValue), ('demo_bit_ciclo', false));
    expect(find.textContaining('só com "Em ciclo (bit da palavra)" desligado'), findsOneWidget);
    await shutdown(tester, c);
  });

  testWidgets('ler da máquina numa receita com valores pede confirmação; a versão anterior se restaura', (tester) async {
    final c = await boot(tester);
    await openRecipes(tester);
    memory().pokeRegister(hr, DemoMap.hrLabelLength, 90);
    await tester.tap(find.byKey(const ValueKey('receita-demo_receita_120')));
    await live(tester, 600);
    await tester.tap(find.byKey(const ValueKey('menu-receita')));
    await live(tester, 400);
    await tester.tap(find.byKey(const ValueKey('ler-maquina')));
    await live(tester, 1500);
    expect(find.text('Atualizar a receita?'), findsOneWidget);
    expect(find.text('Comprimento do rótulo: 120 mm → 90 mm'), findsOneWidget);
    expect(find.textContaining('Velocidade:'), findsNothing, reason: 'só o que mudou');
    await tester.tap(find.byKey(const ValueKey('confirmar-atualizar')));
    await live(tester, 600);
    var r = c.project.recipe('demo_receita_120')!;
    expect((r.version, r.values['comp'], r.note), (2, 90.0, Recipe.noteRead));

    await tester.tap(find.byKey(const ValueKey('versao-receita')));
    await live(tester, 600);
    expect(find.text('Versão 2 · atual'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('versao-1')));
    await live(tester, 400);
    expect(find.text('Comprimento do rótulo: 120 mm  (atual: 90 mm)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('restaurar-versao')));
    await live(tester, 600);
    r = c.project.recipe('demo_receita_120')!;
    expect((r.version, r.values['comp'], r.note), (3, 120.0, 'Restaurada da versão 1'));
    expect(memory().register(hr, DemoMap.hrLabelLength), 90, reason: 'mexer na receita não grava na máquina');
    await shutdown(tester, c);
  });
}

/// Avança o relógio simulado em passos de 100 ms (varredura e demonstração
/// andam). A cada meio segundo cede um instante ao relógio de verdade: o
/// histórico de aplicações é um arquivo, e a E/S real não termina sozinha
/// no relógio simulado.
Future<void> live(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 100) {
    await tester.pump(const Duration(milliseconds: 100));
    if (t % 500 == 0) await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
  }
}
