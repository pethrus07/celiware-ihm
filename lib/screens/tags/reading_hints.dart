import '../../models/tag.dart';

/// Sugestões a partir do valor que o "Lendo agora" trouxe. Valor de formato
/// errado costuma ter cara: 65531 num registrador que deveria valer −5;
/// 2,4 × 10⁻⁴¹ num número com vírgula que chegou com as palavras trocadas.
/// Funções puras, testáveis sem tela.
class ReadingHints {
  ReadingHints._();

  /// Número cru (antes da escala) de um valor lido; nulo se não é número.
  static double? raw(Tag t, Object? v) =>
      v is num ? (t.hasScale ? (v - t.offset) / t.scale : v.toDouble()) : null;

  /// Inteiro sem sinal acima da metade da faixa: se era para ser negativo, o
  /// tipo certo é o com sinal. Devolve o tipo sugerido, ou nulo.
  static TagDataType? signedInstead(Tag t, Object? v) {
    final r = raw(t, v);
    if (r == null) return null;
    if (t.dataType == TagDataType.uint16 && r > 32767) return TagDataType.int16;
    if (t.dataType == TagDataType.uint32 && r > 2147483647) return TagDataType.int32;
    return null;
  }

  /// Valor de 32 bits sem cara de medida de máquina: NaN, gigante (acima de
  /// 10⁹) ou minúsculo (abaixo de 10⁻⁶, sem ser zero).
  static bool looksAbsurd(Tag t, Object? v) {
    if (!t.dataType.is32Bit) return false;
    final r = raw(t, v);
    if (r == null) return false;
    if (r.isNaN || r.isInfinite) return true;
    final a = r.abs();
    return a > 1e9 || (a > 0 && a < 1e-6);
  }

  /// Próxima ordem de bytes a tentar a partir de [current]: palavras trocadas
  /// primeiro (o caso comum em CLP), depois bytes trocados, depois tudo —
  /// pulando as que já leram lixo ([failed]). Nulo quando não sobra nenhuma.
  static ByteOrder? nextOrder(ByteOrder current, Set<ByteOrder> failed) {
    ByteOrder flip({required bool words, required bool bytes}) => ByteOrder.values.firstWhere(
        (o) => o.swapsWords == (current.swapsWords != words) && o.swapsBytes == (current.swapsBytes != bytes));
    for (final o in [flip(words: true, bytes: false), flip(words: false, bytes: true), flip(words: true, bytes: true)]) {
      if (!failed.contains(o)) return o;
    }
    return null;
  }
}
