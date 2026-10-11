import '../../models/tag.dart';
import 'tag_codec.dart';

/// Ainda não chegou mensagem do equipamento — não é erro: no streaming o
/// equipamento fala no ritmo dele. O "Lendo agora" mostra isto em tom
/// neutro, como o "esperando mensagem" do MQTT.
class RawNoMessageYet extends TagValueError {
  const RawNoMessageYet() : super('esperando mensagem do equipamento');
}

/// Campo da mensagem crua ⇄ valor de variável, nos dois sentidos — o
/// [TagCodec] do protocolo cru.
///
/// O `MessageParser` já entrega cada campo como número (quando o texto
/// inteiro é número) ou texto. Daqui sai o valor no tipo da variável e já na
/// escala de engenharia, igual ao Modbus e ao MQTT, para alarme, gráfico e
/// limites funcionarem sem saber de onde veio.
class RawCodec {
  RawCodec._();

  static const _onWords = {'true', 'on', 'ligado', 'liga', 'sim', 'yes', 'high', 'open', 'aberto'};
  static const _offWords = {'false', 'off', 'desligado', 'desliga', 'nao', 'não', 'no', 'low', 'closed', 'fechado'};

  // ── Leitura ──────────────────────────────────────────────────────────────────

  /// Campo (`int`, `double` ou `String`, como veio da mensagem) → `bool` /
  /// `num` / `String`.
  static Object decode(Tag tag, Object raw) {
    if (tag.isText) return raw is String ? raw : _plain(raw);
    if (tag.dataType == TagDataType.bool) return _asBool(raw);
    final n = _asNum(raw);
    final v = tag.hasScale ? n * tag.scale + tag.offset : n;
    // Número com vírgula é sempre double; inteiro que veio "23.0" fica 23.
    if (tag.dataType == TagDataType.float32) return v.toDouble();
    return v is double && v == v.roundToDouble() && !tag.hasScale ? v.toInt() : v;
  }

  static bool _asBool(Object v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = '$v'.trim().toLowerCase();
    if (_onWords.contains(s)) return true;
    if (_offWords.contains(s)) return false;
    throw TagValueError('"${_short('$v')}" não é liga/desliga');
  }

  static num _asNum(Object v) {
    if (v is num) {
      if (v.isFinite) return v;
      throw const TagValueError('número inválido');
    }
    if (v is bool) return v ? 1 : 0;
    throw TagValueError('"${_short('$v')}" não é número');
  }

  static String _plain(Object v) => v is double && v == v.roundToDouble() && v.abs() < 1e15 ? '${v.toInt()}' : '$v';

  static String _short(String s) => s.length <= 24 ? s : '${s.substring(0, 24)}…';

  /// O tipo que mais combina com um campo ouvido — a sugestão do "Ouvir o
  /// equipamento".
  static TagDataType guessType(Object value) {
    if (value is bool) return TagDataType.bool;
    if (value is int) return TagDataType.uint16;
    if (value is double) return TagDataType.float32;
    final s = '$value'.trim().toLowerCase();
    if (_onWords.contains(s) || _offWords.contains(s)) return TagDataType.bool;
    return TagDataType.string;
  }

  // ── Escrita ──────────────────────────────────────────────────────────────────

  /// Valor na unidade da tela → o que vai no `{valor}` do comando. Desfaz a
  /// escala antes, como no Modbus: com ÷10, gravar 75,2 manda 752.
  /// Liga/desliga vai como `true`/`false` — o modelo escreve 1/0.
  static Object encode(Tag tag, Object value) {
    if (tag.isText) throw TagValueError('"${tag.name}" é texto; não é gravável pela tela');
    if (tag.dataType == TagDataType.bool) {
      return switch (value) {
        bool b => b,
        num n => n != 0,
        _ => throw const TagValueError('Esperado liga/desliga'),
      };
    }
    if (value is! num) throw TagValueError('"${tag.name}" espera um número');
    if (value.isNaN || value.isInfinite) throw const TagValueError('Número inválido');
    var raw = tag.hasScale ? (value - tag.offset) / tag.scale : value;
    // 75,2 ÷ 0,1 dá 751,9999999 em ponto flutuante: arredonda o ruído.
    raw = double.parse(raw.toStringAsPrecision(12));
    if (tag.dataType == TagDataType.float32) return raw == raw.roundToDouble() && raw.abs() < 1e15 ? raw.round() : raw;
    if ((raw - raw.round()).abs() > 1e-6) {
      throw TagValueError(tag.hasScale
          ? '"${tag.name}" aceita passos de ${_plain(tag.scale.abs())}'.replaceAll('.', ',')
          : '"${tag.name}" só aceita número inteiro');
    }
    return raw.round();
  }
}
