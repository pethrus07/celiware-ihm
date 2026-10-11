import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/core/mqtt/mqtt_error.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/mqtt_config.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/runtime/drivers/mqtt_driver.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/runtime/mqtt_codec.dart';
import 'package:ihm/services/runtime/tag_codec.dart';
import 'package:ihm/services/runtime/tag_store.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../support/mqtt_test_broker.dart';

/// Equipamento MQTT pelo caminho de produção — fábrica padrão → MqttDriver →
/// sessão → TagStore — contra um broker de verdade, por socket.
void main() {
  late MqttTestBroker broker;
  late Device device;
  final runtimes = <HmiRuntime>[];

  /// Runtime descartado no fim do teste, passe o que passar.
  HmiRuntime runtime() {
    final rt = HmiRuntime();
    runtimes.add(rt);
    return rt;
  }

  setUp(() async {
    broker = MqttTestBroker();
    await broker.start();
    device = Device(id: 'cort', name: 'Cortadora', kind: DeviceKind.mqtt, host: '127.0.0.1', port: broker.port, timeoutMs: 1000, pollMs: 50);
  });

  tearDown(() async {
    for (final rt in runtimes) {
      await rt.dispose();
    }
    runtimes.clear();
    await broker.close();
  });

  /// Espera uma condição de verdade (rede real, não relógio simulado).
  Future<void> until(bool Function() ok, {int ms = 3000, String? what}) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('não aconteceu em $ms ms${what == null ? '' : ': $what'}');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('caminho de produção: testar conexão, ler pela assinatura e gravar', () async {
    const freq = Tag(id: 'f', deviceId: 'cort', name: 'Frequência', writable: true,
        mqtt: MqttAddress(topic: 'inversor/frequencia', commandTopic: 'inversor/frequencia/set', qos: 1));
    broker.publish('inversor/frequencia', '4500', retain: true);

    final rt = runtime();
    expect((await rt.probe(device)).ok, isTrue);
    expect((await rt.probe(device, tag: freq)).value, 4500);

    await rt.apply(Project(devices: [device], tags: const [freq]));
    final sub = rt.subscribe(const ['f']);
    await until(() => rt.watch('f').value.isGood);
    expect(rt.watch('f').value.value, 4500);

    await rt.write('f', 6000);
    expect(broker.received.last.topic, 'inversor/frequencia/set');
    expect(broker.received.last.payload, '6000');
    // A tela só muda quando o equipamento confirma o estado novo.
    expect(rt.watch('f').value.value, 4500);
    broker.publish('inversor/frequencia', '6000', retain: true);
    await until(() => rt.watch('f').value.value == 6000);

    // Sair da tela solta o broker.
    sub.cancel();
    await until(() => broker.clientIds.isEmpty, what: 'desconectar ao sair da tela');
  });

  test('"lendo agora" sem retain espera em tom neutro; fechar o cadastro solta o broker', () async {
    const temp = Tag(id: 'temp', deviceId: 'cort', name: 'Temperatura', mqtt: MqttAddress(topic: 'cortadora/temperatura'));
    final rt = runtime();
    await rt.apply(Project(devices: [device], tags: const [temp]));
    await expectLater(rt.readNow(temp), throwsA(isA<MqttNoMessageYet>()));
    broker.publish('cortadora/temperatura', '70');
    // A assinatura avulsa continua viva entre as perguntas do formulário.
    expect(await rt.readNow(temp), 70);
    expect(broker.clientIds, hasLength(1));

    rt.releaseIdle();
    await until(() => broker.clientIds.isEmpty, what: 'soltar a conexão aberta só para o "lendo agora"');
  });

  test('número, texto, liga/desliga e JSON com caminho chegam pela assinatura', () async {
    final tags = [
      const Tag(id: 'temp', deviceId: 'cort', name: 'Temperatura', dataType: TagDataType.float32, mqtt: MqttAddress(topic: 'cortadora/temperatura')),
      const Tag(id: 'pressao', deviceId: 'cort', name: 'Pressão', scale: 0.1, mqtt: MqttAddress(topic: 'cortadora/pressao')),
      const Tag(id: 'receita', deviceId: 'cort', name: 'Receita', dataType: TagDataType.string, mqtt: MqttAddress(topic: 'cortadora/receita')),
      const Tag(id: 'porta', deviceId: 'cort', name: 'Porta', dataType: TagDataType.bool, mqtt: MqttAddress(topic: 'cortadora/porta')),
      const Tag(id: 'vel', deviceId: 'cort', name: 'Velocidade', mqtt: MqttAddress(topic: 'cortadora/estado', jsonPath: 'sensores.velocidade')),
      const Tag(id: 'faca', deviceId: 'cort', name: 'Faca', dataType: TagDataType.bool, mqtt: MqttAddress(topic: 'cortadora/estado', jsonPath: 'sensores.faca')),
      const Tag(id: 'linha', deviceId: 'cort', name: 'Linha', mqtt: MqttAddress(topic: 'fabrica/+/linha')),
    ];
    final rt = runtime();
    await rt.apply(Project(devices: [device], tags: tags));
    final sub = rt.subscribe(tags.map((t) => t.id));
    await until(() => broker.subscriptions.containsAll({'cortadora/temperatura', 'cortadora/estado', 'fabrica/+/linha'}));
    // Duas variáveis no mesmo tópico: uma assinatura só.
    expect(broker.subscriptions.length, 6);

    broker.publish('cortadora/temperatura', '72.5');
    broker.publish('cortadora/pressao', '752');
    broker.publish('cortadora/receita', 'Rótulo 330 ml');
    broker.publish('cortadora/porta', 'ON');
    broker.publish('cortadora/estado', '{"sensores": {"velocidade": 150, "faca": true}}');
    broker.publish('fabrica/sala2/linha', '3');
    await until(() => tags.every((t) => rt.watch(t.id).value.isGood));

    expect(rt.watch('temp').value.value, 72.5);
    expect(rt.watch('pressao').value.value, closeTo(75.2, 1e-9));
    expect(rt.watch('receita').value.value, 'Rótulo 330 ml');
    expect(rt.watch('porta').value.value, isTrue);
    expect(rt.watch('vel').value.value, 150);
    expect(rt.watch('faca').value.value, isTrue);
    expect(rt.watch('linha').value.value, 3);

    // Campo que não veio é problema da variável, não da conexão.
    broker.publish('cortadora/estado', '{"sensores": {"velocidade": 160}}');
    await until(() => rt.watch('faca').value.quality == TagQuality.configError);
    expect(rt.watch('faca').value.message, contains('sensores.faca'));
    expect(rt.watch('vel').value.value, 160);
    expect(rt.health('cort')!.value.online, isTrue);
    expect(rt.health('cort')!.value.lastScanMs, isNull, reason: 'varredura de assinatura não mede a rede');
    sub.cancel();
  });

  test('retain entrega o último valor na hora da assinatura', () async {
    broker.publish('cortadora/meta', '1200', retain: true);
    const meta = Tag(id: 'meta', deviceId: 'cort', name: 'Meta', mqtt: MqttAddress(topic: 'cortadora/meta'));
    final rt = runtime();
    await rt.apply(Project(devices: [device], tags: const [meta]));
    final sw = Stopwatch()..start();
    final sub = rt.subscribe(const ['meta']);
    await until(() => rt.watch('meta').value.isGood, ms: 1500);
    expect(rt.watch('meta').value.value, 1200);
    expect(sw.elapsedMilliseconds, lessThan(1500), reason: 'ninguém publicou: veio do retain');
    sub.cancel();
  });

  test('gravar publica no tópico de comando, no formato da variável e sem retain', () async {
    final tags = [
      const Tag(id: 'vel', deviceId: 'cort', name: 'Velocidade', writable: true,
          mqtt: MqttAddress(topic: 'cortadora/velocidade', commandTopic: 'cortadora/velocidade/set', qos: 1)),
      const Tag(id: 'liga', deviceId: 'cort', name: 'Liga', dataType: TagDataType.bool, writable: true,
          mqtt: MqttAddress(topic: 'cortadora/liga', commandTopic: 'cortadora/liga/set', boolFormat: MqttBoolFormat.onOff)),
      const Tag(id: 'sp', deviceId: 'cort', name: 'Setpoint', scale: 0.1, writable: true, mqtt: MqttAddress(topic: 'cortadora/setpoint')),
      const Tag(id: 'z2m', deviceId: 'cort', name: 'Velocidade JSON', writable: true,
          mqtt: MqttAddress(topic: 'z2m/cortadora', jsonPath: 'velocidade', commandTopic: 'z2m/cortadora/set', commandJson: true)),
      const Tag(id: 'curinga', deviceId: 'cort', name: 'Curinga', writable: true, mqtt: MqttAddress(topic: 'cortadora/+/x')),
    ];
    final rt = runtime();
    await rt.apply(Project(devices: [device], tags: tags));

    await rt.write('vel', 180); // QoS 1: volta só depois do PUBACK
    expect(broker.received.last.toString(), 'cortadora/velocidade/set = 180 (QoS 1)');

    await rt.write('liga', true);
    await until(() => broker.received.length == 2);
    expect(broker.received.last.toString(), 'cortadora/liga/set = ON (QoS 0)');

    await rt.write('sp', 75.2); // sem tópico de comando: grava no próprio tópico
    await until(() => broker.received.length == 3);
    expect(broker.received.last.toString(), 'cortadora/setpoint = 752 (QoS 0)');

    await rt.write('z2m', 90);
    await until(() => broker.received.length == 4);
    expect(broker.received.last.payload, '{"velocidade":90}');
    expect(broker.received.every((m) => !m.retain), isTrue);

    await expectLater(rt.write('curinga', 1), throwsA(isA<TagValueError>()));
    await expectLater(rt.write('sp', 75.25), throwsA(isA<TagValueError>()));
  });

  test('sem mensagem dentro da validade vira sem comunicação, e volta com a próxima', () async {
    const temp = Tag(id: 'temp', deviceId: 'cort', name: 'Temperatura', mqtt: MqttAddress(topic: 'cortadora/temperatura', validitySec: 1));
    final rt = runtime();
    await rt.apply(Project(devices: [device], tags: const [temp]));
    final sub = rt.subscribe(const ['temp']);
    await until(() => broker.subscriptions.contains('cortadora/temperatura'));
    broker.publish('cortadora/temperatura', '70');
    await until(() => rt.watch('temp').value.isGood);

    await until(() => rt.watch('temp').value.quality == TagQuality.commLost, ms: 2500);
    final r = rt.watch('temp').value;
    expect(r.value, 70, reason: 'último valor, esmaecido — nunca um zero falso');
    expect(r.message, contains('sem mensagem'));
    expect(rt.health('cort')!.value.online, isTrue, reason: 'o broker está bem; quem calou foi o sensor');

    broker.publish('cortadora/temperatura', '71');
    await until(() => rt.watch('temp').value.isGood);
    expect(rt.watch('temp').value.value, 71);
    sub.cancel();
  });

  test('broker que cai vira sem comunicação e a sessão reconecta sozinha', () async {
    const temp = Tag(id: 'temp', deviceId: 'cort', name: 'Temperatura', mqtt: MqttAddress(topic: 'cortadora/temperatura'));
    broker.publish('cortadora/temperatura', '70', retain: true);
    final rt = runtime();
    await rt.apply(Project(devices: [device], tags: const [temp]));
    final sub = rt.subscribe(const ['temp']);
    await until(() => rt.watch('temp').value.isGood);

    final port = broker.port;
    await broker.stop();
    await until(() => rt.watch('temp').value.quality == TagQuality.commLost, what: 'queda percebida');
    expect(rt.watch('temp').value.value, 70);
    expect(rt.health('cort')!.value.online, isFalse);

    // Broker de volta, com o valor que mudou enquanto estava fora.
    await broker.start(port: port);
    broker.publish('cortadora/temperatura', '72', retain: true);
    await until(() => rt.watch('temp').value.isGood, ms: 8000, what: 'reconexão');
    expect(rt.watch('temp').value.value, 72);
    expect(rt.health('cort')!.value.online, isTrue);
    sub.cancel();
  });

  test('testamento (LWT) do equipamento vira sem comunicação; gravar recusa', () async {
    final dev = device.copyWith(mqtt: const MqttBroker(statusTopic: 'cortadora/status'));
    // O equipamento: outro cliente MQTT, que deixa o testamento ao conectar.
    final maquina = MqttServerClient.withPort('127.0.0.1', 'cortadora', broker.port)..logging(on: false);
    maquina.setProtocolV311();
    maquina.connectionMessage = MqttConnectMessage()
        .withClientIdentifier('cortadora')
        .withWillTopic('cortadora/status')
        .withWillMessage('offline')
        .withWillRetain()
        .withWillQos(MqttQos.atLeastOnce)
        .startClean();
    await maquina.connect();
    MqttClientPayloadBuilder texto(String s) => MqttClientPayloadBuilder()..addUTF8String(s);
    maquina.publishMessage('cortadora/status', MqttQos.atLeastOnce, texto('online').payload!, retain: true);
    maquina.publishMessage('cortadora/temperatura', MqttQos.atLeastOnce, texto('70').payload!, retain: true);
    await until(() => broker.retained.length == 2);

    const temp = Tag(id: 'temp', deviceId: 'cort', name: 'Temperatura', mqtt: MqttAddress(topic: 'cortadora/temperatura'));
    const sp = Tag(id: 'sp', deviceId: 'cort', name: 'Setpoint', writable: true, mqtt: MqttAddress(topic: 'cortadora/sp'));
    final rt = runtime();
    await rt.apply(Project(devices: [dev], tags: const [temp, sp]));
    final sub = rt.subscribe(const ['temp']);
    await until(() => rt.watch('temp').value.isGood);

    // A máquina sumiu da rede: o broker publica o testamento dela.
    broker.drop('cortadora');
    await until(() => rt.watch('temp').value.quality == TagQuality.commLost, what: 'testamento');
    expect(rt.watch('temp').value.value, 70);
    expect(rt.watch('temp').value.message, MqttCommError.deviceOffline);
    expect(rt.health('cort')!.value.message, MqttCommError.deviceOffline);
    await expectLater(rt.write('sp', 10), throwsA(isA<MqttCommError>()));

    // Voltou e publicou o estado: a tela volta na hora (sem esperar a espera
    // crescente da sessão).
    broker.publish('cortadora/status', 'online', retain: true);
    broker.publish('cortadora/temperatura', '71', retain: true);
    await until(() => rt.watch('temp').value.isGood, ms: 1500);
    expect(rt.watch('temp').value.value, 71);
    expect(rt.health('cort')!.value.online, isTrue);
    sub.cancel();
  });

  test('reconciliação: troca de tópico tira a assinatura velha; keep-alive pinga', () async {
    final dev = device.copyWith(mqtt: const MqttBroker(keepAliveSec: 1));
    const a = Tag(id: 't', deviceId: 'cort', name: 'T', mqtt: MqttAddress(topic: 'linha/a'));
    final rt = runtime();
    await rt.apply(Project(devices: [dev], tags: const [a]));
    final sub = rt.subscribe(const ['t']);
    await until(() => broker.subscriptions.length == 1 && broker.subscriptions.contains('linha/a'));

    await rt.apply(Project(devices: [dev], tags: [a.copyWith(mqtt: const MqttAddress(topic: 'linha/b'))]));
    await until(() => broker.subscriptions.length == 1 && broker.subscriptions.contains('linha/b'), what: 'trocar a assinatura');
    expect(broker.connects, 1, reason: 'trocar tópico não reconecta');

    await until(() => broker.pings > 0, ms: 2500, what: 'PINGREQ do keep-alive');
    expect(rt.health('cort')!.value.online, isTrue);
    sub.cancel();
  });

  test('testar conexão: porta sem broker = recusou; senha errada = recusou usuário/senha', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closed = probe.port;
    await probe.close();
    final rt = runtime();
    // 5 s: o Windows insiste ~2 s antes de dizer "recusado" no próprio PC.
    final r1 = await rt.probe(device.copyWith(port: closed, timeoutMs: 5000));
    expect(r1.ok, isFalse);
    expect(r1.refused, isTrue);
    expect(r1.message, 'o broker recusou a conexão nesta porta');

    final seguro = MqttTestBroker(username: 'ihm', password: 'certa');
    await seguro.start();
    final d = device.copyWith(port: seguro.port, mqtt: const MqttBroker(username: 'ihm', password: 'errada'));
    final r2 = await rt.probe(d);
    expect(r2.ok, isFalse);
    expect(r2.refused, isTrue, reason: 'achou o broker: não é para conferir Wi-Fi e IP');
    expect(r2.message, MqttCommError.badCredentials);
    expect((await rt.probe(d.copyWith(mqtt: const MqttBroker(username: 'ihm', password: 'certa')))).ok, isTrue);
    await seguro.close();
  });

  test('ouvir o broker lista tópicos e campos (sem as estatísticas do broker)', () async {
    broker.publish('cortadora/estado', '{"temp": 72.5, "porta": true, "producao": [10, 12, 9]}', retain: true);
    broker.publish('cortadora/receita', 'Rótulo 330 ml', retain: true);
    broker.publish(r'$SYS/broker/uptime', '100', retain: true);
    final ao = <String>[];
    final heard = await MqttDriver.listen(device, duration: const Duration(milliseconds: 600), onHeard: (h) => ao.add(h.topic));
    expect(heard.map((h) => h.topic), unorderedEquals(['cortadora/estado', 'cortadora/receita']));
    expect(ao, isNotEmpty, reason: 'a lista cresce na tela enquanto ouve');
    final campos = MqttCodec.fields(heard.firstWhere((h) => h.topic == 'cortadora/estado').payload);
    expect(campos.map((c) => c.$1), ['temp', 'porta', 'producao']);
    expect(MqttCodec.guessType(campos[0].$2), TagDataType.float32);
    expect(MqttCodec.guessType(campos[1].$2), TagDataType.bool);
    await until(() => broker.clientIds.isEmpty, what: 'conexão própria encerrada');
  });

  test('variável Modbus num equipamento MQTT (e vice-versa) vira erro de configuração', () async {
    const modbus = Tag(id: 'hr', deviceId: 'cort', name: 'HR 4', address: 4);
    final rt = runtime();
    await rt.apply(Project(devices: [device], tags: const [modbus]));
    final sub = rt.subscribe(const ['hr']);
    await until(() => rt.watch('hr').value.quality == TagQuality.configError);
    expect(rt.watch('hr').value.message, 'variável sem tópico MQTT');
    sub.cancel();

    const demo = Device(id: 'dm', name: 'Demo', kind: DeviceKind.demo);
    const sobra = Tag(id: 'x', deviceId: 'dm', name: 'Sobra', mqtt: MqttAddress(topic: 'a/b'));
    await rt.apply(const Project(devices: [demo], tags: [sobra]));
    final sub2 = rt.subscribe(const ['x']);
    await until(() => rt.watch('x').value.quality == TagQuality.configError);
    expect(rt.watch('x').value.message, contains('MQTT'));
    sub2.cancel();
  });

  test('arquivo do projeto: ida e volta, e Modbus continua sem nada de MQTT', () {
    const dev = Device(id: 'm', name: 'Sensor', kind: DeviceKind.mqtt, host: '10.0.0.5', port: 8883,
        mqtt: MqttBroker(tls: true, username: 'ihm', password: 's3nha', keepAliveSec: 15, statusTopic: 'sensor/status', clientId: 'painel-1'));
    const t = Tag(id: 't', deviceId: 'm', name: 'Temp', dataType: TagDataType.float32, writable: true,
        mqtt: MqttAddress(topic: 'sensor/estado', jsonPath: 'temp', commandTopic: 'sensor/set', qos: 1, retain: true, validitySec: 30,
            boolFormat: MqttBoolFormat.trueFalse, commandJson: true));
    final p = ProjectRepository.decode(ProjectRepository.encode(const Project(devices: [dev], tags: [t])));
    final d2 = p.devices.single, t2 = p.tags.single;
    expect(d2.kind, DeviceKind.mqtt);
    expect(d2.mqtt, dev.mqtt);
    expect(d2.sameLinkAs(dev), isTrue);
    expect(t2.mqtt, t.mqtt);
    expect(t2.addressLabel, 'sensor/estado · temp');
    expect(dev.addressLabel, '10.0.0.5:8883 · MQTT · TLS');
    expect(dev.sameLinkAs(dev.copyWith(mqtt: dev.mqtt.copyWith(password: 'outra'))), isFalse, reason: 'senha nova reconecta');

    // Projeto Modbus fica byte a byte como antes.
    const mb = Device(id: 'b', name: 'B', host: '10.0.0.6');
    const mt = Tag(id: 'x', deviceId: 'b', name: 'X');
    expect(mb.toJson().containsKey('mqtt'), isFalse);
    expect(mt.toJson().containsKey('mqtt'), isFalse);
    expect(Device.fromJson(mb.toJson()).mqtt, const MqttBroker());

    // Campos Modbus de variável MQTT voltam ao padrão: nenhuma regra de área
    // (entrada discreta = só leitura) vale sem querer.
    final odd = Tag.fromJson({...t.toJson(), 'area': 'discreteInput', 'address': 40});
    expect(odd.area, ModbusArea.holdingRegister);
    expect(odd.address, 0);
    expect(odd.canWrite, isTrue);
    // Curinga sem tópico de comando: não há onde gravar.
    const curinga = Tag(id: 'w', deviceId: 'm', name: 'W', writable: true, mqtt: MqttAddress(topic: 'sensor/+/temp'));
    expect(curinga.canWrite, isFalse);
  });
}
