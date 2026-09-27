import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/modbus/modbus_client.dart';
import 'package:ihm/core/modbus/modbus_client_tcp.dart';
import 'package:ihm/core/modbus/modbus_exception.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/core/modbus/modbus_tcp_server.dart';

/// Integração por socket real: cliente TCP de produção × servidor Dart local.
void main() {
  late ModbusMemory memory;
  late ModbusTcpServer server;
  late ModbusClientTcp client;

  setUp(() async {
    memory = ModbusMemory(holdingRegisters: 200, coils: 200);
    server = ModbusTcpServer(memory);
    await server.start();
    client = ModbusClientTcp(
      host: '127.0.0.1',
      port: server.port,
      responseTimeout: const Duration(milliseconds: 300),
    );
    await client.connect();
  });

  tearDown(() async {
    await client.dispose();
    await server.stop();
  });

  test('lê e escreve registradores e coils', () async {
    memory.pokeRegisters(ModbusArea.holdingRegister, 0, [1, 1200, 0, 85]);
    expect(await client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 4), [1, 1200, 0, 85]);

    await client.fn06WriteSingleRegister(address: 50, value: 4321);
    expect(memory.register(ModbusArea.holdingRegister, 50), 4321);

    await client.fn05WriteSingleCoil(address: 5, value: true);
    expect((await client.fn01ReadCoils(startAddress: 0, count: 8))[5], isTrue);
  });

  test('endereço fora do mapa lança exceção tipada (não lista vazia)', () async {
    expect(
      client.fn03ReadHoldingRegisters(startAddress: 5000, quantity: 1),
      throwsA(isA<ModbusExceptionResponse>().having((e) => e.code, 'code', 2)),
    );
  });

  test('pedidos em paralelo são serializados e cada um recebe a sua resposta', () async {
    for (var i = 0; i < 50; i++) {
      memory.pokeRegister(ModbusArea.holdingRegister, i, i * 10);
    }
    final results = await Future.wait([
      for (var i = 0; i < 50; i++) client.fn03ReadHoldingRegisters(startAddress: i, quantity: 1),
    ]);
    for (var i = 0; i < 50; i++) {
      expect(results[i], [i * 10]);
    }
  });

  test('sem resposta vira ModbusTimeout e o próximo pedido funciona', () async {
    server.dropNextRequests = 1;
    await expectLater(
      client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 1),
      throwsA(isA<ModbusTimeout>()),
    );
    expect(await client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 1), [0]);
  });

  test('queda da conexão marca "lost" e o próximo pedido reconecta sozinho', () async {
    await server.closeAllClients();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(client.state.value, ModbusLinkState.lost);

    memory.pokeRegister(ModbusArea.holdingRegister, 0, 77);
    expect(await client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 1), [77]);
    expect(client.state.value, ModbusLinkState.connected);
  });

  test('desconexão manual não reconecta', () async {
    await client.disconnect();
    expect(client.state.value, ModbusLinkState.disconnected);
    expect(client.fn03ReadHoldingRegisters(startAddress: 0, quantity: 1),
        throwsA(isA<ModbusConnectionError>()));
  });

  test('IP sem equipamento vira ModbusConnectionError', () async {
    final dead = ModbusClientTcp(host: '127.0.0.1', port: 1, connectionTimeout: const Duration(milliseconds: 500));
    await expectLater(dead.connect(), throwsA(isA<ModbusConnectionError>()));
    expect(dead.state.value, ModbusLinkState.lost);
  });

  test('porta fechada num IP que existe = "recusou nesta porta" (não "sem conexão")', () async {
    // Porta livre de verdade: abre um servidor, anota a porta e fecha.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = probe.port;
    await probe.close();
    // 5 s: o Windows insiste ~2 s antes de devolver "recusado" (10061) numa
    // porta fechada do próprio PC; o Android responde na hora (111).
    final c = ModbusClientTcp(host: '127.0.0.1', port: closedPort, connectionTimeout: const Duration(seconds: 5));
    await expectLater(
      c.connect(),
      throwsA(isA<ModbusConnectionError>()
          .having((e) => e.refused, 'refused', isTrue)
          .having((e) => e.userMessage, 'userMessage', contains('recusou'))),
    );
  });
}
