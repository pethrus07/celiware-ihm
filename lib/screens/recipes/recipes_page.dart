import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/ids.dart';
import '../../models/project.dart';
import '../../models/recipe.dart';
import '../../widgets/common/adaptive.dart';
import '../../widgets/common/common.dart';
import 'recipe_history_page.dart';
import 'recipe_page.dart';
import 'recipe_type_page.dart';
import '../tours.dart';
import '../../widgets/tour/tour.dart';

/// Mais → Receitas: os ajustes de cada produto, por tipo de receita.
///
/// Uma seção por tipo, com as receitas dele; tocar abre a receita (onde se
/// lê da máquina, compara e aplica). O tipo — parâmetros, faixas, máquinas —
/// fica atrás do ícone de ajuste, porque se mexe nele raramente.
class RecipesPage extends StatelessWidget {
  const RecipesPage({super.key});

  /// Linha da Mais: "Ajustes por produto…" ou "3 receitas".
  static String summary(Project p) {
    final n = p.recipes.where((r) => p.recipeType(r.typeId) != null).length;
    if (p.recipeTypes.isEmpty) return 'Ajustes de cada produto, aplicados com confirmação';
    return n == 0 ? 'Nenhuma receita ainda' : n == 1 ? '1 receita' : '$n receitas';
  }

  @override
  Widget build(BuildContext context) {
    final p = AppScope.watch(context).controller.project;
    final types = p.recipeTypes;
    // "?" explica a página (não abre sozinho).
    return TourHost(
      spec: Tours.receitas(),
      autoStart: false,
      child: Scaffold(
      appBar: AppBar(
        title: const Text('Receitas'),
        actions: [
          IconButton(
            key: const ValueKey('historico-receitas'),
            tooltip: 'Histórico de aplicações',
            icon: const Icon(Icons.history_rounded),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RecipeHistoryPage())),
          ),
          const HelpButton(),
        ],
      ),
      floatingActionButton: types.isEmpty
          ? null
          : FloatingActionButton.extended(
              key: const ValueKey('nova-receita'),
              onPressed: () => newRecipe(context),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Nova receita'),
            ),
      body: types.isEmpty
          ? EmptyState(
              icon: Icons.receipt_long_rounded,
              title: 'Nenhuma receita',
              body: 'Guarde os ajustes de cada produto — velocidade, comprimento, temperatura — e aplique na máquina com uma confirmação.',
              action: FilledButton.icon(
                key: const ValueKey('criar-tipo'),
                onPressed: () => RecipeTypeSheet.show(context),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Começar'),
              ),
            )
          // No tablet, a coluna das receitas não estica até a borda (TB-3).
          : FormWidth(child: ListView(
              padding: const EdgeInsets.only(bottom: 100),
              children: [
                for (final t in types) ...[
                  SectionHeader(
                    t.name,
                    trailing: IconButton(
                      key: ValueKey('tipo-${t.id}'),
                      tooltip: 'Parâmetros e máquinas',
                      icon: const Icon(Icons.tune_rounded, size: 20),
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => RecipeTypePage(typeId: t.id))),
                    ),
                    padding: const EdgeInsets.fromLTRB(Ind.page, 20, Ind.page - 8, 4),
                  ),
                  if (p.recipesOf(t.id).isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 8),
                      child: Text('Nenhuma receita deste tipo ainda.', style: TextStyle(color: Ind.textMuted)),
                    ),
                  for (final r in p.recipesOf(t.id)) _RecipeTile(type: t, recipe: r),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(Ind.page - 8, 16, Ind.page, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('novo-tipo'),
                      onPressed: () => RecipeTypeSheet.show(context),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Novo tipo de receita'),
                    ),
                  ),
                ),
              ],
            )),
    ));
  }

  /// "Nova receita": escolhe o tipo (se houver mais de um), pede o nome e
  /// abre a receita — já lendo da máquina, se foi o pedido.
  static Future<void> newRecipe(BuildContext context, {String? typeId}) async {
    final c = AppScope.of(context).controller;
    final types = c.project.recipeTypes;
    var type = typeId == null ? (types.length == 1 ? types.single : null) : c.project.recipeType(typeId);
    type ??= await showDialog<RecipeType>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Tipo de receita'),
        children: [
          for (final t in types)
            SimpleDialogOption(
              key: ValueKey('escolher-tipo-${t.id}'),
              onPressed: () => Navigator.pop(ctx, t),
              child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(t.name, style: const TextStyle(fontSize: 16))),
            ),
        ],
      ),
    );
    if (type == null || !context.mounted) return;
    final answer = await showDialog<_NewRecipe>(context: context, builder: (_) => _NewRecipeDialog(type: type!));
    if (answer == null || !context.mounted) return;
    final count = c.project.recipesOf(type.id).length;
    final recipe = Recipe(
      id: newId('rc'),
      typeId: type.id,
      name: answer.name.isEmpty ? '${type.name} ${count + 1}' : answer.name,
      updatedAt: clock.now(),
      note: Recipe.noteCreated,
    );
    c.saveRecipe(recipe);
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => RecipePage(recipeId: recipe.id, deviceId: answer.deviceId, readOnOpen: answer.read)),
    );
  }
}

class _RecipeTile extends StatelessWidget {
  const _RecipeTile({required this.type, required this.recipe});
  final RecipeType type;
  final Recipe recipe;

  @override
  Widget build(BuildContext context) {
    final missing = type.params.where((p) => !recipe.values.containsKey(p.key)).length;
    final summary = missing == 0
        ? '${type.params.length == 1 ? '1 valor' : '${type.params.length} valores'} · versão ${recipe.version}'
        : missing == type.params.length
            ? 'Sem valores ainda'
            : missing == 1
                ? 'Falta 1 valor'
                : 'Faltam $missing valores';
    return ListTile(
      key: ValueKey('receita-${recipe.id}'),
      leading: Icon(Icons.receipt_long_outlined, color: Ind.accent),
      title: Text(recipe.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
      subtitle: Padding(padding: const EdgeInsets.only(top: 3), child: Text(summary)),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => RecipePage(recipeId: recipe.id))),
    );
  }
}

class _NewRecipe {
  const _NewRecipe(this.name, this.read, this.deviceId);
  final String name;
  final bool read;
  final String? deviceId;
}

/// Nome + "Ler da máquina" (o caso comum: a máquina já está no ponto e a
/// pessoa quer guardar esse ajuste) ou "Em branco".
class _NewRecipeDialog extends StatefulWidget {
  const _NewRecipeDialog({required this.type});
  final RecipeType type;

  @override
  State<_NewRecipeDialog> createState() => _NewRecipeDialogState();
}

class _NewRecipeDialogState extends State<_NewRecipeDialog> {
  final _name = TextEditingController();
  late String? _device = widget.type.machines.firstOrNull?.deviceId;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _done(bool read) => Navigator.pop(context, _NewRecipe(_name.text.trim(), read, _device));

  @override
  Widget build(BuildContext context) {
    final project = AppScope.of(context).controller.project;
    final machines = [for (final m in widget.type.machines) if (project.device(m.deviceId) != null) m];
    return AlertDialog(
      title: const Text('Nova receita'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          key: const ValueKey('nome-receita'),
          controller: _name,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: 'Nome', hintText: 'Ex.: ${widget.type.name} 120 mm'),
        ),
        if (machines.length > 1) ...[
          const SizedBox(height: Ind.space),
          const SectionHeader('Ler de', padding: EdgeInsets.zero),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final m in machines)
              ChoiceChip(
                label: Text(project.device(m.deviceId)!.name),
                selected: _device == m.deviceId,
                onSelected: (_) => setState(() => _device = m.deviceId),
              ),
          ]),
        ],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        TextButton(key: const ValueKey('receita-em-branco'), onPressed: () => _done(false), child: const Text('Em branco')),
        FilledButton.icon(
          key: const ValueKey('receita-ler'),
          onPressed: machines.isEmpty ? null : () => _done(true),
          icon: const Icon(Icons.download_rounded, size: 18),
          label: const Text('Ler da máquina'),
        ),
      ],
    );
  }
}
