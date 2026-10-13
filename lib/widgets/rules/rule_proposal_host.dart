import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../services/rules/rule_engine.dart';
import '../alarms/top_band.dart';

/// A pergunta de uma regra (LG-6): "Parar a prensa?". Nada é gravado sem o
/// toque da pessoa.
///
/// Onde ela aparece: na **faixa do topo** (a mesma do alarme, montada por
/// `AlarmBannerHost`), em qualquer tela — proposta só na tela que ninguém
/// está olhando não serve. A faixa tem espaço reservado e altura fixa, então
/// a pergunta chegar ou sair não move nada e não cobre nada: nem a barra de
/// abas, nem o Salvar dos cadastros, nem o teclado numérico. Antes ela era
/// um cartão flutuando no rodapé, por cima das abas — não dava para trocar de
/// aba sem responder, e o "Gravar" caía exatamente onde o dedo ia tocar a
/// aba "Mais".
///
/// Responder é deliberado: tocar a faixa abre a decisão ([RuleProposalDialog])
/// com o que vai ser gravado e os dois botões — Ignorar e o verbo da ação
/// (Desligar, Ligar, Gravar). Fechar sem responder deixa a pergunta na faixa.
///
/// Este widget fica acima do Navigator e só faz o celular vibrar quando chega
/// uma pergunta nova; quem desenha é a faixa.
class RuleProposalHost extends StatefulWidget {
  const RuleProposalHost({super.key, required this.rules, required this.child});

  final RuleEngine rules;
  final Widget child;

  @override
  State<RuleProposalHost> createState() => _RuleProposalHostState();
}

class _RuleProposalHostState extends State<RuleProposalHost> {
  int _count = 0;

  @override
  void initState() {
    super.initState();
    widget.rules.addListener(_changed);
    _count = widget.rules.proposals.length;
  }

  @override
  void dispose() {
    widget.rules.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final n = widget.rules.proposals.length;
    if (n > _count) unawaited(HapticFeedback.heavyImpact());
    _count = n;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A pergunta na faixa do topo: o que a regra quer fazer, o que vai gravar e
/// o convite "Responder". Cor de interação (é uma pergunta, não um alarme).
class RuleProposalBand extends StatelessWidget {
  const RuleProposalBand({super.key, required this.proposal, required this.more, required this.onTap, this.behind});

  final RuleProposal proposal;

  /// Outras perguntas esperando atrás desta.
  final int more;
  final VoidCallback onTap;

  /// Marca de um alarme reconhecido que continua ativo (a faixa é dele quando
  /// não há pergunta).
  final Widget? behind;

  @override
  Widget build(BuildContext context) {
    final compact = TopBand.compact(context);
    const h = TopBand.lineHeight;
    final title = TextStyle(fontFamily: Ind.condensed, fontWeight: FontWeight.w700, fontSize: compact ? 17 : 18, height: h, color: Ind.text);
    final detail = TextStyle(color: Ind.textDim, fontSize: 12.5, height: h);
    return TopBand(
      color: Color.alphaBlend(Ind.accent.withValues(alpha: Ind.isDark ? 0.14 : 0.10), Ind.raised),
      line: Ind.accent.withValues(alpha: 0.7),
      lineWidth: 2,
      onTap: onTap,
      child: Row(children: [
        TopBandLead(child: Icon(Icons.rule_rounded, color: Ind.accent, size: compact ? 22 : 26)),
        const SizedBox(width: 14),
        Expanded(
          child: compact
              ? Text.rich(
                  TextSpan(children: [TextSpan(text: proposal.question, style: title), TextSpan(text: '   ${proposal.detail}', style: detail)]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )
              : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(proposal.question, maxLines: 1, overflow: TextOverflow.ellipsis, style: title),
                  const SizedBox(height: 2),
                  Text(proposal.detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: detail),
                ]),
        ),
        if (behind case final b?) Padding(padding: const EdgeInsets.only(left: 8), child: b),
        if (more > 0)
          Container(
            margin: const EdgeInsets.only(left: 8),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(color: Ind.surfaceHigh, borderRadius: BorderRadius.circular(20)),
            child: Text('+$more', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Ind.text)),
          ),
        const SizedBox(width: 10),
        Text('Responder', style: TextStyle(color: Ind.accent, fontWeight: FontWeight.w700, fontSize: 14, height: h)),
        Icon(Icons.chevron_right_rounded, color: Ind.accent),
      ]),
    );
  }
}

/// Atalho para a pergunta quando a faixa está com um alarme novo (que tem a
/// vez, ISA-18.2): o ícone da regra, com o número se for mais de uma.
class RuleProposalMarker extends StatelessWidget {
  const RuleProposalMarker({super.key, required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Sem tooltip: a faixa fica acima do Navigator, onde não há Overlay para
    // o balão. O nome vai para o leitor de tela.
    return Semantics(
      label: count > 1 ? '$count perguntas de regra' : 'Pergunta de regra',
      button: true,
      excludeSemantics: true,
      child: IconButton(
        key: const ValueKey('faixa-regra'),
        onPressed: onTap,
        icon: Badge(
          isLabelVisible: count > 1,
          label: Text('$count'),
          backgroundColor: Ind.accent,
          textColor: Ind.onAccent,
          child: Icon(Icons.rule_rounded, color: Ind.accent),
        ),
      ),
    );
  }
}

/// A decisão: o que a regra quer gravar, Ignorar ou o verbo da ação. Se a
/// pergunta sair enquanto a caixa está aberta (a condição passou, o app foi
/// para o fundo), a caixa diz que nada foi gravado em vez de gravar tarde.
class RuleProposalDialog extends StatefulWidget {
  const RuleProposalDialog({super.key, required this.rules, required this.proposal});

  final RuleEngine rules;
  final RuleProposal proposal;

  /// Abre pelo Navigator do app (a faixa fica acima dele, sem Overlay).
  static Future<void> open(NavigatorState navigator, {required RuleEngine rules, required RuleProposal proposal}) =>
      showDialog<void>(context: navigator.overlay!.context, builder: (_) => RuleProposalDialog(rules: rules, proposal: proposal));

  @override
  State<RuleProposalDialog> createState() => _RuleProposalDialogState();
}

class _RuleProposalDialogState extends State<RuleProposalDialog> {
  bool _busy = false;

  /// Respondida aqui (Ignorar ou gravação em curso): a pergunta sumir da
  /// lista é o esperado, não "a situação mudou".
  bool _answered = false;
  bool _gone = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.rules.addListener(_changed);
  }

  @override
  void dispose() {
    widget.rules.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (_answered || _gone) return;
    if (!widget.rules.proposals.any((p) => p.ruleId == widget.proposal.ruleId)) setState(() => _gone = true);
  }

  void _ignore() {
    _answered = true;
    widget.rules.ignore(widget.proposal.ruleId);
    Navigator.pop(context);
  }

  Future<void> _confirm() async {
    _answered = true;
    setState(() => _busy = true);
    final error = await widget.rules.confirm(widget.proposal.ruleId);
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _busy = false;
      _error = 'Não gravou: $error';
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.proposal;
    final done = _gone || _error != null;
    final message = _error ?? (_gone ? 'A pergunta não vale mais: a situação mudou antes da resposta. Nada foi gravado.' : p.detail);
    return AlertDialog(
      icon: Icon(Icons.rule_rounded, color: Ind.accent),
      title: Text(p.question),
      content: Text(
        message,
        key: const ValueKey('proposta-detalhe'),
        style: _error != null
            ? TextStyle(fontSize: 16, height: 1.4, color: Ind.textFor(Ind.alarm), fontWeight: FontWeight.w600)
            : const TextStyle(fontSize: 16, height: 1.4),
      ),
      actions: done
          ? [FilledButton(key: const ValueKey('proposta-fechar'), onPressed: () => Navigator.pop(context), child: const Text('Fechar'))]
          : [
              TextButton(key: const ValueKey('proposta-ignorar'), onPressed: _busy ? null : _ignore, child: const Text('Ignorar')),
              FilledButton(key: const ValueKey('proposta-confirmar'), onPressed: _busy ? null : _confirm, child: Text(p.action)),
            ],
    );
  }
}
