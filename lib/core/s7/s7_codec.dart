import 'dart:typed_data';

import 's7_address.dart';

/// Bytes ⇄ valor nos tipos do S7.
///
/// Diferente do Modbus, aqui não há ordem de bytes para escolher: o S7 é
/// **sempre big-endian** (byte mais significativo no endereço menor), em
/// todas as famílias. Por isso o codec é uma tabela fixa, sem opção por
/// variável.
///
/// STRING do S7 tem 2 bytes de cabeçalho — capacidade e tamanho atual —
/// seguidos das letras (1 byte cada). Um STRING[20] ocupa 22 bytes.
abstract final class S7Codec {
  /// Bytes de um STRING com capacidade de [maxChars] letras.
  static int stringBytes(int maxChars) => maxChars + 2;

  /// Bytes → valor: `bool` (BOOL), `int` (inteiros), `double` (REAL) ou
  /// `String` (STRING). [bit] escolhe o bit do byte em BOOL (a leitura de
  /// bit pelo protocolo já devolve o valor no bit 0).
  static Object decode(S7Type type, Uint8List bytes, {int bit = 0}) {
    if (type == S7Type.string) return decodeString(bytes);
    if (bytes.length < type.size) {
      throw ArgumentError('${type.label} precisa de ${type.size} bytes; vieram ${bytes.length}');
    }
    final d = ByteData.sublistView(bytes);
    switch (type) {
      case S7Type.boolean:
        return (bytes[0] >> bit) & 1 == 1;
      case S7Type.byte:
        return bytes[0];
      case S7Type.word:
        return d.getUint16(0);
      case S7Type.int16:
        return d.getInt16(0);
      case S7Type.dword:
        return d.getUint32(0);
      case S7Type.int32:
        return d.getInt32(0);
      case S7Type.real:
        return d.getFloat32(0);
      case S7Type.string:
        return decodeString(bytes);
    }
  }

  /// Valor → bytes. Lança [ArgumentError] com mensagem em português quando o
  /// valor não cabe no tipo — melhor recusar do que gravar um número cortado.
  /// [maxChars] é a capacidade do STRING (obrigatória para STRING).
  static Uint8List encode(S7Type type, Object value, {int? maxChars}) {
    switch (type) {
      case S7Type.boolean:
        return Uint8List.fromList([_bool(value) ? 1 : 0]);
      case S7Type.byte:
        return Uint8List.fromList([_int(type, value, 0, 0xFF)]);
      case S7Type.word:
        return (ByteData(2)..setUint16(0, _int(type, value, 0, 0xFFFF))).buffer.asUint8List();
      case S7Type.int16:
        return (ByteData(2)..setInt16(0, _int(type, value, -0x8000, 0x7FFF))).buffer.asUint8List();
      case S7Type.dword:
        return (ByteData(4)..setUint32(0, _int(type, value, 0, 0xFFFFFFFF))).buffer.asUint8List();
      case S7Type.int32:
        return (ByteData(4)..setInt32(0, _int(type, value, -0x80000000, 0x7FFFFFFF))).buffer.asUint8List();
      case S7Type.real:
        return (ByteData(4)..setFloat32(0, _real(value))).buffer.asUint8List();
      case S7Type.string:
        if (maxChars == null) throw ArgumentError('STRING precisa da capacidade (máximo de letras)');
        if (value is! String) throw ArgumentError('STRING espera um texto');
        return encodeString(value, maxChars);
    }
  }

  /// STRING do S7 → texto. Usa o menor entre o tamanho atual, a capacidade
  /// e os bytes que vieram (cabeçalho incoerente não estoura a leitura).
  /// Letra fora do Latin-1 visível vira "?" em vez de sumir calada.
  static String decodeString(Uint8List bytes) {
    if (bytes.length < 2) return '';
    final capacity = bytes[0];
    var length = bytes[1];
    if (length > capacity) length = capacity;
    if (length > bytes.length - 2) length = bytes.length - 2;
    final out = StringBuffer();
    for (var i = 0; i < length; i++) {
      final c = bytes[2 + i];
      out.writeCharCode(c < 0x20 || c == 0x7F ? 0x3F : c);
    }
    return out.toString();
  }

  /// Texto → STRING do S7 com capacidade [maxChars] (ocupa [maxChars] + 2
  /// bytes; o resto do campo vai zerado). Letra fora do Latin-1 vira "?".
  static Uint8List encodeString(String text, int maxChars) {
    if (maxChars < 0 || maxChars > 254) throw ArgumentError('STRING vai de 0 a 254 letras');
    final codes = text.runes.toList();
    if (codes.length > maxChars) {
      throw ArgumentError('texto com ${codes.length} letras; o campo aceita até $maxChars');
    }
    final out = Uint8List(maxChars + 2)
      ..[0] = maxChars
      ..[1] = codes.length;
    for (var i = 0; i < codes.length; i++) {
      out[2 + i] = codes[i] > 0xFF ? 0x3F : codes[i];
    }
    return out;
  }

  static bool _bool(Object v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    throw ArgumentError('BOOL espera liga/desliga');
  }

  static int _int(S7Type type, Object v, int min, int max) {
    if (v is! num || !v.isFinite) throw ArgumentError('${type.label} espera um número');
    if (v != v.roundToDouble()) throw ArgumentError('${type.label} aceita só número inteiro');
    final i = v.round();
    if (i < min || i > max) throw ArgumentError('${type.label} aceita de $min a $max');
    return i;
  }

  static double _real(Object v) {
    if (v is! num || !v.isFinite) throw ArgumentError('REAL espera um número');
    final d = v.toDouble();
    // Acima disso o float32 vira infinito: o CLP receberia um valor sem sentido.
    if (d.abs() > 3.4028234663852886e38) throw ArgumentError('REAL fora da faixa');
    return d;
  }
}
