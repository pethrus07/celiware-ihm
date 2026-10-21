import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/hmi_screen.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/screens/editor/screen_editor_page.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:ihm/widgets/hmi/element_catalog.dart';
import 'package:ihm/widgets/hmi/hmi_canvas.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Grade extra-fina (24 colunas, pedido do cliente de 21/10/2026): conversão
/// com a fina e a normal sem mexer na tela, volta arredondada sem sobrepor,
/// tamanhos mínimos, arquivo que a 1.4.0/1.5.0 abrem, desenho igual ao da
/// fina e igual entre editor e operação (360, 390 dp e tablet) e as setas de
/// ajuste fino do editor.

// Tela na fina, com um rótulo de uma linha fina (o menor que existe).
const _fina = HmiScreen(id: 's', name: 'Sinótico', columns: HmiScreen.fineColumns, elements: [
  HmiElement(id: 'a', type: ElementType.label, x: 0, y: 0, w: 6, h: 1, props: {'text': 'A'}),
  HmiElement(id: 'b', type: ElementType.label, x: 6, y: 0, w: 6, h: 3, props: {'text': 'B'}),
  HmiElement(id: 'c', type: ElementType.label, x: 1, y: 3, w: 5, h: 2, props: {'text': 'C'}),
  HmiElement(id: 'd', type: ElementType.label, x: 0, y: 6, w: 12, h: 4, props: {'text': 'D'}),
]);

List<int> _geo(HmiElement e) => [e.x, e.y, e.w, e.h];

/// Tela extra-fina aleatória e válida: cada elemento entra só se
/// [ElementCatalog.fits] aceitar (mesma regra do editor).
HmiScreen _aleatoria(int seed) {
  final r = math.Random(seed);
  const tipos = [ElementType.label, ElementType.value, ElementType.lamp, ElementType.button, ElementType.input, ElementType.bar, ElementType.trend];
  var s = const HmiScreen(id: 'r', name: 'R', columns: HmiScreen.extraFineColumns);
  for (var i = 0; i < 60; i++) {
    final t = tipos[r.nextInt(tipos.length)];
    final (mw, mh) = ElementCatalog.minSize(t, HmiScreen.extraFineColumns);
    final w = mw + r.nextInt(5), h = mh + r.nextInt(5);
    if (w > HmiScreen.extraFineColumns) continue;
    final e = HmiElement(id: 'e$i', type: t, x: r.nextInt(HmiScreen.extraFineColumns - w + 1), y: r.nextInt(40), w: w, h: h);
    if (ElementCatalog.fits(s, e)) s = s.copyWith(elements: [...s.elements, e]);
  }
  return s;
}

void main() {
  group('conversão de grade', () {
    test('fina → extra-fina dobra tudo; voltar dá a mesma tela', () {
      final extra = _fina.withColumns(HmiScreen.extraFineColumns)!;
      expect(extra.columns, 24);
      expect(extra.extraFine, isTrue);
      expect(extra.fine, isTrue, reason: '"fine" é fina ou mais fina');
      expect(_geo(extra.elements[2]), [2, 6, 10, 4]);
      expect(extra.withColumns(HmiScreen.fineColumns)!.toJson(), _fina.toJson());
    });

    test('normal ↔ extra-fina: ×4 e volta igual', () {
      const normal = HmiScreen(id: 'n', name: 'N', elements: [
        HmiElement(id: 'a', type: ElementType.label, x: 1, y: 2, w: 3, h: 1),
      ]);
      final extra = normal.withColumns(24)!;
      expect(_geo(extra.elements.single), [4, 8, 12, 4]);
      expect(extra.withColumns(6)!.toJson(), normal.toJson());
    });

    test('extra-fina → fina arredonda as bordas: anda meia célula, vizinhos continuam encostados', () {
      const extra = HmiScreen(id: 'x', name: 'X', columns: 24, elements: [
        HmiElement(id: 'a', type: ElementType.label, x: 0, y: 0, w: 5, h: 3),
        HmiElement(id: 'b', type: ElementType.label, x: 5, y: 0, w: 7, h: 3), // encosta no A em 5
        HmiElement(id: 'c', type: ElementType.label, x: 1, y: 3, w: 5, h: 2), // altura mínima (uma linha fina)
      ]);
      expect(extra.oddElements, 3);
      final fina = extra.withColumns(12)!;
      final [a, b, c] = fina.elements;
      expect(_geo(a), [0, 0, 3, 2]);
      expect(_geo(b), [3, 0, 3, 2]);
      expect(a.right, b.x, reason: 'a borda comum arredonda para o mesmo lugar');
      expect(_geo(c), [1, 2, 2, 1]);
      for (final e in fina.elements) {
        expect(ElementCatalog.fits(fina, e), isTrue, reason: '${e.id} dentro, acima do mínimo e sem sobrepor');
      }
    });

    test('300 telas extra-finas aleatórias: a volta para a fina nunca sobrepõe, nunca sai da grade e anda no máximo meia célula', () {
      var arredondados = 0;
      for (var seed = 0; seed < 300; seed++) {
        final extra = _aleatoria(seed);
        final fina = extra.withColumns(12);
        expect(fina, isNotNull, reason: 'semente $seed');
        arredondados += extra.oddElements;
        for (var i = 0; i < extra.elements.length; i++) {
          final antes = extra.elements[i], depois = fina!.elements[i];
          expect(ElementCatalog.fits(fina, depois), isTrue, reason: 'semente $seed, ${depois.id} ${_geo(depois)}');
          for (final (x2, x1) in [(antes.x, depois.x), (antes.y, depois.y), (antes.right, depois.right), (antes.bottom, depois.bottom)]) {
            expect((x2 - 2 * x1).abs(), lessThanOrEqualTo(1), reason: 'semente $seed: borda anda no máximo meia célula fina');
          }
        }
      }
      expect(arredondados, greaterThan(100), reason: 'as telas aleatórias têm de exercitar o arredondamento');
    });

    test('extra-fina → normal passa pela fina; meia célula da normal impede e diz quantos', () {
      final extra = _fina.withColumns(24)!;
      // A fina tem C em x=1 (meia célula normal) → não volta para a normal.
      expect(extra.withColumns(6), isNull);
      expect(extra.blockersFor(6), _fina.oddElements);
      expect(extra.blockersFor(12), 0);
      const par = HmiScreen(id: 'p', name: 'P', columns: 24, elements: [HmiElement(id: 'a', type: ElementType.label, x: 4, y: 0, w: 8, h: 4)]);
      expect(_geo(par.withColumns(6)!.elements.single), [1, 0, 2, 1]);
    });

    test('elemento de uma célula (vindo de app antigo) não some: a volta é recusada', () {
      const extra = HmiScreen(id: 'v', name: 'V', columns: 24, elements: [
        HmiElement(id: 'fino', type: ElementType.label, x: 0, y: 1, w: 6, h: 1),
      ]);
      expect(extra.withColumns(12), isNull);
      expect(extra.blockersFor(12), 1);
    });

    test('grade que este app não conhece (versão mais nova) abre e não converte', () {
      final j = _fina.toJson()..['columns'] = 48;
      final s = HmiScreen.fromJson(j);
      expect(s.columns, 48);
      expect(s.withColumns(12), isNull);
      expect(HmiScreen.scaleOf(48), 4);
    });
  });

  group('tamanhos', () {
    test('na extra-fina o mínimo e o tamanho inicial são os da fina em dobro (mesmo tamanho na tela)', () {
      for (final t in ElementType.values) {
        final (fw, fh) = ElementCatalog.minSize(t, 12);
        expect(ElementCatalog.minSize(t, 24), (fw * 2, fh * 2), reason: t.name);
        final (dw, dh) = ElementCatalog.defaultSize(t, 12);
        expect(ElementCatalog.defaultSize(t, 24), (dw * 2, dh * 2), reason: t.name);
      }
      expect(ElementCatalog.minSize(ElementType.value, 24), (4, 2), reason: 'uma linha fina = duas extra-finas');
      expect(ElementCatalog.minSize(ElementType.button, 24), (4, 4), reason: 'quem grava nunca desce de ~60 dp');
    });
  });

  group('arquivo', () {
    test('tela extra-fina vai e volta pelo arquivo; o formato não mudou (schemaVersion 1)', () {
      final p = Project(name: 'Sinótico', screens: [_fina.withColumns(24)!]);
      final bytes = ProjectRepository.encode(p);
      final raw = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      expect(raw['schemaVersion'], 1);
      expect(Project.schemaVersion, 1);
      final back = ProjectRepository.decode(bytes);
      expect(back.screens.single.toJson(), p.screens.single.toJson());
    });

    test('a tela só usa campos que a 1.4.0/1.5.0 já leem: lá ela abre com todos os elementos', () {
      final j = jsonDecode(jsonEncode(_fina.withColumns(24)!.toJson())) as Map<String, dynamic>;
      expect(j.keys.toSet(), {'id', 'name', 'columns', 'readOnly', 'confirmWrites', 'elements'});
      expect(j['columns'], isA<int>());
      for (final e in j['elements'] as List) {
        expect((e as Map).keys.toSet(), {'id', 'type', 'x', 'y', 'w', 'h', 'props'});
      }
    });
  });

  group('desenho', () {
    // Celular 360 e 390 dp, tablet em pé e deitado.
    for (final dp in const [Size(360, 780), Size(390, 844), Size(800, 1280), Size(1280, 800)]) {
      final nome = '${dp.width.toInt()}×${dp.height.toInt()} dp';

      testWidgets('$nome: a mesma tela na fina e na extra-fina ocupa os mesmos pixels', (tester) async {
        tester.view.physicalSize = dp;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        Future<Map<String, Rect>> desenha(HmiScreen s) async {
          await tester.pumpWidget(MaterialApp(home: Scaffold(body: HmiCanvas(screen: s))));
          return {for (final e in s.elements) e.id: tester.getRect(find.byKey(ValueKey('el-${e.id}')))};
        }

        final fina = await desenha(_fina);
        final extra = await desenha(_fina.withColumns(24)!);
        for (final id in fina.keys) {
          expect((fina[id]!.topLeft - extra[id]!.topLeft).distance, lessThan(0.01), reason: id);
          expect((fina[id]!.bottomRight - extra[id]!.bottomRight).distance, lessThan(0.01), reason: id);
        }
      });

      testWidgets('$nome: na extra-fina o editor desenha onde a operação desenha', (tester) async {
        tester.view.physicalSize = dp;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final s = _fina.withColumns(24)!.copyWith(elements: [
          ..._fina.withColumns(24)!.elements,
          const HmiElement(id: 'impar', type: ElementType.label, x: 13, y: 21, w: 3, h: 3, props: {'text': 'meia'}),
        ]);
        await tester.pumpWidget(MaterialApp(home: Scaffold(body: HmiCanvas(screen: s))));
        final op = {for (final e in s.elements) e.id: tester.getRect(find.byKey(ValueKey('el-${e.id}')))};
        await tester.pumpWidget(MaterialApp(home: Scaffold(body: HmiCanvas(screen: s, editMode: true))));
        for (final e in s.elements) {
          final ed = tester.getRect(find.byKey(ValueKey('ed-${e.id}')));
          expect((ed.topLeft - op[e.id]!.topLeft).distance, lessThan(0.01), reason: e.id);
          expect((ed.bottomRight - op[e.id]!.bottomRight).distance, lessThan(0.01), reason: e.id);
        }
        // O menor elemento continua tocável.
        expect(op['a']!.height, greaterThanOrEqualTo(20));
      });
    }
  });

  group('editor', () {
    late Directory dir;

    // Letra de verdade (IBM Plex): com a fonte de teste, cada letra é um
    // quadrado e "Normal" não caberia em lugar nenhum.
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
        for (final (id, _, _) in Tours.catalog) for (final v in [1, 2]) 'tour:v$v:$id': true,
      });
      dir = await Directory.systemTemp.createTemp('ihm_extra_fina');
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

    Future<void> tapKey(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await _live(tester, 400);
    }

    HmiScreen tela(ProjectController c) => c.project.screen(_fina.id)!;

    /// Grava a janela inteira em [name].png (só com a variável QA_PNG, como
    /// em screen_templates_render_test.dart) — para conferir com os olhos.
    Future<void> snap(WidgetTester tester, Size size, String name) async {
      final png = Platform.environment['QA_PNG'];
      if (png == null) return;
      final layer = tester.binding.renderViews.first.debugLayer! as OffsetLayer;
      await tester.runAsync(() async {
        final image = await layer.toImage(Offset.zero & size);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('${(Directory(png)..createSync(recursive: true)).path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    testWidgets('320 dp: as três grades cabem inteiras nas regras da tela', (tester) async {
      final c = await boot(tester, const Size(320, 700));
      c.saveScreen(_fina);
      await _live(tester, 200);
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => ScreenEditorPage(screenId: _fina.id))));
      await _live(tester, 900);
      await tester.tap(find.byTooltip('Regras da tela'));
      await _live(tester, 600);
      for (final k in ['grade-normal', 'grade-fina', 'grade-extra-fina']) {
        final p = tester.renderObject<RenderParagraph>(find.byKey(ValueKey(k)));
        expect(p.didExceedMaxLines, isFalse, reason: k);
        expect(p.size.width, greaterThanOrEqualTo(p.getMaxIntrinsicWidth(double.infinity) - 0.5), reason: '$k cortado');
      }
      await shutdown(tester, c);
    });

    testWidgets('360 dp: escolher Extra-fina nas regras da tela, mover e redimensionar pelas setas, voltar arredondando', (tester) async {
      final c = await boot(tester, const Size(360, 780));
      c.saveScreen(_fina);
      await _live(tester, 200);
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => ScreenEditorPage(screenId: _fina.id))));
      await _live(tester, 900);

      // Regras da tela → Grade → Extra-fina: dobra tudo, nada se mexe.
      await tester.tap(find.byTooltip('Regras da tela'));
      await _live(tester, 600);
      expect(find.byKey(const ValueKey('grade-extra-fina')), findsOneWidget);
      await tapKey(tester, 'grade-extra-fina');
      expect(tela(c).columns, 24);
      expect(_geo(tela(c).elements[2]), [2, 6, 10, 4]);
      expect(find.textContaining('Selecione um elemento e use as setas'), findsOneWidget);
      await snap(tester, const Size(360, 780), 'extra-fina-regras');
      Navigator.of(tester.element(find.byKey(const ValueKey('grade-da-tela')))).pop();
      await _live(tester, 600);

      // Seleciona o C e abre as setas (no lugar do "+").
      await tester.tap(find.byKey(const ValueKey('ed-c')));
      await _live(tester, 300);
      expect(find.byTooltip('Outro elemento'), findsNothing);
      await tapKey(tester, 'ajuste-fino');
      expect(find.byKey(const ValueKey('ajuste-fino-barra')), findsOneWidget);
      await snap(tester, const Size(360, 780), 'extra-fina-setas');
      for (final k in ['passo-esquerda', 'passo-cima', 'passo-baixo', 'passo-direita']) {
        final r = tester.getRect(find.byKey(ValueKey(k)));
        expect(r.width >= 48 && r.height >= 48, isTrue, reason: '$k é alvo de toque de verdade');
      }

      // Mover: uma célula extra-fina por toque.
      await tapKey(tester, 'passo-direita');
      expect(_geo(tela(c).elements[2]), [3, 6, 10, 4]);
      await tapKey(tester, 'passo-baixo');
      expect(_geo(tela(c).elements[2]), [3, 7, 10, 4]);
      // Encostado no B por cima (B vai até a linha 6, C começa na 7 só na
      // coluna 3..13; B ocupa 12..24): para cima ainda cabe, mais um não.
      await tapKey(tester, 'passo-cima');
      expect(_geo(tela(c).elements[2]), [3, 6, 10, 4]);
      final cima = tester.widget<FilledButton>(find.descendant(of: find.byKey(const ValueKey('passo-cima')), matching: find.byType(FilledButton)));
      expect(cima.onPressed, isNull, reason: 'subir mais sobreporia o B — a seta apaga');

      // Tamanho: a seta puxa a borda de baixo/direita.
      await tapKey(tester, 'ajuste-tamanho');
      await tapKey(tester, 'passo-esquerda');
      expect(_geo(tela(c).elements[2]), [3, 6, 9, 4]);
      await tapKey(tester, 'passo-baixo');
      expect(_geo(tela(c).elements[2]), [3, 6, 9, 5]);

      // Pronto: a barra de sempre volta.
      await tapKey(tester, 'ajuste-pronto');
      expect(find.byKey(const ValueKey('ajuste-fino-barra')), findsNothing);
      expect(find.text('Configurar'), findsOneWidget);

      // Voltar para a fina: C está fora do encaixe da fina. A pergunta diz
      // quantos andam; Cancelar não mexe, Arredondar não sobrepõe nada.
      final antes = tela(c);
      expect(antes.oddElements, 1);
      // Tocar numa célula vazia tira a seleção e volta o botão das regras.
      final vazio = tester.getRect(find.byKey(const ValueKey('ed-d'))).bottomCenter + const Offset(0, 60);
      await tester.tapAt(vazio);
      await _live(tester, 300);
      await tester.tap(find.byTooltip('Regras da tela'));
      await _live(tester, 600);
      await tapKey(tester, 'grade-fina');
      expect(find.text('Voltar para a grade fina?'), findsOneWidget);
      expect(find.textContaining('1 elemento não encaixa na grade fina'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await _live(tester, 400);
      expect(tela(c).toJson(), antes.toJson(), reason: 'cancelar não mexe em nada');
      await tapKey(tester, 'grade-fina');
      await tapKey(tester, 'arredondar-grade');
      expect(tela(c).columns, 12);
      expect(_geo(tela(c).elements[2]), [2, 3, 4, 3]);
      for (final e in tela(c).elements) {
        expect(ElementCatalog.fits(tela(c), e), isTrue, reason: e.id);
      }

      await shutdown(tester, c);
    });
  });
}

/// Avança o relógio simulado em passos de 100 ms (varredura e demo andam).
Future<void> _live(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
