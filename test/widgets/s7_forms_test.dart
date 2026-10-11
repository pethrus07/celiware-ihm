import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/core/s7/s7_address.dart';
import 'package:ihm/core/s7/s7_codec.dart';
import 'package:ihm/core/s7/s7_test_server.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/s7_config.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/screens/devices/device_form_page.dart';
import 'package:ihm/screens/tags/s7_tag_fields.dart';
import 'package:ihm/screens/tags/tag_form_page.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:ihm/widgets/hmi/element_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cadastro de equipamento e de variável quando o equipamento é um CLP
/// Siemens S7: família do CLP no lugar do ID do escravo, endereço do TIA no
/// lugar do endereço Modbus, e o "Testar conexão" e o "Lendo agora" contra o
/// CLP de teste, por socket de verdade.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      for (final (id, _, _) in Tours.catalog) 'tour:v1:$id': true,
    });
    dir = await Directory.systemTemp.createTemp('ihm_s7_form');
  });

  tearDown(() async {
    DemoRegistry.discard(DemoProject.deviceId);
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {/* Windows ainda segurando o arquivo */}
  });

  /// App com o projeto de demonstração; devolve o controlador.
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

  /// Encerra app e runtime dentro do teste; 2,5 s de relógio esvaziam os
  /// prazos de conexão que tenham ficado pendentes.
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
  Future<void> waitFor(WidgetTester tester, Finder finder, {int rounds = 60, Duration step = const Duration(milliseconds: 20)}) async {
    for (var i = 0; i < rounds && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(step);
    }
    expect(finder, findsWidgets);
  }

  testWidgets('equipamento S7: protocolo em Mais opções, família do CLP no lugar do ID; "Outro" mostra rack e slot', (tester) async {
    final c = await boot(tester);
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);

    nav.push(MaterialPageRoute<void>(builder: (_) => const DeviceFormPage()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('campo-nome-equipamento')), 'Prensa');
    await tester.enterText(find.widgetWithText(TextFormField, 'IP do equipamento'), '192.168.0.60');
    await tester.tap(find.text('Mais opções'));
    await tester.pumpAndSettle();
    expect(find.text('Marca e modelo'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('protocolo-s7')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('protocolo-s7')));
    await tester.pumpAndSettle();
    expect(find.text('ID do escravo'), findsNothing, reason: 'S7 não tem ID do escravo');
    expect(find.text('Marca e modelo'), findsNothing, reason: 'perfil de fabricante é mapa Modbus');
    expect(find.text('S7-1200/1500 · Porta 102'), findsOneWidget, reason: 'porta padrão troca junto com o protocolo');
    expect(find.text('Rack 0, slot 1'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('s7-familia-s7300')));
    await tester.tap(find.byKey(const ValueKey('s7-familia-s7300')));
    await tester.pumpAndSettle();
    expect(find.text('S7-300 · Porta 102'), findsOneWidget);
    expect(find.text('Rack 0, slot 2'), findsOneWidget);
    expect(find.byKey(const ValueKey('campo-slot')), findsNothing, reason: 'rack e slot só em "Outro"');

    await tester.tap(find.byKey(const ValueKey('s7-familia-other')));
    await tester.pumpAndSettle();
    expect(find.text('S7 · rack 0 · slot 2 · Porta 102'), findsOneWidget, reason: '"Outro" começa da família escolhida');
    await tester.ensureVisible(find.byKey(const ValueKey('campo-slot')));
    await tester.enterText(find.byKey(const ValueKey('campo-slot')), '4');
    await tester.pumpAndSettle();
    expect(find.text('S7 · rack 0 · slot 4 · Porta 102'), findsOneWidget);
    await tester.drag(find.byType(ListView).last, const Offset(0, 3000));
    await tester.pumpAndSettle();
    expect(find.text('IP do CLP'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('salvar-equipamento')));
    await tester.pumpAndSettle();
    final d = c.project.devices.last;
    expect(d.kind, DeviceKind.s7);
    expect(d.port, S7Config.defaultPort);
    expect(d.s7, const S7Config(family: S7Family.other, slot: 4));
    expect(d.profile, isNull);
    expect(d.addressLabel, '192.168.0.60:102 · S7 · rack 0 · slot 4');

    // Reaberto, mostra o que foi salvo; voltar ao Modbus devolve a 502 e o ID.
    nav.push(MaterialPageRoute<void>(builder: (_) => DeviceFormPage(device: d)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mais opções'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('campo-slot'))).controller!.text, '4');
    await tester.ensureVisible(find.byKey(const ValueKey('protocolo-tcp')));
    await tester.tap(find.byKey(const ValueKey('protocolo-tcp')));
    await tester.pumpAndSettle();
    expect(find.text('Modbus TCP · Porta 502 · ID 1'), findsOneWidget);
    nav.pop();
    await tester.pumpAndSettle();
    expect(c.project.devices.last.kind, DeviceKind.s7, reason: 'sem salvar, nada muda');
    await shutdown(tester, c);
  });

  testWidgets('testar conexão com o CLP: PUT/GET desligado mostra o passo a passo do TIA; habilitado, responde', (tester) async {
    final memory = S7Memory()..addDb(1, 10);
    final server = S7TestServer(memory)..refuseJobs = true;
    await tester.runAsync(server.start);
    final c = await boot(tester);
    final d = Device(id: 'clp', name: 'Prensa', kind: DeviceKind.s7, host: '127.0.0.1', port: server.port, timeoutMs: 5000);
    c.saveDevice(d);
    await tester.pump();
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute<void>(builder: (_) => DeviceFormPage(device: d)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('testar-conexao')));
    await waitFor(tester, find.byKey(const ValueKey('teste-falhou')));
    await tester.pumpAndSettle();
    expect(find.text('O CLP está na rede, mas não aceitou:'), findsOneWidget, reason: 'achou o CLP: nada de conferir Wi-Fi');
    expect(find.textContaining('Permitir acesso com comunicação PUT/GET'), findsOneWidget);
    expect(find.textContaining('Acesso otimizado ao bloco'), findsOneWidget);
    expect(find.byKey(const ValueKey('teste-dica')), findsNothing);

    server.refuseJobs = false;
    await tester.ensureVisible(find.byKey(const ValueKey('testar-conexao')));
    await tester.tap(find.byKey(const ValueKey('testar-conexao')));
    await waitFor(tester, find.byKey(const ValueKey('teste-ok')));
    expect(find.textContaining('CLP respondeu'), findsOneWidget);

    nav.pop();
    await tester.pumpAndSettle();
    await shutdown(tester, c);
    await tester.runAsync(server.stop);
  });

  testWidgets('variável S7: endereço do TIA no lugar do Modbus, tipo pelo tamanho, prova da leitura e "lendo agora"', (tester) async {
    final memory = S7Memory()..addDb(1, 20);
    memory.poke(S7Address.parse('DB1.DBD8'), S7Codec.encode(S7Type.real, 1234));
    final server = S7TestServer(memory, pduSize: 240);
    await tester.runAsync(server.start);
    final c = await boot(tester);
    final d = Device(id: 'clp', name: 'Prensa', kind: DeviceKind.s7, host: '127.0.0.1', port: server.port, timeoutMs: 5000);
    c.saveDevice(d);
    await tester.pump();
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute<void>(builder: (_) => const TagFormPage(preferDeviceId: 'clp')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('campo-endereco')), findsNothing, reason: 'endereço Modbus dá lugar ao do TIA');
    expect(find.byKey(const ValueKey('campo-endereco-s7')), findsOneWidget);
    expect(find.text('Complete o endereço do CLP'), findsOneWidget);
    // A lista do formulário (a "Observação", de duas linhas, tem rolagem própria).
    final form = find.descendant(of: find.byKey(const ValueKey('formulario-variavel')), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('Mais opções'), 200, scrollable: form);
    await tester.tap(find.text('Mais opções'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('endereco-hex')), findsNothing, reason: 'S7 não tem endereço em hexadecimal');
    expect(find.text('Ordem dos bytes'), findsNothing, reason: 'S7 é sempre big-endian');
    expect(find.text('Inteiro com sinal · INT'), findsOneWidget, reason: 'nome do tipo como no TIA');
    await tester.scrollUntilVisible(find.byKey(const ValueKey('campo-nome-variavel')), -200, scrollable: form);
    await tester.enterText(find.byKey(const ValueKey('campo-nome-variavel')), 'Temperatura');

    final campo = find.byKey(const ValueKey('campo-endereco-s7'));
    await tester.enterText(campo, 'DB1.DBX0.8');
    await tester.pump();
    expect(find.text('DB1.DBX0.8: o bit vai de 0 a 7'), findsOneWidget);

    await tester.enterText(campo, 'm10.3');
    await tester.pump();
    expect(find.text('M10.3 → memória M, bit 3 do byte 10'), findsOneWidget, reason: 'bit vira liga/desliga');

    await tester.enterText(campo, 'EW64');
    await tester.pump();
    expect(find.text('EW64 → entradas, palavra no byte 64'), findsOneWidget);
    expect(find.text('Esta memória é só de leitura.'), findsOneWidget, reason: 'entrada não se grava');

    await tester.enterText(campo, '%db1.dbd8');
    await tester.pump();
    expect(find.text('DB1.DBD8 → DB 1, palavra dupla no byte 8'), findsOneWidget, reason: 'D vira número com vírgula');

    // "Lendo agora": o endereço digitado é lido no CLP de teste.
    await waitFor(tester, find.text('1234'), rounds: 80, step: const Duration(milliseconds: 100));

    await tester.tap(find.byKey(const ValueKey('salvar-variavel')));
    await tester.pumpAndSettle();
    final t = c.project.tags.last;
    expect(t.deviceId, 'clp');
    expect(t.s7, const S7TagAddress('DB1.DBD8'));
    expect(t.dataType, TagDataType.float32);
    expect((t.area, t.address), (ModbusArea.holdingRegister, 0));
    expect(t.addressLabel, 'DB1.DBD8');

    // Deixa a conexão do "lendo agora" fechar no relógio real.
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(server.clientCount, 0, reason: 'fechar o cadastro solta o CLP');
    await shutdown(tester, c);
    await tester.runAsync(server.stop);
  });

  test('prova da leitura e sugestão de tipo (funções puras)', () {
    S7Address at(String s) => S7Address.parse(s);
    expect(S7TagFields.proof(at('DB1.DBW4'), TagDataType.uint16), 'DB1.DBW4 → DB 1, palavra no byte 4');
    expect(S7TagFields.proof(at('MB2'), TagDataType.uint16), 'MB2 → memória M, byte 2');
    expect(S7TagFields.proof(at('A0.1'), TagDataType.bool, german: true), 'A0.1 → saídas, bit 1 do byte 0');
    expect(S7TagFields.proof(at('P#DB1.DBX10.0 BYTE 22'), TagDataType.string), 'P#DB1.DBX10.0 BYTE 22 → DB 1, texto de até 20 letras no byte 10');
    expect(S7TagFields.proof(at('DB1.DBW0'), TagDataType.uint16, length: 8), 'DB1.DBW0 → DB 1, 8 palavras a partir do byte 0');

    final f = S7TagFields(const S7TagAddress('DB1.DBD8'));
    expect(f.suggestedType(TagDataType.uint16, null), TagDataType.float32);
    expect(f.suggestedType(TagDataType.int32, null), isNull, reason: 'DINT num DBD cabe: a escolha fica');
    expect(f.suggestedType(TagDataType.bool, TagFit.boolean), isNull, reason: 'o elemento só aceita liga/desliga');
    expect(f.error(TagDataType.bool), 'Liga / desliga pede um bit: use DB1.DBX8.0');
    f.address.text = '';
    expect(f.error(TagDataType.uint16), 'Informe o endereço (ex.: DB1.DBW4)');
    f.address.text = 'IW2';
    expect(f.canWrite, isFalse);
    f.dispose();
  });
}
