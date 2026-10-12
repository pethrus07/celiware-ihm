import '../../core/opcua/opcua_types.dart';
import '../../models/tag.dart';
import 'tag_codec.dart';

/// Variável ⇄ OPC UA, nos dois sentidos — o [TagCodec] do OPC UA.
///
/// Diferente do Modbus e do S7, aqui o **servidor diz o tipo**: o valor chega
/// num Variant (Double, UInt16, Boolean, String…). A variável só escolhe como
/// mostrar ("Liga / desliga", "Número inteiro", "Número com vírgula",
/// "Texto"); qualquer número vira número, com a escala da variável.
///
/// Na gravação o tipo também é o do servidor: mandar Double num nó UInt16 dá
/// BadTypeMismatch (conferido no asyncua). Por isso o driver guarda o tipo de
/// cada nó na leitura e o codec converte o valor para ele, conferindo faixa e
/// passo com as mesmas mensagens do Modbus ("aceita de 0 a 65535").
abstract final class OpcUaTagCodec {
  /// O nó de [tag]. Lança [TagValueError] — erro de configuração da
  /// variável, não de comunicação — sem NodeId ou com NodeId que não fecha.
  static NodeId plan(Tag tag) {
    final a = tag.opcua;
    if (a == null) throw const TagValueError('variável sem NodeId do OPC UA');
    try {
      return NodeId.parse(a.nodeId);
    } on FormatException catch (e) {
      throw TagValueError(e.message);
    }
  }

  // ── Leitura ──────────────────────────────────────────────────────────────────

  /// Variant → valor na unidade da tela. Lista do servidor numa variável de
  /// lista vira `List`; tipo que não combina com o que a variável mostra é
  /// erro de configuração dela, dito com a escolha certa.
  static Object decode(Tag tag, UaVariant v) {
    if (v.isEmpty) throw const TagValueError('o nó está sem valor no servidor');
    if (v.isArray) {
      final list = v.value as List;
      if (tag.isText || !tag.isArray) {
        throw TagValueError('o nó tem uma lista de ${list.length} valores: em Mais opções, diga quantos ler');
      }
      if (list.length < tag.length) throw TagValueError('o nó tem ${list.length} valores; a variável pede ${tag.length}');
      return [for (final e in list.take(tag.length)) _one(tag, v.type!, e)];
    }
    if (tag.isArray) throw const TagValueError('o nó tem um valor só, não uma lista');
    return _one(tag, v.type!, v.value);
  }

  static Object _one(Tag tag, UaType type, Object? raw) {
    if (tag.isText) {
      return switch (raw) {
        null => '',
        LocalizedText t => t.text ?? '',
        num n => '$n'.replaceAll('.', ','),
        _ => '$raw',
      };
    }
    if (tag.dataType == TagDataType.bool) {
      if (raw is bool) return raw;
      if (raw is num) return raw != 0;
      throw TagValueError('o nó é ${_kind(type)}: escolha ${_choice(type)}');
    }
    if (raw is num) return tag.hasScale ? raw * tag.scale + tag.offset : raw;
    if (raw is bool) throw const TagValueError('o nó é liga/desliga: escolha Liga / desliga');
    throw TagValueError('o nó é ${_kind(type)}: escolha ${_choice(type)}');
  }

  static String _kind(UaType t) => switch (t) {
        UaType.boolean => 'liga/desliga',
        UaType.string || UaType.localizedText || UaType.xmlElement => 'texto',
        _ when t.isNumber => 'número',
        _ => 'do tipo ${t.label}, que o app não mostra',
      };

  static String _choice(UaType t) => switch (t) {
        UaType.boolean => 'Liga / desliga',
        UaType.string || UaType.localizedText || UaType.xmlElement => 'Texto (em Mais opções)',
        UaType.float || UaType.double => 'Número com vírgula',
        _ when t.isNumber => 'Número inteiro',
        _ => 'outro nó',
      };

  /// O tipo de variável que combina com o tipo do nó — o "Navegar e
  /// escolher" preenche com ele. Só os quatro do cadastro OPC UA: qualquer
  /// inteiro é "Número inteiro" (o sinal e o tamanho quem sabe é o servidor).
  static TagDataType suggestedType(UaType? t) => switch (t) {
        UaType.boolean => TagDataType.bool,
        UaType.float || UaType.double => TagDataType.float32,
        null => TagDataType.uint16,
        _ when t.isInteger => TagDataType.uint16,
        _ => TagDataType.string,
      };

  // ── Escrita ──────────────────────────────────────────────────────────────────

  /// Valor na unidade da tela → Variant no tipo do nó ([type], aprendido na
  /// leitura). Valor que não cabe lança [TagValueError] com a faixa na
  /// unidade da tela, antes da rede.
  static UaVariant encode(Tag tag, UaType type, Object value) {
    if (tag.isText) throw TagValueError('"${tag.name}" é texto; não é gravável pela tela');
    if (type == UaType.boolean) {
      return UaVariant(type, switch (value) {
        bool b => b,
        num n => n != 0,
        _ => throw const TagValueError('Esperado liga/desliga'),
      });
    }
    final num v = switch (value) {
      bool b => b ? 1 : 0,
      num n => n,
      _ => throw TagValueError('"${tag.name}" espera um número'),
    };
    if (v.isNaN || v.isInfinite) throw const TagValueError('Número inválido');
    // Liga/desliga num nó numérico grava 1/0, sem escala.
    final raw = tag.dataType != TagDataType.bool && tag.hasScale ? (v - tag.offset) / tag.scale : v;
    if (type == UaType.float || type == UaType.double) return UaVariant(type, raw.toDouble());
    final range = type.range;
    if (range == null) throw TagValueError('o nó é do tipo ${type.label}, que o app não grava');
    // Tolerância: 75,2 ÷ 0,1 dá 751,9999999 em ponto flutuante.
    if ((raw - raw.round()).abs() > 1e-6) {
      throw TagValueError(tag.hasScale && tag.dataType != TagDataType.bool
          ? '"${tag.name}" aceita passos de ${_eng(tag, tag.scale.abs(), raw: false)}'
          : '"${tag.name}" só aceita número inteiro');
    }
    final n = raw.round();
    if (n < range.$1 || n > range.$2) {
      final a = _eng(tag, range.$1), b = _eng(tag, range.$2);
      final lo = tag.scale < 0 ? b : a, hi = tag.scale < 0 ? a : b;
      throw TagValueError('"${tag.name}" aceita de $lo a $hi');
    }
    return UaVariant(type, n);
  }

  /// Número cru → texto na unidade da tela (para as mensagens).
  static String _eng(Tag tag, num x, {bool raw = true}) {
    final v = raw && tag.hasScale ? x * tag.scale + tag.offset : x;
    final d = tag.displayDecimals;
    return (d > 0 ? v.toStringAsFixed(d) : v.round().toString()).replaceAll('.', ',');
  }
}
