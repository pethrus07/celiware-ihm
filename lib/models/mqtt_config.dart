// Configuração MQTT: a do equipamento (como falar com o broker) e a da
// variável (em que tópico o dado mora).
//
// Ficam fora de Device e Tag para os dois continuarem com cara de Modbus no
// arquivo de quem não usa MQTT: os campos daqui só vão para o JSON quando o
// equipamento é MQTT ou a variável tem tópico.

import 'package:flutter/foundation.dart';

import '../core/mqtt/mqtt_topic.dart';

/// Como gravar liga/desliga num tópico de comando. Ler aceita todos.
///
/// Cada firmware espera um: Arduino/ESP costuma ler "1"/"0", Node-RED e JSON
/// "true"/"false", Tasmota e Home Assistant "ON"/"OFF". É escolha explícita
/// da variável — supor a convenção pelo que o equipamento publica falharia
/// justo na primeira gravação, antes de chegar qualquer mensagem.
enum MqttBoolFormat {
  oneZero('1', '0'),
  trueFalse('true', 'false'),
  onOff('ON', 'OFF');

  const MqttBoolFormat(this.on, this.off);
  final String on;
  final String off;

  String get label => '$on / $off';

  static MqttBoolFormat fromName(String? n) =>
      MqttBoolFormat.values.firstWhere((f) => f.name == n, orElse: () => MqttBoolFormat.oneZero);
}

/// Como o app fala com o broker de um equipamento MQTT. O IP e a porta do
/// broker continuam em `Device.host` / `Device.port`.
@immutable
class MqttBroker {
  const MqttBroker({
    this.tls = false,
    this.username = '',
    this.password = '',
    this.keepAliveSec = 10,
    this.clientId = '',
    this.statusTopic = '',
    this.offlinePayload = 'offline',
  });

  static const int defaultPort = 1883;
  static const int tlsPort = 8883;

  /// Conexão cifrada (normalmente na porta 8883).
  final bool tls;

  /// Vazios = broker sem autenticação.
  final String username;

  /// Vai no arquivo do projeto, inclusive no exportado — como o IP. O broker
  /// de uma rede de máquina costuma ter senha de rede local, não de pessoa.
  final String password;

  /// De quanto em quanto tempo o app avisa o broker que está vivo (PINGREQ).
  /// Também é como o app percebe um Wi-Fi que morreu sem fechar a conexão —
  /// por isso 10 s e não os 60 s comuns em MQTT: numa IHM, dado velho sem
  /// aviso por um minuto é demais. 0 desliga.
  final int keepAliveSec;

  /// Vazio = o app gera um ID novo a cada conexão. Fixo só para broker com
  /// permissão por ID: dois celulares com o mesmo projeto e o mesmo ID se
  /// derrubariam um ao outro (o broker só aceita uma conexão por ID).
  final String clientId;

  /// Tópico onde o equipamento deixa o testamento (LWT): quando ele cai, o
  /// broker publica [offlinePayload] ali e as variáveis dele ficam "sem
  /// comunicação". Vazio = o equipamento não avisa.
  final String statusTopic;
  final String offlinePayload;

  bool get hasStatusTopic => statusTopic.trim().isNotEmpty && MqttTopic.isValidFilter(statusTopic.trim());

  MqttBroker copyWith({
    bool? tls,
    String? username,
    String? password,
    int? keepAliveSec,
    String? clientId,
    String? statusTopic,
    String? offlinePayload,
  }) =>
      MqttBroker(
        tls: tls ?? this.tls,
        username: username ?? this.username,
        password: password ?? this.password,
        keepAliveSec: keepAliveSec ?? this.keepAliveSec,
        clientId: clientId ?? this.clientId,
        statusTopic: statusTopic ?? this.statusTopic,
        offlinePayload: offlinePayload ?? this.offlinePayload,
      );

  /// Só o que difere do padrão: o arquivo fica curto e legível.
  Map<String, dynamic> toJson() => {
        if (tls) 'tls': true,
        if (username.isNotEmpty) 'username': username,
        if (password.isNotEmpty) 'password': password,
        if (keepAliveSec != 10) 'keepAliveSec': keepAliveSec,
        if (clientId.isNotEmpty) 'clientId': clientId,
        if (statusTopic.isNotEmpty) 'statusTopic': statusTopic,
        if (offlinePayload != 'offline') 'offlinePayload': offlinePayload,
      };

  factory MqttBroker.fromJson(Map<String, dynamic> j) => MqttBroker(
        tls: (j['tls'] as bool?) ?? false,
        username: (j['username'] as String?) ?? '',
        password: (j['password'] as String?) ?? '',
        keepAliveSec: ((j['keepAliveSec'] as int?) ?? 10).clamp(0, 65535),
        clientId: (j['clientId'] as String?) ?? '',
        statusTopic: (j['statusTopic'] as String?) ?? '',
        offlinePayload: (j['offlinePayload'] as String?) ?? 'offline',
      );

  @override
  bool operator ==(Object other) =>
      other is MqttBroker &&
      other.tls == tls &&
      other.username == username &&
      other.password == password &&
      other.keepAliveSec == keepAliveSec &&
      other.clientId == clientId &&
      other.statusTopic == statusTopic &&
      other.offlinePayload == offlinePayload;

  @override
  int get hashCode => Object.hash(tls, username, password, keepAliveSec, clientId, statusTopic, offlinePayload);
}

/// Onde mora uma variável MQTT: o "endereço" dela.
@immutable
class MqttAddress {
  const MqttAddress({
    required this.topic,
    this.jsonPath = '',
    this.commandTopic = '',
    this.qos = 0,
    this.retain = false,
    this.validitySec = 0,
    this.boolFormat = MqttBoolFormat.oneZero,
    this.commandJson = false,
  });

  /// Tópico de estado — o que o equipamento publica. Aceita curingas.
  final String topic;

  /// Campo dentro de uma mensagem JSON ("sensores.temp", "valores[2]").
  /// Vazio = a mensagem inteira é o valor.
  final String jsonPath;

  /// Onde gravar. Vazio = no próprio tópico de estado (quando não tem
  /// curinga). Separado é o comum: `.../velocidade` e `.../velocidade/set`.
  final String commandTopic;

  /// 0 ou 1, na assinatura e na gravação. Com 1 a gravação espera o broker
  /// confirmar (PUBACK).
  final int qos;

  /// Gravar com retain: o broker guarda o comando e entrega a quem assinar
  /// depois. Desligado por padrão — comando guardado pode ser executado de
  /// novo quando o equipamento reconectar.
  final bool retain;

  /// Sem mensagem nova em tantos segundos = "sem comunicação". MQTT não tem
  /// qualidade por dado: sem isto, um sensor morto parece um valor parado.
  /// 0 = sem prazo (equipamento que só publica quando muda).
  final int validitySec;

  final MqttBoolFormat boolFormat;

  /// Gravar como JSON com o campo (`{"velocidade": 180}`) em vez do valor puro
  /// (`180`). Só faz sentido com [jsonPath].
  final bool commandJson;

  String get publishTopic => commandTopic.trim().isNotEmpty ? commandTopic.trim() : topic.trim();

  bool get canPublish => MqttTopic.isValidTopic(publishTopic);

  bool get isValid => MqttTopic.isValidFilter(topic.trim());

  /// "fabrica/cortadora/estado · sensores.temp".
  String get label => jsonPath.isEmpty ? topic : '$topic · $jsonPath';

  MqttAddress copyWith({
    String? topic,
    String? jsonPath,
    String? commandTopic,
    int? qos,
    bool? retain,
    int? validitySec,
    MqttBoolFormat? boolFormat,
    bool? commandJson,
  }) =>
      MqttAddress(
        topic: topic ?? this.topic,
        jsonPath: jsonPath ?? this.jsonPath,
        commandTopic: commandTopic ?? this.commandTopic,
        qos: qos ?? this.qos,
        retain: retain ?? this.retain,
        validitySec: validitySec ?? this.validitySec,
        boolFormat: boolFormat ?? this.boolFormat,
        commandJson: commandJson ?? this.commandJson,
      );

  Map<String, dynamic> toJson() => {
        'topic': topic,
        if (jsonPath.isNotEmpty) 'jsonPath': jsonPath,
        if (commandTopic.isNotEmpty) 'commandTopic': commandTopic,
        if (qos != 0) 'qos': qos,
        if (retain) 'retain': true,
        if (validitySec != 0) 'validitySec': validitySec,
        if (boolFormat != MqttBoolFormat.oneZero) 'boolFormat': boolFormat.name,
        if (commandJson) 'commandJson': true,
      };

  factory MqttAddress.fromJson(Map<String, dynamic> j) => MqttAddress(
        topic: (j['topic'] as String?) ?? '',
        jsonPath: (j['jsonPath'] as String?) ?? '',
        commandTopic: (j['commandTopic'] as String?) ?? '',
        qos: ((j['qos'] as int?) ?? 0).clamp(0, 1),
        retain: (j['retain'] as bool?) ?? false,
        validitySec: ((j['validitySec'] as int?) ?? 0).clamp(0, 86400),
        boolFormat: MqttBoolFormat.fromName(j['boolFormat'] as String?),
        commandJson: (j['commandJson'] as bool?) ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is MqttAddress &&
      other.topic == topic &&
      other.jsonPath == jsonPath &&
      other.commandTopic == commandTopic &&
      other.qos == qos &&
      other.retain == retain &&
      other.validitySec == validitySec &&
      other.boolFormat == boolFormat &&
      other.commandJson == commandJson;

  @override
  int get hashCode => Object.hash(topic, jsonPath, commandTopic, qos, retain, validitySec, boolFormat, commandJson);
}
