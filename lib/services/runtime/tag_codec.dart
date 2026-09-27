import 'dart:typed_data';

import '../../models/tag.dart';

/// Valor digitado que não cabe na variável (fora da faixa do tipo, texto que
/// não é número...). A mensagem é para o operador.
class TagValueError implements Exception {
  const TagValueError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Tradução entre registradores crus e valores de variável — nos dois sentidos.
///
/// Leitura: registradores (uint16 big-endian, como chegam do [ModbusClient])
/// → `bool` / `int` / `double`, ou lista deles se [Tag.length] > 1.
/// Escrita: valor do operador → registradores prontos para FC06/FC16.
///
/// Toda a lógica de ordem de bytes ([ByteOrder]) vive aqui e só aqui.
class TagCodec {
  TagCodec._();

  // ── Leitura ──────────────────────────────────────────────────────────────────

  /// [bits] = exatamente [Tag.span] posições, a partir de [Tag.address].
  static Object decodeBits(Tag tag, List<bool> bits) {
    if (tag.length == 1) return bits.first;
    return List<bool>.of(bits.take(tag.length));
  }

  /// [regs] = exatamente [Tag.span] registradores, a partir de [Tag.address].
  ///
  /// Número volta **já na escala** da variável ([Tag.scale]/[Tag.offset]).
  static Object decodeRegisters(Tag tag, List<int> regs) {
    if (tag.isText) return decodeText(tag, regs);
    final n = tag.dataType.registerCount;
    final values = [
      for (var i = 0; i < tag.length; i++)
        _scaled(tag, _decodeOne(tag, regs.sublist(i * n, i * n + n))),
    ];
    return tag.length == 1 ? values.first : values;
  }

  /// Registradores → texto ASCII, 2 letras por registrador (byte alto
  /// primeiro; com bytes trocados, o baixo). Para no primeiro zero — o resto
  /// do campo costuma vir preenchido com 0 — e corta espaços do fim.
  /// Byte fora do ASCII visível vira "?" em vez de sumir calado.
  static String decodeText(Tag tag, List<int> regs) {
    final buf = StringBuffer();
    outer:
    for (final raw in regs.take(tag.length)) {
      final w = _word16(raw, tag.byteOrder);
      for (final b in [(w >> 8) & 0xFF, w & 0xFF]) {
        if (b == 0) break outer;
        buf.writeCharCode(b >= 0x20 && b < 0x7F ? b : 0x3F);
      }
    }
    return buf.toString().trimRight();
  }

  /// Bruto → unidade de engenharia. Sem escala, devolve o próprio valor
  /// (inteiro continua inteiro).
  static Object _scaled(Tag tag, Object raw) {
    if (!tag.hasScale || raw is! num) return raw;
    return raw * tag.scale + tag.offset;
  }

  static Object _decodeOne(Tag tag, List<int> r) {
    switch (tag.dataType) {
      case TagDataType.bool:
        final word = _word16(r[0], tag.byteOrder);
        return (word >> tag.bitIndex) & 1 == 1;
      case TagDataType.uint16:
        return _word16(r[0], tag.byteOrder);
      case TagDataType.int16:
        final w = _word16(r[0], tag.byteOrder);
        return w >= 0x8000 ? w - 0x10000 : w;
      case TagDataType.uint32:
        return _word32(r, tag.byteOrder);
      case TagDataType.int32:
        final v = _word32(r, tag.byteOrder);
        return v >= 0x80000000 ? v - 0x100000000 : v;
      case TagDataType.float32:
        final bd = ByteData(4)..setUint32(0, _word32(r, tag.byteOrder));
        return bd.getFloat32(0);
      case TagDataType.string:
        return decodeText(tag, r);
    }
  }

  /// Registrador cru → palavra lógica (desfaz a troca de bytes, se houver).
  static int _word16(int raw, ByteOrder order) =>
      order.swapsBytes ? _swap(raw) : raw;

  /// Dois registradores crus → valor lógico de 32 bits (0..2³²-1).
  static int _word32(List<int> r, ByteOrder order) {
    var w0 = r[0], w1 = r[1];
    if (order.swapsBytes) {
      w0 = _swap(w0);
      w1 = _swap(w1);
    }
    if (order.swapsWords) {
      final t = w0;
      w0 = w1;
      w1 = t;
    }
    return (w0 << 16) | w1;
  }

  static int _swap(int w) => ((w & 0xFF) << 8) | ((w >> 8) & 0xFF);

  // ── Escrita ──────────────────────────────────────────────────────────────────

  /// Valor na unidade de engenharia → registradores crus de **um** elemento
  /// da variável. Desfaz a escala antes: com ÷10, gravar 75,2 manda 752.
  static List<int> encodeRegisters(Tag tag, num value) {
    if (value.isNaN || value.isInfinite) throw const TagValueError('Número inválido');
    final raw = tag.hasScale ? (value - tag.offset) / tag.scale : value;
    switch (tag.dataType) {
      case TagDataType.bool:
        throw const TagValueError('Use encodeBitIntoRegister para bits');
      case TagDataType.string:
        throw TagValueError('"${tag.name}" é texto; não é gravável pela tela');
      case TagDataType.uint16:
        return [_to16(_checkedInt(raw, 0, 0xFFFF, tag), tag.byteOrder)];
      case TagDataType.int16:
        final v = _checkedInt(raw, -32768, 32767, tag);
        return [_to16(v & 0xFFFF, tag.byteOrder)];
      case TagDataType.uint32:
        return _to32(_checkedInt(raw, 0, 0xFFFFFFFF, tag), tag.byteOrder);
      case TagDataType.int32:
        final v = _checkedInt(raw, -2147483648, 2147483647, tag);
        return _to32(v & 0xFFFFFFFF, tag.byteOrder);
      case TagDataType.float32:
        final bd = ByteData(4)..setFloat32(0, raw.toDouble());
        return _to32(bd.getUint32(0), tag.byteOrder);
    }
  }

  /// Liga/desliga um bit dentro do registrador [currentRaw] (leitura-
  /// modificação-escrita). Devolve o registrador cru a gravar.
  static int encodeBitIntoRegister(Tag tag, int currentRaw, bool value) {
    var word = _word16(currentRaw, tag.byteOrder);
    word = value ? word | (1 << tag.bitIndex) : word & ~(1 << tag.bitIndex);
    return _to16(word & 0xFFFF, tag.byteOrder);
  }

  static int _to16(int word, ByteOrder order) =>
      order.swapsBytes ? _swap(word) : word;

  static List<int> _to32(int v, ByteOrder order) {
    var w0 = (v >> 16) & 0xFFFF, w1 = v & 0xFFFF;
    if (order.swapsWords) {
      final t = w0;
      w0 = w1;
      w1 = t;
    }
    if (order.swapsBytes) {
      w0 = _swap(w0);
      w1 = _swap(w1);
    }
    return [w0, w1];
  }

  /// [raw] já sem escala. As mensagens falam na unidade da tela: com ÷10,
  /// "aceita de 0 a 6553,5" e "passos de 0,1" — nunca o número cru.
  static int _checkedInt(num raw, int min, int max, Tag tag) {
    // Tolerância: 75,2 ÷ 0,1 dá 751,9999999 em ponto flutuante.
    if ((raw - raw.round()).abs() > 1e-6) {
      throw TagValueError(tag.hasScale
          ? '"${tag.name}" aceita passos de ${_num(tag, tag.scale.abs())}'
          : '"${tag.name}" só aceita número inteiro');
    }
    final v = raw.round();
    if (v < min || v > max) {
      final a = _eng(tag, min), b = _eng(tag, max);
      final lo = tag.scale < 0 ? b : a, hi = tag.scale < 0 ? a : b;
      throw TagValueError('"${tag.name}" aceita de $lo a $hi');
    }
    return v;
  }

  /// Número cru → texto na unidade da tela (para mensagens).
  static String _eng(Tag tag, num raw) => _num(tag, tag.hasScale ? raw * tag.scale + tag.offset : raw);

  static String _num(Tag tag, num v) {
    final d = tag.displayDecimals;
    return (d > 0 ? v.toStringAsFixed(d) : v.round().toString()).replaceAll('.', ',');
  }

  // ── Apresentação ─────────────────────────────────────────────────────────────

  /// Texto do valor para a tela, com casas decimais e unidade da variável.
  static String format(Tag tag, Object? value, {bool withUnit = true}) {
    if (value == null) return '---';
    if (value is bool) return value ? 'LIGADO' : 'DESLIGADO';
    if (value is num) {
      final d = tag.displayDecimals;
      final text = tag.dataType == TagDataType.float32 || d > 0
          ? value.toStringAsFixed(d).replaceAll('.', ',')
          : value.round().toString();
      return withUnit && tag.unit.isNotEmpty ? '$text ${tag.unit}' : text;
    }
    return value.toString();
  }

  /// Converte o texto digitado ("12,5") em número para [encodeRegisters].
  static num parseInput(Tag tag, String text) {
    final cleaned = text.trim().replaceAll(' ', '').replaceAll(',', '.');
    final v = num.tryParse(cleaned);
    if (v == null) throw TagValueError('"$text" não é um número');
    return v;
  }
}
