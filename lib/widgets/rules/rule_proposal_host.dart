import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../services/rules/rule_engine.dart';

/// A pergunta de uma regra (LG-6), por cima de **qualquer** tela: "Parar a
/// prensa?" com o que vai ser gravado e dois botões — Ignorar e o verbo da
/// ação (Desligar, Ligar, Gravar). Nada é gravado sem o toque.
///
/// Fica acima do Navigator (como a faixa de alarme): proposta só na tela que
/// ninguém está olhando não serve. O celular vibra quando chega uma nova.
class RuleProposalHost extends StatefulWidget {
  const RuleProposalHost({super.key, required this.rules, required this.child});

  final RuleEngine rules;
  final Widget child;

  @override
  State<RuleProposalHost> createState() => _RuleProposalHostState();
}

class _RuleProposalHostState extends State<RuleProposalHost> {
  int _count = 0;
  bool _busy = false;
  String? _error;
  Timer? _errorTimer;

  @override
  void initState() {
    super.initState();
    widget.rules.addListener(_changed);
    _count = widget.rules.proposals.length;
  }

  @override
  void dispose() {
    widget.rules.removeListener(_changed);
    _errorTimer?.cancel();
    super.dispose();
  }

  void _changed() {
    final n = widget.rules.proposals.length;
    if (n > _count) unawaited(HapticFeedback.heavyImpact());
    _count = n;
    if (mounted) setState(() {});
  }

  Future<void> _confirm(RuleProposal p) async {
    setState(() => _busy = true);
    final error = await widget.rules.confirm(p.ruleId);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error == null ? null : 'Não gravou: $error';
    });
    _errorTimer?.cancel();
    if (error != null) {
      _errorTimer = Timer(const Duration(seconds: 6), () {
        if (mounted) setState(() => _error = null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.rules.proposals.firstOrNull;
    final more = widget.rules.proposals.length - 1;
    return Stack(children: [
      widget.child,
      if (p != null || _error != null)
        Positioned(
          left: 12,
          right: 12,
          bottom: 0,
          child: SafeArea(
            top: false,
            minimum: const EdgeInsets.only(bottom: 12),
            child: Material(
              key: const ValueKey('proposta-regra'),
              color: Ind.raised,
              elevation: 8,
              borderRadius: BorderRadius.circular(Ind.radius),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
                child: p == null
                    ? Row(children: [
                        Icon(Icons.error_outline_rounded, color: Ind.textFor(Ind.alarm)),
                        const SizedBox(width: 10),
                        Expanded(child: Text(_error!, style: TextStyle(color: Ind.textFor(Ind.alarm), fontWeight: FontWeight.w600))),
                        IconButton(tooltip: 'Fechar', onPressed: () => setState(() => _error = null), icon: const Icon(Icons.close_rounded)),
                      ])
                    : Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                        Row(children: [
                          Icon(Icons.rule_rounded, color: Ind.accent, size: 20),
                          const SizedBox(width: 8),
                          Expanded(child: Text(more > 0 ? 'REGRA · +$more esperando' : 'REGRA', style: Ind.tag(size: 11, color: Ind.textMuted))),
                        ]),
                        const SizedBox(height: 6),
                        Text(p.question, style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 2),
                        Text(p.detail, style: TextStyle(color: Ind.textDim, height: 1.3)),
                        if (_error != null) ...[
                          const SizedBox(height: 6),
                          Text(_error!, style: TextStyle(color: Ind.textFor(Ind.alarm), fontWeight: FontWeight.w600)),
                        ],
                        const SizedBox(height: 4),
                        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                          TextButton(
                            key: const ValueKey('proposta-ignorar'),
                            onPressed: _busy ? null : () => widget.rules.ignore(p.ruleId),
                            child: const Text('Ignorar'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            key: const ValueKey('proposta-confirmar'),
                            onPressed: _busy ? null : () => _confirm(p),
                            child: Text(p.action),
                          ),
                        ]),
                      ]),
              ),
            ),
          ),
        ),
    ]);
  }
}
