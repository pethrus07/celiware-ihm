import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/screens/tags/bulk_tags_page.dart';
import 'package:ihm/screens/tags/tags_page.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/runtime/tag_store.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Criar várias" (IF-1, IF-5), escolha de marca no equipamento e a lista de
/// variáveis com 2.000 itens (IF-3), pela interface de verdade e no relógio
/// simulado — como em `app_flow_test.dart`.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      for (final (id, _, _) in Tours.catalog) 'tour:v1:$id': true,
    });
    dir = await Directory.systemTemp.createTemp('ihm_lote');
  });

  tearDown(() async {
    DemoRegistry.discard(DemoProject.deviceId);
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {/* Windows ainda segurando o arquivo */}
  });

  Future<ProjectController> boot(WidgetTester tester, {HmiRuntime? runtime, Project? project}) async {
    final rt = runtime ?? HmiRuntime();
    final repo = ProjectRepository(directory: dir);
    if (project != null) await tester.runAsync(() => repo.save(project));
    final controller = ProjectController(repository: repo, runtime: rt);
    await tester.runAsync(controller.load);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
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

  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
    await live(tester, 600);
  }

  // A contagem também está no botão Criar, que fica sempre à vista no rodapé.
  Finder button(String label) => find.descendant(of: find.byKey(const ValueKey('criar-lote')), matching: find.text(label));
  bool enabled(WidgetTester tester) => tester.widget<ButtonStyleButton>(find.byKey(const ValueKey('criar-lote'))).onPressed != null;

  /// Rola a tela até [key] (a prévia fica no pé, fora da tela no celular).
  Future<void> reveal(WidgetTester tester, Key key) async {
    final scrollables = find.descendant(of: find.byType(BulkTagsPage), matching: find.byType(Scrollable));
    final finder = find.byKey(key);
    if (scrollables.evaluate().isNotEmpty) {
      await tester.scrollUntilVisible(finder, 300, scrollable: scrollables.first);
    } else {
      await tester.ensureVisible(finder);
    }
    await live(tester, 100);
  }

  Future<void> tapVisible(WidgetTester tester, Key key) async {
    await reveal(tester, key);
    await tester.tap(find.byKey(key));
    await live(tester, 200);
  }

  testWidgets('Criar várias: faixa de D em 32 bits, prévia, criar; de novo, substituir', (tester) async {
    final c = await boot(tester);
    c.saveDevice(c.project.device(DemoProject.deviceId)!.withProfile('inovance-h3u'));
    final before = c.project.tags.length;
    await openTab(tester, 'Variáveis');
    await tester.tap(find.byKey(const ValueKey('criar-varias')));
    await live(tester, 600);

    expect(find.text('Criar várias'), findsOneWidget);
    expect(find.textContaining('Inovance H3U · Fontes de terceiros · não validado em bancada'), findsOneWidget);
    // D já vem marcado com D0 a D9 — que a demonstração já usa em parte: o
    // botão conta só as novas (pular é o padrão).
    expect(tester.widget<TextField>(find.byKey(const ValueKey('faixa-de'))).controller!.text, '0');
    expect(tester.widget<TextField>(find.byKey(const ValueKey('faixa-ate'))).controller!.text, '9');
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('area-D'))).selected, isTrue);
    await tester.enterText(find.byKey(const ValueKey('faixa-de')), '100');
    await tester.enterText(find.byKey(const ValueKey('faixa-ate')), '119');
    await live(tester, 100);
    await tapVisible(tester, const ValueKey('tipo-int32'));
    expect(button('Criar 10 variáveis'), findsOneWidget); // 32 bits anda de 2 em 2
    expect(find.textContaining('D100, D102, D104'), findsOneWidget);
    await reveal(tester, const ValueKey('previa-leituras'));
    expect(tester.widget<Text>(find.byKey(const ValueKey('previa-contagem'))).data, '10');
    expect(find.text('Todas na tela: 1 leitura por ciclo'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('criar-lote')));
    await live(tester, 600);
    expect(find.text('10 variáveis criadas'), findsOneWidget);
    final created = c.project.tags.where((t) => t.memory != null).toList();
    expect(created.map((t) => t.memory), [for (var n = 100; n < 120; n += 2) 'D$n']);
    expect(created.map((t) => t.address), [for (var n = 100; n < 120; n += 2) n]);
    expect(created.every((t) => t.dataType == TagDataType.int32 && t.byteOrder == ByteOrder.cdab), isTrue);
    expect(c.project.tags.length, before + 10);

    // Na lista, a memória do manual vem antes do endereço Modbus.
    await tester.scrollUntilVisible(find.text('D100 · HR 100..101'), 300, scrollable: find.descendant(of: find.byType(TagsPage), matching: find.byType(Scrollable)).first);
    expect(find.text('D100 · HR 100..101'), findsOneWidget);

    // A mesma faixa de novo: todas já existem; substituir mantém os ids.
    final ids = created.map((t) => t.id).toList();
    await tester.tap(find.byKey(const ValueKey('criar-varias')));
    await live(tester, 600);
    await tester.enterText(find.byKey(const ValueKey('faixa-de')), '100');
    await tester.enterText(find.byKey(const ValueKey('faixa-ate')), '119');
    await live(tester, 100);
    await tapVisible(tester, const ValueKey('tipo-int32'));
    await tester.enterText(find.byKey(const ValueKey('nome-prefixo')), 'Contador');
    await live(tester, 100);
    await reveal(tester, const ValueKey('previa-conflitos'));
    expect(find.text('10 já existem neste equipamento'), findsOneWidget);
    expect(button('Nada novo para criar'), findsOneWidget);
    expect(enabled(tester), isFalse, reason: 'pular tudo = nada novo');
    await tapVisible(tester, const ValueKey('conflito-substituir'));
    expect(button('Criar 0 · substituir 10'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('criar-lote')));
    await live(tester, 600);
    expect(find.text('10 substituídas'), findsOneWidget);
    expect(c.project.tags.length, before + 10);
    final replaced = c.project.tags.where((t) => t.memory != null).toList();
    expect(replaced.map((t) => t.id), ids);
    expect(replaced.first.name, 'Contador 100');
    await shutdown(tester, c);
  });

  testWidgets('Criar várias: X conta em octal — X8 é recusado e nada é criado', (tester) async {
    final c = await boot(tester);
    c.saveDevice(c.project.device(DemoProject.deviceId)!.withProfile('inovance-h3u'));
    await openTab(tester, 'Variáveis');
    await tester.tap(find.byKey(const ValueKey('criar-varias')));
    await live(tester, 600);
    await tester.tap(find.byKey(const ValueKey('area-X')));
    await live(tester, 200);
    expect(find.textContaining('conta em octal'), findsOneWidget); // dica da área
    await tester.enterText(find.byKey(const ValueKey('faixa-ate')), '8');
    await live(tester, 200);
    expect(find.text('X8 não existe — X conta em octal: X7, X10'), findsOneWidget);
    expect(enabled(tester), isFalse);
    await tester.enterText(find.byKey(const ValueKey('faixa-ate')), '17');
    await live(tester, 200);
    expect(find.byKey(const ValueKey('erro-lote')), findsNothing);
    expect(button('Criar 16 variáveis'), findsOneWidget);
    await shutdown(tester, c);
  });

  testWidgets('Criar várias: só equipamento com memória Modbus (S7 e MQTT têm endereço próprio)', (tester) async {
    final c = await boot(tester);
    c.saveDevice(const Device(id: 's7', name: 'CLP S7', kind: DeviceKind.s7, host: '10.0.0.9', port: 102));
    c.saveDevice(const Device(id: 'mq', name: 'Broker', kind: DeviceKind.mqtt, host: '10.0.0.8', port: 1883));
    await live(tester, 300);
    await openTab(tester, 'Variáveis');
    await tester.tap(find.byKey(const ValueKey('criar-varias')));
    await live(tester, 600);
    final page = find.byType(BulkTagsPage);
    // Sobra só a demonstração: um equipamento, nem pergunta qual.
    expect(find.descendant(of: page, matching: find.text('CLP S7')), findsNothing);
    expect(find.descendant(of: page, matching: find.text('Broker')), findsNothing);
    expect(find.descendant(of: page, matching: find.byKey(const ValueKey('lote-perfil'))), findsOneWidget);
    await tester.pageBack();
    await live(tester, 600);

    // Sem nenhum equipamento Modbus, o botão nem acende.
    c.deleteDevice(DemoProject.deviceId);
    await live(tester, 600);
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('criar-varias'))).onPressed, isNull);
    await shutdown(tester, c);
  });

  testWidgets('Criar várias: importar CSV com uma linha ruim', (tester) async {
    final c = await boot(tester);
    c.saveDevice(c.project.device(DemoProject.deviceId)!.withProfile('inovance-h3u'));
    await live(tester, 200);
    final csv = 'memoria;nome;tipo;gravavel;unidade;escala\nD300;Pressão;int16;sim;bar;0,1\nX8;Errada;;;;\n';
    tester.state<NavigatorState>(find.byType(Navigator).first).push(MaterialPageRoute<String>(
      builder: (_) => BulkTagsPage(pickCsv: () async => (name: 'variaveis.csv', bytes: Uint8List.fromList(utf8.encode(csv)))),
    ));
    await live(tester, 600);
    await tester.tap(find.byKey(const ValueKey('modo-csv')));
    await live(tester, 300);
    await tapVisible(tester, const ValueKey('escolher-csv'));
    await live(tester, 300);
    expect(find.text('variaveis.csv'), findsOneWidget);
    expect(button('Criar 1 variável'), findsOneWidget);
    await reveal(tester, const ValueKey('csv-erros'));
    expect(find.text('1 linha ficou de fora:'), findsOneWidget);
    expect(find.textContaining('Linha 3: "X8"'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('criar-lote')));
    await live(tester, 600);
    final t = c.project.tags.singleWhere((t) => t.memory == 'D300');
    expect((t.name, t.dataType, t.writable, t.unit, t.scale), ('Pressão', TagDataType.int16, true, 'bar', 0.1));
    await shutdown(tester, c);
  });

  testWidgets('equipamento: marca e modelo em Mais opções; trocar a marca recalcula os endereços', (tester) async {
    final c = await boot(tester);
    c.saveDevice(const Device(id: 'clp', name: 'CLP da prensa', host: '192.168.0.10'));
    c.saveTags(const [Tag(id: 'm', name: 'Temperatura', deviceId: 'clp', address: 200, memory: 'D200')]);
    await openTab(tester, 'Equipamentos');
    await tester.tap(find.byKey(const ValueKey('equip-clp')));
    await live(tester, 600);
    await tester.tap(find.text('Mais opções'));
    await live(tester, 900);
    await tapVisible(tester, const ValueKey('marca-modelo'));
    await live(tester, 500);
    // Terceiros avisa que não foi validado; manual oficial diz a origem.
    expect(find.descendant(of: find.byKey(const ValueKey('perfil-inovance-h3u')), matching: find.textContaining('não validado em bancada')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('perfil-weg-tpw04')));
    await live(tester, 300);
    expect(find.descendant(of: find.byKey(const ValueKey('perfil-weg-tpw04')), matching: find.text('Pelo manual oficial')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('perfil-weg-tpw04')));
    await live(tester, 500);
    expect(find.text('WEG TPW04'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('salvar-equipamento')));
    await live(tester, 500);
    // A variável tinha a memória do manual: D200 no TPW04 fica em 0x4338 + 200.
    expect(find.text('Recalcular endereços?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('recalcular-enderecos')));
    await live(tester, 600);
    expect(c.project.device('clp')!.profile, 'weg-tpw04');
    expect(c.project.tag('m')!.address, 0x4338 + 200);
    await shutdown(tester, c);
  });

  testWidgets('lista com 2.000 variáveis: monta e lê só as visíveis, e rola até a última', (tester) async {
    final runtime = _CountingRuntime();
    final demo = DemoProject.build().equipment.single;
    final c = await boot(tester, runtime: runtime, project: Project(name: 'Grande', devices: [demo]));
    // 1000 registradores + 1000 bits: a memória da demonstração tem 1000 de cada.
    c.saveTags([
      for (var i = 0; i < 2000; i++)
        Tag(
          id: 'v$i',
          name: 'Variável $i',
          deviceId: demo.id,
          area: i < 1000 ? ModbusArea.holdingRegister : ModbusArea.coil,
          address: i % 1000,
          dataType: i < 1000 ? TagDataType.uint16 : TagDataType.bool,
        ),
    ]);
    await openTab(tester, 'Variáveis');
    await live(tester, 1200);

    expect(find.byKey(const ValueKey('var-v0')), findsOneWidget);
    expect(find.byKey(const ValueKey('var-v1999')), findsNothing);
    expect(find.byType(ListTile).evaluate().length, lessThan(40), reason: 'só as linhas à vista são montadas');
    final biggest = runtime.calls.fold<int>(0, (m, s) => math.max(m, s.length));
    expect(biggest, lessThan(40), reason: 'só as linhas à vista são lidas');
    expect(runtime.store.read('v0').quality, TagQuality.good);
    expect(runtime.store.read('v1999').quality, TagQuality.waiting);

    final list = find.descendant(of: find.byType(TagsPage), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.byKey(const ValueKey('var-v1999')), 4000, scrollable: list);
    await live(tester, 1200);
    expect(find.byKey(const ValueKey('var-v1999')), findsOneWidget);
    expect(find.byKey(const ValueKey('var-v0')), findsNothing);
    expect(runtime.store.read('v1999').quality, TagQuality.good);
    // A inscrição de agora tem a última e não tem mais a primeira.
    expect(runtime.calls.last, contains('v1999'));
    expect(runtime.calls.last, isNot(contains('v0')));
    expect(runtime.calls.every((s) => s.length < 40), isTrue);
    await shutdown(tester, c);
  });
}

/// Runtime que anota cada inscrição — para conferir que a lista longa só
/// pede as variáveis à vista.
class _CountingRuntime extends HmiRuntime {
  final List<Set<String>> calls = [];

  @override
  TagSubscription subscribe(Iterable<String> tagIds) {
    final ids = tagIds.toSet();
    calls.add(ids);
    return super.subscribe(ids);
  }
}

Future<void> live(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
