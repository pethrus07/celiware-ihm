import '../../models/hmi_screen.dart';
import '../../models/project.dart';
import '../../models/tag.dart';
import '../../services/calc/calc_graph.dart';
import '../../widgets/hmi/element_catalog.dart';
import '../../widgets/hmi/elements/control_elements.dart';

/// Um elemento de tela que usa a variável e o tipo de variável que ele aceita
/// **naquele lugar**: o retorno do botão pede liga/desliga mesmo num botão
/// que grava número; a tendência pede número.
class TagUse {
  const TagUse(this.screen, this.element, this.fit, {this.feedback = false});
  final HmiScreen screen;
  final HmiElement element;
  final TagFit fit;

  /// Usada como retorno da máquina de um botão.
  final bool feedback;

  /// "Medidor", "Botão (retorno)".
  String get elementName {
    final name = ElementCatalog.of(element.type).name;
    return feedback ? '$name (retorno)' : name;
  }

  /// Onde a variável [tagId] aparece nas telas do projeto.
  static List<TagUse> of(Project project, String tagId) {
    final uses = <TagUse>[];
    for (final s in project.screens) {
      for (final e in s.elements) {
        if (e.tagId == tagId) {
          final fit = switch (e.type) {
            ElementType.button => _buttonFit(e),
            // Imagem por etapa: o código vem de número ou de liga/desliga.
            ElementType.image => TagFit.scalar,
            _ => ElementCatalog.of(e.type).fit,
          };
          if (fit != null && fit != TagFit.none) uses.add(TagUse(s, e, fit));
        }
        if (e.props['feedbackTagId'] == tagId) uses.add(TagUse(s, e, TagFit.boolean, feedback: true));
        final many = e.props['tagIds'];
        // Tendência pede número; a tabela aceita qualquer valor único.
        if (many is List && many.contains(tagId)) uses.add(TagUse(s, e, e.type == ElementType.table ? TagFit.any : TagFit.number));
      }
    }
    return uses;
  }

  /// Botão: liga/desliga nos modos de bit, número no "grava valor"; o "ir
  /// para tela" não usa variável.
  static TagFit? _buttonFit(HmiElement e) {
    final mode = ButtonModeMeta.fromName(e.prop<String>('mode', 'toggle'));
    if (!mode.needsTag) return null;
    return mode.needsNumber ? TagFit.number : TagFit.boolean;
  }

  /// Usos que funcionam com a variável como era ([before]) e deixam de
  /// funcionar com ela como está no formulário ([after]) — o que a troca de
  /// tipo quebra. Elemento que já não servia antes não entra: não foi esta
  /// troca que quebrou.
  static List<TagUse> brokenBy(List<TagUse> uses, Tag before, Tag after) =>
      uses.where((u) => u.fit.accepts(before) && !u.fit.accepts(after)).toList();

  /// "Cortadora — operação (Medidor, Gráfico de tendência); Resumo (Mostrador)".
  static String describe(Iterable<TagUse> uses) {
    final byScreen = <HmiScreen, List<String>>{};
    for (final u in uses) {
      final list = byScreen.putIfAbsent(u.screen, () => []);
      if (!list.contains(u.elementName)) list.add(u.elementName);
    }
    return [for (final e in byScreen.entries) '${e.key.name} (${e.value.join(', ')})'].join('; ');
  }

  /// O texto do "Apagar": onde a variável [tagId] entra e o que deixa de
  /// funcionar sem ela — elementos de tela, contas de calculadas e regras
  /// entre máquinas (na condição ou como destino). Conta e condição valem em
  /// qualquer profundidade: se ela entra numa calculada que entra em outra,
  /// as duas param. Um parágrafo por tipo; sem uso nenhum, só que ela sai.
  static String deleteNotice(Project project, String tagId) {
    bool uses(Set<String> inputs) => inputs.isNotEmpty && CalcGraph.expand(project, inputs).contains(tagId);
    final screens = project.screensUsingTag(tagId);
    final calcs = [
      for (final t in project.tags)
        if (t.id != tagId && t.calc != null && uses(t.calc!.inputIds)) t.name,
    ];
    final rules = <String>[];
    for (final r in project.rules) {
      final inCondition = uses(r.condition.inputIds), isTarget = r.targetTagId == tagId;
      if (!inCondition && !isTarget) continue;
      rules.add('${r.name} (${inCondition && isTarget ? 'na condição e onde grava' : inCondition ? 'na condição' : 'onde grava'})');
    }
    // Receita: parâmetro, condição ("só com a máquina parada") ou bit de
    // receita carregada de alguma máquina do tipo.
    final recipes = [
      for (final t in project.recipeTypes)
        if (t.machines.any((m) => m.tags.containsValue(tagId) || m.conditionTagId == tagId || m.loadedTagId == tagId)) t.name,
    ];
    final logs = [for (final g in project.logGroups) if (g.tagIds.contains(tagId)) g.name];
    final one = rules.length == 1;
    return [
      if (screens.isEmpty && calcs.isEmpty && rules.isEmpty && recipes.isEmpty && logs.isEmpty) 'A variável sai do projeto.',
      if (screens.isNotEmpty) 'Ela é usada em: ${screens.map((s) => s.name).join(', ')}. Esses elementos vão ficar pedindo "Escolha a variável".',
      if (calcs.isNotEmpty)
        'Ela entra na conta de: ${calcs.join(', ')}. ${calcs.length == 1 ? 'Essa conta vai dar erro até ser corrigida.' : 'Essas contas vão dar erro até serem corrigidas.'}',
      if (rules.isNotEmpty)
        'Ela está ${one ? 'na regra' : 'nas regras'}: ${rules.join(', ')}. ${one ? 'Essa regra fica parada' : 'Essas regras ficam paradas'} até ${one ? 'ser corrigida' : 'serem corrigidas'}.',
      if (recipes.isNotEmpty)
        'Ela está ${recipes.length == 1 ? 'no tipo de receita' : 'nos tipos de receita'}: ${recipes.join(', ')}. Sem ela, ${recipes.length == 1 ? 'as receitas desse tipo não aplicam' : 'as receitas desses tipos não aplicam'} até outra variável ser escolhida no lugar.',
      if (logs.isNotEmpty)
        'Ela é gravada ${logs.length == 1 ? 'no registro' : 'nos registros'}: ${logs.join(', ')}. O que já foi gravado continua no histórico.',
    ].join('\n\n');
  }
}
