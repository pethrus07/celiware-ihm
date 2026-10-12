import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/modbus/modbus_client.dart' show ModbusLinkState;
import 'package:ihm/core/opcua/opcua_binary.dart';
import 'package:ihm/core/opcua/opcua_client.dart';
import 'package:ihm/core/opcua/opcua_crypto.dart';
import 'package:ihm/core/opcua/opcua_error.dart';
import 'package:ihm/core/opcua/opcua_messages.dart';
import 'package:ihm/core/opcua/opcua_status.dart';
import 'package:ihm/core/opcua/opcua_types.dart';

import '../support/opcua_test_keys.dart';
import '../support/opcua_test_server.dart';

Uint8List hex(String h) => Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);
String toHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Horário fixo dos vetores (2026-10-12 12:00 UTC).
final DateTime t0 = DateTime.utc(2026, 10, 12, 12);

void main() {
  // Vetores gerados pelo asyncua 2.1.0 (implementação independente, Python),
  // com o NodeId na forma mais curta — a mesma que o cliente escolhe.
  group('codec com bytes conhecidos (asyncua 2.1.0)', () {
    test('Hello', () {
      final m = UaTcp.hello(endpointUrl: 'opc.tcp://127.0.0.1:4840');
      expect(toHex(m), '48454c46' '38000000' '00000000ffff0000ffff00000000000100000000180000006f70632e7463703a2f2f3132372e302e302e313a34383430');
      expect(m.length, 56);
    });

    test('NodeId nas seis formas, ida e volta', () {
      const vectors = {
        'i=85': '0055',
        'ns=2;i=1001': '0102e903',
        'ns=2;i=70000': '02020070110100',
        'ns=2;s=Maquina.Temperatura': '030200130000004d617175696e612e54656d7065726174757261',
        'ns=1;g=72962B91-FA75-4AE6-8D28-B404DC7DAF63': '040100912b967275fae64a8d28b404dc7daf63',
        'ns=1;b=AQID': '05010003000000010203',
        'i=70000': '02000070110100',
        'ns=300;i=5': '022c0105000000',
      };
      vectors.forEach((text, bytes) {
        final id = NodeId.parse(text);
        final w = UaWriter()..nodeId(id);
        expect(toHex(w.takeBytes()), bytes, reason: text);
        final back = UaReader(hex(bytes)).nodeId();
        expect(back, id, reason: text);
        expect(back.toString(), text);
      });
    });

    test('Variant: número, liga/desliga, texto, lista, texto com idioma', () {
      final vectors = <String, UaVariant>{
        '0b0000000000205240': const UaVariant(UaType.double, 72.5),
        '05dc05': const UaVariant(UaType.uint16, 1500),
        '0101': const UaVariant(UaType.boolean, true),
        '0c070000004c6f7465203432': const UaVariant(UaType.string, 'Lote 42'),
        '84030000000a001400e2ff': const UaVariant(UaType.int16, [10, 20, -30], isArray: true),
        '0a00005040': const UaVariant(UaType.float, 3.25),
        '08fbffffffffffffff': const UaVariant(UaType.int64, -5),
      };
      vectors.forEach((bytes, v) {
        expect(toHex((UaWriter()..variant(v)).takeBytes()), bytes, reason: '$v');
        final back = UaReader(hex(bytes)).variant();
        expect(back.type, v.type);
        expect(back.value, v.value);
        expect(back.isArray, v.isArray);
      });
      final lt = UaReader(hex('15030500000070742d4252060000004c6967616461')).variant();
      expect(lt.type, UaType.localizedText);
      expect((lt.value as LocalizedText).text, 'Ligada');
      expect((lt.value as LocalizedText).locale, 'pt-BR');
    });

    test('DataValue com horários e com StatusCode ruim', () {
      final dv = UaReader(hex('0f0b00000000002052400000000000e00635415add0100e00635415add01')).dataValue();
      expect(dv.value.value, 72.5);
      expect(dv.status, 0);
      expect(dv.sourceTimestamp, t0);
      expect(dv.serverTimestamp, t0);
      final bad = UaReader(hex('030000003480')).dataValue();
      expect(bad.value.isEmpty, isTrue);
      expect(bad.status, UaStatus.badNodeIdUnknown);
      expect((UaWriter()..dateTime(t0)).takeBytes(), hex('00e00635415add01'));
    });

    const token = NodeId.numeric(0, 0x1234);

    test('ReadRequest, WriteRequest (só o valor) e BrowseRequest byte a byte', () {
      final read = UaServices.read(
        handle: 7,
        now: t0,
        token: token,
        timeoutHint: 1500,
        nodes: [(NodeId.parse('ns=2;s=Maquina.Temperatura'), UaAttribute.value), (NodeId.parse('ns=2;i=1001'), UaAttribute.value)],
      );
      expect(toHex(read),
          '010077020100341200e00635415add010700000000000000ffffffffdc05000000000000000000000000000300000002000000030200130000004d617175696e612e54656d70657261747572610d000000ffffffff0000ffffffff0102e9030d000000ffffffff0000ffffffff');

      final write = UaServices.write(handle: 7, now: t0, token: token, timeoutHint: 1500, values: [(NodeId.parse('ns=2;s=Maquina.Velocidade'), const UaVariant(UaType.uint16, 1800))]);
      // DataValue com máscara 0x01: só o valor, sem StatusCode nem horário.
      expect(toHex(write), '0100a1020100341200e00635415add010700000000000000ffffffffdc05000000000001000000030200120000004d617175696e612e56656c6f6369646164650d000000ffffffff01050807');

      final browse = UaServices.browse(handle: 7, now: t0, token: token, timeoutHint: 1500, nodes: [NodeId.objectsFolder]);
      expect(toHex(browse),
          '01000f020100341200e00635415add010700000000000000ffffffffdc0500000000000000000000000000000000000000e803000001000000005500000000002101030000003f000000');
    });

    test('ReadResponse e BrowseResponse lidas', () {
      final r = UaServices.parse(hex(
          '01007a0200e00635415add0107000000000000000000000000000000030000000f0b00000000002052400000000000e00635415add0100e00635415add010300000034800384030000000a0014001e000000000000000000'));
      expect(r.typeId, UaTypeIds.readResponse);
      expect(r.header.requestHandle, 7);
      expect(r.header.timestamp, t0);
      final values = UaServices.parseRead(r.reader);
      expect(values.map((v) => v.status), [0, UaStatus.badNodeIdUnknown, 0]);
      expect(values[0].value.value, 72.5);
      expect(values[2].value.value, [10, 20, 30]);
      expect(r.reader.atEnd, isTrue);

      final b = UaServices.parse(hex(
          '0100120200e00635415add0109000000000000000000000000000000010000000000000002000000010201000000002f01030200130000004d617175696e612e54656d706572617475726102000b00000054656d7065726174757261020b00000054656d706572617475726102000000003f00000000'));
      final result = UaServices.parseBrowse(b.reader).single;
      expect(result.continuationPoint, [1, 2]);
      final ref = result.references.single;
      expect(ref.nodeId, NodeId.parse('ns=2;s=Maquina.Temperatura'));
      expect(ref.nodeClass, UaNodeClass.variable);
      expect(ref.name, 'Temperatura');
      expect(ref.browseName.toString(), '2:Temperatura');
      expect(ref.referenceTypeId, const NodeId.numeric(0, 47));
      expect(ref.typeDefinition, const NodeId.numeric(0, 63));
    });

    test('pedaços de MSG: corpo dividido, sequência crescendo, último "F"', () {
      var seq = 10;
      final chunks = UaTcp.messageChunks('MSG', channelId: 5, tokenId: 6, requestId: 7, body: List.filled(100, 0xAB), nextSequence: () => seq++, maxChunkSize: 64);
      expect(chunks.length, 3, reason: '40 bytes de corpo por pedaço de 64');
      expect(chunks.map((c) => String.fromCharCode(c[3])), ['C', 'C', 'F']);
      final parsed = chunks.map(UaTcp.parseChunk).toList();
      expect(parsed.map((c) => c.sequence), [10, 11, 12]);
      expect(parsed.every((c) => c.channelId == 5 && c.tokenId == 6 && c.requestId == 7), isTrue);
      expect(parsed.expand((c) => c.body).length, 100);
    });

    test('mensagem cortada vira FormatException, não lixo', () {
      expect(() => UaReader(hex('0c07000000414243')).variant(), throwsFormatException);
      expect(() => UaReader(hex('ffffff7f')).array(() => 0), throwsFormatException);
    });
  });

  group('NodeId em texto', () {
    test('formas da norma e a do S7-1500', () {
      expect(NodeId.parse('ns=2;s=Maquina.Temperatura'), const NodeId.string(2, 'Maquina.Temperatura'));
      expect(NodeId.parse(' ns=3;i=1001 '), const NodeId.numeric(3, 1001));
      expect(NodeId.parse('i=2258'), const NodeId.numeric(0, 2258));
      expect(NodeId.parse('ns=3;s="DB1"."Velocidade"').identifier, '"DB1"."Velocidade"');
      expect(NodeId.parse('ns=2;s=a;b').identifier, 'a;b', reason: 'o ";" depois do s= é do nome');
      expect(NodeId.parse('NS=2;S=Temp'), const NodeId.string(2, 'Temp'));
      expect(NodeId.parse('ns=0;i=85').toString(), 'i=85');
      expect(NodeId.parse('ns=1;g=72962b91-fa75-4ae6-8d28-b404dc7daf63').toString(), 'ns=1;g=72962B91-FA75-4AE6-8D28-B404DC7DAF63');
    });

    test('erros curtos, em português', () {
      String err(String t) {
        try {
          NodeId.parse(t);
          return 'aceitou';
        } on FormatException catch (e) {
          return e.message;
        }
      }

      expect(err(''), 'Informe o NodeId (ex.: ns=2;s=Maquina.Temperatura)');
      expect(err('ns=2;Temperatura'), contains('falta o tipo do identificador'));
      expect(err('ns=70000;i=1'), 'o namespace (ns=) vai de 0 a 65535');
      expect(err('ns=2;i=abc'), 'i= pede um número inteiro (ex.: ns=2;i=1001)');
      expect(err('ns=2'), contains('falta o ";"'));
      expect(err('nsu=urn:x;s=a'), contains('nsu='));
      expect(err('ns=1;g=xyz'), contains('GUID'));
      expect(err('ns=2;s='), 's= pede um nome (ex.: ns=2;s=Temperatura)');
    });
  });

  group('senha cifrada com o certificado (RSA-OAEP, SHA-1)', () {
    test('SHA-1 com vetores da FIPS 180', () {
      expect(toHex(Sha1.hash(utf8.encode('abc'))), 'a9993e364706816aba3e25717850c26c9cd0d89d');
      expect(toHex(Sha1.hash(const [])), 'da39a3ee5e6b4b0d3255bfef95601890afd80709');
      expect(toHex(Sha1.hash(utf8.encode('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))), '84983e441c3bd26ebaae4aa1f95129e5e54670f1');
      expect(toHex(Sha1.hash(List.filled(1000, 0x61))), '291e9a6c66994949b57ba5e650361e98fc36b1ba');
    });

    test('chave pública tirada do certificado X.509', () {
      final key = RsaPublicKey.fromCertificate(hex(opcUaTestCertificate));
      expect(key.modulus, BigInt.parse(opcUaTestModulus, radix: 16));
      expect(key.exponent, BigInt.from(65537));
      expect(key.size, 256);
      expect(() => RsaPublicKey.fromCertificate(hex('3003020101')), throwsFormatException);
    });

    test('formato da senha e cifra conferidos contra a Python (cryptography)', () {
      // O servidor de teste decifra o que a Python cifrou: o lado que decifra
      // está certo; daí o que o cliente cifra precisa voltar igual.
      final nonce = Uint8List.fromList(utf8.encode('0123456789'));
      expect(OpcUaTestServer.decryptPasswordWith(hex(opcUaTestCiphertext), nonce), '1234');
      expect(uaPasswordSecret('1234', nonce), [14, 0, 0, 0, ...utf8.encode('1234'), ...nonce]);

      final key = RsaPublicKey.fromCertificate(hex(opcUaTestCertificate));
      final c = key.encryptOaep(uaPasswordSecret('senha forte', nonce), random: Random(1));
      expect(c.length, 256);
      expect(OpcUaTestServer.decryptPasswordWith(c, nonce), 'senha forte');
      // Duas cifras do mesmo texto saem diferentes (semente aleatória).
      expect(toHex(key.encryptOaep(uaPasswordSecret('x', nonce))), isNot(toHex(key.encryptOaep(uaPasswordSecret('x', nonce)))));
      // Texto maior que um bloco (214 bytes) vai em dois blocos.
      final long = 'a' * 300;
      final c2 = key.encryptOaep(uaPasswordSecret(long, nonce));
      expect(c2.length, 512);
      expect(OpcUaTestServer.decryptPasswordWith(c2, nonce), long);
    });
  });

  group('cliente × servidor por socket real', () {
    late OpcUaTestServer server;
    final clients = <OpcUaClient>[];

    OpcUaClient client({String user = '', String pass = '', Duration timeout = const Duration(seconds: 1), String? path}) {
      final c = OpcUaClient(host: '127.0.0.1', port: server.port, path: path ?? server.path, username: user, password: pass, responseTimeout: timeout);
      clients.add(c);
      return c;
    }

    setUp(() async {
      server = OpcUaTestServer();
      server.add(TestUaNode('ns=2;s=Maquina', 'Maquina', isFolder: true));
      server.add(TestUaNode('ns=2;s=Maquina.Temperatura', 'Temperatura', type: 11, value: 72.5), parent: 'ns=2;s=Maquina');
      server.add(TestUaNode('ns=2;s=Maquina.Velocidade', 'Velocidade', type: 5, value: 1500, writable: true), parent: 'ns=2;s=Maquina');
      server.add(TestUaNode('ns=2;i=1001', 'Ajuste', type: 10, value: 3.25, writable: true), parent: 'ns=2;s=Maquina');
      server.add(TestUaNode('ns=2;s=Maquina.Producao', 'Producao', type: 4, value: [10, 20, 30], isArray: true), parent: 'ns=2;s=Maquina');
      await server.start();
    });

    tearDown(() async {
      for (final c in clients) {
        await c.dispose();
      }
      clients.clear();
      await server.stop();
    });

    test('anônimo: conecta, lê vários nós num pedido, grava e navega', () async {
      final c = client();
      await c.connect();
      expect(c.state.value, ModbusLinkState.connected);
      expect(server.sessionsCreated, 1);
      final values = await c.read([
        NodeId.parse('ns=2;s=Maquina.Temperatura'),
        NodeId.parse('ns=2;s=Maquina.Velocidade'),
        NodeId.parse('ns=2;i=1001'),
        NodeId.parse('ns=2;s=Maquina.Producao'),
        NodeId.parse('ns=2;s=Nada'),
      ]);
      expect(values.map((v) => v.value.value), [72.5, 1500, 3.25, [10, 20, 30], null]);
      expect(values.last.status, UaStatus.badNodeIdUnknown, reason: 'nó errado não derruba os outros');
      expect(server.readNodeCounts.last, 5);

      final codes = await c.write([(NodeId.parse('ns=2;s=Maquina.Velocidade'), const UaVariant(UaType.uint16, 1800))]);
      expect(codes, [0]);
      expect(server.node('ns=2;s=Maquina.Velocidade').value, 1800);
      expect(await c.write([(NodeId.parse('ns=2;s=Maquina.Temperatura'), const UaVariant(UaType.double, 1))]), [UaStatus.badNotWritable]);

      final top = await c.browse(NodeId.objectsFolder);
      expect(top.map((r) => r.name), ['Server', 'Maquina']);
      final kids = await c.browse(NodeId.parse('ns=2;s=Maquina'));
      expect(kids.map((r) => (r.name, r.nodeClass)), [
        ('Temperatura', UaNodeClass.variable),
        ('Velocidade', UaNodeClass.variable),
        ('Ajuste', UaNodeClass.variable),
        ('Producao', UaNodeClass.variable),
      ]);
      expect(kids[2].nodeId, const NodeId.numeric(2, 1001));
      await expectLater(c.browse(NodeId.parse('ns=2;s=Nada')), throwsA(isA<OpcUaNodeError>().having((e) => e.userMessage, 'm', 'nó inexistente: ns=2;s=Nada')));

      await c.disconnect();
      // O cliente não espera a resposta do CloseSession: o servidor processa
      // logo depois.
      for (var i = 0; i < 100 && (server.closedSessions == 0 || server.clientCount > 0); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(server.closedSessions, 1, reason: 'sair avisa o servidor (CloseSession)');
      expect(server.clientCount, 0, reason: 'e fecha o canal (CLO)');
      expect(c.state.value, ModbusLinkState.disconnected);
    });

    test('usuário e senha: certo entra, errado é "o servidor recusou o usuário"', () async {
      server.allowAnonymous = false;
      await expectLater(client().connect(), throwsA(isA<OpcUaAuthError>().having((e) => e.userMessage, 'm', OpcUaHint.needsUser)));
      final wrong = client(user: 'operador', pass: '9999');
      await expectLater(
          wrong.connect(),
          throwsA(isA<OpcUaAuthError>()
              .having((e) => e.userMessage, 'm', OpcUaHint.user)
              .having((e) => e.refused, 'refused', isTrue)));
      expect(server.lastPasswordWasEncrypted, isFalse, reason: 'o token pede a senha como está');
      final ok = client(user: 'operador', pass: '1234');
      await ok.connect();
      expect(server.lastPassword, '1234');
      expect((await ok.read([NodeId.parse('ns=2;s=Maquina.Temperatura')])).single.value.value, 72.5);
    });

    test('servidor que pede a senha cifrada: vai com RSA-OAEP e o nonce da sessão', () async {
      server.passwordEncrypted = true;
      final c = client(user: 'operador', pass: 'çã1234');
      server.users['operador'] = 'çã1234';
      await c.connect();
      expect(server.lastPasswordWasEncrypted, isTrue);
      expect(server.lastPassword, 'çã1234');
      server.users['operador'] = 'outra';
      await expectLater(client(user: 'operador', pass: 'çã1234').connect(), throwsA(isA<OpcUaAuthError>()));
    });

    test('só endpoint seguro: recusa dizendo o que o servidor exige', () async {
      server.onlySecureEndpoints = true;
      await expectLater(
          client().connect(),
          throwsA(isA<OpcUaSecurityRequired>()
              .having((e) => e.userMessage, 'm', OpcUaHint.security)
              .having((e) => e.offered, 'offered', ['Basic256Sha256 · SignAndEncrypt'])));
    });

    test('caminho errado: o servidor manda ERR e a mensagem fala do endpoint', () async {
      server.strictPath = true;
      await expectLater(
          client(path: '/outro').connect(),
          throwsA(isA<OpcUaConnectionError>()
              .having((e) => e.userMessage, 'm', OpcUaHint.endpoint)
              .having((e) => e.refused, 'refused', isTrue)));
      await client().connect();
    });

    test('resposta em vários pedaços e navegação com ponto de continuação', () async {
      for (var i = 0; i < 40; i++) {
        server.add(TestUaNode('ns=2;s=Linha.S$i', 'Sensor $i', type: 10, value: i.toDouble()), parent: 'ns=2;s=Maquina');
      }
      server.chunkSize = 200;
      server.maxReferencesPerBrowse = 7;
      final c = client();
      await c.connect();
      final kids = await c.browse(NodeId.parse('ns=2;s=Maquina'));
      expect(kids.length, 44);
      expect(server.browseNextRequests, 6, reason: '44 referências de 7 em 7');
      final values = await c.read([for (var i = 0; i < 40; i++) NodeId.parse('ns=2;s=Linha.S$i')]);
      expect(values.map((v) => v.value.value), [for (var i = 0; i < 40; i++) i.toDouble()]);
      expect(c.partialChunks, greaterThan(0), reason: 'as respostas vieram em pedaços');
    });

    test('limite de nós por leitura do servidor (OperationLimits) divide o pedido', () async {
      server.maxNodesPerRead = 2;
      final c = client();
      await c.connect();
      expect(c.maxNodesPerCall, 2);
      server.readNodeCounts.clear();
      final values = await c.read(List.filled(5, NodeId.parse('ns=2;s=Maquina.Temperatura')));
      expect(values.length, 5);
      expect(server.readNodeCounts, [2, 2, 1]);
    });

    test('canal renovado aos 75% da vida, sem cair', () async {
      server.channelLifetimeMs = 400;
      final c = client();
      await c.connect();
      for (var i = 0; i < 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await c.read([NodeId.parse('ns=2;s=Maquina.Temperatura')]);
      }
      expect(server.renewals, greaterThanOrEqualTo(1));
      expect(server.sessionsCreated, 1);
    });

    test('sessão esquecida pelo servidor: reabre e repete o pedido uma vez', () async {
      final c = client();
      await c.connect();
      server.forgetSessions();
      final v = await c.read([NodeId.parse('ns=2;s=Maquina.Temperatura')]);
      expect(v.single.value.value, 72.5);
      expect(server.sessionsCreated, 2);
      expect(c.sessions, 2);
    });

    test('tempo esgotado, resposta atrasada descartada; queda e reconexão sozinha', () async {
      final c = client(timeout: const Duration(milliseconds: 300));
      await c.connect();
      server.dropNextRequests = 1;
      await expectLater(c.read([NodeId.parse('ns=2;s=Maquina.Temperatura')]), throwsA(isA<OpcUaTimeout>()));
      expect((await c.read([NodeId.parse('ns=2;s=Maquina.Temperatura')])).single.value.value, 72.5);

      server.responseDelay = const Duration(milliseconds: 500);
      await expectLater(c.read([NodeId.parse('ns=2;s=Maquina.Temperatura')]), throwsA(isA<OpcUaTimeout>()));
      server.responseDelay = Duration.zero;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect((await c.read([NodeId.parse('ns=2;s=Maquina.Velocidade')])).single.value.value, 1500, reason: 'a resposta atrasada não se confunde com a nova');

      await server.closeAllClients();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(c.state.value, ModbusLinkState.lost);
      expect((await c.read([NodeId.parse('ns=2;s=Maquina.Temperatura')])).single.value.value, 72.5);
      expect(c.state.value, ModbusLinkState.connected);
      expect(server.sessionsCreated, 2);
    });

    test('desconexão pedida não reconecta; porta fechada é "recusou nesta porta"', () async {
      final c = client();
      await c.connect();
      await c.disconnect();
      await expectLater(c.read([NodeId.parse('i=2259')]), throwsA(isA<OpcUaConnectionError>()));

      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final closed = probe.port;
      await probe.close();
      final dead = OpcUaClient(host: '127.0.0.1', port: closed);
      clients.add(dead);
      await expectLater(
          dead.connect(),
          throwsA(isA<OpcUaConnectionError>()
              .having((e) => e.refused, 'refused', isTrue)
              .having((e) => e.userMessage, 'm', 'o servidor recusou a conexão nesta porta')));
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('ping lê o estado do servidor; caminho normalizado', () async {
      final c = client();
      await c.ping();
      expect(c.isConnected, isTrue);
      expect(OpcUaClient.normalizePath('OPCUA/Sim'), '/OPCUA/Sim');
      expect(OpcUaClient.normalizePath(' / '), '');
      expect(OpcUaClient(host: '10.0.0.5', path: 'x').endpointUrl, 'opc.tcp://10.0.0.5:4840/x');
    });
  });
}
