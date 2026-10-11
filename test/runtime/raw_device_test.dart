import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/core/rawlink/fake_arduino_server.dart';
import 'package:ihm/core/rawlink/message_parser.dart';
import 'package:ihm/core/rawlink/message_profile.dart';
import 'package:ihm/core/rawlink/raw_link_pool.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/raw_config.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/runtime/drivers/raw_driver.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/runtime/raw_codec.dart';
import 'package:ihm/services/runtime/raw_preview.dart';
import 'package:ihm/services/runtime/tag_codec.dart';
import 'package:ihm/services/runtime/tag_store.dart';
import 'package:ihm/services/storage/project_repository.dart';

/// Equipamento cru (Arduino) pelo caminho de produção — fábrica padrão →
/// RawDriver → sessão → TagStore — contra o Arduino falso, por socket de
/// verdade (TCP e UDP).
void main() {
  final servers = <FakeArduinoServer>[];
  final runtimes = <HmiRuntime>[];

  /// Arduino falso parado no fim do teste, passe o que passar.
  Future<FakeArduinoServer> arduino({bool udp = false, Duration? streamEvery, Map<String, Object>? values, List<int> Function(Map<String, Object>)? encode}) async {
    final s = FakeArduinoServer(udp: udp, streamEvery: streamEvery, values: values, encode: encode ?? FakeArduinoServer.keyValueLine);
    await s.start();
    servers.add(s);
    return s;
  }

  HmiRuntime runtime() {
    final rt = HmiRuntime();
    runtimes.add(rt);
    return rt;
  }

  Device device(int port, {MessageProfile profile = RawTemplates.keyValueProfile, bool udp = false, int localPort = 0}) => Device(
        id: 'ard',
        name: 'Tanque',
        kind: DeviceKind.raw,
        host: '127.0.0.1',
        port: port,
        timeoutMs: 1000,
        pollMs: 50,
        raw: RawConfig(transport: udp ? RawTransport.udp : RawTransport.tcp, localPort: localPort, profile: profile),
      );

  const temp = Tag(id: 't', deviceId: 'ard', name: 'Temperatura', dataType: TagDataType.float32, raw: RawAddress(field: 'T'));
  const bomba = Tag(id: 'p', deviceId: 'ard', name: 'Bomba', dataType: TagDataType.bool, writable: true, raw: RawAddress(field: 'P'));

  tearDown(() async {
    for (final rt in runtimes) {
      await rt.dispose();
    }
    runtimes.clear();
    for (final s in servers) {
      await s.stop();
    }
    servers.clear();
    expect(RawLinkPool.openCount, 0, reason: 'nenhum socket ficou aberto');
  });

  /// Espera uma condição de verdade (rede real, não relógio simulado).
  Future<void> until(bool Function() ok, {int ms = 3000, String? what}) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('não aconteceu em $ms ms${what == null ? '' : ': $what'}');
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }
  }

  test('TCP streaming pelo caminho de produção: testar, ler na hora em que chega e gravar pelo comando', () async {
    final s = await arduino(streamEvery: const Duration(milliseconds: 40));
    final d = device(s.port);
    final rt = runtime();
    final probe = await rt.probe(d);
    expect(probe.ok, isTrue, reason: probe.message);
    expect((await rt.probe(d, tag: temp)).value, 25.3);

    await rt.apply(Project(devices: [d], tags: const [temp, bomba]));
    final sub = rt.subscribe(const ['t', 'p']);
    await until(() => rt.watch('t').value.isGood && rt.watch('p').value.isGood);
    expect(rt.watch('t').value.value, 25.3);
    expect(rt.watch('p').value.value, isTrue);
    expect(rt.health('ard')!.value.online, isTrue);
    expect(rt.health('ard')!.value.lastScanMs, isNull, reason: 'varredura de assinatura não mede a rede');

    s.values['T'] = 31.5;
    await until(() => rt.watch('t').value.value == 31.5);

    await rt.write('p', false);
    await until(() => s.received.contains('SET P=0'));
    // A tela muda quando o equipamento manda o estado novo (a confirmação).
    await until(() => rt.watch('p').value.value == false);
    expect(s.connections, 1);

    sub.cancel();
    await until(() => s.connections == 0, what: 'sair da tela solta a conexão');
  });

  test('polling: o app pergunta a cada pollMs do perfil e a resposta vira valor', () async {
    final s = await arduino(); // só responde quando perguntam
    final rt = runtime();
    final d = device(s.port, profile: RawTemplates.keyValueProfile.copyWith(mode: RawMode.polling, pollMs: 60));
    await rt.apply(Project(devices: [d], tags: const [temp]));
    final sub = rt.subscribe(const ['t']);
    await until(() => rt.watch('t').value.isGood);
    expect(rt.watch('t').value.value, 25.3);
    await until(() => s.received.where((l) => l == '?').length >= 3, what: 'perguntas repetidas');
    s.values['T'] = 40;
    await until(() => rt.watch('t').value.value == 40.0);
    sub.cancel();
  });

  test('gravar: escala desfeita, comando próprio da variável, valor que não cabe e falta de comando', () async {
    final s = await arduino(streamEvery: const Duration(milliseconds: 40));
    final rt = runtime();
    const setpoint = Tag(id: 'sp', deviceId: 'ard', name: 'Setpoint', scale: 0.1, writable: true, raw: RawAddress(field: 'S'));
    final propria = Tag(id: 'b', deviceId: 'ard', name: 'Bomba B', dataType: TagDataType.bool, writable: true,
        raw: const RawAddress(field: 'P').withCommand(const CommandTemplate.text('SET B={valor}\n')));
    const curto = Tag(id: 'c', deviceId: 'ard', name: 'Curto', writable: true, raw: RawAddress(field: 'P', command: CommandTemplate.binary('AA {valor:u8}')));
    await rt.apply(Project(devices: [device(s.port)], tags: [setpoint, propria, curto, temp]));
    final sub = rt.subscribe(const ['sp']);

    await rt.write('sp', 75.2);
    await until(() => s.received.contains('SET S=752'));
    await until(() => rt.watch('sp').value.value == 75.2, what: 'estado novo com S=752, já na escala');
    await rt.write('b', true);
    await until(() => s.received.contains('SET B=1'), what: 'o comando da variável vale no lugar do perfil');
    await expectLater(rt.write('c', 300), throwsA(isA<TagValueError>().having((e) => e.message, 'mensagem', contains('não cabe'))));
    await expectLater(rt.write('sp', 75.25), throwsA(isA<TagValueError>().having((e) => e.message, 'mensagem', contains('passos de 0,1'))));
    await expectLater(rt.write('t', 1), throwsA(isA<TagValueError>()), reason: 'só leitura');

    // Perfil sem comando e variável sem comando: não há o que mandar.
    final semComando = device(s.port, profile: const MessageProfile());
    await rt.apply(Project(devices: [semComando], tags: const [setpoint]));
    await expectLater(rt.write('sp', 10), throwsA(isA<TagValueError>().having((e) => e.message, 'mensagem', contains('falta o comando'))));
    sub.cancel();
  });

  test('checksum errado não vira valor; "Testar conexão" separa "não entendeu" de "nada chegou"', () async {
    // Estilo NMEA: T=25.3;P=1*hh, XOR em hexadecimal depois do "*".
    List<int> comXor(Map<String, Object> v) {
      final body = v.entries.map((e) => '${e.key}=${e.value}').join(';');
      var x = 0;
      for (final c in body.codeUnits) {
        x ^= c;
      }
      return utf8.encode('$body*${x.toRadixString(16).toUpperCase().padLeft(2, '0')}\n');
    }

    const nmea = MessageProfile(checksum: ChecksumSpec(kind: ChecksumKind.xor, encoding: ChecksumEncoding.hex, separator: '*'));
    final s = await arduino(streamEvery: const Duration(milliseconds: 40), encode: comXor);
    final rt = runtime();
    expect((await rt.probe(device(s.port, profile: nmea))).ok, isTrue);
    await rt.apply(Project(devices: [device(s.port, profile: nmea)], tags: const [temp]));
    final sub = rt.subscribe(const ['t']);
    await until(() => rt.watch('t').value.isGood);

    s.silent = true; // só os bytes do teste daqui em diante
    s.sendRaw(utf8.encode('T=99.9;P=1*00\n'));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(rt.watch('t').value.value, 25.3, reason: 'mensagem com checksum errado é descartada');
    expect(rt.watch('t').value.isGood, isTrue);
    sub.cancel();

    // O mesmo perfil num equipamento que manda sem checksum: chega, mas não confere.
    final semCs = await arduino(streamEvery: const Duration(milliseconds: 40));
    final r = await rt.probe(device(semCs.port, profile: nmea));
    expect(r.ok, isFalse);
    expect(r.message, '${RawProbeError.notUnderstood}: checksum errado');
    expect(r.refused, isTrue, reason: 'o equipamento foi achado: não é para conferir Wi-Fi e IP');

    // Conectou, mas o equipamento não fala sozinho (perfil em streaming).
    final calado = await arduino();
    final r2 = await rt.probe(device(calado.port, profile: const MessageProfile(staleAfterMs: 2000)));
    expect(r2.ok, isFalse);
    expect(r2.message, RawProbeError.silent(2));
  });

  test('equipamento mudo vira sem comunicação com o último valor; a próxima mensagem volta na hora', () async {
    final s = await arduino(streamEvery: const Duration(milliseconds: 40));
    final rt = runtime();
    await rt.apply(Project(devices: [device(s.port, profile: RawTemplates.keyValueProfile.copyWith(staleAfterMs: 300))], tags: const [temp]));
    final sub = rt.subscribe(const ['t']);
    await until(() => rt.watch('t').value.isGood);

    s.silent = true;
    await until(() => rt.watch('t').value.quality == TagQuality.commLost, what: 'validade do equipamento vencida');
    expect(rt.watch('t').value.value, 25.3, reason: 'último valor, esmaecido — nunca um zero falso');
    expect(rt.watch('t').value.message, 'sem mensagem do equipamento');
    expect(rt.health('ard')!.value.online, isFalse);

    s.silent = false;
    // Sem esperar a espera crescente da sessão (1, 2, 4 s): a mensagem acorda.
    await until(() => rt.watch('t').value.isGood && rt.health('ard')!.value.online, ms: 900);
    sub.cancel();
  });

  test('campo que parou de vir: só aquela variável fica sem comunicação', () async {
    final s = await arduino(streamEvery: const Duration(milliseconds: 40), values: {'T': 25.3, 'X': 5});
    final rt = runtime();
    const x = Tag(id: 'x', deviceId: 'ard', name: 'X', raw: RawAddress(field: 'X', validitySec: 1));
    await rt.apply(Project(devices: [device(s.port)], tags: const [temp, x]));
    final sub = rt.subscribe(const ['t', 'x']);
    await until(() => rt.watch('x').value.isGood && rt.watch('t').value.isGood);

    s.values.remove('X');
    await until(() => rt.watch('x').value.quality == TagQuality.commLost, ms: 2500);
    expect(rt.watch('x').value.message, 'o campo X não vem há mais de 1 s');
    expect(rt.watch('x').value.value, 5);
    expect(rt.watch('t').value.isGood, isTrue);
    expect(rt.health('ard')!.value.online, isTrue, reason: 'o equipamento continua falando');

    s.values['X'] = 6;
    await until(() => rt.watch('x').value.isGood && rt.watch('x').value.value == 6);
    sub.cancel();
  });

  test('queda e volta: sem comunicação e a sessão reconecta sozinha', () async {
    final s = await arduino(streamEvery: const Duration(milliseconds: 40));
    final rt = runtime();
    await rt.apply(Project(devices: [device(s.port)], tags: const [temp]));
    final sub = rt.subscribe(const ['t']);
    await until(() => rt.watch('t').value.isGood);

    final port = s.port;
    await s.stop();
    await until(() => rt.watch('t').value.quality == TagQuality.commLost, what: 'queda percebida');
    expect(rt.watch('t').value.value, 25.3);
    expect(rt.health('ard')!.value.online, isFalse);

    s.values['T'] = 27.0;
    await s.start(port: port);
    await until(() => rt.watch('t').value.isGood && rt.watch('t').value.value == 27.0, ms: 8000, what: 'reconexão');
    expect(rt.health('ard')!.value.online, isTrue);
    sub.cancel();
  });

  test('UDP: streaming para a porta deste celular; polling e comando sem fim de linha', () async {
    // A porta gravada no sketch: o equipamento manda para cá desde o início.
    final probe = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final local = probe.port;
    probe.close();
    final s = await arduino(udp: true, streamEvery: const Duration(milliseconds: 40));
    s.streamTo(InternetAddress.loopbackIPv4, local);
    final rt = runtime();
    await rt.apply(Project(devices: [device(s.port, udp: true, localPort: local)], tags: const [temp]));
    final sub = rt.subscribe(const ['t']);
    await until(() => rt.watch('t').value.isGood);
    expect(rt.watch('t').value.value, 25.3);
    sub.cancel();
    await until(() => RawLinkPool.openCount == 0);

    // ESP que responde a quem perguntou, um pacote por mensagem, sem "\n".
    final esp = await arduino(udp: true, encode: (v) => utf8.encode('T=${v['T']};P=${v['P']}'));
    final d = device(esp.port, udp: true, profile: RawTemplates.keyValueProfile.copyWith(mode: RawMode.polling, pollMs: 60));
    await rt.apply(Project(devices: [d], tags: const [temp, bomba]));
    final sub2 = rt.subscribe(const ['t', 'p']);
    await until(() => rt.watch('p').value.isGood);
    expect(rt.watch('p').value.value, isTrue);
    await rt.write('p', false);
    await until(() => rt.watch('p').value.value == false);
    expect(esp.values['P'], 0);
    sub2.cancel();
  });

  test('um socket só: telas, "Testar conexão", "Ouvir o equipamento" e a prévia do editor dividem a conexão', () async {
    final s = await arduino(streamEvery: const Duration(milliseconds: 40));
    final d = device(s.port);
    final rt = runtime();
    await rt.apply(Project(devices: [d], tags: const [temp]));
    final sub = rt.subscribe(const ['t']);
    await until(() => rt.watch('t').value.isGood);
    expect(s.connections, 1);

    // O sketch comum atende um cliente: um segundo socket não receberia nada.
    expect((await rt.probe(d)).ok, isTrue);
    final heard = await RawDriver.listen(d, duration: const Duration(milliseconds: 300));
    expect(heard.fields, {'T': 25.3, 'P': 1});
    expect(heard.good, greaterThan(0));

    final preview = RawPreview(d, RawTemplates.keyValueProfile);
    await preview.start();
    await until(() => preview.frames.isNotEmpty);
    expect(s.connections, 1);
    preview.dispose();
    expect(rt.watch('t').value.isGood, isTrue);
    sub.cancel();
    await until(() => s.connections == 0);
  });

  test('prévia ao vivo: mexer no perfil reinterpreta o que já chegou; polling manda o pedido do perfil em edição', () async {
    final s = await arduino(streamEvery: const Duration(milliseconds: 30), encode: (v) => utf8.encode('${v['T']},${v['P']}\n'));
    final preview = RawPreview(device(s.port), RawTemplates.keyValueProfile);
    addTearDown(preview.dispose);
    var changes = 0;
    preview.addListener(() => changes++);
    await preview.start();
    expect(preview.state, RawPreviewLink.connected);
    await until(() => preview.frames.length >= 3);
    expect(preview.frames.every((f) => f.problem == FrameProblem.noFields), isTrue, reason: 'CSV lido como chave=valor');

    s.silent = true; // nada novo chega: a mudança vem só do perfil
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final antes = changes;
    preview.profile = RawTemplates.csvProfile;
    expect(changes, antes + 1);
    expect(preview.frames.last.fields, {'1': 25.3, '2': 1});
    preview.profile = const MessageProfile(fields: CsvFields(names: ['temp', 'bomba']));
    expect(preview.frames.last.fields, {'temp': 25.3, 'bomba': 1});
    preview.profile = const MessageProfile(fields: RegexFields('(?<a>'));
    expect(preview.problems, isNotEmpty, reason: 'perfil que não fecha mostra o problema, não mensagens');
    expect(preview.frames, isEmpty);

    // Polling no perfil em edição: a prévia manda o pedido.
    final quieto = await arduino();
    final p2 = RawPreview(device(quieto.port), RawTemplates.keyValueProfile.copyWith(mode: RawMode.polling, pollMs: 200));
    addTearDown(p2.dispose);
    await p2.start();
    await until(() => p2.frames.isNotEmpty);
    expect(quieto.received, contains('?'));
    expect(p2.frames.last.fields, {'T': 25.3, 'P': 1});

    final fechada = RawPreview(device(1), RawTemplates.keyValueProfile);
    addTearDown(fechada.dispose);
    await fechada.start();
    expect(fechada.state, RawPreviewLink.failed);
    expect(fechada.error, isNotNull);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('"Lendo agora": valor na hora, campo que não veio diz quais chegam, nada chegou é neutro; fechar solta a conexão', () async {
    final s = await arduino(streamEvery: const Duration(milliseconds: 40));
    final rt = runtime();
    await rt.apply(Project(devices: [device(s.port)], tags: const [temp]));
    expect(await rt.readNow(temp), 25.3);
    await expectLater(
      rt.readNow(const Tag(id: 'z', deviceId: 'ard', name: 'Z', raw: RawAddress(field: 'Z'))),
      throwsA(isA<TagValueError>().having((e) => e.message, 'mensagem', 'o campo "Z" não veio — chegam T, P')),
    );
    expect(s.connections, 1);
    rt.releaseIdle();
    await until(() => s.connections == 0, what: 'soltar a conexão aberta só para o "lendo agora"');

    final calado = await arduino();
    await rt.apply(Project(devices: [device(calado.port)], tags: const [temp]));
    await expectLater(rt.readNow(temp), throwsA(isA<RawNoMessageYet>()));
    rt.releaseIdle();
  });

  test('variável do protocolo errado vira erro de configuração', () async {
    final s = await arduino(streamEvery: const Duration(milliseconds: 40));
    final rt = runtime();
    const modbus = Tag(id: 'hr', deviceId: 'ard', name: 'HR 4', address: 4);
    await rt.apply(Project(devices: [device(s.port)], tags: const [modbus]));
    final sub = rt.subscribe(const ['hr']);
    await until(() => rt.watch('hr').value.quality == TagQuality.configError);
    expect(rt.watch('hr').value.message, 'variável sem campo da mensagem');
    sub.cancel();

    const demo = Device(id: 'dm', name: 'Demo', kind: DeviceKind.demo);
    const sobra = Tag(id: 'x', deviceId: 'dm', name: 'Sobra', raw: RawAddress(field: 'T'));
    await rt.apply(const Project(devices: [demo], tags: [sobra]));
    final sub2 = rt.subscribe(const ['x']);
    await until(() => rt.watch('x').value.quality == TagQuality.configError);
    expect(rt.watch('x').value.message, contains('Arduino'));
    sub2.cancel();
  });

  test('arquivo do projeto: ida e volta, e Modbus continua sem nada do cru', () {
    const perfil = MessageProfile(
      framing: StartEndFraming(start: '\x02', end: '\x03'),
      checksum: ChecksumSpec(kind: ChecksumKind.xor, afterEnd: true),
      fields: RegexFields(r'(?<peso>[+-]\d+\.\d+)kg'),
      staleAfterMs: 2000,
      commands: [CommandTemplate.text('Z\r\n', name: 'Zerar')],
    );
    const dev = Device(id: 'r', name: 'Balança', kind: DeviceKind.raw, host: '10.0.0.7', port: 4001,
        raw: RawConfig(transport: RawTransport.udp, localPort: 6000, profile: perfil));
    const t = Tag(id: 't', deviceId: 'r', name: 'Peso', dataType: TagDataType.float32, writable: true,
        raw: RawAddress(field: 'peso', validitySec: 30, command: CommandTemplate.binary('AA 01 {valor:u16} {cs}', order: RawByteOrder.dcba)));
    final p = ProjectRepository.decode(ProjectRepository.encode(const Project(devices: [dev], tags: [t])));
    final d2 = p.devices.single, t2 = p.tags.single;
    expect(d2.kind, DeviceKind.raw);
    expect(d2.raw, dev.raw);
    expect(d2.sameLinkAs(dev), isTrue);
    expect(t2.raw, t.raw);
    expect(t2.addressLabel, 'campo peso');
    expect(dev.addressLabel, '10.0.0.7:4001 · Arduino · UDP');
    expect(dev.sameLinkAs(dev.copyWith(raw: dev.raw.copyWith(profile: perfil.copyWith(staleAfterMs: 3000)))), isFalse,
        reason: 'perfil novo refaz a conexão com o perfil novo');

    // Projeto Modbus fica byte a byte como antes.
    const mb = Device(id: 'b', name: 'B', host: '10.0.0.6');
    const mt = Tag(id: 'x', deviceId: 'b', name: 'X');
    expect(mb.toJson().containsKey('raw'), isFalse);
    expect(mt.toJson().containsKey('raw'), isFalse);
    expect(Device.fromJson(mb.toJson()).raw, const RawConfig());
    // Porta local só quando é UDP e diferente de 0.
    expect(const RawConfig(localPort: 6000).toJson().containsKey('localPort'), isFalse);

    // Campos Modbus de variável crua voltam ao padrão; lista não existe lá.
    final odd = Tag.fromJson({...t.toJson(), 'area': 'discreteInput', 'address': 40, 'length': 8});
    expect(odd.area, ModbusArea.holdingRegister);
    expect(odd.address, 0);
    expect(odd.length, 1);
    expect(odd.canWrite, isTrue);
    expect(Tag.fromJson({...t.toJson(), 'raw': {'field': 'peso'}}).raw!.command, isNull);
  });

  test('codec: campo → valor da variável e valor → {valor} do comando; modelos prontos leem os exemplos', () {
    const n = Tag(id: 'n', deviceId: 'd', name: 'N', raw: RawAddress(field: 'N'));
    expect(RawCodec.decode(n, 25), 25);
    expect(RawCodec.decode(n, 25.0), 25, reason: 'inteiro que veio "25.0" fica 25');
    expect(RawCodec.decode(n.copyWith(scale: 0.1), 752), closeTo(75.2, 1e-9));
    expect(RawCodec.decode(n.copyWith(dataType: TagDataType.float32), 25), isA<double>());
    expect(RawCodec.decode(n.copyWith(dataType: TagDataType.bool), 0), isFalse);
    expect(RawCodec.decode(n.copyWith(dataType: TagDataType.bool), 'ON'), isTrue);
    expect(RawCodec.decode(n.copyWith(dataType: TagDataType.string), 25.0), '25');
    expect(() => RawCodec.decode(n, 'OK'), throwsA(isA<TagValueError>().having((e) => e.message, 'mensagem', '"OK" não é número')));
    expect(RawCodec.encode(n.copyWith(scale: 0.1), 75.2), 752);
    expect(RawCodec.encode(n.copyWith(dataType: TagDataType.float32), 12.5), 12.5);
    expect(RawCodec.encode(n.copyWith(dataType: TagDataType.bool), 1), isTrue);
    expect(() => RawCodec.encode(n, 1.5), throwsA(isA<TagValueError>()));
    expect(RawCodec.guessType(1), TagDataType.uint16);
    expect(RawCodec.guessType(25.3), TagDataType.float32);
    expect(RawCodec.guessType('OFF'), TagDataType.bool);
    expect(RawCodec.guessType('OK'), TagDataType.string);

    List<Map<String, Object>> ler(MessageProfile p, List<int> bytes) => [for (final f in MessageParser(p).add(bytes)) f.fields];
    expect(ler(RawTemplates.keyValue.profile, utf8.encode('T=25.3;P=1\n')), [{'T': 25.3, 'P': 1}]);
    expect(ler(RawTemplates.csv.profile, utf8.encode('25.3,1,OK\n')), [{'1': 25.3, '2': 1, '3': 'OK'}]);
    // AA 55, 1000 e 2 com o byte baixo primeiro (struct do Arduino).
    expect(ler(RawTemplates.binary.profile, [0xAA, 0x55, 0xE8, 0x03, 0x02, 0x00]), [{'valor1': 1000, 'valor2': 2}]);
    for (final m in RawTemplates.all) {
      expect(m.profile.problems(), isEmpty, reason: m.name);
      expect(RawTemplates.of(m.profile), same(m));
    }
    expect(RawTemplates.describe(const MessageProfile(fields: RegexFields('(?<a>x)'))), contains('regex'));
  });
}
