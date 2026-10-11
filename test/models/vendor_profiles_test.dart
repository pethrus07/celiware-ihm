import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/models/vendor_profiles.dart';

const _coil = ModbusArea.coil;
const _di = ModbusArea.discreteInput;
const _hr = ModbusArea.holdingRegister;

/// Uma linha das tabelas do relatório (docs/pesquisa-etapa4/2-…): a memória
/// como no manual, a área Modbus e o endereço. Os números estão escritos à mão
/// a partir do relatório — não saem do perfil, senão o teste só repetiria o
/// código. [bit] escolhe entre contato e valor quando a letra é a mesma.
typedef _Row = (String memory, ModbusArea area, int address, {bool? bit});

_Row _r(String memory, ModbusArea area, int address, {bool? bit}) => (memory, area, address, bit: bit);

void _table(VendorProfile p, List<_Row> rows) {
  group(p.name, () {
    for (final (memory, area, address, :bit) in rows) {
      test('$memory → ${area.shortLabel} $address${bit == null ? '' : (bit ? ' (contato)' : ' (valor)')}', () {
        final ref = p.parse(memory, bit: bit);
        expect(ref.area, area);
        expect(ref.address, address);
        expect(ref.text, memory);
        // Caminho de volta: o endereço vira o mesmo texto do manual.
        expect(p.format(area, address), memory);
      });
    }
  });
}

void main() {
  group('tabelas (extremos de cada trecho)', () {
    _table(VendorProfiles.inovanceH3u, [
      _r('X0', _coil, 0xF800), _r('X377', _coil, 0xF800 + 255),
      _r('Y0', _coil, 0xFC00), _r('Y377', _coil, 0xFC00 + 255),
      _r('M0', _coil, 0), _r('M7679', _coil, 7679), _r('M8000', _coil, 0x1F40), _r('M8511', _coil, 8511),
      _r('SM0', _coil, 0x2400), _r('SM1023', _coil, 0x2400 + 1023),
      _r('S0', _coil, 0xE000), _r('S4095', _coil, 0xE000 + 4095),
      _r('T0', _coil, 0xF000, bit: true), _r('T511', _coil, 0xF000 + 511, bit: true),
      _r('C0', _coil, 0xF400, bit: true), _r('C255', _coil, 0xF400 + 255, bit: true),
      _r('D0', _hr, 0), _r('D8511', _hr, 8511),
      _r('SD0', _hr, 0x2400), _r('SD1023', _hr, 0x2400 + 1023),
      _r('R0', _hr, 0x3000), _r('R32767', _hr, 45055),
      _r('T0', _hr, 0xF000, bit: false), _r('T511', _hr, 0xF000 + 511, bit: false),
      _r('C0', _hr, 0xF400, bit: false), _r('C199', _hr, 0xF400 + 199, bit: false),
      // 0xF700 + 2·(n − 200)
      _r('C200', _hr, 0xF700, bit: false), _r('C255', _hr, 0xF700 + 110, bit: false),
    ]);

    _table(VendorProfiles.inovanceH5u, [
      _r('X0', _coil, 0xF800), _r('X1777', _coil, 0xF800 + 1023),
      _r('Y0', _coil, 0xFC00), _r('Y1777', _coil, 0xFFFF),
      _r('M0', _coil, 0), _r('M7999', _coil, 7999),
      _r('B0', _coil, 0x3000), _r('B32767', _coil, 0x3000 + 32767),
      _r('S0', _coil, 0xE000), _r('S4095', _coil, 0xE000 + 4095),
      _r('D0', _hr, 0), _r('D7999', _hr, 7999),
      _r('R0', _hr, 0x3000), _r('R32767', _hr, 0x3000 + 32767),
    ]);

    _table(VendorProfiles.invtIvc1, [
      _r('Y0', _coil, 0), _r('Y377', _coil, 255),
      _r('X0', _di, 0), _r('X377', _di, 255),
      _r('M0', _coil, 2000), _r('M2047', _coil, 4047), _r('M2048', _coil, 12000), _r('M10239', _coil, 20191),
      _r('SM0', _coil, 4400), _r('SM255', _coil, 4655), _r('SM256', _coil, 30000), _r('SM511', _coil, 30255),
      _r('S0', _coil, 6000), _r('S1023', _coil, 7023), _r('S1024', _coil, 31000), _r('S4095', _coil, 34071),
      _r('T0', _coil, 8000, bit: true), _r('T255', _coil, 8255, bit: true), _r('T256', _coil, 11000, bit: true), _r('T511', _coil, 11255, bit: true),
      _r('C0', _coil, 9200, bit: true), _r('C255', _coil, 9455, bit: true), _r('C256', _coil, 10000, bit: true), _r('C306', _coil, 10050, bit: true),
      _r('D0', _hr, 0), _r('D7999', _hr, 7999),
      _r('SD0', _hr, 8000), _r('SD255', _hr, 8255), _r('SD256', _hr, 12000), _r('SD511', _hr, 12255),
      _r('Z0', _hr, 8500), _r('Z15', _hr, 8515),
      _r('T0', _hr, 9000, bit: false), _r('T255', _hr, 9255, bit: false), _r('T256', _hr, 11000, bit: false), _r('T511', _hr, 11255, bit: false),
      _r('C0', _hr, 9500, bit: false), _r('C199', _hr, 9699, bit: false),
      // 32 bits: 2 registradores por contador (C255 ocupa 9810–9811; C306, 10100–10101).
      _r('C200', _hr, 9700, bit: false), _r('C255', _hr, 9810, bit: false), _r('C256', _hr, 10000, bit: false), _r('C306', _hr, 10100, bit: false),
      _r('R0', _hr, 13000), _r('R32767', _hr, 45767),
    ]);

    _table(VendorProfiles.invtIvc3, [
      _r('Y0', _coil, 0), _r('Y777', _coil, 511),
      _r('X0', _di, 0), _r('X777', _di, 511),
      _r('M0', _coil, 2000), _r('M10239', _coil, 20191),
      _r('SM0', _coil, 4400), _r('SM256', _coil, 30000), _r('SM1023', _coil, 30767),
      // O relatório diz "C256–C511 em 10000–10511": 256 contatos não ocupam 512
      // bits. Fica 1:1, como todo o resto da tabela — a conferir no manual.
      _r('C256', _coil, 10000, bit: true), _r('C511', _coil, 10255, bit: true),
      _r('SD256', _hr, 12000), _r('SD1023', _hr, 12767),
      _r('D0', _hr, 0), _r('R32767', _hr, 45767),
    ]);

    _table(VendorProfiles.wegTpw04, [
      _r('X0', _coil, 0x0000), _r('X377', _coil, 0x00FF),
      _r('Y0', _coil, 0x0100), _r('Y377', _coil, 0x01FF),
      _r('M0', _coil, 0x0200), _r('M1535', _coil, 0x07FF), _r('M1536', _coil, 0x1D00), _r('M7679', _coil, 0x34FF), _r('M8000', _coil, 0x0F00), _r('M8511', _coil, 0x10FF),
      _r('S0', _coil, 0x0800), _r('S1023', _coil, 0x0BFF), _r('S1024', _coil, 0x1100), _r('S4095', _coil, 0x1CFF),
      _r('T0', _coil, 0x0C00, bit: true), _r('T511', _coil, 0x0DFF, bit: true),
      _r('C0', _coil, 0x0E00, bit: true), _r('C255', _coil, 0x0EFF, bit: true), _r('C256', _coil, 0x3500, bit: true), _r('C511', _coil, 0x35FF, bit: true),
      _r('T0', _hr, 0x4000, bit: false), _r('T511', _hr, 0x41FF, bit: false),
      _r('C0', _hr, 0x4200, bit: false), _r('C199', _hr, 0x42C7, bit: false),
      _r('C200', _hr, 0x42C8, bit: false), _r('C255', _hr, 0x4336, bit: false), // 42C8–4337, 2 por contador
      _r('D0', _hr, 0x4338), _r('D8511', _hr, 0x6477), // 4338 + n, contínuo até o Z (6478)
      _r('W0', _hr, 0x8000), _r('W32767', _hr, 0xFFFF),
    ]);

    _table(VendorProfiles.deltaDvp, [
      _r('X0', _di, 0x0400), _r('X377', _di, 0x04FF),
      _r('Y0', _coil, 0x0500), _r('Y377', _coil, 0x05FF),
      _r('M0', _coil, 0x0800), _r('M1535', _coil, 0x0DFF), _r('M1536', _coil, 0xB000),
      _r('D0', _hr, 0x1000), _r('D4095', _hr, 0x1FFF), _r('D4096', _hr, 0x9000),
    ]);
  });

  group('regras do perfil', () {
    final plcs = VendorProfiles.all.where((p) => p.kind == ProfileKind.plc);

    test('X/Y em octal: X8 não existe, com as vizinhas certas — em toda família', () {
      for (final p in plcs) {
        expect(() => p.parse('X8'), throwsA(isA<MemoryError>().having((e) => e.message, 'mensagem', 'X8 não existe — X conta em octal: X7, X10')), reason: p.name);
        expect(() => p.parse('X18'), throwsA(isA<MemoryError>().having((e) => e.message, 'mensagem', contains('X17, X20'))), reason: p.name);
        expect(() => p.parse('Y80'), throwsA(isA<MemoryError>().having((e) => e.message, 'mensagem', contains('Y77, Y100'))), reason: p.name);
        expect(p.parse('X10').address - p.parse('X7').address, 1, reason: '${p.name}: X10 vem logo depois de X7');
      }
    });

    test('maior prefixo casa primeiro: SM antes de S, SD antes de D', () {
      const p = VendorProfiles.inovanceH3u;
      expect((p.parse('SM10').area, p.parse('SM10').address), (_coil, 0x2400 + 10));
      expect((p.parse('S10').area, p.parse('S10').address), (_coil, 0xE000 + 10));
      expect((p.parse('SD5').area, p.parse('SD5').address), (_hr, 0x2400 + 5));
      expect((p.parse('D5').area, p.parse('D5').address), (_hr, 5));
    });

    test('contador de 32 bits força INT32; o segundo registrador não é memória', () {
      const p = VendorProfiles.inovanceH3u;
      final c = p.parse('C200', bit: false);
      expect(c.forcedType, TagDataType.int32);
      expect(c.rule!.wordsPerItem, 2);
      expect(p.parse('C201', bit: false).address, 0xF702);
      expect(p.format(_hr, 0xF701), isNull);
      expect(p.parse('C10', bit: false).forcedType, isNull);
      expect(p.parse('M10').forcedType, TagDataType.bool);
    });

    test('sem dizer contato ou valor, a letra repetida usa a primeira área da tabela (o contato)', () {
      expect(VendorProfiles.inovanceH3u.parse('T5').area, _coil);
      // Número que só existe no valor de 32 bits.
      expect(VendorProfiles.invtIvc1.parse('C300', bit: false).address, 10000 + 2 * 44);
    });

    test('bit de registrador: D100.3', () {
      final r = VendorProfiles.inovanceH3u.parse('D100.3');
      expect((r.area, r.address, r.bit, r.forcedType, r.text), (_hr, 100, 3, TagDataType.bool, 'D100.3'));
      expect(VendorProfiles.inovanceH3u.format(_hr, 100, bit: 3), 'D100.3');
      expect(() => VendorProfiles.inovanceH3u.parse('M10.1'), throwsA(isA<MemoryError>().having((e) => e.message, 'm', contains('já é bit'))));
      expect(() => VendorProfiles.inovanceH3u.parse('D10.16'), throwsA(isA<MemoryError>().having((e) => e.message, 'm', contains('0 a 15'))));
    });

    test('memória fora da tabela diz até onde a área vai', () {
      expect(() => VendorProfiles.invtIvc1.parse('D9000'), throwsA(isA<MemoryError>().having((e) => e.message, 'm', 'D9000 não existe neste CLP: D vai de D0 a D7999.')));
      expect(() => VendorProfiles.inovanceH3u.parse('M7700'), throwsA(isA<MemoryError>().having((e) => e.message, 'm', contains('M0 a M7679 e de M8000 a M8511'))));
      // WEG: três trechos de endereço, mas a numeração só tem um buraco.
      expect(() => VendorProfiles.wegTpw04.parse('M7999'), throwsA(isA<MemoryError>().having((e) => e.message, 'm', contains('M0 a M7679 e de M8000 a M8511'))));
      expect(() => VendorProfiles.inovanceH3u.parse('X400'), throwsA(isA<MemoryError>().having((e) => e.message, 'm', contains('X0 a X377'))));
    });

    test('texto que não é memória ganha explicação', () {
      const p = VendorProfiles.inovanceH3u;
      expect(() => p.parse('Q1'), throwsA(isA<MemoryError>().having((e) => e.message, 'm', contains('não tem a área "Q"'))));
      expect(() => p.parse('D'), throwsA(isA<MemoryError>().having((e) => e.message, 'm', contains('Falta o número'))));
      expect(() => p.parse(''), throwsA(isA<MemoryError>()));
      expect(() => p.parse('123'), throwsA(isA<MemoryError>().having((e) => e.message, 'm', contains('Comece pela área'))));
      expect(p.tryParse('Q1'), isNull);
    });

    test('minúscula, espaço e zero à esquerda viram a forma do manual', () {
      expect(VendorProfiles.inovanceH3u.parse(' d 0200 ').text, 'D200');
      expect(VendorProfiles.inovanceH3u.parse('x10').address, 0xF800 + 8);
    });

    test('linha de prova do cadastro', () {
      expect(VendorProfiles.inovanceH3u.parse('D200').proof, 'D200 → Holding 200');
      expect(VendorProfiles.invtIvc1.parse('X10').proof, 'X10 → Entrada discreta 8');
      expect(VendorProfiles.inovanceH3u.parse('D100.3').proof, 'D100.3 → Holding 100, bit 3');
    });

    test('áreas da mesma família nunca se sobrepõem no mapa Modbus', () {
      for (final p in plcs) {
        final used = <ModbusArea, List<(int, int, String)>>{};
        for (final r in p.rules) {
          for (final s in r.segments) {
            final end = s.start + (s.last - s.first + 1) * r.wordsPerItem - 1;
            expect(end, lessThanOrEqualTo(65535), reason: '${p.name} ${r.chip}');
            for (final (a, b, who) in used[r.area] ?? const <(int, int, String)>[]) {
              expect(s.start > b || end < a, isTrue, reason: '${p.name}: ${r.chip} cruza com $who');
            }
            used.putIfAbsent(r.area, () => []).add((s.start, end, r.chip));
          }
        }
      }
    });

    test('entrada física exposta como coil nasce só leitura', () {
      expect(VendorProfiles.inovanceH3u.parse('X0').readOnly, isTrue);
      expect(VendorProfiles.wegTpw04.parse('X0').readOnly, isTrue);
      expect(VendorProfiles.invtIvc1.parse('X0').readOnly, isTrue); // entrada discreta
      expect(VendorProfiles.inovanceH3u.parse('Y0').readOnly, isFalse);
    });

    test('perfis de terceiros ficam marcados como não validados em bancada', () {
      for (final p in VendorProfiles.all) {
        if (p.origin == ProfileOrigin.thirdParty) expect(p.origin.caption, contains('não validado em bancada'), reason: p.name);
      }
      expect(VendorProfiles.inovanceH3u.origin, ProfileOrigin.thirdParty);
      expect(VendorProfiles.deltaDvp.origin, ProfileOrigin.thirdParty);
      expect(VendorProfiles.invtIvc1.origin, ProfileOrigin.official);
    });

    test('ids únicos e achados pelo id; id desconhecido = genérico', () {
      expect(VendorProfiles.all.map((p) => p.id).toSet(), hasLength(VendorProfiles.all.length));
      expect(VendorProfiles.byId('weg-tpw04'), same(VendorProfiles.wegTpw04));
      expect(VendorProfiles.byId(null), isNull);
      expect(VendorProfiles.byId('perfil-do-futuro'), isNull);
    });
  });

  group('notação de manual (MP-4)', () {
    test('só vale sem perfil', () {
      expect(VendorProfiles.manualNotationApplies(null), isTrue);
      expect(VendorProfiles.manualNotationApplies('inovance-h3u'), isFalse);
      expect(VendorProfiles.manualNotationApplies('invt-ivc1'), isFalse);
      expect(VendorProfiles.manualNotationApplies('perfil-do-futuro'), isTrue);
    });

    test('40201 é HR 200 no genérico; com perfil, R27913 (=40201) é legítimo e não vira sugestão', () {
      final generic = VendorProfiles.parseMemory('40201');
      expect((generic.area, generic.address, generic.raw), (_hr, 200, true));
      expect(VendorProfiles.parseMemory('10001').area, _di);
      expect(VendorProfiles.parseMemory('400001').address, 0);
      expect(() => VendorProfiles.parseMemory('40201', profile: VendorProfiles.inovanceH3u), throwsA(isA<MemoryError>()));
      expect(VendorProfiles.inovanceH3u.parse('R27913').address, 40201);
    });

    test('endereço Modbus direto vale com e sem perfil', () {
      for (final p in [null, VendorProfiles.inovanceH3u]) {
        final r = VendorProfiles.parseMemory('HR 200', profile: p);
        expect((r.area, r.address, r.raw), (_hr, 200, true));
      }
      expect(VendorProfiles.parseMemory('coil 5').area, _coil);
      expect(VendorProfiles.parseMemory('HR 0x2000').address, 0x2000);
      expect(VendorProfiles.parseMemory('HR 10.3').bit, 3);
      expect(() => VendorProfiles.parseMemory('HR 70000'), throwsA(isA<MemoryError>()));
    });
  });

  group('parâmetro de inversor (MP-5)', () {
    const md500 = ParameterRule(ParameterStyle.inovance);
    const gd20 = ParameterRule(ParameterStyle.invt);

    test('Inovance MD500: grupo no byte alto, número em hex no baixo', () {
      expect(md500.parse('F3-12').address, 0xF30C);
      expect(md500.parse('F0-02').address, 0xF002);
      expect(md500.parse('FD-00').address, 0xFD00);
      expect(md500.parse('A0-05').address, 0xA005);
      expect(md500.parse('B1-03').address, 0xB103);
      expect(md500.parse('U0-01').address, 0x7001);
      expect(md500.parse('f3-2').text, 'F3-02');
    });

    test('MD500 sem EEPROM: F vira 0 e A vira 4 no byte alto', () {
      expect(md500.parse('F3-12', noEeprom: true).address, 0x030C);
      expect(md500.parse('A0-05', noEeprom: true).address, 0x4005);
      expect(md500.parse('F3-12', noEeprom: true).text, 'F3-12 (RAM)');
      expect(md500.parse('F3-12 (RAM)').address, 0x030C);
      expect(() => md500.parse('B0-01', noEeprom: true), throwsA(isA<MemoryError>()));
      expect(() => md500.parse('U1-00'), throwsA(isA<MemoryError>()));
      expect(() => md500.parse('P05.05'), throwsA(isA<MemoryError>()));
    });

    test('MD500: endereço volta ao texto; registrador de comunicação não é parâmetro', () {
      expect(md500.format(0xF30C), 'F3-12');
      expect(md500.format(0xFD02), 'FD-02');
      expect(md500.format(0x030C), 'F3-12 (RAM)');
      expect(md500.format(0x7001), 'U0-01');
      for (final a in [0x1000, 0x2000, 0x3000, 0x8000]) {
        expect(md500.format(a), isNull, reason: a.toRadixString(16));
      }
    });

    test('INVT GD20: grupo e número em hex', () {
      expect(gd20.parse('P05.05').address, 0x0505);
      expect(gd20.parse('P10.01').address, 0x0A01);
      expect(gd20.parse('P00.01').address, 0x0001);
      expect(gd20.parse('P00.07', noEeprom: true).address, 0x8007);
      expect(gd20.format(0x0A01), 'P10.01');
      expect(gd20.format(0x8007), 'P00.07 (RAM)');
      expect(gd20.format(0x2000), isNull);
      expect(() => gd20.parse('P32.00'), throwsA(isA<MemoryError>()));
      expect(() => gd20.parse('F3-12'), throwsA(isA<MemoryError>()));
    });

    test('perfil de inversor lê parâmetro pelo parse do perfil', () {
      final r = VendorProfiles.inovanceMd500.parse('F0-02');
      expect((r.area, r.address, r.raw), (_hr, 0xF002, false));
      expect(VendorProfiles.inovanceMd500.format(_hr, 0xF002), 'F0-02');
      expect(VendorProfiles.invtGd20.parse('P14.00').address, 0x0E00);
    });

    test('modelos prontos com os endereços do manual', () {
      Map<String, (int, bool)> of(VendorProfile p) => {for (final t in p.templates) t.key: (t.address, t.writable)};
      expect(of(VendorProfiles.inovanceMd500), {'comando': (0x2000, true), 'referencia': (0x1000, true), 'estado': (0x3000, false), 'falha': (0x8000, false)});
      expect(of(VendorProfiles.invtGd20), {'comando': (0x2000, true), 'referencia': (0x2001, true), 'estado': (0x2100, false), 'falha': (0x2102, false)});
      // MD500: ±10000 = ±100,00 % → com sinal e ÷ 100.
      final ref = VendorProfiles.inovanceMd500.templates.firstWhere((t) => t.key == 'referencia').toTag(id: 'r', deviceId: 'd');
      expect((ref.dataType, ref.scale, ref.unit, ref.area), (TagDataType.int16, 0.01, '%', _hr));
    });
  });

  group('trocar de perfil (recalcular endereços)', () {
    test('a memória do manual é relida no perfil novo; o que ele não conhece fica', () {
      final tags = [
        const Tag(id: 'a', name: 'a', deviceId: 'd', address: 200, memory: 'D200'),
        const Tag(id: 'b', name: 'b', deviceId: 'd', area: _coil, address: 0x2400, dataType: TagDataType.bool, memory: 'SM0'),
        const Tag(id: 'c', name: 'c', deviceId: 'd', address: 7),
      ];
      final moved = VendorProfiles.remap(tags, VendorProfiles.wegTpw04);
      expect(moved, hasLength(1)); // TPW04 não tem SM; "c" não tem memória
      expect((moved.single.id, moved.single.address, moved.single.memory), ('a', 0x4338 + 200, 'D200'));
      expect(VendorProfiles.remap(tags, null), isEmpty);
      // Mesmo mapa (H3U → H3U): nada muda.
      expect(VendorProfiles.remap(tags, VendorProfiles.inovanceH3u), isEmpty);
    });
  });
}
