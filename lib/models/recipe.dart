// Receitas (REQUISITOS-ETAPA4 §9.3, RC-1 a RC-7): os ajustes de cada produto
// guardados no projeto e aplicados na máquina com uma confirmação.
//
// Vocabulário da ISA-88 trazido para o chão de fábrica:
//   • tipo de receita — quais parâmetros existem, com unidade, faixa e
//     tolerância ("Rótulo": velocidade e comprimento);
//   • receita — os valores de um produto ("Rótulo 120 mm": 80 m/min, 120 mm);
//   • máquina — o vínculo parâmetro → variável num equipamento. O mesmo tipo
//     vale em várias máquinas, cada uma com as suas variáveis: é isso que
//     deixa transferir uma receita para outra máquina compatível (RC-7).
//
// Mercado: Weintek (base de receitas), WinCC Unified (parameter sets),
// Sepasoft (comparar e conferir a carga) — docs/pesquisa-etapa4/4-…, seção 3.
//
// A receita **nunca é função de segurança**: a condição para aplicar é uma
// conferência do app, não um intertravamento — a segurança continua no CLP.

import 'dart:math' as math;

import 'project.dart';
import 'tag.dart';

/// Um parâmetro do tipo de receita. Imutável.
class RecipeParam {
  const RecipeParam({
    required this.key,
    required this.name,
    this.unit = '',
    this.decimals = 0,
    this.min,
    this.max,
    this.tolerance = 0,
    this.onOff = false,
  });

  /// Identificador estável: liga o valor da receita à variável de cada máquina.
  final String key;
  final String name;
  final String unit;

  /// Casas mostradas (vêm da variável; a escala já fez a conta).
  final int decimals;

  /// Faixa aceita na receita, na unidade de engenharia. Nulo = sem limite
  /// (vale só o que a variável aceita).
  final double? min;
  final double? max;

  /// Diferença que ainda conta como igual na comparação (RC-4). 0 = exato.
  final double tolerance;

  /// Liga/desliga: valor 1 ou 0, sem unidade, faixa nem tolerância.
  final bool onOff;

  /// Variável que pode entrar numa receita: gravável pela tela, de valor
  /// único, número ou liga/desliga (texto não é gravável nesta versão).
  static bool canUse(Tag t) => t.canWrite && !t.isText && !t.isArray;

  /// Variável que serve para **este** parâmetro (número com número,
  /// liga/desliga com liga/desliga).
  bool fits(Tag t) => canUse(t) && (t.dataType == TagDataType.bool) == onOff;

  factory RecipeParam.fromTag(String key, Tag t) => RecipeParam(
        key: key,
        name: t.name,
        unit: t.dataType == TagDataType.bool ? '' : t.unit,
        decimals: t.dataType == TagDataType.bool ? 0 : t.displayDecimals,
        onOff: t.dataType == TagDataType.bool,
      );

  /// Igual dentro da tolerância. Número com vírgula lido de um FLOAT32 nunca
  /// é exato (75,2 chega como 75,19999…): fora a tolerância, sobra uma folga
  /// do tamanho do erro do ponto flutuante — nunca para número inteiro, onde
  /// 1.000.000 e 1.000.001 têm de ser diferentes.
  bool same(double a, double b) {
    if (onOff) return (a != 0) == (b != 0);
    return (a - b).abs() <= tolerance + floatSlack(a, b);
  }

  /// Meio passo do FLOAT32 (2⁻²⁴ do valor, ≈ 6e-8): é o maior erro de guardar
  /// um decimal num FLOAT32. Mais que isso arredondaria valor de verdade
  /// (1.234.567,8 de um UINT32 com ÷10 viraria 1.234.568).
  static double floatSlack(double a, double b) {
    if (a == a.roundToDouble() && b == b.roundToDouble()) return 0;
    return 1e-9 + 6e-8 * math.max(a.abs(), b.abs());
  }

  /// Valor lido da máquina sem o ruído do FLOAT32: 75,19999694 numa variável
  /// de 1 casa vira 75,2 na receita. Valor que tem mais casas de verdade fica.
  double clean(double v) {
    if (onOff) return v != 0 ? 1 : 0;
    final d = _places(v, decimals);
    return d == null ? v : double.parse(v.toStringAsFixed(d));
  }

  /// Menos casas (a partir de [min]) que mostram [v] sem perder nada além do
  /// erro do FLOAT32. Nulo = nem 6 casas bastam.
  static int? _places(double v, int min) {
    for (var d = min.clamp(0, 6); d <= 6; d++) {
      if ((double.parse(v.toStringAsFixed(d)) - v).abs() <= 1e-9 + 6e-8 * v.abs()) return d;
    }
    return null;
  }

  /// "80 m/min", "75,2 °C", "LIGADO", "—".
  String format(double? v, {bool withUnit = true}) {
    if (v == null) return '—';
    if (onOff) return v != 0 ? 'LIGADO' : 'DESLIGADO';
    final text = number(v, decimals);
    return withUnit && unit.isNotEmpty ? '$text $unit' : text;
  }

  /// Número com vírgula brasileira. Mostra as casas da variável — e mais, se
  /// o valor tiver (75,25 numa variável de 1 casa não vira 75,3 calado).
  static String number(double v, int decimals) {
    if (v == 0) v = 0; // sem "-0"
    // A folga do FLOAT32: 75,19999 lido da máquina é o 75,2 da receita.
    final d = _places(v, decimals);
    if (d != null) return v.toStringAsFixed(d).replaceAll('.', ',');
    final long = v.toStringAsFixed(6).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    return long.replaceAll('.', ',');
  }

  /// "De 0 a 150 m/min · tolerância 0,5" — resumo da linha do parâmetro.
  String get limitsLabel {
    if (onOff) return 'Liga / desliga';
    final range = switch ((min, max)) {
      (null, null) => 'Sem faixa',
      (final a?, null) => 'A partir de ${format(a)}',
      (null, final b?) => 'Até ${format(b)}',
      (final a?, final b?) => 'De ${format(a, withUnit: false)} a ${format(b)}',
    };
    return tolerance > 0 ? '$range · tolerância ${number(tolerance, decimals)}' : range;
  }

  RecipeParam copyWith({String? name, String? unit, int? decimals, double? tolerance}) => RecipeParam(
        key: key,
        name: name ?? this.name,
        unit: unit ?? this.unit,
        decimals: decimals ?? this.decimals,
        min: min,
        max: max,
        tolerance: tolerance ?? this.tolerance,
        onOff: onOff,
      );

  /// Troca a faixa — inclusive para nula, o que o [copyWith] não consegue.
  RecipeParam withRange(double? min, double? max) => RecipeParam(
        key: key,
        name: name,
        unit: unit,
        decimals: decimals,
        min: min,
        max: max,
        tolerance: tolerance,
        onOff: onOff,
      );

  /// Corrige valores impossíveis (arquivo editado à mão ou antigo).
  RecipeParam normalized() {
    double? finite(double? v) => v != null && v.isFinite ? v : null;
    var lo = finite(min), hi = finite(max);
    if (lo != null && hi != null && lo > hi) (lo, hi) = (hi, lo);
    return RecipeParam(
      key: key,
      name: name.trim().isEmpty ? 'Parâmetro' : name.trim(),
      unit: onOff ? '' : unit.trim(),
      decimals: onOff ? 0 : decimals.clamp(0, 6),
      min: onOff ? null : lo,
      max: onOff ? null : hi,
      tolerance: !onOff && tolerance.isFinite && tolerance > 0 ? tolerance : 0,
      onOff: onOff,
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'name': name,
        if (unit.isNotEmpty) 'unit': unit,
        if (decimals != 0) 'decimals': decimals,
        if (min != null) 'min': min,
        if (max != null) 'max': max,
        if (tolerance != 0) 'tolerance': tolerance,
        if (onOff) 'onOff': true,
      };

  factory RecipeParam.fromJson(Map<String, dynamic> j) => RecipeParam(
        key: j['key'] as String? ?? '',
        name: j['name'] as String? ?? '',
        unit: j['unit'] as String? ?? '',
        decimals: (j['decimals'] as num?)?.toInt() ?? 0,
        min: (j['min'] as num?)?.toDouble(),
        max: (j['max'] as num?)?.toDouble(),
        tolerance: (j['tolerance'] as num?)?.toDouble() ?? 0,
        onOff: j['onOff'] as bool? ?? false,
      ).normalized();
}

/// Uma máquina onde o tipo de receita vale: qual variável recebe cada
/// parâmetro, a condição para aplicar (RC-6) e o bit de "receita carregada".
class RecipeMachine {
  const RecipeMachine({
    required this.deviceId,
    this.tags = const {},
    this.conditionTagId,
    this.conditionValue = false,
    this.loadedTagId,
  });

  final String deviceId;

  /// Chave do parâmetro → id da variável (deste equipamento).
  final Map<String, String> tags;

  /// "Só aplicar quando": variável liga/desliga que tem de valer
  /// [conditionValue] — "Em ciclo" desligado = só com a máquina parada.
  /// Conferência do app, não intertravamento.
  final String? conditionTagId;
  final bool conditionValue;

  /// Bit de "receita carregada": desligado no começo da aplicação e ligado
  /// só se tudo foi gravado e conferido.
  final String? loadedTagId;

  RecipeMachine withTags(Map<String, String> tags) =>
      RecipeMachine(deviceId: deviceId, tags: tags, conditionTagId: conditionTagId, conditionValue: conditionValue, loadedTagId: loadedTagId);

  RecipeMachine withCondition(String? tagId, bool value) =>
      RecipeMachine(deviceId: deviceId, tags: tags, conditionTagId: tagId, conditionValue: value, loadedTagId: loadedTagId);

  RecipeMachine withLoaded(String? tagId) =>
      RecipeMachine(deviceId: deviceId, tags: tags, conditionTagId: conditionTagId, conditionValue: conditionValue, loadedTagId: tagId);

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'tags': tags,
        if (conditionTagId != null) 'condition': {'tagId': conditionTagId, 'value': conditionValue},
        if (loadedTagId != null) 'loadedTagId': loadedTagId,
      };

  factory RecipeMachine.fromJson(Map<String, dynamic> j) {
    final cond = j['condition'] is Map ? Map<String, dynamic>.from(j['condition'] as Map) : const <String, dynamic>{};
    final tags = j['tags'] is Map ? Map<String, dynamic>.from(j['tags'] as Map) : const <String, dynamic>{};
    return RecipeMachine(
      deviceId: j['deviceId'] as String? ?? '',
      tags: {for (final e in tags.entries) if (e.value is String && (e.value as String).isNotEmpty) e.key: e.value as String},
      conditionTagId: cond['tagId'] as String?,
      conditionValue: cond['value'] as bool? ?? false,
      loadedTagId: j['loadedTagId'] as String?,
    );
  }
}

/// Tipo de receita (RC-1): os parâmetros e as máquinas onde vale. Imutável.
class RecipeType {
  const RecipeType({required this.id, this.name = 'Receita', this.params = const [], this.machines = const []});

  final String id;
  final String name;
  final List<RecipeParam> params;
  final List<RecipeMachine> machines;

  RecipeParam? param(String key) => params.where((p) => p.key == key).firstOrNull;
  RecipeMachine? machine(String deviceId) => machines.where((m) => m.deviceId == deviceId).firstOrNull;

  RecipeType copyWith({String? name, List<RecipeParam>? params, List<RecipeMachine>? machines}) =>
      RecipeType(id: id, name: name ?? this.name, params: params ?? this.params, machines: machines ?? this.machines);

  RecipeType upsertParam(RecipeParam p) {
    final i = params.indexWhere((x) => x.key == p.key);
    return copyWith(params: i < 0 ? [...params, p] : ([...params]..[i] = p));
  }

  /// Tira o parâmetro e o vínculo dele em todas as máquinas. O valor que as
  /// receitas guardavam fica no arquivo, sem uso (volta se o parâmetro voltar).
  RecipeType removeParam(String key) => copyWith(
        params: params.where((p) => p.key != key).toList(),
        machines: [for (final m in machines) m.withTags({...m.tags}..remove(key))],
      );

  RecipeType upsertMachine(RecipeMachine m) {
    final i = machines.indexWhere((x) => x.deviceId == m.deviceId);
    return copyWith(machines: i < 0 ? [...machines, m] : ([...machines]..[i] = m));
  }

  RecipeType removeMachine(String deviceId) => copyWith(machines: machines.where((m) => m.deviceId != deviceId).toList());

  RecipeType normalized() {
    final seen = <String>{};
    final ps = [
      for (final p in params)
        if (p.key.isNotEmpty && seen.add(p.key)) p.normalized(),
    ];
    final devices = <String>{};
    final ms = [
      for (final m in machines)
        if (m.deviceId.isNotEmpty && devices.add(m.deviceId)) m.withTags({for (final e in m.tags.entries) if (seen.contains(e.key)) e.key: e.value}),
    ];
    return RecipeType(id: id, name: name.trim().isEmpty ? 'Receita' : name.trim(), params: ps, machines: ms);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'params': [for (final p in params) p.toJson()],
        'machines': [for (final m in machines) m.toJson()],
      };

  factory RecipeType.fromJson(Map<String, dynamic> j) => RecipeType(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        params: [
          for (final p in (j['params'] as List? ?? const []))
            if (p is Map) RecipeParam.fromJson(Map<String, dynamic>.from(p)),
        ],
        machines: [
          for (final m in (j['machines'] as List? ?? const []))
            if (m is Map) RecipeMachine.fromJson(Map<String, dynamic>.from(m)),
        ],
      ).normalized();
}

/// Uma versão guardada dos valores de uma receita (RC-7).
class RecipeVersion {
  const RecipeVersion({required this.version, required this.values, this.at, this.note = ''});

  final int version;
  final Map<String, double> values;
  final DateTime? at;

  /// O que criou a versão: "Lida da máquina", "Valores editados"…
  final String note;

  Map<String, dynamic> toJson() => {
        'version': version,
        if (at != null) 'at': at!.toUtc().toIso8601String(),
        if (note.isNotEmpty) 'note': note,
        'values': values,
      };

  factory RecipeVersion.fromJson(Map<String, dynamic> j) => RecipeVersion(
        version: (j['version'] as num?)?.toInt() ?? 1,
        at: DateTime.tryParse(j['at'] as String? ?? ''),
        note: j['note'] as String? ?? '',
        values: Recipe.valuesFromJson(j['values']),
      );
}

/// Uma receita: os valores de um produto, por parâmetro do tipo. Imutável.
class Recipe {
  const Recipe({
    required this.id,
    required this.typeId,
    this.name = 'Receita',
    this.values = const {},
    this.version = 1,
    this.updatedAt,
    this.note = '',
    this.history = const [],
  });

  /// Versões guardadas de cada receita, contando a atual.
  static const maxVersions = 10;

  /// Edições à mão dentro deste tempo viram **uma** versão: ajustar três
  /// valores seguidos não pode empurrar para fora as versões que importam.
  static const editWindow = Duration(minutes: 10);

  static const noteCreated = 'Criada';
  static const noteRead = 'Lida da máquina';
  static const noteEdited = 'Valores editados';

  final String id;
  final String typeId;
  final String name;

  /// Chave do parâmetro → valor na unidade de engenharia (liga/desliga: 1/0).
  final Map<String, double> values;
  final int version;
  final DateTime? updatedAt;
  final String note;

  /// Versões anteriores, da mais antiga para a mais nova (até [maxVersions] − 1).
  final List<RecipeVersion> history;

  RecipeVersion get current => RecipeVersion(version: version, values: values, at: updatedAt, note: note);

  /// Todas as versões guardadas, a atual primeiro.
  List<RecipeVersion> get versions => [current, ...history.reversed];

  Recipe copyWith({String? name}) => Recipe(
        id: id,
        typeId: typeId,
        name: name ?? this.name,
        values: values,
        version: version,
        updatedAt: updatedAt,
        note: note,
        history: history,
      );

  /// Valores novos. Mudou alguma coisa → versão nova, e a atual vai para o
  /// histórico (só as últimas [maxVersions] ficam). Igual → a mesma receita.
  /// Receita ainda vazia só se preenche (não há o que guardar). Com
  /// [coalesce], edições à mão seguidas ficam na mesma versão.
  Recipe revise(Map<String, double> next, {required String note, required DateTime at, bool coalesce = false}) {
    if (sameValues(values, next)) return this;
    Recipe keep({required int version, required List<RecipeVersion> history}) =>
        Recipe(id: id, typeId: typeId, name: name, values: Map.unmodifiable(next), version: version, updatedAt: at, note: note, history: history);
    if (values.isEmpty) return keep(version: version, history: history);
    final last = updatedAt;
    if (coalesce && note == this.note && last != null && !at.isBefore(last) && at.difference(last) < editWindow) {
      return keep(version: version, history: history);
    }
    final older = [...history, current];
    return keep(version: version + 1, history: older.sublist(math.max(0, older.length - (maxVersions - 1))));
  }

  /// Volta aos valores de uma versão antiga — como versão nova, sem apagar
  /// nada: restaurar errado também se desfaz.
  Recipe restore(RecipeVersion v, {required DateTime at}) => revise(v.values, note: 'Restaurada da versão ${v.version}', at: at);

  Recipe duplicate({required String id, required String name, required DateTime at}) => Recipe(
        id: id,
        typeId: typeId,
        name: name,
        values: values,
        updatedAt: at,
        note: 'Cópia de "${this.name}" (versão $version)',
      );

  static bool sameValues(Map<String, double> a, Map<String, double> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  Recipe normalized() {
    final v = version < 1 ? 1 : version;
    final older = [...history.where((h) => h.version < v)]..sort((a, b) => a.version.compareTo(b.version));
    return Recipe(
      id: id,
      typeId: typeId,
      name: name.trim().isEmpty ? 'Receita' : name.trim(),
      values: {for (final e in values.entries) if (e.value.isFinite) e.key: e.value},
      version: v,
      updatedAt: updatedAt,
      note: note,
      history: older.sublist(math.max(0, older.length - (maxVersions - 1))),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'typeId': typeId,
        'name': name,
        'values': values,
        'version': version,
        if (updatedAt != null) 'updatedAt': updatedAt!.toUtc().toIso8601String(),
        if (note.isNotEmpty) 'note': note,
        if (history.isNotEmpty) 'history': [for (final h in history) h.toJson()],
      };

  factory Recipe.fromJson(Map<String, dynamic> j) => Recipe(
        id: j['id'] as String? ?? '',
        typeId: j['typeId'] as String? ?? '',
        name: j['name'] as String? ?? '',
        values: valuesFromJson(j['values']),
        version: (j['version'] as num?)?.toInt() ?? 1,
        updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
        note: j['note'] as String? ?? '',
        history: [
          for (final h in (j['history'] as List? ?? const []))
            if (h is Map) RecipeVersion.fromJson(Map<String, dynamic>.from(h)),
        ],
      ).normalized();

  static Map<String, double> valuesFromJson(Object? raw) => raw is Map
      ? {
          for (final e in raw.entries)
            if (e.key is String && e.value is num && (e.value as num).isFinite) e.key as String: (e.value as num).toDouble(),
        }
      : const {};
}

/// Receitas dentro do projeto. Ficam aqui (e não em `project.dart`) para o
/// arquivo compartilhado do projeto mudar o mínimo.
extension ProjectRecipes on Project {
  RecipeType? recipeType(String id) => recipeTypes.where((t) => t.id == id).firstOrNull;
  Recipe? recipe(String id) => recipes.where((r) => r.id == id).firstOrNull;
  List<Recipe> recipesOf(String typeId) => recipes.where((r) => r.typeId == typeId).toList();

  Project upsertRecipeType(RecipeType t) {
    final n = t.normalized();
    final i = recipeTypes.indexWhere((x) => x.id == n.id);
    return copyWith(recipeTypes: i < 0 ? [...recipeTypes, n] : ([...recipeTypes]..[i] = n));
  }

  /// Apaga o tipo **e** as receitas dele.
  Project removeRecipeType(String id) => copyWith(
        recipeTypes: recipeTypes.where((t) => t.id != id).toList(),
        recipes: recipes.where((r) => r.typeId != id).toList(),
      );

  Project upsertRecipe(Recipe r) {
    final n = r.normalized();
    final i = recipes.indexWhere((x) => x.id == n.id);
    return copyWith(recipes: i < 0 ? [...recipes, n] : ([...recipes]..[i] = n));
  }

  Project removeRecipe(String id) => copyWith(recipes: recipes.where((r) => r.id != id).toList());
}
