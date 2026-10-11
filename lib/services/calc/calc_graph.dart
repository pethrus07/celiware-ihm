import '../../models/calc.dart';
import '../../models/project.dart';
import '../../models/tag.dart';
import 'calc_expression.dart';

/// As contas dentro do projeto: quem cita quem, em que ordem calcular, de que
/// equipamentos uma calculada depende, e o texto de editar.
class CalcGraph {
  CalcGraph._();

  /// As variáveis do projeto que uma conta pode citar.
  static CalcScope scope(Project p, {Map<String, String> knownNames = const {}}) => CalcScope(
        [
          for (final t in p.tags) CalcRef(id: t.id, name: t.name, device: p.device(t.deviceId)?.name ?? '', kind: kindOf(t)),
        ],
        knownNames: knownNames,
      );

  static CalcRefKind kindOf(Tag t) => t.isText
      ? CalcRefKind.text
      : t.isArray
          ? CalcRefKind.list
          : t.dataType == TagDataType.bool
              ? CalcRefKind.boolean
              : CalcRefKind.number;

  /// A conta guardada, conferida contra o projeto de agora (variável apagada
  /// ou que virou texto dá [CalcError]).
  static CalcProgram compile(CalcSpec spec, Project p) => CalcProgram.compile(spec.expression, scope(p, knownNames: spec.names));

  /// [ids] mais as entradas das calculadas entre eles, de qualquer
  /// profundidade: uma tela com "Eficiência" precisa que a "Velocidade" da
  /// cortadora seja lida.
  static Set<String> expand(Project p, Iterable<String> ids) {
    final start = ids.toSet();
    if (!p.tags.any((t) => t.calc != null)) return start;
    final byId = {for (final t in p.tags) t.id: t};
    final out = <String>{};
    final queue = [...start];
    while (queue.isNotEmpty) {
      final id = queue.removeLast();
      if (!out.add(id)) continue;
      final c = byId[id]?.calc;
      if (c != null) queue.addAll(c.inputIds);
    }
    return out;
  }

  /// Os ids do círculo que [draft] fecharia (`[draft, A, B, draft]`), ou nulo.
  /// "A usa B que usa A" é recusado ao salvar: a conta nunca terminaria.
  static List<String>? cycle(Project p, Tag draft) {
    final c = draft.calc;
    if (c == null) return null;
    final byId = {for (final t in p.tags) t.id: t};
    final seen = <String>{};
    List<String>? walk(String id, List<String> path) {
      if (id == draft.id) return [...path, id];
      if (!seen.add(id)) return null;
      final cc = byId[id]?.calc;
      if (cc == null) return null;
      for (final i in cc.inputIds) {
        final r = walk(i, [...path, id]);
        if (r != null) return r;
      }
      return null;
    }

    for (final i in c.inputIds) {
      final r = walk(i, [draft.id]);
      if (r != null) return r;
    }
    return null;
  }

  /// O círculo em palavras: "A conta fica em círculo: Eficiência → Meta →
  /// Eficiência".
  static String cycleMessage(Project p, Tag draft, List<String> path) {
    if (path.length <= 2) return 'A conta não pode usar a própria variável';
    String name(String id) => id == draft.id ? draft.name : (p.tag(id)?.name ?? id);
    return 'A conta fica em círculo: ${path.map(name).join(' → ')}';
  }

  /// Ordem de cálculo das calculadas [calcs]: quem é entrada de outra vem
  /// antes. As que estão em círculo (arquivo editado à mão) vão em `cyclic`.
  static (List<Tag>, Set<String>) order(List<Tag> calcs) {
    final byId = {for (final t in calcs) t.id: t};
    final out = <Tag>[];
    final state = <String, int>{}; // 1 = visitando, 2 = pronto
    final cyclic = <String>{};
    void visit(Tag t, List<String> stack) {
      final s = state[t.id];
      if (s == 2) return;
      if (s == 1) {
        cyclic.addAll(stack.sublist(stack.indexOf(t.id)));
        return;
      }
      state[t.id] = 1;
      stack.add(t.id);
      for (final i in t.calc?.inputIds ?? const <String>{}) {
        final d = byId[i];
        if (d != null) visit(d, stack);
      }
      stack.removeLast();
      state[t.id] = 2;
      out.add(t);
    }

    for (final t in calcs) {
      visit(t, []);
    }
    return (out, cyclic);
  }

  /// Equipamentos de verdade de que a variável depende: o dela, ou — se for
  /// calculada — os das entradas, em qualquer profundidade.
  static Set<String> devicesOf(Project p, Tag t) {
    if (t.calc == null) return {t.deviceId};
    final byId = {for (final x in p.tags) x.id: x};
    return {
      for (final id in expand(p, [t.id]))
        if (byId[id] case final x? when x.calc == null) x.deviceId,
    };
  }

  /// O texto para editar: `{id}` vira `[Nome]` — ou `[Equipamento: Nome]`
  /// quando o nome se repete. Variável apagada aparece pelo nome de quando a
  /// conta foi salva (e a conferência avisa que ela não existe).
  static String display(CalcSpec spec, Project p) => spec.expression.replaceAllMapped(CalcSpec.refPattern, (m) {
        final id = m.group(1)!;
        final t = p.tag(id);
        if (t == null) return '[${spec.names[id] ?? id}]';
        return reference(t, p);
      });

  /// Como citar a variável na conta.
  static String reference(Tag t, Project p) {
    // Nome com colchete não cabe entre colchetes: vai pelo id.
    if (t.name.contains(']') || t.name.contains('[')) return '{${t.id}}';
    final key = CalcScope.plain(t.name);
    final same = p.tags.where((x) => CalcScope.plain(x.name) == key).length;
    final device = p.device(t.deviceId)?.name;
    if (same > 1 && device != null && device.isNotEmpty) return '[$device: ${t.name}]';
    return '[${t.name}]';
  }
}
