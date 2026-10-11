import 'package:flutter/material.dart';

import '../../core/s7/s7_address.dart';
import '../../core/theme/app_theme.dart';
import '../../models/s7_config.dart';
import '../../models/tag.dart';
import '../../services/runtime/s7_tag_codec.dart';
import '../../widgets/hmi/element_catalog.dart';

/// Estado do endereço S7 no cadastro de variável — o "endereço" quando o
/// equipamento é um CLP Siemens. Fica fora do formulário para ele só trocar o
/// bloco de endereço Modbus por este, como faz com o MQTT.
class S7TagFields {
  S7TagFields(S7TagAddress? a) : address = TextEditingController(text: a?.address ?? '');

  final TextEditingController address;

  String get _text => address.text.trim();

  /// O endereço lido; nulo enquanto o texto não for um endereço S7.
  S7Address? get parsed => S7Address.tryParse(_text);

  /// Digitado com E/A (mnemônico alemão): os exemplos seguem igual.
  bool get german => S7TagAddress.isGerman(_text);

  /// O que está errado no endereço, ou entre ele e o tipo escolhido — curto,
  /// em português e com o endereço certo quando dá ("Número com vírgula pede
  /// 4 bytes: use DB1.DBD4"). Nulo se está tudo certo.
  String? error(TagDataType type, {int length = 1}) {
    if (_text.isEmpty) return 'Informe o endereço (ex.: DB1.DBW4)';
    final a = parsed;
    if (a == null) return S7Address.validate(_text);
    return S7TagCodec.problem(a, type, length: length, german: german);
  }

  /// O endereço como vai para a variável, já arrumado ("%db1.dbd8" → "DB1.DBD8").
  S7TagAddress build() => S7TagAddress(S7TagAddress.normalize(_text));

  /// Entrada (I/E) é só leitura.
  bool get canWrite => parsed?.area != S7Area.inputs;

  /// O tipo que o tamanho do endereço pede (X → liga/desliga, W → inteiro,
  /// D → com vírgula, P# → texto), quando o de agora não cabe nele e o
  /// elemento que abriu o cadastro aceita esse tipo. Nulo = deixa como está:
  /// quem trocou o REAL de um DBD para DINT não perde a escolha.
  TagDataType? suggestedType(TagDataType current, TagFit? fit) {
    final a = parsed;
    if (a == null || S7TagCodec.s7Type(a, current) != null) return null;
    final t = S7TagCodec.suggestedType(a);
    final fits = switch (fit) {
      TagFit.boolean => t == TagDataType.bool,
      TagFit.number || TagFit.numberList => t.isNumeric,
      TagFit.scalar => t != TagDataType.string,
      _ => true,
    };
    return fits ? t : null;
  }

  void dispose() => address.dispose();

  /// Nome do tipo no TIA Portal (INT, DINT, REAL), ao lado do nome leigo.
  static String technical(TagDataType t) => S7TagCodec.technical(t);

  /// A prova da leitura do endereço, em palavras: "DB1.DBW4 → DB 1, palavra
  /// no byte 4". Lista e texto dizem quanto ocupam.
  static String proof(S7Address a, TagDataType type, {int length = 1, bool german = false}) {
    final where = switch (a.area) {
      S7Area.db => 'DB ${a.dbNumber}',
      S7Area.flags => 'memória M',
      S7Area.inputs => 'entradas',
      S7Area.outputs => 'saídas',
    };
    final String what;
    if (a.isBit) {
      what = 'bit ${a.bitIndex} do byte ${a.byteOffset}';
    } else if (type == TagDataType.string) {
      what = 'texto de até ${a.byteLength - 2} letras no byte ${a.byteOffset}';
    } else if (length > 1) {
      final many = switch (a.byteLength) { 1 => 'bytes', 2 => 'palavras', _ => 'palavras duplas' };
      what = '$length $many a partir do byte ${a.byteOffset}';
    } else {
      what = switch (a.byteLength) {
        1 => 'byte ${a.byteOffset}',
        2 => 'palavra no byte ${a.byteOffset}',
        4 => 'palavra dupla no byte ${a.byteOffset}',
        _ => '${a.byteLength} bytes a partir do byte ${a.byteOffset}',
      };
    }
    return '${a.format(german: german)} → $where, $what';
  }
}

/// O endereço como no TIA Portal, no lugar de "Onde fica" e "Endereço" do
/// Modbus. Embaixo, a prova da leitura ou o erro, enquanto se digita.
class S7AddressBlock extends StatelessWidget {
  const S7AddressBlock({super.key, required this.fields, required this.type, required this.length, required this.onChanged});

  final S7TagFields fields;
  final TagDataType type;

  /// Quantos valores seguidos (lista); 1 = valor único.
  final int length;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final typed = fields.address.text.trim().isNotEmpty;
    final error = typed ? fields.error(type, length: length) : null;
    final a = fields.parsed;
    return TextFormField(
      key: const ValueKey('campo-endereco-s7'),
      controller: fields.address,
      autocorrect: false,
      enableSuggestions: false,
      // Letras e números à vista, sem corretor.
      keyboardType: TextInputType.visiblePassword,
      textCapitalization: TextCapitalization.characters,
      style: Ind.number(20),
      decoration: InputDecoration(
        labelText: 'Endereço no CLP',
        hintText: 'Ex.: DB1.DBW4, M10.3, IW64',
        helperText: error == null && a != null ? S7TagFields.proof(a, type, length: length, german: fields.german) : null,
        helperMaxLines: 2,
        errorText: error,
        errorMaxLines: 3,
      ),
      onChanged: (_) => onChanged(),
      validator: (_) => fields.error(type, length: length),
    );
  }
}
