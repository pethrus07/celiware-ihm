import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../models/tag.dart';

/// Resultado da escolha de variável: um id, ou nenhuma ([tagId] nulo).
class TagPick {
  const TagPick(this.tagId);
  final String? tagId;
}

/// Folha para escolher uma variável. Com [noneLabel], a primeira linha é
/// "nenhuma" ("Sempre", "Nada"). Devolve nulo se a pessoa fechou sem escolher.
Future<TagPick?> pickTag(
  BuildContext context, {
  required String title,
  required List<Tag> tags,
  String? noneLabel,
  String? selectedId,
  String empty = 'Nenhuma variável desta máquina serve aqui.',
}) =>
    showModalBottomSheet<TagPick>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.92,
        builder: (ctx, scroll) => ListView(
          controller: scroll,
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 8),
              child: Text(title, style: Theme.of(ctx).textTheme.titleLarge),
            ),
            if (noneLabel != null)
              ListTile(
                key: const ValueKey('escolher-nenhuma'),
                leading: const Icon(Icons.block_rounded),
                title: Text(noneLabel),
                trailing: selectedId == null ? Icon(Icons.check_rounded, color: Ind.accent) : null,
                onTap: () => Navigator.pop(ctx, const TagPick(null)),
              ),
            if (tags.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(Ind.page, 12, Ind.page, 0),
                child: Text(empty, style: TextStyle(color: Ind.textDim, height: 1.4)),
              ),
            for (final t in tags)
              ListTile(
                key: ValueKey('escolher-${t.id}'),
                title: Text(t.name),
                subtitle: Text(t.memoryLabel),
                trailing: t.id == selectedId ? Icon(Icons.check_rounded, color: Ind.accent) : null,
                onTap: () => Navigator.pop(ctx, TagPick(t.id)),
              ),
          ],
        ),
      ),
    );

/// "75,2" ou "75.2" → 75.2. Vazio ou texto → nulo.
double? parseNumber(String text) => double.tryParse(text.trim().replaceAll(' ', '').replaceAll(',', '.'));

/// 75.2 → "75,2"; inteiro sem casas; vazio para nulo.
String numberText(double? v) {
  if (v == null) return '';
  if (v == v.roundToDouble()) return v.round().toString();
  return v.toString().replaceAll('.', ',');
}

/// "hoje 14:32", "ontem 09:10", "08/10/2026 17:05" — na hora local.
String whenLabel(DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  final l = at.toLocal(), n = clock.now();
  final hm = '${two(l.hour)}:${two(l.minute)}';
  final days = DateTime(n.year, n.month, n.day).difference(DateTime(l.year, l.month, l.day)).inDays;
  if (days == 0) return 'hoje $hm';
  if (days == 1) return 'ontem $hm';
  return '${two(l.day)}/${two(l.month)}/${l.year} $hm';
}

/// Rótulo de seção dentro de folha (caixa alta pequena).
Widget sheetLabel(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(text.toUpperCase(), style: Ind.tag(size: 11)),
    );

/// Barra de baixo de folha com o botão principal e o erro logo acima dele
/// (no meio de uma lista longa, o aviso ficaria fora da tela).
class SheetActions extends StatelessWidget {
  const SheetActions({super.key, required this.child, this.error});
  final Widget child;
  final String? error;

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Ind.page, 8, Ind.page, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(error!, key: const ValueKey('erro-folha'), textAlign: TextAlign.center, style: TextStyle(color: Ind.textFor(Ind.alarm), fontWeight: FontWeight.w600)),
              ),
            child,
          ]),
        ),
      );
}
