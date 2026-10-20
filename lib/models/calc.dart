// Variável calculada: o valor sai de uma conta com outras variáveis, de
// qualquer equipamento (REQUISITOS-ETAPA4 §9.5, LG-1 a LG-3).
//
// A conta mora na variável, como o tópico MQTT ([Tag.mqtt]): a variável
// calculada continua sendo uma variável — vai em qualquer elemento de tela,
// tem alarme, narração e registro —, só que ninguém a lê de um equipamento.
// Quem calcula é o `CalcDriver`, na sessão do equipamento virtual [CalcDevice].

import 'device.dart';

/// A conta de uma variável calculada (ou a condição de uma regra).
///
/// [expression] é o texto **canônico**: cada variável citada vira `{id}`.
/// Renomear a variável não quebra a conta — a tela mostra o nome de agora.
/// [names] guarda o nome de cada variável citada no dia em que a conta foi
/// salva, só para dizer qual era se ela for apagada depois ("a variável
/// 'Temperatura' foi apagada").
class CalcSpec {
  const CalcSpec({required this.expression, this.names = const {}});

  final String expression;
  final Map<String, String> names;

  /// `{id}` no texto canônico. Id do app não tem chave nem espaço.
  static final RegExp refPattern = RegExp(r'\{([^{}\s]+)\}');

  /// Ids das variáveis que a conta usa.
  Set<String> get inputIds => {for (final m in refPattern.allMatches(expression)) m.group(1)!};

  bool get isEmpty => expression.trim().isEmpty;

  /// A mesma conta com outro texto, e os nomes guardados com as chaves
  /// trocadas por [mapKey] (regras da planta: referência qualificada ⇄ id).
  CalcSpec copyWithExpression(String expression, String Function(String id) mapKey) =>
      CalcSpec(expression: expression, names: {for (final e in names.entries) mapKey(e.key): e.value});

  Map<String, dynamic> toJson() => {
        'expr': expression,
        if (names.isNotEmpty) 'names': names,
      };

  factory CalcSpec.fromJson(Map<String, dynamic> j) => CalcSpec(
        expression: (j['expr'] as String?) ?? '',
        names: {
          if (j['names'] is Map)
            for (final e in (j['names'] as Map).entries)
              if (e.value is String) '${e.key}': e.value as String,
        },
      );

  @override
  bool operator ==(Object other) =>
      other is CalcSpec &&
      other.expression == expression &&
      other.names.length == names.length &&
      other.names.entries.every((e) => names[e.key] == e.value);

  @override
  int get hashCode => Object.hash(expression, Object.hashAllUnordered(names.entries.map((e) => '${e.key}=${e.value}')));
}

/// O "equipamento" das variáveis calculadas.
///
/// Não fala com nada: existe para as calculadas terem um lugar no motor (uma
/// `DeviceSession` com o `CalcDriver`) e um grupo próprio na lista de
/// variáveis, no editor e nos registros. Nasce na primeira calculada salva e
/// não aparece em Equipamentos ([Project.equipment]).
class CalcDevice {
  CalcDevice._();

  static const id = 'calculos';

  /// Recalcula duas vezes por segundo mesmo sem entrada nova (a taxa de
  /// contador anda com o relógio; o registro de dados quer leitura fresca).
  static const device = Device(id: id, name: 'Cálculos', kind: DeviceKind.calc, pollMs: 500);
}
