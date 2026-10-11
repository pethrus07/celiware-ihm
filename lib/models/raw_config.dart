// Protocolo cru (Arduino, ESP, balança, leitor): a configuração do
// equipamento (por onde a mensagem viaja e o perfil que diz como lê-la) e a
// da variável (qual campo da mensagem ela mostra e como grava).
//
// Como no MQTT, fica fora de Device e Tag para os dois continuarem com cara
// de Modbus no arquivo de quem não usa: os campos daqui só vão para o JSON
// quando o equipamento é cru ou a variável tem campo.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/rawlink/message_profile.dart';

/// Por onde a mensagem viaja.
enum RawTransport {
  /// Conexão TCP: o `WiFiServer` do sketch, conversor serial→Ethernet.
  tcp('TCP'),

  /// Datagramas UDP: o `WiFiUDP` do ESP — cada pacote é uma mensagem.
  udp('UDP');

  const RawTransport(this.label);
  final String label;

  static RawTransport fromName(String? n) => RawTransport.values.firstWhere((t) => t.name == n, orElse: () => RawTransport.tcp);
}

/// Como o app conversa com um equipamento cru. IP e porta continuam em
/// `Device.host` / `Device.port`.
@immutable
class RawConfig {
  const RawConfig({this.transport = RawTransport.tcp, this.localPort = 0, this.profile = RawTemplates.keyValueProfile});

  /// Equipamento cru não tem porta padrão. Esta é só a de partida (a do
  /// `sim/arduino_falso.py`); a de verdade está no programa do equipamento.
  static const int defaultPort = 5030;

  final RawTransport transport;

  /// UDP: a porta deste celular, para onde o equipamento manda — a que está
  /// gravada no sketch junto com o IP do celular. 0 = qualquer uma livre:
  /// serve para equipamento que responde a quem falou por último (polling).
  final int localPort;

  /// Como a mensagem termina, se confere, como tirar os campos, quem fala
  /// primeiro e o comando para gravar.
  final MessageProfile profile;

  bool get isUdp => transport == RawTransport.udp;

  RawConfig copyWith({RawTransport? transport, int? localPort, MessageProfile? profile}) => RawConfig(
        transport: transport ?? this.transport,
        localPort: localPort ?? this.localPort,
        profile: profile ?? this.profile,
      );

  Map<String, dynamic> toJson() => {
        'transport': transport.name,
        if (isUdp && localPort != 0) 'localPort': localPort,
        'profile': profile.toJson(),
      };

  factory RawConfig.fromJson(Map<String, dynamic> j) => RawConfig(
        transport: RawTransport.fromName(j['transport'] as String?),
        localPort: ((j['localPort'] as int?) ?? 0).clamp(0, 65535),
        profile: j['profile'] is Map ? MessageProfile.fromJson(Map<String, dynamic>.from(j['profile'] as Map)) : RawTemplates.keyValueProfile,
      );

  /// O perfil não tem `==`: compara pelo que vai para o arquivo — é o que
  /// decide se a conexão precisa ser refeita com o perfil novo.
  String get _profileKey => jsonEncode(profile.toJson());

  @override
  bool operator ==(Object other) =>
      other is RawConfig && other.transport == transport && other.localPort == localPort && other._profileKey == _profileKey;

  @override
  int get hashCode => Object.hash(transport, localPort, _profileKey);
}

/// Onde mora uma variável crua: o "endereço" dela.
@immutable
class RawAddress {
  const RawAddress({required this.field, this.validitySec = 0, this.command});

  /// A chave do campo na mensagem: `T` em `T=25.3`, a posição (`1`, `2`…)
  /// num CSV sem nomes, o nome do grupo da regex ou do campo binário.
  final String field;

  /// Sem este campo na mensagem por tantos segundos = "sem comunicação" só
  /// nesta variável (o resto da mensagem continua chegando). 0 = sem prazo
  /// próprio: vale só a validade do equipamento (equipamento mudo).
  final int validitySec;

  /// Comando só desta variável. Nulo = o do equipamento (o perfil traz
  /// `SET {campo}={valor}\n` nos modelos prontos).
  final CommandTemplate? command;

  String get key => field.trim();

  bool get isValid => key.isNotEmpty;

  /// "campo T".
  String get label => 'campo $key';

  RawAddress copyWith({String? field, int? validitySec}) =>
      RawAddress(field: field ?? this.field, validitySec: validitySec ?? this.validitySec, command: command);

  /// Troca o comando — inclusive para nulo (usar o do equipamento), o que o
  /// [copyWith] não consegue.
  RawAddress withCommand(CommandTemplate? command) => RawAddress(field: field, validitySec: validitySec, command: command);

  Map<String, dynamic> toJson() => {
        'field': field,
        if (validitySec != 0) 'validitySec': validitySec,
        if (command != null) 'command': command!.toJson(),
      };

  factory RawAddress.fromJson(Map<String, dynamic> j) => RawAddress(
        field: (j['field'] as String?) ?? '',
        validitySec: ((j['validitySec'] as int?) ?? 0).clamp(0, 86400),
        command: j['command'] is Map ? CommandTemplate.fromJson(j['command']) : null,
      );

  String get _commandKey => command == null ? '' : jsonEncode(command!.toJson());

  @override
  bool operator ==(Object other) =>
      other is RawAddress && other.field == field && other.validitySec == validitySec && other._commandKey == _commandKey;

  @override
  int get hashCode => Object.hash(field, validitySec, _commandKey);
}

/// Um modelo pronto de perfil: para começar sem saber nada de delimitador e
/// checksum. Quem quiser ajusta no editor.
@immutable
class RawTemplate {
  const RawTemplate(this.id, this.name, this.example, this.profile);

  /// Estável, para a interface (não vai para o arquivo: o perfil vai inteiro).
  final String id;
  final String name;

  /// Como a mensagem chega, para a pessoa reconhecer a do equipamento dela.
  final String example;
  final MessageProfile profile;
}

class RawTemplates {
  RawTemplates._();

  static const CommandTemplate setCommand = CommandTemplate.text('SET {campo}={valor}\n');

  /// `T=25.3;P=1\n` — o `Serial.print` mais comum. Também é o padrão.
  static const MessageProfile keyValueProfile = MessageProfile(commands: [setCommand]);

  /// `25.3,1,OK\n` — campos pela posição (1, 2, 3).
  static const MessageProfile csvProfile = MessageProfile(fields: CsvFields(), commands: [setCommand]);

  /// `AA 55` + dois números de 16 bits na ordem do Arduino (byte baixo
  /// primeiro): o `Serial.write` de uma struct.
  static const MessageProfile binaryProfile = MessageProfile(
    framing: FixedLengthFraming(length: 6, header: '\xAA\x55'),
    fields: BinaryFields([
      BinaryField(key: 'valor1', offset: 2, order: RawByteOrder.dcba),
      BinaryField(key: 'valor2', offset: 4, order: RawByteOrder.dcba),
    ]),
  );

  static const RawTemplate keyValue = RawTemplate('chave-valor', 'Linha chave=valor', 'T=25.3;P=1', keyValueProfile);
  static const RawTemplate csv = RawTemplate('virgulas', 'Linha com vírgulas', '25.3,1,OK', csvProfile);
  static const RawTemplate binary = RawTemplate('binario', 'Binário simples', 'AA 55 + dois números de 16 bits', binaryProfile);

  static const List<RawTemplate> all = [keyValue, csv, binary];

  /// O modelo que o perfil segue, pelo jeito de tirar os campos (mudar um
  /// separador não deixa de ser "chave=valor"). Nulo = regex.
  static RawTemplate? of(MessageProfile p) => switch (p.fields) {
        KeyValueFields() => keyValue,
        CsvFields() => csv,
        BinaryFields() => binary,
        RegexFields() => null,
      };

  /// Nome curto do perfil para listas e resumos.
  static String describe(MessageProfile p) => of(p)?.name ?? 'Mensagem própria (regex)';
}
