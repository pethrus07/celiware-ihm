import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart' show ByteData, FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/calc.dart';
import 'package:ihm/models/logic_rule.dart';
import 'package:ihm/models/plant.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/screens/alarms_page.dart';
import 'package:ihm/screens/devices/device_form_page.dart';
import 'package:ihm/screens/projects/backups_page.dart';
import 'package:ihm/screens/projects/projects_page.dart';
import 'package:ihm/screens/screens_page.dart';
import 'package:ihm/screens/shell.dart';
import 'package:ihm/screens/tools_page.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/cameras/camera_vault.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:ihm/services/templates/ready_projects.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A estrutura nova (reunião de 19–20/10/2026): barra com Projetos ·
/// Equipamentos · Variáveis · Ferramentas · Alarmes, e a aba Projetos com a
/// lista de projetos e, dentro de cada um, as telas.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  late Directory dir;

  // A letra de verdade (IBM Plex): a de teste é quadrada e mais larga, e o
  // teste dos rótulos da barra mede a largura real.
  setUpAll(() async {
    sqfliteFfiInit();
    for (final (family, files) in [
      ('Plex', ['IBMPlexSans-400', 'IBMPlexSans-500', 'IBMPlexSans-600', 'IBMPlexSans-700']),
      ('PlexCondensed', ['IBMPlexSansCondensed-SemiBold', 'IBMPlexSansCondensed-Bold']),
    ]) {
      final loader = FontLoader(family);
      for (final f in files) {
        loader.addFont(Future.value(ByteData.sublistView(File('assets/fonts/$f.ttf').readAsBytesSync())));
      }
      await loader.load();
    }
  });

  setUp(() async {
    // Registro de dados num SQLite de verdade (a troca de projeto fecha e
    // abre os bancos).
    databaseFactoryOrNull = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({
      for (final (id, _, _) in Tours.catalog) for (final v in [1, 2]) 'tour:v$v:$id': true,
    });
    CameraVault.instance = MemoryCameraVault();
    dir = await Directory.systemTemp.createTemp('ihm_projetos_tela');
  });

  tearDown(() async {
    databaseFactoryOrNull = null;
    DemoRegistry.discard(DemoProject.deviceId);
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {/* Windows ainda segurando o arquivo — é só a pasta temporária */}
  });

  /// Deixa o disco de verdade responder (abrir, criar e apagar projeto leem e
  /// gravam arquivo) e redesenha; com [until], até a condição valer.
  Future<void> settle(WidgetTester tester, {int rounds = 8, bool Function()? until}) async {
    for (var i = 0; i < (until == null ? rounds : 60); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 100));
      if (until != null && until()) {
        // O disco respondeu; mais duas voltas para o resto da tarefa (avisar
        // a tela) terminar.
        for (var j = 0; j < 2; j++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
          await tester.pump(const Duration(milliseconds: 100));
        }
        break;
      }
    }
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<ProjectController> boot(WidgetTester tester, {Size size = const Size(390, 844), double textScale = 1, bool library = true}) async {
    final runtime = HmiRuntime();
    final controller = library
        ? ProjectController(library: PlantStore(root: dir), runtime: runtime)
        : ProjectController(repository: ProjectRepository(directory: dir), runtime: runtime);
    await tester.runAsync(controller.load);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(CeliwareIhmApp(controller: controller, runtime: runtime));
    await settle(tester, rounds: 4);
    return controller;
  }

  Future<void> shutdown(WidgetTester tester, ProjectController c) async {
    await tester.runAsync(c.flush);
    await tester.pumpWidget(const SizedBox());
    final done = c.runtime.dispose();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await done;
    c.dispose();
  }

  group('barra com cinco áreas', () {
    const labels = ['Projetos', 'Equipamentos', 'Variáveis', 'Ferramentas', 'Alarmes'];

    testWidgets('celular: Projetos · Equipamentos · Variáveis · Ferramentas · Alarmes, sem "Mais"', (tester) async {
      final c = await boot(tester);
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect([for (final d in bar.destinations) (d as NavigationDestination).label], labels);
      expect(find.text('Mais'), findsNothing);
      // Cada área abre a sua página.
      for (final (label, page) in [('Ferramentas', ToolsPage), ('Alarmes', AlarmsPage), ('Projetos', ScreensPage)]) {
        await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
        await settle(tester, rounds: 3);
        expect(find.byType(page), findsOneWidget, reason: label);
      }
      // Registros é o primeiro item de Ferramentas.
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Ferramentas')));
      await settle(tester, rounds: 2);
      final logs = tester.getRect(find.byKey(const ValueKey('registros')));
      for (final k in ['cameras', 'receitas', 'regras', 'voz-e-avisos', 'procurar-na-rede']) {
        expect(tester.getRect(find.byKey(ValueKey(k))).top, greaterThan(logs.top), reason: k);
      }
      await shutdown(tester, c);
    });

    testWidgets('tablet: o trilho tem as mesmas cinco áreas', (tester) async {
      final c = await boot(tester, size: const Size(1280, 800));
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect([for (final d in rail.destinations) (d.label as Text).data], labels);
      await shutdown(tester, c);
    });

    for (final width in [320.0, 360.0]) {
      testWidgets('${width.toInt()} dp com letra a 130%: cada rótulo inteiro numa linha, dentro da aba', (tester) async {
        final c = await boot(tester, size: Size(width, 700), textScale: 1.3);
        final slot = width / labels.length;
        for (final label in labels) {
          final text = find.descendant(of: find.byType(NavigationBar), matching: find.text(label));
          final paragraph = tester.renderObject<RenderParagraph>(text.first);
          expect(paragraph.didExceedMaxLines, isFalse, reason: label);
          final r = tester.getRect(text.first);
          expect(r.width, lessThanOrEqualTo(slot), reason: '$label cabe nos ${slot.toStringAsFixed(0)} dp da aba');
          expect(r.width, greaterThanOrEqualTo(paragraph.getMaxIntrinsicWidth(double.infinity) - 0.5), reason: '$label numa linha só');
        }
        await shutdown(tester, c);
      });
    }
  });

  group('aba Projetos', () {
    testWidgets('abre dentro do último projeto; a seta mostra a lista com o resumo de cada um', (tester) async {
      final c = await boot(tester);
      expect(find.byType(ScreensPage), findsOneWidget);
      expect(find.widgetWithText(AppBar, c.project.name), findsOneWidget, reason: 'o título é o nome do projeto');
      await tester.tap(find.byKey(tester.state<ShellState>(find.byType(Shell)).projectsKey));
      await settle(tester, rounds: 2);
      expect(find.byType(ProjectsPage), findsOneWidget);
      final id = c.openId!;
      expect(find.byKey(ValueKey('resumo-$id')), findsOneWidget);
      final e = c.projects.single;
      expect(tester.widget<Text>(find.byKey(ValueKey('resumo-$id'))).data, '${e.equipment} equipamento${e.equipment == 1 ? '' : 's'} · ${e.tags} variáveis · ${e.screens} telas');

      // "Voltar" do Android dentro do projeto volta para a lista.
      await tester.tap(find.byKey(ValueKey('projeto-$id')));
      await settle(tester, until: () => find.byType(ScreensPage).evaluate().isNotEmpty);
      expect(find.byType(ScreensPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await settle(tester, rounds: 2);
      expect(find.byType(ProjectsPage), findsOneWidget);
      await shutdown(tester, c);
    });

    testWidgets('Novo projeto em branco ACRESCENTA: o anterior continua na lista e no disco', (tester) async {
      final c = await boot(tester);
      final first = c.openId!;
      final firstName = c.project.name;
      tester.state<ShellState>(find.byType(Shell)).showProjectList();
      await settle(tester, rounds: 2);

      await tester.tap(find.text('Novo projeto'));
      await settle(tester, rounds: 3);
      await tester.tap(find.byKey(const ValueKey('opcao-branco')));
      await settle(tester, rounds: 3);
      await tester.enterText(find.byKey(const ValueKey('campo-nome')), 'Linha 2');
      await tester.tap(find.byKey(const ValueKey('ok-nome')));
      await settle(tester, until: () => c.project.name == 'Linha 2' && find.byType(ScreensPage).evaluate().isNotEmpty);

      expect(c.project.name, 'Linha 2');
      expect(c.project.isEmpty, isTrue);
      expect(find.byType(ScreensPage), findsOneWidget, reason: 'já abre dentro do projeto novo');
      expect(c.projects.map((e) => e.name), containsAll([firstName, 'Linha 2']));
      final kept = await tester.runAsync(() => c.library!.repositoryFor(first).load());
      expect(kept?.screens, isNotEmpty, reason: 'o projeto anterior não foi substituído');
      await shutdown(tester, c);
    });

    testWidgets('De um projeto pronto SOMA à planta: nome único, abre, e o anterior continua', (tester) async {
      final c = await boot(tester, size: const Size(360, 740));
      final first = c.openId!;
      final firstName = c.project.name;
      // Um "Tex G4" já na planta: o pronto ganha nome único, como a importação.
      await tester.runAsync(() => c.createProject(const Project(name: 'Tex G4')));
      tester.state<ShellState>(find.byType(Shell)).showProjectList();
      await settle(tester, rounds: 3);

      await tester.tap(find.text('Novo projeto'));
      await settle(tester, rounds: 3);
      await tester.tap(find.byKey(const ValueKey('opcao-pronto')));
      await settle(tester, rounds: 3);
      // A lista: nome e uma linha de cada, nada cortado no celular de 360 dp.
      for (final rp in ReadyProjects.all) {
        expect(find.byKey(ValueKey('opcao-${rp.id}')), findsOneWidget, reason: rp.title);
        expect(find.text(rp.title), findsOneWidget);
      }
      for (final t in find.byType(RichText).evaluate()) {
        final p = t.renderObject! as RenderParagraph;
        expect(p.didExceedMaxLines, isFalse, reason: '"${p.text.toPlainText()}" cortado');
      }
      await tester.scrollUntilVisible(find.byKey(const ValueKey('opcao-tex-g4')), 200, scrollable: find.byType(Scrollable).last);
      await tester.tap(find.byKey(const ValueKey('opcao-tex-g4')));
      await settle(tester, until: () => c.project.name.startsWith('Tex G4 ') && find.byType(ScreensPage).evaluate().isNotEmpty);

      expect(c.project.name, isNot('Tex G4'), reason: 'nome único');
      expect(c.project.name, startsWith('Tex G4'));
      expect(c.project.screens.map((s) => s.name), ['Operação', 'Entradas e saídas']);
      expect(c.project.tags.every((t) => t.addressPending), isTrue);
      expect(find.byType(ScreensPage), findsOneWidget, reason: 'já abre dentro do projeto novo');
      expect(find.textContaining('manual Modbus do Tex G4'), findsOneWidget, reason: 'o aviso diz o próximo passo');
      expect(c.projects.map((e) => e.name), containsAll([firstName, 'Tex G4', c.project.name]));
      expect(c.projects.length, 3, reason: 'somou; nada foi substituído');
      final kept = await tester.runAsync(() => c.library!.repositoryFor(first).load());
      expect(kept?.screens, isNotEmpty, reason: 'o projeto anterior continua no disco');
      await shutdown(tester, c);
    });

    testWidgets('apagar pergunta antes; o último projeto não tem "Apagar"', (tester) async {
      final c = await boot(tester);
      await tester.runAsync(() => c.createProject(const Project(name: 'Prensa')));
      final prensa = c.openId!;
      tester.state<ShellState>(find.byType(Shell)).showProjectList();
      await settle(tester, rounds: 3);

      await tester.tap(find.byKey(ValueKey('menu-projeto-$prensa')));
      await settle(tester, rounds: 2);
      await tester.tap(find.text('Apagar'));
      await settle(tester, rounds: 2);
      expect(find.text('Apagar "Prensa"?'), findsOneWidget);
      // Cancelar não apaga nada.
      await tester.tap(find.text('Cancelar'));
      await settle(tester, rounds: 2);
      expect(c.projects, hasLength(2));

      await tester.tap(find.byKey(ValueKey('menu-projeto-$prensa')));
      await settle(tester, rounds: 2);
      await tester.tap(find.text('Apagar'));
      await settle(tester, rounds: 2);
      await tester.tap(find.widgetWithText(FilledButton, 'Apagar'));
      final folder = Directory('${dir.path}${Platform.pathSeparator}projetos${Platform.pathSeparator}$prensa');
      await settle(tester, until: () => c.projects.length == 1 && !folder.existsSync());
      expect(c.projects, hasLength(1));
      expect(c.openId, isNot(prensa), reason: 'apagar o aberto abre outro');
      expect(folder.existsSync(), isFalse);

      final last = c.projects.single.id;
      await tester.tap(find.byKey(ValueKey('menu-projeto-$last')));
      await settle(tester, rounds: 2);
      expect(find.text('Apagar'), findsNothing, reason: 'o app precisa de um projeto aberto');
      await tester.tapAt(const Offset(10, 10));
      await settle(tester, rounds: 2);
      await shutdown(tester, c);
    });

    // Revisão de 21/10/2026: apagar deixava as regras da planta que citavam
    // o projeto virando "Regra X parada" em todos os projetos.
    testWidgets('apagar avisa quantas regras da planta usam o projeto; confirmar desliga essas regras', (tester) async {
      final c = await boot(tester);
      final first = c.openId!;
      // Calculada: sem rede no teste, e o motor das regras lê de verdade.
      const k = Tag(id: 'k', name: 'Temperatura', deviceId: CalcDevice.id, dataType: TagDataType.float32, calc: CalcSpec(expression: '2 * 40'));
      await tester.runAsync(() => c.createProject(const Project(name: 'Forno', devices: [CalcDevice.device], tags: [k])));
      final forno = c.openId!;
      final ref = '{${PlantRef.of(forno, 'k')}}';
      await tester.runAsync(() async {
        await c.open(first);
        await c.savePlantRule(LogicRule(id: 'g1', name: 'Forno quente', condition: CalcSpec(expression: '$ref > 80')));
        await c.savePlantRule(LogicRule(id: 'g2', name: 'Forno frio', condition: CalcSpec(expression: '$ref < 20')));
      });
      tester.state<ShellState>(find.byType(Shell)).showProjectList();
      await settle(tester, rounds: 3);

      await tester.tap(find.byKey(ValueKey('menu-projeto-$forno')));
      await settle(tester, rounds: 2);
      await tester.tap(find.text('Apagar'));
      await settle(tester, rounds: 2);
      expect(find.textContaining('2 regras da planta usam este projeto e serão desligadas.'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Apagar'));
      await settle(tester, until: () => c.projects.length == 1 && c.plantRules.every((r) => !r.enabled));
      expect(c.projects.map((e) => e.id), [first]);
      expect(c.plantRules.map((r) => (r.id, r.enabled)), [('g1', false), ('g2', false)], reason: 'desligadas, não apagadas');
      await shutdown(tester, c);
    });

    testWidgets('o título da lista é a planta; "Nova planta" pergunta antes e guarda a cópia da atual', (tester) async {
      final c = await boot(tester);
      final before = c.projects.single.name;
      tester.state<ShellState>(find.byType(Shell)).showProjectList();
      await settle(tester, rounds: 3);
      expect(find.widgetWithText(AppBar, c.plantName), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('menu-planta')));
      await settle(tester, rounds: 2);
      await tester.tap(find.text('Nova planta'));
      await settle(tester, rounds: 2);
      expect(find.text('Começar uma planta nova?'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await settle(tester, rounds: 2);
      expect(c.projects.single.name, before, reason: 'cancelar não mexe em nada');

      await tester.tap(find.byKey(const ValueKey('menu-planta')));
      await settle(tester, rounds: 2);
      await tester.tap(find.text('Nova planta'));
      await settle(tester, rounds: 2);
      await tester.tap(find.byKey(const ValueKey('confirmar-substituir-planta')));
      final copies = Directory('${dir.path}${Platform.pathSeparator}copias');
      await settle(tester, until: () => c.projects.length == 1 && c.projects.first.name == 'Meu projeto' && find.byType(ScreensPage).evaluate().isNotEmpty);
      expect(c.project.isEmpty, isTrue);
      expect(copies.listSync(), hasLength(1), reason: 'a planta de antes ficou guardada');
      final saved = ProjectRepository.decodePlant(File(copies.listSync().single.path).readAsBytesSync());
      expect(saved.projects.single.project.name, before);
      await shutdown(tester, c);
    });

    testWidgets('Cópias de segurança: o aviso aponta para elas, a cópia aparece com a data e Abrir soma à planta', (tester) async {
      final c = await boot(tester);
      final before = c.projects.single.name;
      tester.state<ShellState>(find.byType(Shell)).showProjectList();
      await settle(tester, rounds: 3);

      // Sem cópia ainda: a página diz o que vai aparecer ali.
      await tester.tap(find.byKey(const ValueKey('menu-planta')));
      await settle(tester, rounds: 2);
      await tester.tap(find.text('Cópias de segurança'));
      await settle(tester, rounds: 3);
      expect(find.byType(BackupsPage), findsOneWidget);
      expect(find.text('Nenhuma cópia ainda'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await settle(tester, rounds: 3);

      // O aviso de "Nova planta": singular com um projeto, e o caminho de volta.
      await tester.tap(find.byKey(const ValueKey('menu-planta')));
      await settle(tester, rounds: 2);
      await tester.tap(find.text('Nova planta'));
      await settle(tester, rounds: 2);
      expect(find.textContaining('O projeto desta planta sai do app'), findsOneWidget);
      expect(find.textContaining('Os 1 projetos'), findsNothing);
      expect(find.textContaining('menu da planta (⋮) → Cópias de segurança'), findsOneWidget);
      expect(find.textContaining('De um arquivo'), findsNothing, reason: 'o seletor de arquivos não enxerga a pasta das cópias');
      await tester.tap(find.byKey(const ValueKey('confirmar-substituir-planta')));
      await settle(tester, until: () => c.projects.length == 1 && c.projects.first.name == 'Meu projeto' && find.byType(ScreensPage).evaluate().isNotEmpty);

      tester.state<ShellState>(find.byType(Shell)).showProjectList();
      await settle(tester, rounds: 3);
      await tester.tap(find.byKey(const ValueKey('menu-planta')));
      await settle(tester, rounds: 2);
      await tester.tap(find.text('Cópias de segurança'));
      await settle(tester, rounds: 3);
      final copy = c.backups().single;
      expect(find.text(BackupsPage.when(copy.when)), findsOneWidget);
      expect(find.text('Enviar'), findsOneWidget);

      await tester.tap(find.byKey(ValueKey('abrir-copia-${copy.file.uri.pathSegments.last}')));
      await settle(tester, until: () => c.projects.length == 2 && find.byType(BackupsPage).evaluate().isEmpty);
      expect(c.projects.map((e) => e.name), containsAll([before, 'Meu projeto']), reason: 'somou: nada foi substituído');
      expect(find.byType(ProjectsPage), findsOneWidget, reason: 'volta para a lista, com o projeto de volta');
      expect(find.text('1 projeto somado à planta.'), findsOneWidget);
      await shutdown(tester, c);
    });

    testWidgets('tablet: trocar de projeto fecha o cadastro aberto ao lado (o Salvar não grava no projeto novo)', (tester) async {
      final c = await boot(tester, size: const Size(1280, 800));
      final first = c.openId!;
      final device = c.project.equipment.first;
      await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('Equipamentos')));
      await settle(tester, rounds: 3);
      await tester.tap(find.text(device.name).first);
      await settle(tester, rounds: 3);
      expect(find.byType(DeviceFormPage), findsOneWidget, reason: 'cadastro aberto no painel ao lado');

      // Troca de projeto pelo trilho: Projetos → lista → outro projeto.
      await tester.runAsync(() => c.createProject(const Project(name: 'Prensa')));
      await settle(tester, until: () => c.project.name == 'Prensa');
      await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('Equipamentos')));
      await settle(tester, rounds: 3);
      expect(c.openId, isNot(first));
      expect(find.byType(DeviceFormPage), findsNothing, reason: 'o cadastro era do outro projeto');
      expect(find.text('Escolha um equipamento'), findsOneWidget);
      expect(c.project.devices, isEmpty, reason: 'nada do projeto anterior entrou no novo');
      await shutdown(tester, c);
    });

    testWidgets('Regras: "Deste projeto" e "Da planta", cada uma com o seu botão', (tester) async {
      final c = await boot(tester);
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Ferramentas')));
      await settle(tester, rounds: 2);
      await tester.tap(find.byKey(const ValueKey('regras')));
      await settle(tester, rounds: 4);
      expect(find.text('DESTE PROJETO'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const ValueKey('nova-regra-planta')), 200, scrollable: find.byType(Scrollable).last);
      expect(find.text('DA PLANTA'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nova-regra-planta')));
      await settle(tester, until: () => find.text('Nova regra da planta').evaluate().isNotEmpty);
      expect(find.text('Nova regra da planta'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await settle(tester, rounds: 3);
      await shutdown(tester, c);
    });

    testWidgets('sem biblioteca (um projeto só): sem seta e sem lista', (tester) async {
      final c = await boot(tester, library: false);
      expect(find.byType(ScreensPage), findsOneWidget);
      expect(find.byKey(tester.state<ShellState>(find.byType(Shell)).projectsKey), findsNothing);
      await shutdown(tester, c);
    });
  });
}
