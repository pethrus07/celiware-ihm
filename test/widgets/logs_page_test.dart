import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/app_scope.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/log_group.dart';
import 'package:ihm/screens/logs/logs_page.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/logging/data_logger.dart';
import 'package:ihm/services/logging/log_store.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:ihm/widgets/logs/history_chart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Registro de dados pela interface, com a máquina de demonstração e o
/// SQLite de verdade (ffi sem isolate: as operações do banco terminam dentro
/// do relógio simulado do teste de widget).
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  late Directory dir;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      // Todas as versões já vistas (a trilha de início está na v2).
      for (final (id, _, _) in Tours.catalog) for (final v in [1, 2]) 'tour:v$v:$id': true,
    });
    dir = await Directory.systemTemp.createTemp('ihm_registros_ui');
    // O app usa o SQLite do Android; aqui, o do Windows pela mesma interface.
    databaseFactoryOrNull = databaseFactoryFfiNoIsolate;
  });

  tearDown(() async {
    databaseFactoryOrNull = null;
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

  /// A lista da folha de registro (não o rolamento interno do campo de texto).
  Finder sheetList() => find.descendant(of: find.byType(LogGroupSheet), matching: find.byType(Scrollable)).first;

  DataLogger loggerOf(WidgetTester tester) => AppScope.of(tester.element(find.byType(Scaffold).first)).logger;

  Future<void> openLogs(WidgetTester tester) async {
    await tester.tap(find.text('Ferramentas'));
    await live(tester, 400);
    await tester.ensureVisible(find.byKey(const ValueKey('registros')));
    await live(tester, 200);
    await tester.tap(find.byKey(const ValueKey('registros')));
    await live(tester, 600);
  }

  testWidgets('Registros, Receitas e Regras têm o "?" com a explicação da página', (tester) async {
    final c = await boot(tester);
    await tester.tap(find.text('Ferramentas'));
    await live(tester, 600);
    for (final (key, text) in [
      ('registros', 'Grava variáveis no celular'),
      ('receitas', 'Os ajustes de cada produto'),
      ('regras', 'uma máquina avisa a outra'),
    ]) {
      await tester.ensureVisible(find.byKey(ValueKey(key)));
      await live(tester, 300);
      await tester.tap(find.byKey(ValueKey(key)));
      await live(tester, 800);
      await tester.tap(find.byKey(const ValueKey('ajuda')).last);
      await live(tester, 800);
      expect(find.textContaining(text), findsOneWidget, reason: key);
      await tester.tap(find.text('Pular'));
      await live(tester, 600);
      await tester.tap(find.byTooltip('Voltar'));
      await live(tester, 800);
    }
    await shutdown(tester, c);
  });

  testWidgets('Ferramentas → Registros: criar, gravar sem tela aberta, histórico com toque e pinça, desligar', (tester) async {
    final c = await boot(tester);
    await openLogs(tester);
    expect(find.text('Nenhum registro'), findsOneWidget);

    // Criar: nome, duas variáveis, a cada 1 s (padrão), guardar 7 dias (padrão).
    await tester.tap(find.byKey(const ValueKey('criar-registro')));
    await live(tester, 600);
    await tester.enterText(find.byKey(const ValueKey('nome-registro')), 'Motor');
    await tester.tap(find.byKey(const ValueKey('salvar-registro')));
    await live(tester, 300);
    expect(find.text('Escolha ao menos uma variável.'), findsOneWidget);
    for (final id in ['demo_temp', 'demo_vel']) {
      await tester.ensureVisible(find.byKey(ValueKey('var-registro-$id')));
      await live(tester, 200);
      await tester.tap(find.byKey(ValueKey('var-registro-$id')));
    }
    await live(tester, 200);
    expect(find.text('Escolha ao menos uma variável.'), findsNothing);
    // Texto e lista não aparecem para escolher.
    expect(find.byKey(const ValueKey('var-registro-demo_hora'), skipOffstage: false), findsNothing);
    // Ritmo, retenção e o tamanho estimado logo abaixo das variáveis.
    await tester.scrollUntilVisible(find.byKey(const ValueKey('estimativa-registro')), 150, scrollable: sheetList());
    await live(tester, 200);
    expect(find.byKey(const ValueKey('intervalo-1')), findsOneWidget);
    expect(find.textContaining('MB no aparelho'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('salvar-registro')));
    await live(tester, 600);

    final g = c.project.logGroups.single;
    expect((g.name, g.intervalSec, g.retentionDays, g.mode), ('Motor', 1, 7, LogMode.periodic));
    expect(g.tagIds, ['demo_vel', 'demo_temp']); // na ordem do cadastro de variáveis
    expect(find.text('A cada 1 s · 2 variáveis'), findsOneWidget);

    // De volta à lista de telas: nenhuma tela aberta e o registro segue gravando.
    await tester.tap(find.byTooltip('Voltar'));
    await live(tester, 400);
    await tester.tap(find.text('Projetos'));
    await live(tester, 12000); // 12 s: 1 linha por segundo, lote aos 10 s
    final logger = loggerOf(tester);
    final onDisk = await logger.store.count(g.id);
    expect(onDisk, greaterThan(0), reason: 'o lote de 10 s já foi para o disco');
    expect(onDisk + logger.pendingOf(g.id), greaterThanOrEqualTo(10), reason: '~1 linha por segundo');
    expect(logger.usageOf(g.id), greaterThan(0));

    // Histórico.
    await openLogs(tester);
    expect(find.textContaining('A cada 1 s · 2 variáveis · '), findsOneWidget, reason: 'mostra o uso de disco');
    await tester.tap(find.byKey(ValueKey('registro-${g.id}')));
    await live(tester, 800);
    final chart = find.byKey(const ValueKey('grafico-historico'));
    expect(chart, findsOneWidget);
    expect(find.text('Nada gravado neste período'), findsNothing);
    expect(find.byKey(const ValueKey('mostrar-tudo')), findsNothing);

    // Pinça na borda direita (o "agora"): aproxima até o mínimo de 30 s.
    final size = tester.getSize(chart);
    final origin = tester.getTopLeft(chart);
    final plot = HistoryPainter.plotFor(size, dual: true); // °C e m/min: eixo duplo
    // Os dois dedos sobre o eixo da direita: o ponto entre eles fica além da
    // borda das curvas e a pinça aproxima mantendo o "agora" na borda.
    final right = origin + Offset(plot.right, plot.center.dy);
    for (var round = 0; round < 4; round++) {
      final a = await tester.startGesture(right + const Offset(5, 0), pointer: 11 + 2 * round);
      final b = await tester.startGesture(right + const Offset(25, 0), pointer: 12 + 2 * round);
      for (var i = 0; i < 12; i++) {
        await a.moveBy(const Offset(-12, 0));
        await b.moveBy(const Offset(12, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await a.up();
      await b.up();
      await live(tester, 400);
    }
    expect(find.byKey(const ValueKey('mostrar-tudo')), findsOneWidget);
    HistoryPainter painter() => tester.widget<CustomPaint>(find.descendant(of: chart, matching: find.byType(CustomPaint)).first).painter! as HistoryPainter;
    expect(painter().toMs - painter().fromMs, 30000, reason: 'aproxima até o mínimo de 30 s, nunca menos');

    // Arrastar para a esquerda anda para o "agora" — e para no fim do período.
    final before = painter().toMs;
    await tester.dragFrom(origin + plot.center, const Offset(-450, 0));
    await live(tester, 400);
    expect(painter().toMs, greaterThan(before));
    expect(painter().toMs - painter().fromMs, 30000, reason: 'arrastar não muda o zoom');
    expect(find.text('Nada gravado neste período'), findsNothing, reason: 'os últimos 30 s têm linhas');

    // Valor sob o dedo: hora e o valor de cada curva, com unidade.
    await tester.tapAt(origin + Offset(plot.left + plot.width * 0.9, plot.center.dy));
    await live(tester, 300);
    expect(find.byKey(const ValueKey('hora-cursor')), findsOneWidget);
    expect(find.textContaining('°C'), findsOneWidget);
    expect(find.textContaining('m/min'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mostrar-tudo')));
    await live(tester, 400);
    expect(find.byKey(const ValueKey('mostrar-tudo')), findsNothing);

    // Outro período.
    await tester.tap(find.byKey(const ValueKey('periodo-week')));
    await live(tester, 400);
    expect(find.text('Nada gravado neste período'), findsNothing);

    // Dias escolhidos (em português, sem o calendário do Material): ontem a hoje.
    await tester.tap(find.byKey(const ValueKey('periodo-custom')));
    await live(tester, 600);
    expect(find.textContaining('Hoje · '), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dia-1')));
    await live(tester, 200);
    await tester.tap(find.byKey(const ValueKey('dia-0')));
    await live(tester, 600);
    expect(find.textContaining(' a '), findsOneWidget, reason: 'o chip mostra "dd/MM a dd/MM"');
    expect(find.text('Nada gravado neste período'), findsNothing);

    // Desligar pela chave da lista.
    await tester.tap(find.byTooltip('Voltar'));
    await live(tester, 400);
    await tester.tap(find.byKey(ValueKey('ligar-${g.id}')));
    await live(tester, 400);
    expect(c.project.logGroups.single.enabled, isFalse);
    expect(find.textContaining('Desligado'), findsOneWidget);
    await shutdown(tester, c);
  });

  testWidgets('apagar o registro apaga o histórico do aparelho', (tester) async {
    final c = await boot(tester);
    c.saveLogGroup(const LogGroup(id: 'lg_teste', name: 'Teste', tagIds: ['demo_vel']));
    await live(tester, 11000);
    final file = File('${dir.path}${Platform.pathSeparator}${LogStore.folder}${Platform.pathSeparator}${LogStore.fileName('lg_teste')}');
    expect(file.existsSync(), isTrue);

    await openLogs(tester);
    await tester.tap(find.byKey(const ValueKey('registro-lg_teste')));
    await live(tester, 600);
    await tester.tap(find.byKey(const ValueKey('ajustar-registro')));
    await live(tester, 600);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('apagar-registro')), 150, scrollable: sheetList());
    await tester.tap(find.byKey(const ValueKey('apagar-registro')));
    await live(tester, 400);
    expect(find.textContaining('também é apagado'), findsOneWidget);
    await tester.tap(find.text('Apagar'));
    await live(tester, 800);

    expect(c.project.logGroups, isEmpty);
    expect(file.existsSync(), isFalse);
    expect(find.text('Nenhum registro'), findsOneWidget, reason: 'voltou para a lista, agora vazia');
    await shutdown(tester, c);
  });
}

/// Avança o relógio simulado em passos de 100 ms (varredura, demo e registro
/// andam). A cada meio segundo cede um instante ao relógio de verdade: abrir
/// o banco passa por E/S de arquivo real (o ffi confere se o arquivo existe),
/// que o relógio simulado não completa sozinho.
Future<void> live(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 100) {
    await tester.pump(const Duration(milliseconds: 100));
    if (t % 500 == 0) await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
  }
}
