import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'message_profile.dart';
import 'raw_link_error.dart';

/// Por que uma mensagem não virou valores.
enum FrameProblem {
  /// Checksum não confere (ou falta, ou não é hexadecimal).
  checksum,

  /// Chegou inteira, mas nenhum campo foi reconhecido: a regex não casou, a
  /// linha não tem `=` (um "OK" de confirmação), campos todos vazios.
  noFields,

  /// Passou do tamanho máximo sem terminar, ou o prefixo de tamanho é
  /// impossível: descartada.
  tooLong,

  /// Começou outra mensagem antes desta terminar (início/fim): o fim desta se
  /// perdeu no caminho.
  incomplete,
}

/// Uma mensagem separada do fluxo — boa ou com problema. As com problema
/// também saem, para a prévia ao vivo do editor mostrar "checksum errado" em
/// vez de simplesmente não mostrar nada.
class RawFrame {
  const RawFrame(this.bytes, this.fields, [this.problem]);

  /// A mensagem como chegou, delimitadores incluídos (no [FrameProblem.tooLong],
  /// só o começo dela).
  final Uint8List bytes;

  /// Campo → número (`int`/`double`) quando der, texto senão.
  final Map<String, Object> fields;
  final FrameProblem? problem;

  bool get ok => problem == null;

  /// Os bytes em texto legível, invisíveis escapados (`T=25.3\r\n`).
  String get preview => ByteEscapes.encode(String.fromCharCodes(bytes));

  @override
  String toString() => 'RawFrame($preview, $fields${ok ? '' : ', ${problem!.name}'})';
}

/// Interpretador do [MessageProfile]: separa mensagens de um fluxo de bytes
/// que chega em pedaços quaisquer, confere o checksum, tira os campos — e,
/// no sentido contrário, monta comandos a partir dos modelos.
///
/// Não sabe de socket nem de relógio: recebe bytes ([add]) e devolve
/// mensagens. Por isso é testável sem rede e é o mesmo código da prévia do
/// editor e do cliente de verdade.
///
/// Robustez, que é o que separa isto de um `split('\n')`:
///   • mensagem partida em vários pedaços fica no buffer até completar;
///   • várias mensagens numa leitura saem todas;
///   • lixo antes do início (marcador ou cabeçalho) é descartado e contado;
///   • mensagem sem fim não cresce a memória para sempre: passou de
///     [MessageProfile.maxFrameBytes], é descartada — e o rabo dela, quando o
///     fim finalmente chega, também, para não virar uma mensagem falsa;
///   • pacote binário com checksum errado escorrega um byte e procura o
///     próximo pacote que confira (ressincroniza depois de um byte perdido).
class MessageParser {
  MessageParser(this.profile) {
    final problems = profile.problems();
    if (problems.isNotEmpty) throw RawProfileError(problems.join('; '));
    final fields = profile.fields;
    if (fields is RegexFields) _regex = RegExp(fields.pattern);
    if (profile.mode == RawMode.polling) {
      try {
        pollBytes();
      } on RawCommandError catch (e) {
        throw RawProfileError('pedido do polling: ${e.message}');
      }
    }
  }

  final MessageProfile profile;
  RegExp? _regex;

  final List<int> _buf = [];

  /// Fim de linha: descartando o rabo de uma mensagem grande demais.
  bool _skipping = false;

  /// Binário: escorregando byte a byte atrás de um pacote que confira. Só a
  /// primeira falha do episódio sai como mensagem com problema — senão um
  /// byte perdido viraria uma rajada de "checksum errado" na prévia.
  bool _resyncing = false;

  int _discarded = 0;

  /// Bytes que não viraram mensagem (lixo, restos, mensagens grandes demais).
  int get discardedBytes => _discarded;

  /// Bytes esperando o resto da mensagem.
  int get buffered => _buf.length;

  void reset() {
    _buf.clear();
    _skipping = false;
    _resyncing = false;
  }

  // ── Recepção ─────────────────────────────────────────────────────────────────

  /// Junta [chunk] ao que já chegou e devolve as mensagens que fecharam.
  List<RawFrame> add(List<int> chunk) {
    _buf.addAll(chunk);
    final out = <RawFrame>[];
    final consumed = switch (profile.framing) {
      LineFraming f => _scanLine(f, out),
      FixedLengthFraming f => _scanFixed(f, out),
      StartEndFraming f => _scanStartEnd(f, out),
      LengthPrefixFraming f => _scanLengthPrefix(f, out),
    };
    if (consumed > 0) _buf.removeRange(0, consumed);
    return out;
  }

  /// Fim de um datagrama UDP. Com fim de linha, o que sobrou no buffer é uma
  /// mensagem inteira: ESP e Arduino por UDP costumam mandar um pacote por
  /// leitura **sem** o `\n` — o pacote já é a delimitação. Nos outros modos a
  /// mensagem se delimita sozinha e nada muda.
  List<RawFrame> endOfPacket() {
    final f = profile.framing;
    if (f is! LineFraming || _buf.isEmpty) return const [];
    final out = <RawFrame>[];
    if (_skipping) {
      _discarded += _buf.length;
      _skipping = false;
    } else {
      final raw = Uint8List.fromList(_buf);
      final body = _trimCr(f, raw, 0, raw.length);
      if (body.isNotEmpty) out.add(_finish(raw, body));
    }
    _buf.clear();
    return out;
  }

  int _scanLine(LineFraming f, List<RawFrame> out) {
    final end = bytesOf(f.end);
    final max = profile.maxFrameBytes;
    var pos = 0;
    while (true) {
      final idx = _indexOf(end, pos);
      if (idx < 0) {
        // Sem fim ainda. Guarda só o que pode ser o começo de um fim de linha
        // de mais de um byte (`\r` de um `\r\n` partido).
        final keepFrom = math.max(pos, _buf.length - (end.length - 1));
        if (_skipping) {
          _discarded += keepFrom - pos;
          return keepFrom;
        }
        if (_buf.length - pos > max) {
          out.add(RawFrame(_slice(pos, pos + max), const {}, FrameProblem.tooLong));
          _discarded += keepFrom - pos;
          _skipping = true;
          return keepFrom;
        }
        return pos;
      }
      final next = idx + end.length;
      if (_skipping) {
        _discarded += next - pos;
        _skipping = false;
      } else if (idx - pos > max) {
        out.add(RawFrame(_slice(pos, pos + max), const {}, FrameProblem.tooLong));
        _discarded += next - pos;
      } else {
        final body = _trimCr(f, _buf, pos, idx);
        // Linha em branco (o `\r\n\r\n` de muito sketch) não é mensagem.
        if (body.isNotEmpty) out.add(_finish(_slice(pos, next), body));
      }
      pos = next;
    }
  }

  List<int> _trimCr(LineFraming f, List<int> b, int start, int end) {
    var e = end;
    if (f.trimCr && e > start && b[e - 1] == 0x0D) e--;
    return b.sublist(start, e);
  }

  int _scanStartEnd(StartEndFraming f, List<RawFrame> out) {
    final start = bytesOf(f.start), end = bytesOf(f.end);
    final cs = profile.checksum;
    final trailer = cs.afterEnd ? cs.width : 0;
    final max = profile.maxFrameBytes;
    // Num texto, um novo início antes do fim quer dizer que o fim da
    // mensagem anterior se perdeu. Num binário o byte de início pode
    // aparecer no meio dos dados, então lá não dá para concluir isso.
    final restart = profile.fields is! BinaryFields && f.start != f.end;
    var pos = 0;
    while (true) {
      final si = _indexOf(start, pos);
      if (si < 0) {
        final keepFrom = math.max(pos, _buf.length - (start.length - 1));
        _discarded += keepFrom - pos;
        return keepFrom;
      }
      _discarded += si - pos;
      pos = si;
      final bodyStart = si + start.length;
      final ei = _indexOf(end, bodyStart);
      if (restart) {
        final again = _indexOf(start, bodyStart);
        if (again >= 0 && (ei < 0 || again < ei)) {
          out.add(RawFrame(_slice(si, again), const {}, FrameProblem.incomplete));
          _discarded += again - si;
          pos = again;
          continue;
        }
      }
      if (ei < 0 || ei - bodyStart > max) {
        if (_buf.length - bodyStart <= max) return pos; // ainda pode chegar o fim
        out.add(RawFrame(_slice(si, si + max), const {}, FrameProblem.tooLong));
        _discarded += bodyStart - si;
        pos = bodyStart; // o resto é lixo até o próximo início
        continue;
      }
      final next = ei + end.length + trailer;
      if (next > _buf.length) return pos; // falta o checksum que vem depois do fim
      final raw = _slice(si, next);
      out.add(cs.afterEnd
          ? _finish(raw, _buf.sublist(bodyStart, ei), covered: _buf.sublist(bodyStart, ei + end.length), csWire: _buf.sublist(ei + end.length, next))
          : _finish(raw, _buf.sublist(bodyStart, ei)));
      pos = next;
    }
  }

  int _scanFixed(FixedLengthFraming f, List<RawFrame> out) {
    final header = bytesOf(f.header);
    var pos = 0;
    while (true) {
      final at = _seekHeader(header, pos);
      if (at < 0) return math.max(pos, _buf.length - (header.length - 1));
      pos = at;
      if (_buf.length - pos < f.length) return pos;
      final raw = _slice(pos, pos + f.length);
      final frame = _finish(raw, raw);
      if (frame.problem == FrameProblem.checksum) {
        pos = _slip(frame, pos, out);
        continue;
      }
      _resyncing = false;
      out.add(frame);
      pos += f.length;
    }
  }

  int _scanLengthPrefix(LengthPrefixFraming f, List<RawFrame> out) {
    final header = bytesOf(f.header);
    var pos = 0;
    while (true) {
      final at = _seekHeader(header, pos);
      if (at < 0) return math.max(pos, _buf.length - (header.length - 1));
      pos = at;
      final lenAt = pos + header.length;
      if (_buf.length < lenAt + f.lengthBytes) return pos;
      final len = f.lengthBytes == 1
          ? _buf[lenAt]
          : f.bigEndian
              ? (_buf[lenAt] << 8) | _buf[lenAt + 1]
              : _buf[lenAt] | (_buf[lenAt + 1] << 8);
      final total = header.length + f.lengthBytes + len + f.adjust;
      if (len + f.adjust < 0 || total > profile.maxFrameBytes) {
        // Tamanho impossível: o fluxo está desalinhado (ou não é este
        // protocolo). Escorrega um byte e tenta de novo.
        pos = _slip(RawFrame(_slice(pos, lenAt + f.lengthBytes), const {}, FrameProblem.tooLong), pos, out);
        continue;
      }
      if (_buf.length - pos < total) return pos;
      final raw = _slice(pos, pos + total);
      final frame = _finish(raw, raw);
      if (frame.problem == FrameProblem.checksum) {
        pos = _slip(frame, pos, out);
        continue;
      }
      _resyncing = false;
      out.add(frame);
      pos += total;
    }
  }

  /// Próximo cabeçalho a partir de [pos], descartando o lixo antes dele; -1
  /// se não há (aí só o que pode ser começo de cabeçalho fica no buffer).
  int _seekHeader(List<int> header, int pos) {
    if (header.isEmpty) return pos;
    final at = _indexOf(header, pos);
    if (at < 0) {
      _discarded += math.max(0, _buf.length - (header.length - 1) - pos);
      return -1;
    }
    _discarded += at - pos;
    return at;
  }

  /// Pacote binário que não confere: anota (só o primeiro do episódio) e
  /// escorrega um byte.
  int _slip(RawFrame bad, int pos, List<RawFrame> out) {
    if (!_resyncing) out.add(bad);
    _resyncing = true;
    _discarded += 1;
    return pos + 1;
  }

  /// Confere o checksum e tira os campos do corpo.
  RawFrame _finish(Uint8List raw, List<int> body, {List<int>? covered, List<int>? csWire}) {
    final cs = profile.checksum;
    var content = body;
    if (cs.enabled) {
      List<int> cover;
      List<int> wire;
      if (cs.afterEnd) {
        cover = covered!;
        wire = csWire!;
      } else {
        final sep = bytesOf(cs.separator);
        final csAt = body.length - cs.width;
        final sepAt = csAt - sep.length;
        if (sepAt < 0 || !_matchesAt(body, sep, sepAt)) return RawFrame(raw, const {}, FrameProblem.checksum);
        cover = body.sublist(0, sepAt);
        wire = body.sublist(csAt);
        content = cover;
      }
      if (cs.skipStart > cover.length || cs.decodeValue(wire) != cs.compute(cover, cs.skipStart)) {
        return RawFrame(raw, const {}, FrameProblem.checksum);
      }
    }
    final fields = _fieldsOf(content);
    return RawFrame(raw, fields, fields.isEmpty ? FrameProblem.noFields : null);
  }

  // ── Campos ───────────────────────────────────────────────────────────────────

  Map<String, Object> _fieldsOf(List<int> content) {
    final format = profile.fields;
    if (format is BinaryFields) return _binaryFields(format, content);
    // Ruído grudado nas pontas (o que a placa cospe ao ligar, byte inválido
    // de UTF-8) sai; senão a primeira chave viraria "\x00\xFFT" em vez de
    // "T". Só nas pontas: no meio pode haver separador de controle de
    // propósito (`\x1E`, `\r\n` entre linhas de um bloco STX…ETX).
    final text = _decode(content).replaceAll(_edgeJunk, '');
    final out = <String, Object>{};
    // Campo vazio (`T=`, `25.3,,1`, NMEA sem sinal de GPS) não vira valor: a
    // variável fica com o último valor, em vez de receber um texto vazio.
    void put(String key, String raw) {
      final value = raw.trim();
      if (key.isNotEmpty && value.isNotEmpty) out[key] = toValue(value, decimalComma: profile.decimalComma);
    }

    switch (format) {
      case KeyValueFields(:final pairSeparator, :final assign):
        for (final pair in text.split(pairSeparator)) {
          final i = pair.indexOf(assign);
          if (i > 0) put(pair.substring(0, i).trim(), pair.substring(i + assign.length));
        }
      case CsvFields(:final separator, :final quote, :final names):
        final cells = splitCsv(text, separator, quote);
        for (var i = 0; i < cells.length; i++) {
          final name = i < names.length ? names[i].trim() : '';
          put(name.isEmpty ? '${i + 1}' : name, cells[i]);
        }
      case RegexFields():
        final m = _regex!.firstMatch(text);
        if (m != null) {
          final named = m.groupNames.toList();
          if (named.isNotEmpty) {
            for (final n in named) {
              put(n, m.namedGroup(n) ?? '');
            }
          } else {
            for (var i = 1; i <= m.groupCount; i++) {
              put('$i', m.group(i) ?? '');
            }
          }
        }
      case BinaryFields():
        break; // tratado acima
    }
    return out;
  }

  static final RegExp _edgeJunk = RegExp('^[\\x00-\\x1F\\x7F\\uFFFD]+|[\\x00-\\x1F\\x7F\\uFFFD]+\$');

  String _decode(List<int> bytes) =>
      profile.charset == RawCharset.latin1 ? latin1.decode(bytes) : utf8.decode(bytes, allowMalformed: true);

  List<int> _encode(String text) =>
      profile.charset == RawCharset.latin1 ? [for (final c in text.codeUnits) c & 0xFF] : utf8.encode(text);

  /// CSV de uma linha: separador fora de aspas separa; dentro, é texto; aspas
  /// dobradas dentro de aspas são uma aspa.
  static List<String> splitCsv(String text, String separator, String quote) {
    final out = <String>[];
    final cur = StringBuffer();
    var quoted = false;
    var i = 0;
    while (i < text.length) {
      if (quote.isNotEmpty && text.startsWith(quote, i)) {
        if (quoted && text.startsWith(quote, i + quote.length)) {
          cur.write(quote);
          i += quote.length * 2;
        } else {
          quoted = !quoted;
          i += quote.length;
        }
        continue;
      }
      if (!quoted && text.startsWith(separator, i)) {
        out.add(cur.toString());
        cur.clear();
        i += separator.length;
        continue;
      }
      cur.write(text[i]);
      i++;
    }
    out.add(cur.toString());
    return out;
  }

  static final RegExp _number = RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$');

  /// Número quando o texto inteiro é um número (`25.3`, `-7`, `1e3`); texto
  /// senão. Estrito de propósito: `25.3C` e `nan` continuam texto — número
  /// com unidade grudada se tira com regex, não com adivinhação.
  static Object toValue(String raw, {bool decimalComma = false}) {
    final s = raw.trim();
    final n = decimalComma ? s.replaceFirst(',', '.') : s;
    if (_number.hasMatch(n)) {
      if (!n.contains('.') && !n.contains('e') && !n.contains('E')) {
        final i = int.tryParse(n);
        if (i != null) return i;
      }
      final d = double.tryParse(n);
      if (d != null) return d;
    }
    return s;
  }

  Map<String, Object> _binaryFields(BinaryFields format, List<int> content) {
    final out = <String, Object>{};
    for (final f in format.items) {
      if (f.offset < 0 || f.offset + f.type.size > content.length) continue; // pacote curto: campo ausente
      final bd = ByteData(4);
      final order = _orderIndex(f.type.size, f.order);
      for (var k = 0; k < order.length; k++) {
        bd.setUint8(k, content[f.offset + order[k]]);
      }
      out[f.key] = switch (f.type) {
        RawType.u8 => bd.getUint8(0),
        RawType.i8 => bd.getInt8(0),
        RawType.u16 => bd.getUint16(0),
        RawType.i16 => bd.getInt16(0),
        RawType.u32 => bd.getUint32(0),
        RawType.i32 => bd.getInt32(0),
        RawType.f32 => bd.getFloat32(0),
      };
    }
    return out;
  }

  /// Posição no pacote de cada byte do valor, do mais significativo (A) ao
  /// menos. As permutações são involuções: servem para ler e para escrever.
  static List<int> _orderIndex(int size, RawByteOrder order) {
    if (size == 1) return const [0];
    final swapsBytes = order == RawByteOrder.badc || order == RawByteOrder.dcba;
    if (size == 2) return swapsBytes ? const [1, 0] : const [0, 1];
    return switch (order) {
      RawByteOrder.abcd => const [0, 1, 2, 3],
      RawByteOrder.cdab => const [2, 3, 0, 1],
      RawByteOrder.badc => const [1, 0, 3, 2],
      RawByteOrder.dcba => const [3, 2, 1, 0],
    };
  }

  // ── Comandos ─────────────────────────────────────────────────────────────────

  /// O pedido do polling, pronto para enviar.
  Uint8List pollBytes() => buildCommand(profile.pollRequest);

  /// Monta o comando [template] com [field] (`{campo}`), [value] (`{valor}`)
  /// e [args] (os outros marcadores). Lança [RawCommandError] sem enviar nada
  /// se falta um marcador ou o valor não cabe.
  Uint8List buildCommand(CommandTemplate template, {String? field, Object? value, Map<String, Object?> args = const {}}) {
    if (template.template.trim().isEmpty) throw const RawCommandError('modelo de comando vazio');
    return Uint8List.fromList(template.binary ? _buildBinary(template, value, args) : _buildText(template, field, value, args));
  }

  List<int> _buildText(CommandTemplate t, String? field, Object? value, Map<String, Object?> args) {
    final out = <int>[];
    var last = 0;
    for (final m in CommandTemplate.marker.allMatches(t.template)) {
      out.addAll(_encode(t.template.substring(last, m.start)));
      last = m.end;
      final name = m.group(1)!;
      final fmt = m.group(2);
      if (name == 'cs') {
        out.addAll(_checksumOf(out));
        continue;
      }
      if (name == 'campo') {
        if (field == null || field.isEmpty) throw const RawCommandError('o modelo usa {campo} e nenhum campo foi informado');
        out.addAll(_encode(field));
        continue;
      }
      final v = name == 'valor' ? value : args[name];
      if (v == null) throw RawCommandError('falta o valor de {$name} no comando');
      int? decimals;
      if (fmt != null) {
        decimals = int.tryParse(fmt);
        if (decimals == null || decimals > 10) throw RawCommandError('{$name:$fmt}: em modelo de texto o formato é o número de casas (0 a 10)');
      }
      out.addAll(_encode(_formatText(v, decimals)));
    }
    out.addAll(_encode(t.template.substring(last)));
    return out;
  }

  /// Ponto decimal (o `toFloat()` do Arduino não entende vírgula), sem `.0`
  /// em número inteiro, verdadeiro/falso como 1/0.
  String _formatText(Object v, int? decimals) {
    String s;
    if (v is bool) {
      s = v ? '1' : '0';
    } else if (v is num) {
      if (decimals != null) {
        s = v.toDouble().toStringAsFixed(decimals);
      } else if (v is double && v.isFinite && v == v.truncateToDouble() && v.abs() < 1e15) {
        s = v.toInt().toString();
      } else {
        s = v.toString();
      }
      if (profile.decimalComma) s = s.replaceFirst('.', ',');
    } else {
      s = '$v';
    }
    return s;
  }

  List<int> _buildBinary(CommandTemplate t, Object? value, Map<String, Object?> args) {
    final out = <int>[];
    for (final token in t.template.trim().split(RegExp(r'\s+'))) {
      final m = CommandTemplate.marker.matchAsPrefix(token);
      if (m != null && m.end == token.length) {
        final name = m.group(1)!;
        if (name == 'cs') {
          out.addAll(_checksumOf(out));
          continue;
        }
        final v = name == 'valor' ? value : args[name];
        if (v == null) throw RawCommandError('falta o valor de {$name} no comando');
        final type = RawType.values.where((x) => x.name == m.group(2)).firstOrNull;
        if (type == null) throw RawCommandError('{$name}: em modelo binário diga o tipo, ex.: {$name:u16}');
        out.addAll(_encodeBinary(v, type, t.order, name));
        continue;
      }
      // Bytes em hexadecimal: `AA`, ou grudados, `AA55`.
      if (token.length.isOdd || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(token)) {
        throw RawCommandError('"$token" não é byte em hexadecimal nem marcador');
      }
      for (var i = 0; i < token.length; i += 2) {
        out.add(int.parse(token.substring(i, i + 2), radix: 16));
      }
    }
    return out;
  }

  static const Map<RawType, (num, num)> _ranges = {
    RawType.u8: (0, 255),
    RawType.i8: (-128, 127),
    RawType.u16: (0, 65535),
    RawType.i16: (-32768, 32767),
    RawType.u32: (0, 4294967295),
    RawType.i32: (-2147483648, 2147483647),
  };

  List<int> _encodeBinary(Object v, RawType type, RawByteOrder order, String name) {
    final Object parsed = v is String ? toValue(v, decimalComma: profile.decimalComma) : v;
    final num n = switch (parsed) {
      bool b => b ? 1 : 0,
      num x => x,
      _ => throw RawCommandError('{$name}: "$v" não é número'),
    };
    final bd = ByteData(4);
    if (type == RawType.f32) {
      bd.setFloat32(0, n.toDouble());
    } else {
      final i = n.round();
      final (lo, hi) = _ranges[type]!;
      if (i < lo || i > hi) throw RawCommandError('valor $n não cabe em ${type.name} ($lo a $hi)');
      switch (type.size) {
        case 1:
          bd.setUint8(0, i & 0xFF);
        case 2:
          bd.setUint16(0, i & 0xFFFF);
        default:
          bd.setUint32(0, i & 0xFFFFFFFF);
      }
    }
    final idx = _orderIndex(type.size, order);
    return [for (var k = 0; k < type.size; k++) bd.getUint8(idx[k])];
  }

  /// `{cs}`: checksum do perfil sobre o que já foi montado (a partir de
  /// `skipStart`), na codificação do perfil. O separador logo antes do `{cs}`
  /// (`*` em `$SET,P,1*{cs}`) fica fora da conta, como na recepção — assim o
  /// equipamento confere o comando com a mesma regra das mensagens dele.
  List<int> _checksumOf(List<int> soFar) {
    final cs = profile.checksum;
    if (!cs.enabled) throw const RawCommandError('o modelo usa {cs} mas o perfil não tem checksum');
    final sep = bytesOf(cs.separator);
    final end = sep.isNotEmpty && _matchesAt(soFar, sep, soFar.length - sep.length) ? soFar.length - sep.length : soFar.length;
    return cs.encodeValue(cs.compute(soFar, math.min(cs.skipStart, end), end));
  }

  // ── Bytes ────────────────────────────────────────────────────────────────────

  Uint8List _slice(int start, int end) => Uint8List.fromList(_buf.sublist(start, math.min(end, _buf.length)));

  int _indexOf(List<int> pattern, int from) {
    if (pattern.isEmpty) return from;
    final last = _buf.length - pattern.length;
    outer:
    for (var i = from; i <= last; i++) {
      for (var k = 0; k < pattern.length; k++) {
        if (_buf[i + k] != pattern[k]) continue outer;
      }
      return i;
    }
    return -1;
  }

  static bool _matchesAt(List<int> b, List<int> pattern, int at) {
    if (at < 0 || at + pattern.length > b.length) return false;
    for (var k = 0; k < pattern.length; k++) {
      if (b[at + k] != pattern[k]) return false;
    }
    return true;
  }
}
