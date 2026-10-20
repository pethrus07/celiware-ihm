import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/modbus/modbus_client_simulated.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/log_group.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/logging/data_logger.dart';
import 'package:ihm/services/logging/log_store.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/runtime/tag_store.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Motor de registro (RG-2 a RG-4) sobre SQLite de verdade (ffi, arquivo
/// temporário) e relógio controlado (`withClock`): as leituras são
/// publicadas à mão no runtime — sem equipamento, nenhuma varredura
/// atrapalha — e cada `tick` é um segundo do timer.
void main() {
  const temp = Tag(id: 'temp', name: 'Temperatura', deviceId: 'd1', dataType: TagDataType.float32, unit: '°C', decimals: 1);
  const speed = Tag(id: 'speed', name: 'Velocidade', deviceId: 'd1', unit: 'm/min');
  const door = Tag(id: 'door', name: 'Porta fechada', deviceId: 'd1', area: ModbusArea.coil, dataType: TagDataType.bool);
  const recipe = Tag(id: 'txt', name: 'Receita', deviceId: 'd1', dataType: TagDataType.string, length: 4);
  const hourly = Tag(id: 'hora', name: 'Produção por hora', deviceId: 'd1', length: 8);
  // Ontem ao meio-dia (UTC), e não uma data fixa: a descarga sem relógio
  // falso confere a retenção (7 dias) pelo relógio de verdade, e a data
  // fixa de 11/10 passou a ser apagada como velha a partir de 18/10.
  final today = DateTime.now().toUtc();
  final t0 = DateTime.utc(today.year, today.month, today.day, 12).subtract(const Duration(days: 1));

  late Directory dir;
  late HmiRuntime runtime;
  late ProjectController controller;
  late LogStore store;
  DataLogger? logger;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ihm_registro');
    runtime = HmiRuntime();
    controller = ProjectController(repository: ProjectRepository(directory: dir), runtime: runtime);
    store = LogStore.beside(controller.repository, factory: databaseFactoryFfiNoIsolate);
    logger = null;
  });

  tearDown(() async {
    final l = logger;
    if (l != null) {
      await l.close();
      l.dispose();
    }
    await store.close();
    await runtime.dispose();
    controller.dispose();
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {/* Windows ainda segurando o arquivo — é só a pasta temporária */}
  });

  LogGroup group({int interval = 1, LogMode mode = LogMode.periodic, double deadband = 0, int maxGap = 600, int retention = 7}) => LogGroup(
        id: 'g1',
        name: 'Forno',
        tagIds: const ['temp', 'speed', 'door', 'txt', 'hora'],
        intervalSec: interval,
        mode: mode,
        deadband: deadband,
        maxGapSec: maxGap,
        retentionDays: retention,
      );

  Project project(List<LogGroup> groups) => Project(tags: const [temp, speed, door, recipe, hourly], logGroups: groups);

  Future<DataLogger> start(Project p, {DateTime? at}) async {
    await controller.replace(p);
    final l = withClock(Clock.fixed(at ?? t0), () => DataLogger(controller: controller, runtime: runtime, store: store, tickEvery: null, flushEvery: null));
    logger = l;
    await withClock(Clock.fixed(at ?? t0), l.flush); // espera a abertura (pasta, órfãos, retenção)
    return l;
  }

  void put(String id, Object? v, DateTime at, {TagQuality q = TagQuality.good}) =>
      withClock(Clock.fixed(at), () => runtime.store.publish(id, TagReading(value: v, quality: q, at: at)));

  void scan(DateTime at, {double t = 70.5, int s = 120, bool d = true}) {
    put('temp', t, at);
    put('speed', s, at);
    put('door', d, at);
  }

  void tickAt(DateTime at) => withClock(Clock.fixed(at), () => logger!.tick());

  DateTime sec(int s) => t0.add(Duration(seconds: s));

  /// Linhas gravadas: {t, tagId: valor}.
  Future<List<Map<String, Object?>>> saved(String groupId) async {
    final cols = await store.columns(groupId);
    final page = await store.page(groupId, cols, afterMs: 0, toMs: 1 << 62, limit: 100000);
    return [
      for (final r in page) {'t': r[0], for (var i = 0; i < cols.length; i++) cols[i].tagId: r[i + 1]},
    ];
  }

  test('periódico: uma linha a cada intervalo, só com número e liga/desliga', () async {
    final l = await start(project([group(interval: 5)]));
    for (var s = 0; s <= 10; s++) {
      scan(sec(s));
      tickAt(sec(s));
    }
    expect(l.pendingOf('g1'), 3); // 0, 5 e 10 s
    await l.flush();
    final rows = await saved('g1');
    expect(rows.map((r) => r['t']), [sec(0), sec(5), sec(10)].map((t) => t.millisecondsSinceEpoch));
    expect(rows.first, containsPair('temp', 70.5));
    expect(rows.first, containsPair('speed', 120.0));
    expect(rows.first, containsPair('door', 1.0));
    // Texto e lista não viram coluna.
    expect((await store.columns('g1')).map((c) => c.tagId), ['temp', 'speed', 'door']);
  });

  test('o compasso não escorrega com o atraso do timer', () async {
    final l = await start(project([group(interval: 1)]));
    // O timer chega 150 ms antes ou depois: nenhuma amostra se perde ou dobra.
    for (final ms in [0, 1150, 1990, 3120, 3850, 5000]) {
      final at = t0.add(Duration(milliseconds: ms));
      scan(at);
      tickAt(at);
    }
    expect(l.pendingOf('g1'), 6);
  });

  test('ao mudar: banda morta, liga/desliga e máximo entre amostras', () async {
    final l = await start(project([group(mode: LogMode.onChange, deadband: 0.5, maxGap: 60)]));
    final temps = {0: 20.0, 1: 20.3, 2: 20.6, 3: 20.9};
    for (var s = 0; s <= 70; s++) {
      scan(sec(s), t: temps[s] ?? 20.9, d: s < 4);
      tickAt(sec(s));
    }
    await l.flush();
    final rows = await saved('g1');
    // 0: primeira · 2: mudou 0,6 (≥ 0,5) desde a última gravada · 4: porta abriu ·
    // 64: 60 s parado — prova de vida, não buraco.
    expect(rows.map((r) => r['t']), [0, 2, 4, 64].map((s) => sec(s).millisecondsSinceEpoch));
    expect(rows[1]['temp'], closeTo(20.6, 1e-6));
    expect(rows[2]['door'], 0.0);
  });

  test('sem comunicação grava lacuna (nulo), nunca o último valor como bom', () async {
    final l = await start(project([group()]));
    scan(sec(0));
    tickAt(sec(0));

    // Queda: a tela continua mostrando 70,5 esmaecido; o registro grava nulo.
    withClock(Clock.fixed(sec(1)), () => runtime.store.publish('temp', runtime.store.read('temp').degrade(TagQuality.commLost, 'sem resposta')));
    put('speed', 121, sec(1));
    put('door', true, sec(1));
    tickAt(sec(1));
    expect(runtime.store.read('temp').value, 70.5);

    // Endereço recusado também não é valor.
    put('temp', null, sec(2), q: TagQuality.addressError);
    put('speed', 122, sec(2));
    put('door', true, sec(2));
    tickAt(sec(2));

    // Leitura que parou de chegar (laço travado) deixa de valer depois de 10 s.
    put('temp', 71.0, sec(3));
    for (var s = 3; s <= 14; s++) {
      put('temp', 71.0, sec(s));
      tickAt(sec(s));
    }
    await l.flush();
    final rows = await saved('g1');
    expect(rows[0]['temp'], 70.5);
    expect(rows[1]['temp'], isNull);
    expect(rows[1]['speed'], 121.0);
    expect(rows[2]['temp'], isNull);
    final last = rows.last;
    expect(last['temp'], 71.0);
    expect(last['speed'], isNull, reason: 'velocidade parada desde 2 s: mais de 10 s sem leitura');
    expect(last['door'], isNull);
  });

  test('logo ao abrir espera a primeira leitura; depois da folga, lacuna', () async {
    // Equipamento que demora a responder: a primeira leitura ainda não chegou.
    final client = SimulatedModbusClient(memory: ModbusMemory(holdingRegisters: 8), latency: const Duration(seconds: 1));
    final rt = HmiRuntime(clientFactory: (_) => client);
    final ctl = ProjectController(repository: ProjectRepository(directory: dir), runtime: rt);
    await ctl.replace(const Project(devices: [Device(id: 'd1', name: 'CLP', host: 'x')], tags: [speed], logGroups: [LogGroup(id: 'g3', tagIds: ['speed'])]));
    final l = withClock(Clock.fixed(t0), () => DataLogger(controller: ctl, runtime: rt, store: store, tickEvery: null, flushEvery: null));
    addTearDown(() async {
      await l.close();
      l.dispose();
      await rt.dispose();
      ctl.dispose();
    });
    withClock(Clock.fixed(sec(0)), l.tick);
    withClock(Clock.fixed(sec(5)), l.tick);
    expect(l.pendingOf('g3'), 0, reason: 'nada lido ainda e dentro da folga');
    withClock(Clock.fixed(sec(11)), l.tick);
    expect(l.pendingOf('g3'), 1);
    await l.flush();
    expect((await saved('g3')).single['speed'], isNull);
  });

  test('equipamento apagado é estado conhecido: lacuna desde a primeira amostra', () async {
    final l = await start(project([group()])); // as variáveis apontam para "d1", que não existe
    tickAt(sec(0));
    await l.flush();
    expect((await saved('g1')).single['temp'], isNull);
  });

  test('lote: nada no disco antes da descarga; descarga grava tudo de uma vez', () async {
    final l = await start(project([group()]));
    for (var s = 0; s < 5; s++) {
      scan(sec(s));
      tickAt(sec(s));
    }
    expect(l.pendingOf('g1'), 5);
    expect(await store.count('g1'), 0);
    await l.flush();
    expect(await store.count('g1'), 5);
    expect(l.pendingOf('g1'), 0);
    expect(l.usageOf('g1'), greaterThan(0));
  });

  test('segundo plano: descarrega, para de amostrar e na volta espera leitura nova', () async {
    final l = await start(project([group()]));
    scan(sec(0));
    tickAt(sec(0));
    scan(sec(1));
    tickAt(sec(1));
    await withClock(Clock.fixed(sec(2)), l.pause);
    expect(await store.count('g1'), 2, reason: 'o lote foi para o disco ao pausar');
    tickAt(sec(30));
    expect(l.pendingOf('g1'), 0, reason: 'pausado não amostra');

    withClock(Clock.fixed(sec(60)), l.resume);
    tickAt(sec(61));
    expect(l.pendingOf('g1'), 0, reason: 'a leitura de antes da pausa não vale mais');
    scan(sec(62));
    tickAt(sec(62));
    expect(l.pendingOf('g1'), 1);
  });

  test('retenção: apaga só o que passou do prazo do grupo', () async {
    final l = await start(project([group(retention: 7)]));
    final g = group(retention: 7);
    await store.append(g, const [temp], [
      for (final days in [10, 8, 1, 0]) LogRow(t0.subtract(Duration(days: days)), const {'temp': 50.0}),
    ]);
    await withClock(Clock.fixed(t0), l.rotateNow);
    final rows = await saved('g1');
    expect(rows.map((r) => r['t']), [t0.subtract(const Duration(days: 1)), t0].map((t) => t.millisecondsSinceEpoch));
  });

  test('apagar o grupo apaga o arquivo e devolve o espaço', () async {
    final l = await start(project([group()]));
    scan(sec(0));
    tickAt(sec(0));
    await l.flush();
    final file = File('${dir.path}${Platform.pathSeparator}${LogStore.folder}${Platform.pathSeparator}${LogStore.fileName('g1')}');
    expect(file.existsSync(), isTrue);
    await l.deleteGroup('g1');
    expect(controller.project.logGroups, isEmpty);
    expect(file.existsSync(), isFalse);
    expect(store.sizeOf('g1'), 0);
  });

  test('banco de grupo que saiu do projeto vale até a retenção dele e depois some', () async {
    // Dois registros de um projeto anterior: um recente, um vencido.
    await store.append(const LogGroup(id: 'recente', retentionDays: 7), const [temp], [LogRow(t0.subtract(const Duration(days: 3)), const {'temp': 1.0})]);
    await store.append(const LogGroup(id: 'vencido', retentionDays: 7), const [temp], [LogRow(t0.subtract(const Duration(days: 10)), const {'temp': 1.0})]);
    await store.close();
    await start(project([group()]));
    final folder = '${dir.path}${Platform.pathSeparator}${LogStore.folder}${Platform.pathSeparator}';
    expect(File('$folder${LogStore.fileName('recente')}').existsSync(), isTrue);
    expect(File('$folder${LogStore.fileName('vencido')}').existsSync(), isFalse);
  });

  test('grupo desligado não inscreve nem grava; ligado de novo, volta', () async {
    final l = await start(project([group().copyWith(enabled: false)]));
    scan(sec(0));
    tickAt(sec(0));
    expect(l.pendingOf('g1'), 0);
    controller.saveLogGroup(group());
    scan(sec(1));
    tickAt(sec(1));
    expect(l.pendingOf('g1'), 1);
  });

  test('ponta a ponta com equipamento simulado: queda vira lacuna no banco', () async {
    final memory = ModbusMemory(holdingRegisters: 8);
    final client = SimulatedModbusClient(memory: memory, latency: Duration.zero);
    final rt = HmiRuntime(clientFactory: (_) => client);
    final ctl = ProjectController(repository: ProjectRepository(directory: dir), runtime: rt);
    const dev = Device(id: 'd1', name: 'CLP', host: 'x', pollMs: 20, timeoutMs: 100);
    const level = Tag(id: 'nivel', name: 'Nível', deviceId: 'd1', address: 3, unit: '%');
    await ctl.replace(const Project(devices: [dev], tags: [level], logGroups: [LogGroup(id: 'g2', tagIds: ['nivel'])]));
    final l = DataLogger(controller: ctl, runtime: rt, store: store, tickEvery: null, flushEvery: null);
    addTearDown(() async {
      await l.close();
      l.dispose();
      await rt.dispose();
      ctl.dispose();
    });

    Future<void> until(bool Function(TagReading) ok) async {
      final n = rt.watch('nivel');
      if (ok(n.value)) return;
      final c = Completer<void>();
      void f() {
        if (ok(n.value) && !c.isCompleted) c.complete();
      }

      n.addListener(f);
      try {
        await c.future.timeout(const Duration(seconds: 3));
      } finally {
        n.removeListener(f);
      }
    }

    memory.pokeRegister(ModbusArea.holdingRegister, 3, 42);
    await until((r) => r.isGood && r.value == 42); // o registro sozinho manteve a variável inscrita
    final now = DateTime.now();
    withClock(Clock.fixed(now.add(const Duration(seconds: 1))), l.tick);
    client.failureRate = 1;
    await until((r) => r.quality == TagQuality.commLost);
    withClock(Clock.fixed(now.add(const Duration(seconds: 2))), l.tick);
    await l.flush();
    final cols = await store.columns('g2');
    final rows = await store.page('g2', cols, afterMs: 0, toMs: 1 << 62);
    expect(rows.map((r) => r[1]), [42.0, null]);
  });
}
