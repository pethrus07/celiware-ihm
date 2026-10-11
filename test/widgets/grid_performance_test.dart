import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/modbus/modbus_client_simulated.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/main.dart';
import 'package:ihm/screens/screen_run_page.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:ihm/widgets/hmi/hmi_canvas.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../tool/bench/gr9_rolagem.dart' show denseProject;

/// GR-9 — tela com 48 elementos e varredura de 500 ms: **só o que mudou
/// redesenha**, e rolar não redesenha nada.
///
/// O que dá para provar sem aparelho é o trabalho por quadro, contado:
///   • reconstruções disparadas por leitura (o filtro do `TagBuilder`);
///   • elementos repintados (cada elemento tem a própria camada, e o gancho
///     de pintura do Flutter diz qual camada foi repintada).
/// Quadros por segundo de verdade dependem da GPU do aparelho: medidos à
/// parte, em modo profile, com a mesma tela (`tool/bench/gr9_rolagem.dart`).
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  late Directory dir;
  late ModbusMemory memory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      for (final (id, _, _) in Tours.catalog) 'tour:v1:$id': true,
    });
    dir = await Directory.systemTemp.createTemp('ihm_gr9');
    memory = ModbusMemory(holdingRegisters: 1000, coils: 100);
  });

  tearDown(() async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {/* Windows ainda segurando o arquivo */}
  });

  testWidgets('48 elementos, varredura de 500 ms: só o que mudou redesenha; rolar não redesenha', (tester) async {
    final (project, screen) = denseProject();
    expect(screen.elements, hasLength(48));
    for (var i = 0; i < 100; i++) {
      memory.pokeRegister(ModbusArea.holdingRegister, 300 + i, 10 + i);
    }

    final client = SimulatedModbusClient(memory: memory, latency: Duration.zero);
    final rt = HmiRuntime(clientFactory: (_) => client);
    final repo = ProjectRepository(directory: dir);
    await tester.runAsync(() => repo.save(project));
    final c = ProjectController(repository: repo, runtime: rt);
    await tester.runAsync(c.load);
    tester.view.physicalSize = const Size(1170, 2532); // 390×844 dp
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CeliwareIhmApp(controller: c, runtime: rt));
    await live(tester, 600);
    tester.state<NavigatorState>(find.byType(Navigator).first).push(MaterialPageRoute<void>(builder: (_) => ScreenRunPage(screenId: screen.id)));
    await live(tester, 2000);

    // A camada de cada elemento → o id dele.
    final layerOf = <RenderObject, String>{
      for (final e in screen.elements)
        tester.renderObject(find.descendant(of: find.byKey(ValueKey('el-${e.id}')), matching: find.byType(RepaintBoundary)).first): e.id,
    };
    final repainted = <String>{};
    var readingBuilds = 0;
    debugOnProfilePaint = (child) {
      // A camada pedida pelo pai (rolagem) é só recomposta, não repintada.
      if (layerOf.containsKey(child)) return;
      for (RenderObject? r = child; r != null; r = r.parent) {
        final id = layerOf[r];
        if (id != null) {
          repainted.add(id);
          return;
        }
      }
    };
    debugOnRebuildDirtyWidget = (element, _) {
      if (element.widget.runtimeType.toString() == '_ReadingListener') readingBuilds++;
    };
    void reset() {
      repainted.clear();
      readingBuilds = 0;
    }

    try {
      // 1) Nada muda no equipamento: 4 varreduras, nenhuma leitura redesenha.
      //    Só a tendência anda (é a curva rolando no tempo, de propósito).
      reset();
      await live(tester, 2000);
      expect(readingBuilds, 0, reason: 'leitura igual com carimbo novo não redesenha');
      expect(repainted, everyElement('trend'));

      // 2) Três valores mudam: três redesenhos (mostrador, lâmpada e uma linha
      //    da tabela), e só esses elementos repintam.
      reset();
      memory.pokeRegister(ModbusArea.holdingRegister, 305, 777); // mostrador v5
      memory.pokeBit(ModbusArea.coil, 2, true); // lâmpada l2
      memory.pokeRegister(ModbusArea.holdingRegister, 343, 999); // linha r3 da tabela
      await live(tester, 600);
      expect(readingBuilds, 3);
      expect(repainted.difference({'trend'}), {'v5', 'l2', 'tabela'});

      // 3) Rolar a tela inteira por ~1 s, a 60 quadros/s: nada reconstrói por
      //    leitura e nenhum elemento repinta — a rolagem só move camadas.
      reset();
      final canvas = find.byType(HmiCanvas);
      final g = await tester.startGesture(tester.getCenter(canvas));
      for (var i = 0; i < 60; i++) {
        await g.moveBy(const Offset(0, -20));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final scroll = tester.state<ScrollableState>(find.descendant(of: canvas, matching: find.byType(Scrollable)).first);
      expect(scroll.position.pixels, greaterThan(800), reason: 'a tela rolou de fato');
      expect(readingBuilds, 0);
      expect(repainted.difference({'trend'}), isEmpty);

      // 4) Contraprova: tudo muda de uma vez → cada leitura à vista redesenha
      //    (o contador conta; os zeros acima não são de graça).
      reset();
      for (var i = 0; i < 100; i++) {
        memory.pokeRegister(ModbusArea.holdingRegister, 300 + i, 5000 + i);
      }
      for (var i = 0; i < 8; i++) {
        memory.pokeBit(ModbusArea.coil, i, !memory.bit(ModbusArea.coil, i));
      }
      await live(tester, 600);
      // 24 mostradores + 8 lâmpadas + 6 barras + 4 medidores + 3 indicadores
      // + 1 ajuste + 12 linhas da tabela = 58 leituras na tela.
      expect(readingBuilds, 58);
      expect(repainted, hasLength(48));
    } finally {
      debugOnProfilePaint = null;
      debugOnRebuildDirtyWidget = null;
    }

    await tester.pumpWidget(const SizedBox());
    final done = rt.dispose();
    await live(tester, 1200);
    await done;
    c.dispose();
  });
}

/// Avança o relógio simulado em passos de 100 ms (varredura e timers andam).
Future<void> live(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
