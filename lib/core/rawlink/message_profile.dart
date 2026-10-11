/// Perfil de mensagem do protocolo cru: como um Arduino, ESP, balança ou
/// leitor fala, descrito em dados — sem programar.
///
/// Equipamento "cru" não tem norma: cada um inventa a sua linha de texto
/// (`T=25.3;P=1\n`, `25.3,1,OK\n`, `<ST,GS,+012.345kg>`) ou o seu pacote
/// binário. Em vez de um driver por equipamento, o app guarda **um perfil**
/// dentro do arquivo do projeto e um interpretador genérico
/// (`MessageParser`) segue o perfil. As quatro perguntas do perfil:
///
///   1. **onde a mensagem termina** no fluxo de bytes ([FrameSpec]);
///   2. **se ela confere** ([ChecksumSpec], opcional);
///   3. **como tirar os campos** dela ([FieldFormat]);
///   4. **quem fala primeiro** ([RawMode]: o equipamento manda sozinho, ou o
///      app pede a cada [MessageProfile.pollMs]) e como montar comandos
///      ([CommandTemplate]).
///
/// Tudo imutável e serializável em JSON. Sequências de bytes (fim de linha,
/// marcadores, cabeçalhos) ficam em memória como `String` em que cada
/// caractere é um byte (`'\r\n'`, `'\x02'`, `'\xAA\x55'` — a mesma escrita do
/// Dart), e no JSON na notação de [ByteEscapes], que é também a que o editor
/// de perfil mostra e aceita.
library;

import '../modbus/modbus_framing.dart' show ModbusFrames;

// ── Notação de bytes ─────────────────────────────────────────────────────────

/// Escreve e lê bytes invisíveis como texto: `\n`, `\r`, `\t`, `\0`, `\\` e
/// `\xHH`.
///
/// Fim de linha e STX/ETX não se digitam num campo de uma linha só, e um
/// arquivo de projeto com bytes de controle crus fica ilegível. Byte acima de
/// 0x7F também vira `\xHH`: num cabeçalho binário (`\xAA\x55`) é o que o
/// manual mostra, e a ida e volta é exata para qualquer texto.
class ByteEscapes {
  ByteEscapes._();

  static final RegExp _hex2 = RegExp(r'^[0-9a-fA-F]{2}$');

  static String encode(String s) {
    final out = StringBuffer();
    for (final c in s.codeUnits) {
      switch (c) {
        case 0x5C:
          out.write(r'\\');
        case 0x0A:
          out.write(r'\n');
        case 0x0D:
          out.write(r'\r');
        case 0x09:
          out.write(r'\t');
        case 0x00:
          out.write(r'\0');
        default:
          if (c < 0x20 || (c >= 0x7F && c <= 0xFF)) {
            out.write('\\x${c.toRadixString(16).toUpperCase().padLeft(2, '0')}');
          } else {
            out.writeCharCode(c);
          }
      }
    }
    return out.toString();
  }

  /// Contrabarra que não forma escape conhecido (`\q`, `\x` sem dois dígitos,
  /// barra no fim) fica como está: o editor nunca come o que a pessoa digitou.
  static String decode(String s) {
    final out = StringBuffer();
    var i = 0;
    while (i < s.length) {
      final c = s[i];
      if (c != r'\' || i + 1 >= s.length) {
        out.write(c);
        i++;
        continue;
      }
      final n = s[i + 1];
      switch (n) {
        case 'n':
          out.write('\n');
        case 'r':
          out.write('\r');
        case 't':
          out.write('\t');
        case '0':
          out.writeCharCode(0);
        case r'\':
          out.write(r'\');
        case 'x':
          // Confere os dois dígitos antes: int.tryParse aceitaria "4 " (ele
          // ignora espaço) e comeria o espaço que a pessoa digitou.
          final hex = i + 3 < s.length ? s.substring(i + 2, i + 4) : '';
          if (_hex2.hasMatch(hex)) {
            out.writeCharCode(int.parse(hex, radix: 16));
            i += 4;
            continue;
          }
          out.write(r'\x');
        default:
          out.write('\\$n');
      }
      i += 2;
    }
    return out.toString();
  }
}

/// Bytes de uma sequência em memória (cada caractere = um byte).
List<int> bytesOf(String s) => [for (final c in s.codeUnits) c & 0xFF];

bool _fitsBytes(String s) => s.codeUnits.every((c) => c <= 0xFF);

// ── 1. Delimitação do quadro ─────────────────────────────────────────────────

/// Como achar onde uma mensagem termina num fluxo que chega em pedaços.
///
/// Regra do que sobra como corpo da mensagem: delimitador **de texto** (fim
/// de linha, início/fim) sai; cabeçalho **binário** (tamanho fixo, prefixo de
/// tamanho) fica, para os deslocamentos dos campos baterem com o manual, que
/// conta a partir do primeiro byte do pacote.
sealed class FrameSpec {
  const FrameSpec();

  Map<String, dynamic> toJson();

  static FrameSpec fromJson(Object? json) {
    if (json is! Map) return const LineFraming();
    final j = Map<String, dynamic>.from(json);
    String bytes(String key, String fallback) => _escaped(j[key], fallback);
    switch (j['type']) {
      case 'fixed':
        return FixedLengthFraming(length: (j['length'] as int?) ?? 8, header: bytes('header', ''));
      case 'startEnd':
        return StartEndFraming(start: bytes('start', '\x02'), end: bytes('end', '\x03'));
      case 'lengthPrefix':
        return LengthPrefixFraming(
          header: bytes('header', ''),
          lengthBytes: (j['lengthBytes'] as int?) ?? 1,
          bigEndian: (j['bigEndian'] as bool?) ?? true,
          adjust: (j['adjust'] as int?) ?? 0,
        );
      default:
        return LineFraming(end: bytes('end', '\n'), trimCr: (j['trimCr'] as bool?) ?? true);
    }
  }
}

/// Uma mensagem por linha — o `Serial.println` do Arduino. O fim é
/// configurável (`\n`, `\r\n`, `\r`, `;`, `\x03`…).
class LineFraming extends FrameSpec {
  const LineFraming({this.end = '\n', this.trimCr = true});

  final String end;

  /// Com fim `\n`, tira o `\r` que sobra no fim: aceita `\n` e `\r\n` sem a
  /// pessoa precisar saber qual dos dois o equipamento manda.
  final bool trimCr;

  @override
  Map<String, dynamic> toJson() => {'type': 'line', 'end': ByteEscapes.encode(end), 'trimCr': trimCr};
}

/// Pacote de tamanho fixo. O [header] opcional (ex.: `\xAA\x55`) é o que
/// permite ressincronizar quando um byte se perde no caminho — sem ele, um
/// byte perdido desalinha todos os pacotes seguintes (com checksum, o
/// interpretador escorrega byte a byte até voltar a conferir).
class FixedLengthFraming extends FrameSpec {
  const FixedLengthFraming({required this.length, this.header = ''});

  /// Tamanho total do pacote, cabeçalho incluído.
  final int length;
  final String header;

  @override
  Map<String, dynamic> toJson() => {'type': 'fixed', 'length': length, 'header': ByteEscapes.encode(header)};
}

/// Mensagem entre marcadores: STX…ETX, `<`…`>`, `$`…`\n`. O que vier antes do
/// início é lixo e é descartado.
class StartEndFraming extends FrameSpec {
  const StartEndFraming({this.start = '\x02', this.end = '\x03'});

  final String start;
  final String end;

  @override
  Map<String, dynamic> toJson() => {'type': 'startEnd', 'start': ByteEscapes.encode(start), 'end': ByteEscapes.encode(end)};
}

/// Pacote binário com o tamanho escrito no começo: `[cabeçalho][tamanho][…]`.
///
/// Os protocolos discordam do que o tamanho conta (só os dados? dados +
/// checksum? o pacote inteiro?). Em vez de uma opção para cada caso, uma
/// conta só: bytes que vêm **depois** do campo de tamanho = valor + [adjust].
/// Conta só os dados e há 1 byte de checksum depois: `adjust = 1`. Conta o
/// pacote inteiro com 1 byte de cabeçalho e 1 de tamanho: `adjust = -2`.
class LengthPrefixFraming extends FrameSpec {
  const LengthPrefixFraming({this.header = '', this.lengthBytes = 1, this.bigEndian = true, this.adjust = 0});

  final String header;

  /// 1 ou 2.
  final int lengthBytes;
  final bool bigEndian;
  final int adjust;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'lengthPrefix',
        'header': ByteEscapes.encode(header),
        'lengthBytes': lengthBytes,
        'bigEndian': bigEndian,
        'adjust': adjust,
      };
}

// ── 2. Checksum ──────────────────────────────────────────────────────────────

enum ChecksumKind {
  none,

  /// OU-exclusivo de todos os bytes — o "BCC" de balanças e o `*hh` do NMEA.
  xor,

  /// Soma dos bytes, só os 8 bits de baixo.
  sum8,

  /// CRC16 do Modbus (polinômio 0xA001, semente 0xFFFF).
  crc16,
}

enum ChecksumEncoding {
  /// Os bytes do valor, crus.
  binary,

  /// O valor escrito em hexadecimal (2 letras para 8 bits, 4 para o CRC16) —
  /// comum em protocolo de texto, que não pode ter byte de controle no meio.
  hex,
}

/// Checksum opcional e onde ele está.
///
/// Por padrão fica **no fim do corpo** da mensagem (antes do fim de linha ou
/// do marcador de fim), opcionalmente depois de um [separator] (o `*` do
/// NMEA), e cobre o corpo do byte [skipStart] até antes do separador. Com
/// [afterEnd] ele vem **depois** do marcador de fim e cobre o corpo + o
/// marcador — o STX…ETX BCC de balanças e leitores; só vale com
/// [StartEndFraming].
class ChecksumSpec {
  const ChecksumSpec({
    this.kind = ChecksumKind.none,
    this.encoding = ChecksumEncoding.binary,
    this.separator = '',
    this.skipStart = 0,
    this.afterEnd = false,
    this.lowByteFirst = true,
  });

  static const ChecksumSpec none = ChecksumSpec();

  final ChecksumKind kind;
  final ChecksumEncoding encoding;
  final String separator;

  /// Bytes do começo do corpo que não entram na conta (ex.: o `$` do NMEA).
  final int skipStart;
  final bool afterEnd;

  /// CRC16 binário: byte baixo primeiro, como no Modbus. Em hexadecimal o
  /// valor é escrito como número (mais significativo primeiro).
  final bool lowByteFirst;

  bool get enabled => kind != ChecksumKind.none;

  /// Tamanho do valor, em bytes.
  int get size => switch (kind) { ChecksumKind.none => 0, ChecksumKind.crc16 => 2, _ => 1 };

  /// Bytes que o checksum ocupa na mensagem.
  int get width => encoding == ChecksumEncoding.hex ? size * 2 : size;

  int compute(List<int> bytes, [int start = 0, int? end]) {
    final e = end ?? bytes.length;
    switch (kind) {
      case ChecksumKind.none:
        return 0;
      case ChecksumKind.xor:
        var x = 0;
        for (var i = start; i < e; i++) {
          x ^= bytes[i] & 0xFF;
        }
        return x;
      case ChecksumKind.sum8:
        var s = 0;
        for (var i = start; i < e; i++) {
          s = (s + (bytes[i] & 0xFF)) & 0xFF;
        }
        return s;
      case ChecksumKind.crc16:
        return ModbusFrames.crc16(bytes, start, e);
    }
  }

  /// O valor como vai na mensagem ([width] bytes).
  List<int> encodeValue(int value) {
    if (encoding == ChecksumEncoding.hex) {
      return value.toRadixString(16).toUpperCase().padLeft(size * 2, '0').codeUnits;
    }
    if (size == 1) return [value & 0xFF];
    final lo = value & 0xFF, hi = (value >> 8) & 0xFF;
    return lowByteFirst ? [lo, hi] : [hi, lo];
  }

  /// O valor lido da mensagem, ou nulo se não é hexadecimal válido.
  int? decodeValue(List<int> wire) {
    if (wire.length != width) return null;
    if (encoding == ChecksumEncoding.hex) {
      final text = String.fromCharCodes(wire);
      if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(text)) return null;
      return int.parse(text, radix: 16);
    }
    if (size == 1) return wire[0];
    return lowByteFirst ? wire[0] | (wire[1] << 8) : (wire[0] << 8) | wire[1];
  }

  Map<String, dynamic> toJson() => enabled
      ? {
          'kind': kind.name,
          'encoding': encoding.name,
          if (separator.isNotEmpty) 'separator': ByteEscapes.encode(separator),
          if (skipStart != 0) 'skipStart': skipStart,
          if (afterEnd) 'afterEnd': true,
          if (!lowByteFirst) 'lowByteFirst': false,
        }
      : {'kind': 'none'};

  static ChecksumSpec fromJson(Object? json) {
    if (json is! Map) return none;
    final j = Map<String, dynamic>.from(json);
    return ChecksumSpec(
      kind: _byName(ChecksumKind.values, j['kind'], ChecksumKind.none),
      encoding: _byName(ChecksumEncoding.values, j['encoding'], ChecksumEncoding.binary),
      separator: ByteEscapes.decode((j['separator'] as String?) ?? ''),
      skipStart: (j['skipStart'] as int?) ?? 0,
      afterEnd: (j['afterEnd'] as bool?) ?? false,
      lowByteFirst: (j['lowByteFirst'] as bool?) ?? true,
    );
  }
}

// ── 3. Campos ────────────────────────────────────────────────────────────────

/// Como tirar os campos de uma mensagem. Cada campo vira uma chave (`T`,
/// `temp`, `1`); a variável do projeto aponta só para a chave — escala e
/// unidade continuam na variável, como no Modbus.
sealed class FieldFormat {
  const FieldFormat();

  Map<String, dynamic> toJson();

  static FieldFormat fromJson(Object? json) {
    if (json is! Map) return const KeyValueFields();
    final j = Map<String, dynamic>.from(json);
    String text(String key, String fallback) => _escaped(j[key], fallback);
    switch (j['type']) {
      case 'csv':
        return CsvFields(
          separator: text('separator', ','),
          quote: text('quote', '"'),
          names: [for (final n in (j['names'] as List?) ?? const []) '$n'],
        );
      case 'regex':
        return RegexFields((j['pattern'] as String?) ?? '');
      case 'binary':
        return BinaryFields([
          for (final f in (j['items'] as List?) ?? const [])
            if (f is Map) BinaryField.fromJson(Map<String, dynamic>.from(f)),
        ]);
      default:
        return KeyValueFields(pairSeparator: text('pair', ';'), assign: text('assign', '='));
    }
  }
}

/// `T=25.3;P=1` — pares chave/valor. Separadores configuráveis
/// (`T:25.3, P:1` = par `,` e atribuição `:`); espaços em volta saem.
class KeyValueFields extends FieldFormat {
  const KeyValueFields({this.pairSeparator = ';', this.assign = '='});

  final String pairSeparator;
  final String assign;

  @override
  Map<String, dynamic> toJson() => {'type': 'keyValue', 'pair': ByteEscapes.encode(pairSeparator), 'assign': ByteEscapes.encode(assign)};
}

/// `25.3,1,OK` — por posição. A chave é o nome dado em [names] ou, sem nome,
/// a posição contada a partir de 1 (`1`, `2`, `3`), como a pessoa conta.
/// Campo entre [quote] pode conter o separador; aspas dobradas = uma aspa.
class CsvFields extends FieldFormat {
  const CsvFields({this.separator = ',', this.quote = '"', this.names = const []});

  final String separator;

  /// Vazio = sem aspas.
  final String quote;
  final List<String> names;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'csv',
        'separator': ByteEscapes.encode(separator),
        'quote': ByteEscapes.encode(quote),
        if (names.isNotEmpty) 'names': names,
      };
}

/// Expressão regular com grupos nomeados: `T=(?<temp>-?\d+\.\d)` dá o campo
/// `temp`. Sem grupo nomeado, os grupos valem pela posição (`1`, `2`…). É a
/// saída para o formato que nenhum dos outros cobre (ex.: número com unidade
/// grudada, `+012.345kg`).
class RegexFields extends FieldFormat {
  const RegexFields(this.pattern);

  final String pattern;

  @override
  Map<String, dynamic> toJson() => {'type': 'regex', 'pattern': pattern};
}

/// Pacote binário: cada campo num deslocamento, com tipo e ordem de bytes.
class BinaryFields extends FieldFormat {
  const BinaryFields(this.items);

  final List<BinaryField> items;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'binary',
        'items': [for (final f in items) f.toJson()],
      };
}

enum RawType { u8, i8, u16, i16, u32, i32, f32 }

extension RawTypeMeta on RawType {
  int get size => switch (this) { RawType.u8 || RawType.i8 => 1, RawType.u16 || RawType.i16 => 2, _ => 4 };
}

/// Ordem dos bytes de um valor de 16/32 bits — as mesmas quatro do Modbus
/// (`ByteOrder` da variável), com os mesmos nomes, para o técnico reconhecer.
/// Bytes do valor de A (mais significativo) a D:
///
/// | ordem | no pacote | 16 bits |
/// |-------|-----------|---------|
/// | ABCD  | A B C D   | A B (big-endian) |
/// | CDAB  | C D A B   | A B |
/// | BADC  | B A D C   | B A (little-endian) |
/// | DCBA  | D C B A   | B A (little-endian, o do Arduino) |
///
/// O núcleo não conhece os modelos do app, por isso a cópia em vez do
/// `ByteOrder` de `tag.dart`.
enum RawByteOrder { abcd, cdab, badc, dcba }

class BinaryField {
  const BinaryField({required this.key, required this.offset, this.type = RawType.u16, this.order = RawByteOrder.abcd});

  final String key;

  /// Byte onde o campo começa, contado do primeiro byte do pacote (cabeçalho
  /// incluído), como nos manuais.
  final int offset;
  final RawType type;
  final RawByteOrder order;

  Map<String, dynamic> toJson() => {'key': key, 'offset': offset, 'type': type.name, 'order': order.name};

  factory BinaryField.fromJson(Map<String, dynamic> j) => BinaryField(
        key: (j['key'] as String?) ?? '',
        offset: (j['offset'] as int?) ?? 0,
        type: _byName(RawType.values, j['type'], RawType.u16),
        order: _byName(RawByteOrder.values, j['order'], RawByteOrder.abcd),
      );
}

// ── 4. Quem fala primeiro e comandos ─────────────────────────────────────────

enum RawMode {
  /// O equipamento manda sozinho, no ritmo dele (o `loop()` do Arduino).
  streaming,

  /// O app manda [MessageProfile.pollRequest] a cada [MessageProfile.pollMs]
  /// e o equipamento responde.
  polling,
}

/// Como os textos viram bytes e vice-versa. Arduino moderno manda UTF-8
/// (`Serial.print("°C")`); balança e leitor antigos, Latin-1. Errar aqui só
/// estraga acento e símbolo — número e delimitador são ASCII nos dois.
enum RawCharset { utf8, latin1 }

/// Modelo de comando.
///
/// **Texto:** `SET {campo}={valor}\n`. Marcadores: `{campo}` (a chave),
/// `{valor}` (número com ponto decimal, como o `toFloat()` do Arduino
/// entende; `{valor:2}` fixa 2 casas), `{cs}` (checksum do perfil em
/// hexadecimal sobre o que vem antes) e qualquer `{nome}` passado em `args`.
/// Chave que não forma marcador (`{"p":1}`) sai como está.
///
/// **Binário:** bytes em hexadecimal separados por espaço e marcadores com
/// tipo: `AA 01 {valor:u16} {cs}`. A ordem de bytes do valor é [order];
/// `{cs}` é o checksum do perfil, cru, sobre os bytes anteriores.
class CommandTemplate {
  const CommandTemplate.text(this.template, {this.name = '', this.field = ''})
      : binary = false,
        order = RawByteOrder.abcd;

  const CommandTemplate.binary(this.template, {this.name = '', this.field = '', this.order = RawByteOrder.abcd}) : binary = true;

  /// Rótulo (botão "Zerar balança"); opcional.
  final String name;

  /// Para qual chave este modelo grava. Vazio = qualquer uma (usa `{campo}`).
  final String field;
  final String template;
  final bool binary;
  final RawByteOrder order;

  /// Marcador: `{` + nome + opcional `:formato` + `}`.
  static final RegExp marker = RegExp(r'\{([A-Za-z_][A-Za-z0-9_]*)(?::([A-Za-z0-9]+))?\}');

  /// Leva valor — só um modelo assim serve para gravar uma variável.
  bool get usesValue => marker.allMatches(template).any((m) => m.group(1) == 'valor');

  Map<String, dynamic> toJson() => binary
      ? {if (name.isNotEmpty) 'name': name, if (field.isNotEmpty) 'field': field, 'binary': template, 'order': order.name}
      : {if (name.isNotEmpty) 'name': name, if (field.isNotEmpty) 'field': field, 'text': ByteEscapes.encode(template)};

  static CommandTemplate fromJson(Object? json) {
    if (json is! Map) return const CommandTemplate.text('');
    final j = Map<String, dynamic>.from(json);
    final name = (j['name'] as String?) ?? '';
    final field = (j['field'] as String?) ?? '';
    if (j['binary'] is String) {
      return CommandTemplate.binary(j['binary'] as String,
          name: name, field: field, order: _byName(RawByteOrder.values, j['order'], RawByteOrder.abcd));
    }
    return CommandTemplate.text(ByteEscapes.decode((j['text'] as String?) ?? ''), name: name, field: field);
  }
}

// ── O perfil ─────────────────────────────────────────────────────────────────

class MessageProfile {
  const MessageProfile({
    this.framing = const LineFraming(),
    this.checksum = ChecksumSpec.none,
    this.fields = const KeyValueFields(),
    this.mode = RawMode.streaming,
    this.pollRequest = const CommandTemplate.text('?\n'),
    this.pollMs = 1000,
    this.staleAfterMs = 5000,
    this.commands = const [],
    this.charset = RawCharset.utf8,
    this.decimalComma = false,
    this.maxFrameBytes = 1024,
  });

  final FrameSpec framing;
  final ChecksumSpec checksum;
  final FieldFormat fields;
  final RawMode mode;

  /// O pedido do polling. É um modelo como os comandos, para poder levar
  /// checksum (`{cs}`) ou ser binário.
  final CommandTemplate pollRequest;
  final int pollMs;

  /// Sem mensagem válida há mais que isto = sem comunicação. Vale para os
  /// dois modos: no streaming é o único jeito de saber que o equipamento
  /// parou; no polling cobre o pedido que nunca é respondido.
  final int staleAfterMs;
  final List<CommandTemplate> commands;
  final RawCharset charset;

  /// Aceita `25,3` como 25,3 nos campos de texto (balança brasileira). Não
  /// combina com CSV separado por vírgula — aí a vírgula é do separador.
  final bool decimalComma;

  /// Maior mensagem aceita. Protege a memória de um fluxo sem fim de linha
  /// (equipamento configurado errado, baud trocado): passou disso, o pedaço é
  /// descartado e o interpretador espera a próxima mensagem.
  final int maxFrameBytes;

  /// O modelo que grava [key]: o específico daquela chave ou, na falta, o
  /// genérico (sem chave) que leva valor.
  CommandTemplate? commandFor(String key) {
    for (final c in commands) {
      if (c.field == key) return c;
    }
    for (final c in commands) {
      if (c.field.isEmpty && c.usesValue) return c;
    }
    return null;
  }

  CommandTemplate? commandNamed(String name) {
    for (final c in commands) {
      if (c.name == name) return c;
    }
    return null;
  }

  /// O que está errado no perfil, em frases curtas para o editor. Vazio = ok.
  List<String> problems() {
    final out = <String>[];
    void bytesOk(String what, String s) {
      if (!_fitsBytes(s)) out.add('$what só aceita bytes (use \\xHH)');
    }

    if (maxFrameBytes < 8 || maxFrameBytes > 65536) out.add('tamanho máximo da mensagem deve ficar entre 8 e 65536 bytes');
    switch (framing) {
      case LineFraming(:final end):
        if (end.isEmpty) out.add('fim de linha vazio');
        bytesOk('fim de linha', end);
      case FixedLengthFraming(:final length, :final header):
        if (length < 1 || length > maxFrameBytes) out.add('tamanho fixo deve ficar entre 1 e $maxFrameBytes');
        if (header.length >= length) out.add('cabeçalho maior que o pacote');
        if (checksum.width + header.length > length) out.add('checksum não cabe no pacote');
        bytesOk('cabeçalho', header);
      case StartEndFraming(:final start, :final end):
        if (start.isEmpty || end.isEmpty) out.add('marcadores de início e fim não podem ser vazios');
        bytesOk('marcador de início', start);
        bytesOk('marcador de fim', end);
      case LengthPrefixFraming(:final header, :final lengthBytes):
        if (lengthBytes != 1 && lengthBytes != 2) out.add('o campo de tamanho tem 1 ou 2 bytes');
        bytesOk('cabeçalho', header);
    }
    if (checksum.afterEnd && framing is! StartEndFraming) out.add('checksum depois do fim só existe com marcadores de início e fim');
    if (checksum.skipStart < 0) out.add('bytes ignorados no checksum não podem ser negativos');
    bytesOk('separador do checksum', checksum.separator);
    switch (fields) {
      case KeyValueFields(:final pairSeparator, :final assign):
        if (pairSeparator.isEmpty || assign.isEmpty) out.add('separadores de chave=valor não podem ser vazios');
        if (pairSeparator == assign) out.add('separador de pares igual ao de atribuição');
      case CsvFields(:final separator, :final quote):
        if (separator.isEmpty) out.add('separador do CSV vazio');
        if (quote.length > 1) out.add('aspas do CSV: um caractere só');
        if (decimalComma && separator == ',') out.add('vírgula decimal não combina com CSV separado por vírgula');
      case RegexFields(:final pattern):
        if (pattern.isEmpty) {
          out.add('expressão regular vazia');
        } else {
          try {
            RegExp(pattern);
          } on FormatException catch (e) {
            out.add('expressão regular inválida: ${e.message}');
          }
        }
      case BinaryFields(:final items):
        if (items.isEmpty) out.add('nenhum campo binário definido');
        final fixed = switch (framing) { FixedLengthFraming(:final length) => length, _ => null };
        for (final f in items) {
          if (f.key.trim().isEmpty) out.add('campo binário sem nome');
          if (f.offset < 0) out.add('campo ${f.key}: deslocamento negativo');
          if (fixed != null && f.offset + f.type.size > fixed) out.add('campo ${f.key}: passa do fim do pacote de $fixed bytes');
        }
    }
    if (mode == RawMode.polling) {
      if (pollRequest.template.isEmpty) out.add('polling sem texto de pedido');
      if (pollMs < 20) out.add('intervalo de polling curto demais (mínimo 20 ms)');
    }
    if (staleAfterMs < 0) out.add('validade negativa');
    return out;
  }

  MessageProfile copyWith({
    FrameSpec? framing,
    ChecksumSpec? checksum,
    FieldFormat? fields,
    RawMode? mode,
    CommandTemplate? pollRequest,
    int? pollMs,
    int? staleAfterMs,
    List<CommandTemplate>? commands,
    RawCharset? charset,
    bool? decimalComma,
    int? maxFrameBytes,
  }) =>
      MessageProfile(
        framing: framing ?? this.framing,
        checksum: checksum ?? this.checksum,
        fields: fields ?? this.fields,
        mode: mode ?? this.mode,
        pollRequest: pollRequest ?? this.pollRequest,
        pollMs: pollMs ?? this.pollMs,
        staleAfterMs: staleAfterMs ?? this.staleAfterMs,
        commands: commands ?? this.commands,
        charset: charset ?? this.charset,
        decimalComma: decimalComma ?? this.decimalComma,
        maxFrameBytes: maxFrameBytes ?? this.maxFrameBytes,
      );

  Map<String, dynamic> toJson() => {
        'framing': framing.toJson(),
        'checksum': checksum.toJson(),
        'fields': fields.toJson(),
        'mode': mode.name,
        if (mode == RawMode.polling) 'poll': pollRequest.toJson(),
        'pollMs': pollMs,
        'staleAfterMs': staleAfterMs,
        if (commands.isNotEmpty) 'commands': [for (final c in commands) c.toJson()],
        'charset': charset.name,
        if (decimalComma) 'decimalComma': true,
        'maxFrameBytes': maxFrameBytes,
      };

  /// Campo ausente ou desconhecido cai no padrão: arquivo de uma versão mais
  /// nova (ou editado à mão) ainda abre.
  factory MessageProfile.fromJson(Map<String, dynamic> j) => MessageProfile(
        framing: FrameSpec.fromJson(j['framing']),
        checksum: ChecksumSpec.fromJson(j['checksum']),
        fields: FieldFormat.fromJson(j['fields']),
        mode: _byName(RawMode.values, j['mode'], RawMode.streaming),
        pollRequest: j['poll'] == null ? const CommandTemplate.text('?\n') : CommandTemplate.fromJson(j['poll']),
        pollMs: (j['pollMs'] as int?) ?? 1000,
        staleAfterMs: (j['staleAfterMs'] as int?) ?? 5000,
        commands: [for (final c in (j['commands'] as List?) ?? const []) CommandTemplate.fromJson(c)],
        charset: _byName(RawCharset.values, j['charset'], RawCharset.utf8),
        decimalComma: (j['decimalComma'] as bool?) ?? false,
        maxFrameBytes: (j['maxFrameBytes'] as int?) ?? 1024,
      );
}

/// Sequência de bytes gravada no JSON na notação de [ByteEscapes].
String _escaped(Object? json, String fallback) => json is String ? ByteEscapes.decode(json) : fallback;

T _byName<T extends Enum>(List<T> values, Object? name, T fallback) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  return fallback;
}
