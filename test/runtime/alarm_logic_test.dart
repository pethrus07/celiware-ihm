import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/models/alarm.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/alarms/alarm_engine.dart';

void main() {
  const alta = AlarmRule(id: 'a', kind: AlarmKind.above, limit: 85, priority: AlarmPriority.high);
  const baixa = AlarmRule(id: 'b', kind: AlarmKind.below, limit: 20, priority: AlarmPriority.low);

  group('condição com banda morta (anti "alarme tagarela")', () {
    test('acima de 85: dispara acima e só normaliza abaixo de 84,15', () {
      expect(AlarmLogic.condition(alta, 85.0, wasActive: false), isFalse); // no limite, não
      expect(AlarmLogic.condition(alta, 85.1, wasActive: false), isTrue);
      expect(AlarmLogic.condition(alta, 84.5, wasActive: true), isTrue); // oscilou: segue ativo
      expect(AlarmLogic.condition(alta, 84.0, wasActive: true), isFalse); // passou da banda: normaliza
    });

    test('abaixo de 20: simétrico', () {
      expect(AlarmLogic.condition(baixa, 19.9, wasActive: false), isTrue);
      expect(AlarmLogic.condition(baixa, 20.1, wasActive: true), isTrue);
      expect(AlarmLogic.condition(baixa, 20.3, wasActive: true), isFalse);
    });

    test('liga/desliga e valor que não é número', () {
      const on = AlarmRule(id: 'c', kind: AlarmKind.on);
      const off = AlarmRule(id: 'd', kind: AlarmKind.off);
      expect(AlarmLogic.condition(on, true, wasActive: false), isTrue);
      expect(AlarmLogic.condition(off, false, wasActive: false), isTrue);
      expect(AlarmLogic.condition(on, null, wasActive: false), isFalse);
      expect(AlarmLogic.condition(alta, null, wasActive: true), isFalse);
    });
  });

  test('mensagem padrão usa nome, unidade e escala da variável', () {
    const t = Tag(id: 't', name: 'Temperatura', deviceId: 'd', dataType: TagDataType.float32, unit: '°C', decimals: 1);
    expect(AlarmLogic.defaultMessage(t, alta), 'Temperatura acima de 85,0 °C');
  });

  test('alarmes vão para o arquivo e voltam; arquivo sem alarme continua igual', () {
    const t = Tag(id: 't', name: 'T', deviceId: 'd', alarms: [alta, baixa]);
    final back = Tag.fromJson(t.toJson());
    expect(back.alarms.map((a) => (a.id, a.kind, a.limit, a.priority)), [
      ('a', AlarmKind.above, 85.0, AlarmPriority.high),
      ('b', AlarmKind.below, 20.0, AlarmPriority.low),
    ]);
    expect(const Tag(id: 'x', name: 'x', deviceId: 'd').toJson().containsKey('alarms'), isFalse);
  });

  test('alarme incompatível com o tipo é descartado (limite em liga/desliga, texto)', () {
    const bit = Tag(id: 'b', name: 'B', deviceId: 'd', dataType: TagDataType.bool, alarms: [alta, AlarmRule(id: 'on', kind: AlarmKind.on)]);
    expect(bit.normalized().alarms.map((a) => a.id), ['on']);
    const txt = Tag(id: 's', name: 'S', deviceId: 'd', dataType: TagDataType.string, length: 4, alarms: [alta]);
    expect(txt.normalized().alarms, isEmpty);
  });

  test('prioridade: número, rótulo e ordem de urgência', () {
    expect(AlarmPriority.values.map((p) => '${p.number} ${p.label}'), ['1 Alta', '2 Média', '3 Baixa']);
  });
}
