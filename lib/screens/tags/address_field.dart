import 'package:flutter/material.dart';

import '../../core/modbus/modbus_memory.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/common/common.dart';

/// Endereço digitado no cadastro de variável, já interpretado.
class AddressReading {
  const AddressReading({this.address, this.error, this.manual, this.converted = false, this.overMax = false});

  /// Endereço Modbus válido (0 a 65535), ou nulo.
  final int? address;

  /// O que está errado, em palavras de quem opera (nulo = nada).
  final String? error;

  /// Parece a notação de manual ("40101"): o endereço Modbus equivalente.
  final int? manual;

  /// Escrito em hexadecimal: vale mostrar o decimal ao lado ("= 8192").
  final bool converted;

  /// Número válido, mas acima de 65535.
  final bool overMax;
}

/// Leitura do endereço digitado — função pura, testável sem tela.
///
/// Aceita:
///   * decimal: "8192";
///   * hexadecimal com prefixo ou sufixo, como nos manuais de inversor:
///     "0x2000", "2000h" (= 8192) — colado, ou digitado num teclado com letras;
///   * no modo hexadecimal (`hex`), também "2000" sozinho;
///   * notação de manual ("40101", "400101"): não vira endereço sozinha, vira
///     sugestão ([AddressReading.manual]) — 40101 também é um endereço válido.
///
/// Perfis de fabricante ("D100", "M0") entram aqui: mais um formato que
/// devolve endereço (e área).
class AddressInput {
  AddressInput._();

  /// Maior endereço do protocolo.
  static const max = 65535;

  /// Limite do − / + em decimal: deixa andar dentro da notação de manual de
  /// 6 dígitos ("400101" → "400100"), como antes.
  static const _bumpMax = 499999;

  static final _prefixed = RegExp(r'^0x([0-9a-f]+)$', caseSensitive: false);
  static final _suffixed = RegExp(r'^([0-9a-f]+)h$', caseSensitive: false);
  static final _hexDigits = RegExp(r'^[0-9a-f]+$', caseSensitive: false);
  static final _decimal = RegExp(r'^\d+$');

  static String _clean(String text) => text.trim().replaceAll(' ', '');

  /// Texto → número, sem conferir a faixa. Nulo se não for número.
  static int? parse(String text, {bool hex = false}) {
    final t = _clean(text);
    final m = _prefixed.firstMatch(t) ?? _suffixed.firstMatch(t);
    if (m != null) return int.tryParse(m.group(1)!, radix: 16);
    if (hex && _hexDigits.hasMatch(t)) return int.tryParse(t, radix: 16);
    if (!hex && _decimal.hasMatch(t)) return int.tryParse(t);
    return null;
  }

  /// Número → texto no modo do campo ("2000" em hexadecimal, "8192" em decimal).
  static String format(int v, {bool hex = false}) => hex ? v.toRadixString(16).toUpperCase() : '$v';

  /// "40101" → 100 (holding), "30001" → 0 (input)... Nulo se não parece.
  static int? manualNotation(int v, ModbusArea area) {
    final prefix = switch (area) {
      ModbusArea.holdingRegister => 4,
      ModbusArea.inputRegister => 3,
      ModbusArea.discreteInput => 1,
      ModbusArea.coil => 0,
    };
    if (prefix == 0) return null; // "00001" não dá para distinguir de 1
    if (v >= prefix * 10000 + 1 && v <= prefix * 10000 + 9999) return v - prefix * 10000 - 1;
    if (v >= prefix * 100000 + 1 && v <= prefix * 100000 + 65536) return v - prefix * 100000 - 1;
    return null;
  }

  static AddressReading read(String text, {required ModbusArea area, bool hex = false}) {
    final t = _clean(text);
    if (t.isEmpty) return const AddressReading(error: 'Informe o endereço');
    final v = parse(t, hex: hex);
    if (v == null) return AddressReading(error: hex ? 'Hexadecimal: algarismos e letras de A a F' : 'Número inteiro');
    final converted = hex || !_decimal.hasMatch(t);
    // Notação de manual é sempre decimal.
    final manual = converted ? null : manualNotation(v, area);
    if (v > max) {
      return AddressReading(
        error: manual != null ? 'Acima de 65535: veja a sugestão abaixo' : 'Endereço acima de 65535',
        manual: manual,
        converted: converted,
        overMax: true,
      );
    }
    return AddressReading(address: v, manual: manual, converted: converted);
  }

  /// − / +: um a mais ou a menos, escrito do mesmo jeito que estava
  /// ("0x2000" + 1 = "0x2001"; "2000h" − 1 = "1FFFh").
  static String bump(String text, int delta, {bool hex = false}) {
    final t = _clean(text);
    final prefixed = _prefixed.hasMatch(t), suffixed = !prefixed && _suffixed.hasMatch(t);
    final inHex = hex || prefixed || suffixed;
    final v = ((parse(t, hex: hex) ?? 0) + delta).clamp(0, inHex ? max : _bumpMax);
    final digits = format(v, hex: inHex);
    if (prefixed) return '0x$digits';
    if (suffixed) return '${digits}h';
    return digits;
  }
}

/// Bloco do endereço no cadastro de variável: campo com − / +, o decimal
/// embaixo quando digitado em hexadecimal ("= 8192") e a sugestão da notação
/// de manual.
///
/// Isolado aqui de propósito: o campo "Memória do CLP" (perfis de fabricante,
/// "D100" → registrador 100) troca ou complementa este bloco sem mexer no
/// resto do formulário — o formulário só lê o resultado por
/// [AddressInput.read].
class AddressField extends StatelessWidget {
  const AddressField({super.key, required this.controller, required this.area, required this.onChanged, this.hex = false});

  final TextEditingController controller;
  final ModbusArea area;

  /// Modo hexadecimal (ligado em "Mais opções"): "2000" = 8192.
  final bool hex;
  final VoidCallback onChanged;

  void _set(String text) {
    controller.text = text;
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final r = AddressInput.read(controller.text, area: area, hex: hex);
    final manual = r.manual;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: TextFormField(
            key: const ValueKey('campo-endereco'),
            controller: controller,
            // Hexadecimal precisa de A–F: teclado com letras e números à vista
            // e sem corretor (visiblePassword). Fora dele, o numérico.
            keyboardType: hex ? TextInputType.visiblePassword : TextInputType.number,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: hex ? TextCapitalization.characters : TextCapitalization.none,
            style: Ind.number(20),
            decoration: InputDecoration(
              labelText: hex ? 'Endereço (hex)' : 'Endereço',
              helperText: r.converted && r.address != null ? '= ${r.address}' : null,
              // Acima de 65535 sem cara de notação de manual: avisa na hora,
              // sem esperar o Salvar. Com cara de manual, a sugestão azul
              // logo abaixo já explica.
              errorText: r.overMax && manual == null ? r.error : null,
            ),
            onChanged: (_) => onChanged(),
            validator: (_) => AddressInput.read(controller.text, area: area, hex: hex).error,
          ),
        ),
        const SizedBox(width: 6),
        StepButton(icon: Icons.remove_rounded, onTap: () => _set(AddressInput.bump(controller.text, -1, hex: hex))),
        const SizedBox(width: 6),
        StepButton(icon: Icons.add_rounded, onTap: () => _set(AddressInput.bump(controller.text, 1, hex: hex))),
      ]),
      if (manual != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SuggestionTile(
            key: const ValueKey('sugestao-endereco'),
            text: 'Parece a notação de manual (${controller.text.trim()}). No Modbus isso é o endereço $manual. Toque para usar.',
            onTap: () => _set('$manual'),
          ),
        ),
    ]);
  }
}
