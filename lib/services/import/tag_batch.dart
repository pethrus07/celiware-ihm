import 'dart:convert';

import '../../core/modbus/modbus_memory.dart';
import '../../core/utils/ids.dart';
import '../../models/device.dart';
import '../../models/project.dart';
import '../../models/tag.dart';
import '../../models/vendor_profiles.dart';
import '../runtime/scan_planner.dart';

/// "Criar várias" (IF-1, IF-4, IF-5): monta um lote de variáveis a partir de
/// uma faixa ("D0 até D99"), dos modelos prontos de um inversor ou de um CSV,
/// e confere cada uma contra o que já está cadastrado. Funções puras: a tela
/// só mostra a prévia e chama `ProjectController.saveTags` com o resultado.

/// Pedido impossível como um todo (faixa invertida, memória inexistente,
/// passou do teto) — o texto vai direto para a tela.
class BatchError implements Exception {
  const BatchError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Linha do CSV recusada, com o motivo.
class BatchLineError {
  const BatchLineError(this.line, this.message);
  final int line;
  final String message;

  String get text => 'Linha $line: $message';
}

/// Uma variável do lote e, se o endereço já está cadastrado no equipamento,
/// a que já existe.
class BatchItem {
  const BatchItem(this.tag, {this.existing});
  final Tag tag;
  final Tag? existing;

  bool get conflict => existing != null;
}

/// O que fazer com variável cujo endereço já está cadastrado.
enum ConflictPolicy {
  /// Deixa a que existe como está e não cria a nova.
  skip,

  /// A que existe ganha a definição nova, mas **mantém o id, os alarmes, as
  /// narrações e a marca "Aceita escrita por regra"**: telas, contas e regras
  /// que apontavam para ela continuam ligadas e funcionando.
  replace,
}

/// O lote pronto para a prévia.
class TagBatch {
  const TagBatch(this.items, {this.errors = const []});

  static const empty = TagBatch([]);

  /// A partir daqui a prévia avisa: a lista fica longa e a tela que usar
  /// muitas delas lê mais (IF-4, número de partida da pesquisa).
  static const warnAt = 256;

  /// Teto por vez. 125 registradores em RTU a 19200 bps levam ~150 ms por
  /// leitura: mil variáveis numa tela passariam de vários segundos por ciclo.
  static const maxItems = 1000;

  final List<BatchItem> items;

  /// Linhas do CSV que ficaram de fora.
  final List<BatchLineError> errors;

  int get count => items.length;
  int get conflicts => items.where((i) => i.conflict).length;
  bool get large => count >= warnAt;

  /// Quantas leituras Modbus por ciclo o lote custa se estiver todo na tela —
  /// o mesmo agrupamento da varredura de verdade.
  int get readsPerCycle => const ScanPlanner().plan([for (final i in items) i.tag]).length;

  /// O que vai para o projeto com a escolha [policy].
  List<Tag> resolve(ConflictPolicy policy) => [
        for (final i in items)
          if (!i.conflict)
            i.tag
          else if (policy == ConflictPolicy.replace)
            _over(i.existing!, i.tag),
      ];

  /// A definição nova no lugar da antiga, com o que a pessoa configurou na
  /// antiga: id, alarmes, narrações e a permissão de escrita por regra (sem
  /// ela, a regra que grava aqui pararia em silêncio). A memória do manual
  /// vem da nova; se a nova não tem (endereço Modbus direto), fica a da
  /// antiga — o conflito é no mesmo endereço, então o nome continua certo.
  static Tag _over(Tag old, Tag t) => Tag(
        id: old.id,
        name: t.name,
        deviceId: t.deviceId,
        area: t.area,
        address: t.address,
        dataType: t.dataType,
        byteOrder: t.byteOrder,
        bitIndex: t.bitIndex,
        length: t.length,
        writable: t.writable,
        unit: t.unit,
        decimals: t.decimals,
        scale: t.scale,
        offset: t.offset,
        description: t.description,
        alarms: old.alarms,
        narrations: old.narrations,
        memory: t.memory ?? old.memory,
        ruleWritable: old.ruleWritable,
      ).normalized();
}

/// De onde sai a faixa: uma área do perfil, uma área Modbus (genérico), os
/// parâmetros de um inversor ou os modelos prontos dele.
sealed class BatchArea {
  const BatchArea();

  /// Texto do chip.
  String get chip;

  /// Chave estável (testes e seleção).
  String get key;

  /// Linha discreta debaixo dos chips: o que é e de onde até onde vai.
  String get hint;
}

final class ProfileArea extends BatchArea {
  const ProfileArea(this.rule);
  final AreaRule rule;

  @override
  String get chip => rule.chip;
  @override
  String get key => 'area-${rule.chip}';
  @override
  String get hint => '${rule.label} · de ${rule.rangeText}${rule.base == NumberBase.octal ? ' · conta em octal' : ''}';
}

final class ModbusAreaChoice extends BatchArea {
  const ModbusAreaChoice(this.area);
  final ModbusArea area;

  @override
  String get chip => area.label;
  @override
  String get key => 'area-${area.name}';
  @override
  String get hint => 'Endereço Modbus, a partir de 0';
}

final class ParameterArea extends BatchArea {
  const ParameterArea(this.rule);
  final ParameterRule rule;

  @override
  String get chip => 'Parâmetros';
  @override
  String get key => 'area-parametros';
  @override
  String get hint => 'Como no manual: ${rule.example}. A faixa fica num grupo só.';
}

final class TemplateArea extends BatchArea {
  const TemplateArea(this.templates);
  final List<TagTemplate> templates;

  @override
  String get chip => 'Modelos prontos';
  @override
  String get key => 'area-modelos';
  @override
  String get hint => 'As variáveis que todo inversor precisa, com os endereços do manual.';
}

/// Monta os lotes.
abstract final class TagBatchBuilder {
  /// Áreas oferecidas para o equipamento: as do perfil, ou as quatro do
  /// Modbus no genérico. Inversor: modelos prontos, parâmetros e o holding
  /// direto (para as leituras que não são parâmetro, como 0x1001).
  static List<BatchArea> areasFor(VendorProfile? profile) {
    if (profile == null) return [for (final a in ModbusArea.values) ModbusAreaChoice(a)];
    if (profile.kind == ProfileKind.drive) {
      return [
        if (profile.templates.isNotEmpty) TemplateArea(profile.templates),
        if (profile.parameters != null) ParameterArea(profile.parameters!),
        const ModbusAreaChoice(ModbusArea.holdingRegister),
      ];
    }
    return [for (final r in profile.rules) ProfileArea(r)];
  }

  /// Área que já vem marcada: o D (o que mais se cria), ou a primeira.
  static BatchArea defaultArea(List<BatchArea> areas) =>
      areas.whereType<ProfileArea>().where((a) => a.rule.prefix == 'D').firstOrNull ??
      areas.whereType<ModbusAreaChoice>().where((a) => a.area == ModbusArea.holdingRegister && areas.length == 4).firstOrNull ??
      areas.first;

  /// Faixa sugerida ao escolher a área: dez memórias, ou oito em octal (X0 a
  /// X7, uma "dezena" octal).
  static (String, String) defaultRange(BatchArea area) => switch (area) {
        ProfileArea(:final rule) => (
            rule.formatNumber(rule.firstNumber),
            rule.formatNumber(_min(rule.firstNumber + (rule.base == NumberBase.octal ? 7 : 9), rule.segments.first.last)),
          ),
        ModbusAreaChoice() => ('0', '9'),
        ParameterArea(:final rule) => rule.style == ParameterStyle.inovance ? ('F0-00', 'F0-09') : ('P00.00', 'P00.09'),
        TemplateArea() => ('', ''),
      };

  /// Lote de uma faixa. [type] vale para registrador (área de bit é sempre
  /// liga/desliga; contador de 32 bits é sempre INT32). Em registrador de 16
  /// bits, tipo de 32 bits anda de 2 em 2 (D0, D2, D4…).
  ///
  /// Nome: vazio = a própria memória ("D200"); com [namePrefix], prefixo +
  /// número da memória ("Temperatura 200").
  static TagBatch range({
    required Project project,
    required Device device,
    required BatchArea area,
    required String from,
    required String to,
    TagDataType type = TagDataType.uint16,
    String namePrefix = '',
    bool writable = false,
    ByteOrder? byteOrder,
    bool noEeprom = false,
  }) {
    final profile = VendorProfiles.of(device);
    final ids = _ids();
    final tags = <Tag>[];
    ByteOrder order(TagDataType t) => t.is32Bit ? (byteOrder ?? profile?.defaultByteOrder ?? ByteOrder.abcd) : ByteOrder.abcd;

    switch (area) {
      case ProfileArea(:final rule):
        final a = _number(rule, from, 'começo'), b = _number(rule, to, 'fim');
        if (b < a) throw BatchError('O fim (${rule.text(b)}) vem antes do começo (${rule.text(a)}).');
        final t = rule.isBit ? TagDataType.bool : (rule.forcedType ?? type);
        final step = rule.wordsPerItem == 1 && t.is32Bit ? 2 : 1;
        _checkCount((b - a) ~/ step + 1, 'Divida a faixa.');
        for (var n = a; n <= b; n += step) {
          final address = rule.addressOf(n);
          if (address == null) throw BatchError(_missing(rule, n));
          if (step == 2) _checkPair(rule, n, address);
          tags.add(Tag(
            id: ids(tags.length),
            name: _name(namePrefix, rule.formatNumber(n), rule.text(n)),
            deviceId: device.id,
            area: rule.area,
            address: address,
            dataType: t,
            byteOrder: order(t),
            writable: writable && !rule.readOnly,
            memory: rule.text(n),
          ).normalized());
        }
      case ModbusAreaChoice(area: final a):
        final first = _address(from, 'começo'), last = _address(to, 'fim');
        if (last < first) throw BatchError('O fim ($last) vem antes do começo ($first).');
        final t = a.isBit ? TagDataType.bool : type;
        final step = t.is32Bit ? 2 : 1;
        _checkCount((last - first) ~/ step + 1, 'Divida a faixa.');
        if (t.is32Bit && last + 1 > 65535) throw const BatchError('O último valor de 32 bits passaria do endereço 65535.');
        for (var n = first; n <= last; n += step) {
          tags.add(Tag(
            id: ids(tags.length),
            name: _name(namePrefix, '$n', '${a.shortLabel} $n'),
            deviceId: device.id,
            area: a,
            address: n,
            dataType: t,
            byteOrder: order(t),
            writable: writable,
          ).normalized());
        }
      case ParameterArea(:final rule):
        final MemoryRef ra, rb;
        try {
          ra = rule.parse(from, noEeprom: noEeprom);
          rb = rule.parse(to, noEeprom: noEeprom);
        } on MemoryError catch (e) {
          throw BatchError(e.message);
        }
        if (ra.address >> 8 != rb.address >> 8) throw BatchError('A faixa fica num grupo só: ${ra.text} e ${rb.text} são de grupos diferentes.');
        if (rb.address < ra.address) throw BatchError('O fim (${rb.text}) vem antes do começo (${ra.text}).');
        final step = type.is32Bit ? 2 : 1;
        _checkCount((rb.address - ra.address) ~/ step + 1, 'Divida a faixa.');
        for (var addr = ra.address; addr <= rb.address; addr += step) {
          final text = rule.format(addr)!;
          tags.add(Tag(
            id: ids(tags.length),
            name: _name(namePrefix, '${addr & 0xFF}', text),
            deviceId: device.id,
            area: ModbusArea.holdingRegister,
            address: addr,
            dataType: type,
            byteOrder: order(type),
            // Endereço da RAM só aceita escrita: a variável existe para gravar.
            writable: writable || noEeprom,
            description: noEeprom ? 'Grava só na RAM, sem gastar a EEPROM. O inversor não deixa ler este endereço.' : '',
            memory: text,
          ).normalized());
        }
      case TemplateArea(:final templates):
        return TagBatchBuilder.templates(project: project, device: device, templates: templates);
    }
    return TagBatch(_items(project, device.id, tags));
  }

  /// Lote dos modelos prontos de inversor (Comando, Referência, Estado, Falha).
  static TagBatch templates({required Project project, required Device device, required List<TagTemplate> templates}) {
    final ids = _ids();
    final tags = [for (var i = 0; i < templates.length; i++) templates[i].toTag(id: ids(i), deviceId: device.id)];
    return TagBatch(_items(project, device.id, tags));
  }

  /// Lote de um CSV no modelo Celiware (ver [TagCsv]). Linha com problema
  /// fica de fora e vai para [TagBatch.errors]; as boas seguem.
  static TagBatch csv({required Project project, required Device device, required List<int> bytes}) {
    final profile = VendorProfiles.of(device);
    final text = TagCsv.decode(bytes);
    final records = TagCsv.rows(text, TagCsv.separator(text));
    final ids = _ids();
    final tags = <Tag>[];
    final errors = <BatchLineError>[];
    final seen = <String, int>{};
    var columns = TagCsv.positional;
    var first = true;
    for (final (line, cells) in records) {
      if (cells.every((c) => c.trim().isEmpty)) continue;
      if (first) {
        first = false;
        final header = TagCsv.header(cells);
        if (header != null) {
          columns = header;
          continue;
        }
      }
      try {
        final t = TagCsv.tag(cells, columns, device: device, profile: profile, id: ids(tags.length));
        final slot = _slot(t);
        final prev = seen[slot];
        if (prev != null) throw BatchError('repete a memória da linha $prev');
        seen[slot] = line;
        tags.add(t);
      } on BatchError catch (e) {
        errors.add(BatchLineError(line, e.message));
      }
    }
    _checkCount(tags.length, 'Divida o arquivo.');
    return TagBatch(_items(project, device.id, tags), errors: errors);
  }

  // ── Apoio ────────────────────────────────────────────────────────────────────

  /// Ids únicos no lote: `newId` em laço apertado repete o relógio e só o
  /// sorteio separaria mil ids.
  static String Function(int) _ids() {
    final base = newId('t');
    return (i) => '${base}_$i';
  }

  static void _checkCount(int count, String advice) {
    if (count > TagBatch.maxItems) {
      throw BatchError('São $count variáveis: o máximo é ${TagBatch.maxItems} de uma vez. $advice');
    }
  }

  /// Conflito = mesmo equipamento, mesma área, mesmo endereço (e o mesmo bit,
  /// quando é bit de registrador). Faixas que só se sobrepõem não contam: o
  /// app aceita, de propósito, um FLOAT32 e as duas metades dele.
  static List<BatchItem> _items(Project project, String deviceId, List<Tag> tags) {
    final existing = <String, Tag>{};
    for (final t in project.tags) {
      // Endereço a configurar não ocupa memória nenhuma (o HR 0 dela é só o padrão).
      if (t.deviceId == deviceId && !t.addressPending) existing.putIfAbsent(_slot(t), () => t);
    }
    return [for (final t in tags) BatchItem(t, existing: existing[_slot(t)])];
  }

  static String _slot(Tag t) => '${t.area.index}:${t.address}:${t.isBitOfRegister ? t.bitIndex : -1}';

  /// Número do campo "de"/"até" na base da área; aceita com ou sem as letras
  /// ("200" ou "D200").
  static int _number(AreaRule rule, String input, String which) {
    var t = input.replaceAll(RegExp(r'\s'), '').toUpperCase();
    if (t.startsWith(rule.prefix)) t = t.substring(rule.prefix.length);
    if (t.isEmpty) throw BatchError('Falta o número do $which.');
    if (!RegExp(r'^\d+$').hasMatch(t)) throw BatchError('"${input.trim()}" não é um número de ${rule.prefix}.');
    try {
      return VendorProfile.parseNumber(rule.prefix, rule.base, t);
    } on MemoryError catch (e) {
      throw BatchError(e.message);
    }
  }

  static int _address(String input, String which) {
    final t = input.replaceAll(RegExp(r'\s'), '').toLowerCase();
    if (t.isEmpty) throw BatchError('Falta o endereço do $which.');
    final v = t.startsWith('0x') ? int.tryParse(t.substring(2), radix: 16) : int.tryParse(t);
    if (v == null) throw BatchError('"${input.trim()}" não é um endereço.');
    if (v < 0 || v > 65535) throw const BatchError('O endereço Modbus vai de 0 a 65535.');
    return v;
  }

  static String _missing(AreaRule rule, int n) => rule.variant.isEmpty
      ? '${rule.text(n)} não existe neste CLP: ${rule.prefix} vai de ${rule.rangeText}.'
      : '${rule.text(n)} não existe em "${rule.chip}", que vai de ${rule.rangeText}.';

  /// Valor de 32 bits num registrador de 16 ocupa também a memória seguinte —
  /// que precisa existir e estar logo depois no mapa Modbus.
  static void _checkPair(AreaRule rule, int n, int address) {
    final next = rule.addressOf(n + 1);
    if (next == null) throw BatchError('${rule.text(n)} com 32 bits ocuparia ${rule.text(n + 1)}, que não existe neste CLP.');
    if (next != address + 1) throw BatchError('${rule.text(n)} e ${rule.text(n + 1)} não ficam lado a lado no Modbus: um valor de 32 bits não pode começar em ${rule.text(n)}.');
  }

  static final _wordEnd = RegExp(r'[\p{L}\p{N}]$', unicode: true);

  /// "Temperatura" + "200" → "Temperatura 200"; "Motor-" + "3" → "Motor-3".
  static String _name(String prefix, String number, String fallback) {
    if (prefix.trim().isEmpty) return fallback;
    final p = prefix.trimLeft();
    return _wordEnd.hasMatch(p) ? '$p $number' : '$p$number';
  }

  static int _min(int a, int b) => a < b ? a : b;
}

/// CSV no modelo Celiware: `memoria;nome;tipo;gravavel;unidade;escala;descricao`.
///
/// Feito para sair do Excel em português sem ajuste: separador `;` (ou `,`,
/// detectado), vírgula decimal na escala, UTF-8 com BOM (ou Latin-1, o que o
/// Excel grava quando não pedem UTF-8), aspas para campo com separador.
/// O cabeçalho é opcional; com ele, as colunas podem vir em qualquer ordem e
/// faltar as opcionais.
abstract final class TagCsv {
  static const columns = ['memoria', 'nome', 'tipo', 'gravavel', 'unidade', 'escala', 'descricao'];
  static String get template => columns.join(';');

  /// Sem cabeçalho: as colunas na ordem do modelo.
  static const positional = {'memoria': 0, 'nome': 1, 'tipo': 2, 'gravavel': 3, 'unidade': 4, 'escala': 5, 'descricao': 6};

  static String decode(List<int> bytes) {
    var b = bytes;
    if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) b = b.sublist(3);
    try {
      return utf8.decode(b);
    } on FormatException {
      // Windows-1252 e Latin-1 coincidem em todas as letras do português.
      return latin1.decode(b);
    }
  }

  /// `;` se aparecer na primeira linha com conteúdo (fora de aspas); senão `,`.
  static String separator(String text) {
    for (final line in const LineSplitter().convert(text)) {
      if (line.trim().isEmpty) continue;
      final outside = line.replaceAll(RegExp(r'"[^"]*"'), '');
      if (outside.contains(';')) return ';';
      if (outside.contains(',')) return ',';
      return ';';
    }
    return ';';
  }

  /// Registros com o número da linha onde cada um começa. Campo entre aspas
  /// pode ter separador e quebra de linha; `""` dentro dele é uma aspa.
  static List<(int, List<String>)> rows(String text, String sep) {
    final out = <(int, List<String>)>[];
    var line = 1, start = 1;
    var cells = <String>[];
    final cell = StringBuffer();
    var quoted = false;
    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (quoted) {
        if (c == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            cell.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          if (c == '\n') line++;
          cell.write(c);
        }
        continue;
      }
      if (c == '"' && cell.toString().trim().isEmpty) {
        cell.clear();
        quoted = true;
      } else if (c == sep) {
        cells.add(cell.toString());
        cell.clear();
      } else if (c == '\n') {
        cells.add(cell.toString());
        cell.clear();
        out.add((start, cells));
        cells = <String>[];
        line++;
        start = line;
      } else if (c != '\r') {
        cell.write(c);
      }
    }
    if (cell.isNotEmpty || cells.isNotEmpty) {
      cells.add(cell.toString());
      out.add((start, cells));
    }
    return out;
  }

  static const _aliases = {
    'memoria': 'memoria',
    'endereco': 'memoria',
    'nome': 'nome',
    'tipo': 'tipo',
    'gravavel': 'gravavel',
    'grava': 'gravavel',
    'escrita': 'gravavel',
    'unidade': 'unidade',
    'escala': 'escala',
    'descricao': 'descricao',
    'observacao': 'descricao',
  };

  /// Colunas pelo cabeçalho, ou nulo se a linha não é cabeçalho (é dado).
  static Map<String, int>? header(List<String> cells) {
    final map = <String, int>{};
    for (var i = 0; i < cells.length; i++) {
      final name = _aliases[_plain(cells[i])];
      if (name != null) map.putIfAbsent(name, () => i);
    }
    return map.containsKey('memoria') ? map : null;
  }

  /// Uma linha → variável. Lança [BatchError] com o motivo.
  static Tag tag(List<String> cells, Map<String, int> columns, {required Device device, VendorProfile? profile, required String id}) {
    String cell(String col) {
      final i = columns[col];
      return i == null || i >= cells.length ? '' : cells[i].trim();
    }

    final memText = cell('memoria');
    if (memText.isEmpty) throw const BatchError('falta a memória');
    final typeText = cell('tipo');
    final declared = typeText.isEmpty ? null : _type(typeText);
    final MemoryRef ref;
    try {
      ref = VendorProfiles.parseMemory(memText, profile: profile, bit: declared == null ? null : declared == TagDataType.bool);
    } on MemoryError catch (e) {
      throw BatchError('"$memText": ${e.message}');
    }

    // T e C têm contato (bit) e valor (registrador) com a mesma letra: sem o
    // tipo, adivinhar criaria metade das variáveis na área errada.
    final rule0 = ref.rule;
    if (declared == null && profile != null && rule0 != null && ref.bit == null) {
      final other = profile.rules.where((r) => r.prefix == rule0.prefix && r.isBit != rule0.isBit && r.addressOf(ref.number!) != null).firstOrNull;
      if (other != null) {
        final word = rule0.isBit ? other : rule0;
        throw BatchError('${ref.text} tem contato e valor: diga o tipo (BOOL para o contato, ${(word.forcedType ?? TagDataType.uint16).technical} para o valor)');
      }
    }

    final TagDataType type;
    if (ref.bit != null || ref.area.isBit) {
      if (declared != null && declared != TagDataType.bool) throw BatchError('${ref.text} é bit: o tipo é BOOL (ou deixe vazio)');
      type = TagDataType.bool;
    } else if (ref.rule?.forcedType != null) {
      if (declared != null && declared != TagDataType.int32 && declared != TagDataType.uint32) {
        throw BatchError('${ref.text} é contador de 32 bits: o tipo é INT32 (ou deixe vazio)');
      }
      type = declared ?? ref.rule!.forcedType!;
    } else {
      if (declared == TagDataType.bool) throw BatchError('${ref.text} é registrador: para um bit dele use ${ref.text}.0 a ${ref.text}.15');
      type = declared ?? TagDataType.uint16;
    }
    if (type == TagDataType.string) throw const BatchError('texto (STRING) precisa do tamanho: cadastre no formulário da variável');

    final rule = ref.rule;
    if (type.is32Bit && (rule?.wordsPerItem ?? 1) == 1) {
      if (rule != null) {
        final next = rule.addressOf(ref.number! + 1);
        if (next != ref.address + 1) {
          throw BatchError('${ref.text} com 32 bits ocuparia ${rule.text(ref.number! + 1)}, que ${next == null ? 'não existe neste CLP' : 'não fica logo depois no Modbus'}');
        }
      } else if (ref.address + 1 > 65535) {
        throw const BatchError('32 bits passaria do endereço 65535');
      }
    }

    final writable = _yes(cell('gravavel'));
    if (writable && ref.readOnly) throw BatchError('${ref.text} é só leitura: deixe "gravavel" vazio ou "não"');
    final name = cell('nome');

    return Tag(
      id: id,
      name: name.isEmpty ? ref.text : name,
      deviceId: device.id,
      area: ref.area,
      address: ref.address,
      dataType: type,
      byteOrder: type.is32Bit ? (profile?.defaultByteOrder ?? ByteOrder.abcd) : ByteOrder.abcd,
      bitIndex: ref.bit ?? 0,
      writable: writable,
      unit: cell('unidade'),
      scale: type.isNumeric ? _scale(cell('escala')) : 1,
      description: cell('descricao'),
      memory: ref.raw ? null : ref.text,
    ).normalized();
  }

  /// Nomes técnicos (BOOL, INT16, DINT, REAL…) e as palavras do próprio app.
  static TagDataType _type(String s) {
    final k = _plain(s).replaceAll(RegExp(r'[\s_\-/]'), '');
    return switch (k) {
      'bool' || 'bit' || 'booleano' || 'ligadesliga' => TagDataType.bool,
      'uint16' || 'uint' || 'word' || 'u16' || 'inteiro' || 'numerointeiro' => TagDataType.uint16,
      'int16' || 'int' || 'i16' || 'comsinal' || 'inteirocomsinal' => TagDataType.int16,
      'uint32' || 'udint' || 'dword' || 'u32' || 'inteirogrande' => TagDataType.uint32,
      'int32' || 'dint' || 'i32' || 'inteirograndecsinal' || 'inteirograndecomsinal' => TagDataType.int32,
      'float32' || 'float' || 'real' || 'comvirgula' || 'numerocomvirgula' => TagDataType.float32,
      'string' || 'texto' => TagDataType.string,
      _ => throw BatchError('tipo "$s" desconhecido: use BOOL, UINT16, INT16, UINT32, INT32 ou FLOAT32'),
    };
  }

  static bool _yes(String s) {
    final k = _plain(s);
    if (k.isEmpty) return false;
    if (const {'sim', 's', 'yes', 'y', '1', 'true', 'x', 'verdadeiro', 'v'}.contains(k)) return true;
    if (const {'nao', 'n', 'no', '0', 'false', 'falso', 'f'}.contains(k)) return false;
    throw BatchError('gravavel "$s": use sim ou não');
  }

  /// "0,1", "0.1", "÷10", "/10", "×10".
  static double _scale(String s) {
    var k = s.replaceAll(' ', '');
    if (k.isEmpty) return 1;
    var divide = false;
    if (k.startsWith('÷') || k.startsWith('/')) {
      divide = true;
      k = k.substring(1);
    } else if (k.startsWith('×') || k.startsWith('x') || k.startsWith('X') || k.startsWith('*')) {
      k = k.substring(1);
    }
    final v = double.tryParse(k.replaceAll(',', '.'));
    if (v == null || v == 0 || !v.isFinite) throw BatchError('escala "$s" não é um número (ex.: 0,1 ou ÷10)');
    return divide ? 1 / v : v;
  }

  static const _accents = {'á': 'a', 'à': 'a', 'â': 'a', 'ã': 'a', 'é': 'e', 'ê': 'e', 'í': 'i', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ú': 'u', 'ç': 'c'};

  /// Minúsculo e sem acento: "Gravável" = "gravavel", "Não" = "nao".
  static String _plain(String s) {
    final lower = s.trim().toLowerCase();
    final b = StringBuffer();
    for (final ch in lower.split('')) {
      b.write(_accents[ch] ?? ch);
    }
    return b.toString();
  }
}
