/// Endereço absoluto Siemens S7, no formato do TIA Portal / Step 7.
///
/// O integrador copia o endereço do programa do CLP ("DB1.DBD8", "M10.3",
/// "IW64") e o app precisa entender sem tradução. Os dois mnemônicos
/// existem na prática: o alemão (E = entrada, A = saída), padrão de muita
/// instalação em português, e o internacional (I = input, Q = output). Os
/// dois são aceitos e dão o mesmo endereço; o texto canônico é o
/// internacional.
///
/// Fora o básico, aceita o `%` que o TIA põe na frente (`%MW10`) e a faixa
/// de bytes no formato de ponteiro ANY do Step 7 (`P#DB1.DBX10.0 BYTE 22`),
/// que é como se escreve um STRING ou um bloco de bytes.
library;

/// Área de memória do CLP, com o código que vai no pedido S7.
enum S7Area {
  inputs(0x81, 'I', 'E'),
  outputs(0x82, 'Q', 'A'),
  flags(0x83, 'M', 'M'),
  db(0x84, 'DB', 'DB');

  const S7Area(this.code, this.english, this.german);

  /// Código da área no item do pedido (S7ANY).
  final int code;

  /// Letra no mnemônico internacional (I, Q, M, DB).
  final String english;

  /// Letra no mnemônico alemão (E, A, M, DB).
  final String german;
}

/// Tipos de dado S7 com codec ([S7Codec]). Os nomes seguem o modelo de
/// variável do app (int16, int32); [label] é o nome do TIA.
enum S7Type {
  boolean('BOOL', 1),
  byte('BYTE', 1),
  word('WORD', 2),
  int16('INT', 2),
  dword('DWORD', 4),
  int32('DINT', 4),
  real('REAL', 4),
  string('STRING', 0);

  const S7Type(this.label, this.size);

  /// Nome no TIA Portal.
  final String label;

  /// Bytes ocupados; 0 = variável (STRING ocupa capacidade + 2).
  final int size;
}

/// Endereço absoluto: área, DB, byte, bit e tamanho em bytes. Imutável.
///
/// Endereço de bit tem [bitIndex] e ocupa 1 byte; os demais ocupam
/// [byteLength] bytes a partir de [byteOffset].
class S7Address {
  const S7Address._(this.area, this.dbNumber, this.byteOffset, this.bitIndex, this.byteLength);

  /// Monta e confere um endereço. Lança [ArgumentError] com a mensagem em
  /// português se algum campo estiver fora da faixa.
  factory S7Address({
    required S7Area area,
    int dbNumber = 0,
    required int byteOffset,
    int? bitIndex,
    int byteLength = 1,
  }) {
    final db = area == S7Area.db ? dbNumber : 0;
    final length = bitIndex != null ? 1 : byteLength;
    final a = S7Address._(area, db, byteOffset, bitIndex, length);
    final problem = _check(a);
    if (problem != null) throw ArgumentError('$a: $problem');
    return a;
  }

  /// Maior byte endereçável. DB não otimizado vai até 64 KB, e M/I/Q são
  /// bem menores em qualquer CPU.
  static const int maxByte = 65535;

  /// Maior número de DB.
  static const int maxDb = 65535;

  final S7Area area;

  /// Número do DB; 0 quando a área não é DB.
  final int dbNumber;

  /// Primeiro byte.
  final int byteOffset;

  /// Bit dentro do byte (0 a 7), só em endereço de bit.
  final int? bitIndex;

  /// Bytes ocupados (1 em endereço de bit).
  final int byteLength;

  bool get isBit => bitIndex != null;

  /// Primeiro byte depois do endereço.
  int get endByte => byteOffset + byteLength;

  /// Tipos que cabem neste endereço; o primeiro é a sugestão.
  List<S7Type> get suggestedTypes {
    if (isBit) return const [S7Type.boolean];
    switch (byteLength) {
      case 1:
        return const [S7Type.byte];
      case 2:
        return const [S7Type.word, S7Type.int16];
      case 4:
        return const [S7Type.dword, S7Type.int32, S7Type.real];
      default:
        return const [S7Type.string];
    }
  }

  S7Type get suggestedType => suggestedTypes.first;

  /// O mesmo início, como faixa de [bytes] bytes (ex.: o STRING[20] que
  /// começa em DB1.DBB10 ocupa 22 bytes).
  S7Address withLength(int bytes) =>
      S7Address(area: area, dbNumber: dbNumber, byteOffset: byteOffset, byteLength: bytes);

  /// Texto no formato do TIA. [german] troca I/Q por E/A.
  String format({bool german = false}) {
    final letter = german ? area.german : area.english;
    if (area == S7Area.db) {
      final prefix = 'DB$dbNumber.DB';
      if (isBit) return '${prefix}X$byteOffset.$bitIndex';
      final size = _sizeLetter(byteLength);
      if (size != null) return '$prefix$size$byteOffset';
      return 'P#${prefix}X$byteOffset.0 BYTE $byteLength';
    }
    if (isBit) return '$letter$byteOffset.$bitIndex';
    final size = _sizeLetter(byteLength);
    if (size != null) return '$letter$size$byteOffset';
    return 'P#$letter$byteOffset.0 BYTE $byteLength';
  }

  @override
  String toString() => format();

  @override
  bool operator ==(Object other) =>
      other is S7Address &&
      other.area == area &&
      other.dbNumber == dbNumber &&
      other.byteOffset == byteOffset &&
      other.bitIndex == bitIndex &&
      other.byteLength == byteLength;

  @override
  int get hashCode => Object.hash(area, dbNumber, byteOffset, bitIndex, byteLength);

  // ── Leitura do texto ─────────────────────────────────────────────────────────

  /// Lê o endereço digitado. Lança [FormatException] com a mensagem para o
  /// usuário, começando pelo próprio texto ("DB1.DBX0.8: o bit vai de 0 a 7").
  static S7Address parse(String text) {
    final raw = text.trim();
    if (raw.isEmpty) throw const FormatException('endereço vazio');
    var s = raw.toUpperCase();
    if (s.startsWith('%')) s = s.substring(1).trimLeft();
    if (s.startsWith('P#')) return _parsePointer(raw, s.substring(2));
    s = s.replaceAll(RegExp(r'\s+'), '');

    final db = _dbPattern.firstMatch(s);
    if (db != null) {
      final number = _number(raw, db.group(1)!, 'o número do DB', 1, maxDb);
      return _build(raw, S7Area.db, number, db.group(2)!, db.group(3)!, db.group(4), dbForm: true);
    }
    if (_dbOnly.hasMatch(s)) {
      throw FormatException('$raw: falta o endereço dentro do DB (ex.: DB1.DBW0)');
    }
    if (RegExp(r'^DB[XBWD]').hasMatch(s)) {
      throw FormatException('$raw: falta o número do DB (ex.: DB1.DBW4)');
    }
    if (s.startsWith('DB')) {
      throw FormatException('$raw: depois do DB vem DBX, DBB, DBW ou DBD (ex.: DB1.DBW4)');
    }

    final m = _areaPattern.firstMatch(s);
    if (m != null) {
      final area = switch (m.group(1)!) {
        'I' || 'E' => S7Area.inputs,
        'Q' || 'A' => S7Area.outputs,
        _ => S7Area.flags,
      };
      return _build(raw, area, 0, m.group(2)!, m.group(3)!, m.group(4));
    }
    if (_timerCounter.hasMatch(s)) {
      throw FormatException('$raw: temporizador e contador não são lidos; use DB, M, I ou Q');
    }
    throw FormatException('$raw: endereço não reconhecido (ex.: DB1.DBW4, M10.3, IW64)');
  }

  /// Como [parse], mas devolve `null` em vez de lançar.
  static S7Address? tryParse(String text) {
    try {
      return parse(text);
    } on FormatException {
      return null;
    }
  }

  /// Mensagem de erro do endereço, ou `null` se estiver certo — pronto para
  /// o `validator` de um campo de formulário.
  static String? validate(String text) {
    try {
      parse(text);
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  // DB1.DBX0.0 · DB1.DBW4 (o ponto entre o DB e o DBx é tolerado ausente).
  static final _dbPattern = RegExp(r'^DB(\d+)\.?DB([XBWD])(\d+)(?:\.(\d+))?$');
  static final _dbOnly = RegExp(r'^DB\d+\.?$');
  // M10.3 · MX10.3 · MB10 · IW64 · EW64 · QD0 · AD0
  static final _areaPattern = RegExp(r'^([IEQAM])([XBWD]?)(\d+)(?:\.(\d+))?$');
  static final _timerCounter = RegExp(r'^[TCZ]\d+$');

  static S7Address _build(String raw, S7Area area, int db, String size, String byteText, String? bitText,
      {bool dbForm = false}) {
    final bitForm = size == 'X' || size.isEmpty;
    if (bitForm && bitText == null) {
      throw FormatException(dbForm
          ? '$raw: falta o bit (ex.: DB$db.DBX$byteText.0)'
          : '$raw: falta o bit (ex.: ${area.english}$byteText.0) ou o tamanho '
              '(${area.english}B$byteText, ${area.english}W$byteText, ${area.english}D$byteText)');
    }
    if (!bitForm && bitText != null) {
      final example = dbForm ? 'DB$db.DBX$byteText.$bitText' : '${area.english}$byteText.$bitText';
      throw FormatException('$raw: só endereço de bit leva ponto (ex.: $example)');
    }
    final length = switch (size) { 'W' => 2, 'D' => 4, _ => 1 };
    final byte = _number(raw, byteText, 'o byte', 0, maxByte + 1 - length);
    int? bit;
    if (bitForm) bit = _number(raw, bitText!, 'o bit', 0, 7);
    return S7Address._(area, db, byte, bit, length);
  }

  /// P#DB1.DBX10.0 BYTE 22 · P#M10.0 BYTE 5
  static S7Address _parsePointer(String raw, String body) {
    final m = RegExp(r'^(.+?)\s+BYTE\s+(\d+)$').firstMatch(body.trim());
    if (m == null) {
      throw FormatException('$raw: faixa no formato P#DB1.DBX10.0 BYTE 22');
    }
    final S7Address start;
    try {
      start = parse(m.group(1)!);
    } on FormatException catch (e) {
      throw FormatException('$raw: ${e.message.substring(e.message.indexOf(':') + 1).trim()}');
    }
    if (!start.isBit) throw FormatException('$raw: a faixa começa num bit (ex.: P#DB1.DBX10.0 BYTE 22)');
    if (start.bitIndex != 0) throw FormatException('$raw: a faixa começa no bit 0');
    final count = _number(raw, m.group(2)!, 'a quantidade de bytes', 1, maxByte + 1 - start.byteOffset);
    return S7Address._(start.area, start.dbNumber, start.byteOffset, null, count);
  }

  static int _number(String raw, String digits, String what, int min, int max) {
    final v = int.tryParse(digits);
    if (v == null || v < min || v > max) {
      throw FormatException('$raw: $what vai de $min a $max');
    }
    return v;
  }

  static String? _sizeLetter(int length) => switch (length) { 1 => 'B', 2 => 'W', 4 => 'D', _ => null };

  static String? _check(S7Address a) {
    if (a.area == S7Area.db && (a.dbNumber < 1 || a.dbNumber > maxDb)) {
      return 'o número do DB vai de 1 a $maxDb';
    }
    final bit = a.bitIndex;
    if (bit != null && (bit < 0 || bit > 7)) return 'o bit vai de 0 a 7';
    if (a.byteLength < 1) return 'o tamanho mínimo é 1 byte';
    if (a.byteOffset < 0 || a.endByte > maxByte + 1) {
      return 'o byte vai de 0 a ${maxByte + 1 - a.byteLength}';
    }
    return null;
  }
}
