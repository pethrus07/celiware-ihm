import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/modbus/modbus_framing.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/core/rawlink/message_profile.dart';
import 'package:ihm/core/serial/serial_params.dart';
import 'package:ihm/core/serial/usb_serial.dart';
import 'package:ihm/core/serial/usb_serial_link.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/raw_config.dart';
import 'package:ihm/models/serial_config.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/runtime/tag_store.dart';

import '../support/fake_usb_serial.dart';

/// Equipamento no cabo USB pelo caminho de produção: HmiRuntime → fábrica
/// padrão → driver (Modbus ou cru) → UsbSerialPool → porta simulada. Só o
/// lado Android é de mentira — nenhum adaptador nem CLP de verdade foi usado.
void main() {
  late FakeUsbSerial usb;
  final runtimes = <HmiRuntime>[];

  HmiRuntime newRuntime() {
    final rt = HmiRuntime();
    runtimes.add(rt);
    return rt;
  }

  setUp(() {
    usb = FakeUsbSerial();
    UsbSerial.platform = usb;
  });

  tearDown(() async {
    for (final rt in runtimes) {
      await rt.dispose();
    }
    runtimes.clear();
    await UsbSerialPool.reset();
    await usb.dispose();
  });

  // Prazo folgado onde a resposta deve vir (a suíte inteira roda em paralelo
  // e o processo do teste pode parar algumas centenas de ms); quem espera
  // "sem resposta" passa um curto.
  Device usbDevice(FakeAdapter a, {String id = 'inv', int unit = 1, SerialConfig? serial, int timeoutMs = 1500}) => Device(
        id: id,
        name: 'Inversor $unit',
        kind: DeviceKind.usbSerial,
        unitId: unit,
        timeoutMs: timeoutMs,
        pollMs: 50,
        serial: serial ?? SerialConfig(port: UsbPortRef.of(a.info)),
      );

  Future<void> until(HmiRuntime rt, String id, bool Function(TagReading r) ok, {int tries = 120}) async {
    for (var i = 0; i < tries && !ok(rt.watch(id).value); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  const freq = Tag(id: 'f', deviceId: 'inv', name: 'Frequência', area: ModbusArea.holdingRegister, address: 1, writable: true);

  for (final (framing, params) in [(ModbusFraming.rtu, const SerialParams()), (ModbusFraming.ascii, SerialParams.ascii)]) {
    test('${framing.label} pelo cabo: testar conexão, ler na varredura e gravar', () async {
      final memory = ModbusMemory(holdingRegisters: 50);
      final a = usb.plug(FakeAdapter(lineParams: params, equipment: [FakeModbusSlave(memory, framing: framing)]));
      final device = usbDevice(a,
          serial: SerialConfig(port: UsbPortRef.of(a.info), params: params, protocol: framing == ModbusFraming.ascii ? SerialProtocol.ascii : SerialProtocol.rtu));
      memory.pokeRegister(ModbusArea.holdingRegister, 1, 4500);

      final rt = newRuntime();
      final probe = await rt.probe(device);
      expect(probe.ok, isTrue, reason: probe.message);
      expect(probe.network, isNull, reason: 'cabo USB não passa pela rede');
      expect((await rt.probe(device, tag: freq)).value, 4500);

      await rt.apply(Project(devices: [device], tags: const [freq]));
      final sub = rt.subscribe(const ['f']);
      await until(rt, 'f', (r) => r.quality == TagQuality.good);
      expect(rt.watch('f').value.value, 4500);

      await rt.write('f', 6000);
      expect(memory.register(ModbusArea.holdingRegister, 1), 6000);
      await until(rt, 'f', (r) => r.value == 6000);
      expect(rt.watch('f').value.value, 6000, reason: 'a sessão relê e mostra o que o equipamento confirmou');
      sub.cancel();
    });
  }

  test('eco do RS-485 de 2 fios: descartado sozinho na varredura; gravação depois funciona', () async {
    final memory = ModbusMemory(holdingRegisters: 50);
    final a = usb.plug(FakeAdapter(echo: true, equipment: [FakeModbusSlave(memory)]));
    memory.pokeRegister(ModbusArea.holdingRegister, 1, 10);
    final rt = newRuntime();
    final device = usbDevice(a);
    await rt.apply(Project(devices: [device], tags: const [freq]));
    final sub = rt.subscribe(const ['f']);
    await until(rt, 'f', (r) => r.quality == TagQuality.good);
    expect(rt.watch('f').value.value, 10);
    await rt.write('f', 20);
    expect(memory.register(ModbusArea.holdingRegister, 1), 20);
    sub.cancel();
  });

  test('quadro partido (pacotes de 1 byte com pausa de USB) e byte espúrio: leitura normal', () async {
    final memory = ModbusMemory(holdingRegisters: 50);
    final slave = FakeModbusSlave(memory)..glitchNext = true;
    final a = usb.plug(FakeAdapter(equipment: [slave], packetBytes: 1, packetGap: const Duration(milliseconds: 5)));
    memory.pokeRegisters(ModbusArea.holdingRegister, 0, [7, 8, 9]);
    const list = Tag(id: 'l', deviceId: 'inv', name: 'Lista', area: ModbusArea.holdingRegister, address: 0, length: 3);
    final r = await newRuntime().probe(usbDevice(a), tag: list);
    expect(r.ok, isTrue, reason: r.message);
    expect(r.value, [7, 8, 9]);
  });

  test('CRC errado: "resposta inválida" no teste; a varredura segue', () async {
    final memory = ModbusMemory(holdingRegisters: 50);
    final slave = FakeModbusSlave(memory)..corruptNext = true;
    final a = usb.plug(FakeAdapter(equipment: [slave]));
    final rt = newRuntime();
    final bad = await rt.probe(usbDevice(a), tag: freq);
    expect(bad.ok, isFalse);
    expect(bad.message, 'resposta inválida do equipamento');
    expect((await rt.probe(usbDevice(a), tag: freq)).ok, isTrue);
  });

  test('velocidade ou paridade diferente: sem resposta; ID errado também', () async {
    final memory = ModbusMemory(holdingRegisters: 50);
    final a = usb.plug(FakeAdapter(lineParams: const SerialParams(baud: 19200, parity: SerialParity.even), equipment: [FakeModbusSlave(memory)]));
    final rt = newRuntime();
    final wrongBaud = await rt.probe(usbDevice(a, timeoutMs: 400));
    expect(wrongBaud.ok, isFalse);
    expect(wrongBaud.message, 'sem resposta do equipamento');
    final right = SerialConfig(port: UsbPortRef.of(a.info), params: const SerialParams(baud: 19200, parity: SerialParity.even));
    expect((await rt.probe(usbDevice(a, serial: right))).ok, isTrue);
    final wrongId = await rt.probe(usbDevice(a, serial: right, unit: 9, timeoutMs: 400));
    expect(wrongId.message, 'sem resposta do equipamento');
  });

  test('cabo puxado: último valor esmaecido e o motivo no selo; plugado de novo, volta sozinho', () async {
    final memory = ModbusMemory(holdingRegisters: 50);
    final a = usb.plug(FakeAdapter(equipment: [FakeModbusSlave(memory)]));
    memory.pokeRegister(ModbusArea.holdingRegister, 1, 321);
    final rt = newRuntime();
    final device = usbDevice(a);
    await rt.apply(Project(devices: [device], tags: const [freq]));
    final sub = rt.subscribe(const ['f']);
    await until(rt, 'f', (r) => r.quality == TagQuality.good);

    usb.unplug(a);
    await until(rt, 'f', (r) => r.quality == TagQuality.commLost);
    final lost = rt.watch('f').value;
    expect(lost.quality, TagQuality.commLost);
    expect(lost.value, 321, reason: 'nunca um zero falso');
    await until(rt, 'f', (r) => r.message == 'adaptador USB não encontrado');
    expect(rt.health('inv')!.value.message, 'adaptador USB não encontrado');

    memory.pokeRegister(ModbusArea.holdingRegister, 1, 654);
    usb.plug(a); // outro caminho no Android; a permissão vem do "usar sempre"
    await until(rt, 'f', (r) => r.quality == TagQuality.good && r.value == 654, tries: 200);
    expect(rt.watch('f').value.value, 654);
    expect(rt.health('inv')!.value.online, isTrue);
    sub.cancel();
  });

  test('dois inversores na mesma RS-485: um adaptador, cada um com o seu ID', () async {
    final m1 = ModbusMemory(holdingRegisters: 10), m2 = ModbusMemory(holdingRegisters: 10);
    final a = usb.plug(FakeAdapter(equipment: [FakeModbusSlave(m1, unitId: 1), FakeModbusSlave(m2, unitId: 2)]));
    m1.pokeRegister(ModbusArea.holdingRegister, 1, 111);
    m2.pokeRegister(ModbusArea.holdingRegister, 1, 222);
    final d1 = usbDevice(a, id: 'i1', unit: 1), d2 = usbDevice(a, id: 'i2', unit: 2);
    const t1 = Tag(id: 't1', deviceId: 'i1', name: 'F1', area: ModbusArea.holdingRegister, address: 1, writable: true);
    const t2 = Tag(id: 't2', deviceId: 'i2', name: 'F2', area: ModbusArea.holdingRegister, address: 1, writable: true);
    final rt = newRuntime();
    await rt.apply(Project(devices: [d1, d2], tags: const [t1, t2]));
    final sub = rt.subscribe(const ['t1', 't2']);
    await until(rt, 't1', (r) => r.quality == TagQuality.good);
    await until(rt, 't2', (r) => r.quality == TagQuality.good);
    expect(rt.watch('t1').value.value, 111);
    expect(rt.watch('t2').value.value, 222);
    await rt.write('t2', 333);
    expect(m2.register(ModbusArea.holdingRegister, 1), 333);
    expect(m1.register(ModbusArea.holdingRegister, 1), 111);
    // "Testar conexão" com a tela lendo: entra na fila da mesma porta.
    expect((await rt.probe(d1, tag: t1)).value, 111);
    expect(usb.opens, 1, reason: 'o Android abre o adaptador uma vez só');
    sub.cancel();
  });

  test('adaptador: nenhum, não escolhido com dois plugados, sem permissão, fora do Android', () async {
    final rt = newRuntime();
    const device = Device(id: 'x', name: 'X', kind: DeviceKind.usbSerial, timeoutMs: 300);
    expect((await rt.probe(device)).message, 'adaptador USB não encontrado');
    usb.plug(FakeAdapter());
    usb.plug(FakeAdapter(vendorId: 0x0403, productId: 0x6001, chip: 'FTDI'));
    expect((await rt.probe(device)).message, 'escolha o adaptador USB no cadastro do equipamento');
    final locked = usb.plug(FakeAdapter(vendorId: 0x10C4, productId: 0xEA60, chip: 'CP210x', grantedOnPlug: false));
    usb.answerPermission = false;
    final denied = await rt.probe(usbDevice(locked));
    expect(denied.message, 'sem permissão para usar o adaptador USB');
    usb.supported = false;
    expect((await rt.probe(device)).message, 'o cabo USB só funciona no Android');
  });

  test('sem permissão, a varredura não vira uma caixa atrás da outra', () async {
    final a = usb.plug(FakeAdapter(grantedOnPlug: false, equipment: [FakeModbusSlave(ModbusMemory(holdingRegisters: 5))]));
    usb.answerPermission = false;
    final rt = newRuntime();
    await rt.apply(Project(devices: [usbDevice(a)], tags: const [freq]));
    final sub = rt.subscribe(const ['f']);
    await until(rt, 'f', (r) => r.message == 'sem permissão para usar o adaptador USB');
    await Future<void>.delayed(const Duration(milliseconds: 1300)); // a sessão tenta de novo depois de 1 s
    expect(usb.permissionDialogs, 1);
    sub.cancel();
  });

  test('Arduino no cabo (protocolo cru): testar, ler na hora, gravar pelo comando; DTR ligado', () async {
    final arduino = FakeSerialArduino();
    final a = usb.plug(FakeAdapter(equipment: [arduino]));
    final device = Device(
      id: 'ard',
      name: 'Estufa',
      kind: DeviceKind.usbSerial,
      timeoutMs: 800,
      serial: SerialConfig(port: UsbPortRef.of(a.info), protocol: SerialProtocol.raw),
      raw: const RawConfig(profile: RawTemplates.keyValueProfile),
    );
    const temp = Tag(id: 'tp', deviceId: 'ard', name: 'Temperatura', dataType: TagDataType.float32, raw: RawAddress(field: 'T'));
    const pump = Tag(id: 'pp', deviceId: 'ard', name: 'Bomba', dataType: TagDataType.bool, writable: true, raw: RawAddress(field: 'P'));
    final rt = newRuntime();
    final probe = await rt.probe(device);
    expect(probe.ok, isTrue, reason: probe.message);
    expect(a.dtr, isTrue, reason: 'Leonardo/Micro só mandam com DTR ligado');

    await rt.apply(Project(devices: [device], tags: const [temp, pump]));
    final sub = rt.subscribe(const ['tp', 'pp']);
    await until(rt, 'tp', (r) => r.quality == TagQuality.good);
    expect(rt.watch('tp').value.value, closeTo(25.3, 1e-9));
    await rt.write('pp', true);
    // O comando leva o tempo do fio (10 caracteres a 9600) para chegar.
    for (var i = 0; i < 40 && !arduino.commands.contains('SET P=1'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(arduino.commands, contains('SET P=1'));
    await until(rt, 'pp', (r) => r.value == true);
    expect(rt.watch('pp').value.value, isTrue);
    sub.cancel();
  });

  test('Arduino no cabo com velocidade errada: chega mensagem e o perfil não entende', () async {
    final a = usb.plug(FakeAdapter(lineParams: const SerialParams(baud: 115200), equipment: [FakeSerialArduino(every: const Duration(milliseconds: 40))]));
    final device = Device(
      id: 'ard',
      name: 'Estufa',
      kind: DeviceKind.usbSerial,
      timeoutMs: 800,
      serial: SerialConfig(port: UsbPortRef.of(a.info), protocol: SerialProtocol.raw),
      raw: const RawConfig(profile: MessageProfile(staleAfterMs: 2000)),
    );
    final r = await newRuntime().probe(device);
    expect(r.ok, isFalse);
    expect(r.message, anyOf(startsWith('chegou mensagem, mas o perfil não entendeu'), startsWith('conectou, mas nenhuma mensagem chegou')));
  });

  test('arquivo do projeto: cabo USB ida e volta, só com o que difere; projeto antigo igual', () {
    const port = UsbPortRef(vendorId: 0x1A86, productId: 0x7523, chip: 'CH340', product: 'USB2.0-Serial');
    const rtu = Device(id: 'a', name: 'A', kind: DeviceKind.usbSerial, unitId: 3, serial: SerialConfig(port: port));
    final j = rtu.toJson();
    expect(j['kind'], 'usbSerial');
    expect(j['serial'], {'usb': {'vendorId': 0x1A86, 'productId': 0x7523, 'chip': 'CH340', 'product': 'USB2.0-Serial'}});
    expect(j.containsKey('framing'), isFalse);
    expect(j.containsKey('raw'), isFalse);
    final back = Device.fromJson(jsonDecode(jsonEncode(j)) as Map<String, dynamic>);
    expect(back.serial, rtu.serial);
    expect(back.sameLinkAs(rtu), isTrue);
    expect(back.usesModbusMemory, isTrue);
    expect(back.addressLabel, 'Cabo USB · CH340 · RTU · 9600 8N1 · ID 3');

    const ascii = Device(
        id: 'b',
        name: 'B',
        kind: DeviceKind.usbSerial,
        serial: SerialConfig(protocol: SerialProtocol.ascii, params: SerialParams.ascii, discardEcho: true));
    expect(ascii.toJson()['serial'], {'dataBits': 7, 'parity': 'even', 'protocol': 'ascii', 'discardEcho': true});
    expect(Device.fromJson(ascii.toJson()).serial, ascii.serial);
    expect(rtu.sameLinkAs(ascii), isFalse);

    const ard = Device(id: 'c', name: 'C', kind: DeviceKind.usbSerial, serial: SerialConfig(protocol: SerialProtocol.raw), raw: RawConfig(profile: RawTemplates.csvProfile));
    expect(ard.toJson()['raw'], {'profile': RawTemplates.csvProfile.toJson()}, reason: 'no cabo não há TCP/UDP');
    final ardBack = Device.fromJson(ard.toJson());
    expect(ardBack.speaksRaw, isTrue);
    expect(ardBack.usesModbusMemory, isFalse);
    expect(RawTemplates.of(ardBack.raw.profile), RawTemplates.csv);

    // Equipamento de rede não ganha nada novo no arquivo.
    const tcp = Device(id: 'd', name: 'D', host: '10.0.0.5');
    expect(tcp.toJson().containsKey('serial'), isFalse);
    expect(tcp.toJson().keys, ['id', 'name', 'kind', 'host', 'port', 'unitId', 'timeoutMs', 'pollMs']);
    expect(Device.fromJson(tcp.toJson()).serial, const SerialConfig());
    // Arquivo editado à mão: velocidade impossível volta ao padrão.
    final odd = Device.fromJson({'id': 'e', 'name': 'E', 'kind': 'usbSerial', 'serial': {'baud': 0, 'dataBits': 5, 'protocol': '???'}});
    expect(odd.serial.params, const SerialParams());
    expect(odd.serial.protocol, SerialProtocol.rtu);
  });
}
