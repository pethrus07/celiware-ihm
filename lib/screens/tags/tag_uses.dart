import '../../models/hmi_screen.dart';
import '../../models/project.dart';
import '../../models/tag.dart';
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
        if (many is List && many.contains(tagId)) uses.add(TagUse(s, e, TagFit.number));
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
}
