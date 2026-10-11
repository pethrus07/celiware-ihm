// Ler da máquina, preparar e aplicar uma receita (RC-3, RC-5, RC-6) pelo
// caminho de produção: `HmiRuntime.readNow` e `HmiRuntime.write`, as mesmas
// leitura avulsa e escrita dos elementos de tela.
//
// Aplicar é ação séria. A sequência:
//   1. preparar: lê tudo, monta a lista "de → para" e o que impede aplicar;
//   2. (a tela pede UMA confirmação);
//   3. confere a condição de novo — a máquina pode ter partido nesse meio
//      tempo — e desliga o bit de "receita carregada";
//   4. grava parâmetro por parâmetro, só o que difere; na primeira falha,
//      para: o resto fica "não gravado", nunca tentado no escuro;
//   5. relê cada valor gravado e confere a tolerância (o CLP pode ter
//      limitado o valor);
//   6. liga o bit de "receita carregada" só se tudo foi gravado e conferido.
// O resultado diz o que gravou, o que falhou e por quê — falha pela metade
// nunca passa calada. Não há "desfazer" automático: voltar atrás também
// grava e também pode falhar; o relatório mostra o estado de verdade.

import 'package:clock/clock.dart';

import '../../core/comm/comm_error.dart';
import '../../core/modbus/modbus_exception.dart';
import '../../models/device.dart';
import '../../models/recipe.dart';
import '../../models/tag.dart';
import '../runtime/hmi_runtime.dart';
import '../runtime/tag_codec.dart';
import 'recipe_logic.dart';

/// Um parâmetro na lista "de → para".
class RecipePlanItem {
  const RecipePlanItem({required this.param, required this.tag, required this.target, this.current, this.readProblem});
  final RecipeParam param;
  final Tag tag;

  /// Valor da receita.
  final double target;

  /// Valor lido agora (nulo = não deu para ler).
  final double? current;
  final String? readProblem;

  /// Vai ser gravado: difere além da tolerância, ou não deu para ler.
  bool get changes {
    final c = current;
    return c == null || !param.same(c, target);
  }
}

/// A condição para aplicar ("só com a máquina parada") e como ela está.
class RecipeCondition {
  const RecipeCondition({required this.tag, required this.expected, this.actual, this.problem});
  final Tag tag;
  final bool expected;
  final bool? actual;

  /// Não deu para ler a variável da condição.
  final String? problem;

  bool get ok => problem == null && actual == expected;

  /// "Em ciclo" DESLIGADO.
  String get wanted => '"${tag.name}" ${expected ? 'LIGADO' : 'DESLIGADO'}';
}

/// Tudo o que a confirmação precisa mostrar — e o que impede aplicar.
class RecipePlan {
  const RecipePlan({
    required this.type,
    required this.machine,
    required this.recipe,
    required this.device,
    this.items = const [],
    this.blockers = const [],
    this.condition,
    this.loadedTag,
  });

  final RecipeType type;
  final RecipeMachine machine;
  final Recipe recipe;
  final Device device;

  /// Todos os parâmetros, na ordem do tipo.
  final List<RecipePlanItem> items;

  /// Motivos que impedem aplicar (o botão nem aparece).
  final List<String> blockers;
  final RecipeCondition? condition;
  final Tag? loadedTag;

  bool get canApply => blockers.isEmpty;

  /// O que vai ser gravado, na ordem.
  List<RecipePlanItem> get writes => items.where((i) => i.changes).toList();
}

/// Como terminou cada parâmetro.
enum RecipeItemOutcome {
  /// Gravado, relido e dentro da tolerância.
  verified,

  /// Gravado, mas a máquina ficou com outro valor (o CLP limitou?).
  divergent,

  /// Gravado; a releitura não foi possível.
  unverified,

  /// O equipamento (ou o app) recusou o valor.
  refused,

  /// Sem comunicação: não se sabe se chegou.
  commLost,

  /// A aplicação parou antes dele.
  notTried,
}

class RecipeItemResult {
  const RecipeItemResult({required this.item, required this.outcome, this.message = '', this.readBack});
  final RecipePlanItem item;
  final RecipeItemOutcome outcome;
  final String message;

  /// O que se releu depois de gravar.
  final double? readBack;

  bool get written => outcome == RecipeItemOutcome.verified || outcome == RecipeItemOutcome.divergent || outcome == RecipeItemOutcome.unverified;

  /// Frase curta para o relatório e o histórico.
  String get label {
    final p = item.param;
    return switch (outcome) {
      RecipeItemOutcome.verified => 'Gravado e conferido',
      RecipeItemOutcome.divergent => 'Gravou ${p.format(item.target)}, a máquina ficou com ${p.format(readBack)}',
      RecipeItemOutcome.unverified => 'Gravado, sem conferência: $message',
      RecipeItemOutcome.refused => 'Recusado: $message',
      RecipeItemOutcome.commLost => 'Sem comunicação: $message',
      RecipeItemOutcome.notTried => 'Não gravado: a aplicação parou antes',
    };
  }
}

/// Como terminou a aplicação inteira.
enum RecipeOutcome {
  /// Tudo gravado e conferido.
  applied,

  /// Tudo gravado, mas algum valor divergiu ou não foi conferido.
  divergent,

  /// Parou no meio: parte gravou, parte não.
  partial,

  /// Nada foi gravado.
  notApplied,
}

class RecipeApplyResult {
  const RecipeApplyResult({
    required this.plan,
    required this.results,
    required this.outcome,
    required this.at,
    this.reason,
    this.loadedSet = false,
    this.loadedProblem,
  });

  final RecipePlan plan;
  final List<RecipeItemResult> results;
  final RecipeOutcome outcome;
  final DateTime at;

  /// Por que parou ou não aplicou.
  final String? reason;

  /// O bit de "receita carregada" foi ligado.
  final bool loadedSet;
  final String? loadedProblem;

  int get writtenCount => results.where((r) => r.written).length;
  int get troubleCount => results.where((r) => r.outcome == RecipeItemOutcome.divergent || r.outcome == RecipeItemOutcome.unverified).length;

  /// A frase de cima do relatório.
  String get headline {
    final n = results.length;
    switch (outcome) {
      case RecipeOutcome.applied:
        return n == 0 ? 'Receita confirmada: nada precisou mudar' : 'Receita aplicada';
      case RecipeOutcome.divergent:
        final div = results.where((r) => r.outcome == RecipeItemOutcome.divergent).length;
        if (div > 0) return 'Aplicada com ${div == 1 ? '1 divergência' : '$div divergências'}';
        if (troubleCount > 0) return 'Aplicada, mas ${troubleCount == 1 ? '1 valor não foi conferido' : '$troubleCount valores não foram conferidos'}';
        return 'Aplicada, mas ${reason ?? 'algo não conferiu'}';
      case RecipeOutcome.partial:
        final stop = results.indexWhere((r) => !r.written) + 1;
        return 'Parou no $stopº de $n valores: $reason';
      case RecipeOutcome.notApplied:
        return 'Não aplicada: $reason';
    }
  }
}

/// Lê, prepara e aplica receitas pelo [HmiRuntime].
class RecipeApplier {
  RecipeApplier(this.runtime, {this.verifyDelay = const Duration(milliseconds: 300)});

  final HmiRuntime runtime;

  /// Espera antes de reler: o CLP limita o valor na varredura seguinte.
  final Duration verifyDelay;

  /// Recusa do equipamento (endereço inexistente, valor inválido) — diferente
  /// de falta de comunicação.
  static bool isRefusal(CommError e) => e is ModbusExceptionResponse || e is ModbusRequestError;

  /// Lê da máquina os parâmetros ligados (RC-3, RC-4). Um por vez, pela
  /// conexão da sessão. Sem comunicação, para na hora: as outras leituras
  /// só esperariam o mesmo tempo esgotado.
  Future<MachineSnapshot> read(RecipeType type, RecipeMachine machine) async {
    final project = runtime.project;
    final values = <String, double>{};
    final problems = <String, String>{};
    for (final p in type.params) {
      final id = machine.tags[p.key];
      final tag = id == null ? null : project.tag(id);
      if (tag == null || tag.deviceId != machine.deviceId) {
        problems[p.key] = 'sem variável nesta máquina';
        continue;
      }
      try {
        final n = RecipeLogic.asNumber(await runtime.readNow(tag));
        if (n == null) {
          problems[p.key] = 'o valor lido não é número';
        } else {
          values[p.key] = n;
        }
      } on TagValueError catch (e) {
        problems[p.key] = e.message;
      } on CommError catch (e) {
        if (!isRefusal(e)) return MachineSnapshot(values: values, problems: problems, commError: e.userMessage);
        problems[p.key] = e.userMessage;
      }
    }
    return MachineSnapshot(values: values, problems: problems);
  }

  /// Monta a confirmação: lê tudo e junta o que impede aplicar.
  Future<RecipePlan> prepare({required RecipeType type, required RecipeMachine machine, required Recipe recipe}) async {
    final project = runtime.project;
    final device = project.device(machine.deviceId) ?? Device(id: machine.deviceId, name: 'Máquina apagada');
    final problems = RecipeLogic.machineProblems(type, machine, project);
    if (problems.isNotEmpty) return RecipePlan(type: type, machine: machine, recipe: recipe, device: device, blockers: problems);

    final blockers = <String>[];
    for (final p in type.params) {
      final v = recipe.values[p.key];
      if (v == null) {
        blockers.add('A receita não tem valor para "${p.name}"');
        continue;
      }
      final problem = RecipeLogic.valueProblem(p, v, tag: project.tag(machine.tags[p.key]!));
      if (problem != null) blockers.add(problem);
    }
    if (blockers.isNotEmpty) return RecipePlan(type: type, machine: machine, recipe: recipe, device: device, blockers: blockers);

    final snap = await read(type, machine);
    if (!snap.ok) blockers.add('Sem comunicação com ${device.name}: ${snap.commError}');
    final items = [
      for (final p in type.params)
        RecipePlanItem(
          param: p,
          tag: project.tag(machine.tags[p.key]!)!,
          target: recipe.values[p.key]!,
          current: snap.values[p.key],
          readProblem: snap.problems[p.key],
        ),
    ];

    RecipeCondition? condition;
    final condId = machine.conditionTagId;
    if (condId != null && snap.ok) {
      condition = await _condition(project.tag(condId)!, machine.conditionValue);
      if (condition.problem != null) {
        blockers.add('Não deu para conferir ${condition.wanted}: ${condition.problem}');
      } else if (!condition.ok) {
        blockers.add('Só aplica com ${condition.wanted}. Agora está ${condition.actual! ? 'LIGADO' : 'DESLIGADO'}.');
      }
    }
    final loadedId = machine.loadedTagId;
    return RecipePlan(
      type: type,
      machine: machine,
      recipe: recipe,
      device: device,
      items: items,
      blockers: blockers,
      condition: condition,
      loadedTag: loadedId == null ? null : project.tag(loadedId),
    );
  }

  Future<RecipeCondition> _condition(Tag tag, bool expected) async {
    try {
      final v = await runtime.readNow(tag);
      if (v is! bool) return RecipeCondition(tag: tag, expected: expected, problem: 'a variável não é liga/desliga');
      return RecipeCondition(tag: tag, expected: expected, actual: v);
    } on TagValueError catch (e) {
      return RecipeCondition(tag: tag, expected: expected, problem: e.message);
    } on CommError catch (e) {
      return RecipeCondition(tag: tag, expected: expected, problem: e.userMessage);
    }
  }

  /// Aplica o que foi confirmado. [onProgress] recebe quantos já foram.
  Future<RecipeApplyResult> apply(RecipePlan plan, {void Function(int done, int total)? onProgress}) async {
    final writes = plan.writes;
    RecipeApplyResult notApplied(String reason) => RecipeApplyResult(
          plan: plan,
          results: [for (final w in writes) RecipeItemResult(item: w, outcome: RecipeItemOutcome.notTried)],
          outcome: RecipeOutcome.notApplied,
          at: clock.now(),
          reason: reason,
        );
    if (!plan.canApply) return notApplied(plan.blockers.first);

    // A condição de novo, na hora de gravar: entre a confirmação e o toque
    // em "Aplicar" a máquina pode ter partido.
    final cond = plan.condition;
    if (cond != null) {
      final now = await _condition(cond.tag, cond.expected);
      if (now.problem != null) return notApplied('não deu para conferir ${now.wanted} (${now.problem})');
      if (!now.ok) return notApplied('só aplica com ${now.wanted}');
    }

    // Bit de "receita carregada" desligado durante a carga: o CLP sabe que a
    // receita não está completa até o fim.
    final loaded = plan.loadedTag;
    if (loaded != null) {
      try {
        await runtime.write(loaded.id, false);
      } on TagValueError catch (e) {
        return notApplied('"${loaded.name}": ${e.message}');
      } on CommError catch (e) {
        return notApplied(e.userMessage);
      }
    }

    final results = <RecipeItemResult>[];
    String? stop;
    var lost = false;
    for (var i = 0; i < writes.length; i++) {
      final w = writes[i];
      onProgress?.call(i, writes.length);
      if (stop != null) {
        results.add(RecipeItemResult(item: w, outcome: RecipeItemOutcome.notTried));
        continue;
      }
      try {
        await runtime.write(w.tag.id, RecipeLogic.writeValue(w.param, w.target));
        results.add(RecipeItemResult(item: w, outcome: RecipeItemOutcome.unverified, message: 'não relido'));
      } on TagValueError catch (e) {
        stop = e.message;
        results.add(RecipeItemResult(item: w, outcome: RecipeItemOutcome.refused, message: e.message));
      } on CommError catch (e) {
        stop = e.userMessage;
        lost = !isRefusal(e);
        results.add(RecipeItemResult(item: w, outcome: lost ? RecipeItemOutcome.commLost : RecipeItemOutcome.refused, message: e.userMessage));
      }
    }
    onProgress?.call(writes.length, writes.length);

    // Conferência: relê o que foi gravado. Sem comunicação não adianta —
    // cada leitura só esperaria o tempo esgotado.
    if (!lost && results.any((r) => r.written)) {
      if (verifyDelay > Duration.zero) await Future<void>.delayed(verifyDelay);
      for (var i = 0; i < results.length; i++) {
        final r = results[i];
        if (!r.written) continue;
        try {
          final back = RecipeLogic.asNumber(await runtime.readNow(r.item.tag));
          if (back == null) {
            results[i] = RecipeItemResult(item: r.item, outcome: RecipeItemOutcome.unverified, message: 'o valor relido não é número');
          } else {
            final ok = r.item.param.same(back, r.item.target);
            results[i] = RecipeItemResult(item: r.item, outcome: ok ? RecipeItemOutcome.verified : RecipeItemOutcome.divergent, readBack: back);
          }
        } on TagValueError catch (e) {
          results[i] = RecipeItemResult(item: r.item, outcome: RecipeItemOutcome.unverified, message: e.message);
        } on CommError catch (e) {
          results[i] = RecipeItemResult(item: r.item, outcome: RecipeItemOutcome.unverified, message: e.userMessage);
        }
      }
    } else if (lost) {
      for (var i = 0; i < results.length; i++) {
        final r = results[i];
        if (r.written) results[i] = RecipeItemResult(item: r.item, outcome: RecipeItemOutcome.unverified, message: 'a comunicação caiu logo depois');
      }
    }

    final written = results.where((r) => r.written).length;
    if (stop != null) {
      return RecipeApplyResult(
        plan: plan,
        results: results,
        outcome: written == 0 ? RecipeOutcome.notApplied : RecipeOutcome.partial,
        at: clock.now(),
        reason: written == 0 ? '"${results.firstWhere((r) => !r.written).item.param.name}": $stop' : stop,
        loadedProblem: loaded == null ? null : 'não ligado: a receita não foi carregada inteira',
      );
    }

    final allOk = results.every((r) => r.outcome == RecipeItemOutcome.verified);
    var loadedSet = false;
    String? loadedProblem;
    if (loaded != null) {
      if (!allOk) {
        loadedProblem = 'não ligado: algum valor não conferiu';
      } else {
        try {
          await runtime.write(loaded.id, true);
          loadedSet = true;
        } on TagValueError catch (e) {
          loadedProblem = e.message;
        } on CommError catch (e) {
          loadedProblem = e.userMessage;
        }
      }
    }
    return RecipeApplyResult(
      plan: plan,
      results: results,
      outcome: allOk && loadedProblem == null ? RecipeOutcome.applied : RecipeOutcome.divergent,
      at: clock.now(),
      reason: allOk && loadedProblem != null ? 'o bit "${loaded!.name}" não ligou ($loadedProblem)' : null,
      loadedSet: loadedSet,
      loadedProblem: loadedProblem,
    );
  }
}
