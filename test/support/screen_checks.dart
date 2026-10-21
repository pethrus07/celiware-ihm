import 'package:ihm/models/hmi_screen.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/widgets/hmi/element_catalog.dart';
import 'package:ihm/widgets/hmi/elements/control_elements.dart';

/// O que está errado numa tela montada por modelo (de tela ou de projeto
/// pronto) — a mesma régua para os dois: dentro da grade e sem sobrepor (a
/// regra do editor), quem grava com pelo menos 3×3, meia largura com rótulo
/// com 4 de altura, cada elemento com uma variável que ele aceita. Volta a
/// lista inteira, para o relatório do teste mostrar tudo de uma vez.
List<String> templateScreenProblems(HmiScreen s, Map<String, Tag> tags) {
  final out = <String>[];
  if (s.elements.map((e) => e.id).toSet().length != s.elements.length) out.add('id de elemento repetido');
  for (final e in s.elements) {
    final where = '${e.type.name} "${e.props['label'] ?? e.props['text']}" em ${e.x},${e.y}';
    if (!ElementCatalog.fits(s, e)) out.add('$where: fora da grade, abaixo do mínimo ou sobreposto');
    if (ElementCatalog.of(e.type).writes) {
      if (e.w < 3 || e.h < 3) out.add('$where: quem grava tem pelo menos 3×3');
    } else if (e.w < s.columns && e.type != ElementType.label && e.h < 4) {
      out.add('$where: meia largura com rótulo precisa de 4 de altura');
    }
    final missing = [for (final id in e.tagIds) if (tags[id] == null) id];
    if (missing.isNotEmpty) {
      out.add('$where aponta para variável que não existe');
      continue;
    }
    final main = e.tagId == null ? null : tags[e.tagId];
    if (e.type == ElementType.button) {
      final mode = ButtonModeMeta.fromName(e.props['mode'] as String?);
      if (main == null) {
        out.add('$where: botão sem variável');
        continue;
      }
      if (mode.isBit) {
        if (main.dataType != TagDataType.bool) out.add('$where: modo de bit pede liga/desliga');
        final fb = e.props['feedbackTagId'];
        if (fb != null && tags[fb]!.dataType != TagDataType.bool) out.add('$where: retorno');
      } else {
        if (mode != ButtonMode.value || !main.dataType.isNumeric) out.add('$where: modo de valor pede número');
        if (e.props['value'] is! int) out.add('$where: valor da marca');
      }
      if (!main.writable) out.add('$where: botão grava');
    } else if (e.type == ElementType.oee) {
      // O OEE não tem a escolha única do topo (vagas fixas): cada vaga pede número.
      for (final id in e.tagIds) {
        if (!TagFit.number.accepts(tags[id]!)) out.add('$where não aceita "${tags[id]!.name}"');
      }
    } else {
      final fit = ElementCatalog.of(e.type).fit;
      for (final id in e.tagIds) {
        if (!fit.accepts(tags[id]!)) out.add('$where não aceita "${tags[id]!.name}"');
      }
    }
    if (e.type == ElementType.input && !(main?.writable ?? false)) out.add('$where: ajuste grava');
  }
  return out;
}
