import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/appearance.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/modbus/modbus_client_simulated.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/core/theme/app_theme.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/alarm.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/hmi_screen.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/screens/editor/palette_sheet.dart';
import 'package:ihm/screens/editor/screen_editor_page.dart';
import 'package:ihm/screens/screen_run_page.dart';
import 'package:ihm/screens/tags/tag_uses.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/runtime/tag_store.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:ihm/widgets/alarms/alarm_widgets.dart';
import 'package:ihm/widgets/hmi/element_catalog.dart';
import 'package:ihm/widgets/hmi/elements/oee_element.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Elemento OEE (item 8 da lista do cliente): a conta, o arquivo, a tela de
/// verdade com as fontes reais em 320/360/390 dp nos dois temas, a qualidade
/// da leitura (sem comunicação, sem leitura, erro, vaga vazia) e a
/// configuração pelo editor.
///
/// O equipamento é um "CLP" Modbus TCP simulado, como em
/// `table_element_test.dart`: o teste muda um registrador e vê o OEE mudar.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  // ── A conta ─────────────────────────────────────────────────────────────────

  const t = Tag(id: 't', name: 'T', deviceId: 'x');
  TagReading good(Object? v) => TagReading(value: v, quality: TagQuality.good, at: DateTime(2026));
  List<OeePart> parts(List<Object?> values, OeeScale scale) => [for (final v in values) Oee.part(t, good(v), scale)];

  group('conta', () {
    test('de 0 a 100: 90 × 85 × 98 = 75,0 %', () {
      final p = parts([90, 85, 98], OeeScale.percent);
      expect([for (final x in p) Oee.format(x.fraction!)], ['90,0', '85,0', '98,0']);
      final oee = Oee.product(p);
      expect(oee.state, OeeState.good);
      expect(oee.fraction, closeTo(0.7497, 1e-12));
      expect(Oee.format(oee.fraction!), '75,0');
    });

    test('de 0 a 1: 0,9 × 0,85 × 0,98 dá o mesmo OEE', () {
      final oee = Oee.product(parts([0.9, 0.85, 0.98], OeeScale.fraction));
      expect(oee.fraction, closeTo(0.7497, 1e-12));
      expect(Oee.format(oee.fraction!), '75,0');
    });

    test('OEE pronto: o da variável, na mesma escala, não o calculado', () {
      final p = parts([90, 85, 98], OeeScale.percent);
      final ready = Oee.part(t, good(72), OeeScale.percent);
      expect(Oee.compute(OeeSource.tag, p, ready).fraction, closeTo(0.72, 1e-12));
      expect(Oee.compute(OeeSource.calc, p, ready).fraction, closeTo(0.7497, 1e-12));
      expect(Oee.compute(OeeSource.tag, p, Oee.part(t, good(0.72), OeeScale.fraction)).fraction, closeTo(0.72, 1e-12));
    });

    test('os extremos 0 e 100 % estão dentro; arredondamento de float32 também', () {
      expect(Oee.product(parts([0, 100, 100], OeeScale.percent)).fraction, 0);
      expect(Oee.product(parts([100, 100, 100], OeeScale.percent)).fraction, 1);
      final quase = Oee.part(t, good(100.00001), OeeScale.percent);
      expect(quase.outOfRange, isFalse);
      expect(Oee.product([quase, quase, quase]).fraction, 1, reason: 'dentro da folga conta como 100 %');
    });

    test('fora da faixa: a parcela aparece como veio, marcada, e o OEE não é inventado', () {
      // Desempenho de 103 % (tempo de ciclo ideal mal ajustado) e negativo.
      final p = parts([90, 103, 98], OeeScale.percent);
      expect(p[1].fraction, closeTo(1.03, 1e-12), reason: 'sem cortar');
      expect(p[1].outOfRange, isTrue);
      expect(p[0].outOfRange, isFalse);
      expect(Oee.part(t, good(-5), OeeScale.percent).outOfRange, isTrue);
      final oee = Oee.product(p);
      expect(oee.fraction, isNull);
      expect(oee.blocked, isTrue);
      expect(oee.outOfRange, isTrue);
      expect(Oee.zone(oee, warn: 80, alarm: 60), OeeZone.normal, reason: 'sem número, sem faixa');
      // Escala trocada: o CLP manda 0–100 e a configuração diz 0–1.
      final trocada = parts([90, 85, 98], OeeScale.fraction);
      expect(trocada.every((x) => x.outOfRange), isTrue);
      expect(Oee.format(trocada.first.fraction!), '9000,0');
      expect(Oee.product(trocada).fraction, isNull);
      // OEE pronto fora da faixa: mostra o que veio, marcado.
      final pronto = Oee.part(t, good(120), OeeScale.percent);
      expect(pronto.fraction, closeTo(1.2, 1e-12));
      expect(pronto.outOfRange, isTrue);
    });

    test('sem leitura: nunca zero', () {
      const esperando = TagReading.waiting;
      final w = Oee.part(t, esperando, OeeScale.percent);
      expect(w.state, OeeState.waiting);
      expect(w.fraction, isNull);
      final p = parts([90, 85], OeeScale.percent);
      final oee = Oee.product([...p, w]);
      expect(oee.state, OeeState.waiting);
      expect(oee.fraction, isNull, reason: '"---", não 0 %');

      // Sem comunicação: o último valor, parado — e o OEE feito com ele também.
      final caiu = Oee.part(t, good(98).degrade(TagQuality.commLost, 'sem resposta'), OeeScale.percent);
      expect(caiu.state, OeeState.stale);
      expect(caiu.fraction, closeTo(0.98, 1e-12));
      final parado = Oee.product([...p, caiu]);
      expect(parado.state, OeeState.stale);
      expect(parado.fraction, closeTo(0.7497, 1e-12));

      // Caiu antes da primeira leitura: parado e sem número.
      final nunca = Oee.part(t, TagReading.waiting.degrade(TagQuality.commLost, 'sem resposta'), OeeScale.percent);
      expect(nunca.state, OeeState.stale);
      expect(Oee.product([...p, nunca]).fraction, isNull);
      expect(Oee.product([...p, nunca]).state, OeeState.stale);
    });

    test('vaga vazia, erro, valor que não é número; lista usa o 1º valor', () {
      final vazia = Oee.part(null, good(90), OeeScale.percent);
      expect(vazia.state, OeeState.missing);
      final erro = Oee.part(t, const TagReading(quality: TagQuality.addressError, message: 'endereço não existe'), OeeScale.percent);
      expect(erro.state, OeeState.error);
      expect(erro.message, 'endereço não existe');
      final p = parts([90, 85], OeeScale.percent);
      expect(Oee.product([...p, erro]).state, OeeState.error);
      expect(Oee.product([...p, erro]).message, 'endereço não existe');
      expect(Oee.product([vazia, erro, p.first]).state, OeeState.missing, reason: 'falta configurar vem antes do erro');
      expect(Oee.part(t, good(true), OeeScale.percent).state, OeeState.error);
      expect(Oee.part(t, good(double.nan), OeeScale.percent).state, OeeState.error);
      expect(Oee.part(t, good([80, 1, 2]), OeeScale.percent).fraction, closeTo(0.8, 1e-12));
    });

    test('faixas: abaixo da atenção e do alarme, pelo número mostrado', () {
      OeePart oee(double pct) => OeePart(OeeState.good, fraction: pct / 100);
      expect(Oee.zone(oee(85), warn: 80, alarm: 60), OeeZone.normal);
      expect(Oee.zone(oee(80), warn: 80, alarm: 60), OeeZone.normal, reason: 'no limite não está abaixo');
      expect(Oee.zone(oee(79.9), warn: 80, alarm: 60), OeeZone.warn);
      expect(Oee.zone(oee(59.9), warn: 80, alarm: 60), OeeZone.alarm);
      expect(Oee.zone(oee(59.96), warn: 80, alarm: 60), OeeZone.warn, reason: 'aparece "60,0": não está abaixo de 60');
      expect(Oee.zone(oee(10)), OeeZone.normal, reason: 'sem faixas');
      expect(Oee.zone(oee(50), alarm: 60), OeeZone.alarm, reason: 'só alarme');
      expect(Oee.zone(const OeePart(OeeState.waiting), warn: 80), OeeZone.normal);
      // Parado (sem comunicação) continua mostrando a faixa do último valor, esmaecido.
      expect(Oee.zone(const OeePart(OeeState.stale, fraction: 0.5), warn: 80), OeeZone.warn);
    });

    test('formato: uma casa, vírgula, sem "-0,0"', () {
      expect(Oee.format(1), '100,0');
      expect(Oee.format(0.12345), '12,3');
      expect(Oee.format(-0.0000001), '0,0');
      expect(Oee.format(0), '0,0');
    });
  });

  // ── Arquivo e catálogo ──────────────────────────────────────────────────────

  group('arquivo e catálogo', () {
    test('no fim do enum; 6×3 (12×6 na fina), mínimo 3×3 (6×6); na paleta depois do medidor', () {
      expect(ElementType.values.last, ElementType.oee, reason: 'tipo novo entra no fim do enum');
      expect(ElementCatalog.defaultSize(ElementType.oee, 6), (6, 3));
      expect(ElementCatalog.defaultSize(ElementType.oee, 12), (12, 6));
      expect(ElementCatalog.minSize(ElementType.oee, 6), (3, 3));
      expect(ElementCatalog.minSize(ElementType.oee, 12), (6, 6));
      final order = ElementCatalog.all.map((i) => i.type).toList();
      expect(order.indexOf(ElementType.oee), order.indexOf(ElementType.gauge) + 1);
      expect(ElementCatalog.of(ElementType.oee).name, 'OEE');
      final props = ElementCatalog.defaultProps(ElementType.oee, tag: t);
      expect(props['tagIds'], isNull, reason: 'variável solta não tem papel: começa sem nenhuma');
      expect(props['source'], 'calc');
      expect(props['scale'], 'percent');
    });

    test('ida e volta em JSON de verdade, com vagas vazias na posição', () {
      const e = HmiElement(id: 'o', type: ElementType.oee, x: 0, y: 2, w: 6, h: 3, props: {
        'tagIds': ['d', null, 'q', null],
        'source': 'calc',
        'scale': 'fraction',
        'warn': 65,
        'alarm': 50.5,
        'label': 'OEE da linha 2',
      });
      final back = HmiElement.fromJson(jsonDecode(jsonEncode(e.toJson())) as Map<String, dynamic>);
      expect(back.type, ElementType.oee);
      expect(Oee.slots(back), ['d', null, 'q', null]);
      expect(back.tagIds, ['d', 'q']);
      expect(Oee.scaleOf(back), OeeScale.fraction);
      expect(Oee.sourceOf(back), OeeSource.calc);
      expect(back.props['warn'], 65);
      expect(back.props['alarm'], 50.5);
      expect(jsonEncode(back.toJson()), jsonEncode(e.toJson()));
      // Grade normal ↔ fina sem mexer na configuração.
      const s = HmiScreen(id: 's', name: 'S', elements: [e]);
      expect(s.withColumns(12)!.withColumns(6)!.toJson(), s.toJson());
    });

    test('arquivo mínimo ou de outra versão: padrões, e lista curta não quebra', () {
      final e = HmiElement.fromJson({'id': 'o', 'type': 'oee'});
      expect(e.type, ElementType.oee);
      expect(Oee.sourceOf(e), OeeSource.calc);
      expect(Oee.scaleOf(e), OeeScale.percent);
      expect(Oee.slots(e), [null, null, null, null]);
      expect(e.tagIds, isEmpty);
      final curta = HmiElement.fromJson({
        'id': 'o',
        'type': 'oee',
        'props': {
          'tagIds': ['d', 7],
          'source': 'algo novo',
        },
      });
      expect(Oee.slots(curta), ['d', null, null, null]);
      expect(Oee.sourceOf(curta), OeeSource.calc);
      expect(Oee.withSlot(Oee.slots(curta), 3, 'o'), ['d', null, null, 'o']);
      // No calculado, a vaga do OEE pronto não é lida.
      final calc = HmiElement.fromJson({
        'id': 'o',
        'type': 'oee',
        'props': {'tagIds': ['d', 'p', 'q', 'o'], 'source': 'calc'},
      });
      expect(Oee.liveSlots(calc), ['d', 'p', 'q', null]);
      expect(Oee.liveSlots(calc.withProp('source', 'tag')), ['d', 'p', 'q', 'o']);
    });

    test('"usada em" acha o OEE e pede número; a tela inscreve as vagas', () {
      const liga = Tag(id: 'liga', name: 'Liga', deviceId: 'x', dataType: TagDataType.bool);
      const d = Tag(id: 'd', name: 'Disponibilidade', deviceId: 'x');
      const p = Project(tags: [d, liga], screens: [
        HmiScreen(id: 's', name: 'Linha', elements: [
          HmiElement(id: 'o', type: ElementType.oee, x: 0, y: 0, w: 6, h: 3, props: {
            'tagIds': ['d', null, 'liga', null],
          }),
        ]),
      ]);
      final uses = TagUse.of(p, 'd');
      expect(uses.single.fit, TagFit.number);
      expect(uses.single.elementName, 'OEE');
      expect(TagUse.of(p, 'liga').single.fit.accepts(liga), isFalse, reason: 'liga/desliga não serve no OEE');
      expect(p.screens.single.liveTagIds, {'d', 'liga'});
      expect(p.screensUsingTag('d').single.id, 's');
    });
  });

  // ── Na tela de verdade ──────────────────────────────────────────────────────

  late Directory dir;
  late ModbusMemory memory;
  late SimulatedModbusClient client;

  // As fontes de verdade (IBM Plex), e não a de teste, em que cada letra é um
  // quadrado: "cortado com …" depende da largura real do texto.
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
    dir = await Directory.systemTemp.createTemp('ihm_oee');
    memory = ModbusMemory(holdingRegisters: 1000, coils: 100);
    client = SimulatedModbusClient(memory: memory, latency: Duration.zero);
  });

  tearDown(() async {
    await AppearanceController.instance.set(Appearance.auto);
    Ind.use(IndPalette.escuro);
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {/* Windows ainda segurando o arquivo */}
  });

  const clp = Device(id: 'clp', name: 'CLP da linha', host: '10.0.0.5', pollMs: 500);
  Tag reg(String id, String name, int address, {TagDataType type = TagDataType.uint16, int decimals = 0}) =>
      Tag(id: id, name: name, deviceId: clp.id, address: address, dataType: type, decimals: decimals, unit: type == TagDataType.float32 ? '' : '%');
  final tags = [
    reg('d', 'Disponibilidade', 100),
    reg('p', 'Desempenho', 101),
    reg('q', 'Qualidade', 102),
    reg('o', 'OEE do CLP', 103),
    reg('df', 'Disponibilidade (fração)', 110, type: TagDataType.float32, decimals: 2),
    reg('pf', 'Desempenho (fração)', 112, type: TagDataType.float32, decimals: 2),
    reg('qf', 'Qualidade (fração)', 114, type: TagDataType.float32, decimals: 2),
    reg('ruim', 'Endereço errado', 5000),
  ];

  List<int> float32(double v) {
    final b = ByteData(4)..setFloat32(0, v);
    return [b.getUint16(0), b.getUint16(2)];
  }

  void seed({int d = 90, int p = 85, int q = 98, int o = 72}) {
    for (final (addr, v) in [(100, d), (101, p), (102, q), (103, o)]) {
      memory.pokeRegister(ModbusArea.holdingRegister, addr, v);
    }
    for (final (addr, v) in [(110, 0.9), (112, 0.85), (114, 0.98)]) {
      memory.pokeRegisters(ModbusArea.holdingRegister, addr, float32(v));
    }
  }

  HmiElement oee({
    List<String?> slots = const ['d', 'p', 'q', null],
    String source = 'calc',
    String scale = 'percent',
    num? warn,
    num? alarm,
    int w = 6,
    int h = 3,
  }) =>
      HmiElement(id: 'oee', type: ElementType.oee, x: 0, y: 0, w: w, h: h, props: {
        'tagIds': slots,
        'source': source,
        'scale': scale,
        'label': 'OEE',
        'warn': ?warn,
        'alarm': ?alarm,
      });

  Project project(List<HmiElement> elements, {int columns = 6}) =>
      Project(name: 'T', devices: const [clp], tags: tags, screens: [HmiScreen(id: 'a', name: 'Linha 2', columns: columns, elements: elements)]);

  Future<ProjectController> boot(WidgetTester tester, Project p, {Size dp = const Size(390, 844), bool dark = true}) async {
    // O app aplica a paleta no main() e ao trocar: aqui, antes de montar.
    await AppearanceController.instance.set(dark ? Appearance.escuro : Appearance.claro);
    Ind.use(AppearanceController.instance.resolve());
    final rt = HmiRuntime(clientFactory: (_) => client);
    final repo = ProjectRepository(directory: dir);
    await tester.runAsync(() => repo.save(p));
    final controller = ProjectController(repository: repo, runtime: rt);
    await tester.runAsync(controller.load);
    tester.view.physicalSize = dp;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CeliwareIhmApp(controller: controller, runtime: rt));
    await live(tester, 600);
    expect(Ind.isDark, dark);
    return controller;
  }

  Future<void> shutdown(WidgetTester tester, ProjectController c) async {
    await tester.pumpWidget(const SizedBox());
    final done = c.runtime.dispose();
    await live(tester, 1200);
    await done;
    c.dispose();
  }

  Future<void> open(WidgetTester tester, Widget page) async {
    tester.state<NavigatorState>(find.byType(Navigator).first).push(MaterialPageRoute<void>(builder: (_) => page));
    await live(tester, 1200);
  }

  final el = find.byType(OeeElement);
  Finder inEl(Finder f) => find.descendant(of: el, matching: f);
  Finder inPart(int i, Finder f) => find.descendant(of: find.byKey(ValueKey('oee-parcela-$i')), matching: f);
  bool cut(WidgetTester tester, Finder text) => tester.renderObject<RenderParagraph>(text).didExceedMaxLines;

  /// Nenhum texto do elemento cortado, nada fora do cartão, nada transbordando.
  void expectWhole(WidgetTester tester) {
    final card = tester.getRect(el);
    for (final p in find.descendant(of: el, matching: find.byType(RichText)).evaluate()) {
      final paragraph = p.renderObject! as RenderParagraph;
      final text = paragraph.text.toPlainText();
      expect(paragraph.didExceedMaxLines, isFalse, reason: '"$text" cortado');
      final r = paragraph.localToGlobal(Offset.zero) & paragraph.size;
      final inside = r.left >= card.left - 0.5 && r.right <= card.right + 0.5 && r.top >= card.top - 0.5 && r.bottom <= card.bottom + 0.5;
      expect(inside, isTrue, reason: '"$text" sai do cartão ($r fora de $card)');
    }
    expect(tester.takeException(), isNull);
  }

  /// Altura com que o texto aparece (já com o encolhimento do FittedBox).
  double shownHeight(WidgetTester tester, Finder text) {
    final box = tester.renderObject<RenderBox>(text);
    final a = box.localToGlobal(Offset.zero), b = box.localToGlobal(Offset(0, box.size.height));
    return b.dy - a.dy;
  }

  for (final width in [320.0, 360.0, 390.0]) {
    for (final dark in [true, false]) {
      testWidgets('${width.toInt()} dp, ${dark ? 'escuro' : 'claro'}: tamanho padrão mostra os 4 números legíveis e os nomes inteiros', (tester) async {
        seed();
        final c = await boot(tester, project([oee()]), dp: Size(width, 800), dark: dark);
        await open(tester, const ScreenRunPage(screenId: 'a'));

        expect(inEl(find.text('75,0')), findsOneWidget);
        for (final (i, v, name) in [(0, '90,0', 'DISPONIBILIDADE'), (1, '85,0', 'DESEMPENHO'), (2, '98,0', 'QUALIDADE')]) {
          expect(inPart(i, find.text(v)), findsOneWidget);
          expect(inPart(i, find.text(name)), findsOneWidget, reason: 'nome inteiro em ${width.toInt()} dp');
          expect(shownHeight(tester, inPart(i, find.text(v))), greaterThanOrEqualTo(16), reason: 'parcela legível');
        }
        expect(inEl(find.text('OEE')), findsOneWidget);
        expect(shownHeight(tester, inEl(find.text('75,0'))), greaterThanOrEqualTo(30), reason: 'o OEE é o destaque');
        // Lado a lado: o OEE à esquerda das parcelas.
        expect(tester.getRect(inEl(find.text('75,0'))).right, lessThan(tester.getRect(inPart(0, find.text('90,0'))).left));
        // Sem faixa configurada, sem cor nem ícone de estado.
        expect(tester.widget<Text>(inEl(find.text('75,0'))).style!.color, Ind.text);
        expect(inEl(find.byIcon(Icons.warning_amber_rounded)), findsNothing);
        expectWhole(tester);
        await shutdown(tester, c);
      });
    }
  }

  testWidgets('grade fina no celular de 320 dp: 12×6 com os nomes inteiros', (tester) async {
    seed();
    final c = await boot(tester, project([oee(w: 12, h: 6)], columns: 12), dp: const Size(320, 800));
    await open(tester, const ScreenRunPage(screenId: 'a'));
    expect(inEl(find.text('75,0')), findsOneWidget);
    for (final (i, name) in [(0, 'DISPONIBILIDADE'), (1, 'DESEMPENHO'), (2, 'QUALIDADE')]) {
      expect(inPart(i, find.text(name)), findsOneWidget);
    }
    expectWhole(tester);
    await shutdown(tester, c);
  });

  testWidgets('mínimo (3×3) no celular de 320 dp: OEE em cima, parcelas em linha, encolhe junto sem cortar', (tester) async {
    seed();
    final c = await boot(tester, project([oee(w: 3, h: 3)]), dp: const Size(320, 800));
    await open(tester, const ScreenRunPage(screenId: 'a'));
    expect(inEl(find.text('75,0')), findsOneWidget);
    for (final v in ['90,0', '85,0', '98,0']) {
      expect(inEl(find.text(v)), findsOneWidget);
    }
    expect(tester.getRect(inEl(find.text('75,0'))).bottom, lessThanOrEqualTo(tester.getRect(inPart(0, find.text('90,0'))).top));
    // Os três nomes inteiros ou os três abreviados, nunca misturados.
    final full = [for (final n in ['DISPONIBILIDADE', 'DESEMPENHO', 'QUALIDADE']) inEl(find.text(n)).evaluate().length];
    final short = [for (final n in ['DISP.', 'DESEMP.', 'QUAL.']) inEl(find.text(n)).evaluate().length];
    expect(full.every((n) => n == 1) || short.every((n) => n == 1), isTrue, reason: 'inteiros $full, abreviados $short');
    expectWhole(tester);
    await shutdown(tester, c);
  });

  testWidgets('tablet deitado: o OEE cresce com a célula, nada transborda', (tester) async {
    seed();
    final c = await boot(tester, project([oee()]), dp: const Size(1280, 800));
    await open(tester, const ScreenRunPage(screenId: 'a'));
    expect(shownHeight(tester, inEl(find.text('75,0'))), greaterThan(40), reason: 'cresce com a célula');
    expectWhole(tester);
    await shutdown(tester, c);
  });

  for (final dark in [true, false]) {
    testWidgets('faixas (${dark ? 'escuro' : 'claro'}): atenção e alarme com cor de estado e ícone; acima delas, neutro', (tester) async {
      seed();
      final c = await boot(tester, project([oee(warn: 80, alarm: 60)]), dark: dark);
      await open(tester, const ScreenRunPage(screenId: 'a'));

      // 75,0 < 80: atenção.
      expect(tester.widget<Text>(inEl(find.text('75,0'))).style!.color, Ind.textFor(Ind.warn));
      expect(find.byKey(const ValueKey('oee-faixa-warn')), findsOneWidget);

      // Disponibilidade cai para 70: 70 × 85 × 98 = 58,3 % < 60: alarme.
      memory.pokeRegister(ModbusArea.holdingRegister, 100, 70);
      await live(tester, 900);
      expect(tester.widget<Text>(inEl(find.text('58,3'))).style!.color, Ind.textFor(Ind.alarm));
      expect(find.byKey(const ValueKey('oee-faixa-alarm')), findsOneWidget);
      expect(find.byKey(const ValueKey('oee-faixa-warn')), findsNothing);
      // As parcelas não ganham cor: estado é do OEE.
      expect(tester.widget<Text>(inPart(0, find.text('70,0'))).style!.color, Ind.text);

      // Volta a 100 × 85 × 98 = 83,3 %: neutro de novo.
      memory.pokeRegister(ModbusArea.holdingRegister, 100, 100);
      await live(tester, 900);
      expect(tester.widget<Text>(inEl(find.text('83,3'))).style!.color, Ind.text);
      expect(find.byKey(const ValueKey('oee-faixa-alarm')), findsNothing);
      expectWhole(tester);
      await shutdown(tester, c);
    });
  }

  testWidgets('alarme da variável de uma parcela: a forma do alarme na linha dela e a borda do cartão', (tester) async {
    seed();
    final comAlarme = [
      for (final t in tags)
        t.id == 'q'
            ? t.copyWith(alarms: const [
                AlarmRule(id: 'al_q', kind: AlarmKind.below, limit: 95, priority: AlarmPriority.high, message: 'Qualidade baixa'),
              ])
            : t,
    ];
    final c = await boot(tester, Project(name: 'T', devices: const [clp], tags: comAlarme, screens: [
      HmiScreen(id: 'a', name: 'Linha 2', elements: [oee()]),
    ]), dp: const Size(320, 800));
    await open(tester, const ScreenRunPage(screenId: 'a'));
    expect(inEl(find.byType(AlarmShape)), findsNothing);

    // Qualidade cai para 90 (abaixo de 95): depois de 1 s vira alarme.
    memory.pokeRegister(ModbusArea.holdingRegister, 102, 90);
    await live(tester, 2500);
    expect(inPart(2, find.byType(AlarmShape)), findsOneWidget);
    expect(inPart(0, find.byType(AlarmShape)), findsNothing);
    final card = tester.widget<Container>(find.descendant(of: el, matching: find.byType(Container)).first);
    expect(((card.decoration! as BoxDecoration).border! as Border).top.color, AlarmPriority.high.color);
    // A forma ocupa lugar nas três linhas: os nomes continuam iguais entre si.
    expect(inPart(2, find.text('QUALIDADE')).evaluate().length + inPart(2, find.text('QUAL.')).evaluate().length, 1);
    expectWhole(tester);
    await shutdown(tester, c);
  });

  testWidgets('sem comunicação: o último valor esmaecido com o ícone — nunca um zero falso', (tester) async {
    seed();
    final c = await boot(tester, project([oee()]));
    await open(tester, const ScreenRunPage(screenId: 'a'));
    expect(inEl(find.text('75,0')), findsOneWidget);

    client.failureRate = 1;
    await live(tester, 3000);
    expect(c.runtime.store.read('d').quality, TagQuality.commLost);
    for (final (i, v) in [(0, '90,0'), (1, '85,0'), (2, '98,0')]) {
      expect(inPart(i, find.text(v)), findsOneWidget);
      expect(inPart(i, find.byIcon(Icons.wifi_off_rounded)), findsOneWidget);
      final fade = tester.widget<Opacity>(find.ancestor(of: inPart(i, find.text(v)), matching: find.byType(Opacity)).first);
      expect(fade.opacity, lessThan(0.5));
    }
    // O OEE foi feito com valores velhos: também esmaecido, com o ícone na placa.
    expect(inEl(find.text('75,0')), findsOneWidget);
    expect(tester.widget<Opacity>(find.ancestor(of: inEl(find.text('75,0')), matching: find.byType(Opacity)).first).opacity, lessThan(0.5));
    expect(inEl(find.byIcon(Icons.wifi_off_rounded)), findsNWidgets(4));
    expect(inEl(find.textContaining(RegExp(r'^0,0'))), findsNothing);

    client.failureRate = 0;
    await live(tester, 12000);
    expect(inEl(find.byIcon(Icons.wifi_off_rounded)), findsNothing);
    expectWhole(tester);
    await shutdown(tester, c);
  });

  testWidgets('sem nenhuma leitura: "---" esmaecido, nunca 0 %', (tester) async {
    seed();
    client.failureRate = 1;
    final c = await boot(tester, project([oee()]));
    await open(tester, const ScreenRunPage(screenId: 'a'));
    await live(tester, 3000);
    expect(inEl(find.text('---')), findsNWidgets(4));
    expect(inEl(find.textContaining(RegExp(r'^0,0'))), findsNothing);
    expect(inEl(find.text('%')), findsNothing, reason: 'sem número, sem unidade');
    expectWhole(tester);

    // A comunicação chega: os números aparecem.
    client.failureRate = 0;
    await live(tester, 12000);
    expect(inEl(find.text('75,0')), findsOneWidget);
    await shutdown(tester, c);
  });

  testWidgets('vaga vazia pede a variável; endereço recusado mostra o motivo; o OEE fica sem número', (tester) async {
    seed();
    final c = await boot(tester, project([oee(slots: ['d', 'ruim', null, null])]));
    await open(tester, const ScreenRunPage(screenId: 'a'));

    expect(inPart(0, find.text('90,0')), findsOneWidget);
    expect(inPart(1, find.byIcon(Icons.error_outline_rounded)), findsOneWidget);
    expect(inPart(1, find.textContaining('endereço')), findsOneWidget);
    expect(inPart(2, find.text('Escolha')), findsOneWidget);
    expect(inEl(find.text('---')), findsOneWidget, reason: 'o OEE');
    // Borda de "falta configurar" (cor de interação) no cartão.
    final card = tester.widget<Container>(find.descendant(of: el, matching: find.byType(Container)).first);
    expect(((card.decoration! as BoxDecoration).border! as Border).top.color, Ind.accent);
    expect(tester.takeException(), isNull);
    await shutdown(tester, c);
  });

  testWidgets('OEE pronto do equipamento e escala trocada: mostra o que veio, marcado, sem inventar OEE', (tester) async {
    seed();
    final c = await boot(tester, project([oee(slots: ['d', 'p', 'q', 'o'], source: 'tag')]), dp: const Size(320, 800));
    await open(tester, const ScreenRunPage(screenId: 'a'));
    expect(inEl(find.text('72,0')), findsOneWidget, reason: 'o do CLP, não o calculado (75,0)');
    expect(inEl(find.text('75,0')), findsNothing);

    // Mesmas variáveis com a escala de 0 a 1: o CLP manda 90 → 9000 %.
    final screen = c.project.screen('a')!;
    c.saveScreen(screen.copyWith(elements: [oee(scale: 'fraction')]));
    await live(tester, 900);
    expect(inPart(0, find.text('9000,0')), findsOneWidget);
    expect(inPart(0, find.byIcon(Icons.warning_amber_rounded)), findsOneWidget);
    expect(inEl(find.text('---')), findsOneWidget, reason: 'o produto não é calculado');
    expect(inEl(find.text('Confira a escala')), findsOneWidget);

    // As variáveis certas para 0 a 1 (número com vírgula).
    c.saveScreen(screen.copyWith(elements: [oee(slots: ['df', 'pf', 'qf', null], scale: 'fraction')]));
    await live(tester, 900);
    expect(inEl(find.text('75,0')), findsOneWidget);
    expect(inEl(find.text('Confira a escala')), findsNothing);
    expectWhole(tester);
    await shutdown(tester, c);
  });

  testWidgets('pelo editor em 320 dp: paleta, uma variável por vaga, escala, OEE pronto e faixas', (tester) async {
    seed();
    final c = await boot(tester, project(const []), dp: const Size(320, 800));
    await open(tester, const ScreenEditorPage(screenId: 'a'));

    await tester.tap(find.text('Elemento'));
    await live(tester, 600);
    final card = find.byKey(const ValueKey('paleta-oee'));
    await tester.scrollUntilVisible(card, 120, scrollable: find.descendant(of: find.byType(PaletteSheet), matching: find.byType(Scrollable)).first);
    await live(tester, 200);
    expect(cut(tester, find.descendant(of: card, matching: find.text('Eficiência global da máquina.'))), isFalse);
    expect(find.descendant(of: card, matching: find.byIcon(Icons.space_dashboard_outlined)), findsOneWidget);
    await tester.tap(card);
    await live(tester, 900);

    HmiElement current() => c.project.screen('a')!.elements.single;
    expect(current().type, ElementType.oee);
    expect([current().w, current().h], [6, 3]);

    final sheet = find.descendant(of: find.byType(DraggableScrollableSheet), matching: find.byType(Scrollable)).first;
    // Rola a folha até o alvo ([delta] < 0 = para cima) e o põe inteiro à vista.
    Future<void> reveal(Finder f, double delta) async {
      await tester.scrollUntilVisible(f, delta, scrollable: sheet);
      await tester.ensureVisible(f);
      await live(tester, 300);
    }

    Future<void> tapIn(Finder f, double delta) async {
      await reveal(f, delta);
      await tester.tap(f);
      await live(tester, 400);
    }

    Future<void> pick(int slot, String tagId) async {
      await tapIn(find.descendant(of: find.byKey(ValueKey('oee-vaga-$slot')), matching: find.byKey(const ValueKey('escolher-variavel'))), 150);
      await live(tester, 200);
      await tester.tap(find.byKey(ValueKey('escolher-$tagId')));
      await live(tester, 600);
    }

    await pick(0, 'd');
    await pick(1, 'p');
    await pick(2, 'q');
    expect(Oee.slots(current()), ['d', 'p', 'q', null]);
    expect(find.byKey(const ValueKey('oee-vaga-3')), findsNothing, reason: 'calculado: sem a vaga do OEE pronto');

    // Escala de 0 a 1 e volta.
    await tapIn(find.byKey(const ValueKey('opcao-OeeScale.fraction')), -150);
    expect(Oee.scaleOf(current()), OeeScale.fraction);
    await tapIn(find.byKey(const ValueKey('opcao-OeeScale.percent')), -150);
    expect(Oee.scaleOf(current()), OeeScale.percent);

    // OEE pronto: aparece a quarta vaga; voltar ao calculado solta ela.
    await tapIn(find.byKey(const ValueKey('opcao-OeeSource.tag')), -150);
    expect(Oee.sourceOf(current()), OeeSource.tag);
    await pick(3, 'o');
    expect(Oee.slots(current()), ['d', 'p', 'q', 'o']);
    await tapIn(find.byKey(const ValueKey('opcao-OeeSource.calc')), -150);
    expect(Oee.sourceOf(current()), OeeSource.calc);
    expect(Oee.slots(current()), ['d', 'p', 'q', null], reason: 'a vaga do OEE pronto se solta');
    expect(current().tagIds, ['d', 'p', 'q']);
    expect(find.byKey(const ValueKey('oee-vaga-3')), findsNothing);

    // Faixas, com vírgula; rótulos inteiros no meio da largura do celular.
    for (final (key, label, text, prop, value) in [
      ('faixa-atencao-oee', 'Atenção', '80', 'warn', 80),
      ('faixa-alarme-oee', 'Alarme', '62,5', 'alarm', 62.5),
    ]) {
      final field = find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(EditableText));
      await reveal(field, 150);
      expect(cut(tester, find.descendant(of: find.byKey(ValueKey(key)), matching: find.text(label))), isFalse, reason: label);
      await tester.enterText(field, text);
      await live(tester, 300);
      expect(current().props[prop], value);
    }

    // A prévia no topo da folha já mostra o OEE ao vivo, na faixa de atenção.
    final preview = find.descendant(of: find.byType(DraggableScrollableSheet), matching: find.byType(OeeElement));
    await reveal(preview, -300);
    expect(find.descendant(of: preview, matching: find.text('75,0')), findsOneWidget);
    expect(find.descendant(of: preview, matching: find.byKey(const ValueKey('oee-faixa-warn'))), findsOneWidget);
    expect(tester.takeException(), isNull);
    await shutdown(tester, c);
  });
}

/// Avança o relógio simulado em passos de 100 ms (varredura e timers andam).
Future<void> live(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
