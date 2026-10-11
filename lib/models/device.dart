// Equipamento: onde os dados moram.

import '../core/modbus/modbus_framing.dart';

/// Como o app chega até o equipamento.
enum DeviceKind {
  /// Modbus TCP/IP pela rede (Wi-Fi da fábrica, cabo, conversor serial→TCP).
  modbusTcp,

  /// Modbus RTU/ASCII "cru" pelo TCP: gateway serial→Ethernet com o CLP ou o
  /// inversor na linha RS-485 do outro lado. O envelope (RTU ou ASCII) fica em
  /// [Device.framing].
  modbusRtuTcp,

  /// Máquina simulada dentro do próprio app — modo demonstração. Tem um
  /// "programa" rodando (ver [DemoProcess]) para os valores se mexerem.
  demo,
}

extension DeviceKindMeta on DeviceKind {
  String get label {
    switch (this) {
      case DeviceKind.modbusTcp:
        return 'Equipamento na rede (Modbus TCP)';
      case DeviceKind.modbusRtuTcp:
        return 'Gateway RS-485 (Modbus RTU/ASCII sobre TCP)';
      case DeviceKind.demo:
        return 'Máquina de demonstração';
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
/// Ponto de extensão planejado: perfis de fabricante (ex.: Inovance) vão
/// entrar aqui como um campo `profile` que traduz nomes de memória do CLP
/// ("M100", "D200") em endereço Modbus. O protocolo não muda entre marcas —
/// só onde cada área começa — então o resto do app não precisa saber.
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

  bool get isDemo => kind == DeviceKind.demo;

  /// Fala com o equipamento pela rede (IP e porta), qualquer que seja o
  /// protocolo.
  bool get isNetwork => kind == DeviceKind.modbusTcp || kind == DeviceKind.modbusRtuTcp;

  /// Descrição curta para listas: "192.168.0.10:502 · ID 1".
  String get addressLabel => isDemo
      ? 'Simulada neste aparelho'
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
      );

  /// Duas configurações que exigem reabrir a conexão se mudarem.
  bool sameLinkAs(Device other) =>
      kind == other.kind &&
      host == other.host &&
      port == other.port &&
      unitId == other.unitId &&
      timeoutMs == other.timeoutMs &&
      framing == other.framing;

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
      );
}
