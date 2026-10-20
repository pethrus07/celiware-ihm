// Visão da planta a partir do projeto aberto: o que o motor e o editor das
// regras da planta enxergam (funções puras, testadas sem tela nem rede).
//
// O app inteiro trabalha com UM projeto aberto (as telas, Equipamentos,
// Variáveis, alarmes e registros são dele). As regras da planta precisam de
// variáveis de outros projetos. A visão junta ao projeto aberto as
// variáveis e os equipamentos dos outros, com o id qualificado
// (`<projeto>/<id>`) e o nome com o projeto na frente ("Prensa · Velocidade");
// as do projeto aberto ficam com o id e o nome de sempre.
//
// - [runtime]: só o que as regras da planta LIGADAS usam (o motor lê as
//   máquinas citadas; nenhuma outra é conectada por causa da planta).
// - [editor]: todas as variáveis de todos os projetos, para escolher.

import '../../models/calc.dart';
import '../../models/device.dart';
import '../../models/logic_rule.dart';
import '../../models/plant.dart';
import '../../models/project.dart';
import '../../models/tag.dart';
import '../calc/calc_graph.dart';

class PlantView {
  PlantView._();

  /// Separador do nome do projeto no nome da variável e do equipamento.
  static const nameSep = ' · ';

  /// O projeto aberto com o que as regras da planta ligadas citam dos outros
  /// projetos, e essas regras traduzidas para a visão. É o que vai para o
  /// motor ([HmiRuntime]) e para o motor das regras.
  static Project runtime({
    required String openId,
    required Project open,
    required Map<String, Project> others,
    required List<LogicRule> rules,
  }) {
    final enabled = [for (final r in rules) if (r.enabled) r];
    if (enabled.isEmpty) return open;
    // Por projeto: as variáveis citadas.
    final wanted = <String, Set<String>>{};
    for (final r in enabled) {
      for (final ref in {...r.condition.inputIds, if (r.targetTagId.isNotEmpty) r.targetTagId}) {
        final p = PlantRef.parse(ref);
        if (p == null || p.$1 == openId) continue;
        (wanted[p.$1] ??= {}).add(p.$2);
      }
    }
    final extra = _qualify(others, wanted);
    return _merge(open, extra, [for (final r in enabled) PlantRef.ruleToView(r, openId)]);
  }

  /// Todas as variáveis da planta, para o editor das regras da planta. As
  /// regras do projeto aberto saem (aqui só aparecem as da planta).
  static Project editor({
    required String openId,
    required Project open,
    required Map<String, Project> others,
    required List<LogicRule> rules,
  }) {
    final extra = _qualify(others, {for (final e in others.entries) e.key: null});
    return _merge(open.copyWith(rules: const []), extra, [for (final r in rules) PlantRef.ruleToView(r, openId)]);
  }

  /// Equipamentos e variáveis de outros projetos, qualificados. [wanted]
  /// nulo para um projeto = todas as variáveis dele; senão, as citadas e
  /// o que as calculadas citadas precisam (em qualquer profundidade).
  static ({List<Device> devices, List<Tag> tags}) _qualify(Map<String, Project> others, Map<String, Set<String>?> wanted) {
    final devices = <Device>[];
    final tags = <Tag>[];
    for (final MapEntry(key: pid, value: ids) in wanted.entries) {
      final p = others[pid];
      if (p == null) continue; // projeto apagado: a regra fica parada ("falta variável")
      final keep = ids == null ? {for (final t in p.tags) t.id} : CalcGraph.expand(p, ids);
      final usedDevices = <String>{};
      for (final t in p.tags) {
        if (!keep.contains(t.id)) continue;
        tags.add(_tag(pid, p.name, t));
        if (t.deviceId != CalcDevice.id) usedDevices.add(t.deviceId);
      }
      for (final d in p.devices) {
        if (usedDevices.contains(d.id)) devices.add(_device(pid, p.name, d));
      }
    }
    return (devices: devices, tags: tags);
  }

  static Tag _tag(String pid, String projectName, Tag t) {
    String q(String id) => PlantRef.of(pid, id);
    final j = t.toJson()
      ..['id'] = q(t.id)
      ..['name'] = '$projectName$nameSep${t.name}'
      // As calculadas moram todas no equipamento virtual único.
      ..['deviceId'] = t.deviceId == CalcDevice.id ? CalcDevice.id : q(t.deviceId);
    final calc = t.calc;
    if (calc != null) j['calc'] = calc.copyWithExpression(PlantRef.mapExpression(calc.expression, q), q).toJson();
    return Tag.fromJson(j);
  }

  static Device _device(String pid, String projectName, Device d) => Device.fromJson(d.toJson()
    ..['id'] = PlantRef.of(pid, d.id)
    ..['name'] = '$projectName$nameSep${d.name}');

  static Project _merge(Project open, ({List<Device> devices, List<Tag> tags}) extra, List<LogicRule> rules) {
    final hasCalc = open.devices.any((d) => d.id == CalcDevice.id);
    final needsCalc = !hasCalc && extra.tags.any((t) => t.deviceId == CalcDevice.id);
    return open.copyWith(
      devices: [...open.devices, ...extra.devices, if (needsCalc) CalcDevice.device],
      tags: [...open.tags, ...extra.tags],
      rules: [...open.rules, ...rules],
    );
  }
}
