import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/ids.dart';
import '../../core/utils/validators.dart';
import '../../models/alarm.dart';
import '../../models/calc.dart';
import '../../models/narration.dart';
import '../../models/project.dart';
import '../../models/tag.dart';
import '../../services/calc/calc_evaluator.dart';
import '../../services/calc/calc_expression.dart';
import '../../services/calc/calc_graph.dart';
import '../../services/runtime/tag_codec.dart';
import '../../services/runtime/tag_store.dart';
import '../../widgets/common/adaptive.dart';
import '../../widgets/common/common.dart';
import '../../widgets/hmi/live_tags.dart';
import 'alarm_editor.dart';
import 'calc_expression_field.dart';
import 'narration_editor.dart';
import 'tag_uses.dart';

/// Cadastro de variável calculada (LG-1 a LG-3).
///
/// Enxuto: nome, a conta e o resultado ao vivo no topo — o "Lendo agora" das
/// calculadas: as entradas da conta ficam sendo lidas enquanto o cadastro está
/// aberto, e cada letra digitada refaz a conta. A conta se escreve por toque
/// (**Variável** cita sem digitar o nome; **Função ou sinal** traz o que o
/// teclado esconde) e o erro aparece na hora, com o trecho marcado.
///
/// A variável é sempre só leitura: aparece em qualquer elemento, tem alarme,
/// narração e entra no registro de dados, mas nada grava nela. "A usa B que
/// usa A" é recusado ao salvar.
class CalcTagFormPage extends StatefulWidget {
  const CalcTagFormPage({super.key, this.tag});

  /// Calculada a editar; nula = nova.
  final Tag? tag;

  @override
  State<CalcTagFormPage> createState() => _CalcTagFormPageState();
}

class _CalcTagFormPageState extends State<CalcTagFormPage> {
  final _form = GlobalKey<FormState>();
  final _scroll = ScrollController();
  final _more = ExpansibleController();
  final _moreKey = GlobalKey();
  final _nameAnchor = GlobalKey();
  final _exprAnchor = GlobalKey();

  late final String _id = widget.tag?.id ?? newId('t');
  late final _name = TextEditingController(text: widget.tag?.name ?? '');
  final _expr = TextEditingController();
  late final _unit = TextEditingController(text: widget.tag?.unit ?? '');
  late final _description = TextEditingController(text: widget.tag?.description ?? '');

  /// Uma casa de partida: conta com divisão quase sempre quer vírgula.
  late int _decimals = widget.tag?.decimals ?? 1;
  late List<AlarmRule> _alarms = widget.tag?.alarms ?? const [];
  late List<EventNarration> _narrations = widget.tag?.narrations ?? const [];

  bool _started = false;
  late String _initialSnapshot;

  /// "Escreva a conta" só depois de tentar salvar: campo vazio não é erro.
  bool _triedSave = false;
  AutovalidateMode _autovalidate = AutovalidateMode.disabled;

  late final CalcEvaluator _evaluator = CalcEvaluator(() => AppScope.of(context).controller.project);
  TagReading _last = TagReading.waiting;
  Timer? _tick;

  static const _unitPresets = ['%', '°C', 'un/h', 'm/min', 'rpm', 'bar', 'A', 'kW'];

  bool get _editing => widget.tag != null;

  @override
  void initState() {
    super.initState();
    // A conta refaz sozinha: entrada nova, taxa andando com o relógio.
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final calc = widget.tag?.calc;
    if (calc != null) _expr.text = CalcGraph.display(calc, AppScope.of(context).controller.project);
    _initialSnapshot = _snapshot();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _more.dispose();
    _scroll.dispose();
    for (final c in [_name, _expr, _unit, _description]) {
      c.dispose();
    }
    super.dispose();
  }

  // ── Conta ─────────────────────────────────────────────────────────────────

  /// A conta como está no campo: programa conferido, ou o erro.
  (CalcProgram?, CalcError?) _compile(Project p) {
    final text = _expr.text;
    if (text.trim().isEmpty) return (null, _triedSave ? const CalcError('Escreva a conta', 0, 0) : null);
    try {
      return (CalcProgram.compile(text, CalcGraph.scope(p)), null);
    } on CalcError catch (e) {
      return (null, e);
    }
  }

  /// A variável como está no formulário. Sem conta válida, fica com o tipo de
  /// antes (o alarme e a narração não piscam enquanto se digita).
  Tag _draft(CalcProgram? program) {
    final wasBool = widget.tag?.dataType == TagDataType.bool;
    final isBool = program == null ? wasBool : program.type == CalcType.boolean;
    return Tag(
      id: _id,
      name: _name.text.trim().isEmpty ? 'Calculada' : _name.text.trim(),
      deviceId: CalcDevice.id,
      dataType: isBool ? TagDataType.bool : TagDataType.float32,
      unit: isBool ? '' : _unit.text.trim(),
      decimals: isBool ? 0 : _decimals,
      description: _description.text.trim(),
      alarms: _alarms,
      narrations: _narrations,
      calc: program?.spec ?? widget.tag?.calc ?? const CalcSpec(expression: ''),
    ).normalized();
  }

  /// O círculo que a conta fecharia, já como erro do campo.
  CalcError? _cycleError(Project p, Tag draft) {
    final path = CalcGraph.cycle(p, draft);
    return path == null ? null : CalcError(CalcGraph.cycleMessage(p, draft, path), 0, _expr.text.length);
  }

  // ── Alteração pendente ────────────────────────────────────────────────────

  String _snapshot() => jsonEncode([
        _name.text.trim(),
        _expr.text.trim(),
        _unit.text.trim(),
        _decimals,
        _description.text.trim(),
        [for (final a in _alarms) a.toJson()],
        [for (final n in _narrations) n.toJson()],
      ]);

  bool get _dirty => _snapshot() != _initialSnapshot;

  Future<void> _leave() async {
    if (!_dirty) {
      Navigator.pop(context);
      return;
    }
    final choice = await confirmDiscard(context, body: 'O que foi mudado nesta variável ainda não foi salvo.');
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

  // ── Salvar e apagar ───────────────────────────────────────────────────────

  void _save() {
    final c = AppScope.of(context).controller;
    final project = c.project;
    final nameOk = _form.currentState?.validate() ?? false;
    setState(() {
      _triedSave = true;
      _autovalidate = AutovalidateMode.onUserInteraction;
    });
    if (!nameOk) {
      _scrollTo(_nameAnchor);
      return;
    }
    final (program, _) = _compile(project);
    if (program == null) {
      _scrollTo(_exprAnchor);
      return;
    }
    final draft = _draft(program);
    if (_cycleError(project, draft) != null) {
      _scrollTo(_exprAnchor);
      return;
    }
    // O equipamento virtual nasce com a primeira calculada.
    if (project.device(CalcDevice.id) == null) c.saveDevice(CalcDevice.device);
    c.saveTag(draft);
    Navigator.pop(context, draft);
  }

  void _scrollTo(GlobalKey anchor) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = anchor.currentContext;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(ctx, alignment: 0.2, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
      }
    });
  }

  /// O mesmo aviso do cadastro de variável: telas, contas e regras que usam
  /// esta calculada.
  Future<void> _delete() async {
    final c = AppScope.of(context).controller;
    if (!await confirmDelete(context, title: 'Apagar "${widget.tag!.name}"?', body: TagUse.deleteNotice(c.project, _id))) return;
    c.deleteTag(_id);
    if (mounted) Navigator.pop(context);
  }

  // ── Tela ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.watch(context);
    final project = scope.controller.project;
    final (program, compileError) = _compile(project);
    final draft = _draft(program);
    final error = compileError ?? (program == null ? null : _cycleError(project, draft));
    final ok = program != null && error == null;
    if (ok) _last = _evaluator.evaluate('cadastro', program.spec, scope.runtime.store.read, previous: _last);
    final dormant = [for (final a in _alarms) if (!draft.acceptsAlarm(a)) a];
    final isBool = draft.dataType == TagDataType.bool;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: LiveTags(
        // As entradas da conta (e as das calculadas citadas) ficam sendo lidas
        // enquanto o cadastro está aberto.
        tagIds: program == null ? const {} : CalcGraph.expand(project, program.inputIds),
        child: Scaffold(
          appBar: AppBar(
            title: AdaptiveTitle(_editing ? 'Variável calculada' : 'Nova variável calculada'),
            actions: [
              if (_editing) IconButton(tooltip: 'Apagar', icon: Icon(Icons.delete_outline_rounded, color: Ind.alarm), onPressed: _delete),
            ],
          ),
          // No tablet, campos e Salvar com no máximo 640 dp (TB-3), como no
          // cadastro de variável.
          bottomNavigationBar: FormWidth(
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton.icon(
                  key: const ValueKey('salvar-calculada'),
                  onPressed: _save,
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('Salvar'),
                ),
              ),
            ),
          ),
          body: FormWidth(child: Form(
            key: _form,
            autovalidateMode: _autovalidate,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Ind.page, 12, Ind.page, 8),
                child: _ResultPanel(tag: ok ? draft : null, reading: _last, idle: _expr.text.trim().isEmpty ? 'Escreva a conta' : 'Corrija a conta'),
              ),
              Expanded(
                child: ListView(
                  key: const ValueKey('formulario-calculada'),
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 32),
                  children: [
                    const SizedBox(height: Ind.spaceLarge),
                    KeyedSubtree(
                      key: _nameAnchor,
                      child: TextFormField(
                        key: const ValueKey('campo-nome-calculada'),
                        controller: _name,
                        validator: Validators.name,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(labelText: 'Nome', hintText: 'Ex.: Rótulos por hora'),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SectionHeader('Conta', padding: EdgeInsets.fromLTRB(0, 28, 0, 12)),
                    KeyedSubtree(
                      key: _exprAnchor,
                      child: CalcExpressionField(
                        controller: _expr,
                        error: error,
                        excludeTagId: _id,
                        onChanged: () => setState(() {}),
                      ),
                    ),
                    if (dormant.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        dormant.length == 1
                            ? '1 alarme deixa de valer com este resultado e sai ao salvar.'
                            : '${dormant.length} alarmes deixam de valer com este resultado e saem ao salvar.',
                        key: const ValueKey('aviso-alarmes-calculada'),
                        style: TextStyle(color: Ind.textFor(Ind.warn), height: 1.35),
                      ),
                    ],
                    const SizedBox(height: Ind.space),
                    AlarmsRow(
                      tag: draft,
                      alarms: draft.alarms,
                      onChanged: (a) => setState(() => _alarms = [...a, ...dormant]),
                    ),
                    const SizedBox(height: Ind.spaceSmall),
                    NarrationsRow(tag: draft, narrations: _narrations, onChanged: (n) => setState(() => _narrations = n)),
                    const SizedBox(height: Ind.spaceSmall),
                    _moreOptions(isBool),
                  ],
                ),
              ),
            ]),
          )),
        ),
      ),
    );
  }

  /// "Mais opções": unidade, casas decimais (só número) e observação.
  Widget _moreOptions(bool isBool) {
    final summary = [
      if (!isBool && _unit.text.trim().isNotEmpty) _unit.text.trim(),
      if (!isBool) _decimals == 1 ? '1 casa decimal' : '$_decimals casas decimais',
      if (_description.text.trim().isNotEmpty) 'observação',
    ];
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: _moreKey,
        controller: _more,
        tilePadding: EdgeInsets.zero,
        onExpansionChanged: (open) => revealAfterExpand(_moreKey, open),
        // O primeiro filho é um campo: o rótulo dele flutua acima da caixa
        // e era cortado pela borda da seção.
        childrenPadding: const EdgeInsets.only(top: 10, bottom: 8),
        title: const Text('Mais opções'),
        subtitle: Text(summary.isEmpty ? 'Observação' : summary.join(' · '), style: TextStyle(color: Ind.textMuted, fontSize: 13)),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!isBool) ...[
            TextFormField(
              key: const ValueKey('campo-unidade-calculada'),
              controller: _unit,
              decoration: const InputDecoration(labelText: 'Unidade', hintText: 'Ex.: %, un/h'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final u in _unitPresets)
                ChoiceChip(
                  key: ValueKey('unidade-calculada-$u'),
                  label: Text(u),
                  selected: _unit.text.trim() == u,
                  onSelected: (on) => setState(() => _unit.text = on ? u : ''),
                ),
            ]),
            const SizedBox(height: Ind.space),
            StepperCounter(
              label: 'Casas decimais',
              caption: 'Ex.: ${75.2468.toStringAsFixed(_decimals).replaceAll('.', ',')}',
              value: _decimals,
              keyPrefix: 'decimais',
              valueKey: const ValueKey('casas-decimais'),
              onDecrease: _decimals > 0 ? () => setState(() => _decimals--) : null,
              onIncrease: _decimals < 6 ? () => setState(() => _decimals++) : null,
            ),
            const SizedBox(height: Ind.space),
          ],
          TextFormField(
            controller: _description,
            maxLines: 2,
            decoration: const InputDecoration(labelText: 'Observação', hintText: 'Ex.: meta do turno = 12.000'),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
    );
  }
}

/// "Lendo agora" das calculadas: o resultado da conta com as leituras de agora.
class _ResultPanel extends StatelessWidget {
  const _ResultPanel({required this.tag, required this.reading, required this.idle});

  /// A variável como está no formulário; nula enquanto a conta não está certa.
  final Tag? tag;
  final TagReading reading;
  final String idle;

  @override
  Widget build(BuildContext context) {
    final t = tag;
    final r = reading;
    final problem = t != null && r.quality.isProblem;
    final good = t != null && r.isGood;
    final color = problem ? Ind.alarm : (good ? Ind.ok : Ind.textMuted);
    final text = t == null
        ? idle
        : good
            ? TagCodec.format(t, r.value)
            : capitalized(r.message.isEmpty ? 'Lendo…' : r.message);
    return Container(
      key: const ValueKey('lendo-agora'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Ind.bg,
        borderRadius: BorderRadius.circular(Ind.radius),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(children: [
        Icon(problem ? Icons.error_outline_rounded : Icons.functions_rounded, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('LENDO AGORA · RESULTADO DA CONTA', style: Ind.tag(size: 10.5, color: Ind.textMuted)),
            const SizedBox(height: 4),
            Text(
              text,
              key: const ValueKey('resultado-conta'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: good ? Ind.number(24, color: Ind.text) : TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 15),
            ),
          ]),
        ),
        if (t != null) Text(t.dataType == TagDataType.bool ? 'liga/desliga' : 'número', style: Ind.number(12, color: Ind.textMuted)),
      ]),
    );
  }
}
