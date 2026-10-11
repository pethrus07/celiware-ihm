import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/models/log_group.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/logging/log_csv.dart';
import 'package:ihm/services/logging/log_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Banco do registro (consulta reduzida para o gráfico, colunas que
/// sobrevivem a renomear/apagar) e a planilha CSV para o Excel pt-BR.
void main() {
  const temp = Tag(id: 'temp', name: 'Temperatura', deviceId: 'd', dataType: TagDataType.float32, unit: '°C', decimals: 1);
  const speed = Tag(id: 'speed', name: 'Velocidade', deviceId: 'd', unit: 'm/min');
  const door = Tag(id: 'door', name: 'Porta fechada', deviceId: 'd', area: ModbusArea.coil, dataType: TagDataType.bool);
  const g = LogGroup(id: 'g', name: 'Temperaturas do forno', tagIds: ['temp', 'speed', 'door']);
  final t0 = DateTime.utc(2026, 10, 11, 12);

  late Directory dir;
  late LogStore store;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ihm_banco');
    store = LogStore(directory: () async => Directory('${dir.path}${Platform.pathSeparator}registros'), factory: databaseFactoryFfiNoIsolate);
  });

  tearDown(() async {
    await store.close();
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {/* Windows ainda segurando o arquivo */}
  });

  DateTime sec(int s) => t0.add(Duration(seconds: s));

  /// 1000 linhas a 1 s: dente de serra 0..99, um pico de 999 aos 537 s,
  /// 10 s sem comunicação a partir dos 800 s e a porta trocando a cada linha.
  Future<void> seed() => store.append(g, const [temp, speed, door], [
        for (var i = 0; i < 1000; i++)
          LogRow(sec(i), {
            'temp': i >= 800 && i < 810 ? null : (i == 537 ? 999.0 : (i % 100).toDouble()),
            'speed': 120,
            'door': (i % 2).toDouble(),
          }),
      ]);

  test('consulta reduzida: mín./máx. por fatia, o pico não some e a lacuna aparece', () async {
    await seed();
    final w = await store.query('g', from: sec(0), to: sec(1000), tagIds: const ['temp', 'door'], buckets: 10);
    expect(w.buckets.length, 10);
    expect(w.rows, 1000);
    expect(w.buckets.every((b) => b.rows == 100), isTrue);
    expect(w.buckets[3].min[0], 0);
    expect(w.buckets[3].max[0], 99);
    expect(w.buckets[5].max[0], 999, reason: 'um segundo de pico numa fatia de 100 s continua lá');
    expect(w.buckets[8].counts[0], 90, reason: '10 linhas sem comunicação');
    expect(w.buckets[8].rows, 100);
    expect((w.buckets[0].min[1], w.buckets[0].max[1]), (0.0, 1.0));
    expect(w.nearest(sec(537).millisecondsSinceEpoch), same(w.buckets[5]));
  });

  test('mais pixels que linhas: cada fatia é uma linha, valor exato', () async {
    await seed();
    final w = await store.query('g', from: sec(530), to: sec(540), tagIds: const ['temp'], buckets: 400);
    expect(w.buckets.length, 10);
    final spike = w.buckets.firstWhere((b) => b.firstMs == sec(537).millisecondsSinceEpoch);
    expect((spike.rows, spike.min[0], spike.max[0], spike.avg[0]), (1, 999.0, 999.0, 999.0));
  });

  test('fatia toda sem comunicação tem contagem zero (o gráfico interrompe a curva)', () async {
    await seed();
    final w = await store.query('g', from: sec(800), to: sec(810), tagIds: const ['temp', 'speed'], buckets: 10);
    expect(w.buckets.every((b) => b.counts[0] == 0 && b.min[0] == null), isTrue);
    expect(w.buckets.every((b) => b.counts[1] == 1), isTrue);
  });

  test('variável que nunca gravou devolve vazio, sem quebrar a consulta', () async {
    await seed();
    final w = await store.query('g', from: sec(0), to: sec(10), tagIds: const ['nova'], buckets: 10);
    expect(w.buckets.length, 10);
    expect(w.buckets.every((b) => b.counts.single == 0), isTrue);
    final none = await store.query('outro', from: sec(0), to: sec(10), tagIds: const ['temp'], buckets: 10);
    expect(none.isEmpty, isTrue);
  });

  test('colunas guardam nome e unidade; renomear atualiza; sair do grupo não apaga o dado', () async {
    await store.append(g, const [temp, speed], [LogRow(sec(0), const {'temp': 70.0, 'speed': 100.0})]);
    final renamed = temp.copyWith(name: 'Temp. do motor', unit: '°F');
    await store.append(g, [renamed], [LogRow(sec(1), const {'temp': 160.0})]);
    final cols = await store.columns('g');
    expect(cols.map((c) => (c.col, c.tagId, c.name, c.unit)), [('c1', 'temp', 'Temp. do motor', '°F'), ('c2', 'speed', 'Velocidade', 'm/min')]);
    // Velocidade saiu do grupo hoje, mas tem dado no período: vai para a planilha, depois das do grupo.
    final export = await store.exportColumns('g', from: sec(0), to: sec(5), order: const ['temp']);
    expect(export.map((c) => c.tagId), ['temp', 'speed']);
    final later = await store.exportColumns('g', from: sec(1), to: sec(5), order: const ['temp']);
    expect(later.map((c) => c.tagId), ['temp'], reason: 'sem dado no período e fora do grupo: não entra');
  });

  group('planilha CSV', () {
    test('número com vírgula decimal, casas da variável, liga/desliga 1/0', () {
      expect(LogCsv.number(75.2, decimals: 1), '75,2');
      expect(LogCsv.number(75, decimals: 1), '75,0');
      expect(LogCsv.number(1234.5), '1234,5', reason: 'ponto flutuante sem casas definidas não perde a vírgula');
      expect(LogCsv.number(3.0), '3');
      expect(LogCsv.number(0.1 + 0.2), '0,3');
      expect(LogCsv.number(-0.0), '0');
      expect(LogCsv.number(1, isBool: true), '1');
      expect(LogCsv.number(0, isBool: true), '0');
    });

    test('data e hora dd/MM/aaaa HH:mm:ss na hora local', () {
      final ms = DateTime.utc(2026, 3, 5, 7, 8, 9).millisecondsSinceEpoch;
      final local = DateTime.fromMillisecondsSinceEpoch(ms);
      String two(int n) => n.toString().padLeft(2, '0');
      expect(LogCsv.dateTime(ms), '${two(local.day)}/${two(local.month)}/${local.year} ${two(local.hour)}:${two(local.minute)}:${two(local.second)}');
      expect(LogCsv.dateTime(ms), matches(RegExp(r'^\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2}$')));
    });

    test('cabeçalho com nome e unidade; aspas só quando precisa', () {
      const cols = [
        LogColumn(col: 'c1', tagId: 'a', name: 'Temperatura', unit: '°C'),
        LogColumn(col: 'c2', tagId: 'b', name: 'Porta fechada', isBool: true),
        LogColumn(col: 'c3', tagId: 'c', name: 'Contagem; turno "A"'),
      ];
      expect(LogCsv.header(cols), 'Data e hora;Temperatura (°C);Porta fechada (1 = ligado);"Contagem; turno ""A"""\r\n');
    });

    test('arquivo: UTF-8 com BOM, ";" e CRLF, lacuna = célula vazia', () async {
      await store.append(g, const [temp, speed, door], [
        LogRow(sec(0), const {'temp': 70.5, 'speed': 120.0, 'door': 1.0}),
        LogRow(sec(1), const {'temp': null, 'speed': 121.0, 'door': 0.0}),
      ]);
      final out = await withClock(Clock.fixed(t0), () => LogCsv.export(store: store, group: g, from: sec(0), to: sec(10), dir: dir));
      expect(out.rows, 2);
      expect(out.file.uri.pathSegments.last, 'registro-temperaturas-do-forno-2026-10-11.csv');
      final bytes = await out.file.readAsBytes();
      expect(bytes.take(3), [0xEF, 0xBB, 0xBF], reason: 'sem BOM o Excel mostra "Â°C"');
      final lines = utf8.decode(bytes.skip(3).toList()).split('\r\n');
      expect(lines[0], 'Data e hora;Temperatura (°C);Velocidade (m/min);Porta fechada (1 = ligado)');
      expect(lines[1], '${LogCsv.dateTime(sec(0).millisecondsSinceEpoch)};70,5;120;1');
      expect(lines[2], '${LogCsv.dateTime(sec(1).millisecondsSinceEpoch)};;121;0');
      expect(lines[3], '', reason: 'termina com quebra de linha');
      expect(lines.length, 4);
    });

    test('período grande: páginas formatadas num isolate dão o mesmo arquivo', () async {
      await seed();
      final inline = await LogCsv.export(store: store, group: g, from: sec(0), to: sec(1000), dir: dir, pageSize: 300, isolateFrom: 1 << 30);
      final inlineText = await inline.file.readAsString();
      final isolated = await LogCsv.export(store: store, group: g, from: sec(0), to: sec(1000), dir: dir, pageSize: 300, isolateFrom: 1);
      expect(isolated.rows, 1000);
      expect(await isolated.file.readAsString(), inlineText);
      expect(inlineText.split('\r\n').where((l) => l.isNotEmpty).length, 1001); // cabeçalho + 1000
    });
  });
}
