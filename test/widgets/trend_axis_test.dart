import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/widgets/hmi/elements/chart_elements.dart';

/// Eixo da direita do gráfico de tendência (unidades diferentes na mesma
/// curva): mesmo número de passos do eixo da esquerda, cobrindo os dados, em
/// passos redondos — senão as marcas não caem nas linhas de grade.
void main() {
  bool isNice(double step) {
    final exp = math.pow(10, (math.log(step) / math.ln10).floor()).toDouble();
    final f = step / exp;
    return [1.0, 2.0, 2.5, 5.0, 10.0].any((n) => (f - n).abs() < 1e-9);
  }

  for (final (lo, hi, steps) in [(0.0, 80.0, 4), (31.2, 81.7, 4), (80.2, 81.9, 4), (-12.0, 37.5, 5), (0.0, 0.0, 4), (1200.0, 64000.0, 3)]) {
    test('dados $lo..$hi em $steps passos', () {
      final (rLo, rHi) = trendAlignedRange(lo, hi, steps);
      expect(rLo, lessThanOrEqualTo(lo));
      expect(rHi, greaterThanOrEqualTo(hi));
      expect(isNice((rHi - rLo) / steps), isTrue, reason: 'passo ${(rHi - rLo) / steps}');
      if (lo >= 0) expect(rLo, greaterThanOrEqualTo(0), reason: 'grandeza positiva não ganha eixo negativo');
    });
  }

  test('sem dados: faixa padrão', () {
    expect(trendAlignedRange(double.infinity, -double.infinity, 4), (0.0, 100.0));
  });
}
