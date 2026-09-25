import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/runtime/scan_planner.dart';

Tag _hr(String id, int address, {TagDataType type = TagDataType.uint16, int length = 1}) =>
    Tag(id: id, name: id, deviceId: 'd', address: address, dataType: type, length: length);

Tag _coil(String id, int address) =>
    Tag(id: id, name: id, deviceId: 'd', area: ModbusArea.coil, address: address, dataType: TagDataType.bool);

void main() {
  const planner = ScanPlanner(maxRegisterGap: 8);

  test('vizinhas viram uma leitura só', () {
    final blocks = planner.plan([_hr('a', 0), _hr('b', 1), _hr('c', 3, type: TagDataType.float32)]);
    expect(blocks, hasLength(1));
    expect(blocks.single.start, 0);
    expect(blocks.single.count, 5); // 0..4 (float ocupa 3 e 4)
  });

  test('buraco maior que o limite separa em dois blocos', () {
    final blocks = planner.plan([_hr('a', 0), _hr('b', 100)]);
    expect(blocks.map((b) => b.start), [0, 100]);
  });

  test('nunca passa de 125 registradores por leitura', () {
    final tags = [for (var i = 0; i < 300; i += 2) _hr('t$i', i)];
    final blocks = planner.plan(tags);
    expect(blocks.every((b) => b.count <= 125), isTrue);
    expect(blocks.expand((b) => b.tags), hasLength(tags.length));
  });

  test('áreas diferentes nunca se misturam', () {
    final blocks = planner.plan([_hr('a', 0), _coil('b', 0), _coil('c', 5)]);
    expect(blocks, hasLength(2));
    expect(blocks.firstWhere((b) => b.area == ModbusArea.coil).count, 6);
  });

  test('variável isolada ganha leitura própria', () {
    final blocks = planner.plan([_hr('a', 0), _hr('b', 1), _hr('c', 2)], isolated: {'b'});
    expect(blocks, hasLength(2));
    expect(blocks.any((b) => b.tags.length == 1 && b.tags.single.id == 'b'), isTrue);
  });

  test('duas variáveis no mesmo endereço (ex.: bits da mesma palavra) dividem a leitura', () {
    const b0 = Tag(id: 'b0', name: 'b0', deviceId: 'd', address: 30, dataType: TagDataType.bool, bitIndex: 0);
    const b1 = Tag(id: 'b1', name: 'b1', deviceId: 'd', address: 30, dataType: TagDataType.bool, bitIndex: 1);
    final blocks = planner.plan([b0, b1]);
    expect(blocks.single.count, 1);
    expect(blocks.single.tags, hasLength(2));
  });
}
