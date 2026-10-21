import 'dart:async';
import 'dart:convert';
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
import 'package:ihm/models/plant.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/screens/editor/element_config_sheet.dart';
import 'package:ihm/screens/editor/screen_background_section.dart';
import 'package:ihm/screens/editor/screen_editor_page.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:ihm/widgets/hmi/element_catalog.dart';
import 'package:ihm/widgets/hmi/hmi_canvas.dart';
import 'package:ihm/widgets/hmi/hmi_frame.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Imagem de fundo da tela (item 62 da lista do cliente, "sinótico";
/// confirmado pelo Pedro em 21/10/2026): o campo opcional `background` vai e
/// volta pelo arquivo e pela planta, chaves desconhecidas da tela são
/// preservadas, a imagem é reduzida como a do elemento imagem, o desenho é o
/// mesmo no editor e na operação (360 dp e tablet), a imagem fica atenuada só
/// no editor, e "Fundo transparente" só aparece numa tela com imagem.

// PNG de 1×1: o desenho não depende dos pixels — a área sai de width/height.
const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

// Planta da fábrica deitada (2:1) na largura da tela.
const _planta = ScreenBackground(data: _png, width: 1200, height: 600);

// Sinótico na extra-fina: lâmpadas e um valor sobre o desenho.
const _sinotico = HmiScreen(
  id: 'sin',
  name: 'Sinótico',
  columns: HmiScreen.extraFineColumns,
  background: _planta,
  elements: [
    HmiElement(id: 't', type: ElementType.label, x: 0, y: 0, w: 10, h: 2, props: {'text': 'LINHA 1'}),
    HmiElement(id: 'a', type: ElementType.label, x: 3, y: 5, w: 4, h: 2, props: {'text': 'PRENSA'}),
    HmiElement(id: 'b', type: ElementType.label, x: 13, y: 7, w: 5, h: 3, props: {'text': 'FORNO'}),
    HmiElement(id: 'c', type: ElementType.label, x: 1, y: 14, w: 8, h: 4, props: {'text': 'ABAIXO DA PLANTA'}),
  ],
);

void main() {
  group('modelo', () {
    test('o fundo vai e volta pelo arquivo do projeto, e o formato segue no schemaVersion 1', () {
      final s = _sinotico.withBackground(_planta.copyWith(fit: BackgroundFit.cover, rows: 30, dim: 30));
      final p = Project(name: 'Fábrica', screens: [s]);
      final bytes = ProjectRepository.encode(p);
      final raw = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      expect(raw['schemaVersion'], 1);
      final bg = (raw['screens'] as List).single['background'] as Map;
      expect(bg, {'data': _png, 'width': 1200, 'height': 600, 'fit': 'cover', 'rows': 30, 'dim': 30});
      final back = ProjectRepository.decode(bytes).screens.single;
      expect(back.background!.fit, BackgroundFit.cover);
      expect(back.background!.rows, 30);
      expect(back.background!.dim, 30);
      expect(back.toJson(), s.toJson());
    });

    test('tela sem fundo fica byte a byte igual à de antes (sem a chave background)', () {
      final j = _sinotico.withBackground(null).toJson();
      expect(j.keys.toSet(), {'id', 'name', 'columns', 'readOnly', 'confirmWrites', 'elements'});
      // Só o padrão "largura da tela" e sem escurecer: o mínimo vai para o arquivo.
      expect(_planta.toJson().keys.toSet(), {'data', 'width', 'height'});
    });

    test('chaves da tela e do fundo que esta versão não conhece são preservadas (arquivo de versão mais nova)', () {
      final j = jsonDecode(jsonEncode(_sinotico.toJson())) as Map<String, dynamic>;
      j['camadas'] = [
        {'nome': 'tubulação'},
      ];
      (j['background'] as Map)['recorte'] = {'x': 0.1};
      final s = HmiScreen.fromJson(j);
      expect(s.extra['camadas'], isNotNull);
      final again = jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>;
      expect(again['camadas'], j['camadas']);
      expect((again['background'] as Map)['recorte'], {'x': 0.1});
      // Mexer na tela (nome, grade, fundo) não perde nada.
      final mexida = s.copyWith(name: 'Outro').withColumns(HmiScreen.fineColumns)!.withBackground(s.background!.copyWith(dim: 60));
      final j2 = mexida.toJson();
      expect(j2['camadas'], j['camadas']);
      expect((j2['background'] as Map)['recorte'], {'x': 0.1});
    });

    test('fundo que esta versão não sabe ler (sem imagem) vai e volta igual, sem desenhar', () {
      final j = jsonDecode(jsonEncode(_sinotico.withBackground(null).toJson())) as Map<String, dynamic>;
      j['background'] = {'url': 'planta.svg'};
      final s = HmiScreen.fromJson(j);
      expect(s.background, isNull);
      expect(s.toJson()['background'], {'url': 'planta.svg'});
      // Escolher uma imagem de verdade substitui o ilegível.
      expect(s.withBackground(_planta).toJson()['background'], _planta.toJson());
    });

    test('a área da imagem sai em linhas da grade, sem decodificar nada', () {
      expect(_planta.areaRows(6), 3);
      expect(_planta.areaRows(12), 6);
      expect(_planta.areaRows(24), 12);
      // 1000×333 em 6 colunas = 1,998 linha → 2 (a imagem nunca é cortada).
      expect(const ScreenBackground(data: _png, width: 1000, height: 333).areaRows(6), 2);
      // Tela inteira / caber: a altura guardada.
      expect(_planta.copyWith(fit: BackgroundFit.contain, rows: 40).areaRows(24), 40);
      // A grade cresce até a imagem caber, e os elementos abaixo dela contam.
      expect(_sinotico.withBackground(null).drawnRows, 18);
      expect(_sinotico.withBackground(_planta.copyWith(fit: BackgroundFit.cover, rows: 30)).drawnRows, 30);
    });

    test('trocar de grade leva o fundo junto, com a altura em linhas convertida', () {
      final cover = _sinotico.withBackground(_planta.copyWith(fit: BackgroundFit.cover, rows: 31));
      final fina = cover.withColumns(HmiScreen.fineColumns)!;
      expect(fina.background!.rows, 16, reason: '31 extra-finas = 15,5 finas → 16: arredonda para cima, a imagem não perde pedaço');
      expect(fina.background!.data, _png);
      expect(fina.withColumns(HmiScreen.extraFineColumns)!.background!.rows, 32);
      // Largura da tela: não guarda linhas, segue a proporção em qualquer grade.
      expect(_sinotico.withColumns(HmiScreen.fineColumns)!.background!.toJson(), _planta.toJson());
    });

    test('duplicar a tela leva o fundo e as chaves desconhecidas; elementos ganham ids novos', () {
      final s = HmiScreen.fromJson({..._sinotico.toJson(), 'camadas': 1});
      var n = 0;
      final copia = s.duplicate(id: 'sin2', name: 'Sinótico (cópia)', elementId: () => 'n${n++}');
      expect(copia.background!.toJson(), _planta.toJson());
      expect(copia.extra['camadas'], 1);
      expect(copia.elements.map((e) => e.id), ['n0', 'n1', 'n2', 'n3']);
    });

    test('a planta exportada leva o fundo de cada tela', () {
      final plant = Plant(name: 'Fábrica', projects: [PlantProject('p1', Project(name: 'Linha', screens: [_sinotico]))]);
      final back = ProjectRepository.decodePlant(ProjectRepository.encodePlant(plant));
      expect(back.projects.single.project.screens.single.background!.toJson(), _planta.toJson());
    });
  });

  group('tamanho da imagem', () {
    // Foto grande de verdade (3000×1500), gerada aqui.
    Future<Uint8List> foto(int w, int h) async {
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = const Color(0xFF336699));
      canvas.drawCircle(Offset(w / 2, h / 2), h / 3, Paint()..color = const Color(0xFFFFCC00));
      final img = await rec.endRecording().toImage(w, h);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      return data!.buffer.asUint8List();
    }

    Future<(int, int)> medidas(String b64) async {
      final codec = await ui.instantiateImageCodec(base64Decode(b64));
      final frame = (await codec.getNextFrame()).image;
      final r = (frame.width, frame.height);
      frame.dispose();
      codec.dispose();
      return r;
    }

    testWidgets('foto grande é reduzida a 1.200 px no maior lado (o teto das imagens por etapa do elemento imagem), com a proporção guardada', (tester) async {
      await tester.runAsync(() async {
        final big = await foto(3000, 1500);
        final bg = await ScreenBackgroundSection.prepare(big);
        expect(ScreenBackground.maxSide, 1200);
        expect((bg.width, bg.height), (1200, 600));
        expect(await medidas(bg.data), (1200, 600), reason: 'o PNG guardado tem mesmo esse tamanho');
        expect(bg.data.length * 0.75, lessThan(big.length), reason: 'fica menor que o original');
        // Imagem pequena não é ampliada; trocar a imagem mantém o encaixe.
        final small = await ScreenBackgroundSection.prepare(await foto(400, 300), keep: bg.copyWith(fit: BackgroundFit.contain, rows: 12, dim: 60));
        expect((small.width, small.height), (400, 300));
        expect((small.fit, small.rows, small.dim), (BackgroundFit.contain, 12, 60));
      });
    });

    test('PDF é reconhecido pelo começo do arquivo, não pelo nome', () {
      expect(ScreenBackgroundSection.isPdf(Uint8List.fromList(utf8.encode('%PDF-1.7\n...'))), isTrue);
      expect(ScreenBackgroundSection.isPdf(base64Decode(_png)), isFalse);
    });
  });

  group('desenho', () {
    for (final dp in const [Size(360, 780), Size(390, 844), Size(800, 1280), Size(1280, 800)]) {
      final nome = '${dp.width.toInt()}×${dp.height.toInt()} dp';

      for (final fit in BackgroundFit.values) {
        testWidgets('$nome, encaixe ${fit.name}: o editor desenha a imagem e os elementos onde a operação desenha', (tester) async {
          tester.view.physicalSize = dp;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final s = _sinotico.withBackground(fit == BackgroundFit.width ? _planta : _planta.copyWith(fit: fit, rows: 20));
          await tester.pumpWidget(MaterialApp(home: Scaffold(body: HmiCanvas(screen: s))));
          final opFundo = tester.getRect(find.byKey(const ValueKey('fundo-da-tela')));
          final op = {for (final e in s.elements) e.id: tester.getRect(find.byKey(ValueKey('el-${e.id}')))};
          final grade = tester.getRect(find.byKey(const ValueKey('el-t'))).left;

          await tester.pumpWidget(MaterialApp(home: Scaffold(body: HmiCanvas(screen: s, editMode: true))));
          final edFundo = tester.getRect(find.byKey(const ValueKey('fundo-da-tela')));
          expect((edFundo.topLeft - opFundo.topLeft).distance, lessThan(0.01));
          expect((edFundo.bottomRight - opFundo.bottomRight).distance, lessThan(0.01));
          for (final e in s.elements) {
            final ed = tester.getRect(find.byKey(ValueKey('ed-${e.id}')));
            expect((ed.topLeft - op[e.id]!.topLeft).distance, lessThan(0.01), reason: e.id);
            expect((ed.bottomRight - op[e.id]!.bottomRight).distance, lessThan(0.01), reason: e.id);
          }

          // A imagem ocupa a largura inteira da grade, a partir da linha 0.
          final cell = opFundo.width / 24;
          expect(opFundo.left, lessThanOrEqualTo(grade), reason: 'a imagem começa na borda da grade');
          expect((op['t']!.top - opFundo.top - CanvasGap.of(cell)).abs(), lessThan(cell), reason: 'linha 0 = topo da imagem');
          if (fit == BackgroundFit.width) {
            expect(opFundo.height, closeTo(opFundo.width / 2, 0.01), reason: 'proporção da planta (2:1)');
          } else {
            expect(opFundo.height, closeTo(20 * cell, 0.01), reason: '20 linhas da grade');
          }
          // O elemento sobre a prensa fica no mesmo ponto relativo do desenho.
          final rel = (op['a']!.center - opFundo.topLeft).scale(1 / opFundo.width, 1 / opFundo.width);
          expect(rel.dx, closeTo((3 + 2) / 24, 0.01));
        });
      }
    }

    testWidgets('a grade cresce até a imagem caber, e a tela só com a imagem já rola até o fim dela', (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // Planta alta (1:3) e nenhum elemento.
      const alta = HmiScreen(id: 'alta', name: 'A', columns: 12, background: ScreenBackground(data: _png, width: 400, height: 1200));
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: HmiCanvas(screen: alta))));
      final fundo = tester.getRect(find.byKey(const ValueKey('fundo-da-tela')));
      expect(fundo.height, closeTo(fundo.width * 3, 0.01));
      final stack = tester.getRect(find.descendant(of: find.byType(HmiCanvas), matching: find.byType(Stack)).first);
      expect(stack.height, greaterThanOrEqualTo(fundo.height - 0.01));
    });

    testWidgets('no editor a imagem fica atenuada (60%) para a grade aparecer; na operação, cheia', (tester) async {
      final s = _sinotico.withBackground(_planta.copyWith(dim: 30));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: HmiCanvas(screen: s))));
      expect(tester.widget<Image>(find.byKey(const ValueKey('fundo-imagem'))).opacity, isNull, reason: 'operação: opacidade cheia');
      final camada = tester.widget<ColoredBox>(find.byKey(const ValueKey('fundo-escurecer')));
      expect(camada.color.a, closeTo(0.3, 0.01), reason: '"Escurecer a imagem" 30% vale na operação');
      expect(camada.color.withValues(alpha: 1), Ind.bg.withValues(alpha: 1), reason: 'na cor de fundo do tema');

      await tester.pumpWidget(MaterialApp(home: Scaffold(body: HmiCanvas(screen: s, editMode: true))));
      final ed = tester.widget<Image>(find.byKey(const ValueKey('fundo-imagem')));
      expect(ed.opacity?.value, HmiCanvas.editorBackgroundOpacity);
      expect(HmiCanvas.editorBackgroundOpacity, 0.6);

      await tester.pumpWidget(MaterialApp(home: Scaffold(body: HmiCanvas(screen: _sinotico))));
      expect(find.byKey(const ValueKey('fundo-escurecer')), findsNothing, reason: 'escurecer 0 = sem camada');
    });

    testWidgets('texto fixo sobre a imagem ganha o contorno; sem imagem, nada muda', (tester) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: HmiCanvas(screen: _sinotico))));
      final comFundo = tester.widget<RichText>(find.descendant(of: find.byKey(const ValueKey('el-a')), matching: find.byType(RichText)));
      expect(comFundo.text.style?.shadows, isNotEmpty);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: HmiCanvas(screen: _sinotico.withBackground(null)))));
      expect(find.byKey(const ValueKey('fundo-da-tela')), findsNothing);
      final semFundo = tester.widget<RichText>(find.descendant(of: find.byKey(const ValueKey('el-a')), matching: find.byType(RichText)));
      expect(semFundo.text.style?.shadows ?? const [], isEmpty);
    });
  });

  group('editor e operação no app', () {
    late Directory dir;

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        for (final (id, _, _) in Tours.catalog) for (final v in [1, 2]) 'tour:v$v:$id': true,
      });
      dir = await Directory.systemTemp.createTemp('ihm_fundo');
    });

    tearDown(() async {
      DemoRegistry.discard(DemoProject.deviceId);
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } on FileSystemException {/* Windows ainda segurando o arquivo */}
    });

    Future<ProjectController> boot(WidgetTester tester, Size dp) async {
      final runtime = HmiRuntime();
      final controller = ProjectController(repository: ProjectRepository(directory: dir), runtime: runtime);
      await tester.runAsync(controller.load);
      tester.view.physicalSize = dp;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(CeliwareIhmApp(controller: controller, runtime: runtime));
      await _live(tester, 600);
      return controller;
    }

    Future<void> shutdown(WidgetTester tester, ProjectController c) async {
      await tester.pumpWidget(const SizedBox());
      final done = c.runtime.dispose();
      await _live(tester, 1200);
      await done;
      c.dispose();
    }

    HmiScreen tela(ProjectController c) => c.project.screen('sin')!;

    /// Sinótico com uma lâmpada (variável liga/desliga da demonstração) e um botão.
    HmiScreen comLampada(ProjectController c, {ScreenBackground? bg = _planta}) {
      final liga = c.project.tags.firstWhere((t) => t.dataType == TagDataType.bool);
      return HmiScreen(id: 'sin', name: 'Sinótico', columns: 24, background: bg, elements: [
        HmiElement(id: 'lamp', type: ElementType.lamp, x: 2, y: 2, w: 8, h: 4, props: {'tagId': liga.id, 'label': 'Prensa', 'transparent': true}),
        HmiElement(id: 'btn', type: ElementType.button, x: 12, y: 2, w: 8, h: 4, props: {'tagId': liga.id, 'label': 'Liga'}),
      ]);
    }

    Future<void> openEditor(WidgetTester tester) async {
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => const ScreenEditorPage(screenId: 'sin'))));
      await _live(tester, 900);
    }

    /// Abre a configuração do selecionado e rola até o fim (a lista só monta
    /// o que está à vista; "Mais opções" fica logo antes de "Posição e tamanho").
    Future<void> openConfig(WidgetTester tester) async {
      await tester.tap(find.text('Configurar'));
      await _live(tester, 600);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('posicao-e-tamanho')), 200,
          scrollable: find.descendant(of: find.byType(ElementConfigSheet), matching: find.byType(Scrollable)).first);
      await _live(tester, 200);
    }

    Finder cartao(String id) => find.descendant(
        of: find.byKey(ValueKey(id)), matching: find.byWidgetPredicate((w) => w is CustomPaint && w.foregroundPainter is CardEdge));

    testWidgets('360 dp: "Fundo transparente" só aparece com imagem de fundo e tira o cartão da lâmpada', (tester) async {
      final c = await boot(tester, const Size(360, 780));
      c.saveScreen(comLampada(c, bg: null));
      await _live(tester, 200);
      await openEditor(tester);

      // Sem imagem: a lâmpada marcada como transparente continua com cartão,
      // e a configuração não oferece a opção.
      expect(cartao('ed-lamp'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ed-lamp')));
      await _live(tester, 300);
      await openConfig(tester);
      await _live(tester, 600);
      expect(find.byType(ElementConfigSheet), findsOneWidget);
      expect(find.byKey(const ValueKey('mais-opcoes-elemento')), findsNothing);
      expect(find.text('Fundo transparente'), findsNothing);
      Navigator.of(tester.element(find.byType(ElementConfigSheet))).pop();
      await _live(tester, 600);

      // Com imagem: a lâmpada perde o cartão (no editor), e a opção aparece.
      c.saveScreen(tela(c).withBackground(_planta));
      await _live(tester, 300);
      expect(cartao('ed-lamp'), findsNothing);
      expect(cartao('ed-btn'), findsWidgets, reason: 'botão mantém o cartão: é ele que diz "isto se toca"');
      await openConfig(tester);
      await _live(tester, 600);
      expect(find.byKey(const ValueKey('mais-opcoes-elemento')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('mais-opcoes-elemento')), matching: find.text('Fundo transparente')), findsOneWidget,
          reason: 'fechado, o resumo diz como está');
      await tester.ensureVisible(find.byKey(const ValueKey('mais-opcoes-elemento')));
      await tester.tap(find.text('Mais opções'));
      await _live(tester, 400);
      await tester.ensureVisible(find.byKey(const ValueKey('fundo-transparente')));
      await tester.tap(find.byKey(const ValueKey('fundo-transparente')));
      await _live(tester, 300);
      expect(tela(c).elements.first.transparent, isFalse);
      expect(tela(c).elements.first.props.containsKey('transparent'), isFalse, reason: 'desligado não vai para o arquivo');
      await tester.tap(find.byKey(const ValueKey('fundo-transparente')));
      await _live(tester, 300);
      expect(tela(c).elements.first.transparent, isTrue);
      Navigator.of(tester.element(find.byType(ElementConfigSheet))).pop();
      await _live(tester, 600);

      // Botão: tipo que grava não tem a opção, nem com imagem.
      await tester.tap(find.byKey(const ValueKey('ed-btn')));
      await _live(tester, 300);
      await openConfig(tester);
      await _live(tester, 600);
      expect(find.byKey(const ValueKey('mais-opcoes-elemento')), findsNothing);
      Navigator.of(tester.element(find.byType(ElementConfigSheet))).pop();
      await _live(tester, 600);

      // Operação: sem cartão, e o texto da lâmpada com o contorno.
      await tester.tap(find.text('Concluir'));
      await _live(tester, 900);
      expect(find.byKey(const ValueKey('fundo-da-tela')), findsOneWidget);
      expect(cartao('el-lamp'), findsNothing);
      expect(cartao('el-btn'), findsWidgets);
      final rotulo = tester.widget<RichText>(find.descendant(of: find.byKey(const ValueKey('el-lamp')), matching: find.byType(RichText)).first);
      expect(rotulo.text.style?.shadows, isNotEmpty);
      expect(find.descendant(of: find.byKey(const ValueKey('el-lamp')), matching: find.byType(HmiSurface)), findsOneWidget);
      await shutdown(tester, c);
    });

    testWidgets('320 dp: regras da tela com imagem — encaixe, escurecer e remover, sem estourar a folha', (tester) async {
      final c = await boot(tester, const Size(320, 640));
      c.saveScreen(comLampada(c, bg: null));
      await _live(tester, 200);
      await openEditor(tester);

      await tester.tap(find.byTooltip('Regras da tela'));
      await _live(tester, 600);
      expect(find.byKey(const ValueKey('fundo-escolher')), findsOneWidget, reason: 'sem imagem: só o botão de escolher');
      expect(find.byKey(const ValueKey('encaixe-cover')), findsNothing);
      Navigator.of(tester.element(find.byKey(const ValueKey('fundo-escolher')))).pop();
      await _live(tester, 600);

      // A imagem chega (o seletor de arquivo do Android não roda em teste).
      c.saveScreen(tela(c).withBackground(_planta));
      await _live(tester, 300);
      await tester.tap(find.byTooltip('Regras da tela'));
      await _live(tester, 600);
      expect(find.byKey(const ValueKey('fundo-trocar')), findsOneWidget);
      expect(find.byKey(const ValueKey('fundo-remover')), findsOneWidget);
      expect(find.textContaining('KB no projeto'), findsOneWidget, reason: 'imagem pequena: em KB, não "0,0 MB"');

      // Tela inteira: guarda a altura da tela que se vê, em linhas da grade.
      await tester.ensureVisible(find.byKey(const ValueKey('encaixe-cover')));
      await tester.tap(find.byKey(const ValueKey('encaixe-cover')));
      await _live(tester, 300);
      expect(tela(c).background!.fit, BackgroundFit.cover);
      expect(tela(c).background!.rows, greaterThan(10), reason: 'as linhas extra-finas à vista em 320×640');
      await tester.ensureVisible(find.byKey(const ValueKey('encaixe-width')));
      await tester.tap(find.byKey(const ValueKey('encaixe-width')));
      await _live(tester, 300);
      expect(tela(c).background!.fit, BackgroundFit.width);
      expect(tela(c).background!.rows, isNull);

      await tester.ensureVisible(find.byKey(const ValueKey('escurecer-60')));
      await tester.tap(find.byKey(const ValueKey('escurecer-60')));
      await _live(tester, 300);
      expect(tela(c).background!.dim, 60);

      // Remover pergunta antes; os elementos ficam.
      await tester.ensureVisible(find.byKey(const ValueKey('fundo-remover')));
      await tester.tap(find.byKey(const ValueKey('fundo-remover')));
      await _live(tester, 400);
      expect(find.text('Remover a imagem de fundo?'), findsOneWidget);
      await tester.tap(find.text('Apagar'));
      await _live(tester, 400);
      expect(tela(c).background, isNull);
      expect(tela(c).elements, hasLength(2));
      expect(find.byKey(const ValueKey('fundo-escolher')), findsOneWidget);
      await shutdown(tester, c);
    });

    testWidgets('tela só com a imagem de fundo abre o desenho na operação, não "Tela vazia"', (tester) async {
      final c = await boot(tester, const Size(390, 844));
      c.saveScreen(const HmiScreen(id: 'sin', name: 'Sinótico', columns: 24, background: _planta));
      await _live(tester, 200);
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => const ScreenEditorPage(screenId: 'sin'))));
      await _live(tester, 900);
      await tester.tap(find.text('Concluir'));
      await _live(tester, 900);
      expect(find.text('Tela vazia'), findsNothing);
      expect(find.byKey(const ValueKey('fundo-da-tela')), findsOneWidget);
      await shutdown(tester, c);
    });

    // Para conferir com os olhos: com a variável QA_PNG, grava editor,
    // operação e regras da tela com uma planta desenhada aqui (sem ela, não
    // roda — os testes acima já conferem o comportamento).
    testWidgets('fotos do sinótico (QA_PNG)', (tester) async {
      final png = Platform.environment['QA_PNG'];
      if (png == null) return;
      await tester.runAsync(() async {
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
      const size = Size(360, 780);
      final c = await boot(tester, size);
      // Planta: piso claro, três máquinas e a tubulação.
      final bg = (await tester.runAsync(() async {
        final rec = ui.PictureRecorder();
        final cv = Canvas(rec);
        cv.drawRect(const Rect.fromLTWH(0, 0, 1200, 900), Paint()..color = const Color(0xFFD9DEE3));
        final pipe = Paint()
          ..color = const Color(0xFF2E7DB5)
          ..strokeWidth = 14;
        cv.drawLine(const Offset(120, 450), const Offset(1080, 450), pipe);
        for (final r in const [Rect.fromLTWH(80, 160, 260, 220), Rect.fromLTWH(470, 520, 300, 260), Rect.fromLTWH(860, 140, 260, 240)]) {
          cv.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(18)), Paint()..color = const Color(0xFF4A5560));
        }
        final img = await rec.endRecording().toImage(1200, 900);
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        img.dispose();
        return ScreenBackgroundSection.prepare(data!.buffer.asUint8List());
      }))!;
      final tags = c.project.tags;
      final liga = tags.firstWhere((t) => t.dataType == TagDataType.bool);
      final numero = tags.firstWhere((t) => t.dataType.isNumeric && !t.isArray && t.dataType != TagDataType.bool);
      c.saveScreen(HmiScreen(id: 'sin', name: 'Sinótico', columns: 24, background: bg, elements: [
        const HmiElement(id: 'titulo', type: ElementType.label, x: 0, y: 0, w: 12, h: 2, props: {'text': 'LINHA 1'}),
        HmiElement(id: 'lamp', type: ElementType.lamp, x: 1, y: 3, w: 8, h: 2, props: {'tagId': liga.id, 'label': 'Prensa', 'transparent': true}),
        HmiElement(id: 'val', type: ElementType.value, x: 9, y: 12, w: 8, h: 2, props: {'tagId': numero.id, 'transparent': true}),
        HmiElement(id: 'card', type: ElementType.value, x: 16, y: 4, w: 8, h: 4, props: {'tagId': numero.id}),
        HmiElement(id: 'btn', type: ElementType.button, x: 0, y: 19, w: 8, h: 4, props: {'tagId': liga.id, 'label': 'Liga'}),
      ]));
      await _live(tester, 200);
      Future<void> snap(String name) async {
        final layer = tester.binding.renderViews.first.debugLayer! as OffsetLayer;
        await tester.runAsync(() async {
          final image = await layer.toImage(Offset.zero & size);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          File('${(Directory(png)..createSync(recursive: true)).path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await openEditor(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await _live(tester, 300);
      await snap('fundo-editor');
      await tester.tap(find.byTooltip('Regras da tela'));
      await _live(tester, 600);
      await tester.ensureVisible(find.byKey(const ValueKey('escurecer-30')));
      await _live(tester, 300);
      await snap('fundo-regras');
      Navigator.of(tester.element(find.byKey(const ValueKey('escurecer-30')))).pop();
      await _live(tester, 600);
      await tester.tap(find.text('Concluir'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await _live(tester, 900);
      await snap('fundo-operacao');
      await shutdown(tester, c);
    });
  });

  group('tutorial', () {
    test('o passo "Regras da tela" cita a extra-fina e a imagem de fundo, e a trilha subiu de versão', () {
      final spec = Tours.editor(settings: GlobalKey());
      expect(spec.version, 2);
      final passo = spec.steps.firstWhere((s) => s.title == 'Regras da tela');
      expect(passo.body, contains('extra-fina'));
      expect(passo.body, contains('imagem de fundo'));
      // Tela vazia: o passo das regras tem alvo sempre à vista (sem seleção);
      // os essenciais aparecem sem alvo.
      expect(passo.essential, isFalse);
      expect(spec.steps.where((s) => s.essential).length, 3);
    });
  });

  test('só tipos que mostram estado ou número podem ficar sem cartão', () {
    expect(ElementCatalog.transparentTypes, {ElementType.lamp, ElementType.value, ElementType.multistate, ElementType.bar, ElementType.gauge});
    const lamp = HmiElement(id: 'l', type: ElementType.lamp, x: 0, y: 0, w: 4, h: 2, props: {'transparent': true});
    const btn = HmiElement(id: 'b', type: ElementType.button, x: 0, y: 0, w: 4, h: 4, props: {'transparent': true});
    expect(ElementCatalog.drawnBare(_sinotico, lamp), isTrue);
    expect(ElementCatalog.drawnBare(_sinotico.withBackground(null), lamp), isFalse, reason: 'sem imagem, o cartão volta');
    expect(ElementCatalog.drawnBare(_sinotico, btn), isFalse);
  });
}

/// Respiro da grade (o mesmo da operação), para comparar o topo do elemento
/// com o topo da imagem.
class CanvasGap {
  static double of(double cell) => HmiCanvas.gapFor(cell, HmiScreen.extraFineColumns) / 2;
}

/// Avança o relógio simulado em passos de 100 ms (varredura e demo andam).
Future<void> _live(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
