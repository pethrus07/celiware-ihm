import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/models/calc.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/calc/calc_evaluator.dart';
import 'package:ihm/services/calc/calc_expression.dart';
import 'package:ihm/services/calc/calc_graph.dart';
import 'package:ihm/services/runtime/tag_store.dart';

/// A linguagem das calculadas (LG-1): precedência, erros com o trecho, nomes,
/// texto canônico, círculos, taxa de contador e a qualidade que passa da
/// entrada para a conta (LG-2).
void main() {
  final scope = CalcScope(const [
    CalcRef(id: 'vel', name: 'Velocidade', device: 'Cortadora'),
    CalcRef(id: 'faca', name: 'Velocidade da faca', device: 'Cortadora'),
    CalcRef(id: 'ciclo', name: 'Em ciclo', device: 'Cortadora', kind: CalcRefKind.boolean),
    CalcRef(id: 'nome', name: 'Nome da máquina', device: 'Cortadora', kind: CalcRefKind.text),
    CalcRef(id: 'hora', name: 'Produção por hora', device: 'Cortadora', kind: CalcRefKind.list),
    CalcRef(id: 'tc', name: 'Temperatura', device: 'Cortadora'),
    CalcRef(id: 'tp', name: 'Temperatura', device: 'Prensa'),
    CalcRef(id: 'pecas', name: 'Peças', device: 'Prensa'),
  ]);

  Object run(String src, [Map<String, Object> values = const {}]) => CalcProgram.compile(src, scope).run(_Values(values));

  CalcError err(String src) {
    try {
      CalcProgram.compile(src, scope);
    } on CalcError catch (e) {
      return e;
    }
    fail('"$src" deveria dar erro');
  }

  group('conta', () {
    test('precedência e associatividade', () {
      final table = <String, Object>{
        '2 + 3 * 4': 14.0,
        '(2 + 3) * 4': 20.0,
        '-2 * 3': -6.0,
        '2 - 3 - 4': -5.0,
        '8 / 2 / 2': 2.0,
        '10 / 4': 2.5,
        '1,5 * 2': 3.0,
        '1.5 * 2': 3.0,
        '2 × −3': -6.0,
        '10 ÷ 4': 2.5,
        '2 + 3 > 4': true,
        'não 2 > 3': true,
        '1 < 2 e 3 < 2 ou 1 = 1': true,
        'não falso e falso': false,
        'verdadeiro ou falso e falso': true,
        '0,1 + 0,2 = 0,3': true,
        '5 ≥ 5': true,
        '5 >= 6': false,
        '5 ≠ 4': true,
        '5 <> 5': false,
        '5 == 5': true,
        '4 <= 4': true,
        '- (2 + 3)': -5.0,
      };
      for (final e in table.entries) {
        expect(run(e.key), e.value, reason: e.key);
      }
    });

    test('funções: se, mín, máx, abs, arred', () {
      expect(run('se(1 > 2; 10; 20)'), 20.0);
      expect(run('se(verdadeiro; 10; 20)'), 10.0);
      expect(run('mín(3; 1; 2)'), 1.0);
      expect(run('MÁX(3; 1; 2)'), 3.0);
      expect(run('max(3; 1)'), 3.0, reason: 'sem acento também');
      expect(run('abs(-4)'), 4.0);
      expect(run('arred(2,5)'), 3.0);
      expect(run('arred(-2,5)'), -3.0);
      expect(run('arred(1,26; 1)'), 1.3);
      expect(run('arredondar(7,4)'), 7.0);
    });

    test('variáveis pelo nome: solto, entre colchetes, sem diferenciar maiúscula e acento', () {
      final v = {'vel': 80, 'ciclo': true, 'faca': 12, 'tp': 40};
      expect(run('Velocidade * 60', v), 4800.0);
      expect(run('[velocidade] * 60', v), 4800.0);
      expect(run('[Velocidade da faca] + 1', v), 13.0);
      expect(run('[Em ciclo] * [Velocidade]', v), 80.0, reason: 'liga/desliga entra como 1/0');
      expect(run('se([Em ciclo]; [Velocidade]; 0)', v), 80.0);
      expect(run('[Prensa: Temperatura] > 30', v), true);
      expect(run('[Em ciclo] = verdadeiro', v), true);
      expect(run('não [Em ciclo]', v), false);
    });

    test('o tipo do resultado sai da conta', () {
      CalcType type(String s) => CalcProgram.compile(s, scope).type;
      expect(type('[Velocidade] * 60'), CalcType.number);
      expect(type('[Velocidade] > 3'), CalcType.boolean);
      expect(type('[Em ciclo]'), CalcType.boolean);
      expect(type('[Em ciclo] e [Velocidade] > 0'), CalcType.boolean);
      expect(type('se([Em ciclo]; 1; 2)'), CalcType.number);
      expect(type('se([Em ciclo]; verdadeiro; [Velocidade] > 3)'), CalcType.boolean);
      expect(type('se([Em ciclo]; 1; falso)'), CalcType.number);
    });

    test('divisão por zero é erro na hora de calcular, nunca um número', () {
      expect(() => run('[Velocidade] / 0', {'vel': 3}), throwsA(isA<CalcRuntimeError>().having((e) => e.message, 'msg', 'divisão por zero')));
      expect(run('se([Velocidade] > 0; 10 / [Velocidade]; 0)', {'vel': 0}), 0.0, reason: 'o se só calcula o lado escolhido');
    });
  });

  group('erros apontam onde', () {
    void expectError(String src, String message, int start, int end) {
      final e = err(src);
      expect(e.message, message, reason: src);
      expect((e.start, e.end), (start, end), reason: '$src → "${e.message}"');
    }

    test('parêntese, colchete, conta vazia', () {
      expectError('([Velocidade] + 2', 'Falta fechar o parêntese', 0, 1);
      expectError('2 * (3 + (4', 'Falta fechar o parêntese', 9, 10);
      expectError(')', 'Parêntese fechado sem ter aberto', 0, 1);
      expectError('2 + 3)', 'Parêntese fechado sem ter aberto', 5, 6);
      expectError('()', 'Parênteses vazios: falta o valor dentro', 0, 2);
      expectError('[Velocidade * 2', 'Falta fechar o colchete: [Velocidade * 2]', 0, 15);
      expectError('', 'Escreva a conta', 0, 0);
      expectError('   ', 'Escreva a conta', 0, 0);
    });

    test('valor que falta, sinal que falta', () {
      expectError('2 + ', 'Falta um valor depois de "+"', 2, 3);
      expectError('2 + * 3', 'Falta um valor entre "+" e "×"', 2, 5);
      expectError('* 3', 'Falta um valor antes de "×"', 0, 1);
      expectError('2 3', 'Falta um sinal (+ − × ÷ = …) entre "2" e "3"', 2, 3);
      expectError('[Velocidade] [Em ciclo]', 'Falta um sinal (+ − × ÷ = …) entre "[Velocidade]" e "[Em ciclo]"', 13, 23);
      expectError('e 2', 'Falta um valor antes de "e"', 0, 1);
      expectError('1 > 2 e', 'Falta um valor depois de "e"', 6, 7);
      expectError('2 # 3', 'Não entendi "#" aqui', 2, 3);
    });

    test('variável que não existe, nome com espaço sem colchete, nome repetido', () {
      expectError('Temp * 2', 'Não existe variável "Temp"', 0, 4);
      expectError('2 + [Temp]', 'Não existe variável "Temp"', 4, 10);
      expectError('Velocidade da faca * 2', 'Nome com espaço vai entre colchetes: [Velocidade da faca]', 0, 18);
      expectError('[Temperatura] > 2', 'Há 2 variáveis "Temperatura" (Cortadora, Prensa): escreva [Cortadora: Temperatura]', 0, 13);
      expectError('[Nome da máquina] + 1', '"Nome da máquina" é texto: não entra em conta', 0, 17);
      expectError('[Produção por hora] * 2', '"Produção por hora" é uma lista: não entra em conta', 0, 19);
    });

    test('funções: desconhecida, partes erradas, vírgula no lugar de ponto e vírgula', () {
      expectError('raiz(2)', 'Não conheço a função "raiz". Use se, mín, máx, abs, arred ou taxa', 0, 4);
      expectError('se(1; 2)', 'se( ) tem 3 partes: se(condição; valor se sim; valor se não)', 0, 8);
      expectError('máx(1,5)', 'máx( ) compara 2 ou mais valores, separados por ";": máx(a; b)', 0, 8);
      expectError('máx([Velocidade], 2)', 'Separe os valores com ponto e vírgula (;), como em máx(a; b)', 16, 17);
      expectError('máx(1; 2', 'Falta fechar o parêntese de máx(', 3, 4);
      expectError('máx(1 2)', 'Falta ";" entre os valores de máx( ), ou ")" no fim', 6, 7);
      expectError('arred(2; 9)', 'As casas do arred( ) são um número de 0 a 6', 9, 10);
      expectError('taxa(2)', 'taxa( ) recebe uma variável contador, como em taxa([Rótulos cortados])', 0, 7);
      expectError('taxa([Em ciclo])', 'taxa( ) conta quanto um número sobe por hora: use com um contador, não com liga/desliga', 0, 16);
      expectError('2; 3', '";" só separa valores dentro de uma função, como em máx(a; b)', 1, 2);
    });

    test('comparação encadeada', () {
      expectError('1 < 2 < 3', 'Compare dois valores de cada vez: junte com "e", como em a < b e b < c', 6, 7);
    });
  });

  group('texto canônico e nomes', () {
    test('cada citação vira {id}; o texto canônico compila igual', () {
      final p = CalcProgram.compile('[Velocidade] * 60 + Peças', scope);
      expect(p.canonical, '{vel} * 60 + {pecas}');
      expect(p.spec.names, {'vel': 'Velocidade', 'pecas': 'Peças'});
      expect(p.inputIds, {'vel', 'pecas'});
      final again = CalcProgram.compile(p.canonical, scope);
      expect(again.run(_Values({'vel': 2, 'pecas': 1})), 121.0);
    });

    test('renomear não quebra a conta; apagar diz qual era', () {
      const dev = Device(id: 'd', name: 'Cortadora', host: 'x');
      const spec = CalcSpec(expression: '{vel} * 60', names: {'vel': 'Velocidade'});
      final renamed = Project(devices: const [dev], tags: const [Tag(id: 'vel', name: 'Vel. da linha', deviceId: 'd')]);
      expect(CalcGraph.display(spec, renamed), '[Vel. da linha] * 60');
      expect(CalcGraph.compile(spec, renamed).inputIds, {'vel'});

      const gone = Project(devices: [dev]);
      expect(CalcGraph.display(spec, gone), '[Velocidade] * 60');
      expect(() => CalcGraph.compile(spec, gone), throwsA(isA<CalcError>().having((e) => e.message, 'msg', 'A variável "Velocidade" foi apagada')));
    });

    test('nome repetido em dois equipamentos é citado com o equipamento', () {
      const p = Project(devices: [
        Device(id: 'a', name: 'Cortadora', host: 'x'),
        Device(id: 'b', name: 'Prensa', host: 'y'),
      ], tags: [
        Tag(id: 'ta', name: 'Temperatura', deviceId: 'a'),
        Tag(id: 'tb', name: 'Temperatura', deviceId: 'b'),
        Tag(id: 'v', name: 'Velocidade', deviceId: 'a'),
      ]);
      expect(CalcGraph.reference(p.tag('tb')!, p), '[Prensa: Temperatura]');
      expect(CalcGraph.reference(p.tag('v')!, p), '[Velocidade]');
      expect(CalcProgram.compile('[Prensa: Temperatura] - [Cortadora: Temperatura]', CalcGraph.scope(p)).inputIds, {'tb', 'ta'});
    });
  });

  group('círculo e ordem', () {
    Tag calc(String id, String name, String expr) =>
        Tag(id: id, name: name, deviceId: CalcDevice.id, dataType: TagDataType.float32, calc: CalcSpec(expression: expr));
    final project = Project(devices: const [Device(id: 'd', name: 'CLP', host: 'x'), CalcDevice.device], tags: [
      const Tag(id: 'x', name: 'X', deviceId: 'd'),
      calc('a', 'Eficiência', '{b} * 2'),
      calc('b', 'Meta', '{x} + 1'),
    ]);

    test('"A usa B que usa A" é recusado; a própria variável também', () {
      final newB = calc('b', 'Meta', '{a} / 2');
      final path = CalcGraph.cycle(project, newB)!;
      expect(path, ['b', 'a', 'b']);
      expect(CalcGraph.cycleMessage(project, newB, path), 'A conta fica em círculo: Meta → Eficiência → Meta');
      final self = calc('c', 'C', '{c} + 1');
      expect(CalcGraph.cycleMessage(project, self, CalcGraph.cycle(project, self)!), 'A conta não pode usar a própria variável');
      expect(CalcGraph.cycle(project, calc('c', 'C', '{a} + {b}')), isNull);
    });

    test('em uso: as entradas de qualquer profundidade; ordem de cálculo; equipamentos', () {
      expect(CalcGraph.expand(project, ['a']), {'a', 'b', 'x'});
      final (order, cyclic) = CalcGraph.order([project.tag('a')!, project.tag('b')!]);
      expect(order.map((t) => t.id), ['b', 'a']);
      expect(cyclic, isEmpty);
      expect(CalcGraph.devicesOf(project, project.tag('a')!), {'d'});
      final (_, loop) = CalcGraph.order([calc('p', 'P', '{q}'), calc('q', 'Q', '{p}')]);
      expect(loop, {'p', 'q'});
    });
  });

  group('taxa de contador', () {
    test('peças por hora numa janela; contador que zera recomeça; pouco histórico ainda não é taxa', () {
      final r = RateTracker();
      final t0 = DateTime(2026, 10, 11, 8);
      r.add(t0, 600);
      expect(r.perHour(), isNull);
      r.add(t0.add(const Duration(seconds: 5)), 605);
      expect(r.perHour(), isNull, reason: 'menos de 10 s');
      for (var s = 10; s <= 60; s += 10) {
        r.add(t0.add(Duration(seconds: s)), 600 + s.toDouble());
      }
      expect(r.perHour(), closeTo(3600, 1e-6), reason: '1 peça por segundo');
      r.add(t0.add(const Duration(seconds: 61)), 0); // troca de turno
      expect(r.perHour(), isNull);
      r.add(t0.add(const Duration(seconds: 81)), 10);
      expect(r.perHour(), closeTo(1800, 1e-6));
    });

    test('janela de 5 minutos: o começo sai', () {
      final r = RateTracker();
      final t0 = DateTime(2026);
      r.add(t0, 0);
      r.add(t0.add(const Duration(minutes: 1)), 1000); // arrancada no começo
      for (var m = 2; m <= 10; m++) {
        r.add(t0.add(Duration(minutes: m)), 1000 + (m - 1) * 10.0);
      }
      expect(r.perHour(), closeTo(600, 1e-6), reason: '10 por minuto nos últimos 5 min');
    });
  });

  group('qualidade das entradas (LG-2)', () {
    const dev = Device(id: 'd', name: 'Cortadora', host: 'x');
    const vel = Tag(id: 'vel', name: 'Velocidade', deviceId: 'd');
    const temp = Tag(id: 'temp', name: 'Temperatura', deviceId: 'd');
    const project = Project(devices: [dev], tags: [vel, temp]);
    final evaluator = CalcEvaluator(() => project);
    const spec = CalcSpec(expression: '{vel} * 2 + {temp}');
    TagReading good(Object v) => TagReading(value: v, quality: TagQuality.good, at: DateTime(2026));

    test('tudo bom: o valor; uma entrada sem comunicação: a conta também, com o último valor', () {
      var readings = {'vel': good(10), 'temp': good(5)};
      final ok = evaluator.evaluate('k', spec, (id) => readings[id]!);
      expect((ok.quality, ok.value), (TagQuality.good, 25.0));

      readings = {'vel': good(10).degrade(TagQuality.commLost, 'sem resposta'), 'temp': good(5)};
      final lost = evaluator.evaluate('k', spec, (id) => readings[id]!, previous: ok);
      expect(lost.quality, TagQuality.commLost);
      expect(lost.value, 25.0, reason: 'o último valor da conta, esmaecido — nunca uma conta com dado velho');
      expect(lost.message, 'sem comunicação com Cortadora');
    });

    test('entrada esperando → conta esperando; entrada com erro → conta com erro', () {
      final waiting = evaluator.evaluate('k', spec, (id) => id == 'vel' ? TagReading.waiting : good(1));
      expect(waiting.quality, TagQuality.waiting);
      expect(waiting.value, isNull);
      final broken = evaluator.evaluate('k', spec, (id) => id == 'temp' ? const TagReading(quality: TagQuality.addressError, message: 'endereço inexistente') : good(1));
      expect((broken.quality, broken.message), (TagQuality.configError, 'erro na entrada "Temperatura"'));
    });

    test('conta que não confere mais (variável apagada) e divisão por zero viram erro com o motivo', () {
      final gone = evaluator.evaluate('g', const CalcSpec(expression: '{sumiu} + 1', names: {'sumiu': 'Pressão'}), (_) => good(1));
      expect((gone.quality, gone.message), (TagQuality.configError, 'A variável "Pressão" foi apagada'));
      final div = evaluator.evaluate('z', const CalcSpec(expression: '{vel} / {temp}'), (id) => good(id == 'vel' ? 1 : 0));
      expect((div.quality, div.message), (TagQuality.configError, 'divisão por zero'));
    });
  });
}

class _Values implements CalcEnv {
  _Values(this.values);
  final Map<String, Object> values;

  @override
  Object? valueOf(String id) => values[id];

  @override
  double? perHour(String id) => null;
}
