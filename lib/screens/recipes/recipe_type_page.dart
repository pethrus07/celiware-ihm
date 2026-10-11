import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/ids.dart';
import '../../models/recipe.dart';
import '../../models/tag.dart';
import '../../services/recipes/recipe_logic.dart';
import '../../widgets/common/common.dart';
import '../../widgets/hmi/write_actions.dart';
import '../screens_page.dart' show askText;
import 'recipe_widgets.dart';

/// Folha de criar um tipo de receita (RC-1): nome, máquina e as variáveis
/// graváveis que mudam de um produto para outro. Faixa, tolerância, condição
/// e as outras máquinas ficam no tipo, depois — o primeiro passo é curto.
class RecipeTypeSheet extends StatefulWidget {
  const RecipeTypeSheet({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => const RecipeTypeSheet(),
      );

  @override
  State<RecipeTypeSheet> createState() => _RecipeTypeSheetState();
}

class _RecipeTypeSheetState extends State<RecipeTypeSheet> {
  final _name = TextEditingController();
  final Set<String> _tags = {};
  String? _device;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save(List<Tag> usable) {
    final c = AppScope.of(context).controller;
    final device = _device;
    final chosen = [for (final t in usable) if (_tags.contains(t.id)) t];
    if (device == null) {
      setState(() => _error = 'Cadastre um equipamento com variáveis graváveis primeiro.');
      return;
    }
    if (chosen.isEmpty) {
      setState(() => _error = 'Escolha ao menos uma variável.');
      return;
    }
    final params = [for (final t in chosen) RecipeParam.fromTag(newId('p'), t)];
    final type = RecipeType(
      id: newId('rt'),
      name: _name.text.trim().isEmpty ? 'Receita ${c.project.recipeTypes.length + 1}' : _name.text.trim(),
      params: params,
      machines: [
        RecipeMachine(deviceId: device, tags: {for (var i = 0; i < params.length; i++) params[i].key: chosen[i].id}),
      ],
    );
    c.saveRecipeType(type);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final project = AppScope.of(context).controller.project;
    final devices = [for (final d in project.devices) if (project.tagsOf(d.id).any(RecipeParam.canUse)) d];
    _device ??= devices.firstOrNull?.id;
    final usable = _device == null ? const <Tag>[] : project.tagsOf(_device!).where(RecipeParam.canUse).toList();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.96,
      builder: (context, scroll) => Column(children: [
        Expanded(
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 24),
            children: [
              Text('Novo tipo de receita', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text('O que muda de um produto para outro na máquina.', style: TextStyle(color: Ind.textDim)),
              const SizedBox(height: Ind.space),
              TextField(
                key: const ValueKey('nome-tipo'),
                controller: _name,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Nome', hintText: 'Ex.: Rótulo'),
              ),
              if (devices.length > 1) ...[
                const SizedBox(height: Ind.spaceLarge),
                sheetLabel('Máquina'),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final d in devices)
                    ChoiceChip(
                      key: ValueKey('tipo-maquina-${d.id}'),
                      label: Text(d.name),
                      selected: _device == d.id,
                      onSelected: (_) => setState(() {
                        _device = d.id;
                        _tags.clear();
                      }),
                    ),
                ]),
              ],
              const SizedBox(height: Ind.spaceLarge),
              sheetLabel('Parâmetros'),
              if (usable.isEmpty)
                Text('Nenhuma variável gravável. No cadastro da variável, ligue "Pode ser alterada pela tela".', style: TextStyle(color: Ind.textDim, height: 1.4))
              else
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final t in usable)
                    FilterChip(
                      key: ValueKey('param-${t.id}'),
                      label: Text(t.name),
                      selected: _tags.contains(t.id),
                      onSelected: (on) => setState(() {
                        on ? _tags.add(t.id) : _tags.remove(t.id);
                        _error = null;
                      }),
                    ),
                ]),
            ],
          ),
        ),
        SheetActions(
          error: _error,
          child: FilledButton.icon(
            key: const ValueKey('salvar-tipo'),
            onPressed: () => _save(usable),
            icon: const Icon(Icons.check_rounded),
            label: const Text('Criar'),
          ),
        ),
      ]),
    );
  }
}

/// O tipo de receita: parâmetros (faixa e tolerância) e máquinas (variável de
/// cada parâmetro, condição para aplicar, bit de receita carregada).
class RecipeTypePage extends StatelessWidget {
  const RecipeTypePage({super.key, required this.typeId});
  final String typeId;

  @override
  Widget build(BuildContext context) {
    final c = AppScope.watch(context).controller;
    final p = c.project;
    final type = p.recipeType(typeId);
    if (type == null) return Scaffold(appBar: AppBar());
    final free = [
      for (final d in p.devices)
        if (type.machine(d.id) == null && p.tagsOf(d.id).any(RecipeParam.canUse)) d,
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(type.name),
        actions: [
          IconButton(
            key: const ValueKey('renomear-tipo'),
            tooltip: 'Renomear',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              final name = await askText(context, title: 'Nome do tipo', label: 'Nome', initial: type.name);
              if (name != null) c.saveRecipeType(type.copyWith(name: name));
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          const SectionHeader('Parâmetros'),
          for (final param in type.params)
            ListTile(
              key: ValueKey('parametro-${param.key}'),
              title: Text(param.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(param.limitsLabel),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => RecipeParamSheet.show(context, typeId: type.id, paramKey: param.key),
            ),
          _TextAction(
            key: const ValueKey('mais-parametro'),
            icon: Icons.add_rounded,
            label: 'Parâmetro',
            onTap: () => _addParam(context, type),
          ),
          const SectionHeader('Máquinas'),
          for (final m in type.machines) _MachineTile(type: type, machine: m),
          if (free.isNotEmpty)
            _TextAction(
              key: const ValueKey('ligar-maquina'),
              icon: Icons.add_link_rounded,
              label: 'Ligar outra máquina',
              onTap: () => addMachine(context, type),
            ),
          const SizedBox(height: Ind.spaceLarge),
          _TextAction(
            key: const ValueKey('apagar-tipo'),
            icon: Icons.delete_outline_rounded,
            label: 'Apagar tipo de receita',
            color: Ind.textFor(Ind.alarm),
            onTap: () async {
              final n = p.recipesOf(type.id).length;
              final ok = await confirmDelete(
                context,
                title: 'Apagar "${type.name}"?',
                body: n == 0 ? 'Nenhuma receita usa este tipo.' : n == 1 ? 'A receita deste tipo também é apagada.' : 'As $n receitas deste tipo também são apagadas.',
              );
              if (!ok || !context.mounted) return;
              c.deleteRecipeType(type.id);
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }

  /// Parâmetro novo, escolhido entre as variáveis graváveis da primeira
  /// máquina. Nas outras ele aparece como "falta escolher a variável".
  static Future<void> _addParam(BuildContext context, RecipeType type) async {
    final c = AppScope.of(context).controller;
    final m = type.machines.where((m) => c.project.device(m.deviceId) != null).firstOrNull;
    if (m == null) {
      WriteActions.toast(context, 'Ligue uma máquina primeiro.');
      return;
    }
    final used = m.tags.values.toSet();
    final tags = [for (final t in c.project.tagsOf(m.deviceId)) if (RecipeParam.canUse(t) && !used.contains(t.id)) t];
    final pick = await pickTag(context, title: 'Novo parâmetro', tags: tags, empty: 'Todas as variáveis graváveis desta máquina já estão no tipo.');
    final tag = pick?.tagId == null ? null : c.project.tag(pick!.tagId!);
    if (tag == null) return;
    final param = RecipeParam.fromTag(newId('p'), tag);
    c.saveRecipeType(type.upsertParam(param).upsertMachine(m.withTags({...m.tags, param.key: tag.id})));
  }

  /// Liga o tipo a outra máquina, já com as variáveis sugeridas pelo nome,
  /// pela memória ou pelo endereço (transferir, RC-7). Devolve a máquina salva.
  static Future<RecipeMachine?> addMachine(BuildContext context, RecipeType type, {String? deviceId}) async {
    final p = AppScope.of(context).controller.project;
    final free = [
      for (final d in p.devices)
        if (type.machine(d.id) == null && p.tagsOf(d.id).any(RecipeParam.canUse)) d,
    ];
    var id = deviceId ?? (free.length == 1 ? free.single.id : null);
    id ??= await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Qual máquina?'),
        children: [
          for (final d in free)
            SimpleDialogOption(
              key: ValueKey('escolher-maquina-${d.id}'),
              onPressed: () => Navigator.pop(ctx, d.id),
              child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(d.name, style: const TextStyle(fontSize: 16))),
            ),
        ],
      ),
    );
    if (id == null || !context.mounted) return null;
    final from = type.machines.where((m) => p.device(m.deviceId) != null).firstOrNull;
    final suggested = RecipeLogic.suggestBinding(type, p, toDeviceId: id, from: from);
    return RecipeMachineSheet.show(context, typeId: type.id, machine: RecipeMachine(deviceId: id, tags: suggested), isNew: true);
  }
}

class _MachineTile extends StatelessWidget {
  const _MachineTile({required this.type, required this.machine});
  final RecipeType type;
  final RecipeMachine machine;

  @override
  Widget build(BuildContext context) {
    final p = AppScope.of(context).controller.project;
    final problems = RecipeLogic.machineProblems(type, machine, p);
    final m = machine;
    final cond = m.conditionTagId == null ? null : p.tag(m.conditionTagId!);
    final loaded = m.loadedTagId == null ? null : p.tag(m.loadedTagId!);
    final summary = problems.isNotEmpty
        ? problems.length == 1
            ? problems.single
            : '${problems.first} · e mais ${problems.length - 1}'
        : [
            'Pronta',
            if (cond != null) 'só com "${cond.name}" ${m.conditionValue ? 'ligado' : 'desligado'}',
            if (loaded != null) 'liga "${loaded.name}" no fim',
          ].join(' · ');
    return ListTile(
      key: ValueKey('maquina-${m.deviceId}'),
      leading: Icon(problems.isEmpty ? Icons.precision_manufacturing_outlined : Icons.link_off_rounded, color: problems.isEmpty ? Ind.accent : Ind.textFor(Ind.warn)),
      title: Text(p.device(m.deviceId)?.name ?? 'Máquina apagada', style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(summary, style: problems.isEmpty ? null : TextStyle(color: Ind.textFor(Ind.warn))),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: p.device(m.deviceId) == null ? null : () => RecipeMachineSheet.show(context, typeId: type.id, machine: m),
    );
  }
}

class _TextAction extends StatelessWidget {
  const _TextAction({super.key, required this.icon, required this.label, required this.onTap, this.color});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Ind.page - 8, 4, Ind.page, 0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onTap,
            style: color == null ? null : TextButton.styleFrom(foregroundColor: color),
            icon: Icon(icon),
            label: Text(label),
          ),
        ),
      );
}

/// Um parâmetro: nome, unidade, faixa e tolerância da comparação.
class RecipeParamSheet extends StatefulWidget {
  const RecipeParamSheet({super.key, required this.typeId, required this.paramKey});
  final String typeId;
  final String paramKey;

  static Future<void> show(BuildContext context, {required String typeId, required String paramKey}) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => RecipeParamSheet(typeId: typeId, paramKey: paramKey),
      );

  @override
  State<RecipeParamSheet> createState() => _RecipeParamSheetState();
}

class _RecipeParamSheetState extends State<RecipeParamSheet> {
  late final RecipeType _type = AppScope.of(context).controller.project.recipeType(widget.typeId)!;
  late final RecipeParam _param = _type.param(widget.paramKey)!;
  late final _name = TextEditingController(text: _param.name);
  late final _unit = TextEditingController(text: _param.unit);
  late final _min = TextEditingController(text: numberText(_param.min));
  late final _max = TextEditingController(text: numberText(_param.max));
  late final _tol = TextEditingController(text: _param.tolerance == 0 ? '' : numberText(_param.tolerance));
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _unit, _min, _max, _tol]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Campo vazio = sem valor; texto que não é número = erro.
  (double?, String?) _read(TextEditingController c, String what) {
    if (c.text.trim().isEmpty) return (null, null);
    final v = parseNumber(c.text);
    return v == null || !v.isFinite ? (null, '$what: "${c.text.trim()}" não é número') : (v, null);
  }

  void _save() {
    final (lo, e1) = _read(_min, 'Mínimo');
    final (hi, e2) = _read(_max, 'Máximo');
    final (tol, e3) = _read(_tol, 'Tolerância');
    final error = e1 ?? e2 ?? e3 ??
        (lo != null && hi != null && lo > hi ? 'O mínimo passa do máximo.' : null) ??
        (tol != null && tol < 0 ? 'A tolerância não pode ser negativa.' : null);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    final next = _param
        .copyWith(name: _name.text.trim().isEmpty ? _param.name : _name.text.trim(), unit: _unit.text.trim(), tolerance: tol ?? 0)
        .withRange(lo, hi);
    final c = AppScope.of(context).controller;
    c.saveRecipeType((c.project.recipeType(widget.typeId) ?? _type).upsertParam(next));
    Navigator.pop(context);
  }

  Future<void> _remove() async {
    final ok = await confirmDelete(context, title: 'Tirar "${_param.name}"?', body: 'As receitas deixam de usar este valor. Nada é gravado na máquina.');
    if (!ok || !mounted) return;
    final c = AppScope.of(context).controller;
    c.saveRecipeType((c.project.recipeType(widget.typeId) ?? _type).removeParam(_param.key));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final p = _param;
    Widget number(Key key, TextEditingController c, String label, {String? helper}) => TextField(
          key: key,
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          style: Ind.number(20),
          decoration: InputDecoration(labelText: label, helperText: helper, helperMaxLines: 2, suffixText: p.unit.isEmpty ? null : p.unit),
          onChanged: (_) => setState(() => _error = null),
        );

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.96,
      builder: (context, scroll) => Column(children: [
        Expanded(
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 24),
            children: [
              Text('Parâmetro', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Ind.space),
              TextField(key: const ValueKey('param-nome'), controller: _name, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Nome')),
              if (p.onOff) ...[
                const SizedBox(height: Ind.space),
                Text('Liga/desliga: compara ligado com ligado, sem faixa nem tolerância.', style: TextStyle(color: Ind.textDim, height: 1.4)),
              ] else ...[
                const SizedBox(height: Ind.space),
                TextField(key: const ValueKey('param-unidade'), controller: _unit, decoration: const InputDecoration(labelText: 'Unidade', hintText: 'Ex.: m/min')),
                const SizedBox(height: Ind.space),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: number(const ValueKey('param-min'), _min, 'Mínimo')),
                  const SizedBox(width: 12),
                  Expanded(child: number(const ValueKey('param-max'), _max, 'Máximo')),
                ]),
                const SizedBox(height: Ind.space),
                number(const ValueKey('param-tolerancia'), _tol, 'Tolerância', helper: 'Diferença que ainda conta como igual ao comparar. Vazio = exato.'),
              ],
              const SizedBox(height: Ind.spaceLarge),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('tirar-parametro'),
                  onPressed: _remove,
                  style: TextButton.styleFrom(foregroundColor: Ind.textFor(Ind.alarm)),
                  icon: const Icon(Icons.remove_circle_outline_rounded),
                  label: const Text('Tirar parâmetro'),
                ),
              ),
            ],
          ),
        ),
        SheetActions(
          error: _error,
          child: FilledButton.icon(key: const ValueKey('salvar-parametro'), onPressed: _save, icon: const Icon(Icons.check_rounded), label: const Text('Salvar')),
        ),
      ]),
    );
  }
}

/// Uma máquina do tipo: a variável de cada parâmetro e, em "Mais opções", a
/// condição para aplicar e o bit de receita carregada (RC-6).
class RecipeMachineSheet extends StatefulWidget {
  const RecipeMachineSheet({super.key, required this.typeId, required this.machine, this.isNew = false});
  final String typeId;
  final RecipeMachine machine;
  final bool isNew;

  /// Devolve a máquina salva (nula se fechou sem salvar ou desligou).
  static Future<RecipeMachine?> show(BuildContext context, {required String typeId, required RecipeMachine machine, bool isNew = false}) =>
      showModalBottomSheet<RecipeMachine>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => RecipeMachineSheet(typeId: typeId, machine: machine, isNew: isNew),
      );

  @override
  State<RecipeMachineSheet> createState() => _RecipeMachineSheetState();
}

class _RecipeMachineSheetState extends State<RecipeMachineSheet> {
  late final Map<String, String> _tags = {...widget.machine.tags};
  late String? _cond = widget.machine.conditionTagId;
  late bool _condValue = widget.machine.conditionValue;
  late String? _loaded = widget.machine.loadedTagId;
  final _moreKey = GlobalKey();

  RecipeMachine get _draft => RecipeMachine(deviceId: widget.machine.deviceId, tags: _tags, conditionTagId: _cond, conditionValue: _condValue, loadedTagId: _loaded);

  void _save() {
    final c = AppScope.of(context).controller;
    final type = c.project.recipeType(widget.typeId);
    if (type == null) return;
    final m = _draft;
    c.saveRecipeType(type.upsertMachine(m));
    Navigator.pop(context, m);
  }

  Future<void> _remove() async {
    final c = AppScope.of(context).controller;
    final type = c.project.recipeType(widget.typeId);
    final name = c.project.device(widget.machine.deviceId)?.name ?? 'esta máquina';
    if (type == null) return;
    final ok = await confirmDelete(context, title: 'Desligar $name do tipo?', body: 'As receitas continuam; só deixam de valer para $name.');
    if (!ok || !mounted) return;
    c.saveRecipeType(type.removeMachine(widget.machine.deviceId));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final p = AppScope.of(context).controller.project;
    final type = p.recipeType(widget.typeId);
    if (type == null) return const SizedBox();
    final device = p.device(widget.machine.deviceId);
    final tags = p.tagsOf(widget.machine.deviceId);
    final bools = [for (final t in tags) if (t.dataType == TagDataType.bool && !t.isArray) t];
    final cond = _cond == null ? null : p.tag(_cond!);
    final loaded = _loaded == null ? null : p.tag(_loaded!);
    final more = [
      cond == null ? 'Aplica sempre' : 'Só com "${cond.name}" ${_condValue ? 'ligado' : 'desligado'}',
      if (loaded != null) 'liga "${loaded.name}" no fim',
    ].join(' · ');

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.86,
      maxChildSize: 0.96,
      builder: (context, scroll) => Column(children: [
        Expanded(
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 24),
            children: [
              Text(device?.name ?? 'Máquina', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text('A variável de cada parâmetro nesta máquina.', style: TextStyle(color: Ind.textDim)),
              const SizedBox(height: Ind.space),
              for (final param in type.params)
                Builder(builder: (context) {
                  final t = _tags[param.key] == null ? null : p.tag(_tags[param.key]!);
                  final ok = t != null && t.deviceId == widget.machine.deviceId && param.fits(t);
                  return ListTile(
                    key: ValueKey('vinculo-${param.key}'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(param.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text(t != null && ok ? t.name : 'Escolher a variável', style: ok ? null : TextStyle(color: Ind.accent, fontWeight: FontWeight.w600)),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () async {
                      final pick = await pickTag(context, title: param.name, tags: [for (final x in tags) if (param.fits(x)) x], selectedId: _tags[param.key]);
                      if (pick?.tagId != null) setState(() => _tags[param.key] = pick!.tagId!);
                    },
                  );
                }),
              const SizedBox(height: 8),
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  key: _moreKey,
                  initiallyExpanded: _cond != null || _loaded != null,
                  onExpansionChanged: (open) => revealAfterExpand(_moreKey, open),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  title: const Text('Mais opções'),
                  subtitle: Text(more, style: TextStyle(color: Ind.textMuted, fontSize: 13)),
                  children: [
                    ListTile(
                      key: const ValueKey('condicao'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Só aplicar quando'),
                      subtitle: Text(cond == null ? 'Sempre' : '"${cond.name}" ${_condValue ? 'ligado' : 'desligado'}'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () async {
                        final pick = await pickTag(context, title: 'Só aplicar quando', tags: bools, noneLabel: 'Sempre', selectedId: _cond);
                        if (pick != null) setState(() => _cond = pick.tagId);
                      },
                    ),
                    if (cond != null)
                      Wrap(spacing: 8, children: [
                        ChoiceChip(key: const ValueKey('condicao-desligado'), label: const Text('Desligado'), selected: !_condValue, onSelected: (_) => setState(() => _condValue = false)),
                        ChoiceChip(key: const ValueKey('condicao-ligado'), label: const Text('Ligado'), selected: _condValue, onSelected: (_) => setState(() => _condValue = true)),
                      ]),
                    Padding(
                      padding: const EdgeInsets.only(top: 6, bottom: 12),
                      child: Text('Ex.: "Em ciclo" desligado = só com a máquina parada. É uma conferência do app, não um intertravamento: a segurança continua no CLP.',
                          style: TextStyle(color: Ind.textMuted, fontSize: 13, height: 1.4)),
                    ),
                    ListTile(
                      key: const ValueKey('bit-carregada'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Ao terminar, ligar'),
                      subtitle: Text(loaded?.name ?? 'Nada'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () async {
                        final pick = await pickTag(context, title: 'Ao terminar, ligar', tags: [for (final t in bools) if (t.canWrite) t], noneLabel: 'Nada', selectedId: _loaded);
                        if (pick != null) setState(() => _loaded = pick.tagId);
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('Bit de "receita carregada": desliga no começo e liga só se tudo foi gravado e conferido.',
                          style: TextStyle(color: Ind.textMuted, fontSize: 13, height: 1.4)),
                    ),
                  ],
                ),
              ),
              if (!widget.isNew) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('tirar-maquina'),
                    onPressed: _remove,
                    style: TextButton.styleFrom(foregroundColor: Ind.textFor(Ind.alarm)),
                    icon: const Icon(Icons.link_off_rounded),
                    label: const Text('Desligar do tipo'),
                  ),
                ),
              ],
            ],
          ),
        ),
        SheetActions(
          child: FilledButton.icon(key: const ValueKey('salvar-maquina'), onPressed: _save, icon: const Icon(Icons.check_rounded), label: const Text('Salvar')),
        ),
      ]),
    );
  }
}
