import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/app_scope.dart';
import 'package:ihm/app/appearance.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/theme/app_theme.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/hmi_screen.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:ihm/widgets/alarms/alarm_widgets.dart';
import 'package:ihm/widgets/hmi/elements/control_elements.dart';
import 'package:ihm/widgets/hmi/hmi_canvas.dart';
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
      // Todas as versões já vistas (a trilha de início está na v2).
      for (final (id, _, _) in Tours.catalog) for (final v in [1, 2]) 'tour:v$v:$id': true,
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
    expect(find.text('SEM RETORNO'), findsNothing);

    // Passado o prazo, a espera vira aviso: ampulheta para sempre parecia travado.
    await live(tester, ButtonElement.feedbackTimeout.inMilliseconds);
    expect(find.byIcon(Icons.hourglass_top_rounded), findsNothing);
    expect(find.text('SEM RETORNO'), findsOneWidget);

    // Operador desligou o comando: acabou a espera, o aviso sai.
    await tester.tap(find.text('LIGA'));
    await live(tester, 300);
    await tester.tap(find.byKey(const ValueKey('confirmar-escrita')));
    await live(tester, 1500);
    expect(memory.bit(ModbusArea.coil, DemoMap.coilRun), isFalse);
    expect(find.text('SEM RETORNO'), findsNothing);
    expect(find.byIcon(Icons.hourglass_top_rounded), findsNothing);
    await shutdown(tester, c);
  });

  testWidgets('celular deitado / tablet: a célula tem teto e a grade fica centralizada', (tester) async {
    final c = await boot(tester);
    tester.view.physicalSize = const Size(2400, 1080); // Pixel 7 deitado
    await live(tester, 300);
    await tester.tap(find.byKey(const ValueKey('tela-${DemoProject.operationScreenId}')));
    await live(tester, 900);
    final status = tester.getRect(find.byKey(const ValueKey('el-op_status')));
    final vel = tester.getRect(find.byKey(const ValueKey('el-op_vel')));
    final screenW = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    // 3 células com teto (menos o respiro): antes ocupava meia tela.
    expect(status.width, lessThanOrEqualTo(3 * HmiCanvas.maxCell));
    // Centralizada: sobra o mesmo espaço dos dois lados, não só à direita.
    expect(status.left, greaterThan(100));
    expect((status.left + vel.right) / 2, closeTo(screenW / 2, 1));
    await shutdown(tester, c);
  });

  testWidgets('escolha de variável: busca por nome, sem acento', (tester) async {
    final c = await boot(tester);
    await tester.tap(find.text('Nova tela'));
    await live(tester, 300);
    await tester.enterText(find.byKey(const ValueKey('campo-nome')), 'Busca');
    await tester.tap(find.byKey(const ValueKey('ok-nome')));
    await live(tester, 700);
    await tester.tap(find.text('Elemento'));
    await live(tester, 500);
    // Mostrador aceita qualquer valor único (18 na demo): a busca aparece a
    // partir de 8 compatíveis — a lâmpada, com 7 liga/desliga, não mostra.
    await tester.tap(find.byKey(const ValueKey('paleta-value')));
    await live(tester, 700);
    await tester.tap(find.byKey(const ValueKey('escolher-variavel')));
    await live(tester, 600);

    await tester.enterText(find.byKey(const ValueKey('buscar-variavel')), 'maquina'); // "Liga máquina"
    await live(tester, 300);
    expect(find.byKey(const ValueKey('escolher-demo_liga')), findsOneWidget);
    expect(find.byKey(const ValueKey('escolher-demo_porta')), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('buscar-variavel')), 'xyz');
    await live(tester, 300);
    expect(find.textContaining('Nenhuma variável com'), findsOneWidget);
    await shutdown(tester, c);
  });

  testWidgets('trocar a aparência no meio do uso: continua na mesma tela e tudo responde', (tester) async {
    final c = await boot(tester);
    await tester.tap(find.byKey(const ValueKey('tela-${DemoProject.operationScreenId}')));
    await live(tester, 900);
    final before = Ind.palette;
    await AppearanceController.instance.set(before.dark ? Appearance.claro : Appearance.escuro);
    await live(tester, 300);
    expect(Ind.palette, isNot(same(before)));
    // Continua na operação (não voltou para o início) e com a cor nova.
    expect(find.text('Cortadora — operação'), findsOneWidget);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).last);
    expect(Theme.of(tester.element(find.byWidget(scaffold))).scaffoldBackgroundColor, Ind.bg);
    // E segue operável: o botão Liga pede confirmação.
    await tester.tap(find.text('LIGA'));
    await live(tester, 300);
    expect(find.byKey(const ValueKey('confirmar-escrita')), findsOneWidget);
    await AppearanceController.instance.set(Appearance.auto);
    await shutdown(tester, c);
  });

  testWidgets('alarme ponta a ponta: faixa no topo, marca no elemento, reconhecer, normalizar, histórico', (tester) async {
    final c = await boot(tester);
    final memory = DemoRegistry.forDevice(DemoProject.deviceId).memory;
    await tester.tap(find.byKey(const ValueKey('tela-${DemoProject.operationScreenId}')));
    await live(tester, 900);
    expect(find.byKey(const ValueKey('faixa-alarme')), findsNothing);

    // Porta abre: depois de 1 s de condição, vira alarme de prioridade alta.
    memory.pokeBit(ModbusArea.discreteInput, DemoMap.diDoorClosed, false);
    await live(tester, 600);
    expect(find.byKey(const ValueKey('faixa-alarme')), findsNothing, reason: 'antes de 1 s não dispara');
    await live(tester, 1200);
    expect(find.byKey(const ValueKey('faixa-alarme')), findsOneWidget);
    expect(find.text('Porta aberta'), findsOneWidget);
    expect(find.byType(ElementAlarmBadge), findsOneWidget); // a lâmpada da porta se marca

    // Toque na faixa abre a lista; reconhecer.
    await tester.tap(find.byKey(const ValueKey('faixa-alarme')));
    await live(tester, 600);
    expect(find.text('Alarmes'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('reconhecer-regra:demo_porta:al_porta')));
    await live(tester, 300);
    expect(find.text('Alta · Reconhecido'), findsOneWidget);

    // Porta fecha: reconhecido + normalizou = sai da lista e a faixa some.
    memory.pokeBit(ModbusArea.discreteInput, DemoMap.diDoorClosed, true);
    await live(tester, 1200);
    expect(find.byKey(const ValueKey('faixa-alarme')), findsNothing);
    expect(find.text('Tudo normal'), findsOneWidget);

    await tester.tap(find.text('Histórico'));
    await live(tester, 600);
    expect(find.textContaining('Ativou'), findsOneWidget);
    expect(find.textContaining('Reconhecido'), findsOneWidget);
    expect(find.textContaining('Normalizou'), findsOneWidget);
    await shutdown(tester, c);
  });

  testWidgets('alarme que normaliza sem ninguém ver continua na faixa até ser reconhecido', (tester) async {
    final c = await boot(tester);
    final memory = DemoRegistry.forDevice(DemoProject.deviceId).memory;
    memory.pokeBit(ModbusArea.discreteInput, DemoMap.diDoorClosed, false);
    await live(tester, 2000);
    memory.pokeBit(ModbusArea.discreteInput, DemoMap.diDoorClosed, true);
    await live(tester, 1200);
    // Vigiado mesmo sem nenhuma tela aberta (estamos na lista de telas).
    expect(find.byKey(const ValueKey('faixa-alarme')), findsOneWidget);
    expect(find.textContaining('Voltou ao normal'), findsOneWidget);
    expect(c.runtime.store.read('demo_porta').value, isTrue);
    await shutdown(tester, c);
  });

  // O "pulo da tela" do QA: a faixa chegava com a confirmação aberta, o
  // diálogo descia ~38 dp e o toque mirado no Confirmar caía no vazio.
  testWidgets('alarme que chega com a confirmação aberta não tira o Confirmar do lugar', (tester) async {
    final c = await boot(tester);
    final memory = DemoRegistry.forDevice(DemoProject.deviceId).memory;
    await tester.tap(find.byKey(const ValueKey('tela-${DemoProject.operationScreenId}')));
    await live(tester, 900);
    await tester.tap(find.text('LIGA'));
    await live(tester, 400);
    final confirm = find.byKey(const ValueKey('confirmar-escrita'));
    final before = tester.getRect(confirm);

    memory.pokeBit(ModbusArea.discreteInput, DemoMap.diDoorClosed, false);
    await live(tester, 2000);
    expect(find.byKey(const ValueKey('faixa-alarme')), findsOneWidget, reason: 'a faixa aparece mesmo com o diálogo aberto');
    expect(tester.getRect(confirm), before, reason: 'o diálogo não se mexe');

    // Fechado o diálogo, a tela continua onde estava (o espaço da faixa é
    // reservado o tempo todo) e nada fica escondido debaixo dela.
    final title = find.text('Cortadora — operação');
    final titleRect = tester.getRect(title);
    await tester.tap(find.text('Cancelar'));
    await live(tester, 600);
    final banner = tester.getRect(find.byKey(const ValueKey('faixa-alarme')));
    expect(tester.getRect(title), titleRect, reason: 'a tela não desce quando o diálogo fecha');
    expect(tester.getRect(title).top, greaterThanOrEqualTo(banner.bottom));

    // O contrário: faixa no topo, diálogo aberto, o alarme sai (reconhecido e
    // normalizado) — o diálogo continua onde estava.
    await tester.tap(find.text('LIGA'));
    await live(tester, 400);
    final withBanner = tester.getRect(confirm);
    AppScope.of(tester.element(confirm)).alarms.acknowledgeAll();
    memory.pokeBit(ModbusArea.discreteInput, DemoMap.diDoorClosed, true);
    await live(tester, 1500);
    expect(find.byKey(const ValueKey('faixa-alarme')), findsNothing);
    expect(tester.getRect(confirm), withBanner);
    await tester.tap(find.text('Cancelar'));
    await live(tester, 600);
    expect(find.byKey(const ValueKey('faixa-quieta')), findsOneWidget);
    expect(tester.getRect(title), titleRect, reason: 'sem alarme, a tela também não sobe: o lugar da faixa fica');
    await shutdown(tester, c);
  });

  // No aparelho, o caso do QA era o do Ajuste: o teclado (uma folha) fecha e
  // a confirmação abre logo em seguida — as duas trocas de rota chegam
  // juntas e a faixa precisa saber que há um diálogo aberto.
  testWidgets('teclado do Ajuste → Confirmar: a faixa que chega não move o diálogo', (tester) async {
    final c = await boot(tester);
    final memory = DemoRegistry.forDevice(DemoProject.deviceId).memory;
    await tester.tap(find.byKey(const ValueKey('tela-${DemoProject.operationScreenId}')));
    await live(tester, 900);
    await tester.tap(find.byKey(const ValueKey('el-op_sp')));
    await live(tester, 500);
    for (final k in ['1', '2', '0']) {
      await tester.tap(find.byKey(ValueKey('tecla-$k')));
      await tester.pump();
    }
    await tester.tap(find.byKey(const ValueKey('numpad-ok')));
    await live(tester, 500);
    final confirm = find.byKey(const ValueKey('confirmar-escrita'));
    final before = tester.getRect(confirm);
    memory.pokeBit(ModbusArea.discreteInput, DemoMap.diDoorClosed, false);
    await live(tester, 2000);
    expect(find.byKey(const ValueKey('faixa-alarme')), findsOneWidget);
    expect(tester.getRect(confirm), before);
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
