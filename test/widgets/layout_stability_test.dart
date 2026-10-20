import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/app_scope.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/calc.dart';
import 'package:ihm/models/log_group.dart';
import 'package:ihm/screens/logs/log_history_page.dart';
import 'package:ihm/screens/tags/calc_tag_form_page.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:ihm/widgets/logs/history_chart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Segunda rodada do QA visual (12/10/2026): nada na tela muda de lugar
/// sozinho. Cada teste mede em dp, com as fontes de verdade (IBM Plex) e a
/// barra de status de um Android (24 dp):
///   • a faixa de alarme entrar ou sair não move a tela (com e sem diálogo);
///   • a pergunta de uma regra não cobre a barra de abas nem o Salvar;
///   • tocar no gráfico do histórico não empurra o gráfico;
///   • no tablet deitado a tela de operação é a do celular ampliada (o
///     rótulo cresce com a célula).
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  const phone = Size(360, 800);
  const tablet = Size(1280, 800);

  late Directory dir;

  // O histórico lê o SQLite de verdade (o do Windows, pela mesma interface).
  setUpAll(sqfliteFfiInit);
  setUpAll(() async {
    for (final (family, files) in [
      ('Plex', ['IBMPlexSans-400', 'IBMPlexSans-500', 'IBMPlexSans-600', 'IBMPlexSans-700']),
      ('PlexCondensed', ['IBMPlexSansCondensed-SemiBold', 'IBMPlexSansCondensed-Bold']),
      ('PlexMono', ['IBMPlexMono-Regular', 'IBMPlexMono-SemiBold']),
    ]) {
      final loader = FontLoader(family);
      for (final f in files) {
        loader.addFont(Future.value(ByteData.sublistView(File('assets/fonts/$f.ttf').readAsBytesSync())));
      }
      await loader.load();
    }
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      // Todas as versões já vistas (a trilha de início está na v2).
      for (final (id, _, _) in Tours.catalog) for (final v in [1, 2]) 'tour:v$v:$id': true,
    });
    dir = await Directory.systemTemp.createTemp('ihm_estabilidade');
    databaseFactoryOrNull = databaseFactoryFfiNoIsolate;
  });

  tearDown(() async {
    databaseFactoryOrNull = null;
    DemoRegistry.discard(DemoProject.deviceId);
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {/* Windows ainda segurando o arquivo — é só a pasta temporária */}
  });

  Future<ProjectController> boot(WidgetTester tester, Size dp) async {
    final runtime = HmiRuntime();
    final controller = ProjectController(repository: ProjectRepository(directory: dir), runtime: runtime);
    await tester.runAsync(controller.load);
    tester.view.physicalSize = dp;
    tester.view.devicePixelRatio = 1;
    // Barra de status de verdade: a faixa do topo passa por baixo dela.
    tester.view.padding = const FakeViewPadding(top: 24);
    tester.view.viewPadding = const FakeViewPadding(top: 24);
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

  ModbusMemory memory() => DemoRegistry.forDevice(DemoProject.deviceId).memory;

  Future<void> openOperation(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('tela-${DemoProject.operationScreenId}')));
    await live(tester, 1200);
  }

  /// Porta aberta: alarme de prioridade alta depois de 1 s.
  Future<void> raiseAlarm(WidgetTester tester) async {
    memory().pokeBit(ModbusArea.discreteInput, DemoMap.diDoorClosed, false);
    await live(tester, 2000);
  }

  /// Reconhece e fecha a porta: o alarme sai da lista e da faixa.
  Future<void> clearAlarm(WidgetTester tester) async {
    AppScope.of(tester.element(find.byType(Navigator).first)).alarms.acknowledgeAll();
    memory().pokeBit(ModbusArea.discreteInput, DemoMap.diDoorClosed, true);
    await live(tester, 1500);
  }

  /// Liga a regra de exemplo da demonstração com uma condição que já vale:
  /// "Diminuir a velocidade?" chega em poucos segundos, em qualquer tela.
  Future<void> ask(WidgetTester tester, ProjectController c) async {
    final r = c.project.rule(DemoProject.ruleId)!;
    c.saveRule(r.copyWith(
      enabled: true,
      holdSec: 0,
      condition: const CalcSpec(expression: '{demo_temp} > 10', names: {'demo_temp': 'Temperatura do motor'}),
    ));
    await live(tester, 3000);
  }

  NavigatorState root(WidgetTester tester) => tester.state<NavigatorState>(find.byType(Navigator).first);

  final liga = find.byKey(const ValueKey('el-op_liga'));
  final alarmBand = find.byKey(const ValueKey('faixa-alarme'));
  final quietBand = find.byKey(const ValueKey('faixa-quieta'));
  final proposalBand = find.byKey(const ValueKey('proposta-regra'));

  group('pulo da tela: a faixa do topo tem lugar reservado', () {
    testWidgets('alarme entra e sai sem mover o Liga (sem diálogo)', (tester) async {
      final c = await boot(tester, phone);
      await openOperation(tester);
      final before = tester.getRect(liga);

      await raiseAlarm(tester);
      expect(alarmBand, findsOneWidget);
      expect(tester.getRect(liga), before, reason: 'o alarme entrou: antes a tela descia junto com a faixa');

      await clearAlarm(tester);
      expect(alarmBand, findsNothing);
      expect(tester.getRect(liga), before, reason: 'o alarme saiu: antes a tela subia');
      await shutdown(tester, c);
    });

    testWidgets('com o Confirmar aberto o alarme entra; fechado o diálogo, o Liga continua no lugar (p-143)', (tester) async {
      final c = await boot(tester, phone);
      await openOperation(tester);
      final before = tester.getRect(liga);

      await tester.tap(find.text('LIGA'));
      await live(tester, 400);
      final confirm = find.byKey(const ValueKey('confirmar-escrita'));
      final dialog = tester.getRect(confirm);
      await raiseAlarm(tester);
      expect(alarmBand, findsOneWidget);
      expect(tester.getRect(confirm), dialog, reason: 'o diálogo não se mexe');

      await tester.tap(find.text('Cancelar'));
      await live(tester, 600);
      expect(tester.getRect(liga), before, reason: 'a tela descia ~70 dp quando o diálogo fechava');

      // E o contrário: diálogo aberto, o alarme sai, o diálogo fecha.
      await tester.tap(find.text('LIGA'));
      await live(tester, 400);
      await clearAlarm(tester);
      await tester.tap(find.text('Cancelar'));
      await live(tester, 600);
      expect(quietBand, findsOneWidget);
      expect(tester.getRect(liga), before);
      await shutdown(tester, c);
    });

    testWidgets('a faixa mede o mesmo quieta, com alarme e com pergunta — em pé e deitado', (tester) async {
      final c = await boot(tester, phone);
      final quiet = tester.getRect(quietBand);
      // Barra de status + no mínimo 56 dp de alvo.
      expect(quiet.top, 0);
      expect(quiet.height, greaterThanOrEqualTo(24 + 56));

      await raiseAlarm(tester);
      expect(tester.getRect(alarmBand), quiet);
      AppScope.of(tester.element(find.byType(Navigator).first)).alarms.acknowledgeAll();
      await ask(tester, c);
      expect(proposalBand, findsOneWidget, reason: 'alarme reconhecido: a vez é da pergunta');
      expect(tester.getRect(proposalBand), quiet);

      // Deitado: uma linha só, ainda com alvo de 48 dp — e igual nas três.
      tester.view.physicalSize = const Size(800, 360);
      await live(tester, 400);
      final lying = tester.getRect(proposalBand);
      expect(lying.height, greaterThanOrEqualTo(24 + 48));
      expect(lying.height, lessThan(quiet.height));
      memory().pokeBit(ModbusArea.discreteInput, DemoMap.diDoorClosed, true);
      c.saveRule(c.project.rule(DemoProject.ruleId)!.copyWith(enabled: false));
      await live(tester, 1500);
      expect(tester.getRect(quietBand), lying);
      await shutdown(tester, c);
    });
  });

  group('pergunta da regra: aviso que não cobre navegação nem Salvar', () {
    testWidgets('chega sem cobrir a barra de abas e sem mover a tela; dá para trocar de aba sem responder', (tester) async {
      final c = await boot(tester, phone);
      final card = find.byKey(const ValueKey('tela-${DemoProject.operationScreenId}'));
      final before = tester.getRect(card);
      final nav = tester.getRect(find.byType(NavigationBar));

      await ask(tester, c);
      expect(proposalBand, findsOneWidget);
      expect(tester.getRect(proposalBand).overlaps(nav), isFalse, reason: 'o cartão antigo ficava em cima das abas');
      expect(tester.getRect(card), before, reason: 'a lista de telas não se mexe');

      // Trocar de aba sem responder (toque que não acerta o alvo é falha).
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Ferramentas')));
      await live(tester, 500);
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 3);
      expect(proposalBand, findsOneWidget, reason: 'a pergunta continua esperando');
      await shutdown(tester, c);
    });

    testWidgets('não cobre o Salvar de um cadastro, que continua no mesmo lugar', (tester) async {
      final c = await boot(tester, phone);
      unawaited(root(tester).push(MaterialPageRoute<void>(builder: (_) => const CalcTagFormPage())));
      await live(tester, 700);
      final save = find.byKey(const ValueKey('salvar-calculada'));
      final before = tester.getRect(save);

      await ask(tester, c);
      expect(proposalBand, findsOneWidget);
      expect(tester.getRect(proposalBand).overlaps(before), isFalse);
      expect(tester.getRect(save), before);
      // O toque no Salvar chega nele (com o nome vazio, o cadastro avisa).
      await tester.tap(save);
      await live(tester, 600);
      expect(find.byType(CalcTagFormPage), findsOneWidget);
      await shutdown(tester, c);
    });

    testWidgets('com um alarme novo na faixa, a pergunta espera na marca; tocar abre a decisão e Ignorar não grava', (tester) async {
      final c = await boot(tester, phone);
      final sp = memory().register(ModbusArea.holdingRegister, DemoMap.hrSpeedSetpoint);
      await raiseAlarm(tester);
      await ask(tester, c);
      expect(alarmBand, findsOneWidget, reason: 'alarme não reconhecido tem a vez (ISA-18.2)');
      expect(proposalBand, findsNothing);
      final marker = find.byKey(const ValueKey('faixa-regra'));
      expect(marker, findsOneWidget);
      expect(tester.getSize(marker).height, greaterThanOrEqualTo(48));

      await tester.tap(marker);
      await live(tester, 400);
      expect(find.text('Diminuir a velocidade?'), findsOneWidget);
      expect(find.text('Grava 65 m/min em "Velocidade desejada" (Cortadora de rótulos)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('proposta-ignorar')));
      await live(tester, 600);
      expect(AppScope.of(tester.element(find.byType(Navigator).first)).rules!.proposals, isEmpty);
      expect(marker, findsNothing);
      expect(memory().register(ModbusArea.holdingRegister, DemoMap.hrSpeedSetpoint), sp, reason: 'Ignorar não grava');
      await shutdown(tester, c);
    });
  });

  testWidgets('histórico: tocar e arrastar no gráfico não move o gráfico', (tester) async {
    final c = await boot(tester, phone);
    c.saveLogGroup(const LogGroup(id: 'lg', name: 'Motor', tagIds: ['demo_vel', 'demo_temp']));
    // A tela de operação aberta lê a máquina por alguns segundos; o primeiro
    // lote abre o banco no disco de verdade (fora do relógio simulado).
    await openOperation(tester);
    await live(tester, 4000);
    await tester.tap(find.byTooltip('Voltar'));
    await live(tester, 500);
    unawaited(root(tester).push(MaterialPageRoute<void>(builder: (_) => const LogHistoryPage(groupId: 'lg'))));
    await live(tester, 600);
    // A consulta grava o lote e lê o banco no disco de verdade, fora do
    // relógio simulado: dá a vez ao disco até o gráfico ter o que mostrar.
    final chart = find.byKey(const ValueKey('grafico-historico'));
    HistoryPainter painter() => tester.widget<CustomPaint>(find.descendant(of: chart, matching: find.byType(CustomPaint)).first).painter! as HistoryPainter;
    for (var i = 0; i < 40 && painter().window.tagIds.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(painter().window.tagIds, isNotEmpty, reason: 'o histórico carregou');
    final before = tester.getRect(chart);

    await tester.tapAt(before.center);
    await live(tester, 300);
    expect(find.byKey(const ValueKey('hora-cursor')), findsOneWidget);
    expect(tester.getRect(chart), before, reason: 'a leitura entrava em cima e empurrava o gráfico ~44 dp');

    // Toque longo e arrasto: o gráfico fica parado sob o dedo.
    final finger = await tester.startGesture(before.center + const Offset(60, 0));
    await tester.pump(const Duration(milliseconds: 700));
    for (var i = 0; i < 6; i++) {
      await finger.moveBy(const Offset(-20, 0));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.getRect(chart), before);
    }
    await finger.up();
    await live(tester, 300);
    await shutdown(tester, c);
  });

  testWidgets('tablet deitado: a tela de operação é a do celular ampliada — rótulo na proporção da célula, grade mais larga', (tester) async {
    Finder label(String id, String text) =>
        find.descendant(of: find.byKey(ValueKey('el-$id')), matching: find.byWidgetPredicate((w) => w is Text && w.data == text));

    /// Altura do rótulo "STATUS" por altura do cartão.
    Future<double> ratio(Size size) async {
      final c = await boot(tester, size);
      await openOperation(tester);
      final card = tester.getRect(find.byKey(const ValueKey('el-op_status')));
      final r = tester.getRect(label('op_status', 'STATUS')).height / card.height;
      await shutdown(tester, c);
      return r;
    }

    // 412 dp: o celular grande, célula de 64 dp — a referência da ampliação.
    final reference = await ratio(const Size(412, 900));
    final small = await ratio(phone);
    final big = await ratio(tablet);
    expect(big, closeTo(reference, reference * 0.03), reason: 'antes o rótulo ficava do tamanho do celular num cartão 1,7× maior');
    expect(big, greaterThan(small * 0.8));

    final c = await boot(tester, tablet);
    await openOperation(tester);
    final status = tester.getRect(find.byKey(const ValueKey('el-op_status')));
    final vel = tester.getRect(find.byKey(const ValueKey('el-op_vel')));
    expect(vel.right - status.left, greaterThan(6 * 96), reason: 'a grade passava de 6 × 96 dp no tablet deitado');
    expect((status.left + vel.right) / 2, closeTo(tablet.width / 2, 1), reason: 'centralizada');
    await shutdown(tester, c);
  });
}

/// Avança o relógio simulado em passos de 100 ms (varredura e demo andam).
Future<void> live(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
