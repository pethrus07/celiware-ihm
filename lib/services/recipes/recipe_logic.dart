// Regras puras das receitas: comparar com tolerância (RC-4), conferir se uma
// máquina está pronta para o tipo, validar um valor contra a receita e contra
// a variável, e sugerir as variáveis de outra máquina (transferir, RC-7).
// Nada aqui fala com a rede — os testes rodam sem app.

import '../../models/project.dart';
import '../../models/recipe.dart';
import '../../models/tag.dart';
import '../runtime/tag_codec.dart';

/// O que se leu da máquina, por parâmetro.
class MachineSnapshot {
  const MachineSnapshot({this.values = const {}, this.problems = const {}, this.commError});

  /// Chave do parâmetro → valor lido (liga/desliga: 1/0).
  final Map<String, double> values;

  /// Parâmetro que não deu para ler, com o motivo ("endereço inexistente").
  final Map<String, String> problems;

  /// Sem comunicação: a leitura parou aí e o resto não foi lido.
  final String? commError;

  bool get ok => commError == null;
}

/// Como está um parâmetro na comparação máquina × receita.
enum RecipeDiffState {
  /// Igual dentro da tolerância.
  same,

  /// Diferente além da tolerância.
  different,

  /// A receita não tem valor para ele.
  noValue,

  /// Não deu para ler da máquina.
  unreadable,
}

class RecipeDiff {
  const RecipeDiff({required this.param, required this.state, this.recipe, this.machine, this.message = ''});
  final RecipeParam param;
  final RecipeDiffState state;
  final double? recipe;
  final double? machine;
  final String message;
}

class RecipeLogic {
  RecipeLogic._();

  /// Valor lido → número da receita (liga/desliga vira 1/0).
  static double? asNumber(Object? v) => v is bool ? (v ? 1.0 : 0.0) : v is num ? v.toDouble() : null;

  /// Número da receita → o que o runtime grava.
  static Object writeValue(RecipeParam p, double v) => p.onOff ? v != 0 : v;

  /// Compara parâmetro a parâmetro, na ordem do tipo.
  static List<RecipeDiff> compare(RecipeType type, Map<String, double> recipe, MachineSnapshot machine) => [
        for (final p in type.params)
          () {
            final r = recipe[p.key], m = machine.values[p.key];
            if (r == null) return RecipeDiff(param: p, state: RecipeDiffState.noValue, machine: m, message: 'sem valor na receita');
            if (m == null) {
              return RecipeDiff(param: p, state: RecipeDiffState.unreadable, recipe: r, message: machine.problems[p.key] ?? machine.commError ?? 'não lido');
            }
            return RecipeDiff(param: p, state: p.same(m, r) ? RecipeDiffState.same : RecipeDiffState.different, recipe: r, machine: m);
          }(),
      ];

  /// Só o que difere (o que a comparação mostra).
  static List<RecipeDiff> differences(List<RecipeDiff> all) => all.where((d) => d.state == RecipeDiffState.different).toList();

  /// O que impede a máquina de receber o tipo: parâmetro sem variável,
  /// variável apagada, de outra máquina, que não grava ou de outro tipo; e a
  /// condição ou o bit de "receita carregada" quebrados. Vazio = pronta.
  static List<String> machineProblems(RecipeType type, RecipeMachine m, Project project) {
    if (project.device(m.deviceId) == null) return const ['A máquina foi apagada do projeto'];
    final out = <String>[];
    for (final p in type.params) {
      final id = m.tags[p.key];
      final t = id == null ? null : project.tag(id);
      if (id == null) {
        out.add('Falta escolher a variável de "${p.name}"');
      } else if (t == null) {
        out.add('"${p.name}": a variável foi apagada');
      } else if (t.deviceId != m.deviceId) {
        out.add('"${p.name}": a variável é de outra máquina');
      } else if (!RecipeParam.canUse(t)) {
        out.add('"${p.name}": "${t.name}" não pode ser gravada pela tela');
      } else if (!p.fits(t)) {
        out.add(p.onOff ? '"${p.name}" é liga/desliga e "${t.name}" não' : '"${p.name}" é número e "${t.name}" é liga/desliga');
      }
    }
    final c = m.conditionTagId;
    if (c != null) {
      final t = project.tag(c);
      if (t == null || t.deviceId != m.deviceId) {
        out.add('A variável da condição para aplicar foi apagada');
      } else if (t.dataType != TagDataType.bool || t.isArray) {
        out.add('A condição para aplicar precisa de uma variável liga/desliga');
      }
    }
    final l = m.loadedTagId;
    if (l != null) {
      final t = project.tag(l);
      if (t == null || t.deviceId != m.deviceId) {
        out.add('A variável de "receita carregada" foi apagada');
      } else if (t.dataType != TagDataType.bool || !t.canWrite || t.isArray) {
        out.add('"Receita carregada" precisa de uma variável liga/desliga gravável');
      }
    }
    return out;
  }

  /// O valor cabe? Primeiro a faixa da receita, depois o que a variável da
  /// máquina aceita (tipo, passo da escala). Nulo = cabe.
  static String? valueProblem(RecipeParam p, double v, {Tag? tag}) {
    if (!v.isFinite) return '"${p.name}": número inválido';
    if (p.onOff) return null;
    // A faixa é rígida: a tolerância é da comparação, não da faixa. Só a folga
    // do ponto flutuante vale (150,00000001 lido de um FLOAT32 é 150).
    final lo = p.min, hi = p.max;
    if (lo != null && v < lo - RecipeParam.floatSlack(v, lo)) return '"${p.name}": ${p.format(v)} está abaixo do mínimo (${p.format(lo)})';
    if (hi != null && v > hi + RecipeParam.floatSlack(v, hi)) return '"${p.name}": ${p.format(v)} passa do máximo (${p.format(hi)})';
    if (tag != null && tag.dataType != TagDataType.bool) {
      try {
        TagCodec.encodeRegisters(tag, v);
      } on TagValueError catch (e) {
        return 'Nesta máquina, ${e.message}';
      }
    }
    return null;
  }

  /// Variáveis de outra máquina para o mesmo tipo (transferir, RC-7). Para
  /// cada parâmetro, a primeira que servir, nesta ordem: mesmo nome da
  /// variável de origem; mesma memória do CLP ("D200"); mesmo endereço (é o
  /// mesmo modelo de máquina); nome igual ao do parâmetro. Sem acento e sem
  /// diferença de maiúscula. Uma variável não serve a dois parâmetros.
  static Map<String, String> suggestBinding(RecipeType type, Project project, {required String toDeviceId, RecipeMachine? from}) {
    final candidates = project.tagsOf(toDeviceId).where(RecipeParam.canUse).toList();
    final used = <String>{};
    final out = <String, String>{};
    for (final p in type.params) {
      final srcId = from?.tags[p.key];
      final src = srcId == null ? null : project.tag(srcId);
      final tests = <bool Function(Tag)>[
        if (src != null) (t) => plain(t.name) == plain(src.name),
        if (src?.memory != null) (t) => t.memory != null && t.memory!.trim().toUpperCase() == src!.memory!.trim().toUpperCase(),
        if (src != null && src.mqtt == null)
          (t) => t.mqtt == null && t.area == src.area && t.address == src.address && (!t.isBitOfRegister || t.bitIndex == src.bitIndex),
        (t) => plain(t.name) == plain(p.name),
      ];
      for (final test in tests) {
        final hit = candidates.where((t) => !used.contains(t.id) && p.fits(t) && test(t)).firstOrNull;
        if (hit != null) {
          out[p.key] = hit.id;
          used.add(hit.id);
          break;
        }
      }
    }
    return out;
  }

  /// "Velocidade Desejada " → "velocidade desejada", sem acento.
  static String plain(String s) => s
      .trim()
      .toLowerCase()
      .replaceAll(RegExp('[áàâã]'), 'a')
      .replaceAll(RegExp('[éê]'), 'e')
      .replaceAll('í', 'i')
      .replaceAll(RegExp('[óôõ]'), 'o')
      .replaceAll('ú', 'u')
      .replaceAll('ç', 'c')
      .replaceAll(RegExp(r'\s+'), ' ');
}
