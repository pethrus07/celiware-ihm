import 'package:flutter/foundation.dart';

import '../../core/s7/s7_address.dart';
import '../../core/s7/s7_client.dart';
import '../../core/s7/s7_codec.dart';
import '../../models/s7_config.dart';
import '../../models/tag.dart';
import 'tag_codec.dart';

/// O que ler no CLP para uma variável, e com qual tipo do S7.
@immutable
class S7TagPlan {
  const S7TagPlan(this.address, this.type);

  /// Endereço que cobre a variável inteira (numa lista, todos os valores).
  final S7Address address;
  final S7Type type;
}

/// Variável ⇄ S7, nos dois sentidos — o [TagCodec] do Siemens.
///
/// No S7 o endereço já diz o tamanho (X = bit, B = byte, W = palavra, D =
/// palavra dupla, P# = faixa), e o tipo da variável precisa caber nele: um
/// REAL num DBW é erro de cadastro, dito com o endereço certo já escrito
/// ("Número com vírgula pede 4 bytes: use DB1.DBD4"). Ordem de bytes não há:
/// o S7 é sempre big-endian, que é a ordem ABCD do Modbus — por isso escala,
/// sinal, 32 bits e lista passam pelo mesmo [TagCodec], com as mesmas
/// mensagens na unidade da tela.
abstract final class S7TagCodec {
  /// O tipo que combina com o tamanho do endereço: bit → liga/desliga, byte e
  /// palavra → número inteiro, palavra dupla → número com vírgula (o REAL é o
  /// mais comum num DB), faixa → texto.
  static TagDataType suggestedType(S7Address a) {
    if (a.isBit) return TagDataType.bool;
    return switch (a.byteLength) {
      1 || 2 => TagDataType.uint16,
      4 => TagDataType.float32,
      _ => TagDataType.string,
    };
  }

  /// Tipo do S7 para o tipo da variável neste endereço; nulo se não cabe.
  static S7Type? s7Type(S7Address a, TagDataType t) {
    if (a.isBit) return t == TagDataType.bool ? S7Type.boolean : null;
    return switch ((t, a.byteLength)) {
      (TagDataType.uint16, 1) => S7Type.byte,
      (TagDataType.uint16, 2) => S7Type.word,
      (TagDataType.int16, 2) => S7Type.int16,
      (TagDataType.uint32, 4) => S7Type.dword,
      (TagDataType.int32, 4) => S7Type.int32,
      (TagDataType.float32, 4) => S7Type.real,
      (TagDataType.string, >= 3) => S7Type.string,
      _ => null,
    };
  }

  /// Nome do tipo no TIA Portal (o que o integrador declarou no DB).
  static String technical(TagDataType t) => switch (t) {
        TagDataType.bool => 'BOOL',
        TagDataType.uint16 => 'WORD',
        TagDataType.int16 => 'INT',
        TagDataType.uint32 => 'DWORD',
        TagDataType.int32 => 'DINT',
        TagDataType.float32 => 'REAL',
        TagDataType.string => 'STRING',
      };

  /// O que não combina entre o endereço e a variável, já com o endereço certo
  /// no mesmo lugar do CLP; nulo quando está tudo certo. [german] escreve o
  /// exemplo com E/A, como a pessoa digitou.
  static String? problem(S7Address a, TagDataType t, {int length = 1, bool german = false}) {
    if (s7Type(a, t) == null) {
      final (need, bytes) = switch (t) {
        TagDataType.bool => ('um bit', 0),
        TagDataType.uint16 => ('1 ou 2 bytes', 2),
        TagDataType.int16 => ('2 bytes', 2),
        TagDataType.string => ('a faixa do STRING', 22),
        _ => ('4 bytes', 4),
      };
      final example = _example(a, bytes, german);
      return '${t.label} pede $need: use $example${t == TagDataType.string ? ' (STRING[20])' : ''}';
    }
    if (length > 1 && t != TagDataType.string) {
      if (t == TagDataType.bool) return 'lista de bits não é lida no S7: uma variável por bit';
      if (a.byteOffset + a.byteLength * length > S7Address.maxByte + 1) {
        return '${a.format(german: german)}: a lista passa do byte ${S7Address.maxByte}';
      }
    }
    return null;
  }

  /// O mesmo início, com o tamanho que o tipo pede (0 = bit).
  static String _example(S7Address a, int bytes, bool german) {
    try {
      return S7Address(
        area: a.area,
        dbNumber: a.dbNumber,
        byteOffset: a.byteOffset,
        bitIndex: bytes == 0 ? 0 : null,
        byteLength: bytes == 0 ? 1 : bytes,
      ).format(german: german);
    } on ArgumentError {
      // Perto do fim da área não cabe no mesmo byte: exemplo genérico.
      return switch (bytes) { 0 => 'DB1.DBX0.0', 2 => 'DB1.DBW0', 4 => 'DB1.DBD0', _ => 'P#DB1.DBX0.0 BYTE 22' };
    }
  }

  /// O que ler para [tag]. Lança [TagValueError] — erro de configuração da
  /// variável, não de comunicação — sem endereço S7 ou com tipo que não cabe.
  static S7TagPlan plan(Tag tag) {
    final s = tag.s7;
    if (s == null) throw const TagValueError('variável sem endereço S7');
    final S7Address a;
    try {
      a = S7Address.parse(s.address);
    } on FormatException catch (e) {
      throw TagValueError(e.message);
    }
    final problem = S7TagCodec.problem(a, tag.dataType, length: tag.length, german: S7TagAddress.isGerman(s.address));
    if (problem != null) throw TagValueError(problem);
    final type = s7Type(a, tag.dataType)!;
    return S7TagPlan(tag.isArray ? a.withLength(a.byteLength * tag.length) : a, type);
  }

  // ── Leitura ──────────────────────────────────────────────────────────────────

  /// Bytes do CLP → valor na unidade da tela. Em liga/desliga, [bytes] é um
  /// byte com o valor no bit 0 (como o transporte BIT devolve).
  static Object decode(Tag tag, S7TagPlan plan, Uint8List bytes) {
    switch (plan.type) {
      case S7Type.boolean:
        return S7Codec.decode(S7Type.boolean, bytes);
      case S7Type.string:
        return S7Codec.decodeString(bytes);
      case S7Type.byte:
        final values = [for (final b in bytes.take(tag.length)) tag.hasScale ? b * tag.scale + tag.offset : b];
        return tag.isArray ? values : values.first;
      default:
        // Palavras big-endian são registradores na ordem ABCD.
        return TagCodec.decodeRegisters(tag, [for (var i = 0; i + 1 < bytes.length; i += 2) (bytes[i] << 8) | bytes[i + 1]]);
    }
  }

  // ── Escrita ──────────────────────────────────────────────────────────────────

  /// Valor na unidade da tela → o que gravar. Bit vai com transporte BIT: só
  /// aquele bit muda no CLP, sem ler e regravar o byte. Valor que não cabe
  /// lança [TagValueError] com a faixa na unidade da tela.
  static S7WriteItem encode(Tag tag, S7TagPlan plan, Object value) {
    switch (plan.type) {
      case S7Type.boolean:
        return S7WriteItem.bit(plan.address, switch (value) {
          bool b => b,
          num n => n != 0,
          _ => throw const TagValueError('Esperado liga/desliga'),
        });
      case S7Type.string:
        throw TagValueError('"${tag.name}" é texto; não é gravável pela tela');
      default:
        if (value is! num) throw TagValueError('"${tag.name}" espera um número');
        final regs = TagCodec.encodeRegisters(tag, value);
        if (plan.type == S7Type.byte) {
          // O TagCodec conferiu passo e faixa de 16 bits; o byte vai até 255.
          if (regs.single > 0xFF) {
            final a = _eng(tag, 0), b = _eng(tag, 0xFF);
            throw TagValueError('"${tag.name}" aceita de ${tag.scale < 0 ? b : a} a ${tag.scale < 0 ? a : b}');
          }
          return S7WriteItem(plan.address, Uint8List.fromList(regs));
        }
        return S7WriteItem(plan.address, Uint8List.fromList([for (final r in regs) ...[r >> 8, r & 0xFF]]));
    }
  }

  static String _eng(Tag tag, int raw) => TagCodec.format(tag, tag.hasScale ? raw * tag.scale + tag.offset : raw, withUnit: false);
}

/// Um item do pedido de leitura que atende uma ou várias variáveis.
class S7ScanBlock {
  S7ScanBlock(this.address, this.members);

  final S7Address address;
  final List<(Tag, S7TagPlan)> members;

  /// Os bytes de [plan] dentro do que foi lido; bit vira um byte com o valor
  /// no bit 0.
  Uint8List bytesOf(S7TagPlan plan, Uint8List data) {
    // Item próprio de um bit: o transporte BIT já devolve 0 ou 1.
    if (address.isBit) return data;
    final a = plan.address;
    final off = a.byteOffset - address.byteOffset;
    final part = Uint8List.sublistView(data, off, off + a.byteLength);
    return a.isBit ? Uint8List.fromList([(part[0] >> a.bitIndex!) & 1]) : part;
  }

  @override
  String toString() => '$address (${members.length} var.)';
}

/// Junta variáveis vizinhas do mesmo DB (ou da mesma área M, I, Q) num item
/// só do pedido.
///
/// O cliente já põe vários itens por pedido até encher a PDU negociada; juntar
/// os vizinhos ainda poupa o item de 12 bytes no pedido e o cabeçalho de 4 na
/// resposta de cada variável — com PDU 240 um pedido leva 19 itens, mas 222
/// bytes de um DB. Dentro de um DB não há buraco (a memória é contínua), então
/// ler os bytes entre duas variáveis que existem é sempre seguro.
///
/// Variável em [isolated] (o item juntado voltou com erro) ganha item próprio:
/// só a errada fica marcada, como no Modbus.
class S7ScanPlanner {
  const S7ScanPlanner({this.maxGap = 32, this.maxBytes = 200});

  /// Bytes que se aceita ler à toa entre duas variáveis.
  final int maxGap;

  /// Teto de um item juntado: com PDU 240, cabe numa resposta sozinho.
  final int maxBytes;

  List<S7ScanBlock> plan(List<(Tag, S7TagPlan)> items, {Set<String> isolated = const {}}) {
    final blocks = <S7ScanBlock>[];
    final groups = <(S7Area, int), List<(Tag, S7TagPlan)>>{};
    for (final it in items) {
      final a = it.$2.address;
      if (isolated.contains(it.$1.id) || a.byteLength > maxBytes) {
        blocks.add(S7ScanBlock(a, [it]));
      } else {
        groups.putIfAbsent((a.area, a.dbNumber), () => []).add(it);
      }
    }
    for (final group in groups.values) {
      group.sort((x, y) => x.$2.address.byteOffset.compareTo(y.$2.address.byteOffset));
      var start = 0, end = 0;
      var members = <(Tag, S7TagPlan)>[];
      void flush() {
        if (members.isEmpty) return;
        final first = members.first.$2.address;
        // Sozinha, a variável fica com o próprio endereço (bit com transporte BIT).
        blocks.add(S7ScanBlock(
          members.length == 1 ? first : S7Address(area: first.area, dbNumber: first.dbNumber, byteOffset: start, byteLength: end - start),
          members,
        ));
        members = [];
      }

      for (final it in group) {
        final a = it.$2.address;
        final fits = members.isNotEmpty && a.byteOffset - end <= maxGap && (a.endByte > end ? a.endByte : end) - start <= maxBytes;
        if (!fits) {
          flush();
          start = a.byteOffset;
          end = a.endByte;
        } else if (a.endByte > end) {
          end = a.endByte;
        }
        members.add(it);
      }
      flush();
    }
    return blocks;
  }
}
