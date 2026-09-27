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

  group('escala (valor = bruto × fator + soma)', () {
    const temp = Tag(id: 's', name: 'Temp', deviceId: 'd', scale: 0.1, unit: '°C', writable: true);

    test('÷10: lê 752 como 75,2 e grava 75,2 como 752', () {
      expect(TagCodec.decodeRegisters(temp, [752]), closeTo(75.2, 1e-9));
      expect(TagCodec.encodeRegisters(temp, 75.2), [752]); // 75,2 ÷ 0,1 = 751,999… → 752
    });

    test('casas decimais saem da escala quando ninguém pediu', () {
      expect(temp.displayDecimals, 1);
      expect(TagCodec.format(temp, 75.2), '75,2 °C');
      expect(const Tag(id: 'c', name: 'c', deviceId: 'd', scale: 0.01).displayDecimals, 2);
      expect(const Tag(id: 'c', name: 'c', deviceId: 'd', scale: 10).displayDecimals, 0);
    });

    test('mensagens falam na unidade da tela, não no número cru', () {
      expect(() => TagCodec.encodeRegisters(temp, 75.25),
          throwsA(isA<TagValueError>().having((e) => e.message, 'msg', contains('passos de 0,1'))));
      expect(() => TagCodec.encodeRegisters(temp, 7000),
          throwsA(isA<TagValueError>().having((e) => e.message, 'msg', contains('0,0 a 6553,5'))));
    });

    test('deslocamento: 4–20 mA em 0..1000 virando -50..150 °C', () {
      const t = Tag(id: 'o', name: 'Sonda', deviceId: 'd', scale: 0.2, offset: -50, writable: true);
      expect(TagCodec.decodeRegisters(t, [0]), closeTo(-50, 1e-9));
      expect(TagCodec.decodeRegisters(t, [1000]), closeTo(150, 1e-9));
      expect(TagCodec.encodeRegisters(t, 25), [375]);
    });

    test('lista escalada: cada valor passa pela conta', () {
      const t = Tag(id: 'l', name: 'Lista', deviceId: 'd', length: 3, scale: 0.5);
      expect(TagCodec.decodeRegisters(t, [2, 4, 6]), [1.0, 2.0, 3.0]);
    });

    test('JSON guarda a escala e arquivo sem escala continua igual', () {
      expect(Tag.fromJson(temp.toJson()).scale, 0.1);
      expect(const Tag(id: 'x', name: 'x', deviceId: 'd').toJson().containsKey('scale'), isFalse);
      expect(Tag.fromJson(const Tag(id: 'x', name: 'x', deviceId: 'd').toJson()).scale, 1);
    });

    test('escala zero é corrigida (apagaria o valor)', () {
      expect(const Tag(id: 'z', name: 'z', deviceId: 'd', scale: 0).normalized().scale, 1);
    });
  });

  group('texto ASCII', () {
    const name = Tag(id: 'n', name: 'Nome', deviceId: 'd', dataType: TagDataType.string, length: 4);

    test('2 letras por registrador, para no primeiro zero', () {
      // "CORT" "A" + zeros
      expect(TagCodec.decodeRegisters(name, [0x434F, 0x5254, 0x4100, 0x0000]), 'CORTA');
    });

    test('bytes trocados (byte baixo primeiro)', () {
      const t = Tag(id: 'n', name: 'Nome', deviceId: 'd', dataType: TagDataType.string, length: 2, byteOrder: ByteOrder.badc);
      expect(TagCodec.decodeRegisters(t, [0x4F43, 0x5452]), 'CORT');
    });

    test('é um valor só (não lista), ocupa length registradores e é só leitura', () {
      expect(name.isArray, isFalse);
      expect(name.span, 4);
      expect(name.addressLabel, 'HR 0..3');
      expect(name.copyWith(writable: true).normalized().writable, isFalse);
      expect(() => TagCodec.encodeRegisters(name, 1), throwsA(isA<TagValueError>()));
    });

    test('byte fora do ASCII visível vira "?" em vez de sumir', () {
      expect(TagCodec.decodeRegisters(name, [0x41FF, 0x4200, 0, 0]), 'A?B');
    });
  });

  test('normalized() corrige combinações impossíveis', () {
    const t = Tag(id: 'x', name: 'x', deviceId: 'd', area: ModbusArea.discreteInput, dataType: TagDataType.uint16, writable: true);
    final n = t.normalized();
    expect(n.dataType, TagDataType.bool);
    expect(n.writable, isFalse);
  });
}
