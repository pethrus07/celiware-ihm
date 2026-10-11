import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/core/s7/s7_address.dart';
import 'package:ihm/core/s7/s7_codec.dart';
import 'package:ihm/core/s7/s7_error.dart';
import 'package:ihm/core/s7/s7_test_server.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/s7_config.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/runtime/s7_tag_codec.dart';
import 'package:ihm/services/runtime/tag_codec.dart';
import 'package:ihm/services/runtime/tag_store.dart';
import 'package:ihm/services/storage/project_repository.dart';

S7Address at(String text) => S7Address.parse(text);

Tag s7(String id, String address, {TagDataType type = TagDataType.uint16, bool writable = false, double scale = 1, int length = 1}) =>
    Tag(id: id, deviceId: 'clp', name: id, dataType: type, writable: writable, scale: scale, length: length, s7: S7TagAddress(address));

/// CLP Siemens S7 pelo caminho de produção — fábrica padrão → S7Driver →
/// sessão → TagStore — contra o `S7TestServer`, por socket de verdade.
void main() {
  late S7Memory memory;
  late S7TestServer server;
  late Device device;
  final runtimes = <HmiRuntime>[];

  /// Runtime descartado no fim do teste, passe o que passar.
  HmiRuntime runtime() {
    final rt = HmiRuntime();
    runtimes.add(rt);
    return rt;
  }

  setUp(() async {
    memory = S7Memory()
      ..addDb(1, 100)
      ..addDb(2, 40);
    // PDU 240, como S7-300 e S7-1200: obriga a dividir cedo.
    server = S7TestServer(memory, pduSize: 240);
    await server.start();
    device = Device(id: 'clp', name: 'Prensa', kind: DeviceKind.s7, host: '127.0.0.1', port: server.port, timeoutMs: 1000, pollMs: 50);
  });

  tearDown(() async {
    for (final rt in runtimes) {
      await rt.dispose();
    }
    runtimes.clear();
    await server.stop();
  });

  /// Espera uma condição de verdade (rede real, não relógio simulado).
  Future<void> until(bool Function() ok, {int ms = 3000, String? what}) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('não aconteceu em $ms ms${what == null ? '' : ': $what'}');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('caminho de produção: testar conexão, ler na varredura num pedido só, gravar bit e palavra', () async {
    memory
      ..poke(at('DB1.DBB0'), [0xA5]) // 1010 0101: bit 3 desligado, bit 5 ligado
      ..poke(at('DB1.DBW2'), S7Codec.encode(S7Type.word, 1500))
      ..poke(at('DB1.DBW4'), S7Codec.encode(S7Type.int16, -12))
      ..poke(at('DB1.DBD6'), S7Codec.encode(S7Type.real, 72.5))
      ..poke(at('DB1.DBD10'), S7Codec.encode(S7Type.int32, -100000))
      ..poke(at('P#DB1.DBX20.0 BYTE 12'), S7Codec.encodeString('Lote 42', 10))
      ..poke(at('DB1.DBW40'), [0, 10, 0, 20, 0, 30])
      ..poke(at('M10.3'), [1])
      ..poke(at('IW64'), S7Codec.encode(S7Type.word, 752));
    final tags = [
      s7('liga', 'DB1.DBX0.5', type: TagDataType.bool, writable: true),
      s7('vizinho', 'DB1.DBX0.3', type: TagDataType.bool),
      s7('vel', 'DB1.DBW2', writable: true),
      s7('ajuste', 'DB1.DBW4', type: TagDataType.int16),
      s7('temp', '%DB1.DBD6', type: TagDataType.float32),
      s7('pecas', 'DB1.DBD10', type: TagDataType.int32),
      s7('lote', 'P#DB1.DBX20.0 BYTE 12', type: TagDataType.string),
      s7('producao', 'DB1.DBW40', length: 3),
      s7('porta', 'M10.3', type: TagDataType.bool),
      s7('pressao', 'EW64', scale: 0.1),
    ];

    final rt = runtime();
    expect((await rt.probe(device)).ok, isTrue);
    expect((await rt.probe(device, tag: tags[2])).value, 1500);

    await rt.apply(Project(devices: [device], tags: tags));
    server.readItemCounts.clear();
    final sub = rt.subscribe(tags.map((t) => t.id));
    await until(() => tags.every((t) => rt.watch(t.id).value.isGood), what: 'todas boas');
    expect(rt.watch('liga').value.value, isTrue);
    expect(rt.watch('vizinho').value.value, isFalse);
    expect(rt.watch('vel').value.value, 1500);
    expect(rt.watch('ajuste').value.value, -12);
    expect(rt.watch('temp').value.value, 72.5);
    expect(rt.watch('pecas').value.value, -100000);
    expect(rt.watch('lote').value.value, 'Lote 42');
    expect(rt.watch('producao').value.value, [10, 20, 30]);
    expect(rt.watch('porta').value.value, isTrue);
    expect(rt.watch('pressao').value.value, closeTo(75.2, 1e-9));
    // DB1 vira um item só; M e I, um cada: um pedido com 3 itens.
    expect(server.readItemCounts.first, 3);
    expect(rt.health('clp')!.value.online, isTrue);
    expect(rt.health('clp')!.value.blocks, 1, reason: 'uma ida e volta por varredura');

    // Bit grava com transporte BIT: os vizinhos do byte ficam como estavam.
    await rt.write('liga', false);
    expect(memory.peek(at('DB1.DBB0')), [0x85]);
    await until(() => rt.watch('liga').value.value == false);
    await rt.write('vel', 1800);
    expect(S7Codec.decode(S7Type.word, memory.peek(at('DB1.DBW2'))), 1800);
    await until(() => rt.watch('vel').value.value == 1800);

    // Entrada (I/E) é só leitura; valor fora do tipo é recusado antes da rede.
    await expectLater(rt.write('pressao', 80), throwsA(isA<TagValueError>()));
    await expectLater(rt.write('vel', 70000), throwsA(isA<TagValueError>().having((e) => e.message, 'm', '"vel" aceita de 0 a 65535')));
    sub.cancel();
  });

  test('erro por item marca só a variável errada (DB inexistente, fora do DB, acesso negado)', () async {
    memory
      ..poke(at('DB1.DBW0'), [0, 42])
      ..poke(at('DB1.DBW96'), [0, 96]);
    server.deniedDbs.add(2);
    final tags = [
      s7('boa', 'DB1.DBW0'),
      s7('vizinha', 'DB1.DBW96'),
      s7('fora', 'DB1.DBD98', type: TagDataType.float32), // o DB1 tem 100 bytes
      s7('sem-db', 'DB9.DBW0'),
      s7('negado', 'DB2.DBW0'),
    ];
    final rt = runtime();
    await rt.apply(Project(devices: [device], tags: tags));
    final sub = rt.subscribe(tags.map((t) => t.id));
    await until(() => rt.watch('fora').value.quality == TagQuality.addressError, what: 'isolar a errada');
    await until(() => rt.watch('boa').value.isGood && rt.watch('vizinha').value.isGood);
    expect(rt.watch('boa').value.value, 42);
    expect(rt.watch('vizinha').value.value, 96);
    expect(rt.watch('fora').value.message, 'endereço fora do DB (DB menor ou com acesso otimizado)');
    expect(rt.watch('sem-db').value.quality, TagQuality.addressError);
    expect(rt.watch('sem-db').value.message, 'DB inexistente no CLP');
    expect(rt.watch('negado').value.quality, TagQuality.configError);
    expect(rt.watch('negado').value.message, S7Hint.accessDenied);
    expect(rt.health('clp')!.value.online, isTrue, reason: 'erro de item não é queda');

    // Corrigido o endereço, a variável volta a ser juntada com as vizinhas.
    await rt.apply(Project(devices: [device], tags: [...tags.take(2), s7('fora', 'DB1.DBW98'), ...tags.skip(3)]));
    await until(() => rt.watch('fora').value.isGood, what: 'endereço corrigido');
    sub.cancel();
  });

  test('PUT/GET desligado: testar conexão diz o que fazer; a varredura fica sem comunicação com a dica', () async {
    server.refuseJobs = true;
    final rt = runtime();
    final probe = await rt.probe(device);
    expect(probe.ok, isFalse);
    expect(probe.message, S7Hint.putGet);
    expect(probe.refused, isTrue, reason: 'o CLP respondeu: não é para conferir Wi-Fi e IP');
    expect(probe.hint, isNull);

    final vel = s7('vel', 'DB1.DBW2');
    await rt.apply(Project(devices: [device], tags: [vel]));
    final sub = rt.subscribe(const ['vel']);
    await until(() => rt.watch('vel').value.quality == TagQuality.commLost);
    expect(rt.watch('vel').value.message, S7Hint.putGet);
    expect(rt.health('clp')!.value.message, S7Hint.putGet);

    // Habilitado no TIA e carregado: volta sozinho, sem reconectar.
    server.refuseJobs = false;
    memory.poke(at('DB1.DBW2'), [0, 7]);
    await until(() => rt.watch('vel').value.isGood, ms: 5000, what: 'voltar depois de habilitar');
    expect(rt.watch('vel').value.value, 7);
    sub.cancel();
  });

  test('rack/slot: família errada recusa com a dica; a certa e "Outro" com o slot conectam', () async {
    final s300 = S7TestServer(memory, requiredRemoteTsap: 0x0102); // CPU no slot 2
    await s300.start();
    final d = device.copyWith(port: s300.port);
    final rt = runtime();
    final wrong = await rt.probe(d);
    expect(wrong.ok, isFalse);
    expect(wrong.message, S7Hint.rackSlot);
    expect(wrong.refused, isTrue);
    expect((await rt.probe(d.copyWith(s7: const S7Config(family: S7Family.s7300)))).ok, isTrue);
    expect((await rt.probe(d.copyWith(s7: const S7Config(family: S7Family.other, slot: 2)))).ok, isTrue);
    expect(s300.lastRemoteTsap, 0x0102);
    await s300.stop();
  });

  test('porta fechada = "recusou nesta porta"', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closed = probe.port;
    await probe.close();
    final r = await runtime().probe(device.copyWith(port: closed));
    expect(r.ok, isFalse);
    expect(r.refused, isTrue);
    expect(r.message, 'o CLP recusou a conexão nesta porta');
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('CLP que cai vira sem comunicação com o último valor, e a sessão reconecta sozinha', () async {
    memory.poke(at('DB1.DBW2'), [0, 70]);
    final vel = s7('vel', 'DB1.DBW2');
    final rt = runtime();
    await rt.apply(Project(devices: [device], tags: [vel]));
    final sub = rt.subscribe(const ['vel']);
    await until(() => rt.watch('vel').value.isGood);

    final port = server.port;
    await server.stop();
    await until(() => rt.watch('vel').value.quality == TagQuality.commLost, what: 'queda percebida');
    expect(rt.watch('vel').value.value, 70, reason: 'último valor, esmaecido — nunca um zero falso');
    expect(rt.health('clp')!.value.online, isFalse);

    memory.poke(at('DB1.DBW2'), [0, 72]);
    server = S7TestServer(memory, pduSize: 240);
    await server.start(port: port);
    await until(() => rt.watch('vel').value.isGood, ms: 8000, what: 'reconexão');
    expect(rt.watch('vel').value.value, 72);
    expect(rt.health('clp')!.value.online, isTrue);
    sub.cancel();
  });

  test('"lendo agora": lê o endereço digitado e solta a conexão ao fechar o cadastro', () async {
    memory.poke(at('DB1.DBD6'), S7Codec.encode(S7Type.real, 3.5));
    final rt = runtime();
    await rt.apply(Project(devices: [device]));
    expect(await rt.readNow(s7('novo', 'DB1.DBD6', type: TagDataType.float32)), 3.5);
    await expectLater(rt.readNow(s7('novo', 'DB9.DBW0')), throwsA(isA<S7ItemError>().having((e) => e.userMessage, 'm', 'DB inexistente no CLP')));
    expect(server.clientCount, 1);
    rt.releaseIdle();
    await until(() => server.clientCount == 0, what: 'soltar a conexão aberta só para o "lendo agora"');
  });

  test('cadastro que não fecha vira erro de configuração; variável de outro protocolo também', () async {
    final tags = [
      s7('real-num-dbw', 'DB1.DBW4', type: TagDataType.float32),
      s7('bit-num', 'DB1.DBX0.0'),
      s7('texto-curto', 'DB1.DBW4', type: TagDataType.string),
      s7('torto', 'DB1.DBX0.8', type: TagDataType.bool),
      const Tag(id: 'modbus', deviceId: 'clp', name: 'HR 4', address: 4),
    ];
    final rt = runtime();
    await rt.apply(Project(devices: [device], tags: tags));
    final sub = rt.subscribe(tags.map((t) => t.id));
    await until(() => tags.every((t) => rt.watch(t.id).value.quality == TagQuality.configError));
    expect(rt.watch('real-num-dbw').value.message, 'Número com vírgula pede 4 bytes: use DB1.DBD4');
    expect(rt.watch('bit-num').value.message, 'Número inteiro pede 1 ou 2 bytes: use DB1.DBW0');
    expect(rt.watch('texto-curto').value.message, 'Texto pede a faixa do STRING: use P#DB1.DBX4.0 BYTE 22 (STRING[20])');
    expect(rt.watch('torto').value.message, 'DB1.DBX0.8: o bit vai de 0 a 7');
    expect(rt.watch('modbus').value.message, 'variável sem endereço S7');
    expect(server.readJobs, 0, reason: 'nada disso vai para a rede');
    sub.cancel();

    // E o contrário: variável S7 num equipamento Modbus não lê o HR 0.
    const demo = Device(id: 'dm', name: 'Demo', kind: DeviceKind.demo);
    final sobra = Tag(id: 'x', deviceId: 'dm', name: 'Sobra', s7: const S7TagAddress('DB1.DBW0'));
    await rt.apply(Project(devices: const [demo], tags: [sobra]));
    final sub2 = rt.subscribe(const ['x']);
    await until(() => rt.watch('x').value.quality == TagQuality.configError);
    expect(rt.watch('x').value.message, 'variável de Siemens S7 num equipamento Modbus');
    sub2.cancel();
  });

  group('variável ⇄ S7 (funções puras)', () {
    test('tipo sugerido pelo tamanho do endereço', () {
      expect(S7TagCodec.suggestedType(at('DB1.DBX0.0')), TagDataType.bool);
      expect(S7TagCodec.suggestedType(at('MB4')), TagDataType.uint16);
      expect(S7TagCodec.suggestedType(at('DB1.DBW4')), TagDataType.uint16);
      expect(S7TagCodec.suggestedType(at('DB1.DBD8')), TagDataType.float32);
      expect(S7TagCodec.suggestedType(at('P#DB1.DBX10.0 BYTE 22')), TagDataType.string);
      expect(S7TagCodec.technical(TagDataType.int32), 'DINT');
    });

    test('exemplo no mesmo lugar do CLP, no mnemônico que a pessoa usou', () {
      expect(S7TagCodec.problem(at('EW64'), TagDataType.float32, german: true), 'Número com vírgula pede 4 bytes: use ED64');
      expect(S7TagCodec.problem(at('MW10'), TagDataType.bool), 'Liga / desliga pede um bit: use M10.0');
      expect(S7TagCodec.problem(at('DB1.DBW4'), TagDataType.int16), isNull);
      expect(S7TagCodec.problem(at('MB4'), TagDataType.int16), 'Inteiro com sinal pede 2 bytes: use MW4');
      expect(S7TagCodec.problem(at('DB1.DBX0.0'), TagDataType.bool, length: 4), contains('lista de bits'));
      expect(S7TagCodec.problem(at('DB1.DBW65532'), TagDataType.uint16, length: 3), 'DB1.DBW65532: a lista passa do byte 65535');
    });

    test('lista, byte e escala nos dois sentidos', () {
      final lista = s7('l', 'DB1.DBW10', length: 4);
      final plan = S7TagCodec.plan(lista);
      expect(plan.address, at('P#DB1.DBX10.0 BYTE 8'));
      expect(S7TagCodec.decode(lista, plan, Uint8List.fromList([0, 1, 0, 2, 0, 3, 0, 4])), [1, 2, 3, 4]);

      final byte = s7('b', 'DB1.DBB3', scale: 0.5, writable: true);
      final bp = S7TagCodec.plan(byte);
      expect(bp.type, S7Type.byte);
      expect(S7TagCodec.decode(byte, bp, Uint8List.fromList([200])), 100);
      expect(S7TagCodec.encode(byte, bp, 100).bytes, [200]);
      expect(() => S7TagCodec.encode(byte, bp, 200), throwsA(isA<TagValueError>().having((e) => e.message, 'm', '"b" aceita de 0,0 a 127,5')));

      final temp = s7('t', 'DB1.DBD0', type: TagDataType.float32, writable: true);
      expect(S7TagCodec.encode(temp, S7TagCodec.plan(temp), 1.5).bytes, [0x3F, 0xC0, 0x00, 0x00]);
      final dint = s7('d', 'DB1.DBD0', type: TagDataType.int32, scale: 0.01, writable: true);
      expect(S7TagCodec.encode(dint, S7TagCodec.plan(dint), -1000).bytes, [0xFF, 0xFE, 0x79, 0x60]);
      expect(() => S7TagCodec.encode(dint, S7TagCodec.plan(dint), 1.234), throwsA(isA<TagValueError>()));
    });

    test('item juntado: vizinhos do mesmo DB num item só, áreas e DBs separados, isolado à parte', () {
      final items = [
        for (final t in [
          s7('a', 'DB1.DBW0'),
          s7('b', 'DB1.DBX4.1', type: TagDataType.bool),
          s7('c', 'DB1.DBD30', type: TagDataType.float32),
          s7('longe', 'DB1.DBW90'),
          s7('outro-db', 'DB2.DBW0'),
          s7('m', 'MW0'),
        ])
          (t, S7TagCodec.plan(t)),
      ];
      final blocks = const S7ScanPlanner().plan(items);
      expect(blocks.map((b) => b.toString()), unorderedEquals([
        'P#DB1.DBX0.0 BYTE 34 (3 var.)',
        'DB1.DBW90 (1 var.)',
        'DB2.DBW0 (1 var.)',
        'MW0 (1 var.)',
      ]));
      final db1 = blocks.firstWhere((b) => b.members.length == 3);
      final data = Uint8List(34)..[4] = 0x02;
      expect(db1.bytesOf(items[1].$2, data), [1], reason: 'bit 1 do byte 4');

      final isolated = const S7ScanPlanner().plan(items, isolated: {'b'});
      expect(isolated.where((b) => b.address == at('DB1.DBX4.1')), hasLength(1), reason: 'isolado com o próprio endereço');
    });
  });

  test('arquivo do projeto: ida e volta, e projeto antigo fica byte a byte igual', () {
    const dev = Device(id: 'p', name: 'Prensa', kind: DeviceKind.s7, host: '10.0.0.7', port: 1102, s7: S7Config(family: S7Family.other, slot: 3));
    const t = Tag(id: 't', deviceId: 'p', name: 'Pressão', dataType: TagDataType.float32, writable: true, s7: S7TagAddress('EW64'));
    final p = ProjectRepository.decode(ProjectRepository.encode(const Project(devices: [dev], tags: [t])));
    final d2 = p.devices.single, t2 = p.tags.single;
    expect(d2.kind, DeviceKind.s7);
    expect(d2.s7, dev.s7);
    expect((d2.s7.rack, d2.s7.slot), (0, 3));
    expect(d2.sameLinkAs(dev), isTrue);
    expect(dev.toJson()['s7'], {'family': 'other', 'slot': 3}, reason: 'só o que difere do padrão');
    expect(t2.s7, t.s7);
    expect(t2.addressLabel, 'EW64');
    expect(t2.canWrite, isFalse, reason: 'entrada é só leitura');
    expect(dev.addressLabel, '10.0.0.7:1102 · S7 · rack 0 · slot 3');
    expect(dev.sameLinkAs(dev.copyWith(s7: const S7Config(family: S7Family.s7300))), isFalse, reason: 'outra família reconecta');

    // 1200/1500 de fábrica não grava nada além do tipo.
    const fabrica = Device(id: 'f', name: 'F', kind: DeviceKind.s7, host: '10.0.0.8', port: 102);
    expect(fabrica.toJson().containsKey('s7'), isFalse);
    expect(Device.fromJson(fabrica.toJson()).s7, const S7Config());
    expect(fabrica.addressLabel, '10.0.0.8:102 · S7-1200/1500');
    expect(S7TagAddress.normalize(' %db1.dbd8 '), 'DB1.DBD8');
    expect(S7TagAddress.normalize('ew64'), 'EW64');
    expect(s7('l', 'DB1.DBW0', length: 8).addressLabel, 'DB1.DBW0 · 8 valores');

    // Campos Modbus de variável S7 voltam ao padrão.
    final odd = Tag.fromJson({...s7('x', 'DB1.DBW0', writable: true).toJson(), 'area': 'discreteInput', 'address': 40});
    expect((odd.area, odd.address), (ModbusArea.holdingRegister, 0));
    expect(odd.canWrite, isTrue);

    // Projeto de antes do S7: o arquivo regravado sai idêntico.
    const antigo = Project(name: 'Linha 1', devices: [
      Device(id: 'a', name: 'CLP', host: '192.168.0.10'),
      Device(id: 'b', name: 'Sensor', kind: DeviceKind.mqtt, host: '192.168.0.20', port: 1883),
    ], tags: [
      Tag(id: 'x', deviceId: 'a', name: 'Velocidade', address: 4, writable: true, scale: 0.1),
    ]);
    final bytes = ProjectRepository.encode(antigo);
    expect(utf8.decode(bytes).contains('s7'), isFalse);
    expect(ProjectRepository.encode(ProjectRepository.decode(bytes)), bytes);
  });
}
