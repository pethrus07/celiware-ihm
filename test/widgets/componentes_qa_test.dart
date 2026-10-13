import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/theme/app_theme.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/hmi_screen.dart';
import 'package:ihm/screens/editor/screen_editor_page.dart';
import 'package:ihm/screens/screen_run_page.dart';
import 'package:ihm/screens/tags/calc_tag_form_page.dart';
import 'package:ihm/screens/tags/mqtt_tag_fields.dart';
import 'package:ihm/screens/tags/tag_form_page.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:ihm/widgets/common/common.dart';
import 'package:ihm/widgets/hmi/element_catalog.dart';
import 'package:ihm/widgets/hmi/elements/chart_elements.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Pontos da rodada de QA visual de 12/10/2026 que ficaram "para decidir" e
/// foram decididos pelo melhor padrão: rótulo da lâmpada sem "…", pergunta
/// de descarte com os botões alinhados, barra neutra (cor só para estado),
/// título do editor inteiro, um desenho só de − / + e de cabeçalho de seção,
/// régua do gráfico sem casa decimal à toa e barras com a hora de verdade.
///
/// Tudo medido com as fontes de verdade (IBM Plex), em dp, de 320 a 412.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  late Directory dir;

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
      for (final (id, _, _) in Tours.catalog) 'tour:v1:$id': true,
    });
    dir = await Directory.systemTemp.createTemp('ihm_qa_componentes');
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
    await live(tester, 900);
  }

  /// O parágrafo foi cortado com "…" (ou perdeu linhas)?
  bool cut(WidgetTester tester, Finder text) => tester.renderObject<RenderParagraph>(text).didExceedMaxLines;

  /// Tamanho de letra de fato na tela (depois do encolhe-para-caber).
  double shownSize(WidgetTester tester, Finder text) {
    final natural = tester.getSize(text).height;
    final shown = tester.getRect(text).height;
    final style = tester.renderObject<RenderParagraph>(text).text.style!;
    return style.fontSize! * shown / natural;
  }

  /// Tela de teste com os elementos no tamanho padrão do catálogo.
  const qaScreen = 'qa_componentes';
  HmiScreen screenWithDefaults() => const HmiScreen(id: qaScreen, name: 'QA componentes', elements: [
        HmiElement(id: 'q_faca', type: ElementType.lamp, x: 0, y: 0, w: 3, h: 1, props: {'tagId': 'demo_faca', 'label': 'Faca acionada', 'onText': 'LIGADO', 'offText': 'DESLIGADO', 'color': 'green'}),
        HmiElement(id: 'q_porta', type: ElementType.lamp, x: 3, y: 0, w: 3, h: 1, props: {'tagId': 'demo_porta', 'label': 'Porta fechada', 'onText': 'FECHADA', 'offText': 'ABERTA', 'color': 'green'}),
        HmiElement(id: 'q_status', type: ElementType.multistate, x: 0, y: 1, w: 3, h: 1, props: {
          'tagId': 'demo_status',
          'label': 'Status da máquina',
          'states': [
            {'value': 0, 'text': 'PARADA', 'color': 'neutral'},
            {'value': 1, 'text': 'EM CICLO', 'color': 'green'},
            {'value': 2, 'text': 'ALARME', 'color': 'red'},
          ],
        }),
        HmiElement(id: 'q_papel', type: ElementType.lamp, x: 3, y: 1, w: 3, h: 1, props: {'tagId': 'demo_papel', 'label': 'Papel presente', 'onText': 'PRESENTE', 'offText': 'FALTA', 'color': 'green'}),
        HmiElement(id: 'q_temp', type: ElementType.value, x: 0, y: 2, w: 3, h: 2, props: {'tagId': 'demo_temp', 'label': 'Temperatura do motor'}),
        HmiElement(id: 'q_vel', type: ElementType.value, x: 3, y: 2, w: 3, h: 2, props: {'tagId': 'demo_vel', 'label': 'Velocidade'}),
        HmiElement(id: 'q_tensao', type: ElementType.bar, x: 0, y: 4, w: 6, h: 1, props: {'tagId': 'demo_tensao', 'label': 'Tensão do papel', 'min': 0, 'max': 100}),
      ]);

  // ── 1. Lâmpada e indicadores de uma linha ─────────────────────────────────
  for (final width in [320.0, 360.0, 390.0, 412.0]) {
    testWidgets('${width.toInt()} dp: lâmpada, indicador e mostrador no tamanho padrão com o rótulo inteiro e o estado legível', (tester) async {
      final c = await boot(tester, Size(width, 900));
      c.saveScreen(screenWithDefaults());
      await live(tester, 300);
      await push(tester, const ScreenRunPage(screenId: qaScreen));
      await live(tester, 600);
      for (final (id, label) in [
        ('q_faca', 'FACA ACIONADA'),
        ('q_porta', 'PORTA FECHADA'),
        ('q_status', 'STATUS DA MÁQUINA'),
        ('q_papel', 'PAPEL PRESENTE'),
        ('q_temp', 'TEMPERATURA DO MOTOR'),
        ('q_tensao', 'TENSÃO DO PAPEL'),
      ]) {
        final text = find.descendant(of: find.byKey(ValueKey('el-$id')), matching: find.text(label));
        expect(text, findsOneWidget, reason: id);
        expect(cut(tester, text), isFalse, reason: '$label cortado em ${width.toInt()} dp (era "FACA ACIONA…")');
        expect(shownSize(tester, text), greaterThanOrEqualTo(11 * 0.7 - 0.01), reason: '$label miúdo demais');
      }
      // A palavra do estado: era "DESLIGADO" a ~7 pt ao lado do rótulo.
      final state = find.descendant(of: find.byKey(const ValueKey('el-q_faca')), matching: find.text('DESLIGADO'));
      expect(shownSize(tester, state), greaterThanOrEqualTo(12), reason: 'estado da lâmpada legível');
      await shutdown(tester, c);
    });
  }

  for (final width in [320.0, 360.0, 390.0]) {
    testWidgets('${width.toInt()} dp: lâmpada 2×2 com a palavra do estado embaixo do LED (só a cor falha para daltônico)', (tester) async {
      final c = await boot(tester, Size(width, 800));
      await push(tester, const ScreenRunPage(screenId: DemoProject.operationScreenId));
      final lamp = find.byKey(const ValueKey('el-op_alarme'));
      final word = find.descendant(of: lamp, matching: find.text('OK'));
      expect(word, findsOneWidget, reason: 'no 2×2 do celular só o LED aparecia');
      expect(shownSize(tester, word), greaterThanOrEqualTo(12));
      await shutdown(tester, c);
    });
  }

  // ── 2. "Descartar alterações?" ─────────────────────────────────────────────
  for (final width in [320.0, 360.0, 390.0, 1280.0]) {
    testWidgets('${width.toInt()} dp: "Descartar alterações?" com os três botões alinhados (linha à direita ou pilha de largura toda)', (tester) async {
      final c = await boot(tester, Size(width, 800));
      await push(tester, const CalcTagFormPage());
      await tester.enterText(find.byKey(const ValueKey('campo-nome-calculada')), 'Rendimento');
      await live(tester, 200);
      await tester.tap(find.byTooltip('Voltar'));
      await live(tester, 500);
      expect(find.byKey(const ValueKey('descartar-alteracoes')), findsOneWidget);
      final keep = tester.getRect(find.byKey(const ValueKey('continuar-editando')));
      final drop = tester.getRect(find.byKey(const ValueKey('descartar')));
      final save = tester.getRect(find.byKey(const ValueKey('salvar-e-sair')));
      for (final r in [keep, drop, save]) {
        expect(r.height, greaterThanOrEqualTo(Ind.minTouch - 0.01), reason: 'alvo de toque');
      }
      final row = (keep.center.dy - save.center.dy).abs() < 0.5;
      if (row) {
        // Numa linha: fechar · destrutiva · principal, da esquerda para a direita.
        expect(drop.center.dy, closeTo(save.center.dy, 0.5));
        expect(keep.right, lessThan(drop.left));
        expect(drop.right, lessThan(save.left));
      } else {
        // Empilhados: mesma largura e mesmas bordas, a principal em cima.
        for (final r in [keep, drop]) {
          expect(r.left, closeTo(save.left, 0.5), reason: 'borda esquerda alinhada');
          expect(r.right, closeTo(save.right, 0.5), reason: 'borda direita alinhada (era escada)');
        }
        expect(save.top, lessThan(drop.top));
        expect(drop.top, lessThan(keep.top));
      }
      if (width <= 390) expect(row, isFalse, reason: 'no celular os três não cabem numa linha');
      if (width >= 1280) expect(row, isTrue, reason: 'no tablet cabem');
      // Destrutiva em vermelho.
      final dropText = tester.renderObject<RenderParagraph>(find.descendant(of: find.byKey(const ValueKey('descartar')), matching: find.text('Descartar')));
      expect(dropText.text.style?.color, Ind.textFor(Ind.alarm));
      // E continua funcionando: ficar fecha a pergunta e mantém o formulário.
      await tester.tap(find.byKey(const ValueKey('continuar-editando')));
      await live(tester, 400);
      expect(find.byKey(const ValueKey('descartar-alteracoes')), findsNothing);
      expect(find.byKey(const ValueKey('campo-nome-calculada')), findsOneWidget);
      await shutdown(tester, c);
    });
  }

  // ── 3. Barra neutra ────────────────────────────────────────────────────────
  /// Cores do preenchimento da barra (o degradê dentro do trilho).
  List<Color> barFill(WidgetTester tester, String elementId) {
    final boxes = tester.widgetList<Container>(find.descendant(of: find.byKey(ValueKey('el-$elementId')), matching: find.byType(Container)));
    for (final b in boxes) {
      final d = b.decoration;
      if (d is BoxDecoration && d.gradient is LinearGradient) return (d.gradient! as LinearGradient).colors;
    }
    fail('preenchimento da barra não achado');
  }

  bool sameRgb(Color a, Color b) => (a.r - b.r).abs() < 0.01 && (a.g - b.g).abs() < 0.01 && (a.b - b.b).abs() < 0.01;

  testWidgets('barra nasce neutra (cor só para estado) e só ganha cor dentro da faixa', (tester) async {
    final c = await boot(tester, const Size(360, 800));
    // A barra recém-colocada na tela, com as propriedades de fábrica do catálogo.
    final fresh = ElementCatalog.defaultProps(ElementType.bar, tag: c.project.tag('demo_tensao'));
    c.saveScreen(HmiScreen(id: qaScreen, name: 'Barras', elements: [
      HmiElement(id: 'b_nova', type: ElementType.bar, x: 0, y: 0, w: 6, h: 1, props: fresh),
      // Barra gravada antes, com o azul de fábrica: a cor antiga é ignorada.
      HmiElement(id: 'b_antiga', type: ElementType.bar, x: 0, y: 1, w: 6, h: 1, props: {...fresh, 'color': 'blue'}),
      // Faixas: atenção a partir de 10, alarme a partir de 20 — a tensão da demonstração (~50%) passa disso.
      HmiElement(id: 'b_faixa', type: ElementType.bar, x: 0, y: 2, w: 6, h: 1, props: {...fresh, 'warn': 10, 'alarm': 20}),
    ]));
    await live(tester, 300);
    await push(tester, const ScreenRunPage(screenId: qaScreen));
    await live(tester, 1500);
    for (final id in ['b_nova', 'b_antiga']) {
      final fill = barFill(tester, id).last;
      expect(sameRgb(fill, StateColor.blue.color), isFalse, reason: '$id: nascia azul (cor de informação)');
      expect(sameRgb(fill, Ind.text), isTrue, reason: '$id: neutra, o tom do texto, como o arco do medidor');
    }
    expect(sameRgb(barFill(tester, 'b_faixa').last, Ind.alarm), isTrue, reason: 'dentro da faixa de alarme, vermelha');
    await shutdown(tester, c);
  });

  // ── 4. Título do editor ────────────────────────────────────────────────────
  for (final width in [360.0, 390.0]) {
    testWidgets('${width.toInt()} dp: título do editor com o nome da tela inteiro e o Concluir com alvo de 48 dp', (tester) async {
      final c = await boot(tester, Size(width, 800));
      for (final name in ['Cortadora — operação', 'Linha 2 — envasadora A', 'Embaladora automática', 'Forno de secagem nº 3']) {
        final op = c.project.screen(DemoProject.operationScreenId)!;
        c.saveScreen(op.copyWith(name: name));
        await live(tester, 200);
        await push(tester, const ScreenEditorPage(screenId: DemoProject.operationScreenId));
        final title = find.descendant(of: find.byType(AppBar), matching: find.text(name));
        expect(title, findsOneWidget);
        expect(cut(tester, title), isFalse, reason: '"$name" cortado no editor (era "Cortadora — o…")');
        expect(shownSize(tester, title), greaterThanOrEqualTo(15), reason: 'título legível');
        final done = find.widgetWithText(FilledButton, 'Concluir');
        expect(tester.getSize(done).height, greaterThanOrEqualTo(Ind.minTouch));
        expect(cut(tester, find.descendant(of: done, matching: find.text('Concluir'))), isFalse);
        root(tester).pop();
        await live(tester, 600);
      }
      await shutdown(tester, c);
    });
  }

  // ── 5. Um − / + e um cabeçalho de seção ───────────────────────────────────
  testWidgets('variável: "Casas decimais" com o mesmo − / + do "Quantos valores seguidos"', (tester) async {
    final c = await boot(tester, const Size(360, 800));
    await push(tester, const TagFormPage());
    final form = find.descendant(of: find.byKey(const ValueKey('formulario-variavel')), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('Mais opções'), 200, scrollable: form);
    await live(tester, 200);
    await tester.tap(find.text('Mais opções'));
    await live(tester, 900);
    final minus = find.byKey(const ValueKey('decimais-menos'));
    await tester.scrollUntilVisible(minus, 200, scrollable: form);
    await live(tester, 300);
    expect(tester.widget(minus), isA<StepButton>(), reason: 'era um círculo de contorno (IconButton.outlined)');
    // O − do campo "Quantos valores seguidos", logo abaixo: mesmo tamanho.
    final field = find.ancestor(of: find.text('Quantos valores seguidos'), matching: find.byType(StepperField));
    final fieldMinus = find.descendant(of: field, matching: find.byType(StepButton)).first;
    final fieldPlus = find.descendant(of: field, matching: find.byType(StepButton)).last;
    expect(tester.getSize(minus), tester.getSize(fieldMinus));
    // E na mesma coluna: o − sobre o −, o + sobre o +.
    expect(tester.getRect(minus).left, closeTo(tester.getRect(fieldMinus).left, 0.5));
    expect(tester.getRect(find.byKey(const ValueKey('decimais-mais'))).left, closeTo(tester.getRect(fieldPlus).left, 0.5));
    await shutdown(tester, c);
  });

  testWidgets('MQTT, Mais opções: "Entrega (QoS)" com a mesma letra de "Validade da mensagem"', (tester) async {
    tester.view.physicalSize = const Size(360, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fields = MqttTagFields(null);
    await tester.pumpWidget(MaterialApp(
      theme: Ind.theme,
      home: Scaffold(body: ListView(padding: const EdgeInsets.all(20), children: [
        MqttMoreOptions(fields: fields, writable: true, isBool: true, onChanged: () {}),
      ])),
    ));
    TextStyle styleOf(String text) => tester.renderObject<RenderParagraph>(find.textContaining(RegExp('^${RegExp.escape(text)}\$', caseSensitive: false))).text.style!;
    final reference = styleOf('Validade da mensagem');
    for (final other in ['Entrega (QoS)', 'Gravar liga/desliga como']) {
      final s = styleOf(other);
      expect((s.fontFamily, s.fontSize, s.fontWeight, s.letterSpacing, s.color), (reference.fontFamily, reference.fontSize, reference.fontWeight, reference.letterSpacing, reference.color),
          reason: '"$other" era outro estilo de cabeçalho no mesmo formulário');
    }
  });

  // ── 6. Gráficos ────────────────────────────────────────────────────────────
  test('curva parada em 0: régua de 0 a um número redondo, sem casa decimal (era 0 · 0,50 · 1)', () {
    final canvas = Canvas(ui.PictureRecorder());
    final s = TrendScale.paint(canvas, const Rect.fromLTWH(40, 4, 300, 160), leftData: (0, 0), leftColor: Ind.textMuted, rightColor: Ind.textMuted);
    expect(s.lo, 0);
    expect(s.hi, greaterThanOrEqualTo(10));
    final step = TrendScale.niceStep((s.hi - s.lo) / 4);
    final labels = [for (var v = s.lo; v <= s.hi + 1e-9; v += step) TrendScale.short(v)];
    expect(labels.where((l) => l.contains(',')), isEmpty, reason: '$labels');
  });

  test('curva parada: com limite de alarme, a régua vai até ele; variável inteira nunca ganha passo de 0,5', () {
    expect(TrendScale.range((0, 0), limits: [85]), (0.0, 100.0, 25.0));
    expect(TrendScale.range((0, 0), limits: [20]), (0.0, 20.0, 5.0));
    expect(TrendScale.range((31.7, 31.7)).$1, 0);
    final (lo, hi, step) = TrendScale.range((10, 12), resolution: 1);
    expect(step, greaterThanOrEqualTo(1));
    expect(step, step.roundToDouble());
    expect(lo, lessThanOrEqualTo(10));
    expect(hi, greaterThanOrEqualTo(12));
    // Com casa decimal de verdade, o eixo mostra só as que precisa.
    expect(TrendScale.short(0.5, step: 0.5), '0,5');
    expect(TrendScale.short(0.25, step: 0.25), '0,25');
    expect(TrendScale.short(30, step: 5), '30');
  });

  for (final width in [320.0, 360.0]) {
    testWidgets('${width.toInt()} dp: produção por hora com a hora real embaixo de cada barra, a última é a de agora', (tester) async {
      final c = await boot(tester, Size(width, 800));
      await push(tester, const ScreenRunPage(screenId: DemoProject.operationScreenId));
      final chart = find.byKey(const ValueKey('el-op_hora'));
      await tester.ensureVisible(chart);
      await live(tester, 600);
      final now = DateTime.now().hour;
      String h(int x) => '${(x % 24).toString().padLeft(2, '0')}h';
      // As 8 horas cabem (8 barras): todas aparecem, inteiras.
      for (var i = 0; i < 8; i++) {
        final label = find.descendant(of: chart, matching: find.text(h(now - i)));
        expect(label, findsOneWidget, reason: i == 0 ? 'era "8"' : 'era "${8 - i}"');
        expect(cut(tester, label), isFalse);
      }
      expect(find.descendant(of: chart, matching: find.text('8')), findsNothing);
      expect(BarChartElement.labels(3, hours: true, last: DateTime(2026, 10, 12, 1)), ['23h', '00h', '01h'], reason: 'vira a meia-noite');
      expect(BarChartElement.labels(3, hours: false, last: DateTime(2026)), ['1', '2', '3']);
      await shutdown(tester, c);
    });
  }
}

/// Avança o relógio simulado em passos de 100 ms (varredura e demo andam).
Future<void> live(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
