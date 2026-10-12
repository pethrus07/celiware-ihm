// Equipamento: onde os dados moram.

import '../core/modbus/modbus_framing.dart';
import 'mqtt_config.dart';
import 's7_config.dart';
import 'raw_config.dart';
import 'serial_config.dart';

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

  /// CLP Siemens S7 (300, 400, 1200, 1500) pela rede, no S7 "clássico"
  /// (PUT/GET, porta 102). Rack e slot ficam em [Device.s7].
  s7,
  /// Arduino, ESP, balança ou leitor que manda a sua própria mensagem
  /// (`T=25.3;P=1`) por TCP ou UDP — sem norma. Como ler a mensagem fica no
  /// perfil, em [Device.raw].
  raw,
  /// Equipamento virtual das variáveis calculadas ([CalcDevice]): não fala com
  /// nada, faz as contas com o que as outras variáveis leram.
  calc,

  /// Cabo USB-OTG no celular com adaptador RS-485/RS-232 (CH340, FTDI,
  /// CP210x, PL2303) ou o próprio USB de um Arduino. Fala Modbus RTU/ASCII
  /// ou a mensagem do Arduino (perfil em [Device.raw]); adaptador, velocidade
  /// e protocolo ficam em [Device.serial]. Um tipo só para o cabo — e não um
  /// "meio" ao lado de cada protocolo — porque o que muda é o lugar onde o
  /// equipamento está, como "na rede" ou "demonstração".
  usbSerial,
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
      case DeviceKind.s7:
        return 'CLP Siemens S7';
      case DeviceKind.raw:
        return 'Arduino, ESP ou balança (mensagem própria)';
      case DeviceKind.calc:
        return 'Variáveis calculadas';
      case DeviceKind.usbSerial:
        return 'Cabo USB (RS-485/RS-232)';
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
    this.s7 = const S7Config(),
    this.raw = const RawConfig(),
    this.serial = const SerialConfig(),
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

  /// CLP em [DeviceKind.s7]: família (rack e slot).
  final S7Config s7;
  /// Em [DeviceKind.raw]: TCP ou UDP e o perfil da mensagem. No cabo USB
  /// com Arduino, só o perfil.
  final RawConfig raw;

  /// Em [DeviceKind.usbSerial]: adaptador, velocidade, bits, paridade e o que
  /// fala pelo cabo.
  final SerialConfig serial;

  bool get isDemo => kind == DeviceKind.demo;

  /// Variável aponta para área + endereço Modbus (a demonstração também:
  /// ela simula um CLP Modbus). S7, MQTT e os outros têm endereço próprio —
  /// ficam fora do "Criar várias", que gera faixas de memória Modbus.
  bool get usesModbusMemory =>
      kind == DeviceKind.modbusTcp || kind == DeviceKind.modbusRtuTcp || kind == DeviceKind.demo || (isUsb && !serial.isRaw);

  /// Pelo cabo USB-OTG.
  bool get isUsb => kind == DeviceKind.usbSerial;

  /// Fala a mensagem própria de um Arduino (pela rede ou pelo cabo): as
  /// variáveis apontam para um campo da mensagem, não para memória Modbus.
  bool get speaksRaw => kind == DeviceKind.raw || (isUsb && serial.isRaw);
  /// O equipamento virtual das calculadas — fica fora de Equipamentos.
  bool get isCalc => kind == DeviceKind.calc;

  /// Fala com o equipamento pela rede (IP e porta), qualquer que seja o
  /// protocolo.
  bool get isNetwork =>
      kind == DeviceKind.modbusTcp || kind == DeviceKind.modbusRtuTcp || kind == DeviceKind.mqtt || kind == DeviceKind.s7 || kind == DeviceKind.raw;

  /// Descrição curta para listas: "192.168.0.10:502 · ID 1".
  String get addressLabel => isDemo
      ? 'Simulada neste aparelho'
      : isCalc
          ? 'Contas feitas neste aparelho'
          : kind == DeviceKind.mqtt
          ? '$host:$port · MQTT${mqtt.tls ? ' · TLS' : ''}'
          : kind == DeviceKind.s7
          ? '$host:$port · ${s7.label}'
          : kind == DeviceKind.raw
          ? '$host:$port · Arduino · ${raw.transport.label}'
          : isUsb
          ? 'Cabo USB · ${serial.label}${serial.isRaw ? '' : ' · ID $unitId'}'
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
    S7Config? s7,
    RawConfig? raw,
    SerialConfig? serial,
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
        s7: s7 ?? this.s7,
        raw: raw ?? this.raw,
        serial: serial ?? this.serial,
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
        s7: s7,
        raw: raw,
        serial: serial,
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
      s7 == other.s7 &&
      raw == other.raw &&
      serial == other.serial;

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
        // S7 de fábrica (1200/1500) não grava nada; família diferente, só ela.
        if (kind == DeviceKind.s7 && s7.toJson().isNotEmpty) 's7': s7.toJson(),
        if (kind == DeviceKind.raw) 'raw': raw.toJson(),
        if (isUsb) 'serial': serial.toJson(),
        // Arduino no cabo: só o perfil (TCP/UDP não existem aqui).
        if (isUsb && serial.isRaw) 'raw': {'profile': raw.profile.toJson()},
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
        s7: j['s7'] is Map ? S7Config.fromJson(Map<String, dynamic>.from(j['s7'] as Map)) : const S7Config(),
        raw: j['raw'] is Map ? RawConfig.fromJson(Map<String, dynamic>.from(j['raw'] as Map)) : const RawConfig(),
        serial: j['serial'] is Map ? SerialConfig.fromJson(Map<String, dynamic>.from(j['serial'] as Map)) : const SerialConfig(),
      );
}
