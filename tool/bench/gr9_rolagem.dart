// GR-9 — medidor de rolagem em modo profile (quadros reais, com GPU).
//
// Monta a tela densa de 48 elementos (a mesma do teste
// `test/widgets/grid_performance_test.dart`) com varredura de 500 ms, rola a
// tela para cima e para baixo sem parar e anota o FrameTiming de cada quadro
// (tempo de montagem na thread da interface e de desenho na de GPU). Três
// fases de 15 s: "referência" (a tela de operação da demonstração, com a
// cortadora em ciclo — régua do próprio aparelho), "ciclo" (13 das 58
// leituras da tela densa mudam a cada varredura: 12 números e uma lâmpada) e
// "pior-caso" (todas mudam). O resumo sai no log com o prefixo GR9.
//
// O APK tem o mesmo pacote do app e instala por cima dele: use um aparelho
// ou emulador de teste. Num PC ocupado (outro emulador aberto, CPU acima de
// ~50%), o emulador mede a disputa, não a tela — compare com a fase de
// referência antes de acreditar no número.
//
// Uso (emulador ou aparelho, nunca em debug — debug mede o compilador):
//   flutter build apk --profile -t tool/bench/gr9_rolagem.dart
//   adb -s <aparelho> install -r build/app/outputs/flutter-apk/app-profile.apk
//   adb -s <aparelho> shell monkey -p com.celiware.ihm -c android.intent.category.LAUNCHER 1
//   adb -s <aparelho> logcat -s flutter      (esperar "GR9 FIM")
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/runtime/device_session.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Sem tutorial por cima da tela medida.
  final prefs = await SharedPreferences.getInstance();
  for (final (id, _, _) in Tours.catalog) {
    await prefs.setBool('tour:v1:$id', true);
  }
  Ind.use(IndPalette.escuro);

  final dir = Directory('${(await getTemporaryDirectory()).path}/gr9');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  final (dense, screen) = denseProject();
  final demo = DemoProject.build();
  final project = Project(
    name: 'GR-9',
    devices: [...demo.devices, ...dense.devices],
    tags: [...demo.tags, ...dense.tags],
    screens: [...demo.screens, screen],
  );
  final repo = ProjectRepository(directory: dir);
  await repo.save(project);

  final memory = ModbusMemory(holdingRegisters: 1000, coils: 100);
  for (var i = 0; i < 100; i++) {
    memory.pokeRegister(ModbusArea.holdingRegister, 300 + i, 1000 + i * 37);
  }
  // Latência padrão do simulador (15 ms): parecida com a rede de fábrica.
  final runtime = HmiRuntime(clientFactory: (d) => d.isDemo ? DeviceSession.defaultClientFactory(d) : SimulatedModbusClient(memory: memory));
  final controller = ProjectController(repository: repo, runtime: runtime);
  await controller.load();
  runApp(CeliwareIhmApp(controller: controller, runtime: runtime));

  await Future<void>.delayed(const Duration(seconds: 3));
  final nav = _find<NavigatorState>()!;

  // Referência: a tela de operação da demonstração com a cortadora em ciclo.
  nav.push(MaterialPageRoute<void>(builder: (_) => const ScreenRunPage(screenId: DemoProject.operationScreenId)));
  await Future<void>.delayed(const Duration(seconds: 2));
  DemoRegistry.forDevice(DemoProject.deviceId).memory.pokeBit(ModbusArea.coil, DemoMap.coilRun, true);
  await Future<void>.delayed(const Duration(seconds: 2));
  await _phase('referencia', _canvasScroll()!.position, const Duration(seconds: 15));
  nav.pushReplacement(MaterialPageRoute<void>(builder: (_) => ScreenRunPage(screenId: screen.id)));
  await Future<void>.delayed(const Duration(seconds: 3));

  // O "CLP": muda [changing] leituras a cada varredura.
  final rng = math.Random(9);
  var changing = 12;
  var tick = 0;
  final machine = Timer.periodic(const Duration(milliseconds: 500), (_) {
    // Dos 50 registradores, [changing] mudam; das 8 lâmpadas, uma (todas no pior caso).
    final regs = [for (var i = 0; i < 50; i++) i]..shuffle(rng);
    for (final i in regs.take(math.min(changing, 50))) {
      memory.pokeRegister(ModbusArea.holdingRegister, _registerOf(i), 1000 + rng.nextInt(8000));
    }
    for (var b = 0; b < 8; b++) {
      if (changing > 50 || b == tick % 8) memory.pokeBit(ModbusArea.coil, b, !memory.bit(ModbusArea.coil, b));
    }
    tick++;
  });

  final canvas = _canvasScroll()!;
  await _phase('ciclo', canvas.position, const Duration(seconds: 15));
  changing = 58;
  await _phase('pior-caso', canvas.position, const Duration(seconds: 15));
  machine.cancel();
  debugPrint('GR9 FIM');
}

/// Os 50 registradores da tela densa (mostradores, barras, medidores,
/// tabela, indicadores e ajuste), na ordem.
int _registerOf(int i) => i < 24
    ? 300 + i
    : i < 34
        ? 330 + (i - 24)
        : i < 46
            ? 340 + (i - 34)
            : i < 49
                ? 360 + (i - 46)
                : 365;

Future<void> _phase(String name, ScrollPosition pos, Duration length) async {
  final timings = <FrameTiming>[];
  void collect(List<FrameTiming> t) => timings.addAll(t);
  SchedulerBinding.instance.addTimingsCallback(collect);
  final sw = Stopwatch()..start();
  var down = true;
  while (sw.elapsed < length) {
    await pos.animateTo(down ? pos.maxScrollExtent : 0, duration: const Duration(milliseconds: 1500), curve: Curves.linear);
    down = !down;
  }
  // Os tempos chegam em lote (~1 s): espera o último.
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  SchedulerBinding.instance.removeTimingsCallback(collect);
  final secs = sw.elapsedMilliseconds / 1000 - 1.5;

  double ms(Duration d) => d.inMicroseconds / 1000;
  List<double> sorted(Iterable<double> v) => v.toList()..sort();
  double pct(List<double> v, double p) => v.isEmpty ? 0 : v[math.min(v.length - 1, (v.length * p).floor())];
  final build = sorted(timings.map((t) => ms(t.buildDuration)));
  final raster = sorted(timings.map((t) => ms(t.rasterDuration)));
  final worst = sorted(timings.map((t) => math.max(ms(t.buildDuration), ms(t.rasterDuration))));
  final over16 = worst.where((v) => v > 1000 / 60).length;
  final over32 = worst.where((v) => v > 32).length;
  String f(double v) => v.toStringAsFixed(1);
  debugPrint('GR9 fase=$name quadros=${timings.length} segundos=${f(secs)} qps=${f(timings.length / secs)} '
      'montagem_mediana=${f(pct(build, 0.5))}ms montagem_p99=${f(pct(build, 0.99))}ms '
      'desenho_mediana=${f(pct(raster, 0.5))}ms desenho_p99=${f(pct(raster, 0.99))}ms '
      'pior=${f(worst.isEmpty ? 0 : worst.last)}ms acima_16ms=$over16 acima_32ms=$over32');
}

/// A rolagem da grade: o Scrollable de maior curso dentro da tela em operação.
ScrollableState? _canvasScroll() {
  Element? page;
  void findPage(Element e) {
    if (e.widget is ScreenRunPage) page = e;
    e.visitChildElements(findPage);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(findPage);
  ScrollableState? best;
  void visit(Element e) {
    if (e is StatefulElement && e.state is ScrollableState) {
      final s = e.state as ScrollableState;
      if (s.position.hasContentDimensions && (best == null || s.position.maxScrollExtent > best!.position.maxScrollExtent)) best = s;
    }
    e.visitChildElements(visit);
  }

  page?.visitChildElements(visit);
  return best;
}

T? _find<T extends State>() {
  T? found;
  void visit(Element e) {
    if (found != null) return;
    if (e is StatefulElement && e.state is T) {
      found = e.state as T;
      return;
    }
    e.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  return found;
}

/// Tela fina com 48 elementos de todos os tipos que leem: 24 mostradores
/// (12 normais e 12 de uma linha), 8 lâmpadas, 6 barras, 4 medidores, 3
/// indicadores de estado, 1 ajuste, 1 tendência e 1 tabela de 12 linhas.
/// Uma variável por elemento (a tendência reaproveita dois mostradores).
(Project, HmiScreen) denseProject() {
  const clp = Device(id: 'clp', name: 'CLP', host: '10.0.0.9', pollMs: 500);
  final tags = <Tag>[];
  final elements = <HmiElement>[];
  void reg(String id, int address, {bool writable = false}) =>
      tags.add(Tag(id: id, name: 'Var $id', deviceId: clp.id, address: address, unit: 'un', writable: writable));
  void add(String id, ElementType type, int x, int y, int w, int h, Map<String, dynamic> props) =>
      elements.add(HmiElement(id: id, type: type, x: x, y: y, w: w, h: h, props: {'label': id, ...props}));

  // Mostradores: 12 de 6×2 e 12 de uma linha (4×1).
  for (var i = 0; i < 24; i++) {
    reg('v$i', 300 + i);
    if (i < 12) {
      add('v$i', ElementType.value, (i % 2) * 6, (i ~/ 2) * 2, 6, 2, {'tagId': 'v$i'});
    } else {
      final k = i - 12;
      add('v$i', ElementType.value, (k % 3) * 4, 12 + k ~/ 3, 4, 1, {'tagId': 'v$i'});
    }
  }
  for (var i = 0; i < 8; i++) {
    tags.add(Tag(id: 'l$i', name: 'Lâmpada $i', deviceId: clp.id, area: ModbusArea.coil, address: i, dataType: TagDataType.bool));
    add('l$i', ElementType.lamp, (i % 2) * 6, 16 + (i ~/ 2) * 2, 6, 2, {'tagId': 'l$i', 'onText': 'LIGADO', 'offText': 'DESLIGADO'});
  }
  for (var i = 0; i < 6; i++) {
    reg('b$i', 330 + i);
    add('b$i', ElementType.bar, 0, 24 + i * 2, 12, 2, {'tagId': 'b$i', 'min': 0, 'max': 10000});
  }
  for (var i = 0; i < 4; i++) {
    reg('g$i', 336 + i);
    add('g$i', ElementType.gauge, (i % 2) * 6, 36 + (i ~/ 2) * 6, 6, 6, {'tagId': 'g$i', 'min': 0, 'max': 10000});
  }
  for (var i = 0; i < 3; i++) {
    reg('m$i', 360 + i);
    add('m$i', ElementType.multistate, i * 4, 48, 4, 2, {
      'tagId': 'm$i',
      'states': [
        {'value': 0, 'text': 'PARADA', 'color': 'neutral'},
      ],
    });
  }
  reg('sp', 365, writable: true);
  add('sp', ElementType.input, 0, 50, 12, 4, {'tagId': 'sp'});
  add('trend', ElementType.trend, 0, 54, 12, 8, {
    'tagIds': ['v0', 'v1'],
    'windowSec': 60,
  });
  for (var i = 0; i < 12; i++) {
    reg('r$i', 340 + i);
  }
  add('tabela', ElementType.table, 0, 62, 12, 12, {
    'tagIds': [for (var i = 0; i < 12; i++) 'r$i'],
    'label': '',
  });

  final screen = HmiScreen(id: 'densa', name: 'Densa', columns: 12, readOnly: true, elements: elements);
  return (Project(name: 'GR-9', devices: const [clp], tags: tags, screens: [screen]), screen);
}
