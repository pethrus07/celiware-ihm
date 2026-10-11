import 'dart:convert';

import '../../models/mqtt_config.dart';
import '../../models/tag.dart';
import 'tag_codec.dart';

/// Ainda não chegou mensagem no tópico — não é erro: no MQTT o equipamento
/// fala quando quer, e tópico sem retain só mostra valor na próxima
/// publicação. O "Lendo agora" mostra isto em tom neutro.
class MqttNoMessageYet extends TagValueError {
  MqttNoMessageYet(String topic) : super('esperando mensagem em $topic');
}

/// Mensagem MQTT ⇄ valor de variável, nos dois sentidos — o [TagCodec] do
/// MQTT.
///
/// Tópico não tem tipo: o mesmo "23" pode ser número, texto ou ligado. Quem
/// decide é a variável ([Tag.dataType]); daqui sai o valor já na escala de
/// engenharia, igual ao Modbus, para alarme, gráfico e limites funcionarem
/// sem saber de onde veio.
class MqttCodec {
  MqttCodec._();

  // ── Leitura ──────────────────────────────────────────────────────────────────

  /// Payload (texto UTF-8) → `bool` / `num` / `String`, ou lista de números.
  static Object decode(Tag tag, String payload) {
    // Mensagem vazia é como o equipamento apaga o valor guardado (retain).
    if (payload.trim().isEmpty && !tag.isText) throw const TagValueError('mensagem vazia: o equipamento apagou o valor');
    final path = tag.mqtt?.jsonPath.trim() ?? '';
    Object? raw;
    if (path.isNotEmpty) {
      final json = _tryJson(payload);
      if (json == null || (json is! Map && json is! List)) {
        throw TagValueError('a mensagem não é JSON (esperava o campo "$path")');
      }
      raw = pick(json, path);
      if (identical(raw, _missing)) throw TagValueError('o campo "$path" não veio na mensagem');
    } else {
      final text = payload.trim();
      // Texto mostra a mensagem como veio (inclusive um JSON inteiro); só
      // perde as aspas de uma string JSON.
      if (tag.isText) return text.startsWith('"') ? _asText(_tryJson(text) ?? payload) : payload.trimRight();
      // Payload JSON sem campo escolhido: lista vai para o gráfico de barras;
      // objeto pede o campo (melhor dizer isso que "não é número").
      if (text.startsWith('{')) throw const TagValueError('a mensagem é um JSON: diga qual campo ler');
      raw = (text.startsWith('[') || text.startsWith('"')) ? (_tryJson(text) ?? payload) : payload;
    }
    return _convert(tag, raw);
  }

  static Object _convert(Tag tag, Object? raw) {
    if (tag.isText) return _asText(raw);
    if (tag.isArray) {
      if (raw is! List) throw const TagValueError('esperava uma lista JSON ([1, 2, 3])');
      return [for (final v in raw.take(tag.length)) _scaled(tag, _asNum(v))];
    }
    if (tag.dataType == TagDataType.bool) return _asBool(raw);
    final n = _asNum(raw);
    final v = _scaled(tag, n);
    // Número com vírgula é sempre double; inteiro que veio "23.0" fica 23.
    if (tag.dataType == TagDataType.float32) return v.toDouble();
    return v is double && v == v.roundToDouble() && !tag.hasScale ? v.toInt() : v;
  }

  static num _scaled(Tag tag, num raw) => tag.hasScale ? raw * tag.scale + tag.offset : raw;

  static const _onWords = {'true', '1', 'on', 'ligado', 'liga', 'sim', 'yes', 'high', 'open', 'aberto'};
  static const _offWords = {'false', '0', 'off', 'desligado', 'desliga', 'nao', 'não', 'no', 'low', 'closed', 'fechado'};

  /// Liga/desliga aceita todas as convenções de mercado — ler é tolerante;
  /// gravar é que segue o formato escolhido na variável.
  static bool _asBool(Object? v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final s = v.trim().toLowerCase();
      if (_onWords.contains(s)) return true;
      if (_offWords.contains(s)) return false;
      final n = num.tryParse(s);
      if (n != null) return n != 0;
      throw TagValueError('"${_short(v)}" não é liga/desliga');
    }
    throw TagValueError('"${_short(jsonEncode(v))}" não é liga/desliga');
  }

  static num _asNum(Object? v) {
    if (v is num) return v;
    if (v is bool) return v ? 1 : 0;
    if (v is String) {
      final s = v.trim();
      // Vírgula decimal (firmware brasileiro) também vale: "23,5".
      final n = num.tryParse(s) ?? (s.contains('.') ? null : num.tryParse(s.replaceAll(',', '.')));
      if (n != null && n.isFinite) return n;
      throw TagValueError('"${_short(v)}" não é número');
    }
    throw TagValueError('"${_short(jsonEncode(v))}" não é número');
  }

  static String _asText(Object? v) {
    if (v == null) return '';
    if (v is String) return v.trimRight();
    if (v is num || v is bool) return '$v';
    return jsonEncode(v);
  }

  static String _short(String s) => s.length <= 24 ? s : '${s.substring(0, 24)}…';

  static Object? _tryJson(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  static const Object _missing = Object();

  /// Valor no [path] do JSON: "sensores.temp", "valores[2]", "valores.2".
  /// Devolve um marcador próprio (não `null`) quando o campo não existe:
  /// `null` é um valor JSON válido e o erro precisa ser outro.
  static Object? pick(Object? json, String path) {
    final norm = path.replaceAllMapped(RegExp(r'\[(\d+)\]'), (m) => '.${m[1]}');
    Object? cur = json;
    for (final seg in norm.split('.')) {
      if (seg.isEmpty) continue;
      if (cur is Map && cur.containsKey(seg)) {
        cur = cur[seg];
      } else if (cur is List && int.tryParse(seg) != null && int.parse(seg) >= 0 && int.parse(seg) < cur.length) {
        cur = cur[int.parse(seg)];
      } else {
        return _missing;
      }
    }
    return cur;
  }

  /// Campos de uma mensagem JSON, para o "ouvir o broker": caminho → valor
  /// de cada folha. Mensagem que não é JSON (ou é um valor só) devolve vazio:
  /// o valor é o tópico inteiro.
  static List<(String, Object?)> fields(String payload, {int max = 40}) {
    final json = _tryJson(payload.trim());
    if (json is! Map && json is! List) return const [];
    final out = <(String, Object?)>[];
    void walk(Object? v, String at) {
      if (out.length >= max) return;
      if (v is Map) {
        for (final e in v.entries) {
          walk(e.value, at.isEmpty ? '${e.key}' : '$at.${e.key}');
        }
      } else if (v is List) {
        // Lista de números é um valor só (gráfico de barras); lista de
        // objetos se abre por posição.
        if (v.isNotEmpty && v.every((x) => x is num)) {
          out.add((at, v));
        } else {
          for (var i = 0; i < v.length; i++) {
            walk(v[i], at.isEmpty ? '$i' : '$at.$i');
          }
        }
      } else if (at.isNotEmpty) {
        out.add((at, v));
      }
    }

    walk(json, '');
    return out;
  }

  /// O tipo que mais combina com um valor ouvido — sugestão do "ouvir".
  static TagDataType guessType(Object? value) {
    if (value is bool) return TagDataType.bool;
    if (value is num) return value == value.roundToDouble() ? TagDataType.uint16 : TagDataType.float32;
    if (value is String) {
      final s = value.trim().toLowerCase();
      if (s == 'true' || s == 'false' || s == 'on' || s == 'off') return TagDataType.bool;
      final n = num.tryParse(s);
      if (n != null) return n == n.roundToDouble() && !s.contains('.') ? TagDataType.uint16 : TagDataType.float32;
    }
    return TagDataType.string;
  }

  // ── Escrita ──────────────────────────────────────────────────────────────────

  /// Valor na unidade da tela → payload do comando. Desfaz a escala antes,
  /// como no Modbus: com ÷10, gravar 75,2 manda "752".
  static String encode(Tag tag, Object value) {
    final a = tag.mqtt ?? const MqttAddress(topic: '');
    if (tag.isText) throw TagValueError('"${tag.name}" é texto; não é gravável pela tela');
    final Object out;
    if (tag.dataType == TagDataType.bool) {
      final on = switch (value) {
        bool b => b,
        num n => n != 0,
        _ => throw const TagValueError('Esperado liga/desliga'),
      };
      out = switch (a.boolFormat) {
        MqttBoolFormat.oneZero => on ? 1 : 0,
        MqttBoolFormat.trueFalse => on,
        MqttBoolFormat.onOff => on ? 'ON' : 'OFF',
      };
    } else {
      if (value is! num) throw TagValueError('"${tag.name}" espera um número');
      if (value.isNaN || value.isInfinite) throw const TagValueError('Número inválido');
      var raw = tag.hasScale ? (value - tag.offset) / tag.scale : value;
      // 75,2 ÷ 0,1 dá 751,9999999 em ponto flutuante: arredonda o ruído.
      raw = double.parse(raw.toStringAsPrecision(12));
      if (tag.dataType != TagDataType.float32) {
        if ((raw - raw.round()).abs() > 1e-6) {
          throw TagValueError(tag.hasScale
              ? '"${tag.name}" aceita passos de ${_plain(tag.scale.abs())}'.replaceAll('.', ',')
              : '"${tag.name}" só aceita número inteiro');
        }
        out = raw.round();
      } else {
        out = raw == raw.roundToDouble() ? raw.round() : raw;
      }
    }
    if (a.commandJson && a.jsonPath.trim().isNotEmpty) return jsonEncode(_nest(a.jsonPath.trim(), out));
    return out is String ? out : jsonEncode(out);
  }

  static String _plain(num v) => v == v.roundToDouble() ? '${v.round()}' : '$v';

  /// "a.b" + 5 → {"a": {"b": 5}}.
  static Object _nest(String path, Object value) {
    final parts = path.replaceAllMapped(RegExp(r'\[(\d+)\]'), (m) => '.${m[1]}').split('.').where((p) => p.isNotEmpty).toList();
    Object v = value;
    for (final p in parts.reversed) {
      v = {p: v};
    }
    return v;
  }
}
