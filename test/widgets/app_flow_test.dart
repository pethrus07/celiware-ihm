import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/hmi_screen.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fluxos de ponta a ponta da interface, com a máquina de demonstração.
///
/// Tudo roda no **relógio simulado** do teste de widget: a varredura, o
/// "programa do CLP" da demo e as animações avançam com `tester.pump(dt)`.
/// Isso deixa o teste determinístico (não depende da velocidade da máquina).
/// O runtime nasce e morre dentro de cada teste, para nenhum timer sobrar.
///
/// Os tutoriais são marcados como vistos antes de montar o app: a camada do
/// tour captura todo toque (de propósito), e um teste que não a dispensa
/// morre sem explicação — armadilha 3 do onboarding da Retífica.
void main() {
  // Toque que não acerta o alvo vira falha, não aviso: um aviso passou
  // despercebido e mascarou um teste que \"passava\" sem tocar em nada.
  WidgetController.hitTestWarningShouldBeFatal = true;

  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      for (final (id, _, _) in Tours.catalog) 'tour:v1:$id': true,
    });
    dir = await Directory.systemTemp.createTemp('ihm_test');
  });

  tearDown(() async {
    DemoRegistry.discard(DemoProject.deviceId);
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {/* Windows ainda segurando o arquivo — é só a pasta temporária */}
  });

  /// Monta o app com um projeto de demonstração novo. Devolve o controlador.
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

  /// Encerra o app e o runtime dentro do teste (nenhum timer pendente).
  Future<void> shutdown(WidgetTester tester, ProjectController c) async {
    await tester.pumpWidget(const SizedBox());
    final done = c.runtime.dispose();
    await live(tester, 1200);
    await done;
    c.dispose();
  }

  testWidgets('primeira abertura: projeto de demonstração com as duas telas', (tester) async {
    final c = await boot(tester);
    expect(find.text('Cortadora — operação'), findsOneWidget);
    expect(find.text('Resumo do líder'), findsOneWidget);
    expect(File('${dir.path}/${ProjectRepository.fileName}').existsSync(), isTrue);
    await shutdown(tester, c);
  });

  testWidgets('tela em operação mostra valores ao vivo da máquina simulada', (tester) async {
    final c = await boot(tester);
    await tester.tap(find.byKey(const ValueKey('tela-${DemoProject.operationScreenId}')));
    await live(tester, 1500);
    expect(find.textContaining('Online'), findsOneWidget);
    expect(find.text('PARADA'), findsWidgets);
    expect(find.text('18240'), findsOneWidget); // produção inicial da demo
    await shutdown(tester, c);
  });

  testWidgets('botão Liga pede confirmação e liga a máquina de verdade', (tester) async {
    final c = await boot(tester);
    await tester.tap(find.byKey(const ValueKey('tela-${DemoProject.operationScreenId}')));
    await live(tester, 1200);

    await tester.tap(find.text('LIGA'));
    await live(tester, 300);
    expect(find.byKey(const ValueKey('confirmar-escrita')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirmar-escrita')));
    await live(tester, 1500);

    final memory = DemoRegistry.forDevice(DemoProject.deviceId).memory;
    expect(memory.bit(ModbusArea.coil, DemoMap.coilRun), isTrue);
    expect(find.text('EM CICLO'), findsWidgets);
    await shutdown(tester, c);
  });

  testWidgets('tela só de acompanhamento não grava nada', (tester) async {
    final c = await boot(tester);
    final leader = c.project.screen(DemoProject.leaderScreenId)!;
    c.saveScreen(leader.copyWith(elements: [
      ...leader.elements,
      const HmiElement(id: 't_btn', type: ElementType.button, x: 0, y: 7, w: 2, h: 2,
          props: {'tagId': 'demo_liga', 'label': 'Teste', 'mode': 'toggle'}),
    ]));
    await live(tester, 200);
    await tester.tap(find.byKey(const ValueKey('tela-${DemoProject.leaderScreenId}')));
    await live(tester, 900);
    await tester.tap(find.text('TESTE'));
    await live(tester, 300);
    expect(find.byKey(const ValueKey('confirmar-escrita')), findsNothing);
    expect(find.text('Esta tela é só de acompanhamento.'), findsOneWidget);
    expect(DemoRegistry.forDevice(DemoProject.deviceId).memory.bit(ModbusArea.coil, DemoMap.coilRun), isFalse);
    await shutdown(tester, c);
  });

  testWidgets('escala e texto: 352 do equipamento vira 35,2 °C; nome lido em ASCII', (tester) async {
    final c = await boot(tester);
    final memory = DemoRegistry.forDevice(DemoProject.deviceId).memory;
    await tester.tap(find.byKey(const ValueKey('tela-${DemoProject.leaderScreenId}')));
    await live(tester, 1200);
    expect(find.text(DemoMap.machineName), findsOneWidget);
    final raw = memory.register(ModbusArea.holdingRegister, DemoMap.hrMotorTempX10);
    expect(raw, greaterThan(300)); // ~32 °C × 10
    // O mostrador tem o número sem unidade; a leitura anda, então basta a vírgula da escala.
    expect(find.textContaining(RegExp(r'^\d{2},\d$')), findsWidgets);
    await shutdown(tester, c);
  });

  testWidgets('botão "Ir para tela" e mostrador com "ao tocar, abrir" trocam de tela', (tester) async {
    final c = await boot(tester);
    await tester.tap(find.byKey(const ValueKey('tela-${DemoProject.leaderScreenId}')));
    await live(tester, 900);
    // Funciona em tela só de acompanhamento: navegar não grava nada.
    await tester.tap(find.byKey(const ValueKey('ir-li_ir')));
    await live(tester, 600);
    expect(find.text('Cortadora — operação'), findsOneWidget);
    expect(find.text('Resumo do líder'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('ir-op_prod')));
    await live(tester, 600);
    expect(find.text('Resumo do líder'), findsOneWidget);
    await shutdown(tester, c);
  });

  testWidgets('botão com retorno: porta aberta = comando gravado, botão aguardando', (tester) async {
    final c = await boot(tester);
    final memory = DemoRegistry.forDevice(DemoProject.deviceId).memory;
    memory.pokeBit(ModbusArea.discreteInput, DemoMap.diDoorClosed, false);
    await tester.tap(find.byKey(const ValueKey('tela-${DemoProject.operationScreenId}')));
    await live(tester, 1200);
    await tester.tap(find.text('LIGA'));
    await live(tester, 300);
    await tester.tap(find.byKey(const ValueKey('confirmar-escrita')));
    await live(tester, 1500);

    expect(memory.bit(ModbusArea.coil, DemoMap.coilRun), isTrue); // o comando foi
    expect(memory.bit(ModbusArea.coil, DemoMap.coilInCycle), isFalse); // a máquina não partiu
    expect(find.byIcon(Icons.hourglass_top_rounded), findsOneWidget);
    await shutdown(tester, c);
  });

  testWidgets('editor: paleta acrescenta elemento e abre a configuração', (tester) async {
    final c = await boot(tester);
    await tester.tap(find.text('Nova tela'));
    await live(tester, 300);
    await tester.enterText(find.byKey(const ValueKey('campo-nome')), 'Teste');
    await tester.tap(find.byKey(const ValueKey('ok-nome')));
    await live(tester, 700);

    expect(find.text('Elemento'), findsOneWidget); // barra do editor
    await tester.tap(find.text('Elemento'));
    await live(tester, 500);
    await tester.tap(find.byKey(const ValueKey('paleta-lamp')));
    await live(tester, 700);

    expect(find.text('Lâmpada'), findsWidgets);
    // A variável agora é escolhida numa folha própria (lista não ocupa a configuração).
    await tester.tap(find.byKey(const ValueKey('escolher-variavel')));
    await live(tester, 600);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('escolher-demo_porta')), 150, scrollable: find.byType(Scrollable).last);
    await live(tester, 200);
    await tester.tap(find.byKey(const ValueKey('escolher-demo_porta')));
    await live(tester, 300);

    final screen = c.project.screens.firstWhere((s) => s.name == 'Teste');
    expect(screen.elements.single.type, ElementType.lamp);
    expect(screen.elements.single.tagId, 'demo_porta');
    expect(screen.elements.single.prop<String>('label', ''), 'Porta fechada');
    await shutdown(tester, c);
  });
}

/// Avança o relógio simulado em passos de 100 ms (varredura e demo andam).
Future<void> live(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
