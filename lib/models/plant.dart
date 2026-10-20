// Planta: a fábrica inteira no celular (reunião de 19–20/10/2026, decisões
// D6, D7 e D10). Hierarquia: Planta > Projetos > (equipamentos, variáveis,
// telas, regras locais, registros, receitas, câmeras). Cada máquina é um
// PROJETO isolado — exatamente o `Project` de sempre —, e a planta junta os
// projetos e as REGRAS DA PLANTA, que podem usar variáveis de qualquer
// projeto para interligar máquinas (item 226 da lista do cliente).
//
// Arquivo da planta (exportar "a planta inteira", D7), `schemaVersion` 2:
//
//   { "format": "celiware-ihm", "schemaVersion": 2, "kind": "planta",
//     "name": "Fábrica", "projects": [ { "id": "p_…", <projeto> }, … ],
//     "rules": [ <regra da planta>, … ] }
//
// Um projeto avulso continua saindo no formato de sempre (`schemaVersion`
// 1): a 1.4.0 abre o arquivo de um projeto mandado por quem já atualizou.
//
// Regra da planta cita variável por referência QUALIFICADA:
// `{<projeto>/<variável>}` na conta e `<projeto>/<variável>` no destino —
// o mesmo id de variável pode existir em dois projetos (projeto duplicado).

import 'calc.dart';
import 'logic_rule.dart';
import 'project.dart';

/// Um projeto dentro da planta: o id (a pasta dele no aparelho e a chave das
/// referências das regras da planta) e o projeto.
class PlantProject {
  const PlantProject(this.id, this.project);
  final String id;
  final Project project;
}

class Plant {
  const Plant({this.name = defaultName, this.projects = const [], this.rules = const []});

  static const defaultName = 'Minha planta';

  /// Versão do arquivo da planta. O projeto avulso segue em
  /// [Project.schemaVersion] (1).
  static const schemaVersion = 2;
  static const kind = 'planta';

  final String name;
  final List<PlantProject> projects;

  /// Regras da planta (referências qualificadas, ver [PlantRef]).
  final List<LogicRule> rules;

  Map<String, dynamic> toJson() => {
        'format': 'celiware-ihm',
        'schemaVersion': schemaVersion,
        'kind': kind,
        'name': name,
        'projects': [
          for (final p in projects)
            {
              'id': p.id,
              ...p.project.toJson()
                ..remove('format')
                ..remove('schemaVersion'),
            },
        ],
        if (rules.isNotEmpty) 'rules': [for (final r in rules) r.toJson()],
      };

  factory Plant.fromJson(Map<String, dynamic> j) => Plant(
        name: (j['name'] as String?)?.trim().isNotEmpty == true ? (j['name'] as String).trim() : defaultName,
        projects: [
          for (final p in (j['projects'] as List? ?? const []))
            if (p is Map && p['id'] is String) PlantProject(p['id'] as String, Project.fromJson(Map<String, dynamic>.from(p))),
        ],
        rules: [
          for (final r in (j['rules'] as List? ?? const []))
            if (r is Map && r['id'] is String) LogicRule.fromJson(Map<String, dynamic>.from(r)),
        ],
      );
}

/// Referências das regras da planta: `<projeto>/<variável>`.
///
/// Dentro do app, a regra da planta é mostrada e avaliada numa visão em que
/// as variáveis do projeto ABERTO têm o id de sempre e as dos outros
/// projetos o id qualificado ([PlantView]). Guardada, toda referência é
/// qualificada — não depende de qual projeto estava aberto ao salvar.
class PlantRef {
  PlantRef._();

  static const sep = '/';

  static String of(String projectId, String id) => '$projectId$sep$id';

  /// (projeto, variável) de uma referência qualificada; nulo se não é.
  static (String, String)? parse(String ref) {
    final i = ref.indexOf(sep);
    if (i <= 0 || i == ref.length - 1) return null;
    return (ref.substring(0, i), ref.substring(i + 1));
  }

  /// Id da variável na visão com [openId] aberto.
  static String toView(String ref, String openId) {
    final p = parse(ref);
    return p != null && p.$1 == openId ? p.$2 : ref;
  }

  /// Id guardado (qualificado) de um id da visão.
  static String toStored(String id, String openId) => parse(id) != null ? id : of(openId, id);

  /// Troca cada `{ref}` da conta por `{map(ref)}`.
  static String mapExpression(String expression, String Function(String ref) map) =>
      expression.replaceAllMapped(CalcSpec.refPattern, (m) => '{${map(m.group(1)!)}}');

  static LogicRule mapRule(LogicRule r, String Function(String ref) map) => r.copyWith(
        condition: r.condition.copyWithExpression(mapExpression(r.condition.expression, map), map),
        targetTagId: r.targetTagId.isEmpty ? '' : map(r.targetTagId),
      );

  static LogicRule ruleToView(LogicRule r, String openId) => mapRule(r, (ref) => toView(ref, openId));
  static LogicRule ruleToStored(LogicRule r, String openId) => mapRule(r, (id) => toStored(id, openId));

  /// Os projetos que a regra cita.
  static Set<String> projectsOf(LogicRule r) => {
        for (final ref in {...r.condition.inputIds, if (r.targetTagId.isNotEmpty) r.targetTagId}) ?parse(ref)?.$1,
      };
}
