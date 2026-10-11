import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/models/log_group.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/storage/project_repository.dart';

/// Grupo de registro no arquivo do projeto (RG-1): ida e volta, projeto
/// antigo sem grupo, valores impossíveis corrigidos e a estimativa de disco
/// calibrada pela medição.
void main() {
  const forno = LogGroup(
    id: 'lg_1',
    name: 'Forno',
    tagIds: ['temp', 'porta'],
    intervalSec: 5,
    mode: LogMode.onChange,
    deadband: 0.5,
    maxGapSec: 3600,
    retentionDays: 30,
    enabled: false,
  );

  test('grupo vai para o arquivo e volta igual', () {
    final back = LogGroup.fromJson(jsonDecode(jsonEncode(forno.toJson())) as Map<String, dynamic>);
    expect(back.id, 'lg_1');
    expect(back.name, 'Forno');
    expect(back.tagIds, ['temp', 'porta']);
    expect(back.intervalSec, 5);
    expect(back.mode, LogMode.onChange);
    expect(back.deadband, 0.5);
    expect(back.maxGapSec, 3600);
    expect(back.retentionDays, 30);
    expect(back.enabled, isFalse);
  });

  test('projeto com registro: grava e lê pelo formato do arquivo, sem subir a versão', () {
    const p = Project(name: 'P', logGroups: [forno]);
    final bytes = ProjectRepository.encode(p);
    final raw = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    expect(raw['schemaVersion'], 1);
    expect((raw['logGroups'] as List).length, 1);
    final back = ProjectRepository.decode(bytes);
    expect(back.logGroups.single.name, 'Forno');
    expect(back.logGroup('lg_1')?.retentionDays, 30);
  });

  test('projeto antigo (sem registro) abre com lista vazia e continua salvando igual', () {
    final old = utf8.encode(jsonEncode({'format': 'celiware-ihm', 'schemaVersion': 1, 'name': 'Antigo', 'devices': [], 'tags': [], 'screens': []}));
    final p = ProjectRepository.decode(old);
    expect(p.logGroups, isEmpty);
    expect(p.toJson().containsKey('logGroups'), isFalse);
  });

  test('valores impossíveis viram o mais próximo possível', () {
    final g = LogGroup.fromJson(const {
      'id': 'x',
      'name': '   ',
      'tagIds': ['a', 'a', 'b', 7],
      'intervalSec': 0,
      'deadband': -3,
      'maxGapSec': 0,
      'retentionDays': 0,
    });
    expect(g.name, 'Registro');
    expect(g.tagIds, ['a', 'b']);
    expect(g.intervalSec, 1);
    expect(g.deadband, 0);
    expect(g.maxGapSec, 1, reason: 'nunca menor que o intervalo');
    expect(g.retentionDays, 1);
    expect(g.mode, LogMode.periodic);
    expect(g.enabled, isTrue);

    final big = const LogGroup(id: 'y', intervalSec: 99999, retentionDays: 5000).normalized();
    expect(big.intervalSec, 3600);
    expect(big.retentionDays, 365);
    expect(big.maxGapSec, 3600);
  });

  test('só número e liga/desliga de valor único entram no registro', () {
    const n = Tag(id: 'n', name: 'N', deviceId: 'd');
    const b = Tag(id: 'b', name: 'B', deviceId: 'd', area: ModbusArea.coil, dataType: TagDataType.bool);
    const s = Tag(id: 's', name: 'S', deviceId: 'd', dataType: TagDataType.string, length: 4);
    const l = Tag(id: 'l', name: 'L', deviceId: 'd', length: 8);
    expect([n, b, s, l].where(LogGroup.canLog).map((t) => t.id), ['n', 'b']);
  });

  test('estimativa de disco bate com a medição: 20 variáveis a 1 s ≈ 15,8 MB/dia', () {
    final perDay = LogGroup.bytesPerDay(numbers: 20, bools: 0, intervalSec: 1);
    expect(perDay / 1e6, closeTo(15.8, 0.2));
    // Liga/desliga custa ~1 byte; a cada 10 s, um décimo.
    expect(LogGroup.bytesPerDay(numbers: 0, bools: 20, intervalSec: 1), lessThan(perDay / 4));
    expect(LogGroup.bytesPerDay(numbers: 20, bools: 0, intervalSec: 10), closeTo(perDay / 10, 1));
    const tags = [Tag(id: 'a', name: 'A', deviceId: 'd'), Tag(id: 'b', name: 'B', deviceId: 'd')];
    final week = const LogGroup(id: 'g', intervalSec: 1, retentionDays: 7).estimateBytes(tags);
    expect(week, closeTo(LogGroup.bytesPerDay(numbers: 2, bools: 0, intervalSec: 1) * 7, 1));
  });

  test('textos curtos: intervalo, retenção e tamanho com vírgula', () {
    expect([1, 30, 60, 300, 3600].map(LogGroup.durationLabel), ['1 s', '30 s', '1 min', '5 min', '1 h']);
    expect([1, 7, 365].map(LogGroup.daysLabel), ['1 dia', '7 dias', '1 ano']);
    expect(LogGroup.sizeLabel(850000), '850 kB');
    expect(LogGroup.sizeLabel(3.2e6), '3,2 MB');
    expect(LogGroup.sizeLabel(15.8e6), '16 MB');
    expect(LogGroup.sizeLabel(1.2e9), '1,2 GB');
  });

  test('buraco no gráfico: depende do ritmo e do modo', () {
    expect(const LogGroup(id: 'a', intervalSec: 1).gapThreshold, const Duration(seconds: 3));
    expect(const LogGroup(id: 'b', intervalSec: 60).gapThreshold, const Duration(seconds: 150));
    expect(const LogGroup(id: 'c', intervalSec: 1, mode: LogMode.onChange, maxGapSec: 600).gapThreshold, const Duration(seconds: 602));
  });
}
