import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/rawlink/fake_arduino_server.dart';
import 'package:ihm/core/rawlink/message_profile.dart';
import 'package:ihm/core/rawlink/raw_link_pool.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/raw_config.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/screens/devices/device_form_page.dart';
import 'package:ihm/screens/devices/raw_profile_page.dart';
import 'package:ihm/screens/tags/tag_form_page.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cadastro de equipamento e de variável quando o equipamento é cru
/// (Arduino): os campos do Modbus somem; o perfil da mensagem tem editor com
/// prévia ao vivo; "Ouvir o equipamento" preenche o campo da variável.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      for (final (id, _, _) in Tours.catalog) 'tour:v1:$id': true,
    });
    dir = await Directory.systemTemp.createTemp('ihm_raw_form');
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

  /// Rede no relógio real (runAsync), tela no simulado (pump), alternando
  /// até [found] aparecer.
  Future<void> waitFor(WidgetTester tester, Finder found, {int tries = 80}) async {
    for (var i = 0; i < tries && found.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    if (found.evaluate().isEmpty) {
      debugPrint('Textos na tela: ${[for (final t in tester.widgetList<Text>(find.byType(Text))) t.data ?? t.textSpan?.toPlainText()].join(' | ')}');
    }
    expect(found, findsWidgets);
  }

  /// Encerra app e runtime dentro do teste, deixando os sockets fecharem.
  Future<void> shutdown(WidgetTester tester, ProjectController c) async {
    await tester.pumpWidget(const SizedBox());
    final done = c.runtime.dispose();
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await done;
    c.dispose();
  }

  testWidgets('equipamento Arduino: protocolo em Mais opções, TCP/UDP e porta; mensagem à vista; variável com campo e comando', (tester) async {
    final c = await boot(tester);
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);

    // ── Equipamento ──
    nav.push(MaterialPageRoute<void>(builder: (_) => const DeviceFormPage()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('campo-nome-equipamento')), 'Tanque');
    await tester.enterText(find.widgetWithText(TextFormField, 'IP do equipamento'), '192.168.0.50');
    await tester.tap(find.text('Mais opções'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('protocolo-raw')));
    await tester.pumpAndSettle();
    expect(find.text('Arduino / mensagem própria'), findsOneWidget, reason: 'chip com nome de leigo');
    await tester.tap(find.byKey(const ValueKey('protocolo-raw')));
    await tester.pumpAndSettle();
    expect(find.text('Número na rede'), findsNothing, reason: 'Modbus some quando o protocolo é cru');
    expect(find.text('Marca e modelo'), findsNothing);
    expect(find.text('Arduino · TCP · Porta 5030'), findsOneWidget, reason: 'porta de partida troca junto com o protocolo');

    await tester.ensureVisible(find.byKey(const ValueKey('transporte-udp')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('transporte-udp')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('porta-local')));
    await tester.enterText(find.byKey(const ValueKey('porta-local')), '6000');
    await tester.pumpAndSettle();
    expect(find.text('Arduino · UDP · Porta 5030 · porta deste celular 6000'), findsOneWidget);

    // O perfil da mensagem fica à vista, logo abaixo do IP.
    final deviceForm = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).last;
    await tester.scrollUntilVisible(find.byKey(const ValueKey('mensagem-equipamento')), -200, scrollable: deviceForm);
    await tester.ensureVisible(find.byKey(const ValueKey('mensagem-equipamento')));
    await tester.pumpAndSettle();
    expect(find.text('Linha chave=valor · o equipamento manda sozinho'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('salvar-equipamento')));
    await tester.pumpAndSettle();
    final d = c.project.devices.last;
    expect(d.kind, DeviceKind.raw);
    expect(d.raw, const RawConfig(transport: RawTransport.udp, localPort: 6000));
    expect(d.profile, isNull);
    expect(d.addressLabel, '192.168.0.50:5030 · Arduino · UDP');

    // ── Variável ──
    nav.push(MaterialPageRoute<void>(builder: (_) => TagFormPage(preferDeviceId: d.id)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('campo-endereco')), findsNothing, reason: 'endereço Modbus dá lugar ao campo da mensagem');
    expect(find.byKey(const ValueKey('campo-mensagem')), findsOneWidget);
    expect(find.byKey(const ValueKey('ouvir-equipamento')), findsOneWidget);
    expect(find.text('Diga qual campo da mensagem'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('campo-nome-variavel')), 'Bomba');
    await tester.tap(find.text('Liga / desliga'));
    await tester.pump();
    expect(find.byKey(const ValueKey('campo-comando')), findsNothing, reason: 'só aparece quando grava');
    final form = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).last;
    await tester.scrollUntilVisible(find.byKey(const ValueKey('pode-gravar')), 200, scrollable: form);
    await tester.ensureVisible(find.byKey(const ValueKey('pode-gravar')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pode-gravar')));
    await tester.pump();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('campo-comando')), 200, scrollable: form);
    await tester.ensureVisible(find.byKey(const ValueKey('campo-comando')));
    await tester.pumpAndSettle();
    expect(find.text(r'Vazio = SET {campo}={valor}\n'), findsOneWidget, reason: 'o comando do equipamento vale sem digitar nada');
    // Campo por último e salvar logo: o "Lendo agora" só tenta a rede com campo.
    await tester.scrollUntilVisible(find.byKey(const ValueKey('campo-mensagem')), -200, scrollable: form);
    await tester.ensureVisible(find.byKey(const ValueKey('campo-mensagem')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('campo-mensagem')), 'P');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('salvar-variavel')));
    await tester.pumpAndSettle();

    final t = c.project.tags.last;
    expect(t.deviceId, d.id);
    expect(t.raw, const RawAddress(field: 'P'));
    expect(t.dataType, TagDataType.bool);
    expect(t.canWrite, isTrue);
    expect(t.addressLabel, 'campo P');
    await shutdown(tester, c);
  });

  testWidgets('editor do perfil: prévia ao vivo com campos e problemas, reinterpretando a cada mexida; testar conexão diz se entendeu', (tester) async {
    // Arduino que manda CSV: o perfil padrão (chave=valor) não entende.
    final server = FakeArduinoServer(streamEvery: const Duration(milliseconds: 50), encode: (v) => utf8.encode('${v['T']},${v['P']}\n'));
    await tester.runAsync(server.start);
    final c = await boot(tester);
    final d = Device(id: 'ard', name: 'Tanque', kind: DeviceKind.raw, host: '127.0.0.1', port: server.port, timeoutMs: 1000);
    c.saveDevice(d);
    await tester.pump();
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute<void>(builder: (_) => DeviceFormPage(device: d)));
    await tester.pumpAndSettle();

    // Testar conexão: chegou, mas o perfil não entendeu.
    await tester.tap(find.byKey(const ValueKey('testar-conexao')));
    await waitFor(tester, find.byKey(const ValueKey('teste-falhou')));
    await tester.pumpAndSettle(); // o cartão do resultado rola até ele
    expect(find.text('Chegou mensagem, mas o perfil não entendeu: nenhum campo reconhecido'), findsOneWidget);
    expect(find.textContaining('abra "Mensagem do equipamento"'), findsOneWidget);

    // Editor: a prévia mostra a mensagem e o problema.
    await tester.tap(find.byKey(const ValueKey('mensagem-equipamento')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await waitFor(tester, find.byKey(const ValueKey('previa-problema-0')));
    expect(find.text('nenhum campo reconhecido'), findsWidgets);
    expect(find.text('Ao vivo · 127.0.0.1:${server.port}'), findsOneWidget);

    // Nada novo chega daqui em diante: o que muda na prévia vem do perfil.
    server.silent = true;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('modelo-virgulas')));
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const ValueKey('previa-campos-0'))).data, '1 = 25,3  ·  2 = 1');
    await tester.enterText(find.byKey(const ValueKey('nomes-campos')), 'temp, bomba');
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const ValueKey('previa-campos-0'))).data, 'temp = 25,3  ·  bomba = 1');
    // Sem o foco no campo: senão ele puxa a rolagem de volta para o cursor.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    // Escolha rara recolhida: checksum que a mensagem não tem → "checksum errado".
    final list = find.descendant(of: find.byType(RawProfilePage), matching: find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down)).last;
    // O cadastro do equipamento, embaixo, também tem um "Mais opções".
    final more = find.descendant(of: find.byType(RawProfilePage), matching: find.text('Mais opções'));
    await tester.scrollUntilVisible(more, 200, scrollable: list);
    await tester.ensureVisible(more);
    await tester.pumpAndSettle();
    await tester.tap(more);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('checksum-xor')), 200, scrollable: list);
    await tester.ensureVisible(find.byKey(const ValueKey('checksum-xor')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('checksum-xor')));
    await tester.pump();
    expect(find.text('checksum errado'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('checksum-none')));
    await tester.pump();
    expect(find.byKey(const ValueKey('previa-campos-0')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('concluir-perfil')));
    await tester.pumpAndSettle();
    expect(find.text('Linha com vírgulas · o equipamento manda sozinho'), findsOneWidget);

    // Com o perfil certo, o teste passa.
    server.silent = false;
    await tester.tap(find.byKey(const ValueKey('testar-conexao')));
    await waitFor(tester, find.byKey(const ValueKey('teste-ok')));
    expect(find.textContaining('Chegou mensagem e o perfil entendeu'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('salvar-equipamento')));
    await tester.pumpAndSettle();
    expect(c.project.device('ard')!.raw.profile.fields, isA<CsvFields>().having((f) => f.names, 'nomes', ['temp', 'bomba']));

    await shutdown(tester, c);
    await tester.runAsync(server.stop);
    expect(RawLinkPool.openCount, 0, reason: 'prévia e teste soltaram o socket');
  });

  testWidgets('variável: "Ouvir o equipamento" lista os campos com o último valor; tocar preenche campo, tipo e nome', (tester) async {
    final server = FakeArduinoServer(streamEvery: const Duration(milliseconds: 50));
    await tester.runAsync(server.start);
    final c = await boot(tester);
    final d = Device(id: 'ard', name: 'Tanque', kind: DeviceKind.raw, host: '127.0.0.1', port: server.port, timeoutMs: 1000);
    c.saveDevice(d);
    await tester.pump();
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute<void>(builder: (_) => TagFormPage(preferDeviceId: d.id)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('ouvir-equipamento')));
    await waitFor(tester, find.byKey(const ValueKey('ouvido-campo-T')));
    await tester.pump(const Duration(milliseconds: 500)); // a folha termina de subir
    expect(find.byKey(const ValueKey('ouvido-campo-P')), findsOneWidget);
    expect(find.text('25,3'), findsOneWidget, reason: 'o último valor de cada campo');
    expect(find.textContaining('Ouvindo'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ouvido-campo-T')));
    await tester.pumpAndSettle();
    expect(find.text('T'), findsWidgets);
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('campo-mensagem'))).controller!.text, 'T');
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('campo-nome-variavel'))).controller!.text, 'T',
        reason: 'nome de partida vindo do campo');

    // "Lendo agora" pela mesma conexão: o valor do campo escolhido.
    await waitFor(tester, find.text('25,3'));
    await tester.tap(find.byKey(const ValueKey('salvar-variavel')));
    await tester.pumpAndSettle();
    final t = c.project.tags.last;
    expect(t.raw, const RawAddress(field: 'T'));
    expect(t.dataType, TagDataType.float32, reason: '25.3 pede número com vírgula');

    await shutdown(tester, c);
    await tester.runAsync(server.stop);
    expect(RawLinkPool.openCount, 0);
  });
}
