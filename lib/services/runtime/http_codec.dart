import 'dart:convert';

import '../../core/rawlink/message_parser.dart';
import '../../models/http_config.dart';
import '../../models/mqtt_config.dart' show MqttBoolFormat;
import '../../models/tag.dart';
import 'mqtt_codec.dart';
import 'raw_codec.dart';
import 'tag_codec.dart';

/// Um pedido HTTP já montado (método, caminho relativo e corpo).
class HttpRequestPlan {
  const HttpRequestPlan(this.method, this.path, this.body);
  final HttpMethod method;
  final String path;

  /// Nulo = sem corpo (GET).
  final String? body;
}

/// Resposta HTTP ⇄ valor de variável, nos dois sentidos — o [TagCodec] do
/// HTTP.
///
/// Reaproveita o que já existe: o caminho JSON é o mesmo do MQTT
/// ([MqttCodec.pick]: `data.temperatura`, `itens[0].valor`), o texto vira
/// número pelo mesmo critério da mensagem crua ([MessageParser.toValue]) e o
/// valor entra no tipo e na escala da variável pelo [RawCodec] — então
/// alarme, gráfico e limites funcionam sem saber de onde veio.
class HttpCodec {
  HttpCodec._();

  // ── Leitura ──────────────────────────────────────────────────────────────────

  /// O pedido de leitura de [tag]. Lança [TagValueError] — erro de cadastro
  /// da variável, não de comunicação — sem requisição ou com uma que não fecha.
  static HttpRequestPlan readPlan(Tag tag) {
    final a = tag.http;
    if (a == null) throw const TagValueError('variável sem requisição HTTP');
    final problem = a.problem;
    if (problem != null) throw TagValueError(problem);
    return HttpRequestPlan(a.method, a.path.trim(), a.method.hasBody ? a.body : null);
  }

  /// Corpo da resposta → `bool` / `num` / `String`, ou lista de números.
  static Object decode(Tag tag, String body) {
    final a = tag.http ?? const HttpTagAddress();
    final select = a.select.trim();
    if (a.extract == HttpExtract.regex) {
      final RegExpMatch? m;
      try {
        m = RegExp(a.select).firstMatch(body);
      } on FormatException catch (e) {
        throw TagValueError('expressão regular inválida: ${e.message}');
      }
      if (m == null) throw const TagValueError('a expressão regular não achou nada na resposta');
      return _fromText(tag, regexValue(m));
    }
    if (select.isEmpty) {
      final text = body.trim();
      // Resposta JSON sem campo escolhido: lista vai para o gráfico de
      // barras; objeto pede o campo (melhor dizer isso que "não é número").
      if (text.startsWith('{')) {
        if (tag.isText) return text;
        throw const TagValueError('a resposta é um JSON: diga qual campo ler (ex.: data.temperatura)');
      }
      if (text.startsWith('[') || text.startsWith('"')) {
        final json = _tryJson(text);
        if (json != null) return _fromJson(tag, json, 'resposta');
      }
      return _fromText(tag, text);
    }
    final json = _tryJson(body.trim());
    if (json is! Map && json is! List) throw TagValueError('a resposta não é JSON (esperava o campo "$select")');
    final v = MqttCodec.pick(json, select);
    if (identical(v, MqttCodec.missing)) throw TagValueError('o campo "$select" não veio na resposta');
    return _fromJson(tag, v, '"$select"');
  }

  /// O texto que a expressão pegou: o grupo `valor`, senão o primeiro grupo,
  /// senão o trecho inteiro.
  static String regexValue(RegExpMatch m) {
    if (m.groupNames.contains('valor')) return m.namedGroup('valor') ?? '';
    if (m.groupCount >= 1) return m.group(1) ?? '';
    return m.group(0) ?? '';
  }

  static Object _fromJson(Tag tag, Object? v, String what) {
    if (v == null) throw TagValueError('o campo $what veio vazio (null)');
    if (tag.isArray) {
      if (v is! List) throw TagValueError('o campo $what não é uma lista ([1, 2, 3])');
      return [for (final e in v.take(tag.length)) _one(tag, e, what)];
    }
    return _one(tag, v, what);
  }

  static Object _one(Tag tag, Object? v, String what) {
    if (v == null) throw TagValueError('o campo $what veio vazio (null)');
    if (v is Map || v is List) {
      if (tag.isText) return jsonEncode(v);
      throw TagValueError('o campo $what é ${v is Map ? 'um objeto' : 'uma lista'}: escolha um campo dentro dele');
    }
    if (v is String) return _fromText(tag, v);
    if (tag.isText) return v is double && v == v.roundToDouble() ? '${v.toInt()}' : '$v';
    return RawCodec.decode(tag, v);
  }

  /// Texto → valor: número só quando o texto inteiro é número (`25.3`, e
  /// também `25,3` de firmware brasileiro); liga/desliga aceita 1/0,
  /// true/false, ON/OFF.
  static Object _fromText(Tag tag, String text) {
    if (tag.isText) return text.trim();
    final s = text.trim();
    if (s.isEmpty) throw const TagValueError('a resposta veio vazia');
    final decimalComma = s.contains(',') && !s.contains('.');
    final v = MessageParser.toValue(s, decimalComma: decimalComma);
    if (tag.dataType == TagDataType.bool && v is String) {
      final l = v.toLowerCase();
      if (l == '1') return true;
      if (l == '0') return false;
    }
    return RawCodec.decode(tag, v);
  }

  static Object? _tryJson(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  /// Campos de uma resposta JSON, para escolher com um toque depois do
  /// "Testar": caminho → valor de cada folha. Resposta que não é JSON
  /// devolve vazio.
  static List<(String, Object?)> fields(String body, {int max = 40}) => MqttCodec.fields(body, max: max);

  /// O tipo que mais combina com um valor da resposta.
  static TagDataType guessType(Object? value) => MqttCodec.guessType(value);

  // ── Escrita ──────────────────────────────────────────────────────────────────

  /// O valor na unidade da tela → o texto que entra no `{valor}`. Desfaz a
  /// escala antes, como no Modbus: com ÷10, gravar 75,2 manda 752. Número
  /// com ponto decimal (o que JSON e firmware entendem).
  static String valueText(Tag tag, Object value) {
    final raw = RawCodec.encode(tag, value);
    final format = tag.http?.boolFormat ?? MqttBoolFormat.oneZero;
    return switch (raw) {
      bool b => b ? format.on : format.off,
      double d when d.isFinite => d == d.roundToDouble() && d.abs() < 1e15 ? '${d.toInt()}' : '$d',
      _ => '$raw',
    };
  }

  /// O pedido de gravar [value] em [tag]: método, caminho (vazio = o da
  /// leitura) e corpo do comando, com `{valor}` trocado. Na URL o valor vai
  /// codificado; no corpo, como está. POST/PUT sem corpo escrito mandam só o
  /// valor.
  static HttpRequestPlan writePlan(Tag tag, Object value) {
    final a = tag.http;
    if (a == null) throw const TagValueError('variável sem requisição HTTP');
    if (tag.isText) throw TagValueError('"${tag.name}" é texto; não é gravável pela tela');
    final text = valueText(tag, value);
    final path = (a.writePath.trim().isEmpty ? a.path : a.writePath).trim();
    if (path.contains('://')) throw const TagValueError('o comando leva só o caminho (ex.: /rele): o endereço fica no cadastro do equipamento');
    final m = a.writeMethod;
    final body = m.hasBody ? (a.writeBody.isEmpty ? HttpTagAddress.valueMarker : a.writeBody) : null;
    return HttpRequestPlan(
      m,
      path.replaceAll(HttpTagAddress.valueMarker, Uri.encodeComponent(text)),
      body?.replaceAll(HttpTagAddress.valueMarker, text),
    );
  }

  /// Content-Type do corpo, pelo jeito dele: JSON quando parece JSON.
  static String contentTypeFor(String body) {
    final t = body.trimLeft();
    return t.startsWith('{') || t.startsWith('[') ? 'application/json; charset=utf-8' : 'text/plain; charset=utf-8';
  }
}
