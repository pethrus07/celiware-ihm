import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/core/theme/app_theme.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/hmi_screen.dart';
import 'package:ihm/screens/alarms_page.dart';
import 'package:ihm/screens/devices/device_form_page.dart';
import 'package:ihm/screens/editor/element_config_sheet.dart';
import 'package:ihm/screens/editor/screen_editor_page.dart';
import 'package:ihm/screens/shell.dart';
import 'package:ihm/screens/tags/tag_form_page.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:ihm/widgets/common/adaptive.dart';
import 'package:ihm/widgets/hmi/hmi_canvas.dart';
import 'package:ihm/widgets/tour/tour.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tablet (etapa 4, TB-1 a TB-6; docs/REQUISITOS-ETAPA4.md §5.2), com a
/// máquina de demonstração e o relógio simulado — mesmo esquema de
/// `app_flow_test.dart`. A janela é medida em dp (densidade 1): 390 é o
/// celular, 600 o tablet pequeno em pé, 840 o começo de dois painéis e 1280
/// o tablet deitado.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  const phone = Size(390, 844);
  const small = Size(600, 960);
  const medium = Size(700, 1000);
  const wide = Size(840, 1180);
  const tablet = Size(1280, 800);

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

  Future<void> resize(WidgetTester tester, Size dp) async {
    tester.view.physicalSize = dp;
    await live(tester, 400);
  }

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

  /// Abre uma área da casca pela barra ou pelo trilho, o que estiver à vista.
  Future<void> area(WidgetTester tester, String label) async {
    final rail = find.byType(NavigationRail);
    final host = rail.evaluate().isNotEmpty ? rail : find.byType(NavigationBar);
    await tester.tap(find.descendant(of: host, matching: find.text(label)));
    await live(tester, 600);
  }

  String nameField(WidgetTester tester, String key) => tester.widget<TextFormField>(find.byKey(ValueKey(key))).controller!.text;

  group('TB-1 · trilho lateral', () {
    for (final (size, rail) in [(phone, false), (const Size(844, 390), false), (small, true), (wide, true), (tablet, true)]) {
      testWidgets('${size.width.toInt()}×${size.height.toInt()}: ${rail ? 'trilho' : 'barra embaixo'}', (tester) async {
        final c = await boot(tester, size);
        expect(find.byType(NavigationRail), rail ? findsOneWidget : findsNothing);
        expect(find.byType(NavigationBar), rail ? findsNothing : findsOneWidget);
        // O tutorial "Primeiros passos" aponta para a barra ou para o trilho.
        final shell = tester.state<ShellState>(find.byType(Shell));
        expect(shell.navKey.currentContext?.widget, rail ? isA<NavigationRail>() : isA<NavigationBar>());
        await shutdown(tester, c);
      });
    }

    testWidgets('o passo "O caminho" realça o trilho e o balão vai ao lado dele', (tester) async {
      final c = await boot(tester, tablet);
      final shell = tester.state<ShellState>(find.byType(Shell));
      // Só o passo do trilho (com Voltar/Próximo, a fonte de teste — mais
      // larga que a IBM Plex — não cabe no balão).
      final passo = Tours.inicio(screens: shell.screensKey, nav: shell.navKey, add: shell.addScreenKey, help: shell.helpKey).steps[3];
      tester.state<TourHostState>(find.byType(TourHost).first).start(TourSpec(id: 'trilho', version: 1, title: 'Trilho', steps: [passo]));
      await live(tester, 600);
      expect(find.text('O caminho'), findsOneWidget);
      final rail = tester.getRect(find.byType(NavigationRail));
      final balloon = tester.getRect(find.byKey(const ValueKey('tour-balao')));
      expect(balloon.left, greaterThan(rail.right), reason: 'o balão não cobre o trilho');
      await tester.tap(find.text('Entendi'));
      await live(tester, 300);
      await shutdown(tester, c);
    });

    testWidgets('girar e voltar mantém a aba escolhida', (tester) async {
      final c = await boot(tester, tablet);
      await area(tester, 'Variáveis');
      await resize(tester, phone);
      expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 2);
      expect(find.widgetWithText(AppBar, 'Variáveis'), findsOneWidget);
      await resize(tester, tablet);
      expect(tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex, 2);
      await shutdown(tester, c);
    });
  });

  group('TB-2 · lista + detalhe', () {
    testWidgets('1280: equipamento abre ao lado, sem empilhar rota, com o item marcado', (tester) async {
      final c = await boot(tester, tablet);
      await area(tester, 'Equipamentos');
      await tester.tap(find.byKey(const ValueKey('equip-${DemoProject.deviceId}')));
      await live(tester, 600);
      expect(find.byKey(const ValueKey('campo-nome-equipamento')), findsOneWidget);
      expect(root(tester).canPop(), isFalse, reason: 'o cadastro mora no painel, não numa rota por cima');
      // A lista continua à vista, à esquerda, e o equipamento aberto fica marcado.
      final card = find.ancestor(of: find.byKey(const ValueKey('equip-${DemoProject.deviceId}')), matching: find.byType(Card));
      expect(tester.getRect(card).right, lessThanOrEqualTo(tester.getRect(find.byKey(const ValueKey('campo-nome-equipamento'))).left));
      expect((tester.widget<Card>(card).shape! as RoundedRectangleBorder).side.color, Ind.accent);
      // Salvar fecha só o painel.
      await tester.tap(find.byKey(const ValueKey('salvar-equipamento')));
      await live(tester, 600);
      expect(find.byKey(const ValueKey('campo-nome-equipamento')), findsNothing);
      expect(find.text('Escolha um equipamento'), findsOneWidget);
      expect(find.byKey(const ValueKey('equip-${DemoProject.deviceId}')), findsOneWidget);
      await shutdown(tester, c);
    });

    testWidgets('840: dois painéis; 600: um painel por vez e o "voltar" fecha o cadastro', (tester) async {
      final c = await boot(tester, wide);
      await area(tester, 'Equipamentos');
      await tester.tap(find.byKey(const ValueKey('equip-${DemoProject.deviceId}')));
      await live(tester, 600);
      expect(find.byKey(const ValueKey('campo-nome-equipamento')), findsOneWidget);
      expect(find.byKey(const ValueKey('equip-${DemoProject.deviceId}')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await live(tester, 600);

      await resize(tester, small);
      await tester.tap(find.byKey(const ValueKey('equip-${DemoProject.deviceId}')));
      await live(tester, 600);
      expect(find.byKey(const ValueKey('campo-nome-equipamento')), findsOneWidget);
      expect(find.byKey(const ValueKey('equip-${DemoProject.deviceId}')), findsNothing, reason: 'um painel por vez');
      expect(find.byType(NavigationRail), findsOneWidget, reason: 'o trilho continua à vista');
      expect(root(tester).canPop(), isFalse);
      await tester.binding.handlePopRoute();
      await live(tester, 600);
      expect(find.byKey(const ValueKey('campo-nome-equipamento')), findsNothing);
      expect(find.byKey(const ValueKey('equip-${DemoProject.deviceId}')), findsOneWidget);
      await shutdown(tester, c);
    });

    testWidgets('390: tocar empilha a página por cima, como sempre', (tester) async {
      final c = await boot(tester, phone);
      await area(tester, 'Equipamentos');
      await tester.tap(find.byKey(const ValueKey('equip-${DemoProject.deviceId}')));
      await live(tester, 700);
      expect(find.byKey(const ValueKey('campo-nome-equipamento')), findsOneWidget);
      expect(root(tester).canPop(), isTrue);
      await shutdown(tester, c);
    });

    testWidgets('variáveis: tocar noutra troca o detalhe; com alteração, pergunta antes', (tester) async {
      final c = await boot(tester, tablet);
      final a = c.project.tags[0], b = c.project.tags[1];
      await area(tester, 'Variáveis');
      await tester.tap(find.byKey(ValueKey('var-${a.id}')));
      await live(tester, 600);
      expect(nameField(tester, 'campo-nome-variavel'), a.name);
      expect(tester.widget<ListTile>(find.byKey(ValueKey('var-${a.id}'))).selected, isTrue);

      // Sem alteração: troca direto.
      await tester.tap(find.byKey(ValueKey('var-${b.id}')));
      await live(tester, 600);
      expect(nameField(tester, 'campo-nome-variavel'), b.name);
      expect(tester.widget<ListTile>(find.byKey(ValueKey('var-${b.id}'))).selected, isTrue);
      expect(tester.widget<ListTile>(find.byKey(ValueKey('var-${a.id}'))).selected, isFalse);

      // Com alteração: "Descartar alterações?" antes de trocar.
      await tester.enterText(find.byKey(const ValueKey('campo-nome-variavel')), 'Rascunho');
      await live(tester, 200);
      await tester.tap(find.byKey(ValueKey('var-${a.id}')));
      await live(tester, 400);
      expect(find.byKey(const ValueKey('descartar-alteracoes')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('continuar-editando')));
      await live(tester, 400);
      expect(nameField(tester, 'campo-nome-variavel'), 'Rascunho');

      await tester.tap(find.byKey(ValueKey('var-${a.id}')));
      await live(tester, 400);
      await tester.tap(find.byKey(const ValueKey('descartar')));
      await live(tester, 600);
      expect(nameField(tester, 'campo-nome-variavel'), a.name);
      expect(c.project.tag(b.id)!.name, b.name, reason: 'descartado, não gravado');
      expect(root(tester).canPop(), isFalse);
      await shutdown(tester, c);
    });

    testWidgets('alarmes: o tocado abre ao lado com o valor de agora; no celular, sem detalhe', (tester) async {
      final c = await boot(tester, tablet);
      DemoRegistry.forDevice(DemoProject.deviceId).memory.pokeBit(ModbusArea.discreteInput, DemoMap.diDoorClosed, false);
      await live(tester, 2000);
      unawaited(root(tester).push(AlarmsPage.route()));
      await live(tester, 700);
      // Sem toque, o detalhe mostra o mais grave.
      final detail = find.byKey(const ValueKey('detalhe-alarme'));
      expect(detail, findsOneWidget);
      expect(find.descendant(of: detail, matching: find.text('Porta aberta')), findsOneWidget);
      expect(find.descendant(of: detail, matching: find.byKey(const ValueKey('detalhe-alarme-valor'))), findsOneWidget);
      expect(find.descendant(of: detail, matching: find.text('Reconhecer')), findsOneWidget);

      // Reconhecer pelo cartão da lista: o detalhe acompanha.
      await tester.tap(find.byKey(const ValueKey('reconhecer-regra:demo_porta:al_porta')));
      await live(tester, 300);
      expect(find.descendant(of: detail, matching: find.text('Reconhecer')), findsNothing);
      expect(find.descendant(of: detail, matching: find.textContaining('Reconhecido')), findsWidgets);

      // No celular: a lista como sempre, sem painel.
      await resize(tester, phone);
      expect(detail, findsNothing);
      expect(find.byKey(const ValueKey('alarme-regra:demo_porta:al_porta')), findsOneWidget);
      await shutdown(tester, c);
    });
  });

  group('TB-3 · formulários com no máximo 640 dp', () {
    for (final size in [phone, small, wide, tablet]) {
      testWidgets('${size.width.toInt()} dp', (tester) async {
        final c = await boot(tester, size);
        unawaited(root(tester).push(MaterialPageRoute<void>(builder: (_) => const DeviceFormPage())));
        await live(tester, 700);
        final field = tester.getRect(find.byKey(const ValueKey('campo-nome-equipamento')));
        final save = tester.getRect(find.byKey(const ValueKey('salvar-equipamento')));
        if (size.width < 680) {
          // Celular e tablet estreito: igual a antes, de margem a margem.
          expect(field.width, closeTo(size.width - 2 * Ind.page, 0.5));
        } else {
          expect(field.width, lessThanOrEqualTo(FormWidth.maxWidth));
          expect(field.center.dx, closeTo(size.width / 2, 0.5), reason: 'centralizado');
          expect(save.width, lessThanOrEqualTo(FormWidth.maxWidth + 2 * Ind.page));
        }
        root(tester).pop();
        await live(tester, 400);
        unawaited(root(tester).push(MaterialPageRoute<void>(builder: (_) => const TagFormPage())));
        await live(tester, 700);
        expect(tester.getRect(find.byKey(const ValueKey('campo-nome-variavel'))).width, lessThanOrEqualTo(FormWidth.maxWidth));
        await shutdown(tester, c);
      });
    }
  });

  group('TB-4 · editor com painel lateral', () {
    Future<void> openEditor(WidgetTester tester) async {
      unawaited(root(tester).push(MaterialPageRoute<void>(builder: (_) => const ScreenEditorPage(screenId: DemoProject.operationScreenId))));
      await live(tester, 700);
    }

    testWidgets('1280: configuração num painel de ~30%, trocando sem fechar', (tester) async {
      final c = await boot(tester, tablet);
      await openEditor(tester);
      // Sem seleção, o painel mostra as regras da tela.
      expect(find.text('Regras da tela'), findsOneWidget);
      expect(find.text('Configurar'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('ed-op_status')));
      await live(tester, 300);
      final panel = find.byType(ElementConfigSheet);
      expect(panel, findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing, reason: 'painel fixo, não folha que sobe');
      final w = tester.getRect(panel).width;
      expect(w, closeTo(tablet.width * 0.3, 1));
      expect(tester.getRect(panel).right, closeTo(tablet.width, 0.5));

      // Outro elemento: o painel continua aberto e passa a mostrar ele.
      await tester.tap(find.byKey(const ValueKey('ed-op_vel')));
      await live(tester, 300);
      expect(find.byKey(const ValueKey('painel-op_vel')), findsOneWidget);
      expect(find.byType(ElementConfigSheet), findsOneWidget);

      // A grade não fica embaixo do painel.
      expect(tester.getRect(find.byKey(const ValueKey('ed-op_vel'))).right, lessThan(tester.getRect(panel).left));
      await shutdown(tester, c);
    });

    testWidgets('390: sem painel; Configurar abre a folha como antes', (tester) async {
      final c = await boot(tester, phone);
      await openEditor(tester);
      await tester.tap(find.byKey(const ValueKey('ed-op_status')));
      await live(tester, 300);
      expect(find.byType(ElementConfigSheet), findsNothing);
      await tester.tap(find.text('Configurar'));
      await live(tester, 600);
      expect(find.byType(BottomSheet), findsOneWidget);
      await shutdown(tester, c);
    });
  });

  group('TB-5 · grade fina na largura útil', () {
    Future<Rect> draw(WidgetTester tester, Size dp, HmiScreen s) async {
      tester.view.physicalSize = dp;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: HmiCanvas(screen: s))));
      return tester.getRect(find.byKey(ValueKey('el-${s.elements.first.id}')));
    }

    const fina = HmiScreen(id: 'f', name: 'Fina', columns: 12, elements: [
      HmiElement(id: 'larga', type: ElementType.label, x: 0, y: 0, w: 12, h: 1, props: {'text': 'Larga'}),
    ]);
    const normal = HmiScreen(id: 'n', name: 'Normal', elements: [
      HmiElement(id: 'larga', type: ElementType.label, x: 0, y: 0, w: 6, h: 1, props: {'text': 'Larga'}),
    ]);

    testWidgets('tablet deitado: a fina ocupa até 1.200 dp; a normal segue centralizada', (tester) async {
      final r = await draw(tester, tablet, fina);
      expect(r.width + HmiCanvas.gapFor(HmiCanvas.maxFineWidth / 12), closeTo(HmiCanvas.maxFineWidth, 1));
      final n = await draw(tester, tablet, normal);
      expect(n.width, lessThanOrEqualTo(6 * HmiCanvas.maxCell));
      expect(n.center.dx, closeTo(tablet.width / 2, 1));
    });

    testWidgets('celular deitado: a fina continua presa pela altura', (tester) async {
      final r = await draw(tester, const Size(844, 390), fina);
      expect(r.width, lessThan(844 / 2 + 100), reason: 'pelo menos ~4,5 linhas da grade normal à vista');
    });
  });

  group('TB-6 · girar e redimensionar não perdem estado', () {
    testWidgets('cadastro meio preenchido atravessa 1280 → 700 → 390 → 1280', (tester) async {
      final c = await boot(tester, tablet);
      final t = c.project.tags[0];
      await area(tester, 'Variáveis');
      await tester.tap(find.byKey(ValueKey('var-${t.id}')));
      await live(tester, 600);
      await tester.enterText(find.byKey(const ValueKey('campo-nome-variavel')), 'Meio preenchido');
      await live(tester, 200);
      final state = tester.state(find.byType(TagFormPage));

      await resize(tester, medium);
      expect(nameField(tester, 'campo-nome-variavel'), 'Meio preenchido');
      expect(find.byKey(ValueKey('var-${t.id}')), findsNothing, reason: 'um painel por vez');

      await resize(tester, phone);
      expect(nameField(tester, 'campo-nome-variavel'), 'Meio preenchido');
      expect(find.byType(NavigationBar), findsOneWidget);

      await resize(tester, tablet);
      expect(nameField(tester, 'campo-nome-variavel'), 'Meio preenchido');
      expect(find.byKey(ValueKey('var-${t.id}')), findsOneWidget, reason: 'a lista volta ao lado');
      expect(identical(tester.state(find.byType(TagFormPage)), state), isTrue, reason: 'o mesmo cadastro, não um novo');
      expect(c.project.tag(t.id)!.name, t.name, reason: 'nada gravado sem Salvar');
      await shutdown(tester, c);
    });

    testWidgets('cadastro aberto no celular continua aberto ao virar tablet', (tester) async {
      final c = await boot(tester, phone);
      await area(tester, 'Equipamentos');
      await tester.tap(find.byKey(const ValueKey('equip-${DemoProject.deviceId}')));
      await live(tester, 700);
      await tester.enterText(find.byKey(const ValueKey('campo-nome-equipamento')), 'CLP novo');
      await live(tester, 200);
      await resize(tester, tablet);
      expect(nameField(tester, 'campo-nome-equipamento'), 'CLP novo');
      await resize(tester, phone);
      expect(nameField(tester, 'campo-nome-equipamento'), 'CLP novo');
      await shutdown(tester, c);
    });

    testWidgets('editor: seleção e rolagem (em linhas da grade) sobrevivem ao girar', (tester) async {
      final c = await boot(tester, phone);
      unawaited(root(tester).push(MaterialPageRoute<void>(builder: (_) => const ScreenEditorPage(screenId: DemoProject.operationScreenId))));
      await live(tester, 700);
      await tester.tap(find.byKey(const ValueKey('ed-op_status')));
      await live(tester, 300);
      final scroll = find.descendant(of: find.byType(HmiCanvas), matching: find.byType(Scrollable));
      ScrollPosition pos() => tester.state<ScrollableState>(scroll).position;
      // "Status" fica na coluna 0 e "Velocidade" na 3: a distância é 3 células.
      double cell() => (tester.getRect(find.byKey(const ValueKey('ed-op_vel'))).left - tester.getRect(find.byKey(const ValueKey('ed-op_status'))).left) / 3;
      pos().jumpTo(pos().maxScrollExtent / 2);
      await live(tester, 200);
      final rowsBefore = pos().pixels / cell();

      await resize(tester, tablet);
      expect(find.byKey(const ValueKey('painel-op_status')), findsOneWidget, reason: 'a seleção continua');
      expect(pos().pixels / cell(), closeTo(rowsBefore, 0.2), reason: 'a mesma linha no topo');

      await resize(tester, phone);
      expect(pos().pixels / cell(), closeTo(rowsBefore, 0.2));
      expect(find.text('Configurar'), findsOneWidget, reason: 'continua selecionado');
      await shutdown(tester, c);
    });
  });
}

/// Avança o relógio simulado em passos de 100 ms (varredura e demo andam).
Future<void> live(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
