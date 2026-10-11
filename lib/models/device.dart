// Equipamento: onde os dados moram.

import '../core/modbus/modbus_framing.dart';
import 'mqtt_config.dart';
import 'raw_config.dart';

/// Como o app chega até o equipamento.
enum DeviceKind {
  /// Modbus TCP/IP pela rede (Wi-Fi da fábrica, cabo, conversor serial→TCP).
  modbusTcp,

  /// Modbus RTU/ASCII "cru" pelo TCP: gateway serial→Ethernet com o CLP ou o
  /// inversor na linha RS-485 do outro lado. O envelope (RTU ou ASCII) fica em
  /// [Device.framing].
  modbusRtuTcp,

  /// Equipamento que publica num broker MQTT da rede local (Mosquitto,
  /// Node-RED, CLP ou ESP32 com MQTT). Host e porta são os do broker; o resto
  /// fica em [Device.mqtt].
  mqtt,

  /// Máquina simulada dentro do próprio app — modo demonstração. Tem um
  /// "programa" rodando (ver [DemoProcess]) para os valores se mexerem.
  demo,

  /// Arduino, ESP, balança ou leitor que manda a sua própria mensagem
  /// (`T=25.3;P=1`) por TCP ou UDP — sem norma. Como ler a mensagem fica no
  /// perfil, em [Device.raw].
  raw,
}

extension DeviceKindMeta on DeviceKind {
  String get label {
    switch (this) {
      case DeviceKind.modbusTcp:
        return 'Equipamento na rede (Modbus TCP)';
      case DeviceKind.modbusRtuTcp:
        return 'Gateway RS-485 (Modbus RTU/ASCII sobre TCP)';
      case DeviceKind.mqtt:
        return 'Equipamento num broker MQTT';
      case DeviceKind.demo:
        return 'Máquina de demonstração';
      case DeviceKind.raw:
        return 'Arduino, ESP ou balança (mensagem própria)';
    }
  }

  static DeviceKind fromName(String? name) => DeviceKind.values.firstWhere(
      (k) => k.name == name,
      orElse: () => DeviceKind.modbusTcp);
}

/// Um equipamento cadastrado: CLP, inversor, IHM, gateway...
///
/// Imutável. Só guarda **como** conversar; os valores lidos vivem no
/// [TagStore] e nunca vão para o disco.
///
/// [profile] é o perfil de fabricante (`lib/models/vendor_profiles.dart`), que
/// traduz nomes de memória do CLP ("M100", "D200") em endereço Modbus. O
/// protocolo não muda entre marcas — só onde cada área começa — então o resto
/// do app não precisa saber.
class Device {
  const Device({
    required this.id,
    required this.name,
    this.kind = DeviceKind.modbusTcp,
    this.host = '',
    this.port = 502,
    this.unitId = 1,
    this.timeoutMs = 1500,
    this.pollMs = 500,
    this.framing = ModbusFraming.rtu,
    this.profile,
    this.mqtt = const MqttBroker(),
    this.raw = const RawConfig(),
  });

  final String id;
  final String name;
  final DeviceKind kind;

  /// IP ou nome na rede. Vazio em [DeviceKind.demo].
  final String host;
  final int port;

  /// Endereço do escravo (1..247). Conversores serial→TCP usam para escolher
  /// qual equipamento da linha RS-485 responde.
  final int unitId;

  /// Tempo máximo esperando cada resposta.
  final int timeoutMs;

  /// Intervalo entre varreduras completas das variáveis em uso.
  final int pollMs;

  /// Envelope das mensagens em [DeviceKind.modbusRtuTcp] (RTU ou ASCII).
  final ModbusFraming framing;

  /// Id do perfil de fabricante ("inovance-h3u"); nulo = Modbus genérico. O
  /// projeto guarda só o id: a tabela mora no código
  /// (`lib/models/vendor_profiles.dart`), e cada variável guarda o texto da
  /// memória (`Tag.memory`) para o endereço poder ser recalculado.
  final String? profile;
  /// Broker em [DeviceKind.mqtt]: TLS, usuário, keep-alive, testamento.
  final MqttBroker mqtt;

  /// Em [DeviceKind.raw]: TCP ou UDP e o perfil da mensagem.
  final RawConfig raw;

  bool get isDemo => kind == DeviceKind.demo;

  /// Fala com o equipamento pela rede (IP e porta), qualquer que seja o
  /// protocolo.
  bool get isNetwork => kind == DeviceKind.modbusTcp || kind == DeviceKind.modbusRtuTcp || kind == DeviceKind.mqtt || kind == DeviceKind.raw;

  /// Descrição curta para listas: "192.168.0.10:502 · ID 1".
  String get addressLabel => isDemo
      ? 'Simulada neste aparelho'
      : kind == DeviceKind.mqtt
          ? '$host:$port · MQTT${mqtt.tls ? ' · TLS' : ''}'
          : kind == DeviceKind.raw
          ? '$host:$port · Arduino · ${raw.transport.label}'
          : '$host:$port · ${kind == DeviceKind.modbusRtuTcp ? '${framing.label} · ' : ''}ID $unitId';

  Device copyWith({
    String? name,
    DeviceKind? kind,
    String? host,
    int? port,
    int? unitId,
    int? timeoutMs,
    int? pollMs,
    ModbusFraming? framing,
    MqttBroker? mqtt,
    RawConfig? raw,
  }) =>
      Device(
        id: id,
        name: name ?? this.name,
        kind: kind ?? this.kind,
        host: host ?? this.host,
        port: port ?? this.port,
        unitId: unitId ?? this.unitId,
        timeoutMs: timeoutMs ?? this.timeoutMs,
        pollMs: pollMs ?? this.pollMs,
        framing: framing ?? this.framing,
        mqtt: mqtt ?? this.mqtt,
        raw: raw ?? this.raw,
        profile: profile,
      );

  /// Troca o perfil — inclusive para nulo (Genérico), o que o [copyWith] não
  /// consegue. Não mexe na conexão.
  Device withProfile(String? profile) => Device(
        id: id,
        name: name,
        kind: kind,
        host: host,
        port: port,
        unitId: unitId,
        timeoutMs: timeoutMs,
        pollMs: pollMs,
        framing: framing,
        mqtt: mqtt,
        raw: raw,
        profile: profile,
      );

  /// Duas configurações que exigem reabrir a conexão se mudarem.
  bool sameLinkAs(Device other) =>
      kind == other.kind &&
      host == other.host &&
      port == other.port &&
      unitId == other.unitId &&
      timeoutMs == other.timeoutMs &&
      framing == other.framing &&
      mqtt == other.mqtt &&
      raw == other.raw;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'host': host,
        'port': port,
        'unitId': unitId,
        'timeoutMs': timeoutMs,
        'pollMs': pollMs,
        // Só quando importa: projeto de Modbus TCP fica igual ao de antes.
        if (kind == DeviceKind.modbusRtuTcp) 'framing': framing.name,
        if (profile != null) 'profile': profile,
        if (kind == DeviceKind.mqtt) 'mqtt': mqtt.toJson(),
        if (kind == DeviceKind.raw) 'raw': raw.toJson(),
      };

  factory Device.fromJson(Map<String, dynamic> j) => Device(
        id: j['id'] as String,
        name: j['name'] as String,
        kind: DeviceKindMeta.fromName(j['kind'] as String?),
        host: (j['host'] as String?) ?? '',
        port: (j['port'] as int?) ?? 502,
        unitId: (j['unitId'] as int?) ?? 1,
        timeoutMs: (j['timeoutMs'] as int?) ?? 1500,
        pollMs: (j['pollMs'] as int?) ?? 500,
        framing: ModbusFramingMeta.fromName(j['framing'] as String?),
        profile: j['profile'] as String?,
        mqtt: j['mqtt'] is Map ? MqttBroker.fromJson(Map<String, dynamic>.from(j['mqtt'] as Map)) : const MqttBroker(),
        raw: j['raw'] is Map ? RawConfig.fromJson(Map<String, dynamic>.from(j['raw'] as Map)) : const RawConfig(),
      );
}
