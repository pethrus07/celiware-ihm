import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

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
import 'package:ihm/models/device.dart';
import 'package:ihm/models/hmi_screen.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/screens/screen_run_page.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:ihm/services/templates/screen_templates.dart';
import 'package:ihm/services/templates/template_builder.dart';
import 'package:ihm/widgets/hmi/element_catalog.dart';
import 'package:ihm/widgets/hmi/hmi_canvas.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Conferência visual dos modelos de tela, desenhados com as fontes de
/// verdade (IBM Plex) do celular de 320 dp ao tablet, claro e escuro — cada
/// modelo no equipamento genérico (variáveis a configurar), o mesmo depois
/// de preenchidos os endereços (valores na tela) e o de inversor também com
/// o mapa do MD500 (palavra de comando):
///
///   • nenhum elemento sai da grade nem encosta noutro;
///   • quem grava tem pelo menos 48 dp de alvo de toque;
///   • nenhum texto cortado com "…" (rótulo, botão, aviso);
///   • nenhum texto encolhido abaixo de 10 dp (estado, aviso "a configurar",
///     nome do botão) — em cada estado: cada código do indicador de estado e
///     cada lâmpada acesa;
///   • o diálogo de "Nova tela" e a folha dos modelos cabem no celular.
///
/// Com `QA_PNG=<pasta>` no ambiente, grava também a imagem de cada tela
/// (inteira, numa janela alta) e do diálogo, para olhar a olho.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  late Directory dir;
  final png = Platform.environment['QA_PNG'];

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
    // Ícones só para a imagem (sem eles cada ícone vira um quadrado).
    final exe = Platform.resolvedExecutable.replaceAll(r'\', '/');
    final root = Platform.environment['FLUTTER_ROOT'] ?? (exe.contains('/bin/cache/') ? exe.substring(0, exe.indexOf('/bin/cache/')) : '');
    final icons = File('$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf');
    if (png != null && icons.existsSync()) {
      await (FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())))).load();
    }
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      // Todas as versões já vistas (a trilha de início está na v2).
      for (final (id, _, _) in Tours.catalog) for (final v in [1, 2]) 'tour:v$v:$id': true,
    });
    dir = await Directory.systemTemp.createTemp('ihm_modelos');
  });

  tearDown(() async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {/* Windows ainda segurando o arquivo — é só a pasta temporária */}
  });

  const generic = Device(id: 'gen', name: 'Prensa', host: '10.0.0.3');
  const md500 = Device(id: 'md', name: 'Inversor da bomba', host: '10.0.0.4', profile: 'inovance-md500');
  // O mesmo genérico depois de a pessoa preencher os endereços: a tela com
  // valor de verdade em cada elemento (número, texto, lâmpada, estado).
  const configured = Device(id: 'cfg', name: 'Prensa configurada', host: '10.0.0.6');

  /// Todas as telas de modelo num projeto só: id da tela → nome do caso.
  (Project, Map<String, String>) project() {
    var p = const Project(devices: [generic, configured, md500]);
    var coil = 0, register = 100;
    Tag fill(Tag t) => t.copyWith(address: t.area.isBit ? coil++ : (register += 40), addressPending: false);
    final cases = <String, String>{};
    for (final t in ScreenTemplates.all.where((t) => !t.isBlank)) {
      for (final d in [generic, configured, if (t.driveMap) md500]) {
        final id = 's-${t.id}-${d.id}';
        final r = TemplateBuilder.build(t, project: p, device: d, screenId: id, name: t.name);
        p = p.upsertTags(d == configured ? r.created.map(fill) : r.created).upsertScreen(r.screen);
        cases[id] = '${t.id}${switch (d.id) { 'md' => '-md500', 'cfg' => '-configurado', _ => '' }}';
      }
    }
    return (p, cases);
  }

  Future<(ProjectController, ModbusMemory)> boot(WidgetTester tester, Size dp, Appearance look, Project p) async {
    // Memória do tamanho do mapa do inversor (falha em 0x8000): o mapa lê sem
    // "endereço inexistente", e nenhum socket abre no teste.
    final memory = ModbusMemory(coils: 100, discreteInputs: 100, holdingRegisters: 65536, inputRegisters: 100);
    final runtime = HmiRuntime(clientFactory: (_) => SimulatedModbusClient(memory: memory, latency: Duration.zero));
    final controller = ProjectController(repository: ProjectRepository(directory: dir), runtime: runtime);
    await tester.runAsync(controller.load);
    await tester.runAsync(() => controller.replace(p));
    await AppearanceController.instance.set(look);
    Ind.use(AppearanceController.instance.resolve());
    tester.view.physicalSize = dp;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CeliwareIhmApp(controller: controller, runtime: runtime));
    await live(tester, 600);
    return (controller, memory);
  }

  Future<void> shutdown(WidgetTester tester, ProjectController c) async {
    await tester.pumpWidget(const SizedBox());
    final done = c.runtime.dispose();
    await live(tester, 1200);
    await done;
    c.dispose();
  }

  NavigatorState root(WidgetTester tester) => tester.state<NavigatorState>(find.byType(Navigator).first);

  Future<void> open(WidgetTester tester, String screenId) async {
    unawaited(root(tester).push(MaterialPageRoute<void>(builder: (_) => ScreenRunPage(screenId: screenId))));
    await live(tester, 900);
  }

  Future<void> close(WidgetTester tester) async {
    root(tester).pop();
    await live(tester, 600);
  }

  /// Tamanho de letra que chega à tela: o `FitText` encolhe o texto para caber.
  double shownSize(WidgetTester tester, Finder text) {
    final p = tester.renderObject<RenderParagraph>(text);
    final drawn = tester.getRect(text).height;
    final font = p.text.style?.fontSize ?? 14;
    return p.size.height == 0 ? font : font * drawn / p.size.height;
  }

  /// O que está errado na tela aberta — tudo de uma vez, para o relatório
  /// do teste mostrar a lista inteira e não só o primeiro problema.
  List<String> problems(WidgetTester tester, HmiScreen screen, String what) {
    final out = <String>[];
    final canvas = tester.getRect(find.byType(HmiCanvas));
    final rects = <String, Rect>{};
    for (final e in screen.elements) {
      final r = tester.getRect(find.byKey(ValueKey('el-${e.id}')));
      final where = '$what: ${e.type.name} "${e.props['label']}"';
      if (r.left < canvas.left - 0.5) out.add('$where sai pela esquerda');
      if (r.right > canvas.right + 0.5) out.add('$where sai pela direita');
      for (final o in rects.entries) {
        if (r.deflate(0.5).overlaps(o.value)) out.add('$where encosta em ${o.key}');
      }
      rects['${e.type.name} "${e.props['label']}"'] = r;
      if (ElementCatalog.of(e.type).writes && r.shortestSide < Ind.minTouch) out.add('$where: alvo de toque ${r.size}');
    }
    final texts = find.descendant(of: find.byType(HmiCanvas), matching: find.byType(RichText));
    for (final t in texts.evaluate()) {
      final p = t.renderObject! as RenderParagraph;
      if (p.didExceedMaxLines) out.add('$what: "${p.text.toPlainText()}" cortado');
    }
    // Texto que o `FitText` encolheu (estado, aviso, nome do botão): a letra
    // que chega à tela não desce de 10 dp.
    for (var i = 0; i < texts.evaluate().length; i++) {
      final f = texts.at(i);
      final text = (tester.renderObject(f) as RenderParagraph).text.toPlainText();
      if (text.trim().isEmpty) continue;
      final size = shownSize(tester, f);
      if (size < 10) out.add('$what: "$text" encolhido para ${size.toStringAsFixed(1)} dp');
    }
    return out;
  }

  /// Cada texto de estado que a tela pode mostrar — cada código do indicador
  /// de estado e cada lâmpada acesa: o mais longo também tem que caber.
  Future<List<String>> statesProblems(WidgetTester tester, ProjectController c, ModbusMemory memory, HmiScreen screen, String what) async {
    final out = <String>[];
    for (final e in screen.elements) {
      final tag = e.tagId == null ? null : c.project.tag(e.tagId!);
      if (tag == null || tag.addressPending) continue;
      if (e.type == ElementType.multistate) {
        for (final s in (e.props['states'] as List).cast<Map<String, Object?>>()) {
          memory.pokeRegister(tag.area, tag.address, s['value']! as int);
          await live(tester, 600);
          out.addAll(problems(tester, screen, '$what (${s['text']})'));
        }
        memory.pokeRegister(tag.area, tag.address, 0);
      } else if (e.type == ElementType.lamp) {
        memory.pokeBit(tag.area, tag.address, true);
        await live(tester, 600);
        out.addAll(problems(tester, screen, '$what (${e.props['label']} aceso)'));
        memory.pokeBit(tag.area, tag.address, false);
      }
    }
    await live(tester, 600);
    return out;
  }

  // 320 é o celular pequeno, 360 o comum, 390 o Pixel 7; o tablet em pé e deitado.
  const sizes = [Size(320, 640), Size(360, 740), Size(390, 844), Size(800, 1280), Size(1280, 800)];

  for (final size in sizes) {
    for (final look in [Appearance.claro, Appearance.escuro]) {
      testWidgets('${size.width.toInt()}×${size.height.toInt()} ${look.name}: todos os modelos inteiros, legíveis e tocáveis', (tester) async {
        final (p, cases) = project();
        final (c, memory) = await boot(tester, size, look, p);
        final found = <String>[];
        for (final MapEntry(key: id, value: name) in cases.entries) {
          await open(tester, id);
          final screen = c.project.screen(id)!;
          found.addAll(problems(tester, screen, name));
          found.addAll(await statesProblems(tester, c, memory, screen, name));
          await close(tester);
        }
        await shutdown(tester, c);
        expect(found, isEmpty, reason: found.join('\n'));
      });
    }
  }

  /// Grava a janela inteira em [name].png (só com QA_PNG).
  Future<void> snap(WidgetTester tester, Size size, String name) async {
    if (png == null) return;
    final layer = tester.binding.renderViews.first.debugLayer! as OffsetLayer;
    await tester.runAsync(() async {
      final image = await layer.toImage(Offset.zero & size);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('${(Directory(png)..createSync(recursive: true)).path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  // O diálogo de "Nova tela" e a folha dos modelos no celular: cada linha de
  // escolha com pelo menos 48 dp, nada cortado nem transbordando (um
  // transbordo vira exceção e derruba o teste sozinho).
  for (final width in [320.0, 360.0, 390.0]) {
    for (final look in [Appearance.claro, Appearance.escuro]) {
      testWidgets('${width.toInt()} dp ${look.name}: "Nova tela" com modelo cabe no celular', (tester) async {
        final size = Size(width, 740);
        final (p, _) = project();
        final (c, _) = await boot(tester, size, look, p);
        await tester.tap(find.text('Nova tela'));
        await live(tester, 400);
        await tester.tap(find.byKey(const ValueKey('escolher-modelo')));
        await live(tester, 700);
        final found = <String>[];
        void scan(String where, Finder rows) {
          for (final t in find.byType(RichText).evaluate()) {
            final p = t.renderObject! as RenderParagraph;
            if (p.didExceedMaxLines) found.add('$where: "${p.text.toPlainText()}" cortado');
          }
          for (final r in rows.evaluate()) {
            final h = (r.renderObject! as RenderBox).size.height;
            if (h < Ind.minTouch) found.add('$where: linha com ${h.toStringAsFixed(0)} dp');
          }
        }

        scan('folha', find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('modelo-')));
        await snap(tester, size, 'dialogo-folha-${width.toInt()}-${look.name}');
        // O nome mais comprido do catálogo.
        await tester.scrollUntilVisible(find.byKey(const ValueKey('modelo-leitor-codigo')), 200, scrollable: find.byType(Scrollable).last);
        await live(tester, 200);
        await tester.tap(find.byKey(const ValueKey('modelo-leitor-codigo')));
        await live(tester, 700);
        scan('diálogo', find.byWidgetPredicate((w) => w.key == const ValueKey('escolher-modelo') || w.key == const ValueKey('escolher-equipamento-modelo')));
        await snap(tester, size, 'dialogo-${width.toInt()}-${look.name}');
        await tester.tap(find.text('Cancelar'));
        await live(tester, 400);
        await shutdown(tester, c);
        expect(found, isEmpty, reason: found.join('\n'));
      });
    }
  }

  // Só existe com QA_PNG: sem a pasta, não há o que gravar (nem conta como pulado).
  if (png != null) {
    testWidgets('imagens para olhar a olho (QA_PNG)', (tester) async {
      final (p, cases) = project();
      for (final width in [320.0, 390.0, 800.0]) {
        for (final look in [Appearance.claro, Appearance.escuro]) {
          // Janela alta: a tela inteira numa imagem só.
          final size = Size(width, width < 600 ? 1500 : 1900);
          final (c, _) = await boot(tester, size, look, p);
          for (final MapEntry(key: id, value: name) in cases.entries) {
            await open(tester, id);
            await snap(tester, size, '$name-${width.toInt()}-${look.name}');
            await close(tester);
          }
          await shutdown(tester, c);
        }
      }
    });
  }
}

/// Avança o relógio simulado em passos de 100 ms (varredura e animações andam).
Future<void> live(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
