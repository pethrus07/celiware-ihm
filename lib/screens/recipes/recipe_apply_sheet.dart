import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../services/recipes/recipe_applier.dart';
import '../../services/recipes/recipe_history.dart';
import 'recipe_widgets.dart';

enum _Phase { confirm, running, done }

/// Aplicar uma receita (RC-5): **uma** confirmação com a lista "de → para",
/// a gravação com o progresso à vista e o relatório do que gravou e do que
/// falhou. Enquanto grava, a folha não fecha (nem pelo "voltar").
class RecipeApplySheet extends StatefulWidget {
  const RecipeApplySheet({super.key, required this.plan, required this.applier, required this.history});

  final RecipePlan plan;
  final RecipeApplier applier;
  final RecipeHistoryStore history;

  static Future<RecipeApplyResult?> show(
    BuildContext context, {
    required RecipePlan plan,
    required RecipeApplier applier,
    required RecipeHistoryStore history,
  }) =>
      showModalBottomSheet<RecipeApplyResult>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        // Arrastar para baixo fecharia no meio da gravação.
        enableDrag: false,
        builder: (_) => RecipeApplySheet(plan: plan, applier: applier, history: history),
      );

  @override
  State<RecipeApplySheet> createState() => _RecipeApplySheetState();
}

class _RecipeApplySheetState extends State<RecipeApplySheet> {
  final _operator = TextEditingController();
  _Phase _phase = _Phase.confirm;
  int _done = 0, _total = 0;
  RecipeApplyResult? _result;

  @override
  void initState() {
    super.initState();
    // Quem aplicou por último neste aparelho já vem escrito — sem segurar a
    // confirmação esperando o arquivo, e sem apagar o que a pessoa digitou.
    widget.history.lastOperator().then((name) {
      if (mounted && _operator.text.isEmpty && name.isNotEmpty) _operator.text = name;
    });
  }

  @override
  void dispose() {
    _operator.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _phase = _Phase.running;
      _total = widget.plan.writes.length;
    });
    final r = await widget.applier.apply(widget.plan, onProgress: (done, total) {
      if (mounted) {
        setState(() {
          _done = done;
          _total = total;
        });
      }
    });
    // O histórico grava mesmo se a folha já tiver fechado.
    unawaited(widget.history.add(RecipeApplyRecord.of(r, operator: _operator.text)));
    if (r.outcome == RecipeOutcome.applied) {
      HapticFeedback.lightImpact();
    } else {
      HapticFeedback.heavyImpact();
    }
    if (!mounted) return;
    setState(() {
      _result = r;
      _phase = _Phase.done;
    });
  }

  @override
  Widget build(BuildContext context) {
    final content = switch (_phase) {
      _Phase.confirm => _confirm(context),
      _Phase.running => _running(context),
      _Phase.done => _report(context, _result!),
    };
    return PopScope(
      canPop: _phase != _Phase.running,
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.96,
        builder: (context, scroll) => Column(children: [
          Expanded(
            // Sem a alça de arrastar (de propósito), o respiro do topo vem daqui.
            child: ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(Ind.page, Ind.spaceLarge, Ind.page, 16), children: content.$1),
          ),
          if (content.$2 != null) SheetActions(child: content.$2!),
        ]),
      ),
    );
  }

  // ── Confirmação ─────────────────────────────────────────────────────────────

  (List<Widget>, Widget?) _confirm(BuildContext context) {
    final plan = widget.plan;
    final writes = plan.writes;
    final same = plan.items.length - writes.length;
    final title = [
      Text('Aplicar "${plan.recipe.name}"', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 4),
      Text('em ${plan.device.name}', style: TextStyle(color: Ind.textDim)),
      const SizedBox(height: Ind.space),
    ];
    if (!plan.canApply) {
      return (
        [
          ...title,
          Text('Não dá para aplicar agora:', style: TextStyle(color: Ind.textDim, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (final (i, b) in plan.blockers.indexed) _line(Icons.block_rounded, Ind.textFor(Ind.alarm), b, key: ValueKey('impede-aplicar-$i')),
          if (plan.items.isNotEmpty) ...[
            const SizedBox(height: Ind.space),
            sheetLabel('O que mudaria'),
            if (writes.isEmpty) Text('Nada: a máquina já está com esta receita.', style: TextStyle(color: Ind.textDim)),
            for (final w in writes) _fromTo(w),
          ],
        ],
        OutlinedButton(key: const ValueKey('fechar-aplicar'), onPressed: () => Navigator.pop(context), child: const Text('Fechar')),
      );
    }
    final n = writes.length;
    return (
      [
        ...title,
        if (n == 0)
          Text('Nenhum valor muda: a máquina já está com esta receita.', style: const TextStyle(fontSize: 16, height: 1.4))
        else ...[
          sheetLabel(n == 1 ? 'Vai gravar 1 valor' : 'Vai gravar $n valores'),
          for (final w in writes) _fromTo(w),
          if (same > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(same == 1 ? 'O outro já está igual.' : 'Os outros $same já estão iguais.', style: TextStyle(color: Ind.textMuted, fontSize: 13)),
            ),
        ],
        const SizedBox(height: Ind.space),
        if (plan.condition != null) _line(Icons.check_circle_rounded, Ind.textFor(Ind.ok), 'Conferido: ${plan.condition!.wanted}'),
        if (plan.loadedTag != null) _line(Icons.flag_outlined, Ind.textDim, 'No fim, liga "${plan.loadedTag!.name}".'),
        const SizedBox(height: Ind.space),
        TextField(
          key: const ValueKey('quem-aplica'),
          controller: _operator,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Quem está aplicando', hintText: 'Opcional — fica no histórico deste aparelho'),
        ),
      ],
      Row(children: [
        Expanded(
          child: OutlinedButton(key: const ValueKey('cancelar-aplicar'), onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: FilledButton.icon(
            key: const ValueKey('confirmar-aplicar'),
            onPressed: _run,
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(n == 0 ? 'Confirmar receita' : n == 1 ? 'Aplicar 1 valor' : 'Aplicar $n valores'),
          ),
        ),
      ]),
    );
  }

  Widget _fromTo(RecipePlanItem w) {
    final p = w.param;
    return Padding(
      key: ValueKey('de-para-${p.key}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Row(children: [
          Flexible(child: Text(w.current == null ? '?' : p.format(w.current), style: Ind.number(17, color: Ind.textDim))),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.arrow_forward_rounded, size: 18, color: Ind.textMuted)),
          Flexible(child: Text(p.format(w.target), style: Ind.number(19, color: Ind.text))),
        ]),
        if (w.readProblem != null)
          Text('Não deu para ler antes: ${w.readProblem}', style: TextStyle(color: Ind.textFor(Ind.warn), fontSize: 13)),
      ]),
    );
  }

  // ── Gravando ────────────────────────────────────────────────────────────────

  (List<Widget>, Widget?) _running(BuildContext context) {
    final checking = _total > 0 && _done >= _total;
    return (
      [
        const SizedBox(height: Ind.spaceLarge),
        Text(
          _total == 0 ? 'Conferindo…' : checking ? 'Conferindo o que foi gravado…' : 'Gravando ${_done + 1} de $_total…',
          key: const ValueKey('progresso-aplicar'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: Ind.space),
        LinearProgressIndicator(value: _total == 0 || checking ? null : _done / _total),
        const SizedBox(height: Ind.space),
        Text('Não feche o app até terminar.', style: TextStyle(color: Ind.textMuted)),
      ],
      null,
    );
  }

  // ── Relatório ───────────────────────────────────────────────────────────────

  (List<Widget>, Widget?) _report(BuildContext context, RecipeApplyResult r) {
    final (icon, color) = switch (r.outcome) {
      RecipeOutcome.applied => (Icons.check_circle_rounded, Ind.textFor(Ind.ok)),
      RecipeOutcome.divergent => (Icons.warning_amber_rounded, Ind.textFor(Ind.warn)),
      RecipeOutcome.partial || RecipeOutcome.notApplied => (Icons.error_rounded, Ind.textFor(Ind.alarm)),
    };
    final loaded = r.plan.loadedTag;
    return (
      [
        const SizedBox(height: 4),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color, size: 30),
          const SizedBox(width: 12),
          Expanded(child: Text(r.headline, key: const ValueKey('resultado-aplicar'), style: Theme.of(context).textTheme.titleLarge?.copyWith(color: color))),
        ]),
        const SizedBox(height: Ind.space),
        for (final x in r.results) _resultLine(x),
        if (loaded != null)
          r.loadedSet
              ? _line(Icons.flag_rounded, Ind.textFor(Ind.ok), 'Ligou "${loaded.name}".')
              : _line(Icons.outlined_flag_rounded, Ind.textFor(Ind.warn), '"${loaded.name}" ${r.loadedProblem ?? 'não ligado'}.'),
      ],
      FilledButton(key: const ValueKey('fechar-relatorio'), onPressed: () => Navigator.pop(context, r), child: const Text('Fechar')),
    );
  }

  Widget _resultLine(RecipeItemResult x) {
    final (icon, color) = switch (x.outcome) {
      RecipeItemOutcome.verified => (Icons.check_rounded, Ind.textFor(Ind.ok)),
      RecipeItemOutcome.divergent || RecipeItemOutcome.unverified => (Icons.warning_amber_rounded, Ind.textFor(Ind.warn)),
      RecipeItemOutcome.refused || RecipeItemOutcome.commLost => (Icons.close_rounded, Ind.textFor(Ind.alarm)),
      RecipeItemOutcome.notTried => (Icons.remove_rounded, Ind.textMuted),
    };
    final p = x.item.param;
    return Padding(
      key: ValueKey('resultado-${p.key}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, color: color, size: 20)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${p.name}: ${x.item.current == null ? '?' : p.format(x.item.current)} → ${p.format(x.item.target)}', style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(x.label, style: TextStyle(color: x.outcome == RecipeItemOutcome.verified ? Ind.textDim : color, height: 1.35)),
          ]),
        ),
      ]),
    );
  }

  static Widget _line(IconData icon, Color color, String text, {Key? key}) => Padding(
        key: key,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
        ]),
      );
}
