import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/core/theme/app_theme.dart';
import 'package:ihm/main.dart';
import 'package:ihm/screens/editor/screen_editor_page.dart';
import 'package:ihm/screens/screen_run_page.dart';
import 'package:ihm/screens/shell.dart';
import 'package:ihm/screens/tags/calc_tag_form_page.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:ihm/widgets/common/common.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Achados do QA visual de 12/10/2026 no emulador (celular 1080×2400 e Pixel
/// Tablet, temas claro e escuro), cada um preso a um teste: texto cortado
/// com "…", campos desalinhados, valor em cima da régua, planta da tela
/// pela metade, contraste da chave desligada, textos do Flutter em inglês.
///
/// A janela é medida em dp (densidade 1). 320 é o celular pequeno, 360 o
/// comum, 390 o Pixel 7 e 1280 × 800 o tablet deitado.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  late Directory dir;

  // As fontes de verdade (IBM Plex), e não a de teste, em que cada letra é
  // um quadrado: "cortado com …" depende da largura real do texto.
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
    dir = await Directory.systemTemp.createTemp('ihm_qa_visual');
  });

  tearDown(() async {
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

  NavigatorState root(WidgetTester tester) => tester.state<NavigatorState>(find.byType(Navigator).first);

  Future<void> push(WidgetTester tester, Widget page) async {
    unawaited(root(tester).push(MaterialPageRoute<void>(builder: (_) => page)));
    await live(tester, 700);
  }

  /// Abre a configuração de um elemento da tela de operação da demonstração.
  Future<void> configure(WidgetTester tester, String elementId) async {
    await push(tester, const ScreenEditorPage(screenId: DemoProject.operationScreenId));
    await tester.ensureVisible(find.byKey(ValueKey('ed-$elementId')));
    await live(tester, 200);
    await tester.tap(find.byKey(ValueKey('ed-$elementId')));
    await live(tester, 300);
    await tester.tap(find.text('Configurar'));
    await live(tester, 700);
  }

  /// O texto foi cortado com "…"? (RenderParagraph de uma linha só.)
  bool cut(WidgetTester tester, Finder text) => tester.renderObject<RenderParagraph>(text).didExceedMaxLines;

  for (final width in [320.0, 360.0, 390.0]) {
    group('${width.toInt()} dp', () {
      final phone = Size(width, 800);

      testWidgets('indicador de estado: "Código" inteiro e na altura do campo de texto', (tester) async {
        final c = await boot(tester, phone);
        await configure(tester, 'op_status');
        final code = find.byKey(const ValueKey('estado-codigo-0'));
        await tester.ensureVisible(code);
        await live(tester, 300);
        expect(cut(tester, find.descendant(of: code, matching: find.text('Código'))), isFalse, reason: 'era "Có…"');
        final codeBox = tester.getRect(find.descendant(of: code, matching: find.byType(InputDecorator)));
        final textBox = tester.getRect(find.descendant(of: find.byKey(const ValueKey('estado-texto-0')), matching: find.byType(InputDecorator)));
        expect(codeBox.top, closeTo(textBox.top, 0.5));
        expect(codeBox.height, closeTo(textBox.height, 0.5));
        await shutdown(tester, c);
      });

      testWidgets('medidor: rótulos das faixas inteiros', (tester) async {
        final c = await boot(tester, phone);
        await configure(tester, 'op_temp');
        for (final (key, label) in [('faixa-atencao', 'Atenção'), ('faixa-alarme-medidor', 'Alarme')]) {
          // Rola até o campo: com a faixa do topo sempre reservada, a folha
          // é mais baixa e a lista ainda não montou a seção das faixas.
          await tester.scrollUntilVisible(find.byKey(ValueKey(key)), 200,
              scrollable: find.descendant(of: find.byType(BottomSheet), matching: find.byType(Scrollable)).first);
          await live(tester, 200);
          expect(cut(tester, find.descendant(of: find.byKey(ValueKey(key)), matching: find.text(label))), isFalse, reason: label);
        }
        await shutdown(tester, c);
      });

      testWidgets('medidor: o valor fica dentro das marcas da régua', (tester) async {
        final c = await boot(tester, phone);
        await push(tester, const ScreenRunPage(screenId: DemoProject.operationScreenId));
        final box = find.byKey(const ValueKey('valor-medidor'));
        await tester.ensureVisible(box);
        await live(tester, 400);
        // A mesma conta do pintor: centro, raio e espessura do arco, e o fim
        // de dentro das marcas grandes da régua.
        final face = tester.getRect(find.ancestor(of: box, matching: find.byType(Stack)).first);
        final side = math.min(face.width, face.height * 1.15);
        final stroke = (side * 0.085).clamp(5.0, 13.0);
        final radius = side / 2 - stroke * 1.6;
        final center = Offset(face.left + face.width / 2, face.top + face.height * 0.56);
        final ticksInner = radius - stroke * 0.5 - 3 - stroke * 0.7;
        final text = tester.getRect(find.descendant(of: box, matching: find.byType(RichText)));
        for (final corner in [text.topLeft, text.topRight, text.bottomLeft, text.bottomRight]) {
          expect((corner - center).distance, lessThan(ticksInner), reason: '"${tester.widget<RichText>(find.descendant(of: box, matching: find.byType(RichText))).text.toPlainText()}" encosta na régua');
        }
        await shutdown(tester, c);
      });

      testWidgets('variável calculada: rótulo do primeiro campo de "Mais opções" não é cortado', (tester) async {
        final c = await boot(tester, phone);
        await push(tester, const CalcTagFormPage());
        await tester.ensureVisible(find.text('Mais opções'));
        await live(tester, 200);
        await tester.tap(find.text('Mais opções'));
        await live(tester, 900);
        await tester.enterText(find.byKey(const ValueKey('campo-unidade-calculada')), 'un/h');
        await live(tester, 300);
        final header = tester.getRect(find.ancestor(of: find.text('Mais opções'), matching: find.byType(ListTile)).first);
        final label = tester.getRect(find.descendant(of: find.byKey(const ValueKey('campo-unidade-calculada')), matching: find.text('Unidade')));
        expect(label.top, greaterThanOrEqualTo(header.bottom), reason: 'o rótulo flutua acima da caixa e a seção o cortava');
        await shutdown(tester, c);
      });

      testWidgets('campo com − e +: a dica longa não acaba em "…"', (tester) async {
        const helper = 'O endereço dele na linha RS-485. Vários na mesma linha: um cadastro por ID, mesmo adaptador.';
        final ctrl = TextEditingController(text: '1');
        addTearDown(ctrl.dispose);
        tester.view.physicalSize = phone;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MaterialApp(
          theme: Ind.theme,
          home: Scaffold(body: Padding(padding: const EdgeInsets.all(20), child: StepperField(label: 'ID do escravo', controller: ctrl, helper: helper))),
        ));
        expect(cut(tester, find.text(helper)), isFalse);
      });

      testWidgets('campo com − e +: o rótulo longo encolhe e cabe inteiro, sem "…"', (tester) async {
        // "Tempo de resposta (ms)" saía "Tempo de respos…" em 320 dp em todo
        // "Mais opções" de equipamento.
        const label = 'Tempo de resposta (ms)';
        final ctrl = TextEditingController(text: '1500');
        addTearDown(ctrl.dispose);
        tester.view.physicalSize = phone;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MaterialApp(
          theme: Ind.theme,
          home: Scaffold(body: Padding(padding: const EdgeInsets.all(20), child: StepperField(label: label, controller: ctrl))),
        ));
        expect(cut(tester, find.text(label)), isFalse, reason: 'terminava em "…"');
        final text = tester.getRect(find.text(label));
        final field = tester.getRect(find.byType(InputDecorator));
        expect(text.left, greaterThanOrEqualTo(field.left - 0.5));
        expect(text.right, lessThanOrEqualTo(field.right + 0.5), reason: 'o rótulo inteiro dentro do campo');
        expect(text.height, greaterThanOrEqualTo(9), reason: 'encolhe, mas continua legível');
      });
    });
  }

  // Duas colunas a partir de 340 dp de largura útil (Pixel 7: 350; tablet
  // com formulário de 640).
  for (final box in [350.0, 640.0]) {
    testWidgets('cartões de escolha em ${box.toInt()} dp: os da mesma linha com a mesma altura', (tester) async {
      tester.view.physicalSize = Size(box + 40, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: Ind.theme,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: box,
              child: ChoiceCards<int>(
                options: const [
                  ChoiceOption(value: 1, title: 'Na rede', subtitle: 'Modbus TCP', icon: Icons.router_outlined),
                  ChoiceOption(value: 2, title: 'Cabo USB', subtitle: 'RS-485 · RS-232 · RTU · e um texto mais longo', icon: Icons.usb_rounded),
                  ChoiceOption(value: 3, title: 'Demonstração', subtitle: 'Simulada', icon: Icons.smart_toy_outlined),
                ],
                selected: 1,
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ));
      final a = tester.getRect(find.byKey(const ValueKey('opcao-1')));
      final b = tester.getRect(find.byKey(const ValueKey('opcao-2')));
      expect(a.top, closeTo(b.top, 0.5), reason: 'lado a lado');
      expect(a.height, closeTo(b.height, 0.5), reason: '"Na rede" ficava mais baixo que "Cabo USB"');
      // O que sobra na última linha ocupa só a sua coluna.
      expect(tester.getRect(find.byKey(const ValueKey('opcao-3'))).width, closeTo(a.width, 0.5));
    });
  }

  testWidgets('planta da tela na grade fina mostra o mesmo pedaço que na normal', (tester) async {
    final c = await boot(tester, const Size(390, 844));
    Finder blocks() => find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('miniatura-op_'));
    final normal = blocks().evaluate().length;
    expect(normal, greaterThan(3));
    final screen = c.project.screens.firstWhere((s) => s.id == DemoProject.operationScreenId);
    c.saveScreen(screen.withColumns(12)!);
    await live(tester, 400);
    expect(blocks().evaluate().length, normal, reason: 'com 5 linhas finas a planta mostrava só a metade de cima');
    await shutdown(tester, c);
  });

  test('chave desligada com contorno que se vê, nos dois temas (3:1)', () {
    double lum(Color c) => c.computeLuminance();
    double contrast(Color a, Color b) {
      final (x, y) = (lum(a), lum(b));
      return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
    }

    for (final p in [IndPalette.claro, IndPalette.escuro]) {
      Ind.use(p);
      final outline = Ind.theme.switchTheme.trackOutlineColor!.resolve(<WidgetState>{})!;
      expect(contrast(outline, p.bg), greaterThanOrEqualTo(3), reason: '${p.name}: fundo');
      expect(contrast(outline, p.surface), greaterThanOrEqualTo(3), reason: '${p.name}: cartão');
    }
    Ind.use(IndPalette.escuro);
  });

  testWidgets('textos do próprio Flutter em português (dicas, licenças, leitor de tela)', (tester) async {
    final c = await boot(tester, const Size(390, 844));
    final l = MaterialLocalizations.of(tester.element(find.byType(Shell)));
    expect(l.backButtonTooltip, 'Voltar');
    expect(l.showMenuTooltip, isNot('Show menu'));
    expect(l.licensesPageTitle, 'Licenças');
    await shutdown(tester, c);
  });

  testWidgets('tablet: na lista de alarmes, número e unidade não se separam na quebra de linha', (tester) async {
    final c = await boot(tester, const Size(1280, 800));
    final memory = DemoRegistry.forDevice(DemoProject.deviceId).memory;
    // A 150 m/min o motor passa de 75 °C em ~30 s.
    memory.pokeRegister(ModbusArea.holdingRegister, DemoMap.hrSpeedSetpoint, 150);
    memory.pokeBit(ModbusArea.coil, DemoMap.coilRun, true);
    await live(tester, 40000);
    await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('Alarmes')));
    await live(tester, 800);
    final line = find.textContaining('Temperatura do motor · agora');
    expect(line, findsWidgets);
    final text = tester.widget<Text>(line.first).data!;
    expect(text, matches(RegExp('agora [0-9,]+ °C')), reason: 'quebrava entre "81,8" e "°C" na coluna de 360 dp');
    await shutdown(tester, c);
  });
}

/// Avança o relógio simulado em passos de 100 ms (varredura e demo andam).
Future<void> live(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
