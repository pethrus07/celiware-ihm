import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/modbus/modbus_client_serial.dart';
import 'package:ihm/core/modbus/modbus_exception.dart';
import 'package:ihm/core/modbus/modbus_framing.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/core/serial/serial_params.dart';
import 'package:ihm/core/serial/usb_serial.dart';
import 'package:ihm/core/serial/usb_serial_link.dart';

import '../support/fake_usb_serial.dart';

/// Cabo USB sem hardware: o lado Android é a porta simulada de
/// `test/support/fake_usb_serial.dart`; daqui para cima é o código do app.
void main() {
  group('parâmetros da linha', () {
    test('tempo de um caractere e t3.5 pela velocidade', () {
      const p = SerialParams(); // 9600 8N1 = 10 bits
      expect(p.bitsPerChar, 10);
      expect(p.charTime, const Duration(microseconds: 1042));
      expect(p.t35, const Duration(microseconds: 3647));
      // Paridade é um bit a mais por caractere.
      expect(const SerialParams(parity: SerialParity.even).charTime, const Duration(microseconds: 1146));
      expect(const SerialParams(baud: 19200).t35, const Duration(microseconds: 1824));
      // Acima de 19200 a norma fixa 1,75 ms.
      expect(const SerialParams(baud: 38400).t35, const Duration(microseconds: 1750));
      expect(const SerialParams(baud: 115200).t35, const Duration(microseconds: 1750));
      expect(const SerialParams(baud: 1200).t35.inMilliseconds, 29);
    });

    test('rótulo, JSON só com o que difere e arquivo impossível corrigido', () {
      expect(const SerialParams().label, '9600 8N1');
      expect(SerialParams.ascii.label, '9600 7E1');
      expect(const SerialParams().toJson(), isEmpty);
      const p = SerialParams(baud: 19200, dataBits: 7, parity: SerialParity.odd, stopBits: 2);
      expect(p.toJson(), {'baud': 19200, 'dataBits': 7, 'parity': 'odd', 'stopBits': 2});
      expect(SerialParams.fromJson(p.toJson()), p);
      expect(SerialParams.fromJson({'baud': -5, 'dataBits': 9, 'stopBits': 3, 'parity': 'xyz'}), const SerialParams());
    });
  });

  group('adaptador escolhido × plugado', () {
    const ch340 = UsbPortInfo(deviceName: '/dev/bus/usb/001/002', vendorId: 0x1A86, productId: 0x7523, chip: 'CH340', product: 'USB2.0-Serial');
    const ftdiA = UsbPortInfo(deviceName: '/dev/bus/usb/001/003', vendorId: 0x0403, productId: 0x6001, chip: 'FTDI', serialNumber: 'AAA');
    const ftdiB = UsbPortInfo(deviceName: '/dev/bus/usb/001/004', vendorId: 0x0403, productId: 0x6001, chip: 'FTDI', serialNumber: 'BBB');

    test('acha pelo chip e, com dois iguais, pelo número de série', () {
      expect(UsbPortRef.of(ch340).find([ftdiA, ch340]), same(ch340));
      expect(UsbPortRef.of(ftdiB).find([ftdiA, ftdiB]), same(ftdiB));
      // Sem número de série guardado (CH340 não tem): o primeiro igual.
      expect(const UsbPortRef(vendorId: 0x0403, productId: 0x6001).find([ftdiA, ftdiB]), same(ftdiA));
      expect(const UsbPortRef(vendorId: 0x10C4, productId: 0xEA60).find([ch340]), isNull);
    });

    test('nomes para a tela e JSON', () {
      expect(ch340.title, 'CH340 · USB2.0-Serial');
      expect(ch340.ids, '1A86:7523');
      expect(const UsbPortInfo(deviceName: 'x', vendorId: 0x0781, productId: 0x5567).title, 'Aparelho USB');
      expect(const UsbPortInfo(deviceName: 'x', vendorId: 0x0403, productId: 0x6010, chip: 'FTDI', portIndex: 1, portCount: 2).title, 'FTDI · porta 2');
      final ref = UsbPortRef.of(ftdiA);
      expect(UsbPortRef.fromJson(ref.toJson()), ref);
      expect(UsbPortRef.fromJson({'vendorId': 'x'}), isNull);
    });

    test('mapa vindo do Android', () {
      final p = UsbPortInfo.fromMap({'nome': '/dev/bus/usb/001/002', 'vid': 6790, 'pid': 29987, 'chip': 'CH340', 'produto': ' USB2.0-Serial ', 'permissao': true, 'porta': 0, 'portas': 1})!;
      expect(p.title, 'CH340 · USB2.0-Serial');
      expect(p.hasPermission, isTrue);
      expect(UsbPortInfo.fromMap({'nome': 1}), isNull);
    });
  });

  group('porta dividida (UsbSerialPool)', () {
    late FakeUsbSerial usb;

    setUp(() {
      usb = FakeUsbSerial();
      UsbSerial.platform = usb;
    });

    tearDown(() async {
      await UsbSerialPool.reset();
      await usb.dispose();
    });

    test('sem adaptador, sem escolha com dois, escolhido que não está plugado, fora do Android', () async {
      Future<UsbProblem> problem(UsbPortRef? ref) async {
        try {
          await UsbSerialPool.resolve(ref);
        } on UsbSerialError catch (e) {
          return e.problem;
        }
        fail('devia falhar');
      }

      expect(await problem(null), UsbProblem.noAdapter);
      usb.plug(FakeAdapter(chip: null, product: 'Pendrive')); // aparelho sem driver serial não conta
      expect(await problem(null), UsbProblem.noAdapter);
      final a = usb.plug(FakeAdapter());
      expect((await UsbSerialPool.resolve(null)).deviceName, a.deviceName, reason: 'um só plugado: é ele');
      usb.plug(FakeAdapter(vendorId: 0x0403, productId: 0x6001, chip: 'FTDI'));
      expect(await problem(null), UsbProblem.notChosen);
      expect(await problem(const UsbPortRef(vendorId: 0x067B, productId: 0x2303, chip: 'PL2303')), UsbProblem.noAdapter);
      usb.supported = false;
      expect(await problem(null), UsbProblem.unsupported);
      expect(const UsbSerialError('x', UsbProblem.noAdapter).userMessage, 'adaptador USB não encontrado');
    });

    test('dois canos no mesmo adaptador: uma abertura no Android, fecha com o último', () async {
      final a = usb.plug(FakeAdapter());
      final ref = UsbPortRef.of(a.info);
      final l1 = UsbSerialPool.acquire(port: ref, params: const SerialParams());
      final l2 = UsbSerialPool.acquire(port: ref, params: const SerialParams());
      final got1 = <int>[], got2 = <int>[];
      l1.input.listen(got1.addAll);
      l2.input.listen(got2.addAll);
      await Future.wait([l1.open(), l2.open()]);
      expect(usb.opens, 1);
      expect(UsbSerialPool.openCount, 1);
      a.inject([1, 2, 3]);
      await _settle();
      expect(got1, [1, 2, 3]);
      expect(got2, [1, 2, 3], reason: 'todos recebem todos os bytes');
      await l1.close();
      expect(usb.isOpen(a), isTrue);
      await l2.close();
      expect(usb.isOpen(a), isFalse);
      expect(UsbSerialPool.openCount, 0);
    });

    test('cada um nos seus parâmetros: troca na fila, nunca no meio do pedido do outro', () async {
      final a = usb.plug(FakeAdapter());
      final ref = UsbPortRef.of(a.info);
      final slow = UsbSerialPool.acquire(port: ref, params: const SerialParams());
      final fast = UsbSerialPool.acquire(port: ref, params: const SerialParams(baud: 19200));
      await slow.open();
      await fast.open();
      expect(a.appParams.baud, 19200, reason: 'quem chega com outra velocidade passa a valer para o que chega sozinho');
      final order = <String>[];
      final gate = Completer<void>();
      final f1 = slow.exclusive(() async {
        order.add('slow ${a.appParams.baud}');
        await gate.future;
        order.add('slow fim ${a.appParams.baud}');
      });
      final f2 = fast.exclusive(() async => order.add('fast ${a.appParams.baud}'));
      await _settle();
      gate.complete();
      await Future.wait([f1, f2]);
      expect(order, ['slow 9600', 'slow fim 9600', 'fast 19200']);
      await fast.close();
      await _settle();
      expect(a.appParams.baud, 9600, reason: 'saiu quem mudou: volta a de quem ficou');
      await slow.close();
    });

    test('cabo puxado: todos ficam sabendo; plugado de novo (outro caminho), reabre', () async {
      final a = usb.plug(FakeAdapter());
      final ref = UsbPortRef.of(a.info);
      final l1 = UsbSerialPool.acquire(port: ref, params: const SerialParams());
      final l2 = UsbSerialPool.acquire(port: ref, params: const SerialParams());
      final reasons = <String>[];
      l1.onClosed = reasons.add;
      l2.onClosed = reasons.add;
      await l1.open();
      await l2.open();
      final firstPath = a.deviceName;
      usb.unplug(a);
      await _settle();
      expect(reasons, ['adaptador USB desconectado', 'adaptador USB desconectado']);
      expect(l1.isOpen, isFalse);
      expect(UsbSerialPool.openCount, 0);
      await expectLater(l1.open(), throwsA(isA<UsbSerialError>().having((e) => e.problem, 'problem', UsbProblem.noAdapter)));
      usb.plug(a);
      expect(a.deviceName, isNot(firstPath));
      await l1.open();
      expect(l1.isOpen, isTrue);
      await l1.close();
      await l2.close();
    });

    test('permissão: pergunta uma vez; negada, a reconexão não pergunta de novo', () async {
      usb.plug(FakeAdapter(grantedOnPlug: false));
      usb.answerPermission = false;
      final l = UsbSerialPool.acquire(port: null, params: const SerialParams());
      for (var i = 0; i < 3; i++) {
        await expectLater(l.open(), throwsA(isA<UsbSerialError>().having((e) => e.userMessage, 'msg', 'sem permissão para usar o adaptador USB')));
      }
      expect(usb.permissionDialogs, 1, reason: 'caixa atrás de caixa a cada reconexão seria inaceitável');
      expect(UsbSerialPool.openCount, 0);
      // O cadastro insiste (depois de explicar): aí a caixa volta.
      usb.answerPermission = true;
      expect(await usb.requestPermission((await usb.list()).single, insist: true), isTrue);
      await l.open();
      expect(l.isOpen, isTrue);
      await l.close();
    });
  });

  group('Modbus RTU/ASCII pelo cabo (RT-2)', () {
    late FakeUsbSerial usb;
    late ModbusMemory memory;
    late FakeModbusSlave slave;
    late FakeAdapter adapter;
    late ModbusClientSerial client;

    Future<void> sobe({SerialParams line = const SerialParams(), ModbusFraming framing = ModbusFraming.rtu, bool echo = false, bool discardEcho = false, int packet = 8}) async {
      usb = FakeUsbSerial();
      UsbSerial.platform = usb;
      memory = ModbusMemory(holdingRegisters: 100, coils: 32);
      slave = FakeModbusSlave(memory, unitId: 5, framing: framing);
      adapter = usb.plug(FakeAdapter(lineParams: line, equipment: [slave], echo: echo, packetBytes: packet));
      client = ModbusClientSerial(
        link: UsbSerialPool.acquire(port: UsbPortRef.of(adapter.info), params: line),
        framing: framing,
        unitId: 5,
        discardEcho: discardEcho,
        // Folgado: a suíte inteira roda em paralelo. Quem espera tempo
        // esgotado encurta no próprio teste.
        responseTimeout: const Duration(milliseconds: 1500),
        label: 'USB CH340',
      );
      await client.connect();
    }

    tearDown(() async {
      await client.dispose();
      await UsbSerialPool.reset();
      await usb.dispose();
    });

    test('lê e grava; a resposta chega em pacotes de 1 byte (quadro partido)', () async {
      await sobe(packet: 1);
      memory.pokeRegisters(ModbusArea.holdingRegister, 10, [111, 222, 333]);
      expect(await client.fn03ReadHoldingRegisters(startAddress: 10, quantity: 3), [111, 222, 333]);
      await client.fn06WriteSingleRegister(address: 20, value: 4321);
      expect(memory.register(ModbusArea.holdingRegister, 20), 4321);
      await client.fn16WriteMultipleRegisters(startAddress: 30, values: [1, 2]);
      expect(memory.readRegisters(ModbusArea.holdingRegister, 30, 2), [1, 2]);
      await client.fn05WriteSingleCoil(address: 3, value: true);
      expect((await client.fn01ReadCoils(startAddress: 0, count: 8))[3], isTrue);
    });

    test('ASCII 7E1', () async {
      await sobe(line: SerialParams.ascii, framing: ModbusFraming.ascii);
      memory.pokeRegister(ModbusArea.holdingRegister, 1, 0xBEEF);
      expect(await client.fn03ReadHoldingRegisters(startAddress: 1, quantity: 1), [0xBEEF]);
      // Lixo antes do ':' sai.
      adapter.equipment.clear();
      adapter.equipment.add(_Prefix(slave, [0x00, 0x7F]));
      expect(await client.fn03ReadHoldingRegisters(startAddress: 1, quantity: 1), [0xBEEF]);
    });

    test('eco do RS-485 de 2 fios com "descartar eco": leitura e gravação (FC06 = resposta igual ao pedido)', () async {
      await sobe(echo: true, discardEcho: true);
      memory.pokeRegister(ModbusArea.holdingRegister, 2, 77);
      await client.fn06WriteSingleRegister(address: 4, value: 99);
      expect(memory.register(ModbusArea.holdingRegister, 4), 99);
      expect(await client.fn03ReadHoldingRegisters(startAddress: 2, quantity: 1), [77]);
    });

    test('eco percebido sozinho na primeira leitura e descartado daí em diante', () async {
      await sobe(echo: true);
      memory.pokeRegister(ModbusArea.holdingRegister, 2, 77);
      expect(client.echoDetected, isFalse);
      expect(await client.fn03ReadHoldingRegisters(startAddress: 2, quantity: 1), [77]);
      expect(client.echoDetected, isTrue);
      // Gravação depois: o primeiro quadro igual ao pedido é o eco, o segundo a resposta.
      await client.fn06WriteSingleRegister(address: 4, value: 55);
      expect(memory.register(ModbusArea.holdingRegister, 4), 55);
      expect(await client.fn03ReadHoldingRegisters(startAddress: 4, quantity: 1), [55]);
    });

    test('sem eco no adaptador, "descartar eco" não come a resposta da leitura', () async {
      await sobe(discardEcho: true);
      memory.pokeRegister(ModbusArea.holdingRegister, 2, 31);
      expect(await client.fn03ReadHoldingRegisters(startAddress: 2, quantity: 1), [31]);
    });

    test('byte espúrio antes da resposta (transceptor virando a linha) é descartado', () async {
      await sobe();
      memory.pokeRegister(ModbusArea.holdingRegister, 0, 1234);
      slave.glitchNext = true;
      expect(await client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 1), [1234]);
    });

    test('pausa maior que t3.5 + folga no meio do quadro: o começo sai, a resposta inteira vale', () async {
      await sobe();
      memory.pokeRegister(ModbusArea.holdingRegister, 0, 4321);
      // Logo depois do pedido chega o começo de um quadro que "parece" a
      // resposta (ID 5, função 3, 16 bytes) e para; a resposta de verdade vem
      // 80 ms depois. Só pelo tamanho, os dois se juntariam e o CRC falharia.
      slave.turnaround = const Duration(milliseconds: 80);
      adapter.onWrite = (_) => adapter.inject([0x05, 0x03, 0x10, 0x00]);
      expect(await client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 1), [4321]);
    });

    test('pacotes da mesma resposta com pausa de USB (16 ms, FTDI de fábrica) não partem o quadro', () async {
      await sobe(packet: 3);
      adapter.packetGap = const Duration(milliseconds: 16);
      memory.pokeRegisters(ModbusArea.holdingRegister, 0, [1, 2, 3, 4, 5]);
      expect(await client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 5), [1, 2, 3, 4, 5]);
    });

    test('CRC errado = resposta inválida; a próxima funciona', () async {
      await sobe();
      slave.corruptNext = true;
      await expectLater(client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 1),
          throwsA(isA<ModbusProtocolError>().having((e) => e.userMessage, 'msg', 'resposta inválida do equipamento')));
      expect(await client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 1), [0]);
    });

    test('velocidade diferente: o escravo não entende e fica quieto = sem resposta', () async {
      await sobe(line: const SerialParams(baud: 19200));
      // O app abre a 9600 (outro cano, outra velocidade) e pede.
      final wrong = ModbusClientSerial(
        link: UsbSerialPool.acquire(port: UsbPortRef.of(adapter.info), params: const SerialParams()),
        unitId: 5,
        responseTimeout: const Duration(milliseconds: 300),
      );
      await wrong.connect();
      await expectLater(wrong.fn03ReadHoldingRegisters(startAddress: 0, quantity: 1), throwsA(isA<ModbusTimeout>()));
      expect(slave.requests, 0);
      await wrong.dispose();
      expect(await client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 1), [0], reason: 'quem está na velocidade certa continua lendo');
    });

    test('bytes sem sentido e nenhuma resposta = "chegaram bytes que não formam uma resposta"', () async {
      await sobe();
      client.responseTimeout = const Duration(milliseconds: 300);
      slave.silent = true;
      adapter.onWrite = (_) => adapter.inject([0xF1, 0x22, 0x9A, 0x05, 0x44]);
      await expectLater(client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 1),
          throwsA(isA<ModbusProtocolError>().having((e) => e.garbled, 'garbled', isTrue).having((e) => e.userMessage, 'msg', ModbusProtocolError.garbledMessage)));
      adapter.onWrite = null;
      slave.silent = false;
      expect(await client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 1), [0]);
    });

    test('t3.5 entre quadros: a 1200 o pedido seguinte espera a linha quieta', () async {
      await sobe(line: const SerialParams(baud: 1200));
      client.responseTimeout = const Duration(seconds: 2);
      await client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 1);
      await client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 1);
      final between = adapter.writtenAt[1] - adapter.writtenAt[0];
      const line = SerialParams(baud: 1200);
      // Pedido (8 caracteres) sai no fio, a resposta chega, e mais t3.5.
      // (folga de 2 ms: o timer do fio simulado conta em milissegundos inteiros)
      expect(between, greaterThanOrEqualTo(line.charTime * 8 + line.t35 - const Duration(milliseconds: 2)));
    });

    test('cabo puxado com o pedido no ar: erro de conexão; volta sozinho quando pluga de novo', () async {
      await sobe();
      slave.turnaround = const Duration(milliseconds: 150);
      final read = client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 1);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      usb.unplug(adapter);
      await expectLater(read, throwsA(isA<ModbusConnectionError>()));
      await expectLater(client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 1),
          throwsA(isA<UsbSerialError>().having((e) => e.userMessage, 'msg', 'adaptador USB não encontrado')));
      slave.turnaround = const Duration(milliseconds: 3);
      usb.plug(adapter);
      memory.pokeRegister(ModbusArea.holdingRegister, 0, 9);
      expect(await client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 1), [9]);
    });

    test('dois escravos na mesma linha: um adaptador, pedidos em fila', () async {
      await sobe();
      final mem2 = ModbusMemory(holdingRegisters: 10);
      adapter.equipment.add(FakeModbusSlave(mem2, unitId: 6));
      final other = ModbusClientSerial(link: UsbSerialPool.acquire(port: UsbPortRef.of(adapter.info), params: const SerialParams()), unitId: 6);
      await other.connect();
      memory.pokeRegister(ModbusArea.holdingRegister, 0, 500);
      mem2.pokeRegister(ModbusArea.holdingRegister, 0, 600);
      final results = await Future.wait([
        for (var i = 0; i < 5; i++) ...[
          client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 1),
          other.fn03ReadHoldingRegisters(startAddress: 0, quantity: 1),
        ],
      ]);
      for (var i = 0; i < results.length; i++) {
        expect(results[i], [i.isEven ? 500 : 600]);
      }
      expect(usb.opens, 1);
      await other.dispose();
    });
  });
}

/// Deixa as entregas assíncronas da porta simulada acontecerem.
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 30));

/// Escravo que manda lixo antes da resposta (ASCII com bytes antes do ':').
class _Prefix extends FakeSerialEquipment {
  _Prefix(this.inner, this.junk);
  final FakeModbusSlave inner;
  final List<int> junk;

  @override
  void receive(Uint8List bytes, FakeAdapter line) {
    line.inject(junk);
    inner.receive(bytes, line);
  }
}
