// Configuração Siemens S7: a do equipamento (família do CLP → rack e slot) e
// a da variável (o endereço como no TIA Portal).
//
// Como no MQTT, fica fora de Device e Tag para os dois continuarem com cara de
// Modbus no arquivo de quem não usa S7: os campos daqui só vão para o JSON
// quando o equipamento é S7 ou a variável tem endereço S7.

import 'package:flutter/foundation.dart';

import '../core/s7/s7_address.dart';
import '../core/s7/s7_client.dart' show S7Cpu;

/// Família do CLP, em palavras de quem tem o CLP na frente. Ela decide o
/// rack e o slot de fábrica (a tabela mora em [S7Cpu]); "Outro" é para CPU
/// fora do lugar de fábrica — S7-400 em outro slot, CPU num bastidor
/// diferente — e mostra os dois números.
enum S7Family {
  s7300('S7-300', S7Cpu.s7300),
  s7400('S7-400', S7Cpu.s7400),
  s71200('S7-1200/1500', S7Cpu.s71200),
  other('Outro', null);

  const S7Family(this.label, this.cpu);
  final String label;

  /// Rack e slot de fábrica; nulo em [other].
  final S7Cpu? cpu;

  static S7Family fromName(String? n) => S7Family.values.firstWhere((f) => f.name == n, orElse: () => S7Family.s71200);
}

/// Como o app fala com um CLP S7. O IP e a porta continuam em `Device.host`
/// / `Device.port` (102).
@immutable
class S7Config {
  /// [rack] e [slot] só valem em [S7Family.other]; nas outras famílias vale
  /// o de fábrica.
  const S7Config({this.family = S7Family.s71200, this._rack = 0, this._slot = 1});

  /// ISO-on-TCP. O simulador do python-snap7 usa 1102.
  static const int defaultPort = 102;

  /// 1200/1500 é o que mais aparece hoje e é o padrão do cliente.
  final S7Family family;
  final int _rack;
  final int _slot;

  int get rack => family.cpu?.rack ?? _rack;
  int get slot => family.cpu?.slot ?? _slot;

  /// "S7-1200/1500" ou, com rack e slot à mão, "S7 · rack 0 · slot 3".
  String get label => family == S7Family.other ? 'S7 · rack $rack · slot $slot' : family.label;

  /// Só o que difere do padrão: 1200/1500 de fábrica não grava nada.
  Map<String, dynamic> toJson() => {
        if (family != S7Family.s71200) 'family': family.name,
        if (family == S7Family.other && _rack != 0) 'rack': _rack,
        if (family == S7Family.other && _slot != 1) 'slot': _slot,
      };

  factory S7Config.fromJson(Map<String, dynamic> j) => S7Config(
        family: S7Family.fromName(j['family'] as String?),
        // Fora da faixa o TSAP não existe: o cliente recusaria montar a conexão.
        rack: ((j['rack'] as int?) ?? 0).clamp(0, 7),
        slot: ((j['slot'] as int?) ?? 1).clamp(0, 31),
      );

  @override
  bool operator ==(Object other) => other is S7Config && other.family == family && other.rack == rack && other.slot == slot;

  @override
  int get hashCode => Object.hash(family, rack, slot);
}

/// Onde mora uma variável S7: o endereço como no TIA Portal ("DB1.DBW4",
/// "M10.3", "IW64" ou "EW64", "P#DB1.DBX10.0 BYTE 22" para STRING).
///
/// Guarda o texto, não a área e o byte: é o que a pessoa conhece e o que a
/// lista mostra. A leitura do texto é do núcleo ([S7Address.parse]); o tipo
/// de dado continua sendo o da variável (`Tag.dataType`), conferido contra o
/// tamanho do endereço no driver.
@immutable
class S7TagAddress {
  const S7TagAddress(this.address);

  /// O endereço já arrumado por [normalize] (texto inválido fica como veio).
  final String address;

  /// O endereço lido; nulo se o texto não for um endereço S7.
  S7Address? get parsed => S7Address.tryParse(address);

  bool get isValid => parsed != null;

  /// Entrada (I/E) é a imagem do que está ligado no CLP: o próximo ciclo
  /// sobrescreve qualquer gravação. Fica só leitura, como a entrada do Modbus.
  bool get canWrite => parsed?.area != S7Area.inputs;

  /// Endereço escrito no mnemônico alemão (E = entrada, A = saída).
  static bool isGerman(String text) {
    var s = text.trim().toUpperCase();
    if (s.startsWith('%')) s = s.substring(1).trimLeft();
    if (s.startsWith('P#')) s = s.substring(2).trimLeft();
    return s.startsWith('E') || s.startsWith('A');
  }

  /// O texto canônico do endereço digitado, no mnemônico que a pessoa usou:
  /// "%db1.dbd8" → "DB1.DBD8", "ew64" → "EW64". Texto que não é endereço
  /// volta só sem os espaços das pontas.
  static String normalize(String text) {
    final a = S7Address.tryParse(text);
    return a == null ? text.trim() : a.format(german: isGerman(text));
  }

  Map<String, dynamic> toJson() => {'address': address};

  factory S7TagAddress.fromJson(Map<String, dynamic> j) => S7TagAddress((j['address'] as String?) ?? '');

  @override
  bool operator ==(Object other) => other is S7TagAddress && other.address == address;

  @override
  int get hashCode => address.hashCode;
}
