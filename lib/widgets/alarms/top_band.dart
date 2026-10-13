import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// Moldura da faixa do topo do app (alarme, pergunta de regra ou "Sem
/// alarmes"): fundo, linha de baixo e **altura fixa**.
///
/// Toda variação da faixa passa por aqui, então nenhuma mede diferente da
/// outra: trocar o alarme pela pergunta, aparecer o botão de silenciar ou o
/// "+2" muda o que está **dentro** da faixa, nunca a altura dela — e, com
/// isso, nunca a posição das telas embaixo.
class TopBand extends StatelessWidget {
  const TopBand({super.key, required this.color, this.line, this.lineWidth = 1, required this.onTap, required this.child});

  final Color color;

  /// Linha de baixo. Só quando comunica estado (alarme, pergunta): a faixa
  /// quieta não tem borda.
  final Color? line;
  final double lineWidth;
  final VoidCallback onTap;
  final Widget child;

  /// Deitado, a altura é o recurso escasso: a faixa vira uma linha só.
  static bool compact(BuildContext context) => MediaQuery.orientationOf(context) == Orientation.landscape;

  /// Altura das linhas de texto da faixa. Fixa (não a da fonte), para a
  /// conta de [heightOf] bater com o que é desenhado.
  static const lineHeight = 1.3;

  /// Altura da faixa, fora a barra de status. Não depende do que ela mostra:
  /// só da orientação e do tamanho de letra do sistema.
  ///
  /// Em pé: duas linhas (o quê / desde quando), no mínimo 56 dp — alvo
  /// largo no alto da tela, que é a área mais difícil de acertar com o dedo,
  /// sem custar mais que o necessário (o espaço é reservado em toda tela).
  /// Deitado: uma linha, no mínimo o alvo de 48 dp. Letra grande do sistema
  /// aumenta a faixa (na hora de trocar a letra, não quando chega alarme).
  static double heightOf(BuildContext context) {
    final t = MediaQuery.textScalerOf(context);
    if (compact(context)) return math.max(Ind.minTouch, t.scale(17) * lineHeight + 8);
    return math.max(56, t.scale(18) * lineHeight + 2 + t.scale(12.5) * lineHeight + 2 * _padV);
  }

  /// Respiro de cima e de baixo, em pé: sobra exatamente o alvo de 48 dp
  /// para o botão de silenciar.
  static const _padV = 4.0;

  /// Altura total do espaço reservado no topo: a faixa mais a barra de status.
  static double slotOf(BuildContext context) => MediaQuery.paddingOf(context).top + heightOf(context);

  @override
  Widget build(BuildContext context) {
    final c = compact(context);
    return Material(
      color: color,
      child: InkWell(
        onTap: onTap,
        child: Container(
          // Borda pintada por cima: não empurra o conteúdo (a de 2 dp do
          // alarme novo e a de 1 dp do reconhecido ficam com o texto no mesmo
          // lugar).
          foregroundDecoration: line == null ? null : BoxDecoration(border: Border(bottom: BorderSide(color: line!, width: lineWidth))),
          child: SafeArea(
            bottom: false,
            child: SizedBox(
              height: heightOf(context),
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, c ? 0 : _padV, 10, c ? 0 : _padV),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Lugar do ícone à esquerda da faixa (forma do alarme, ícone da regra): a
/// mesma largura nas três variações, para o texto começar sempre no mesmo x.
class TopBandLead extends StatelessWidget {
  const TopBandLead({super.key, required this.child});
  final Widget child;

  static double sizeOf(BuildContext context) => TopBand.compact(context) ? 24 : 30;

  @override
  Widget build(BuildContext context) {
    final s = sizeOf(context);
    return SizedBox(width: s, height: s, child: Center(child: child));
  }
}
