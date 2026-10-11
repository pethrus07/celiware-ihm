// Perfis de fabricante: o nome da memória como está no manual do CLP ("D200",
// "X10", "M8000") traduzido em área + endereço Modbus, e o caminho de volta.
//
// Entre marcas o protocolo é o mesmo; muda só onde cada área começa. Por isso
// o perfil mora aqui e no cadastro: o runtime continua recebendo `Tag` com
// área + endereço Modbus (a verdade da varredura), e nada no ScanPlanner nem
// no TagCodec muda.
//
// Fonte de todas as tabelas: docs/pesquisa-etapa4/2-mapas-de-memoria-e-importacao.md,
// com a página de cada manual. Endereços em base 0, como no resto do app. Os
// perfis são constantes no código, não no arquivo do projeto: o projeto guarda
// só o id (`Device.profile`) e, em cada variável, o texto da memória
// (`Tag.memory`). O endereço Modbus gravado na variável é uma foto do dia em
// que ela foi criada; se uma tabela daqui for corrigida, [VendorProfiles.remap]
// recalcula a partir do texto.

import '../core/modbus/modbus_memory.dart';
import 'device.dart';
import 'tag.dart';

/// Base em que o fabricante numera a área. X e Y contam em octal na Inovance
/// série H, no INVT, no WEG e no Delta: depois de X7 vem X10.
enum NumberBase { decimal, octal }

/// De onde veio a tabela do perfil (MP-6).
enum ProfileOrigin {
  /// Manual oficial do fabricante, lido no PDF.
  official,

  /// Driver de IHM, gateway, código aberto ou fórum — não o manual.
  thirdParty,

  /// Conferido num equipamento de verdade.
  benchValidated,
}

extension ProfileOriginMeta on ProfileOrigin {
  /// Frase discreta para a interface. Fonte de terceiros avisa que ninguém
  /// conferiu num CLP: um endereço errado ali vira "endereço inexistente" na
  /// tela, e a pessoa precisa saber que a tabela pode ser a culpada.
  String get caption => switch (this) {
        ProfileOrigin.official => 'Pelo manual oficial',
        ProfileOrigin.thirdParty => 'Fontes de terceiros · não validado em bancada',
        ProfileOrigin.benchValidated => 'Validado em bancada',
      };
}

/// CLP (áreas de memória) ou inversor (parâmetros).
enum ProfileKind { plc, drive }

/// Trecho contínuo: as memórias [first]..[last] começam no endereço Modbus
/// [start]. Uma área pode ter vários (o M do INVT é M0–M2047 em 2000 e
/// M2048–M10239 em 12000). [first] e [last] já estão decodificados: X377 em
/// octal é 255.
class Segment {
  const Segment(this.first, this.last, this.start);
  final int first;
  final int last;
  final int start;

  bool contains(int n) => n >= first && n <= last;
}

/// Uma área de memória do fabricante ("D", "M", "X"...).
class AreaRule {
  const AreaRule({
    required this.prefix,
    required this.area,
    required this.segments,
    this.base = NumberBase.decimal,
    this.wordsPerItem = 1,
    this.forcedType,
    this.readOnly = false,
    this.label = '',
    this.variant = '',
  });

  /// Letras do manual. Mais longo casa primeiro: SM antes de S, SD antes de D.
  final String prefix;
  final ModbusArea area;
  final List<Segment> segments;
  final NumberBase base;

  /// Registradores por item: 2 nos contadores de 32 bits (C200 em diante),
  /// onde C201 fica dois endereços depois de C200.
  final int wordsPerItem;

  /// Tipo que a área impõe (INT32 nos contadores de 32 bits).
  final TagDataType? forcedType;

  /// Entrada física exposta como coil (X da Inovance e do WEG): gravar não faz
  /// sentido, então a variável nasce só leitura.
  final bool readOnly;

  /// O que é, para quem não decorou o manual: "Relés auxiliares".
  final String label;

  /// Distingue áreas com a mesma letra: o T do temporizador tem o contato
  /// (bit) e o valor (registrador).
  final String variant;

  bool get isBit => area.isBit;

  /// "D100.3" = bit 3 do registrador D100 — vale em registrador de 16 bits.
  bool get allowBit => !area.isBit && wordsPerItem == 1;

  /// Texto do chip: "D", "T · valor".
  String get chip => variant.isEmpty ? prefix : '$prefix · $variant';

  int get firstNumber => segments.first.first;
  int get lastNumber => segments.last.last;

  /// Quantas memórias a área tem.
  int get count => segments.fold(0, (s, g) => s + g.last - g.first + 1);

  /// Endereço Modbus da memória [n], ou nulo se ela não existe.
  int? addressOf(int n) {
    for (final s in segments) {
      if (s.contains(n)) return s.start + (n - s.first) * wordsPerItem;
    }
    return null;
  }

  /// Caminho inverso: número da memória no [address], ou nulo. No segundo
  /// registrador de um contador de 32 bits também é nulo (não é um item).
  int? numberAt(int address) {
    for (final s in segments) {
      final off = address - s.start;
      if (off < 0 || off % wordsPerItem != 0) continue;
      final n = s.first + off ~/ wordsPerItem;
      if (n <= s.last) return n;
    }
    return null;
  }

  String formatNumber(int n) => base == NumberBase.octal ? n.toRadixString(8) : '$n';

  /// "D200", "X10".
  String text(int n) => '$prefix${formatNumber(n)}';

  /// "D0 a D8511", "M0 a M7679 e M8000 a M8511": trechos de numeração
  /// contínua aparecem juntos (o M do WEG tem três trechos e dois buracos só
  /// de endereço, não de numeração).
  String get rangeText => _rangesText(prefix, base, [for (final s in segments) (s.first, s.last)]);
}

/// Memória traduzida: o texto normalizado e onde ela fica no Modbus.
class MemoryRef {
  const MemoryRef({required this.text, required this.area, required this.address, this.bit, this.rule, this.number, this.raw = false});

  /// Como no manual, normalizado: "D200", "X10", "D100.3", "F3-12".
  final String text;

  /// Endereço Modbus direto ("HR 200"), não a notação do fabricante: a
  /// variável não guarda [Tag.memory] (seria repetir o endereço).
  final bool raw;
  final ModbusArea area;
  final int address;

  /// Bit dentro do registrador ("D100.3" → 3).
  final int? bit;

  /// Área do perfil; nula em parâmetro de inversor e em endereço Modbus direto.
  final AreaRule? rule;

  /// Número da memória, já decodificado (X10 → 8).
  final int? number;

  /// Tipo que a memória impõe: liga/desliga em área de bit e em "D100.3";
  /// INT32 nos contadores de 32 bits.
  TagDataType? get forcedType => bit != null || area.isBit ? TagDataType.bool : rule?.forcedType;

  /// Nunca gravável: entrada discreta, input register ou entrada física.
  bool get readOnly => !area.isWritable || (rule?.readOnly ?? false);

  /// A linha de prova do cadastro: "D200 → Holding 200", "X10 → Entrada
  /// discreta 8", "D100.3 → Holding 100, bit 3".
  String get proof => '$text → ${_areaWord(area)} $address${bit == null ? '' : ', bit $bit'}';
}

/// Memória que não existe, ou texto que não é memória — com a mensagem para a
/// pessoa ("X8 não existe — X conta em octal: X7, X10").
class MemoryError implements Exception {
  const MemoryError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Como o fabricante do inversor numera os parâmetros.
enum ParameterStyle {
  /// Inovance MD500: "F3-12" → byte alto = grupo (F3 → 0xF3), byte baixo =
  /// número em hex (12 → 0x0C) → 0xF30C.
  inovance,

  /// INVT GD20: "P05.05" → grupo e número, os dois em hex → 0x0505.
  invt,
}

/// Regra de parâmetro de inversor (MP-5): "F3-12" ⇄ 0xF30C, "P05.05" ⇄ 0x0505.
///
/// "Não gravar na EEPROM" usa o endereço da RAM do mesmo parâmetro: a memória
/// do inversor aguenta um número limitado de gravações, e um ajuste que o CLP
/// manda a cada minuto acabaria com ela. Esse endereço **só aceita escrita**
/// (manual de cada um), então a variável fica para gravar.
class ParameterRule {
  const ParameterRule(this.style);
  final ParameterStyle style;

  String get example => style == ParameterStyle.inovance ? 'F3-12' : 'P05.05';

  // O sufixo "(RAM)" é o que o próprio app escreve no texto da memória de um
  // parâmetro gravado sem EEPROM — reler o texto dá o mesmo endereço.
  static final _inovance = RegExp(r'^([FABU])([0-9A-F])[-.](\d{1,3})(\(?RAM\)?)?$');
  static final _invt = RegExp(r'^P(\d{1,3})[.\-](\d{1,3})(\(?RAM\)?)?$');

  /// Lê "F3-12" (ou "F3-12 (RAM)") e devolve o endereço em holding register.
  MemoryRef parse(String input, {bool noEeprom = false}) {
    final text = input.replaceAll(RegExp(r'\s'), '').toUpperCase();
    if (text.isEmpty) throw MemoryError('Digite o parâmetro como no manual, ex.: $example');
    return style == ParameterStyle.inovance ? _parseInovance(text, input, noEeprom) : _parseInvt(text, input, noEeprom);
  }

  MemoryRef? tryParse(String input, {bool noEeprom = false}) {
    try {
      return parse(input, noEeprom: noEeprom);
    } on MemoryError {
      return null;
    }
  }

  MemoryRef _parseInovance(String text, String input, bool noEeprom) {
    final m = _inovance.firstMatch(text);
    if (m == null) throw MemoryError('"${input.trim()}" não é um parâmetro: use o formato do manual, ex.: F3-12, A0-05.');
    final letter = m.group(1)!;
    final digit = int.parse(m.group(2)!, radix: 16);
    final number = int.parse(m.group(3)!);
    final ram = noEeprom || m.group(4) != null;
    if (number > 255) throw MemoryError('O número do parâmetro vai até 255 (é o byte baixo do endereço).');
    if (letter == 'U' && digit != 0) throw MemoryError('Do grupo U o manual só dá endereço para o U0.');
    if (ram && (letter == 'B' || letter == 'U')) throw const MemoryError('Gravar sem EEPROM só existe para os grupos F e A.');
    final high = switch (letter) {
      'F' => (ram ? 0x00 : 0xF0) | digit,
      'A' => (ram ? 0x40 : 0xA0) | digit,
      'B' => 0xB0 | digit,
      _ => 0x70, // U0
    };
    return MemoryRef(
      text: '$letter${m.group(2)}-${_pad2(number)}${ram ? ' (RAM)' : ''}',
      area: ModbusArea.holdingRegister,
      address: (high << 8) | number,
    );
  }

  MemoryRef _parseInvt(String text, String input, bool noEeprom) {
    final m = _invt.firstMatch(text);
    if (m == null) throw MemoryError('"${input.trim()}" não é um parâmetro: use o formato do manual, ex.: P05.05, P00.01.');
    final group = int.parse(m.group(1)!);
    final number = int.parse(m.group(2)!);
    final ram = noEeprom || m.group(3) != null;
    if (number > 255) throw MemoryError('O número do parâmetro vai até 255 (é o byte baixo do endereço).');
    // De 0x2000 em diante ficam os registradores de comunicação (comando
    // 0x2000, estado 0x2100, leituras 0x3000): um "P32.00" cairia lá.
    if (group > 31) throw MemoryError('P$group não é grupo de parâmetro: de 0x2000 em diante ficam os registradores de comunicação.');
    return MemoryRef(
      text: 'P${_pad2(group)}.${_pad2(number)}${ram ? ' (RAM)' : ''}',
      area: ModbusArea.holdingRegister,
      address: (ram ? 0x8000 : 0) | (group << 8) | number,
    );
  }

  /// Caminho inverso: 0xF30C → "F3-12"; nulo se o endereço não é parâmetro.
  String? format(int address) {
    final high = (address >> 8) & 0xFF, low = address & 0xFF;
    if (style == ParameterStyle.invt) {
      final ram = (address & 0x8000) != 0;
      final group = high & 0x7F;
      if (group > 31) return null;
      return 'P${_pad2(group)}.${_pad2(low)}${ram ? ' (RAM)' : ''}';
    }
    final digit = (high & 0x0F).toRadixString(16).toUpperCase();
    return switch (high & 0xF0) {
      0xF0 => 'F$digit-${_pad2(low)}',
      0xA0 => 'A$digit-${_pad2(low)}',
      0xB0 => 'B$digit-${_pad2(low)}',
      0x70 when high == 0x70 => 'U0-${_pad2(low)}',
      0x00 => 'F$digit-${_pad2(low)} (RAM)',
      0x40 => 'A$digit-${_pad2(low)} (RAM)',
      _ => null,
    };
  }
}

/// Variável pronta de inversor, criada com um toque (MP-5).
class TagTemplate {
  const TagTemplate({
    required this.key,
    required this.name,
    required this.address,
    this.dataType = TagDataType.uint16,
    this.writable = false,
    this.unit = '',
    this.scale = 1,
    this.description = '',
  });

  final String key;
  final String name;

  /// Holding register (base 0).
  final int address;
  final TagDataType dataType;
  final bool writable;
  final String unit;
  final double scale;
  final String description;

  Tag toTag({required String id, required String deviceId}) => Tag(
        id: id,
        name: name,
        deviceId: deviceId,
        area: ModbusArea.holdingRegister,
        address: address,
        dataType: dataType,
        writable: writable,
        unit: unit,
        scale: scale,
        description: description,
      ).normalized();
}

/// Perfil de um fabricante e família.
class VendorProfile {
  const VendorProfile({
    required this.id,
    required this.brand,
    required this.family,
    this.kind = ProfileKind.plc,
    this.rules = const [],
    this.parameters,
    this.templates = const [],
    this.defaultByteOrder = ByteOrder.cdab,
    this.origin = ProfileOrigin.thirdParty,
    this.source = '',
    this.notes = '',
  });

  /// O que vai para o arquivo do projeto ('inovance-h3u'). Nunca muda.
  final String id;
  final String brand;
  final String family;
  final ProfileKind kind;
  final List<AreaRule> rules;
  final ParameterRule? parameters;
  final List<TagTemplate> templates;

  /// Ordem de 32 bits mais comum na marca; a variável ainda pode trocar.
  final ByteOrder defaultByteOrder;
  final ProfileOrigin origin;

  /// Documento de onde a tabela saiu.
  final String source;

  /// O que a pessoa precisa saber para conectar (gateway, parâmetros).
  final String notes;

  String get name => '$brand $family';

  /// Exemplo de memória para mensagens e dicas.
  String get example {
    if (parameters != null) return parameters!.example;
    final d = rules.where((r) => r.prefix == 'D').firstOrNull;
    if (d != null) return d.text(d.firstNumber + 200 <= d.lastNumber ? 200 : d.firstNumber);
    return rules.isEmpty ? '' : rules.first.text(rules.first.firstNumber);
  }

  /// Letras das áreas, sem repetir: "X, Y, M, SM, S, T, C, D, SD, R".
  String get areaList => {for (final r in rules) r.prefix}.join(', ');

  /// Lê a memória como no manual: "D200", "X10", "D100.3" (ou "F3-12" num
  /// inversor). Lança [MemoryError] com a explicação.
  ///
  /// Quando a mesma letra tem duas áreas (o T do temporizador é contato e
  /// valor), [bit] escolhe: `true` o contato, `false` o valor; nulo, a
  /// primeira da tabela que tiver o número.
  MemoryRef parse(String input, {bool? bit, bool noEeprom = false}) {
    if (parameters != null) return parameters!.parse(input, noEeprom: noEeprom);
    final text = input.replaceAll(RegExp(r'\s'), '').toUpperCase();
    if (text.isEmpty) throw MemoryError('Digite a memória como no manual, ex.: $example');

    // Maior prefixo primeiro: "SM10" é SM, não S; "SD5" é SD, não D.
    final byLength = [...rules]..sort((a, b) => b.prefix.length.compareTo(a.prefix.length));
    String? prefix;
    for (final r in byLength) {
      if (text.length > r.prefix.length && text.startsWith(r.prefix) && _isDigit(text.codeUnitAt(r.prefix.length))) {
        prefix = r.prefix;
        break;
      }
    }
    if (prefix == null) {
      final letters = RegExp(r'^[A-Z]+').stringMatch(text);
      if (letters != null && rules.any((r) => r.prefix == letters)) {
        throw MemoryError('Falta o número: ${rules.firstWhere((r) => r.prefix == letters).text(0)}, por exemplo.');
      }
      if (letters == null) throw MemoryError('Comece pela área, como no manual: $example.');
      throw MemoryError('$name não tem a área "$letters". Áreas: $areaList.');
    }

    final m = RegExp(r'^(\d+)(?:\.(\d+))?$').firstMatch(text.substring(prefix.length));
    var candidates = rules.where((r) => r.prefix == prefix).toList();
    if (m == null) {
      final dot = candidates.any((r) => r.allowBit) ? ' ou ${prefix}100.3' : '';
      throw MemoryError('"${input.trim()}" não é uma memória: use $prefix seguido do número ($prefix${candidates.first.formatNumber(candidates.first.firstNumber)}$dot).');
    }
    final digits = m.group(1)!;
    int? bitIndex;
    if (m.group(2) != null) {
      bitIndex = int.parse(m.group(2)!);
      final words = candidates.where((r) => r.allowBit).toList();
      if (words.isEmpty) throw MemoryError('$prefix já é bit: use $prefix${int.parse(digits)}, sem o ponto.');
      if (bitIndex > 15) throw MemoryError('O bit vai de 0 a 15: $prefix${int.parse(digits)}.15 é o último.');
      candidates = words;
    } else if (bit != null) {
      final same = candidates.where((r) => r.isBit == bit).toList();
      if (same.isNotEmpty) candidates = same;
    }

    // A mesma letra tem a mesma base em todas as áreas dela.
    final n = parseNumber(prefix, candidates.first.base, digits);
    for (final r in candidates) {
      final address = r.addressOf(n);
      if (address != null) {
        return MemoryRef(
          text: '${r.text(n)}${bitIndex == null ? '' : '.$bitIndex'}',
          area: r.area,
          address: address,
          bit: bitIndex,
          rule: r,
          number: n,
        );
      }
    }
    throw MemoryError(_missing(prefix, candidates, n));
  }

  MemoryRef? tryParse(String input, {bool? bit, bool noEeprom = false}) {
    try {
      return parse(input, bit: bit, noEeprom: noEeprom);
    } on MemoryError {
      return null;
    }
  }

  /// Caminho inverso, para mostrar "D200" ao lado do endereço Modbus. Nulo
  /// se o endereço não cai em nenhuma área do perfil.
  String? format(ModbusArea area, int address, {int? bit}) {
    if (parameters != null) return area == ModbusArea.holdingRegister && bit == null ? parameters!.format(address) : null;
    for (final r in rules) {
      if (r.area != area) continue;
      final n = r.numberAt(address);
      if (n == null) continue;
      if (bit == null) return r.text(n);
      return r.allowBit ? '${r.text(n)}.$bit' : null;
    }
    return null;
  }

  /// Mensagem de memória que não existe: "D9000 não existe neste CLP: D vai
  /// de D0 a D7999."
  String _missing(String prefix, List<AreaRule> candidates, int n) {
    final ranges = [for (final r in candidates) for (final s in r.segments) (s.first, s.last)]..sort((a, b) => a.$1.compareTo(b.$1));
    final what = kind == ProfileKind.plc ? 'neste CLP' : 'neste equipamento';
    return '$prefix${candidates.first.formatNumber(n)} não existe $what: $prefix vai de ${_rangesText(prefix, candidates.first.base, ranges)}.';
  }

  /// Número da memória na base da área; em octal, 8 e 9 dão o erro com as
  /// vizinhas certas ("X8 não existe — X conta em octal: X7, X10").
  static int parseNumber(String prefix, NumberBase base, String digits) {
    if (base == NumberBase.decimal) return int.parse(digits);
    final bad = digits.indexOf(RegExp('[89]'));
    if (bad < 0) return int.parse(digits, radix: 8);
    // Vizinha de baixo: o dígito errado e tudo depois dele vira 7 (X18 → X17;
    // X80 → X77). De cima: soma 1 ao que vem antes, em octal, e zera o resto
    // (X18 → X20; X8 → X10; X78 → X100).
    final head = digits.substring(0, bad), tail = digits.length - bad;
    final below = int.parse('$head${'7' * tail}');
    final up = ((head.isEmpty ? 0 : int.parse(head, radix: 8)) + 1).toRadixString(8);
    final above = int.parse('$up${'0' * tail}');
    final shown = int.parse(digits);
    throw MemoryError('$prefix$shown não existe — $prefix conta em octal: $prefix$below, $prefix$above');
  }

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;
}

/// O endereço Modbus direto, aceito com ou sem perfil: "HR 200", "COIL 5",
/// "DI 3", "IR 7", "HR 100.3", "HR 0x2000" — o mesmo texto que a lista de
/// variáveis mostra.
abstract final class ModbusNotation {
  static final _direct = RegExp(r'^(COIL|DI|HR|IR)(0X[0-9A-F]+|\d+)(?:\.(\d+))?$');

  /// [manual] aceita também a notação clássica de manual ("40201" = HR 200,
  /// "10001" = DI 0). Só vale sem perfil: com perfil, 40001–49999 são
  /// endereços legítimos (ver [VendorProfiles.manualNotationApplies]).
  static MemoryRef parse(String input, {bool manual = false}) {
    final text = input.replaceAll(RegExp(r'\s'), '').toUpperCase();
    final m = _direct.firstMatch(text);
    if (m != null) {
      final area = switch (m.group(1)) {
        'COIL' => ModbusArea.coil,
        'DI' => ModbusArea.discreteInput,
        'IR' => ModbusArea.inputRegister,
        _ => ModbusArea.holdingRegister,
      };
      final n = m.group(2)!;
      final address = n.startsWith('0X') ? int.parse(n.substring(2), radix: 16) : int.parse(n);
      if (address > 65535) throw const MemoryError('O endereço Modbus vai de 0 a 65535.');
      final bit = m.group(3) == null ? null : int.parse(m.group(3)!);
      if (bit != null && area.isBit) throw MemoryError('${area.shortLabel} já é bit: tire o ".$bit".');
      if (bit != null && bit > 15) throw const MemoryError('O bit vai de 0 a 15.');
      return MemoryRef(text: '${area.shortLabel} $address${bit == null ? '' : '.$bit'}', area: area, address: address, bit: bit, raw: true);
    }
    if (manual && RegExp(r'^\d{5,6}$').hasMatch(text)) {
      final v = int.parse(text);
      final (lead, offset) = text.length == 5 ? (v ~/ 10000, v % 10000) : (v ~/ 100000, v % 100000);
      final area = switch (lead) {
        0 => ModbusArea.coil,
        1 => ModbusArea.discreteInput,
        3 => ModbusArea.inputRegister,
        4 => ModbusArea.holdingRegister,
        _ => null,
      };
      if (area != null && offset >= 1 && offset <= 65536) {
        return MemoryRef(text: '${area.shortLabel} ${offset - 1}', area: area, address: offset - 1, raw: true);
      }
    }
    throw MemoryError('"${input.trim()}" não é um endereço: use HR 200, COIL 5, DI 3 ou IR 7${manual ? ' (ou 40201, como nos manuais)' : ''}.');
  }
}

/// Todos os perfis que o app conhece.
abstract final class VendorProfiles {
  static const List<VendorProfile> all = [
    inovanceH3u,
    inovanceH5u,
    invtIvc1,
    invtIvc3,
    wegTpw04,
    deltaDvp,
    inovanceMd500,
    invtGd20,
  ];

  /// Perfil pelo id gravado no projeto. Nulo = Modbus genérico (inclusive id
  /// de uma versão mais nova do app, que esta não conhece).
  static VendorProfile? byId(String? id) => id == null ? null : all.where((p) => p.id == id).firstOrNull;

  static VendorProfile? of(Device? device) => byId(device?.profile);

  /// MP-4: a sugestão "parece a notação de manual (40001…)" do cadastro só vale
  /// no Modbus genérico. Com perfil, 40001–49999 são endereços legítimos (o R
  /// da Inovance vai até 45055 e o do INVT até 45767), e a sugestão mandaria
  /// trocar um endereço certo por um errado.
  static bool manualNotationApplies(String? profileId) => byId(profileId) == null;

  /// Lê o que a pessoa escreveu: com perfil, a notação da marca ("D200",
  /// "F3-12"); sempre, o endereço Modbus direto ("HR 200"); sem perfil, também
  /// a notação clássica de manual ("40201").
  static MemoryRef parseMemory(String input, {VendorProfile? profile, bool? bit, bool noEeprom = false}) {
    final text = input.replaceAll(RegExp(r'\s'), '').toUpperCase();
    final direct = RegExp(r'^(COIL|DI|HR|IR)[0-9]').hasMatch(text);
    if (profile == null || direct) return ModbusNotation.parse(input, manual: profile == null);
    return profile.parse(input, bit: bit, noEeprom: noEeprom);
  }

  /// O equipamento trocou de perfil: relê a memória de cada variável no perfil
  /// novo. Devolve só as que mudaram de endereço; as que o perfil novo não
  /// conhece ficam como estão (o endereço Modbus delas continua valendo).
  static List<Tag> remap(Iterable<Tag> tags, VendorProfile? profile) {
    if (profile == null) return const [];
    final out = <Tag>[];
    for (final t in tags) {
      final memory = t.memory;
      if (memory == null) continue;
      final ref = profile.tryParse(memory, bit: t.dataType == TagDataType.bool);
      if (ref == null) continue;
      final bit = ref.bit ?? t.bitIndex;
      if (ref.area == t.area && ref.address == t.address && bit == t.bitIndex) continue;
      out.add(t.copyWith(area: ref.area, address: ref.address, bitIndex: bit).withMemory(ref.text));
    }
    return out;
  }

  // ── CLPs ─────────────────────────────────────────────────────────────────────

  /// Inovance H3U / H3U-XP. Tabela de terceiros: o manual de programação da
  /// série H (§9.8.3, p. 654) não foi aberto — primeiro ponto a conferir com o
  /// cliente.
  static const inovanceH3u = VendorProfile(
    id: 'inovance-h3u',
    brand: 'Inovance',
    family: 'H3U',
    origin: ProfileOrigin.thirdParty,
    source: 'HslCommunication (InovanceHelper.cs), Pro-face GP-Pro EX SIT_MODT §5.1, Maple Systems',
    notes: 'Modbus TCP na porta 502.',
    rules: [
      AreaRule(prefix: 'X', area: ModbusArea.coil, base: NumberBase.octal, readOnly: true, label: 'Entradas', segments: [Segment(0, 255, 0xF800)]),
      AreaRule(prefix: 'Y', area: ModbusArea.coil, base: NumberBase.octal, label: 'Saídas', segments: [Segment(0, 255, 0xFC00)]),
      // M8000–M8511 (especiais) continuam no mesmo mapa: 0x1F40 = 8000.
      AreaRule(prefix: 'M', area: ModbusArea.coil, label: 'Relés auxiliares', segments: [Segment(0, 7679, 0x0000), Segment(8000, 8511, 0x1F40)]),
      AreaRule(prefix: 'SM', area: ModbusArea.coil, label: 'Relés especiais', segments: [Segment(0, 1023, 0x2400)]),
      AreaRule(prefix: 'S', area: ModbusArea.coil, label: 'Passos', segments: [Segment(0, 4095, 0xE000)]),
      AreaRule(prefix: 'T', area: ModbusArea.coil, variant: 'contato', label: 'Temporizadores (contato)', segments: [Segment(0, 511, 0xF000)]),
      AreaRule(prefix: 'C', area: ModbusArea.coil, variant: 'contato', label: 'Contadores (contato)', segments: [Segment(0, 255, 0xF400)]),
      // D8000 em diante continua em 0x1F40: o D é um trecho só.
      AreaRule(prefix: 'D', area: ModbusArea.holdingRegister, label: 'Registradores de dados', segments: [Segment(0, 8511, 0x0000)]),
      AreaRule(prefix: 'SD', area: ModbusArea.holdingRegister, label: 'Registradores especiais', segments: [Segment(0, 1023, 0x2400)]),
      AreaRule(prefix: 'R', area: ModbusArea.holdingRegister, label: 'Registradores estendidos', segments: [Segment(0, 32767, 0x3000)]),
      AreaRule(prefix: 'T', area: ModbusArea.holdingRegister, variant: 'valor', label: 'Temporizadores (valor)', segments: [Segment(0, 511, 0xF000)]),
      AreaRule(prefix: 'C', area: ModbusArea.holdingRegister, variant: 'valor', label: 'Contadores (valor, 16 bits)', segments: [Segment(0, 199, 0xF400)]),
      AreaRule(prefix: 'C', area: ModbusArea.holdingRegister, variant: '32 bits', label: 'Contadores (valor, 32 bits)', wordsPerItem: 2, forcedType: TagDataType.int32, segments: [Segment(200, 255, 0xF700)]),
    ],
  );

  /// Inovance H5U e Easy (Easy301, Easy521…). Três fontes de terceiros
  /// concordam; SM/SD não confirmados, por isso ficam de fora.
  static const inovanceH5u = VendorProfile(
    id: 'inovance-h5u',
    brand: 'Inovance',
    family: 'H5U / Easy',
    origin: ProfileOrigin.thirdParty,
    source: 'EMQX Neuron "Inovance Modbus TCP", HslCommunication, Pro-face §5.2',
    notes: 'Modbus TCP. 32 bits em CDAB (EMQX, Mech-Mind).',
    rules: [
      AreaRule(prefix: 'X', area: ModbusArea.coil, base: NumberBase.octal, readOnly: true, label: 'Entradas', segments: [Segment(0, 1023, 0xF800)]),
      AreaRule(prefix: 'Y', area: ModbusArea.coil, base: NumberBase.octal, label: 'Saídas', segments: [Segment(0, 1023, 0xFC00)]),
      AreaRule(prefix: 'M', area: ModbusArea.coil, label: 'Relés auxiliares', segments: [Segment(0, 7999, 0x0000)]),
      AreaRule(prefix: 'B', area: ModbusArea.coil, label: 'Bits B', segments: [Segment(0, 32767, 0x3000)]),
      AreaRule(prefix: 'S', area: ModbusArea.coil, label: 'Passos', segments: [Segment(0, 4095, 0xE000)]),
      AreaRule(prefix: 'D', area: ModbusArea.holdingRegister, label: 'Registradores de dados', segments: [Segment(0, 7999, 0x0000)]),
      AreaRule(prefix: 'R', area: ModbusArea.holdingRegister, label: 'Registradores estendidos', segments: [Segment(0, 32767, 0x3000)]),
    ],
  );

  // INVT IVC: áreas iguais nas duas famílias. Manual oficial, Apêndice G.
  // O corte do M em M2047/M2048 é inferência (vem da tabela do IVC3 e da
  // contagem de 2048 pontos).
  static const _invtM = AreaRule(prefix: 'M', area: ModbusArea.coil, label: 'Relés auxiliares', segments: [Segment(0, 2047, 2000), Segment(2048, 10239, 12000)]);
  static const _invtS = AreaRule(prefix: 'S', area: ModbusArea.coil, label: 'Passos', segments: [Segment(0, 1023, 6000), Segment(1024, 4095, 31000)]);
  static const _invtT = AreaRule(prefix: 'T', area: ModbusArea.coil, variant: 'contato', label: 'Temporizadores (contato)', segments: [Segment(0, 255, 8000), Segment(256, 511, 11000)]);
  static const _invtD = AreaRule(prefix: 'D', area: ModbusArea.holdingRegister, label: 'Registradores de dados', segments: [Segment(0, 7999, 0)]);
  static const _invtZ = AreaRule(prefix: 'Z', area: ModbusArea.holdingRegister, label: 'Registradores de índice', segments: [Segment(0, 15, 8500)]);
  static const _invtR = AreaRule(prefix: 'R', area: ModbusArea.holdingRegister, label: 'Registradores estendidos', segments: [Segment(0, 32767, 13000)]);
  static const _invtTv = AreaRule(prefix: 'T', area: ModbusArea.holdingRegister, variant: 'valor', label: 'Temporizadores (valor)', segments: [Segment(0, 255, 9000), Segment(256, 511, 11000)]);
  static const _invtCv = AreaRule(prefix: 'C', area: ModbusArea.holdingRegister, variant: 'valor', label: 'Contadores (valor, 16 bits)', segments: [Segment(0, 199, 9500)]);
  // Contadores de 32 bits: 2 registradores cada; leem com FC03 e só gravam
  // com FC16 (o codec já grava 32 bits com FC16).
  static const _invtC32 = AreaRule(
    prefix: 'C',
    area: ModbusArea.holdingRegister,
    variant: '32 bits',
    label: 'Contadores (valor, 32 bits)',
    wordsPerItem: 2,
    forcedType: TagDataType.int32,
    segments: [Segment(200, 255, 9700), Segment(256, 306, 10000)],
  );

  /// INVT IVC1 / IVC1L / IVC1S / IVC2L. X fica como entrada discreta (FC02):
  /// pelo coil (1200–1455) o CLP ignora a gravação sem dar erro.
  static const invtIvc1 = VendorProfile(
    id: 'invt-ivc1',
    brand: 'INVT',
    family: 'IVC1 / IVC1L / IVC2L',
    origin: ProfileOrigin.official,
    source: 'IVC Series Micro-PLC Programming Manual V1.4, Apêndice G, p. 420–422',
    // 32 bits: o texto do §3.1.8 diz ABCD e a figura da mesma página, CDAB
    // (a convenção do FX, que o IVC segue). Fica CDAB até a bancada.
    notes: 'Só Modbus RTU (PORT0/PORT1): precisa de gateway. Estação de 1 a 31; padrão 19200 8E1. Ordem de 32 bits ambígua no manual.',
    rules: [
      AreaRule(prefix: 'X', area: ModbusArea.discreteInput, base: NumberBase.octal, label: 'Entradas', segments: [Segment(0, 255, 0)]),
      AreaRule(prefix: 'Y', area: ModbusArea.coil, base: NumberBase.octal, label: 'Saídas', segments: [Segment(0, 255, 0)]),
      _invtM,
      AreaRule(prefix: 'SM', area: ModbusArea.coil, label: 'Relés especiais', segments: [Segment(0, 255, 4400), Segment(256, 511, 30000)]),
      _invtS,
      _invtT,
      AreaRule(prefix: 'C', area: ModbusArea.coil, variant: 'contato', label: 'Contadores (contato)', segments: [Segment(0, 255, 9200), Segment(256, 306, 10000)]),
      _invtD,
      AreaRule(prefix: 'SD', area: ModbusArea.holdingRegister, label: 'Registradores especiais', segments: [Segment(0, 255, 8000), Segment(256, 511, 12000)]),
      _invtZ,
      _invtR,
      _invtTv,
      _invtCv,
      _invtC32,
    ],
  );

  /// INVT IVC3: a mesma página do manual, com X/Y até 777 (octal), SM e SD
  /// até 1023 e o contato do C até 511. O resto da tabela é a do IVC1.
  static const invtIvc3 = VendorProfile(
    id: 'invt-ivc3',
    brand: 'INVT',
    family: 'IVC3',
    origin: ProfileOrigin.official,
    source: 'IVC Series Micro-PLC Programming Manual V1.4, Apêndice G, p. 420–422; Modbus TCP §10.8',
    notes: 'Modbus TCP nativo; IP de fábrica 192.168.1.10. Ordem de 32 bits ambígua no manual.',
    rules: [
      AreaRule(prefix: 'X', area: ModbusArea.discreteInput, base: NumberBase.octal, label: 'Entradas', segments: [Segment(0, 511, 0)]),
      AreaRule(prefix: 'Y', area: ModbusArea.coil, base: NumberBase.octal, label: 'Saídas', segments: [Segment(0, 511, 0)]),
      _invtM,
      AreaRule(prefix: 'SM', area: ModbusArea.coil, label: 'Relés especiais', segments: [Segment(0, 255, 4400), Segment(256, 1023, 30000)]),
      _invtS,
      _invtT,
      // O relatório dá "C256–C511 em 10000–10511": 256 contatos não ocupam 512
      // bits. Fica 1:1 (10000–10255), como toda área de bit da tabela — conferir
      // no manual antes de validar o perfil.
      AreaRule(prefix: 'C', area: ModbusArea.coil, variant: 'contato', label: 'Contadores (contato)', segments: [Segment(0, 255, 9200), Segment(256, 511, 10000)]),
      _invtD,
      AreaRule(prefix: 'SD', area: ModbusArea.holdingRegister, label: 'Registradores especiais', segments: [Segment(0, 255, 8000), Segment(256, 1023, 12000)]),
      _invtZ,
      _invtR,
      _invtTv,
      _invtCv,
      _invtC32,
    ],
  );

  /// WEG TPW04 (manual oficial, §8.3.3.2). Z fica de fora: a tabela dá a
  /// faixa 6478–6497 hex, mas não a numeração dos itens.
  static const wegTpw04 = VendorProfile(
    id: 'weg-tpw04',
    brand: 'WEG',
    family: 'TPW04',
    origin: ProfileOrigin.official,
    source: 'TPW04 Manual do usuário 10003853210, §8.3.3.2, p. 47–49',
    notes: 'Só Modbus RTU: precisa de gateway. 32 bits em CDAB (palavra baixa no endereço menor).',
    rules: [
      AreaRule(prefix: 'X', area: ModbusArea.coil, base: NumberBase.octal, readOnly: true, label: 'Entradas', segments: [Segment(0, 255, 0x0000)]),
      AreaRule(prefix: 'Y', area: ModbusArea.coil, base: NumberBase.octal, label: 'Saídas', segments: [Segment(0, 255, 0x0100)]),
      // Três trechos de endereço, numeração contínua até M7679 e de novo em M8000.
      AreaRule(prefix: 'M', area: ModbusArea.coil, label: 'Relés auxiliares', segments: [Segment(0, 1535, 0x0200), Segment(1536, 7679, 0x1D00), Segment(8000, 8511, 0x0F00)]),
      AreaRule(prefix: 'S', area: ModbusArea.coil, label: 'Passos', segments: [Segment(0, 1023, 0x0800), Segment(1024, 4095, 0x1100)]),
      AreaRule(prefix: 'T', area: ModbusArea.coil, variant: 'contato', label: 'Temporizadores (contato)', segments: [Segment(0, 511, 0x0C00)]),
      AreaRule(prefix: 'C', area: ModbusArea.coil, variant: 'contato', label: 'Contadores (contato)', segments: [Segment(0, 255, 0x0E00), Segment(256, 511, 0x3500)]),
      AreaRule(prefix: 'D', area: ModbusArea.holdingRegister, label: 'Registradores de dados', segments: [Segment(0, 8511, 0x4338)]),
      AreaRule(prefix: 'W', area: ModbusArea.holdingRegister, label: 'Registradores W', segments: [Segment(0, 32767, 0x8000)]),
      AreaRule(prefix: 'T', area: ModbusArea.holdingRegister, variant: 'valor', label: 'Temporizadores (valor)', segments: [Segment(0, 511, 0x4000)]),
      AreaRule(prefix: 'C', area: ModbusArea.holdingRegister, variant: 'valor', label: 'Contadores (valor, 16 bits)', segments: [Segment(0, 199, 0x4200)]),
      AreaRule(prefix: 'C', area: ModbusArea.holdingRegister, variant: '32 bits', label: 'Contadores (valor, 32 bits)', wordsPerItem: 2, forcedType: TagDataType.int32, segments: [Segment(200, 255, 0x42C8)]),
    ],
  );

  /// Delta DVP. Só terceiros (o manual oficial pede aceite de termos e não foi
  /// baixado). S, T e C não confirmados: ficam de fora. Os fins M4095 e D9999
  /// são inferência (limites dos ES2/SS2): o começo de cada trecho é o da fonte.
  static const deltaDvp = VendorProfile(
    id: 'delta-dvp',
    brand: 'Delta',
    family: 'DVP',
    origin: ProfileOrigin.thirdParty,
    source: 'plcprogramming.io "Delta PLC Modbus address", tabela no Scribd',
    notes: 'Fins de M (M4095) e D (D9999) inferidos; ordem de 32 bits não confirmada.',
    rules: [
      AreaRule(prefix: 'X', area: ModbusArea.discreteInput, base: NumberBase.octal, label: 'Entradas', segments: [Segment(0, 255, 0x0400)]),
      AreaRule(prefix: 'Y', area: ModbusArea.coil, base: NumberBase.octal, label: 'Saídas', segments: [Segment(0, 255, 0x0500)]),
      AreaRule(prefix: 'M', area: ModbusArea.coil, label: 'Relés auxiliares', segments: [Segment(0, 1535, 0x0800), Segment(1536, 4095, 0xB000)]),
      AreaRule(prefix: 'D', area: ModbusArea.holdingRegister, label: 'Registradores de dados', segments: [Segment(0, 4095, 0x1000), Segment(4096, 9999, 0x9000)]),
    ],
  );

  // ── Inversores ───────────────────────────────────────────────────────────────

  /// Inovance MD500 / MD500-PLUS (Software Guide 19011580, §4.1.4).
  static const inovanceMd500 = VendorProfile(
    id: 'inovance-md500',
    brand: 'Inovance',
    family: 'MD500',
    kind: ProfileKind.drive,
    defaultByteOrder: ByteOrder.abcd,
    origin: ProfileOrigin.official,
    source: 'MD500-PLUS Software Guide 19011580, §4.1.4, p. 700–702',
    notes: 'Fala Modbus RTU: precisa de gateway. Para comandar pela rede: F0-02 = 2 e F0-03 = 9; velocidade e endereço no grupo FD (FD-00, FD-02).',
    parameters: ParameterRule(ParameterStyle.inovance),
    templates: [
      TagTemplate(key: 'comando', name: 'Comando', address: 0x2000, writable: true, description: '1 avante · 2 ré · 3/4 jog · 5 parada livre · 6 parada em rampa · 7 reset de falha'),
      // ±10000 = ±100,00 % da frequência máxima (F0-10).
      TagTemplate(key: 'referencia', name: 'Referência de frequência', address: 0x1000, dataType: TagDataType.int16, writable: true, unit: '%', scale: 0.01, description: '% da frequência máxima (F0-10)'),
      TagTemplate(key: 'estado', name: 'Estado', address: 0x3000, description: '1 avante · 2 ré · 3 parado'),
      TagTemplate(key: 'falha', name: 'Falha', address: 0x8000, description: 'Código da falha'),
    ],
  );

  /// INVT GD20 (manual V1.3, §7.4.1–7.4.2).
  static const invtGd20 = VendorProfile(
    id: 'invt-gd20',
    brand: 'INVT',
    family: 'GD20',
    kind: ProfileKind.drive,
    defaultByteOrder: ByteOrder.abcd,
    origin: ProfileOrigin.official,
    source: 'GD20 Manual V1.3, §7.4.1–7.4.2, p. 109–111',
    notes: 'Fala Modbus RTU: precisa de gateway. Para comandar pela rede: P00.01 = 2 e P00.06 = 8; comunicação no grupo P14.',
    parameters: ParameterRule(ParameterStyle.invt),
    templates: [
      TagTemplate(key: 'comando', name: 'Comando', address: 0x2000, writable: true, description: '1 avante · 2 ré · 3/4 jog · 5 parar · 6 parada livre · 7 reset de falha · 8 parar jog'),
      TagTemplate(key: 'referencia', name: 'Referência de frequência', address: 0x2001, writable: true, unit: 'Hz', scale: 0.01, description: '0 até a frequência máxima, em 0,01 Hz'),
      TagTemplate(key: 'estado', name: 'Estado', address: 0x2100, description: '1 avante · 2 ré · 3 parado · 4 falha'),
      TagTemplate(key: 'falha', name: 'Falha', address: 0x2102, description: 'Código da falha'),
    ],
  );
}

String _pad2(int n) => n.toString().padLeft(2, '0');

String _areaWord(ModbusArea a) => switch (a) {
      ModbusArea.coil => 'Coil',
      ModbusArea.discreteInput => 'Entrada discreta',
      ModbusArea.holdingRegister => 'Holding',
      ModbusArea.inputRegister => 'Input register',
    };

/// Junta trechos de numeração contínua: [(0,1535),(1536,7679),(8000,8511)] →
/// "M0 a M7679 e de M8000 a M8511".
String _rangesText(String prefix, NumberBase base, List<(int, int)> ranges) {
  String n(int v) => '$prefix${base == NumberBase.octal ? v.toRadixString(8) : v}';
  final merged = <(int, int)>[];
  for (final r in ranges) {
    if (merged.isNotEmpty && r.$1 <= merged.last.$2 + 1) {
      final last = merged.removeLast();
      merged.add((last.$1, r.$2 > last.$2 ? r.$2 : last.$2));
    } else {
      merged.add(r);
    }
  }
  final parts = [for (final r in merged) '${n(r.$1)} a ${n(r.$2)}'];
  if (parts.length == 1) return parts.single;
  return '${parts.sublist(0, parts.length - 1).join(', de ')} e de ${parts.last}';
}
