import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/core/opcua/opcua_types.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/opcua_config.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/screens/devices/device_form_page.dart';
import 'package:ihm/screens/tags/opcua_tag_fields.dart';
import 'package:ihm/screens/tags/tag_form_page.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/opcua_test_server.dart';

/// Cadastro de equipamento e de variável quando o equipamento é um servidor
/// OPC UA: caminho, usuário e senha no lugar do ID do escravo, NodeId no
/// lugar do endereço Modbus, "Navegar e escolher", e o "Testar conexão" e o
/// "Lendo agora" contra o servidor de teste, por socket de verdade.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      for (final (id, _, _) in Tours.catalog) 'tour:v1:$id': true,
    });
    dir = await Directory.systemTemp.createTemp('ihm_opcua_form');
  });

  tearDown(() async {
    DemoRegistry.discard(DemoProject.deviceId);
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {/* Windows ainda segurando o arquivo */}
  });

  Future<ProjectController> boot(WidgetTester tester) async {
    final runtime = HmiRuntime();
    final c = ProjectController(repository: ProjectRepository(directory: dir), runtime: runtime);
    await tester.runAsync(c.load);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CeliwareIhmApp(controller: c, runtime: runtime));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    return c;
  }

  Future<void> shutdown(WidgetTester tester, ProjectController c) async {
    await tester.pumpWidget(const SizedBox());
    final done = c.runtime.dispose();
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await done;
    c.dispose();
  }

  /// Rede no relógio real (runAsync), tela no simulado (pump), alternando até
  /// [finder] aparecer.
  Future<void> waitFor(WidgetTester tester, Finder finder, {int rounds = 80, Duration step = const Duration(milliseconds: 20)}) async {
    for (var i = 0; i < rounds && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(step);
    }
    expect(finder, findsWidgets);
  }

  OpcUaTestServer machine() {
    final s = OpcUaTestServer();
    s.add(TestUaNode('ns=2;s=Maquina', 'Maquina', isFolder: true));
    s.add(TestUaNode('ns=2;s=Maquina.Temperatura', 'Temperatura', type: 11, value: 72.5), parent: 'ns=2;s=Maquina');
    s.add(TestUaNode('ns=2;s=Maquina.Velocidade', 'Velocidade', type: 5, value: 1500, writable: true), parent: 'ns=2;s=Maquina');
    return s;
  }

  testWidgets('equipamento OPC UA: protocolo em Mais opções, porta 4840, caminho, usuário e a segurança dita na tela', (tester) async {
    final c = await boot(tester);
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute<void>(builder: (_) => const DeviceFormPage()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('campo-nome-equipamento')), 'Linha 2');
    // O formulário cresceu (cartão Cabo USB): rolar antes, o Salvar cobre o pé.
    await tester.ensureVisible(find.text('Mais opções'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mais opções'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('protocolo-opcua')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('protocolo-opcua')));
    await tester.pumpAndSettle();
    expect(find.text('ID do escravo'), findsNothing, reason: 'OPC UA não tem ID do escravo');
    expect(find.text('Marca e modelo'), findsNothing);
    expect(find.text('OPC UA · Porta 4840 · anônimo'), findsOneWidget, reason: 'a porta padrão troca junto com o protocolo');
    expect(find.byKey(const ValueKey('opcua-seguranca')), findsOneWidget);
    expect(find.textContaining('ainda não faz Sign nem SignAndEncrypt'), findsOneWidget);
    expect(find.byKey(const ValueKey('campo-senha-opcua')), findsNothing, reason: 'sem usuário, sem senha');

    // O endereço inteiro colado no campo do IP vira IP, porta e caminho.
    await tester.drag(find.byType(ListView).last, const Offset(0, 3000));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'IP do servidor'), 'opc.tcp://192.168.0.70:49320/Kepware');
    await tester.pumpAndSettle();
    expect(find.text('OPC UA · Porta 49320 · /Kepware · anônimo'), findsOneWidget);
    expect(tester.widget<TextFormField>(find.widgetWithText(TextFormField, 'IP do servidor')).controller!.text, '192.168.0.70');

    await tester.ensureVisible(find.byKey(const ValueKey('campo-usuario-opcua')));
    await tester.enterText(find.byKey(const ValueKey('campo-usuario-opcua')), 'operador');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('campo-senha-opcua')));
    await tester.enterText(find.byKey(const ValueKey('campo-senha-opcua')), '1234');
    await tester.pumpAndSettle();
    expect(find.text('Endereço: opc.tcp://192.168.0.70:49320/Kepware'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('salvar-equipamento')));
    await tester.pumpAndSettle();
    final d = c.project.devices.last;
    expect(d.kind, DeviceKind.opcua);
    expect((d.host, d.port), ('192.168.0.70', 49320));
    expect(d.opcua, const OpcUaConfig(path: '/Kepware', username: 'operador', password: '1234'));
    expect(d.profile, isNull);

    // Reaberto e voltando ao Modbus: 502 e ID de volta; sem salvar, nada muda.
    nav.push(MaterialPageRoute<void>(builder: (_) => DeviceFormPage(device: d)));
    await tester.pumpAndSettle();
    expect(find.text('OPC UA · Porta 49320 · /Kepware · operador'), findsOneWidget);
    // O formulário cresceu (cartão Cabo USB): rolar antes, o Salvar cobre o pé.
    await tester.ensureVisible(find.text('Mais opções'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mais opções'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('protocolo-tcp')));
    await tester.tap(find.byKey(const ValueKey('protocolo-tcp')));
    await tester.pumpAndSettle();
    expect(find.text('Modbus TCP · Porta 49320 · ID 1'), findsOneWidget, reason: 'porta mexida à mão fica');
    nav.pop();
    await tester.pumpAndSettle();
    expect(c.project.devices.last.kind, DeviceKind.opcua);
    await shutdown(tester, c);
  });

  testWidgets('testar conexão: usuário errado mostra o que conferir; certo, "Servidor respondeu"', (tester) async {
    final server = machine()..allowAnonymous = false;
    await tester.runAsync(server.start);
    final c = await boot(tester);
    final d = Device(
        id: 'srv', name: 'Linha', kind: DeviceKind.opcua, host: '127.0.0.1', port: server.port, timeoutMs: 5000, opcua: OpcUaConfig(path: server.path, username: 'operador', password: 'errada'));
    c.saveDevice(d);
    await tester.pump();
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute<void>(builder: (_) => DeviceFormPage(device: d)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('testar-conexao')));
    await waitFor(tester, find.byKey(const ValueKey('teste-falhou')));
    await tester.pumpAndSettle();
    expect(find.text('Não conectou: o servidor recusou o usuário'), findsOneWidget);
    expect(find.text('O servidor está na rede, mas não aceitou:'), findsOneWidget, reason: 'achou o servidor: nada de conferir Wi-Fi');
    expect(find.textContaining('Maiúsculas contam'), findsOneWidget);
    expect(find.byKey(const ValueKey('teste-dica')), findsNothing);

    // O formulário cresceu (cartão Cabo USB): rolar antes, o Salvar cobre o pé.
    await tester.ensureVisible(find.text('Mais opções'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mais opções'));
    await tester.pumpAndSettle();
    final list = find.descendant(of: find.byType(Form), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.byKey(const ValueKey('campo-senha-opcua')), 300, scrollable: list);
    await tester.enterText(find.byKey(const ValueKey('campo-senha-opcua')), '1234');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('testar-conexao')), -300, scrollable: list);
    await tester.tap(find.byKey(const ValueKey('testar-conexao')));
    await waitFor(tester, find.byKey(const ValueKey('teste-ok')));
    expect(find.textContaining('Servidor respondeu'), findsOneWidget);

    nav.pop();
    await tester.pumpAndSettle();
    await shutdown(tester, c);
    await tester.runAsync(server.stop);
  });

  testWidgets('variável OPC UA: NodeId no lugar do Modbus, erro curto, "Navegar e escolher" e "lendo agora"', (tester) async {
    final server = machine();
    await tester.runAsync(server.start);
    final c = await boot(tester);
    final d = Device(id: 'srv', name: 'Linha', kind: DeviceKind.opcua, host: '127.0.0.1', port: server.port, timeoutMs: 5000, opcua: OpcUaConfig(path: server.path));
    c.saveDevice(d);
    await tester.pump();
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute<void>(builder: (_) => const TagFormPage(preferDeviceId: 'srv')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('campo-endereco')), findsNothing, reason: 'endereço Modbus dá lugar ao NodeId');
    expect(find.byKey(const ValueKey('campo-nodeid')), findsOneWidget);
    expect(find.text('Complete o NodeId'), findsOneWidget);
    final form = find.descendant(of: find.byKey(const ValueKey('formulario-variavel')), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('Mais opções'), 200, scrollable: form);
    await tester.tap(find.text('Mais opções'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('endereco-hex')), findsNothing);
    expect(find.text('Ordem dos bytes'), findsNothing, reason: 'o servidor diz o tipo; não há registrador');
    expect(find.byKey(const ValueKey('formato-int16')), findsNothing);
    expect(find.byKey(const ValueKey('formato-string')), findsOneWidget, reason: 'dos formatos raros só sobra texto');
    await tester.scrollUntilVisible(find.byKey(const ValueKey('campo-nodeid')), -200, scrollable: form);

    await tester.enterText(find.byKey(const ValueKey('campo-nodeid')), 'ns=2;Temperatura');
    await tester.pump();
    expect(find.textContaining('falta o tipo do identificador'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('campo-nodeid')), 'ns=2;s=Maquina.Nada');
    await tester.pump();
    expect(find.text('namespace 2, nome Maquina.Nada'), findsOneWidget);
    await waitFor(tester, find.text('Nó inexistente: ns=2;s=Maquina.Nada'), rounds: 80, step: const Duration(milliseconds: 100));

    // Navegar: Objects → Maquina → Temperatura preenche NodeId, nome e tipo.
    await tester.tap(find.byKey(const ValueKey('navegar-opcua')));
    await tester.pump();
    await waitFor(tester, find.byKey(const ValueKey('no-ns=2;s=Maquina')));
    await tester.pumpAndSettle();
    expect(find.text('Server'), findsNothing, reason: 'objeto do próprio servidor fica de fora');
    await tester.tap(find.byKey(const ValueKey('no-ns=2;s=Maquina')));
    await tester.pump();
    await waitFor(tester, find.byKey(const ValueKey('no-ns=2;s=Maquina.Temperatura')));
    await tester.pumpAndSettle();
    expect(find.text('72,5 · Double'), findsOneWidget);
    expect(find.text('Objects › Maquina'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('no-ns=2;s=Maquina.Temperatura')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('campo-nodeid'))).controller!.text, 'ns=2;s=Maquina.Temperatura');
    await waitFor(tester, find.text('72,5'), rounds: 80, step: const Duration(milliseconds: 100));

    await tester.tap(find.byKey(const ValueKey('salvar-variavel')));
    await tester.pumpAndSettle();
    final t = c.project.tags.last;
    expect(t.deviceId, 'srv');
    expect(t.name, 'Temperatura', reason: 'nome de partida vem do nó');
    expect(t.opcua, const OpcUaTagAddress('ns=2;s=Maquina.Temperatura'));
    expect(t.dataType, TagDataType.float32);
    expect(t.decimals, 1, reason: 'casas do valor visto (72,5)');
    expect(t.writable, isFalse, reason: 'nó só leitura no servidor');
    expect((t.area, t.address), (ModbusArea.holdingRegister, 0));
    expect(t.addressLabel, 'ns=2;s=Maquina.Temperatura');

    // Fechar a sessão OPC UA passa pelo CloseSession antes de largar o
    // socket: com a máquina carregada leva mais que uns poucos quadros.
    for (var i = 0; i < 100 && server.clientCount > 0; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(server.clientCount, 0, reason: 'fechar o cadastro e a navegação solta o servidor');
    expect(server.closedSessions, greaterThanOrEqualTo(2), reason: 'as duas sessões (lendo agora e navegação) avisaram o servidor');
    await shutdown(tester, c);
    await tester.runAsync(server.stop);
  });

  test('prova do NodeId e erro (funções puras)', () {
    expect(OpcUaTagFields.proof(NodeId.parse('ns=3;i=1001')), 'namespace 3, número 1001');
    expect(OpcUaTagFields.proof(NodeId.parse('i=2258')), 'namespace 0 (do próprio servidor), número 2258');
    expect(OpcUaTagFields.proof(NodeId.parse('ns=3;s="DB1"."Velocidade"')), 'namespace 3, nome "DB1"."Velocidade"');
    final f = OpcUaTagFields(const OpcUaTagAddress(' NS=2; s=Temp '));
    expect(f.error(), isNull);
    expect(f.build(), const OpcUaTagAddress('ns=2;s=Temp'));
    f.nodeId.text = '';
    expect(f.error(), 'Informe o NodeId (ex.: ns=2;s=Maquina.Temperatura)');
    f.dispose();
    const pick = OpcUaPick(nodeId: 'ns=2;s=a', name: 'velocidade_faca', type: TagDataType.uint16, writable: true);
    expect(pick.suggestedName, 'Velocidade faca');
  });
}
