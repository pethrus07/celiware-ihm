// Histórico de aplicações de receita (RC-7): quem aplicou o quê, onde,
// quando e como terminou. É do aparelho, como o histórico de alarmes — fica
// ao lado do projeto e não vai na exportação.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import '../storage/project_repository.dart';
import 'recipe_applier.dart';

/// Uma linha do que mudou numa aplicação.
class RecipeChangeRecord {
  const RecipeChangeRecord({required this.name, required this.from, required this.to, required this.result});
  final String name;
  final String from;
  final String to;
  final String result;

  Map<String, dynamic> toJson() => {'name': name, 'from': from, 'to': to, 'result': result};

  factory RecipeChangeRecord.fromJson(Map<String, dynamic> j) => RecipeChangeRecord(
        name: j['name'] as String? ?? '',
        from: j['from'] as String? ?? '',
        to: j['to'] as String? ?? '',
        result: j['result'] as String? ?? '',
      );
}

/// Uma aplicação de receita, com o texto já pronto: o histórico precisa
/// continuar legível depois que a receita, a variável ou a máquina mudarem
/// de nome ou forem apagadas.
class RecipeApplyRecord {
  const RecipeApplyRecord({
    required this.at,
    required this.recipeId,
    required this.recipeName,
    required this.version,
    required this.typeName,
    required this.machineName,
    required this.outcome,
    required this.headline,
    this.operator = '',
    this.changes = const [],
  });

  final DateTime at;
  final String recipeId;
  final String recipeName;
  final int version;
  final String typeName;
  final String machineName;

  /// Quem aplicou (digitado na confirmação; vazio = não disse).
  final String operator;
  final RecipeOutcome outcome;
  final String headline;
  final List<RecipeChangeRecord> changes;

  factory RecipeApplyRecord.of(RecipeApplyResult r, {String operator = ''}) => RecipeApplyRecord(
        at: r.at,
        recipeId: r.plan.recipe.id,
        recipeName: r.plan.recipe.name,
        version: r.plan.recipe.version,
        typeName: r.plan.type.name,
        machineName: r.plan.device.name,
        operator: operator.trim(),
        outcome: r.outcome,
        headline: r.headline,
        changes: [
          for (final x in r.results)
            RecipeChangeRecord(
              name: x.item.param.name,
              // "?" = não deu para ler antes de gravar (como na confirmação).
              from: x.item.current == null ? '?' : x.item.param.format(x.item.current),
              to: x.item.param.format(x.item.target),
              result: x.label,
            ),
        ],
      );

  Map<String, dynamic> toJson() => {
        'at': at.toUtc().toIso8601String(),
        'recipeId': recipeId,
        'recipe': recipeName,
        'version': version,
        'type': typeName,
        'machine': machineName,
        if (operator.isNotEmpty) 'operator': operator,
        'outcome': outcome.name,
        'headline': headline,
        if (changes.isNotEmpty) 'changes': [for (final c in changes) c.toJson()],
      };

  static RecipeApplyRecord? fromJson(Map<String, dynamic> j) {
    final at = DateTime.tryParse(j['at'] as String? ?? '');
    // Resultado que esta versão não conhece (arquivo de uma mais nova): a
    // linha é pulada em vez de virar "aplicada".
    final outcome = RecipeOutcome.values.where((o) => o.name == j['outcome']).firstOrNull;
    if (at == null || outcome == null) return null;
    return RecipeApplyRecord(
      at: at,
      recipeId: j['recipeId'] as String? ?? '',
      recipeName: j['recipe'] as String? ?? '',
      version: (j['version'] as num?)?.toInt() ?? 1,
      typeName: j['type'] as String? ?? '',
      machineName: j['machine'] as String? ?? '',
      operator: j['operator'] as String? ?? '',
      outcome: outcome,
      headline: j['headline'] as String? ?? '',
      changes: [
        for (final c in (j['changes'] as List? ?? const []))
          if (c is Map) RecipeChangeRecord.fromJson(Map<String, dynamic>.from(c)),
      ],
    );
  }
}

/// Arquivo do histórico (`historico-receitas.json`, ao lado do projeto).
/// Sem estado na memória: cada tela lê quando abre, e acrescentar lê, junta
/// e grava de forma atômica — numa fila, para duas gravações não se cruzarem.
class RecipeHistoryStore {
  RecipeHistoryStore(this.file);

  factory RecipeHistoryStore.beside(ProjectRepository repository) => RecipeHistoryStore(() => repository.sidecar(fileName));

  static final Logger _log = Logger('RecipeHistory');
  static const fileName = 'historico-receitas.json';

  /// Aplicações guardadas (a mais antiga sai).
  static const limit = 200;

  final Future<File> Function() file;

  static Future<void> _queue = Future.value();

  /// Do mais novo para o mais antigo.
  Future<List<RecipeApplyRecord>> load() async => (await _read()).reversed.toList();

  /// Nome de quem aplicou por último neste aparelho (para já vir preenchido).
  Future<String> lastOperator() async {
    for (final r in (await _read()).reversed) {
      if (r.operator.isNotEmpty) return r.operator;
    }
    return '';
  }

  Future<void> add(RecipeApplyRecord record) {
    final next = _queue.then((_) async {
      final list = [...await _read(), record];
      if (list.length > limit) list.removeRange(0, list.length - limit);
      final f = await file();
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode([for (final r in list) r.toJson()]), flush: true);
      await tmp.rename(f.path);
    });
    _queue = next.catchError((Object e) => _log.warning('Não gravou o histórico de receitas: $e'));
    return _queue;
  }

  Future<List<RecipeApplyRecord>> _read() async {
    try {
      final f = await file();
      if (!await f.exists()) return [];
      final raw = jsonDecode(await f.readAsString());
      if (raw is! List) return [];
      return [
        for (final j in raw)
          if (j is Map) ?RecipeApplyRecord.fromJson(Map<String, dynamic>.from(j)),
      ];
    } catch (e) {
      _log.warning('Histórico de receitas ilegível, começando vazio: $e');
      return [];
    }
  }
}
