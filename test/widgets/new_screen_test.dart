import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/modbus/modbus_client_simulated.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/hmi_screen.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/vendor_profiles.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/runtime/device_session.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Nova tela" com modelos prontos (itens 28, 161, 162, 165–167): em branco
/// continua o padrão (Enter no nome cria a tela vazia de sempre); escolhido
/// um modelo, aparecem o equipamento e o resumo do que vai ser criado, e a
/// tela abre no editor com as variáveis no lugar.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      // Todas as versões já vistas (a trilha de início está na v2).
      for (final (id, _, _) in Tours.catalog) for (final v in [1, 2]) 'tour:v$v:$id': true,
    });
    dir = await Directory.systemTemp.createTemp('ihm_nova_tela');
  });

  tearDown(() async {
    DemoRegistry.discard(DemoProject.deviceId);
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {/* Windows ainda segurando o arquivo — é só a pasta temporária */}
  });

  const md500 = Device(id: 'md', name: 'Inversor da bomba', host: '10.0.0.4', profile: 'inovance-md500');

  /// App com a demonstração (e o que [extra] acrescentar ao projeto). O
  /// inversor fala com uma memória simulada: nenhum socket no teste.
  Future<ProjectController> boot(WidgetTester tester, {Project Function(Project)? extra}) async {
    final memory = ModbusMemory(holdingRegisters: 65536);
    final runtime = HmiRuntime(clientFactory: (d) => d.isDemo ? DeviceSession.defaultClientFactory(d) : SimulatedModbusClient(memory: memory, latency: Duration.zero));
    final controller = ProjectController(repository: ProjectRepository(directory: dir), runtime: runtime);
    await tester.runAsync(controller.load);
    if (extra != null) await tester.runAsync(() => controller.replace(extra(controller.project)));
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

  Future<void> tapKey(WidgetTester tester, String key, {int wait = 500}) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await live(tester, wait);
  }

  Future<void> newScreen(WidgetTester tester) async {
    await tester.tap(find.text('Nova tela'));
    await live(tester, 400);
  }

  Future<void> pickTemplate(WidgetTester tester, String id) async {
    await tapKey(tester, 'escolher-modelo', wait: 700);
    await tester.scrollUntilVisible(find.byKey(ValueKey('modelo-$id')), 200, scrollable: find.byType(Scrollable).last);
    await live(tester, 200);
    await tapKey(tester, 'modelo-$id', wait: 700);
  }

  /// Fecha o editor (o "voltar" do celular).
  Future<void> back(WidgetTester tester) async {
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await live(tester, 700);
  }

  String fieldText(WidgetTester tester, String key) => tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

  testWidgets('em branco é o padrão: Enter no nome cria a tela vazia de sempre', (tester) async {
    final c = await boot(tester);
    final before = c.project.tags.length;
    await newScreen(tester);
    expect(find.text('Em branco'), findsOneWidget);
    expect(find.byKey(const ValueKey('escolher-equipamento-modelo')), findsNothing, reason: 'em branco não pede equipamento');
    await tester.enterText(find.byKey(const ValueKey('campo-nome')), 'Painel');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await live(tester, 700);
    final s = c.project.screens.firstWhere((s) => s.name == 'Painel');
    expect(s.columns, HmiScreen.defaultColumns);
    expect(s.elements, isEmpty);
    expect(c.project.tags.length, before);
    expect(find.text('Elemento'), findsOneWidget, reason: 'abriu o editor');
    await shutdown(tester, c);
  });

  testWidgets('Máquina na demonstração: usa o que a cortadora já tem e cria o resto a configurar', (tester) async {
    final c = await boot(tester);
    final before = c.project.tags.length;
    await newScreen(tester);
    await pickTemplate(tester, 'maquina');
    // O nome vem do modelo; o equipamento, o único que há.
    expect(fieldText(tester, 'campo-nome'), 'Máquina');
    expect(find.descendant(of: find.byKey(const ValueKey('escolher-equipamento-modelo')), matching: find.text('Cortadora de rótulos')), findsOneWidget);
    // "Liga máquina", "Reset de alarme" e "Velocidade" já existem na demonstração.
    expect(tester.widget<Text>(find.byKey(const ValueKey('resumo-modelo'))).data, 'Cria 5 variáveis com o endereço a configurar; usa 3 que já existem.');
    expect(find.text('Criar'), findsOneWidget);
    await tapKey(tester, 'ok-nome', wait: 900);

    final s = c.project.screens.firstWhere((s) => s.name == 'Máquina');
    expect(s.columns, HmiScreen.fineColumns);
    expect(s.elements.length, 7);
    final created = c.project.tags.skip(before).toList();
    expect(created.length, 5);
    expect(created.every((t) => t.addressPending && t.deviceId == DemoProject.deviceId), isTrue);
    expect(s.tagIds, containsAll(['demo_liga', 'demo_reset', 'demo_vel']));
    // No editor: o aviso de baixo e os elementos sem endereço marcados.
    expect(find.text('Elemento'), findsOneWidget);
    expect(find.byKey(const ValueKey('aviso-a-configurar')), findsOneWidget);
    expect(find.text('5 variáveis com o endereço a configurar — preencha em Variáveis.'), findsOneWidget);
    expect(find.textContaining('a configurar'), findsWidgets);
    // De volta à lista: o cartão diz o que falta.
    await back(tester);
    expect(find.byKey(ValueKey('a-configurar-${s.id}')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(ValueKey('a-configurar-${s.id}'))).data, ' · 5 a configurar');
    await shutdown(tester, c);
  });

  testWidgets('inversor: sugere o equipamento com perfil de inversor e usa o mapa da marca', (tester) async {
    final c = await boot(tester, extra: (p) => p.upsertDevice(md500));
    await newScreen(tester);
    await pickTemplate(tester, 'inversor-basico');
    expect(find.descendant(of: find.byKey(const ValueKey('escolher-equipamento-modelo')), matching: find.text('Inversor da bomba')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('resumo-modelo'))).data, 'Cria 6 variáveis: 4 com o mapa do Inovance MD500 e 2 a configurar.');
    await tapKey(tester, 'ok-nome', wait: 900);

    final s = c.project.screens.firstWhere((s) => s.name == 'Inversor — básico');
    final tags = [for (final id in s.tagIds) c.project.tag(id)!];
    for (final t in VendorProfiles.inovanceMd500.templates) {
      expect(tags.where((x) => x.address == t.address && !x.addressPending && x.deviceId == 'md'), hasLength(1), reason: t.name);
    }
    expect(tags.where((x) => x.addressPending).map((x) => x.name), unorderedEquals(['Frequência de saída', 'Corrente do motor']));
    expect(find.text('2 variáveis com o endereço a configurar — preencha em Variáveis.'), findsOneWidget);
    await shutdown(tester, c);
  });

  testWidgets('trocar de modelo não apaga o nome digitado; trocar de equipamento refaz o resumo', (tester) async {
    final c = await boot(tester, extra: (p) => p.upsertDevice(md500));
    await newScreen(tester);
    await tester.enterText(find.byKey(const ValueKey('campo-nome')), 'Bomba 3');
    await pickTemplate(tester, 'inversor-completo');
    expect(fieldText(tester, 'campo-nome'), 'Bomba 3');
    await tapKey(tester, 'escolher-equipamento-modelo', wait: 700);
    await tapKey(tester, 'equipamento-modelo-${DemoProject.deviceId}', wait: 500);
    // Sem perfil de inversor: comando por bits, tudo a configurar.
    expect(tester.widget<Text>(find.byKey(const ValueKey('resumo-modelo'))).data, contains('com o endereço a configurar'));
    // Voltar para "Em branco" some com o equipamento.
    await pickTemplate(tester, 'em-branco');
    expect(find.byKey(const ValueKey('escolher-equipamento-modelo')), findsNothing);
    expect(fieldText(tester, 'campo-nome'), 'Bomba 3');
    await tester.tap(find.text('Cancelar'));
    await live(tester, 400);
    await shutdown(tester, c);
  });

  testWidgets('sem equipamento cadastrado: o modelo explica e não deixa criar', (tester) async {
    final c = await boot(tester, extra: (_) => const Project());
    await newScreen(tester);
    await pickTemplate(tester, 'celula-carga');
    expect(find.textContaining('Cadastre o equipamento primeiro'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('ok-nome'))).onPressed, isNull);
    await tester.tap(find.text('Cancelar'));
    await live(tester, 400);
    expect(c.project.screens, isEmpty);
    await shutdown(tester, c);
  });

  testWidgets('em operação, botão sem endereço não grava e diz por quê', (tester) async {
    final c = await boot(tester);
    await newScreen(tester);
    await pickTemplate(tester, 'celula-carga');
    await tapKey(tester, 'ok-nome', wait: 900);
    final s = c.project.screens.firstWhere((s) => s.name == 'Célula de carga');
    await back(tester);
    await tester.tap(find.byKey(ValueKey('tela-${s.id}')));
    await live(tester, 900);
    expect(find.text('A CONFIGURAR'), findsNWidgets(2), reason: 'Tarar e Zerar');
    await tester.tap(find.text('TARAR'));
    await live(tester, 400);
    expect(find.byKey(const ValueKey('confirmar-escrita')), findsNothing, reason: 'nem pergunta: não há onde gravar');
    expect(find.text('"Comando de tara" ainda está com o endereço a configurar (em Variáveis).'), findsOneWidget);
    await shutdown(tester, c);
  });

  testWidgets('variável a configurar: a lista avisa, o cadastro abre sem endereço e salvar tira a marca', (tester) async {
    final c = await boot(tester);
    await newScreen(tester);
    await pickTemplate(tester, 'celula-carga');
    await tapKey(tester, 'ok-nome', wait: 900);
    final peso = c.project.tags.firstWhere((t) => t.name == 'Peso' && t.deviceId == DemoProject.deviceId);
    expect(peso.addressPending, isTrue);
    await back(tester);

    await tester.tap(find.text('Variáveis').last);
    await live(tester, 900);
    final tile = find.byKey(ValueKey('var-${peso.id}'));
    await tester.scrollUntilVisible(tile, 300, scrollable: find.byType(Scrollable).first);
    await live(tester, 300);
    expect(find.descendant(of: tile, matching: find.text('Endereço a configurar')), findsOneWidget);
    expect(find.descendant(of: tile, matching: find.text('a configurar')), findsOneWidget);
    await tester.tap(tile);
    await live(tester, 900);
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('campo-endereco'))).controller!.text, '', reason: 'o 0 do padrão não é endereço');

    await tester.enterText(find.byKey(const ValueKey('campo-endereco')), '20');
    await live(tester, 300);
    await tester.ensureVisible(find.byKey(const ValueKey('salvar-variavel')));
    await live(tester, 200);
    await tester.tap(find.byKey(const ValueKey('salvar-variavel')));
    await live(tester, 900);
    final saved = c.project.tag(peso.id)!;
    expect(saved.addressPending, isFalse);
    expect(saved.address, 20);
    expect(saved.name, 'Peso');
    await shutdown(tester, c);
  });
}

/// Avança o relógio simulado em passos de 100 ms (varredura e demo andam).
Future<void> live(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
