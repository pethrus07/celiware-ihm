import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/ids.dart';
import '../../core/utils/validators.dart';
import '../../models/logic_rule.dart';
import '../../models/project.dart';
import '../../models/tag.dart';
import '../../services/calc/calc_evaluator.dart';
import '../../services/calc/calc_expression.dart';
import '../../services/calc/calc_graph.dart';
import '../../services/runtime/tag_store.dart';
import '../../widgets/common/adaptive.dart';
import '../../widgets/common/common.dart';
import '../../widgets/hmi/live_tags.dart';
import '../tags/calc_expression_field.dart';
import 'rules_page.dart';

/// Cadastro de regra: **Quando** (a condição, escrita como uma conta, com o
/// estado dela ao vivo), **por quanto tempo**, **então** gravar o quê e onde,
/// e **como agir** — perguntar antes (padrão) ou gravar sozinha, só para
/// parar e com o termo aceito (LG-6).
///
/// O destino precisa aceitar escrita por regra (LG-5): escolher um que não
/// aceita pergunta antes de marcar.
///
/// [plant]: regra da planta — as variáveis vêm de todos os projetos
/// ([ProjectController.plantEditorView]; as dos outros com o nome do projeto
/// na frente) e a regra é guardada na planta, não no projeto aberto.
class RuleEditorPage extends StatefulWidget {
  const RuleEditorPage({super.key, this.rule, this.plant = false});
  final LogicRule? rule;
  final bool plant;

  @override
  State<RuleEditorPage> createState() => _RuleEditorPageState();
}

class _RuleEditorPageState extends State<RuleEditorPage> {
  final _form = GlobalKey<FormState>();
  late final String _id = widget.rule?.id ?? newId('r');
  late final _name = TextEditingController(text: widget.rule?.name ?? '');
  final _condition = TextEditingController();
  late final _value = TextEditingController(text: _numText(widget.rule?.value ?? 0));
  late int _hold = widget.rule?.holdSec ?? 10;
  late String _target = widget.rule?.targetTagId ?? '';
  late RuleMode _mode = widget.rule?.mode ?? RuleMode.propose;

  bool _started = false;
  late String _initial;
  bool _triedSave = false;
  AutovalidateMode _autovalidate = AutovalidateMode.disabled;

  late final CalcEvaluator _evaluator = CalcEvaluator(() => _source);

  /// Visão da planta (regra da planta); nula enquanto lê os projetos.
  Project? _plantView;

  /// De onde vêm as variáveis: o projeto aberto, ou a planta inteira.
  Project get _source => widget.plant ? (_plantView ?? const Project()) : AppScope.of(context).controller.project;

  Future<void> _loadPlantView() async {
    final view = await AppScope.of(context).controller.plantEditorView();
    if (!mounted) return;
    final first = _plantView == null;
    setState(() => _plantView = view);
    final r = widget.rule;
    if (first && r != null && !r.condition.isEmpty) {
      _condition.text = CalcGraph.display(r.condition, view);
      _initial = _snapshot();
    }
  }
  TagReading _last = TagReading.waiting;
  Timer? _tick;

  static const _holds = [0, 5, 10, 30, 60, 300];

  static String _numText(double v) => (v == v.roundToDouble() ? v.round().toString() : v.toString()).replaceAll('.', ',');
  double? get _valueNum => double.tryParse(_value.text.trim().replaceAll(',', '.'));

  bool get _editing => widget.rule != null;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final r = widget.rule;
    if (widget.plant) {
      _initial = _snapshot();
      unawaited(_loadPlantView());
      return;
    }
    if (r != null && !r.condition.isEmpty) _condition.text = CalcGraph.display(r.condition, AppScope.of(context).controller.project);
    _initial = _snapshot();
  }

  @override
  void dispose() {
    _tick?.cancel();
    for (final c in [_name, _condition, _value]) {
      c.dispose();
    }
    super.dispose();
  }

  String _snapshot() => jsonEncode([_name.text.trim(), _condition.text.trim(), _value.text.trim(), _hold, _target, _mode.name]);

  (CalcProgram?, CalcError?) _compile(Project p) {
    final text = _condition.text;
    if (text.trim().isEmpty) return (null, _triedSave ? const CalcError('Escreva a condição', 0, 0) : null);
    try {
      final program = CalcProgram.compile(text, CalcGraph.scope(p));
      if (program.type != CalcType.boolean) {
        return (null, CalcError('A condição precisa dar sim ou não: compare, como em [Temperatura] > 85', 0, text.length));
      }
      return (program, null);
    } on CalcError catch (e) {
      return (null, e);
    }
  }

  // ── Destino ───────────────────────────────────────────────────────────────

  Future<void> _pickTarget() async {
    final c = AppScope.of(context).controller;
    final tag = await showModalBottomSheet<Tag>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _TargetSheet(source: widget.plant ? _source : null),
    );
    if (tag == null || !mounted) return;
    if (!tag.acceptsRuleWrite) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const ValueKey('permitir-regra-dialogo'),
          title: Text('Permitir que regras gravem em "${tag.name}"?'),
          content: const Text('Fica marcado na variável ("aceita escrita por regra"). A tela continua igual; só regras usam essa permissão.',
              style: TextStyle(height: 1.4)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
            FilledButton(key: const ValueKey('permitir-regra'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Permitir')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      if (widget.plant) {
        // A variável pode ser de outro projeto: grava no arquivo dele.
        await c.allowRuleWrite(tag.id);
        if (mounted) await _loadPlantView();
        if (!mounted) return;
      } else {
        c.saveTag(tag.copyWith(ruleWritable: true));
      }
    }
    setState(() {
      // Liga/desliga começa em "Desligar": regra existe para parar, não para dar partida.
      if (tag.dataType == TagDataType.bool && tag.id != _target) _value.text = '0';
      _target = tag.id;
    });
  }

  void _setValue(String text) {
    _value.text = text;
    // Gravar sozinha só para parar: valor diferente de zero volta a perguntar.
    if (_mode == RuleMode.automatic && _valueNum != 0) {
      _mode = RuleMode.propose;
      _toast('Gravar sozinha só serve para parar: a regra volta a perguntar antes.');
    }
    setState(() {});
  }

  Future<void> _setMode(RuleMode m) async {
    if (m == _mode) return;
    if (m == RuleMode.propose) {
      setState(() => _mode = m);
      return;
    }
    if (_valueNum != 0) {
      _toast('Gravar sozinha só serve para parar: escolha Desligar ou o valor zero.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('termo-automatico'),
        icon: Icon(Icons.shield_outlined, color: Ind.textFor(Ind.warn)),
        title: const Text('Gravar sem perguntar?'),
        content: const Text(
          'O app não é intertravamento de segurança: o celular pode demorar ou deixar de ler (Wi-Fi, bateria, app fechado), e aí a regra não age. '
          'Use só para parar ou avisar — nunca como proteção de pessoas ou da máquina.',
          style: TextStyle(height: 1.4),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(key: const ValueKey('aceitar-termo'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Entendo e aceito')),
        ],
      ),
    );
    if (ok == true && mounted) setState(() => _mode = RuleMode.automatic);
  }

  void _toast(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  // ── Salvar ────────────────────────────────────────────────────────────────

  String? _targetError(Project p) {
    final t = p.tag(_target);
    if (_target.isEmpty) return 'Escolha onde gravar';
    if (t == null) return 'A variável de destino foi apagada';
    if (!t.canWrite) return '"${t.name}" não pode ser alterada';
    if (!t.acceptsRuleWrite) return '"${t.name}" não aceita escrita por regra: toque para permitir';
    return null;
  }

  void _save() {
    final c = AppScope.of(context).controller;
    final p = _source;
    final nameOk = _form.currentState?.validate() ?? false;
    setState(() {
      _triedSave = true;
      _autovalidate = AutovalidateMode.onUserInteraction;
    });
    final (program, _) = _compile(p);
    final value = _valueNum;
    if (!nameOk || program == null || _targetError(p) != null || value == null) return;
    final rule = LogicRule(
      id: _id,
      name: _name.text.trim(),
      condition: program.spec,
      holdSec: _hold,
      targetTagId: _target,
      value: value,
      mode: _mode,
      enabled: widget.rule?.enabled ?? true,
    );
    if (widget.plant) {
      unawaited(c.savePlantRule(rule));
    } else {
      c.saveRule(rule);
    }
    Navigator.pop(context);
  }

  Future<void> _leave() async {
    if (_snapshot() == _initial) {
      Navigator.pop(context);
      return;
    }
    final choice = await confirmDiscard(context, body: 'O que foi mudado nesta regra ainda não foi salvo.');
    if (!mounted) return;
    switch (choice) {
      case LeaveChoice.save:
        _save();
      case LeaveChoice.discard:
        Navigator.pop(context);
      case LeaveChoice.keep:
        break;
    }
  }

  Future<void> _delete() async {
    final c = AppScope.of(context).controller;
    if (!await confirmDelete(context,
        title: 'Apagar "${widget.rule!.name}"?', body: 'A regra para de vigiar e sai ${widget.plant ? 'da planta' : 'do projeto'}. O histórico fica.')) {
      return;
    }
    if (widget.plant) {
      unawaited(c.deletePlantRule(_id));
    } else {
      c.deleteRule(_id);
    }
    if (mounted) Navigator.pop(context);
  }

  // ── Tela ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.watch(context);
    if (widget.plant && _plantView == null) {
      return Scaffold(appBar: AppBar(title: const Text('Regra da planta')), body: const Center(child: CircularProgressIndicator()));
    }
    final project = _source;
    final (program, error) = _compile(project);
    if (program != null) _last = _evaluator.evaluate('editor', program.spec, scope.runtime.store.read, previous: _last);
    final target = project.tag(_target);
    final targetError = _triedSave ? _targetError(project) : null;
    final isBool = target?.dataType == TagDataType.bool;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: LiveTags(
        tagIds: program == null ? const {} : CalcGraph.expand(project, program.inputIds),
        child: Scaffold(
          appBar: AppBar(
            title: Text(widget.plant ? (_editing ? 'Regra da planta' : 'Nova regra da planta') : (_editing ? 'Regra' : 'Nova regra')),
            actions: [
              if (_editing) IconButton(tooltip: 'Apagar', icon: Icon(Icons.delete_outline_rounded, color: Ind.alarm), onPressed: _delete),
            ],
          ),
          // No tablet, campos e Salvar com no máximo 640 dp (TB-3).
          bottomNavigationBar: FormWidth(child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: FilledButton.icon(key: const ValueKey('salvar-regra'), onPressed: _save, icon: const Icon(Icons.check_rounded), label: const Text('Salvar')),
            ),
          )),
          body: FormWidth(child: Form(
            key: _form,
            autovalidateMode: _autovalidate,
            child: ListView(
              key: const ValueKey('formulario-regra'),
              padding: const EdgeInsets.fromLTRB(Ind.page, 20, Ind.page, 32),
              children: [
                TextFormField(
                  key: const ValueKey('campo-nome-regra'),
                  controller: _name,
                  validator: Validators.name,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: 'O que a regra faz',
                    hintText: 'Ex.: Parar a prensa',
                    helperText: _name.text.trim().isEmpty ? 'Vira a pergunta: "Parar a prensa?"' : 'Vira a pergunta: "${_name.text.trim()}?"',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SectionHeader('Quando', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)),
                CalcExpressionField(
                  controller: _condition,
                  error: error,
                  label: 'Condição',
                  hint: 'Ex.: [Temperatura do motor] > 85',
                  source: widget.plant ? project : null,
                  onChanged: () => setState(() {}),
                ),
                if (program != null) _ConditionNow(reading: _last),
                const SectionHeader('Por quanto tempo', padding: EdgeInsets.fromLTRB(0, 24, 0, 10)),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final s in {..._holds, _hold}.toList()..sort())
                    ChoiceChip(
                      key: ValueKey('durar-$s'),
                      label: Text(s == 0 ? 'Na hora' : RulesPage.holdLabel(s)),
                      selected: _hold == s,
                      onSelected: (_) => setState(() => _hold = s),
                    ),
                ]),
                const SizedBox(height: 6),
                Text('A condição precisa ficar esse tempo seguido: um pico de uma leitura não dispara nada.',
                    style: TextStyle(color: Ind.textMuted, fontSize: 12.5, height: 1.35)),
                const SectionHeader('Então gravar', padding: EdgeInsets.fromLTRB(0, 24, 0, 12)),
                _TargetRow(tag: target, project: project, error: targetError, onTap: _pickTarget),
                if (target != null) ...[
                  const SizedBox(height: Ind.space),
                  if (isBool)
                    ChoiceCards<int>(
                      options: const [
                        ChoiceOption(value: 0, title: 'Desligar', subtitle: 'Grava DESLIGADO'),
                        ChoiceOption(value: 1, title: 'Ligar', subtitle: 'Grava LIGADO'),
                      ],
                      selected: (_valueNum ?? 0) == 0 ? 0 : 1,
                      onChanged: (v) => _setValue('$v'),
                    )
                  else
                    TextFormField(
                      key: const ValueKey('valor-regra'),
                      controller: _value,
                      keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                      decoration: InputDecoration(labelText: 'Valor a gravar', suffixText: target.unit.isEmpty ? null : target.unit),
                      validator: (t) => double.tryParse((t ?? '').trim().replaceAll(',', '.')) == null ? 'Número' : null,
                      onChanged: _setValue,
                    ),
                ],
                const SectionHeader('Como agir', padding: EdgeInsets.fromLTRB(0, 24, 0, 12)),
                ChoiceCards<RuleMode>(
                  options: const [
                    ChoiceOption(value: RuleMode.propose, title: 'Perguntar antes', subtitle: 'Recomendado: avisa e só grava com o seu toque'),
                    ChoiceOption(value: RuleMode.automatic, title: 'Gravar sozinha', subtitle: 'Só para parar (desligar ou zero)'),
                  ],
                  selected: _mode,
                  onChanged: _setMode,
                ),
              ],
            ),
          )),
        ),
      ),
    );
  }
}

/// "Agora: presente" — a condição com as leituras do momento.
class _ConditionNow extends StatelessWidget {
  const _ConditionNow({required this.reading});
  final TagReading reading;

  @override
  Widget build(BuildContext context) {
    final r = reading;
    final (text, color) = switch (r.quality) {
      TagQuality.good => r.value == true ? ('Agora: a condição está presente', Ind.textFor(Ind.warn)) : ('Agora: a condição não está presente', Ind.textMuted),
      TagQuality.waiting => ('Lendo…', Ind.textMuted),
      _ => (capitalized(r.message), Ind.textFor(Ind.alarm)),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(text, key: const ValueKey('condicao-agora'), style: TextStyle(color: color, fontWeight: FontWeight.w600)),
    );
  }
}

/// A variável de destino numa linha; tocar abre a lista das graváveis.
class _TargetRow extends StatelessWidget {
  const _TargetRow({required this.tag, required this.project, required this.error, required this.onTap});
  final Tag? tag;
  final Project project;
  final String? error;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = tag;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Material(
        color: t == null ? Ind.accent.withValues(alpha: 0.12) : Ind.surfaceHigh,
        borderRadius: BorderRadius.circular(Ind.radiusSmall),
        child: InkWell(
          key: const ValueKey('destino-regra'),
          borderRadius: BorderRadius.circular(Ind.radiusSmall),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: Row(children: [
              Icon(t == null ? Icons.link_rounded : Icons.edit_note_rounded, color: t == null ? Ind.accent : Ind.textDim),
              const SizedBox(width: 14),
              Expanded(
                child: t == null
                    ? Text('Escolher onde gravar', style: TextStyle(color: Ind.accent, fontWeight: FontWeight.w700, fontSize: 16))
                    : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(t.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                        const SizedBox(height: 2),
                        Text('${project.device(t.deviceId)?.name ?? ''} · ${t.acceptsRuleWrite ? 'aceita escrita por regra' : 'não aceita escrita por regra'}',
                            style: TextStyle(color: Ind.textMuted, fontSize: 13)),
                      ]),
              ),
              Icon(Icons.chevron_right_rounded, color: Ind.textMuted),
            ]),
          ),
        ),
      ),
      if (error != null)
        Padding(
          padding: const EdgeInsets.only(top: 6, left: 4),
          child: Text(error!, key: const ValueKey('erro-destino'), style: TextStyle(color: Ind.textFor(Ind.alarm), fontSize: 12.5)),
        ),
    ]);
  }
}

/// As variáveis que a tela pode gravar, agrupadas por equipamento; as que
/// aceitam escrita por regra dizem isso.
class _TargetSheet extends StatelessWidget {
  const _TargetSheet({this.source});

  /// Nulo = o projeto aberto; regra da planta passa a visão da planta.
  final Project? source;

  @override
  Widget build(BuildContext context) {
    final open = AppScope.watch(context).controller.project;
    final project = source ?? open;
    final writable = [for (final t in project.tags) if (t.canWrite && !t.isArray && !t.isText) t];
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 32),
        children: [
          Text('Onde a regra grava?', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (writable.isEmpty)
            Text('Nenhuma variável pode ser alterada pela tela. Marque "Pode ser alterada pela tela" na variável primeiro.',
                style: TextStyle(color: Ind.textDim, height: 1.4)),
          for (final d in project.devices)
            if (writable.any((t) => t.deviceId == d.id)) ...[
              SectionHeader(d.name, padding: const EdgeInsets.fromLTRB(4, 12, 0, 8)),
              for (final t in writable.where((t) => t.deviceId == d.id))
                ListTile(
                  key: ValueKey('destino-${t.id}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(t.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(t.acceptsRuleWrite ? 'Aceita escrita por regra' : 'Não aceita ainda — tocar pede permissão'),
                  trailing: Icon(t.acceptsRuleWrite ? Icons.check_circle_outline_rounded : Icons.lock_outline_rounded, color: Ind.textMuted),
                  onTap: () => Navigator.pop(context, t),
                ),
            ],
        ],
      ),
    );
  }
}
