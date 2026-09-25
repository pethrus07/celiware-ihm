import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/runtime/tag_codec.dart';

Tag _t(TagDataType type, [ByteOrder order = ByteOrder.abcd]) =>
    Tag(id: 't', name: 'Teste', deviceId: 'd', dataType: type, byteOrder: order, writable: true);

void main() {
  group('32 bits nas quatro ordens (valor 0x11223344)', () {
    const v = 0x11223344;
    final cases = {
      ByteOrder.abcd: [0x1122, 0x3344],
      ByteOrder.cdab: [0x3344, 0x1122],
      ByteOrder.badc: [0x2211, 0x4433],
      ByteOrder.dcba: [0x4433, 0x2211],
    };
    cases.forEach((order, regs) {
      test('${order.label}: lê e grava', () {
        final tag = _t(TagDataType.uint32, order);
        expect(TagCodec.decodeRegisters(tag, regs), v);
        expect(TagCodec.encodeRegisters(tag, v), regs);
      });
    });
  });

  test('FLOAT32 ida e volta (12,5 em CDAB)', () {
    final tag = _t(TagDataType.float32, ByteOrder.cdab);
    final regs = TagCodec.encodeRegisters(tag, 12.5);
    expect(regs, [0x0000, 0x4148]); // 12.5 = 0x41480000, palavras trocadas
    expect(TagCodec.decodeRegisters(tag, regs), 12.5);
  });

  test('INT16 e INT32 negativos', () {
    expect(TagCodec.decodeRegisters(_t(TagDataType.int16), [0xFFFE]), -2);
    expect(TagCodec.encodeRegisters(_t(TagDataType.int16), -2), [0xFFFE]);
    expect(TagCodec.decodeRegisters(_t(TagDataType.int32), [0xFFFF, 0xFFFF]), -1);
  });

  test('UINT16 com bytes trocados', () {
    expect(TagCodec.decodeRegisters(_t(TagDataType.uint16, ByteOrder.badc), [0x3412]), 0x1234);
  });

  test('bit dentro de registrador: leitura e leitura-modificação-escrita', () {
    const tag = Tag(id: 'b', name: 'Bit', deviceId: 'd', dataType: TagDataType.bool, bitIndex: 3, writable: true);
    expect(TagCodec.decodeRegisters(tag, [0x0008]), isTrue);
    expect(TagCodec.decodeRegisters(tag, [0x0007]), isFalse);
    expect(TagCodec.encodeBitIntoRegister(tag, 0x00F0, true), 0x00F8);
    expect(TagCodec.encodeBitIntoRegister(tag, 0x00F8, false), 0x00F0);
  });

  test('lista (memória inicial + tamanho) devolve todos os valores', () {
    const tag = Tag(id: 'l', name: 'Hora', deviceId: 'd', length: 4);
    expect(TagCodec.decodeRegisters(tag, [10, 20, 30, 40]), [10, 20, 30, 40]);
  });

  test('valor fora da faixa ou com vírgula em inteiro é recusado com mensagem clara', () {
    expect(() => TagCodec.encodeRegisters(_t(TagDataType.uint16), 70000),
        throwsA(isA<TagValueError>().having((e) => e.message, 'msg', contains('0 a 65535'))));
    expect(() => TagCodec.encodeRegisters(_t(TagDataType.uint16), 1.5), throwsA(isA<TagValueError>()));
  });

  test('entrada aceita vírgula brasileira', () {
    expect(TagCodec.parseInput(_t(TagDataType.float32), ' 12,75 '), 12.75);
    expect(() => TagCodec.parseInput(_t(TagDataType.float32), 'abc'), throwsA(isA<TagValueError>()));
  });

  test('formatação usa vírgula, casas decimais e unidade', () {
    const tag = Tag(id: 'f', name: 'Temp', deviceId: 'd', dataType: TagDataType.float32, decimals: 1, unit: '°C');
    expect(TagCodec.format(tag, 41.26), '41,3 °C');
    expect(TagCodec.format(tag, null), '---');
  });

  test('normalized() corrige combinações impossíveis', () {
    const t = Tag(id: 'x', name: 'x', deviceId: 'd', area: ModbusArea.discreteInput, dataType: TagDataType.uint16, writable: true);
    final n = t.normalized();
    expect(n.dataType, TagDataType.bool);
    expect(n.writable, isFalse);
  });
}
