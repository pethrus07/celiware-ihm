import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/core/serial/serial_params.dart';
import 'package:ihm/core/serial/usb_serial.dart';
import 'package:ihm/core/serial/usb_serial_link.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/serial_config.dart';
import 'package:ihm/screens/devices/device_form_page.dart';
import 'package:ihm/screens/devices/usb_device_fields.dart';
import 'package:ihm/screens/tags/tag_form_page.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_usb_serial.dart';

/// Cadastro de equipamento no cabo USB: o adaptador no lugar do IP (achado
/// sozinho quando é um só), protocolo e linha em "Mais opções", a explicação
/// antes da pergunta de permissão do Android e o que conferir quando o teste
/// falha. A porta é a simulada; o resto é o app.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  late Directory dir;
  late FakeUsbSerial usb;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      for (final (id, _, _) in Tours.catalog) 'tour:v1:$id': true,
    });
    dir = await Directory.systemTemp.createTemp('ihm_usb_form');
    usb = FakeUsbSerial();
    UsbSerial.platform = usb;
  });

  tearDown(() async {
    DemoRegistry.discard(DemoProject.deviceId);
    await UsbSerialPool.reset();
    await usb.dispose();
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

  /// Porta no relógio real (runAsync), tela no simulado (pump), alternando
  /// até [found] aparecer.
  Future<void> waitFor(WidgetTester tester, Finder found, {int tries = 80}) async {
    for (var i = 0; i < tries && found.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    if (found.evaluate().isEmpty) {
      debugPrint('Textos na tela: ${[for (final t in tester.widgetList<Text>(find.byType(Text))) t.data ?? t.textSpan?.toPlainText()].join(' | ')}');
    }
    expect(found, findsWidgets);
  }

  Future<void> shutdown(WidgetTester tester, ProjectController c) async {
    await tester.pumpWidget(const SizedBox());
    final done = c.runtime.dispose();
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await done;
    c.dispose();
  }

  Finder formScroll() => find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).last;

  Future<void> reveal(WidgetTester tester, Finder f, {double delta = 200}) async {
    await tester.scrollUntilVisible(f, delta, scrollable: formScroll());
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
  }

  Future<void> openNew(WidgetTester tester, {Device? device}) async {
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute<void>(builder: (_) => DeviceFormPage(device: device)));
    await tester.pumpAndSettle();
  }

  testWidgets('cabo USB: adaptador no lugar do IP, achado sozinho; Mais opções com protocolo, velocidade e paridade; salvar', (tester) async {
    usb.plug(FakeAdapter());
    final c = await boot(tester);
    await openNew(tester);
    await tester.enterText(find.byKey(const ValueKey('campo-nome-equipamento')), 'Inversor da bomba');
    expect(find.text('Cabo USB'), findsOneWidget, reason: 'terceira escolha de onde o equipamento está');
    await tester.tap(find.text('Cabo USB'));
    await tester.pump();
    expect(find.widgetWithText(TextFormField, 'IP do equipamento'), findsNothing, reason: 'cabo não tem IP');
    await waitFor(tester, find.text('CH340 · USB2.0-Serial · conectado'));
    expect(find.text('Modbus RTU · 9600 8N1 · ID 1'), findsOneWidget, reason: '9600 8N1 de partida, à vista no resumo');

    await reveal(tester, find.text('Mais opções'));
    await tester.tap(find.text('Mais opções'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('protocolo-tcp')), findsNothing, reason: 'protocolos de rede somem no cabo');
    expect(find.text('Marca e modelo'), findsOneWidget, reason: 'perfil de fabricante vale no RTU (INVT IVC1, WEG TPW04 só falam RTU)');
    await reveal(tester, find.byKey(const ValueKey('usb-baud-19200')));
    await tester.tap(find.byKey(const ValueKey('usb-baud-19200')));
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const ValueKey('usb-paridade-SerialParity.even')));
    await tester.tap(find.byKey(const ValueKey('usb-paridade-SerialParity.even')));
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const ValueKey('usb-id')));
    await tester.enterText(find.byKey(const ValueKey('usb-id')), '3');
    await tester.pumpAndSettle();
    expect(find.text('Modbus RTU · 19200 8E1 · ID 3'), findsOneWidget);

    // Trocar para ASCII leva junto o 7E1 de costume só se os bits não foram
    // mexidos — aqui a paridade já foi escolhida à mão e fica.
    await reveal(tester, find.byKey(const ValueKey('usb-protocolo-ascii')), delta: -200);
    await tester.tap(find.byKey(const ValueKey('usb-protocolo-ascii')));
    await tester.pumpAndSettle();
    expect(find.text('Modbus ASCII · 19200 8E1 · ID 3'), findsOneWidget);
    await reveal(tester, find.byKey(const ValueKey('usb-protocolo-rtu')), delta: -200);
    await tester.tap(find.byKey(const ValueKey('usb-protocolo-rtu')));
    await tester.pumpAndSettle();
    expect(find.text('Modbus RTU · 19200 8E1 · ID 3'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('salvar-equipamento')));
    await tester.pumpAndSettle();
    final d = c.project.devices.last;
    expect(d.kind, DeviceKind.usbSerial);
    expect(d.unitId, 3);
    expect(d.host, '');
    expect(d.serial.params, const SerialParams(baud: 19200, parity: SerialParity.even));
    expect(d.serial.protocol, SerialProtocol.rtu);
    expect(d.serial.port?.chip, 'CH340');
    expect(d.addressLabel, 'Cabo USB · CH340 · RTU · 19200 8E1 · ID 3');
    expect(d.toJson()['serial'], {
      'usb': {'vendorId': 0x1A86, 'productId': 0x7523, 'chip': 'CH340', 'product': 'USB2.0-Serial'},
      'baud': 19200,
      'parity': 'even',
    });

    // Reabrir: tudo como foi salvo.
    await openNew(tester, device: d);
    expect(find.text('Modbus RTU · 19200 8E1 · ID 3'), findsOneWidget);
    await shutdown(tester, c);
  });

  testWidgets('testar conexão: explica a permissão antes da pergunta do Android, responde; falhando, diz o que conferir', (tester) async {
    final memory = ModbusMemory(holdingRegisters: 10);
    final slave = FakeModbusSlave(memory);
    usb.plug(FakeAdapter(grantedOnPlug: false, equipment: [slave]));
    final c = await boot(tester);
    await openNew(tester, device: const Device(id: 'u', name: 'Inversor', kind: DeviceKind.usbSerial, timeoutMs: 300));
    await waitFor(tester, find.text('CH340 · USB2.0-Serial · conectado'));

    // "Agora não": nada de pergunta do Android; o cartão diz o que fazer.
    await tester.tap(find.byKey(const ValueKey('testar-conexao')));
    await waitFor(tester, find.byKey(const ValueKey('usb-permissao')));
    expect(find.text('Permitir o adaptador USB'), findsOneWidget);
    expect(find.textContaining('Toque em OK: sem essa permissão o app não fala com o equipamento pelo cabo'), findsOneWidget);
    await tester.tap(find.text('Agora não'));
    await tester.pumpAndSettle();
    expect(usb.permissionDialogs, 0);
    expect(find.text('Não conectou: sem permissão para usar o adaptador USB'), findsOneWidget);
    expect(find.textContaining('na pergunta do Android, toque em OK'), findsOneWidget);

    // Continuar: a pergunta do Android aparece (aqui, a pessoa deixa) e o teste segue.
    await tester.ensureVisible(find.byKey(const ValueKey('testar-conexao')));
    await tester.tap(find.byKey(const ValueKey('testar-conexao')));
    await waitFor(tester, find.byKey(const ValueKey('usb-permissao-continuar')));
    await tester.tap(find.byKey(const ValueKey('usb-permissao-continuar')));
    await tester.pump();
    await waitFor(tester, find.byKey(const ValueKey('teste-ok')));
    expect(usb.permissionDialogs, 1);
    expect(find.textContaining('Equipamento respondeu'), findsOneWidget);

    // Equipamento mudo: o adaptador abriu; a lista começa por velocidade e paridade.
    slave.silent = true;
    await tester.ensureVisible(find.byKey(const ValueKey('testar-conexao')));
    await tester.tap(find.byKey(const ValueKey('testar-conexao')));
    await tester.pump();
    await waitFor(tester, find.byKey(const ValueKey('teste-falhou')));
    await tester.pumpAndSettle();
    expect(find.text('Sem resposta do equipamento'), findsOneWidget, reason: '"Não conectou" seria mentira: o adaptador abriu');
    expect(find.text('O adaptador abriu. Confira, nesta ordem:'), findsOneWidget);
    expect(find.textContaining('Velocidade, bits, paridade e parada'), findsOneWidget);
    expect(find.textContaining('Os fios A e B (D+ e D−) não estão invertidos?'), findsOneWidget);
    expect(find.textContaining('O número na rede (ID do escravo)'), findsOneWidget);
    await shutdown(tester, c);
  });

  testWidgets('lista dos adaptadores: chip de cada um, aparelho sem driver apagado; escolher; sem adaptador, diz o que fazer', (tester) async {
    usb.plug(FakeAdapter());
    usb.plug(FakeAdapter(vendorId: 0x0403, productId: 0x6001, chip: 'FTDI', product: 'FT232R USB UART'));
    usb.plug(FakeAdapter(vendorId: 0x0781, productId: 0x5567, chip: null, product: 'Cruzer Blade'));
    final c = await boot(tester);
    await openNew(tester, device: const Device(id: 'u', name: 'CLP', kind: DeviceKind.usbSerial, timeoutMs: 300));
    await waitFor(tester, find.text('2 adaptadores plugados: toque para escolher'));
    await tester.tap(find.byKey(const ValueKey('adaptador-usb')));
    await tester.pumpAndSettle();
    expect(find.text('CH340 · USB2.0-Serial'), findsOneWidget);
    expect(find.text('FTDI · FT232R USB UART'), findsOneWidget);
    expect(find.text('Aparelho USB · Cruzer Blade'), findsOneWidget);
    expect(find.text('0781:5567 · não é um adaptador serial conhecido'), findsOneWidget);
    await tester.tap(find.text('FTDI · FT232R USB UART'));
    await tester.pumpAndSettle();
    expect(find.text('FTDI · FT232R USB UART · conectado'), findsOneWidget);

    // Tirou todos: o cartão do teste manda conferir o cabo OTG.
    for (final a in usb.plugged.toList()) {
      usb.unplug(a);
    }
    await waitFor(tester, find.text('FTDI · FT232R USB UART · não está plugado agora'));
    await tester.tap(find.byKey(const ValueKey('testar-conexao')));
    await tester.pump();
    await waitFor(tester, find.byKey(const ValueKey('teste-falhou')));
    await tester.pumpAndSettle();
    expect(find.text('Não conectou: adaptador USB não encontrado'), findsOneWidget);
    expect(find.textContaining('cabo OTG'), findsWidgets);
    await shutdown(tester, c);
  });

  testWidgets('Arduino pelo cabo: mensagem do equipamento à vista, sem ID nem marca; variável com campo da mensagem', (tester) async {
    usb.plug(FakeAdapter(equipment: [FakeSerialArduino()]));
    final c = await boot(tester);
    await openNew(tester);
    await tester.enterText(find.byKey(const ValueKey('campo-nome-equipamento')), 'Estufa');
    await tester.tap(find.text('Cabo USB'));
    await tester.pump();
    await waitFor(tester, find.text('CH340 · USB2.0-Serial · conectado'));
    await reveal(tester, find.text('Mais opções'));
    await tester.tap(find.text('Mais opções'));
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const ValueKey('usb-protocolo-raw')));
    await tester.tap(find.byKey(const ValueKey('usb-protocolo-raw')));
    await tester.pumpAndSettle();
    expect(find.text('Arduino / mensagem própria · 9600 8N1'), findsOneWidget);
    expect(find.text('Número na rede'), findsNothing);
    expect(find.text('Descartar eco'), findsNothing);
    expect(find.text('Marca e modelo'), findsNothing);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('mensagem-equipamento')), -200, scrollable: formScroll());
    expect(find.byKey(const ValueKey('mensagem-equipamento')), findsOneWidget, reason: 'o perfil da mensagem fica à vista');

    // Testar: chegou mensagem e o perfil (chave=valor) entendeu.
    await tester.ensureVisible(find.byKey(const ValueKey('testar-conexao')));
    await tester.tap(find.byKey(const ValueKey('testar-conexao')));
    await tester.pump();
    await waitFor(tester, find.byKey(const ValueKey('teste-ok')), tries: 150);
    expect(find.textContaining('Chegou mensagem e o perfil entendeu'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('salvar-equipamento')));
    await tester.pumpAndSettle();
    final d = c.project.devices.last;
    expect(d.kind, DeviceKind.usbSerial);
    expect(d.serial.isRaw, isTrue);
    expect(d.profile, isNull);

    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute<void>(builder: (_) => TagFormPage(preferDeviceId: d.id)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('campo-endereco')), findsNothing, reason: 'endereço Modbus dá lugar ao campo da mensagem');
    expect(find.byKey(const ValueKey('campo-mensagem')), findsOneWidget);
    expect(find.byKey(const ValueKey('ouvir-equipamento')), findsOneWidget);
    await shutdown(tester, c);
  });

  test('o que conferir, como função pura', () {
    expect(usbProbeChecks(const ProbeResult(ok: false, message: UsbHint.notChosen), raw: false).single, contains('escolha qual usar'));
    expect(usbProbeChecks(const ProbeResult(ok: false, message: 'chegaram bytes que não formam uma resposta'), raw: false).first, contains('velocidade ou paridade diferente'));
    expect(usbProbeChecks(const ProbeResult(ok: false, message: 'resposta inválida do equipamento'), raw: false).first, contains('120 Ω'));
    expect(usbProbeChecks(const ProbeResult(ok: false, message: 'conectou, mas nenhuma mensagem chegou em 2 s'), raw: true).first, contains('Serial.begin()'));
    expect(usbProbeTitle(const ProbeResult(ok: false, message: UsbHint.noAdapter), raw: true), 'Não conectou: adaptador USB não encontrado');
    expect(usbProbeHeader(const ProbeResult(ok: false, message: 'sem resposta do equipamento')), 'O adaptador abriu. Confira, nesta ordem:');
    final f = UsbDeviceFields(const SerialConfig());
    f.setProtocol(SerialProtocol.ascii);
    expect(f.params, SerialParams.ascii);
    f.params = f.params.copyWith(stopBits: 2);
    f.setProtocol(SerialProtocol.rtu);
    expect(f.params.label, '9600 7E2', reason: 'quem mexeu nos bits fica com o que escolheu');
  });
}
