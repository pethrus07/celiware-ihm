import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/core/opcua/opcua_error.dart';
import 'package:ihm/core/opcua/opcua_status.dart';
import 'package:ihm/core/opcua/opcua_types.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/opcua_config.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/runtime/drivers/opcua_driver.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/runtime/opcua_tag_codec.dart';
import 'package:ihm/services/runtime/tag_codec.dart';
import 'package:ihm/services/runtime/tag_store.dart';
import 'package:ihm/services/storage/project_repository.dart';

import '../support/opcua_test_server.dart';

Tag ua(String id, String nodeId, {TagDataType type = TagDataType.uint16, bool writable = false, double scale = 1, int length = 1}) =>
    Tag(id: id, deviceId: 'srv', name: id, dataType: type, writable: writable, scale: scale, length: length, opcua: OpcUaTagAddress(nodeId));

/// Servidor OPC UA pelo caminho de produção — fábrica padrão → OpcUaDriver →
/// sessão → TagStore — contra o `OpcUaTestServer`, por socket de verdade.
void main() {
  late OpcUaTestServer server;
  late Device device;
  final runtimes = <HmiRuntime>[];

  HmiRuntime runtime() {
    final rt = HmiRuntime();
    runtimes.add(rt);
    return rt;
  }

  void machine(OpcUaTestServer s) {
    s.add(TestUaNode('ns=2;s=Maquina', 'Maquina', isFolder: true));
    s.add(TestUaNode('ns=2;s=Maquina.Temperatura', 'Temperatura', type: 11, value: 72.5), parent: 'ns=2;s=Maquina');
    s.add(TestUaNode('ns=2;s=Maquina.Velocidade', 'Velocidade', type: 5, value: 1500, writable: true), parent: 'ns=2;s=Maquina');
    s.add(TestUaNode('ns=2;s=Maquina.Ligada', 'Ligada', type: 1, value: true, writable: true), parent: 'ns=2;s=Maquina');
    s.add(TestUaNode('ns=2;s=Maquina.Pecas', 'Pecas', type: 6, value: -12), parent: 'ns=2;s=Maquina');
    s.add(TestUaNode('ns=2;s=Maquina.Lote', 'Lote', type: 12, value: 'Lote 42'), parent: 'ns=2;s=Maquina');
    s.add(TestUaNode('ns=2;s=Maquina.Producao', 'Producao', type: 4, value: [10, 20, 30], isArray: true), parent: 'ns=2;s=Maquina');
    s.add(TestUaNode('ns=2;i=1001', 'Ajuste', type: 10, value: 3.25, writable: true), parent: 'ns=2;s=Maquina');
    s.add(TestUaNode('ns=2;s=Maquina.Pressao', 'Pressao', type: 5, value: 752, writable: true), parent: 'ns=2;s=Maquina');
  }

  setUp(() async {
    server = OpcUaTestServer();
    machine(server);
    await server.start();
    device = Device(id: 'srv', name: 'Servidor', kind: DeviceKind.opcua, host: '127.0.0.1', port: server.port, timeoutMs: 1000, pollMs: 50, opcua: OpcUaConfig(path: server.path));
  });

  tearDown(() async {
    for (final rt in runtimes) {
      await rt.dispose();
    }
    runtimes.clear();
    await server.stop();
  });

  Future<void> until(bool Function() ok, {int ms = 3000, String? what}) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('não aconteceu em $ms ms${what == null ? '' : ': $what'}');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('caminho de produção: testar, ler num pedido só, gravar no tipo do nó, escala e faixa', () async {
    final tags = [
      ua('temp', 'ns=2;s=Maquina.Temperatura', type: TagDataType.float32),
      ua('vel', 'ns=2;s=Maquina.Velocidade', writable: true),
      ua('liga', 'ns=2;s=Maquina.Ligada', type: TagDataType.bool, writable: true),
      ua('pecas', 'ns=2;s=Maquina.Pecas'),
      ua('lote', 'ns=2;s=Maquina.Lote', type: TagDataType.string),
      ua('prod', 'ns=2;s=Maquina.Producao', length: 3),
      ua('ajuste', 'ns=2;i=1001', type: TagDataType.float32, writable: true),
      ua('pressao', 'ns=2;s=Maquina.Pressao', scale: 0.1, writable: true),
      ua('mesmo-no', 'ns=2;s=Maquina.Temperatura', type: TagDataType.float32),
    ];
    final rt = runtime();
    final probe = await rt.probe(device);
    expect(probe.ok, isTrue, reason: probe.message);
    expect((await rt.probe(device, tag: tags[1])).value, 1500);

    await rt.apply(Project(devices: [device], tags: tags));
    server.readNodeCounts.clear();
    final sub = rt.subscribe(tags.map((t) => t.id));
    await until(() => tags.every((t) => rt.watch(t.id).value.isGood), what: 'todas boas');
    expect(rt.watch('temp').value.value, 72.5);
    expect(rt.watch('vel').value.value, 1500);
    expect(rt.watch('liga').value.value, isTrue);
    expect(rt.watch('pecas').value.value, -12);
    expect(rt.watch('lote').value.value, 'Lote 42');
    expect(rt.watch('prod').value.value, [10, 20, 30]);
    expect(rt.watch('ajuste').value.value, 3.25);
    expect(rt.watch('pressao').value.value, closeTo(75.2, 1e-9));
    expect(rt.watch('mesmo-no').value.value, 72.5);
    expect(server.readNodeCounts.last, 8, reason: 'um Read com os 8 nós distintos');
    expect(rt.health('srv')!.value.online, isTrue);
    expect(rt.health('srv')!.value.blocks, 1, reason: 'uma ida e volta por varredura');

    // Gravar no tipo que o servidor tem: UInt16, Boolean, Float.
    await rt.write('vel', 1800);
    expect(server.node('ns=2;s=Maquina.Velocidade').value, 1800);
    await until(() => rt.watch('vel').value.value == 1800);
    await rt.write('liga', false);
    expect(server.node('ns=2;s=Maquina.Ligada').value, isFalse);
    await rt.write('ajuste', 4.5);
    expect(server.node('ns=2;i=1001').value, 4.5);
    await rt.write('pressao', 80.1);
    expect(server.node('ns=2;s=Maquina.Pressao').value, 801, reason: 'a escala é desfeita antes de gravar');
    expect(server.writtenTypes, ['5', '1', '10', '5'], reason: 'UInt16, Boolean, Float, UInt16');

    // Valor que não cabe no tipo do nó: recusado antes da rede, na unidade da tela.
    await expectLater(rt.write('vel', 70000), throwsA(isA<TagValueError>().having((e) => e.message, 'm', '"vel" aceita de 0 a 65535')));
    await expectLater(rt.write('pressao', 75.25), throwsA(isA<TagValueError>().having((e) => e.message, 'm', '"pressao" aceita passos de 0,1')));
    await expectLater(rt.write('temp', 1), throwsA(isA<TagValueError>()), reason: 'variável só leitura no app');
    expect(server.writeRequests, 4);
    sub.cancel();
  });

  test('nó inexistente marca só a variável dele; corrigido, volta', () async {
    final tags = [ua('boa', 'ns=2;s=Maquina.Velocidade'), ua('errada', 'ns=2;s=Maquina.Velocdade')];
    final rt = runtime();
    await rt.apply(Project(devices: [device], tags: tags));
    final sub = rt.subscribe(tags.map((t) => t.id));
    await until(() => rt.watch('errada').value.quality == TagQuality.addressError);
    await until(() => rt.watch('boa').value.isGood);
    expect(rt.watch('errada').value.message, 'nó inexistente: ns=2;s=Maquina.Velocdade');
    expect(rt.health('srv')!.value.online, isTrue, reason: 'nó errado não é queda');

    await rt.apply(Project(devices: [device], tags: [tags.first, ua('errada', 'ns=2;s=Maquina.Pecas')]));
    await until(() => rt.watch('errada').value.isGood, what: 'NodeId corrigido');
    expect(rt.watch('errada').value.value, -12);
    sub.cancel();
  });

  test('servidor sem comunicação com o equipamento: só aquele nó fica sem comunicação, com o último valor', () async {
    final tags = [ua('vel', 'ns=2;s=Maquina.Velocidade'), ua('pecas', 'ns=2;s=Maquina.Pecas')];
    final rt = runtime();
    await rt.apply(Project(devices: [device], tags: tags));
    final sub = rt.subscribe(tags.map((t) => t.id));
    await until(() => rt.watch('vel').value.isGood && rt.watch('pecas').value.isGood);
    server.node('ns=2;s=Maquina.Velocidade').readStatus = UaStatus.badNoCommunication;
    await until(() => rt.watch('vel').value.quality == TagQuality.commLost);
    expect(rt.watch('vel').value.value, 1500, reason: 'último valor, esmaecido');
    expect(rt.watch('vel').value.message, 'o servidor está sem comunicação com o equipamento');
    expect(rt.watch('pecas').value.isGood, isTrue);
    server.node('ns=2;s=Maquina.Velocidade').readStatus = 0;
    await until(() => rt.watch('vel').value.isGood);
    sub.cancel();
  });

  test('usuário errado e servidor que exige segurança: o teste diz por quê; a varredura fica sem comunicação', () async {
    server.allowAnonymous = false;
    final rt = runtime();
    final anon = await rt.probe(device);
    expect(anon.ok, isFalse);
    expect(anon.message, OpcUaHint.needsUser);
    expect(anon.refused, isTrue, reason: 'achou o servidor: nada de conferir Wi-Fi');
    expect(anon.hint, isNull);

    final wrong = device.copyWith(opcua: OpcUaConfig(path: server.path, username: 'operador', password: 'errada'));
    final r = await rt.probe(wrong);
    expect(r.message, OpcUaHint.user);
    expect(r.refused, isTrue);
    expect((await rt.probe(device.copyWith(opcua: OpcUaConfig(path: server.path, username: 'operador', password: '1234')))).ok, isTrue);

    await rt.apply(Project(devices: [wrong], tags: [ua('vel', 'ns=2;s=Maquina.Velocidade')]));
    final sub = rt.subscribe(const ['vel']);
    await until(() => rt.watch('vel').value.quality == TagQuality.commLost);
    expect(rt.watch('vel').value.message, OpcUaHint.user);
    sub.cancel();

    server.onlySecureEndpoints = true;
    final sec = await rt.probe(device.copyWith(opcua: OpcUaConfig(path: server.path, username: 'operador', password: '1234')));
    expect(sec.message, OpcUaHint.security);
    expect(sec.refused, isTrue);
  });

  test('caminho errado e porta fechada: o teste fala do endpoint e da porta', () async {
    server.strictPath = true;
    final rt = runtime();
    final wrongPath = await rt.probe(device.copyWith(opcua: const OpcUaConfig(path: '/outro')));
    expect(wrongPath.message, OpcUaHint.endpoint);
    expect(wrongPath.refused, isTrue);

    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closed = probe.port;
    await probe.close();
    final r = await rt.probe(device.copyWith(port: closed));
    expect(r.refused, isTrue);
    expect(r.message, 'o servidor recusou a conexão nesta porta');
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('servidor que cai vira sem comunicação com o último valor, e a sessão reconecta sozinha', () async {
    final rt = runtime();
    await rt.apply(Project(devices: [device], tags: [ua('vel', 'ns=2;s=Maquina.Velocidade')]));
    final sub = rt.subscribe(const ['vel']);
    await until(() => rt.watch('vel').value.isGood);
    final port = server.port;
    await server.stop();
    await until(() => rt.watch('vel').value.quality == TagQuality.commLost, what: 'queda percebida');
    expect(rt.watch('vel').value.value, 1500);
    expect(rt.health('srv')!.value.online, isFalse);

    server = OpcUaTestServer();
    machine(server);
    server.node('ns=2;s=Maquina.Velocidade').value = 1600;
    await server.start(port: port);
    await until(() => rt.watch('vel').value.isGood, ms: 8000, what: 'reconexão');
    expect(rt.watch('vel').value.value, 1600);
    expect(rt.health('srv')!.value.online, isTrue);
    sub.cancel();
  });

  test('"lendo agora": lê o NodeId digitado e solta a sessão ao fechar o cadastro', () async {
    final rt = runtime();
    await rt.apply(Project(devices: [device]));
    expect(await rt.readNow(ua('novo', 'ns=2;i=1001', type: TagDataType.float32)), 3.25);
    await expectLater(rt.readNow(ua('novo', 'ns=2;s=Nada')), throwsA(isA<OpcUaNodeError>().having((e) => e.userMessage, 'm', 'nó inexistente: ns=2;s=Nada')));
    expect(server.clientCount, 1);
    rt.releaseIdle();
    await until(() => server.clientCount == 0, what: 'soltar a conexão aberta só para o "lendo agora"');
    expect(server.closedSessions, 1, reason: 'avisou o servidor (CloseSession)');
  });

  test('cadastro que não fecha vira erro de configuração; variável de outro protocolo também', () async {
    final tags = [
      ua('torto', 'ns=2;Temperatura'),
      ua('texto-num-numero', 'ns=2;s=Maquina.Lote'),
      ua('bool-em-texto', 'ns=2;s=Maquina.Lote', type: TagDataType.bool),
      ua('lista-sem-lista', 'ns=2;s=Maquina.Producao'),
      const Tag(id: 'modbus', deviceId: 'srv', name: 'HR 4', address: 4),
    ];
    final rt = runtime();
    await rt.apply(Project(devices: [device], tags: tags));
    final sub = rt.subscribe(tags.map((t) => t.id));
    await until(() => tags.every((t) => rt.watch(t.id).value.quality == TagQuality.configError));
    expect(rt.watch('torto').value.message, contains('falta o tipo do identificador'));
    expect(rt.watch('texto-num-numero').value.message, 'o nó é texto: escolha Texto (em Mais opções)');
    expect(rt.watch('bool-em-texto').value.message, 'o nó é texto: escolha Texto (em Mais opções)');
    expect(rt.watch('lista-sem-lista').value.message, 'o nó tem uma lista de 3 valores: em Mais opções, diga quantos ler');
    expect(rt.watch('modbus').value.message, 'variável sem NodeId do OPC UA');
    sub.cancel();

    // E o contrário: NodeId num equipamento Modbus não lê o HR 0.
    const demo = Device(id: 'dm', name: 'Demo', kind: DeviceKind.demo);
    final sobra = Tag(id: 'x', deviceId: 'dm', name: 'Sobra', opcua: const OpcUaTagAddress('ns=2;s=Temp'));
    await rt.apply(Project(devices: const [demo], tags: [sobra]));
    final sub2 = rt.subscribe(const ['x']);
    await until(() => rt.watch('x').value.quality == TagQuality.configError);
    expect(rt.watch('x').value.message, 'variável de OPC UA num equipamento Modbus');
    sub2.cancel();
  });

  test('navegar: Objects sem os nós do servidor, pasta, variáveis com valor e permissão', () async {
    server.add(TestUaNode('i=23470', 'Aliases')); // objeto do namespace 0, como no asyncua
    final browser = OpcUaBrowser(device);
    final top = await browser.children();
    expect(top.map((i) => i.name), ['Maquina'], reason: 'Server e Aliases (namespace 0) ficam de fora');
    expect(top.single.isVariable, isFalse);
    final kids = await browser.children(top.single.nodeId);
    final temp = kids.firstWhere((i) => i.name == 'Temperatura');
    expect(temp.isVariable, isTrue);
    expect(temp.value, 72.5);
    expect(temp.type, UaType.double);
    expect(temp.writable, isFalse);
    expect(temp.suggestedType, TagDataType.float32);
    expect(temp.decimals, 1);
    expect(kids.firstWhere((i) => i.name == 'Ajuste').decimals, 2);
    final vel = kids.firstWhere((i) => i.name == 'Velocidade');
    expect((vel.writable, vel.suggestedType), (true, TagDataType.uint16));
    final prod = kids.firstWhere((i) => i.name == 'Producao');
    expect((prod.count, prod.suggestedType), (3, TagDataType.uint16));
    expect(kids.firstWhere((i) => i.name == 'Ajuste').nodeId, 'ns=2;i=1001');
    await browser.dispose();
  });

  group('variável ⇄ OPC UA (funções puras)', () {
    test('leitura: qualquer número, escala, liga/desliga de número, texto com idioma', () {
      expect(OpcUaTagCodec.decode(ua('a', 'i=1', scale: 0.1), const UaVariant(UaType.int32, 752)), closeTo(75.2, 1e-9));
      expect(OpcUaTagCodec.decode(ua('b', 'i=1', type: TagDataType.bool), const UaVariant(UaType.byte, 1)), isTrue);
      expect(OpcUaTagCodec.decode(ua('c', 'i=1', type: TagDataType.string), const UaVariant(UaType.localizedText, LocalizedText('Pronta'))), 'Pronta');
      expect(OpcUaTagCodec.decode(ua('d', 'i=1', type: TagDataType.string), const UaVariant(UaType.double, 1.5)), '1,5');
      expect(() => OpcUaTagCodec.decode(ua('e', 'i=1'), const UaVariant(UaType.boolean, true)), throwsA(isA<TagValueError>().having((e) => e.message, 'm', 'o nó é liga/desliga: escolha Liga / desliga')));
      expect(() => OpcUaTagCodec.decode(ua('f', 'i=1'), UaVariant.empty), throwsA(isA<TagValueError>()));
      expect(() => OpcUaTagCodec.decode(ua('g', 'i=1', length: 4), const UaVariant(UaType.int16, [1, 2], isArray: true)), throwsA(isA<TagValueError>().having((e) => e.message, 'm', 'o nó tem 2 valores; a variável pede 4')));
    });

    test('gravação no tipo do servidor, com faixa e passo na unidade da tela', () {
      final t = ua('v', 'i=1', writable: true);
      expect(OpcUaTagCodec.encode(t, UaType.int16, -5).value, -5);
      expect(OpcUaTagCodec.encode(t, UaType.double, 2).value, 2.0);
      expect(OpcUaTagCodec.encode(t, UaType.boolean, 1).value, isTrue);
      expect(OpcUaTagCodec.encode(ua('b', 'i=1', type: TagDataType.bool, writable: true, scale: 0.1), UaType.byte, true).value, 1, reason: 'liga/desliga num nó numérico grava 1, sem escala');
      expect(() => OpcUaTagCodec.encode(t, UaType.byte, 256), throwsA(isA<TagValueError>().having((e) => e.message, 'm', '"v" aceita de 0 a 255')));
      expect(() => OpcUaTagCodec.encode(t, UaType.int32, 1.5), throwsA(isA<TagValueError>().having((e) => e.message, 'm', '"v" só aceita número inteiro')));
      expect(() => OpcUaTagCodec.encode(ua('s', 'i=1', scale: 0.5), UaType.int16, 20000), throwsA(isA<TagValueError>().having((e) => e.message, 'm', '"s" aceita de -16384,0 a 16383,5')));
      expect(() => OpcUaTagCodec.encode(t, UaType.string, 1), throwsA(isA<TagValueError>()));
    });

    test('tipo sugerido pelo tipo do nó: só os quatro do cadastro', () {
      expect(OpcUaTagCodec.suggestedType(UaType.boolean), TagDataType.bool);
      expect(OpcUaTagCodec.suggestedType(UaType.float), TagDataType.float32);
      expect(OpcUaTagCodec.suggestedType(UaType.int64), TagDataType.uint16);
      expect(OpcUaTagCodec.suggestedType(UaType.string), TagDataType.string);
      expect(OpcUaTagCodec.suggestedType(UaType.localizedText), TagDataType.string);
    });

    test('endereço colado inteiro e NodeId arrumado', () {
      final e = OpcUaConfig.parseEndpoint(' opc.tcp://192.168.0.10:4840/OPCUA/Sim ')!;
      expect((e.host, e.port, e.path), ('192.168.0.10', 4840, '/OPCUA/Sim'));
      expect(OpcUaConfig.parseEndpoint('opc.tcp://plc-01')!.port, 4840);
      expect(OpcUaConfig.parseEndpoint('192.168.0.10'), isNull);
      expect(OpcUaTagAddress.normalize(' NS=2; s=Temp '), 'ns=2;s=Temp');
      expect(OpcUaTagAddress.normalize('ns=0;i=85'), 'i=85');
      expect(OpcUaTagAddress.normalize('lixo '), 'lixo');
    });
  });

  test('arquivo do projeto: ida e volta, e projeto antigo fica byte a byte igual', () {
    const dev = Device(
        id: 'p', name: 'Linha', kind: DeviceKind.opcua, host: '10.0.0.7', port: 4840, opcua: OpcUaConfig(path: '/OPCUA/Sim', username: 'operador', password: '1234'));
    const t = Tag(id: 't', deviceId: 'p', name: 'Temperatura', dataType: TagDataType.float32, writable: true, opcua: OpcUaTagAddress('ns=2;s=Maquina.Temperatura'));
    final p = ProjectRepository.decode(ProjectRepository.encode(const Project(devices: [dev], tags: [t])));
    final d2 = p.devices.single, t2 = p.tags.single;
    expect(d2.kind, DeviceKind.opcua);
    expect(d2.opcua, dev.opcua);
    expect(d2.sameLinkAs(dev), isTrue);
    expect(dev.sameLinkAs(dev.copyWith(opcua: const OpcUaConfig(path: '/OPCUA/Sim', username: 'outro'))), isFalse, reason: 'outro usuário reconecta');
    expect(t2.opcua, t.opcua);
    expect(t2.canWrite, isTrue);
    expect(t2.addressLabel, 'ns=2;s=Maquina.Temperatura');
    expect(ua('l', 'ns=2;s=L', length: 8).addressLabel, 'ns=2;s=L · 8 valores');
    expect(dev.addressLabel, '10.0.0.7:4840/OPCUA/Sim · OPC UA · operador');
    expect(dev.kind.label, 'Servidor OPC UA');

    // Anônimo na raiz não grava nada além do tipo.
    const anon = Device(id: 'a', name: 'A', kind: DeviceKind.opcua, host: '10.0.0.8', port: 4840);
    expect(anon.toJson().containsKey('opcua'), isFalse);
    expect(Device.fromJson(anon.toJson()).opcua, const OpcUaConfig());
    expect(anon.addressLabel, '10.0.0.8:4840 · OPC UA');

    // Campos Modbus de variável OPC UA voltam ao padrão.
    final odd = Tag.fromJson({...ua('x', 'ns=2;s=A', writable: true).toJson(), 'area': 'discreteInput', 'address': 40});
    expect((odd.area, odd.address), (ModbusArea.holdingRegister, 0));
    expect(odd.canWrite, isTrue);

    // Projeto de antes do OPC UA: o arquivo regravado sai idêntico.
    const antigo = Project(name: 'Linha 1', devices: [
      Device(id: 'a', name: 'CLP', host: '192.168.0.10'),
      Device(id: 'b', name: 'Prensa', kind: DeviceKind.s7, host: '192.168.0.20', port: 102),
    ], tags: [
      Tag(id: 'x', deviceId: 'a', name: 'Velocidade', address: 4, writable: true, scale: 0.1),
    ]);
    final bytes = ProjectRepository.encode(antigo);
    expect(utf8.decode(bytes).contains('opcua'), isFalse);
    expect(ProjectRepository.encode(ProjectRepository.decode(bytes)), bytes);
  });
}
