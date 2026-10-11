import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/modbus/modbus_client_simulated.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/alarm.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/hmi_screen.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/screens/editor/screen_editor_page.dart';
import 'package:ihm/screens/screen_run_page.dart';
import 'package:ihm/screens/tags/tag_uses.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/runtime/tag_store.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:ihm/widgets/alarms/alarm_widgets.dart';
import 'package:ihm/widgets/hmi/element_catalog.dart';
import 'package:ihm/widgets/hmi/elements/table_element.dart';
import 'package:ihm/widgets/hmi/hmi_canvas.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tabela de valores (GR-7) e densidade da grade fina (GR-8), pela interface
/// de verdade e no relógio simulado, como em `app_flow_test.dart`.
///
/// O equipamento é um "CLP" Modbus TCP cujo cliente fala com uma memória do
/// próprio teste (`SimulatedModbusClient`): o teste muda um registrador e vê a
/// linha mudar, derruba a comunicação e vê a linha esmaecer.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  late Directory dir;
  late ModbusMemory memory;
  late SimulatedModbusClient client;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      for (final (id, _, _) in Tours.catalog) 'tour:v1:$id': true,
    });
    dir = await Directory.systemTemp.createTemp('ihm_tabela');
    memory = ModbusMemory(holdingRegisters: 1000, coils: 100);
    client = SimulatedModbusClient(memory: memory, latency: Duration.zero);
  });

  tearDown(() async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {/* Windows ainda segurando o arquivo */}
  });

  Future<ProjectController> boot(WidgetTester tester, Project project,
      {HmiRuntime? runtime, Size size = const Size(1080, 2400), double dpr = 2.75}) async {
    final rt = runtime ?? HmiRuntime(clientFactory: (_) => client);
    final repo = ProjectRepository(directory: dir);
    await tester.runAsync(() => repo.save(project));
    final controller = ProjectController(repository: repo, runtime: rt);
    await tester.runAsync(controller.load);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CeliwareIhmApp(controller: controller, runtime: rt));
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

  Future<void> open(WidgetTester tester, Widget page) async {
    tester.state<NavigatorState>(find.byType(Navigator).first).push(MaterialPageRoute<void>(builder: (_) => page));
    await live(tester, 1200);
  }

  Finder row(String tagId) => find.byWidgetPredicate((w) => w is TableValueRow && w.tag.id == tagId);
  Finder inRow(String tagId, Finder f) => find.descendant(of: row(tagId), matching: f);

  group('catálogo', () {
    test('tamanho padrão e mínimo nas grades normal e fina', () {
      expect(ElementCatalog.defaultSize(ElementType.table, 6), (6, 4));
      expect(ElementCatalog.defaultSize(ElementType.table, 12), (12, 8));
      expect(ElementCatalog.minSize(ElementType.table, 6), (3, 2));
      expect(ElementCatalog.minSize(ElementType.table, 12), (6, 4));
      expect(ElementCatalog.of(ElementType.table).fit, TagFit.any);
      expect(ElementType.values.last, ElementType.table, reason: 'tipo novo entra no fim do enum');
    });

    test('ida e volta no arquivo; grade normal ↔ fina sem mexer na tabela', () {
      const e = HmiElement(id: 't', type: ElementType.table, x: 0, y: 1, w: 6, h: 4, props: {
        'tagIds': ['a', 'b', 'c'],
        'label': 'Forno',
      });
      final back = HmiElement.fromJson(e.toJson());
      expect(back.type, ElementType.table);
      expect(back.tagIds, ['a', 'b', 'c']);
      const s = HmiScreen(id: 's', name: 'S', elements: [e]);
      final fina = s.withColumns(12)!;
      expect([fina.elements.single.w, fina.elements.single.h], [12, 8]);
      expect(fina.withColumns(6)!.toJson(), s.toJson());
    });

    test('a tela não inscreve as linhas da tabela; a própria tabela inscreve', () {
      const s = HmiScreen(id: 's', name: 'S', elements: [
        HmiElement(id: 'v', type: ElementType.value, x: 0, y: 0, w: 3, h: 2, props: {'tagId': 'x'}),
        HmiElement(id: 't', type: ElementType.table, x: 0, y: 2, w: 6, h: 4, props: {
          'tagIds': ['a', 'b'],
        }),
      ]);
      expect(s.tagIds, {'x', 'a', 'b'}, reason: 'equipamentos da faixa e "usada em" contam a tabela');
      expect(s.liveTagIds, {'x'});
    });

    test('"usada em": linha da tabela aceita qualquer valor único, inclusive texto', () {
      const texto = Tag(id: 'a', name: 'Receita', deviceId: 'd', dataType: TagDataType.string, length: 4);
      const p = Project(tags: [texto], screens: [
        HmiScreen(id: 's', name: 'S', elements: [
          HmiElement(id: 't', type: ElementType.table, x: 0, y: 0, w: 6, h: 4, props: {
            'tagIds': ['a'],
          }),
        ]),
      ]);
      final uses = TagUse.of(p, 'a');
      expect(uses.single.fit, TagFit.any);
      expect(uses.single.fit.accepts(texto), isTrue);
    });
  });

  // ── Projeto do teste ────────────────────────────────────────────────────────

  const clp = Device(id: 'clp', name: 'CLP da linha', host: '10.0.0.5', pollMs: 500);

  Tag reg(String id, String name, int address,
          {String unit = '', bool writable = false, TagDataType type = TagDataType.uint16, int decimals = 0, List<AlarmRule> alarms = const []}) =>
      Tag(id: id, name: name, deviceId: clp.id, address: address, dataType: type, unit: unit, writable: writable, decimals: decimals, alarms: alarms);

  final tags = [
    reg('sp', 'Velocidade desejada', 200, unit: 'm/min', writable: true),
    reg('temp', 'Temperatura do forno', 202, unit: '°C', type: TagDataType.float32, decimals: 1),
    const Tag(id: 'porta', name: 'Porta', deviceId: 'clp', area: ModbusArea.coil, address: 5, dataType: TagDataType.bool, writable: true),
    reg('nome', 'Receita', 210, type: TagDataType.string).copyWith(length: 4),
    reg('ruim', 'Endereço errado', 5000),
    reg('pressao', 'Pressão', 220, unit: 'bar', alarms: const [
      AlarmRule(id: 'al_p', kind: AlarmKind.above, limit: 50, priority: AlarmPriority.high, message: 'Pressão alta'),
    ]),
    for (var i = 0; i < 46; i++) reg('v$i', 'Variável $i', 300 + i, unit: i.isEven ? 'A' : ''),
  ];

  HmiScreen tela(String id, List<HmiElement> elements, {int columns = 6, bool readOnly = false}) =>
      HmiScreen(id: id, name: 'Tela $id', columns: columns, readOnly: readOnly, elements: elements);

  HmiElement tabela(String id, List<String> ids, {int x = 0, int y = 0, int w = 6, int h = 4, Map<String, dynamic> extra = const {}}) =>
      HmiElement(id: id, type: ElementType.table, x: x, y: y, w: w, h: h, props: {'tagIds': ids, 'label': '', 'onText': 'FECHADA', 'offText': 'ABERTA', ...extra});

  void seed() {
    memory.pokeRegister(ModbusArea.holdingRegister, 200, 80);
    memory.pokeRegisters(ModbusArea.holdingRegister, 202, const [0x4291, 0x0000]); // 72,5 em float32
    memory.pokeBit(ModbusArea.coil, 5, true);
    memory.pokeRegisters(ModbusArea.holdingRegister, 210, [0x4C4F, 0x5445, 0x2037, 0]); // "LOTE 7"
    memory.pokeRegister(ModbusArea.holdingRegister, 220, 30);
    for (var i = 0; i < 46; i++) {
      memory.pokeRegister(ModbusArea.holdingRegister, 300 + i, 1000 + i);
    }
  }

  testWidgets('monta com valores ao vivo: unidade, liga/desliga com o texto da tabela, texto lido', (tester) async {
    seed();
    final c = await boot(tester, Project(name: 'T', devices: const [clp], tags: tags, screens: [
      tela('a', [tabela('tab', ['sp', 'temp', 'porta', 'nome'])]),
    ]));
    await open(tester, const ScreenRunPage(screenId: 'a'));

    expect(find.byType(TableValueRow), findsNWidgets(4));
    expect(inRow('sp', find.text('80')), findsOneWidget);
    expect(inRow('sp', find.text('m/min')), findsOneWidget);
    expect(inRow('temp', find.text('72,5')), findsOneWidget);
    expect(inRow('porta', find.text('FECHADA')), findsOneWidget);
    expect(inRow('nome', find.text('LOTE 7')), findsOneWidget);
    // A ordem das linhas é a da configuração.
    final ys = [for (final id in ['sp', 'temp', 'porta', 'nome']) tester.getRect(row(id)).top];
    expect(ys, orderedEquals([...ys]..sort()));

    // O equipamento muda: só a linha dele muda.
    memory.pokeRegister(ModbusArea.holdingRegister, 200, 95);
    memory.pokeBit(ModbusArea.coil, 5, false);
    await live(tester, 700);
    expect(inRow('sp', find.text('95')), findsOneWidget);
    expect(inRow('porta', find.text('ABERTA')), findsOneWidget);
    await shutdown(tester, c);
  });

  testWidgets('qualidade por linha: endereço recusado, sem comunicação com o último valor e alarme', (tester) async {
    seed();
    final c = await boot(tester, Project(name: 'T', devices: const [clp], tags: tags, screens: [
      tela('a', [tabela('tab', ['sp', 'ruim', 'pressao'])]),
    ]));
    await open(tester, const ScreenRunPage(screenId: 'a'));

    // Endereço que não existe: o motivo em vermelho na linha dele; as outras seguem.
    expect(inRow('ruim', find.byIcon(Icons.error_outline_rounded)), findsOneWidget);
    expect(inRow('ruim', find.textContaining('endereço')), findsOneWidget);
    expect(inRow('sp', find.text('80')), findsOneWidget);

    // Alarme da variável: a forma da prioridade aparece na linha (depois de 1 s).
    memory.pokeRegister(ModbusArea.holdingRegister, 220, 70);
    await live(tester, 2500);
    expect(inRow('pressao', find.byType(AlarmShape)), findsOneWidget);
    expect(inRow('sp', find.byType(AlarmShape)), findsNothing);

    // Queda: último valor esmaecido + ícone de sem comunicação — nunca um zero falso.
    client.failureRate = 1;
    await live(tester, 3000);
    expect(c.runtime.store.read('sp').quality, TagQuality.commLost);
    expect(inRow('sp', find.byIcon(Icons.wifi_off_rounded)), findsOneWidget);
    expect(inRow('sp', find.text('80')), findsOneWidget);
    final fade = tester.widget<Opacity>(find.ancestor(of: inRow('sp', find.text('80')), matching: find.byType(Opacity)).first);
    expect(fade.opacity, lessThan(0.5));

    // Voltou: some o ícone.
    client.failureRate = 0;
    await live(tester, 12000);
    expect(c.runtime.store.read('sp').quality, TagQuality.good);
    expect(inRow('sp', find.byIcon(Icons.wifi_off_rounded)), findsNothing);
    await shutdown(tester, c);
  });

  testWidgets('tocar numa linha gravável abre o teclado e grava; liga/desliga e tela só acompanhamento não', (tester) async {
    seed();
    final c = await boot(tester, Project(name: 'T', devices: const [clp], tags: tags, screens: [
      tela('a', [tabela('tab', ['sp', 'temp', 'porta'])]),
      tela('b', [tabela('tab2', ['sp'])], readOnly: true),
    ]));
    await open(tester, const ScreenRunPage(screenId: 'a'));

    expect(find.byKey(const ValueKey('ajustar-sp')), findsOneWidget);
    expect(find.byKey(const ValueKey('ajustar-temp')), findsNothing, reason: 'só leitura');
    expect(find.byKey(const ValueKey('ajustar-porta')), findsNothing, reason: 'comando é com o Botão');
    expect(inRow('sp', find.byIcon(Icons.edit_rounded)), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ajustar-sp')));
    await live(tester, 400);
    expect(find.byKey(const ValueKey('numpad-visor')), findsOneWidget);
    for (final k in ['1', '2', '0']) {
      await tester.tap(find.byKey(ValueKey('tecla-$k')));
      await tester.pump();
    }
    await tester.tap(find.byKey(const ValueKey('numpad-ok')));
    await live(tester, 400);
    // A confirmação da tela vale também para a linha.
    expect(find.text('De 80 m/min para 120 m/min?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirmar-escrita')));
    await live(tester, 800);
    expect(memory.register(ModbusArea.holdingRegister, 200), 120);
    expect(inRow('sp', find.text('120')), findsOneWidget);

    Navigator.of(tester.element(find.byType(ScreenRunPage))).pop();
    await live(tester, 400);
    await open(tester, const ScreenRunPage(screenId: 'b'));
    expect(find.byKey(const ValueKey('ajustar-sp')), findsNothing, reason: 'tela só de acompanhamento');
    await shutdown(tester, c);
  });

  testWidgets('tabela que rola lê só as linhas à vista, e rolar troca a inscrição', (tester) async {
    seed();
    final runtime = _CountingRuntime(client);
    final ids = [for (var i = 0; i < 30; i++) 'v$i'];
    final c = await boot(tester, Project(name: 'T', devices: const [clp], tags: tags, screens: [
      // 6×3 na grade normal: ~5 linhas à vista de 30.
      tela('a', [tabela('tab', ids, h: 3)]),
    ]), runtime: runtime);
    await open(tester, const ScreenRunPage(screenId: 'a'));

    final mounted = find.byType(TableValueRow).evaluate().length;
    expect(mounted, lessThan(10), reason: 'só as linhas à vista (e uma de folga) são montadas');
    final biggest = runtime.calls.fold<int>(0, (m, s) => math.max(m, s.length));
    expect(biggest, lessThan(10), reason: 'só as linhas à vista são lidas');
    expect(c.runtime.store.read('v0').quality, TagQuality.good);
    expect(c.runtime.store.read('v29').quality, TagQuality.waiting);

    final list = find.descendant(of: find.byType(TableElement), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(row('v29'), 200, scrollable: list);
    await live(tester, 1200);
    expect(c.runtime.store.read('v29').quality, TagQuality.good);
    expect(inRow('v29', find.text('1029')), findsOneWidget);
    expect(runtime.calls.last, contains('v29'));
    expect(runtime.calls.last, isNot(contains('v0')));
    expect(runtime.calls.every((s) => s.length < 10), isTrue);
    await shutdown(tester, c);
  });

  testWidgets('pelo editor: paleta põe a tabela na grade fina, escolher várias, reordenar e tirar', (tester) async {
    seed();
    final c = await boot(tester, Project(name: 'T', devices: const [clp], tags: tags, screens: [tela('a', const [], columns: 12)]));
    await open(tester, const ScreenEditorPage(screenId: 'a'));

    await tester.tap(find.text('Elemento'));
    await live(tester, 600);
    await tester.tap(find.byKey(const ValueKey('paleta-table')));
    await live(tester, 900);
    var e = c.project.screen('a')!.elements.single;
    expect(e.type, ElementType.table);
    expect([e.w, e.h], [12, 8], reason: 'tamanho padrão dobrado na grade fina');

    // A folha abriu sozinha; a escolha marca várias de uma vez.
    await tester.tap(find.byKey(const ValueKey('escolher-variaveis')));
    await live(tester, 600);
    for (final id in ['sp', 'temp', 'porta', 'nome']) {
      await tester.tap(find.byKey(ValueKey('marcar-$id')));
      await live(tester, 100);
    }
    e = c.project.screen('a')!.elements.single;
    expect(e.tagIds, ['sp', 'temp', 'porta', 'nome'], reason: 'grava na hora, na ordem dos toques');
    await tester.tap(find.byKey(const ValueKey('marcar-temp')));
    await live(tester, 100);
    expect(c.project.screen('a')!.elements.single.tagIds, ['sp', 'porta', 'nome'], reason: 'tocar de novo desmarca');
    expect(find.text('Pronto · 3 variáveis'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pronto-variaveis')));
    await live(tester, 600);

    // Reordenar: a "Receita" sobe para o topo pela alça.
    final handle = find.byKey(const ValueKey('arrastar-nome'));
    await tester.ensureVisible(handle);
    await live(tester, 200);
    final from = tester.getCenter(handle);
    final to = tester.getCenter(find.byKey(const ValueKey('arrastar-sp')));
    final g = await tester.startGesture(from);
    await live(tester, 100);
    for (var i = 1; i <= 10; i++) {
      await g.moveTo(Offset.lerp(from, to - const Offset(0, 30), i / 10)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await live(tester, 600);
    expect(c.project.screen('a')!.elements.single.tagIds, ['nome', 'sp', 'porta']);

    // Tirar uma linha.
    await tester.ensureVisible(find.byKey(const ValueKey('tirar-sp')));
    await live(tester, 200);
    await tester.tap(find.byKey(const ValueKey('tirar-sp')));
    await live(tester, 300);
    expect(c.project.screen('a')!.elements.single.tagIds, ['nome', 'porta']);

    // Com liga/desliga na tabela, aparecem os textos da linha; o rótulo vira título.
    final sheet = find.descendant(of: find.byType(DraggableScrollableSheet), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('Texto ligado'), 200, scrollable: sheet);
    await live(tester, 200);
    expect(find.text('Texto ligado'), findsOneWidget);
    expect(find.text('Título (opcional)'), findsOneWidget);

    Navigator.of(tester.element(find.byKey(const ValueKey('escolher-variaveis')))).pop();
    await live(tester, 800);
    // A tabela na grade do editor já mostra as linhas ao vivo.
    expect(find.descendant(of: find.byType(HmiCanvas), matching: find.text('LOTE 7')), findsOneWidget);
    await shutdown(tester, c);
  });

  testWidgets('GR-8: grade fina num celular de 390×844 dp mostra 40+ variáveis sem rolar', (tester) async {
    seed();
    // Duas tabelas lado a lado, 6 colunas finas cada, 22 linhas finas de
    // altura (~658 dp), com 23 variáveis em cada.
    final esquerda = [for (var i = 0; i < 23; i++) 'v$i'];
    final direita = [for (var i = 23; i < 46; i++) 'v$i'];
    final c = await boot(
      tester,
      Project(name: 'T', devices: const [clp], tags: tags, screens: [
        tela('d', [
          tabela('t1', esquerda, x: 0, y: 0, w: 6, h: 22),
          tabela('t2', direita, x: 6, y: 0, w: 6, h: 22),
        ], columns: 12),
      ]),
      size: const Size(1170, 2532),
      dpr: 3,
    );

    /// Variáveis com valor, inteiras dentro da área visível (abaixo do topo
    /// do app e acima da barra de navegação), sem rolar nada.
    int visible() {
      final canvas = tester.getRect(find.byType(HmiCanvas));
      final bottom = 844 - tester.view.padding.bottom / tester.view.devicePixelRatio;
      var n = 0;
      for (final el in find.byType(TableValueRow).evaluate()) {
        final box = el.renderObject! as RenderBox;
        final r = box.localToGlobal(Offset.zero) & box.size;
        final id = (el.widget as TableValueRow).tag.id;
        if (r.top >= canvas.top && r.bottom <= bottom && r.left >= 0 && r.right <= 390 && c.runtime.store.read(id).isGood) n++;
      }
      return n;
    }

    // Barras de status e de navegação típicas de Android (32 e 24 dp)...
    tester.view.padding = const FakeViewPadding(top: 32 * 3, bottom: 24 * 3);
    await open(tester, const ScreenRunPage(screenId: 'd'));
    final android = visible();
    expect(android, greaterThanOrEqualTo(40));
    expect(android, 46, reason: 'as duas tabelas inteiras');
    // ...e o pior caso de recorte de câmera (47 e 34 dp).
    tester.view.padding = const FakeViewPadding(top: 47 * 3, bottom: 34 * 3);
    await live(tester, 600);
    expect(visible(), greaterThanOrEqualTo(40));
    // Nenhuma tabela precisou rolar: as 23 linhas de cada cabem (~28 dp).
    expect(find.byType(RawScrollbar), findsNothing);
    final rows = find.byType(TableValueRow).evaluate().map((e) => e.size!.height);
    expect(rows.every((h) => h >= TableElement.minRow && h <= TableElement.maxRow), isTrue);
    await shutdown(tester, c);
  });
}

/// Runtime que anota cada inscrição — para conferir que a tabela que rola só
/// pede as variáveis à vista.
class _CountingRuntime extends HmiRuntime {
  _CountingRuntime(SimulatedModbusClient client) : super(clientFactory: (_) => client);
  final List<Set<String>> calls = [];

  @override
  TagSubscription subscribe(Iterable<String> tagIds) {
    final ids = tagIds.toSet();
    if (ids.isNotEmpty) calls.add(ids);
    return super.subscribe(ids);
  }
}

/// Avança o relógio simulado em passos de 100 ms (varredura e timers andam).
Future<void> live(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
