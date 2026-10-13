import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/ids.dart';
import '../../models/project.dart';
import '../../models/recipe.dart';
import '../../models/tag.dart';
import '../../services/recipes/recipe_applier.dart';
import '../../services/recipes/recipe_history.dart';
import '../../services/recipes/recipe_logic.dart';
import '../../services/runtime/hmi_runtime.dart';
import '../../widgets/common/adaptive.dart';
import '../../widgets/common/common.dart';
import '../../widgets/hmi/write_actions.dart';
import '../screens_page.dart' show askText;
import 'recipe_apply_sheet.dart';
import 'recipe_type_page.dart';
import 'recipe_widgets.dart';

/// Uma receita: os valores (tocar edita), e as três ações com a máquina —
/// **Comparar** e **Aplicar** à vista; **Ler da máquina** no menu, junto de
/// versões, transferir, renomear, duplicar e apagar.
class RecipePage extends StatefulWidget {
  const RecipePage({super.key, required this.recipeId, this.deviceId, this.readOnOpen = false});
  final String recipeId;

  /// Máquina escolhida ao abrir (nulo = a primeira do tipo).
  final String? deviceId;

  /// Receita recém-criada com "Ler da máquina": lê assim que abre.
  final bool readOnOpen;

  @override
  State<RecipePage> createState() => _RecipePageState();
}

class _RecipePageState extends State<RecipePage> {
  late String? _device = widget.deviceId;
  String? _busy;
  HmiRuntime? _runtime;

  @override
  void initState() {
    super.initState();
    if (widget.readOnOpen) WidgetsBinding.instance.addPostFrameCallback((_) => _read());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _runtime ??= AppScope.of(context).runtime;
  }

  @override
  void dispose() {
    // Conexões abertas só para ler a receita (equipamento sem tela aberta).
    _runtime?.releaseIdle();
    super.dispose();
  }

  Project get _project => AppScope.of(context).controller.project;
  Recipe? get _recipe => _project.recipe(widget.recipeId);
  RecipeType? get _type => _recipe == null ? null : _project.recipeType(_recipe!.typeId);

  /// Máquinas do tipo que ainda existem no projeto.
  List<RecipeMachine> _machines(RecipeType t, Project p) => [for (final m in t.machines) if (p.device(m.deviceId) != null) m];

  RecipeMachine? _machineOf(RecipeType t, Project p) {
    final ms = _machines(t, p);
    return ms.where((m) => m.deviceId == _device).firstOrNull ?? ms.firstOrNull;
  }

  RecipeApplier get _applier => RecipeApplier(AppScope.of(context).runtime);

  Future<T?> _working<T>(String what, Future<T> Function() job) async {
    setState(() => _busy = what);
    try {
      return await job();
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  // ── Ler da máquina (RC-3) ───────────────────────────────────────────────────

  Future<void> _read() async {
    final type = _type, recipe = _recipe;
    final machine = type == null ? null : _machineOf(type, _project);
    if (type == null || recipe == null || machine == null) return;
    final snap = await _working('Lendo a máquina…', () => _applier.read(type, machine));
    if (snap == null || !mounted) return;
    if (!snap.ok) {
      WriteActions.toast(context, 'Não consegui ler: ${snap.commError}.', error: true);
      return;
    }
    // Dentro da tolerância fica o valor da receita: ruído de leitura não
    // vira versão nova.
    final current = _recipe ?? recipe;
    final next = {...current.values};
    final changed = <RecipeParam>[];
    for (final p in type.params) {
      final v = snap.values[p.key];
      if (v == null) continue;
      final old = current.values[p.key];
      if (old != null && p.same(v, old)) continue;
      next[p.key] = p.clean(v);
      changed.add(p);
    }
    final missed = [for (final p in type.params) if (snap.problems.containsKey(p.key)) '"${p.name}" (${snap.problems[p.key]})'];
    final tail = missed.isEmpty ? '' : ' Não leu ${missed.join(', ')}${current.values.isEmpty ? '' : ': ficou o valor antigo'}.';
    if (changed.isEmpty) {
      WriteActions.toast(context, current.values.isEmpty ? 'Nada foi lido.$tail' : 'Nada mudou: a receita já está igual à máquina.$tail', error: missed.isNotEmpty);
      return;
    }
    if (current.values.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(Icons.download_rounded, color: Ind.accent),
          title: const Text('Atualizar a receita?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final p in changed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text('${p.name}: ${p.format(current.values[p.key])} → ${p.format(next[p.key])}', style: const TextStyle(height: 1.35)),
              ),
            const SizedBox(height: 10),
            Text('A versão atual fica guardada em Versões.', style: TextStyle(color: Ind.textMuted, fontSize: 13)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(key: const ValueKey('confirmar-atualizar'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Atualizar')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final c = AppScope.of(context).controller;
    c.saveRecipe((_recipe ?? current).revise(next, note: Recipe.noteRead, at: clock.now()));
    WriteActions.toast(context, '${changed.length == 1 ? '1 valor lido' : '${changed.length} valores lidos'} da máquina.$tail', error: missed.isNotEmpty);
  }

  // ── Comparar (RC-4) ─────────────────────────────────────────────────────────

  Future<void> _compare() async {
    final type = _type, recipe = _recipe;
    final machine = type == null ? null : _machineOf(type, _project);
    if (type == null || recipe == null || machine == null) return;
    final snap = await _working('Lendo a máquina…', () => _applier.read(type, machine));
    if (snap == null || !mounted) return;
    final apply = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _CompareSheet(type: type, recipe: recipe, snapshot: snap, machineName: _project.device(machine.deviceId)?.name ?? ''),
    );
    if (apply == true && mounted) await _apply();
  }

  // ── Aplicar (RC-5, RC-6) ────────────────────────────────────────────────────

  Future<void> _apply() async {
    final type = _type, recipe = _recipe;
    final machine = type == null ? null : _machineOf(type, _project);
    if (type == null || recipe == null || machine == null) return;
    final applier = _applier;
    final history = RecipeHistoryStore.beside(AppScope.of(context).controller.repository);
    final plan = await _working('Lendo a máquina…', () => applier.prepare(type: type, machine: machine, recipe: recipe));
    if (plan == null || !mounted) return;
    await RecipeApplySheet.show(context, plan: plan, applier: applier, history: history);
  }

  // ── Transferir (RC-7) ───────────────────────────────────────────────────────

  /// Outra máquina com o mesmo tipo: escolhe; se faltam variáveis, liga
  /// (com sugestão) e já abre a aplicação lá.
  Future<void> _transfer() async {
    final type = _type;
    if (type == null) return;
    final p = _project;
    final here = _machineOf(type, p)?.deviceId;
    final others = [
      for (final d in p.devices)
        if (d.id != here && (type.machine(d.id) != null || p.tagsOf(d.id).any(RecipeParam.canUse))) d,
    ];
    if (others.isEmpty) {
      WriteActions.toast(context, 'Não há outra máquina com variáveis graváveis no projeto.');
      return;
    }
    final id = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 16), children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 4),
            child: Text('Transferir para outra máquina', style: Theme.of(ctx).textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 8),
            child: Text('Mesma receita, gravada nas variáveis da outra máquina.', style: TextStyle(color: Ind.textDim)),
          ),
          for (final d in others)
            Builder(builder: (ctx) {
              final m = type.machine(d.id);
              final problems = m == null ? null : RecipeLogic.machineProblems(type, m, p);
              return ListTile(
                key: ValueKey('transferir-${d.id}'),
                leading: const Icon(Icons.precision_manufacturing_outlined),
                title: Text(d.name),
                subtitle: Text(problems == null
                    ? 'Escolher as variáveis desta máquina'
                    : problems.isEmpty
                        ? 'Pronta'
                        : problems.first),
                onTap: () => Navigator.pop(ctx, d.id),
              );
            }),
        ]),
      ),
    );
    if (id == null || !mounted) return;
    var m = type.machine(id);
    if (m == null) {
      m = await RecipeTypePage.addMachine(context, type, deviceId: id);
    } else if (RecipeLogic.machineProblems(type, m, p).isNotEmpty) {
      m = await RecipeMachineSheet.show(context, typeId: type.id, machine: m);
    }
    if (m == null || !mounted) return;
    setState(() => _device = id);
    final now = _type;
    if (now != null && RecipeLogic.machineProblems(now, m, _project).isEmpty) await _apply();
  }

  // ── Valores ─────────────────────────────────────────────────────────────────

  Future<void> _edit(RecipeType type, Recipe recipe, RecipeParam p, Tag? tag) async {
    final old = recipe.values[p.key];
    double? v;
    if (p.onOff) {
      v = await showDialog<double>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text(p.name),
          children: [
            for (final (value, label) in const [(1.0, 'LIGADO'), (0.0, 'DESLIGADO')])
              SimpleDialogOption(
                key: ValueKey('valor-${label.toLowerCase()}'),
                onPressed: () => Navigator.pop(ctx, value),
                child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
              ),
          ],
        ),
      );
    } else {
      v = await showDialog<double>(context: context, builder: (_) => _ValueDialog(param: p, tag: tag, initial: old));
    }
    if (v == null || !mounted) return;
    final c = AppScope.of(context).controller;
    final now = _recipe ?? recipe;
    c.saveRecipe(now.revise({...now.values, p.key: v}, note: Recipe.noteEdited, at: clock.now(), coalesce: true));
  }

  Future<void> _menu(String action, RecipeType type, Recipe recipe) async {
    final c = AppScope.of(context).controller;
    switch (action) {
      case 'ler':
        await _read();
      case 'transferir':
        await _transfer();
      case 'versoes':
        await showModalBottomSheet<void>(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => _VersionsSheet(recipeId: recipe.id));
      case 'renomear':
        final name = await askText(context, title: 'Nome da receita', label: 'Nome', initial: recipe.name);
        if (name != null) c.saveRecipe((_recipe ?? recipe).copyWith(name: name));
      case 'duplicar':
        final name = await askText(context, title: 'Nome da cópia', label: 'Nome', initial: '${recipe.name} (cópia)');
        if (name == null || !mounted) return;
        final copy = recipe.duplicate(id: newId('rc'), name: name, at: clock.now());
        c.saveRecipe(copy);
        await Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => RecipePage(recipeId: copy.id, deviceId: _device)));
      case 'apagar':
        final ok = await confirmDelete(context, title: 'Apagar "${recipe.name}"?', body: 'As versões guardadas também são apagadas. Nada muda na máquina.');
        if (!ok || !mounted) return;
        Navigator.pop(context);
        c.deleteRecipe(recipe.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AppScope.watch(context).controller.project;
    final recipe = p.recipe(widget.recipeId);
    final type = recipe == null ? null : p.recipeType(recipe.typeId);
    if (recipe == null || type == null) return Scaffold(appBar: AppBar());
    final machines = _machines(type, p);
    final machine = _machineOf(type, p);
    final problems = machine == null ? const ['Este tipo não está ligado a nenhuma máquina'] : RecipeLogic.machineProblems(type, machine, p);
    final busy = _busy != null;
    final updated = recipe.updatedAt;

    return Scaffold(
      appBar: AppBar(
        title: AdaptiveTitle(recipe.name),
        bottom: busy ? const PreferredSize(preferredSize: Size.fromHeight(3), child: LinearProgressIndicator(minHeight: 3)) : null,
        actions: [
          PopupMenuButton<String>(
            key: const ValueKey('menu-receita'),
            enabled: !busy,
            onSelected: (a) => _menu(a, type, recipe),
            itemBuilder: (_) => [
              if (machine != null) const PopupMenuItem(key: ValueKey('ler-maquina'), value: 'ler', child: Text('Ler da máquina')),
              const PopupMenuItem(key: ValueKey('transferir'), value: 'transferir', child: Text('Transferir para outra máquina')),
              const PopupMenuItem(key: ValueKey('versoes'), value: 'versoes', child: Text('Versões')),
              const PopupMenuItem(key: ValueKey('renomear-receita'), value: 'renomear', child: Text('Renomear')),
              const PopupMenuItem(key: ValueKey('duplicar-receita'), value: 'duplicar', child: Text('Duplicar')),
              const PopupMenuItem(key: ValueKey('apagar-receita'), value: 'apagar', child: Text('Apagar')),
            ],
          ),
        ],
      ),
      // No tablet, valores, Comparar e Aplicar com no máximo 640 dp (TB-3).
      body: FormWidth(child: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        children: [
          if (machines.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(Ind.page, 4, Ind.page, 8),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                for (final m in machines)
                  ChoiceChip(
                    key: ValueKey('maquina-chip-${m.deviceId}'),
                    label: Text(p.device(m.deviceId)!.name),
                    selected: m.deviceId == machine?.deviceId,
                    onSelected: busy ? null : (_) => setState(() => _device = m.deviceId),
                  ),
              ]),
            )
          else if (machine != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Ind.page, 4, Ind.page, 8),
              child: Text('Em ${p.device(machine.deviceId)!.name}', style: TextStyle(color: Ind.textDim)),
            ),
          if (problems.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(Ind.page, 4, Ind.page, 8),
              child: SuggestionTile(
                icon: Icons.link_off_rounded,
                text: '${problems.first}${problems.length > 1 ? ' (e mais ${problems.length - 1})' : ''}. Toque para ajustar o tipo.',
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => RecipeTypePage(typeId: type.id))),
              ),
            ),
          if (recipe.values.isEmpty && machine != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Ind.page, 8, Ind.page, 8),
              child: Container(
                padding: const EdgeInsets.all(Ind.space),
                decoration: Ind.card(),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Esta receita ainda não tem valores.', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text('Ajuste a máquina e leia, ou toque em cada valor para digitar.', style: TextStyle(color: Ind.textDim, height: 1.4)),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    key: const ValueKey('ler-maquina-vazia'),
                    onPressed: busy ? null : _read,
                    icon: const Icon(Icons.download_rounded),
                    label: const Text('Ler da máquina'),
                  ),
                ]),
              ),
            ),
          for (final param in type.params)
            Builder(builder: (context) {
              final v = recipe.values[param.key];
              final tagId = machine?.tags[param.key];
              final tag = tagId == null ? null : p.tag(tagId);
              final problem = v == null ? null : RecipeLogic.valueProblem(param, v, tag: tag);
              return ListTile(
                key: ValueKey('valor-${param.key}'),
                title: Text(param.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: problem == null ? null : Text(problem, style: TextStyle(color: Ind.textFor(Ind.alarm))),
                trailing: Text(param.format(v), style: Ind.number(20, color: v == null ? Ind.textMuted : Ind.text)),
                onTap: busy ? null : () => _edit(type, recipe, param, tag),
              );
            }),
          if (updated != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Ind.page - 8, 12, Ind.page, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('versao-receita'),
                  onPressed: busy ? null : () => _menu('versoes', type, recipe),
                  child: Text('Versão ${recipe.version} · ${recipe.note.isEmpty ? 'alterada' : recipe.note.toLowerCase()} ${whenLabel(updated)}',
                      style: TextStyle(color: Ind.textMuted, fontWeight: FontWeight.w500)),
                ),
              ),
            ),
        ],
      )),
      bottomNavigationBar: FormWidth(child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Ind.page, 8, Ind.page, 12),
          child: Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const ValueKey('comparar'),
                onPressed: busy || machine == null ? null : _compare,
                icon: const Icon(Icons.compare_arrows_rounded),
                label: const Text('Comparar'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                key: const ValueKey('aplicar'),
                onPressed: busy || machine == null ? null : _apply,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Aplicar'),
              ),
            ),
          ]),
        ),
      )),
    );
  }
}

/// Valor digitado, conferido contra a faixa da receita e contra o que a
/// variável da máquina aceita (passo da escala, tipo).
class _ValueDialog extends StatefulWidget {
  const _ValueDialog({required this.param, this.tag, this.initial});
  final RecipeParam param;
  final Tag? tag;
  final double? initial;

  @override
  State<_ValueDialog> createState() => _ValueDialogState();
}

class _ValueDialogState extends State<_ValueDialog> {
  late final _text = TextEditingController(text: widget.initial == null ? '' : RecipeParam.number(widget.initial!, 0));
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _ok() {
    final v = parseNumber(_text.text);
    if (v == null) {
      setState(() => _error = 'Digite um número.');
      return;
    }
    final problem = RecipeLogic.valueProblem(widget.param, v, tag: widget.tag);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.param;
    final limits = switch ((p.min, p.max)) {
      (null, null) => null,
      (final a?, null) => 'A partir de ${p.format(a)}',
      (null, final b?) => 'Até ${p.format(b)}',
      (final a?, final b?) => 'De ${p.format(a, withUnit: false)} a ${p.format(b)}',
    };
    return AlertDialog(
      title: Text(p.name),
      content: TextField(
        key: const ValueKey('campo-valor'),
        controller: _text,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        style: Ind.number(24),
        decoration: InputDecoration(suffixText: p.unit.isEmpty ? null : p.unit, helperText: limits, errorText: _error, errorMaxLines: 3),
        onChanged: (_) => setState(() => _error = null),
        onSubmitted: (_) => _ok(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(key: const ValueKey('ok-valor'), onPressed: _ok, child: const Text('OK')),
      ],
    );
  }
}

/// Resultado da comparação (RC-4): só as diferenças à vista.
class _CompareSheet extends StatelessWidget {
  const _CompareSheet({required this.type, required this.recipe, required this.snapshot, required this.machineName});
  final RecipeType type;
  final Recipe recipe;
  final MachineSnapshot snapshot;
  final String machineName;

  @override
  Widget build(BuildContext context) {
    final all = RecipeLogic.compare(type, recipe.values, snapshot);
    final diff = RecipeLogic.differences(all);
    final unread = all.where((d) => d.state == RecipeDiffState.unreadable).toList();
    final noValue = all.where((d) => d.state == RecipeDiffState.noValue).toList();
    final same = all.where((d) => d.state == RecipeDiffState.same).length;
    final allSame = snapshot.ok && diff.isEmpty && unread.isEmpty && noValue.isEmpty;

    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 16),
        children: [
          Text('Máquina × receita', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('$machineName · "${recipe.name}"', style: TextStyle(color: Ind.textDim)),
          const SizedBox(height: Ind.space),
          if (!snapshot.ok)
            _row(Icons.error_rounded, Ind.textFor(Ind.alarm), 'Sem comunicação: ${snapshot.commError}', key: const ValueKey('comparar-sem-comunicacao')),
          if (allSame) ...[
            Row(key: const ValueKey('comparar-igual'), children: [
              Icon(Icons.check_circle_rounded, color: Ind.textFor(Ind.ok), size: 28),
              const SizedBox(width: 12),
              const Expanded(child: Text('A máquina está com esta receita', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600))),
            ]),
            const SizedBox(height: 6),
            Text('Dentro da tolerância de cada parâmetro.', style: TextStyle(color: Ind.textMuted)),
          ],
          if (diff.isNotEmpty) ...[
            sheetLabel(diff.length == 1 ? '1 diferença' : '${diff.length} diferenças'),
            for (final d in diff)
              Padding(
                key: ValueKey('diferenca-${d.param.key}'),
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(d.param.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text.rich(TextSpan(children: [
                    TextSpan(text: 'Na máquina ', style: TextStyle(color: Ind.textMuted)),
                    TextSpan(text: d.param.format(d.machine), style: Ind.number(17)),
                    TextSpan(text: '   na receita ', style: TextStyle(color: Ind.textMuted)),
                    TextSpan(text: d.param.format(d.recipe), style: Ind.number(17, color: Ind.accent)),
                  ])),
                ]),
              ),
          ],
          for (final d in unread) _row(Icons.help_outline_rounded, Ind.textFor(Ind.warn), '${d.param.name}: não deu para ler (${d.message})'),
          for (final d in noValue) _row(Icons.edit_off_rounded, Ind.textDim, '${d.param.name}: sem valor na receita'),
          if (same > 0 && !allSame)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(same == 1 ? 'O outro está igual.' : 'Os outros $same estão iguais.', style: TextStyle(color: Ind.textMuted, fontSize: 13)),
            ),
          const SizedBox(height: Ind.spaceLarge),
          if (diff.isNotEmpty)
            FilledButton.icon(
              key: const ValueKey('comparar-aplicar'),
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Aplicar a receita'),
            ),
          TextButton(key: const ValueKey('fechar-comparacao'), onPressed: () => Navigator.pop(context, false), child: const Text('Fechar')),
        ],
      ),
    );
  }

  static Widget _row(IconData icon, Color color, String text, {Key? key}) => Padding(
        key: key,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
        ]),
      );
}

/// Últimas versões (RC-7). Tocar numa antiga mostra os valores e oferece
/// restaurar — como versão nova, sem apagar nada.
class _VersionsSheet extends StatelessWidget {
  const _VersionsSheet({required this.recipeId});
  final String recipeId;

  @override
  Widget build(BuildContext context) {
    final c = AppScope.watch(context).controller;
    final recipe = c.project.recipe(recipeId);
    final type = recipe == null ? null : c.project.recipeType(recipe.typeId);
    if (recipe == null || type == null) return const SizedBox();
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.92,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 4),
            child: Text('Versões', style: Theme.of(context).textTheme.titleLarge),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 8),
            child: Text('As últimas ${Recipe.maxVersions} ficam guardadas.', style: TextStyle(color: Ind.textDim)),
          ),
          for (final v in recipe.versions)
            ListTile(
              key: ValueKey('versao-${v.version}'),
              leading: Icon(v.version == recipe.version ? Icons.radio_button_checked_rounded : Icons.history_rounded, color: v.version == recipe.version ? Ind.accent : Ind.textDim),
              title: Text('Versão ${v.version}${v.version == recipe.version ? ' · atual' : ''}', style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text([if (v.note.isNotEmpty) v.note, if (v.at != null) whenLabel(v.at!)].join(' · ')),
              onTap: v.version == recipe.version ? null : () => _restore(context, type, recipe, v),
            ),
        ],
      ),
    );
  }

  static Future<void> _restore(BuildContext context, RecipeType type, Recipe recipe, RecipeVersion v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Versão ${v.version}'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final p in type.params)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text(
                '${p.name}: ${p.format(v.values[p.key])}${v.values[p.key] == recipe.values[p.key] ? '' : '  (atual: ${p.format(recipe.values[p.key])})'}',
                style: const TextStyle(height: 1.35),
              ),
            ),
          const SizedBox(height: 10),
          Text('Restaurar cria uma versão nova; a atual continua guardada.', style: TextStyle(color: Ind.textMuted, fontSize: 13)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(key: const ValueKey('restaurar-versao'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Restaurar')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final c = AppScope.of(context).controller;
    final now = c.project.recipe(recipe.id) ?? recipe;
    final next = now.restore(v, at: clock.now());
    c.saveRecipe(next);
    WriteActions.toast(context, next.version == now.version ? 'Os valores já eram esses.' : 'Versão ${v.version} restaurada como versão ${next.version}.');
    Navigator.pop(context);
  }
}
