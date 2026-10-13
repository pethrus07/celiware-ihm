import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/mqtt_config.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/screens/devices/device_form_page.dart';
import 'package:ihm/screens/tags/tag_form_page.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/mqtt_test_broker.dart';

/// Cadastro de equipamento e de variável quando o protocolo é MQTT: os campos
/// do Modbus somem e os do MQTT aparecem; "Ouvir o broker" preenche o
/// endereço a partir do que chega.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      for (final (id, _, _) in Tours.catalog) 'tour:v1:$id': true,
    });
    dir = await Directory.systemTemp.createTemp('ihm_mqtt_form');
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

  testWidgets('equipamento MQTT: protocolo em Mais opções, campos do broker; variável com tópico', (tester) async {
    final c = await boot(tester);
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);

    // ── Equipamento ──
    nav.push(MaterialPageRoute<void>(builder: (_) => const DeviceFormPage()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('campo-nome-equipamento')), 'Sensores');
    await tester.enterText(find.widgetWithText(TextFormField, 'IP do equipamento'), '192.168.0.50');
    await tester.tap(find.text('Mais opções'));
    await tester.pumpAndSettle();
    expect(find.text('Número na rede'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('protocolo-mqtt')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('protocolo-mqtt')));
    await tester.pumpAndSettle();
    expect(find.text('Número na rede'), findsNothing, reason: 'Modbus some quando o protocolo é MQTT');
    expect(find.text('Ler a cada (ms)'), findsNothing);
    expect(find.text('MQTT · Porta 1883'), findsOneWidget, reason: 'porta padrão troca junto com o protocolo');
    await tester.drag(find.byType(ListView).last, const Offset(0, 3000));
    await tester.pumpAndSettle();
    expect(find.text('IP do broker'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('mqtt-tls')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mqtt-tls')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('campo-usuario-mqtt')), 'ihm');
    await tester.pumpAndSettle();
    expect(find.text('MQTT · Porta 8883 · TLS · ihm'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('salvar-equipamento')));
    await tester.pumpAndSettle();
    final d = c.project.devices.last;
    expect(d.kind, DeviceKind.mqtt);
    expect(d.port, MqttBroker.tlsPort);
    expect(d.mqtt.tls, isTrue);
    expect(d.mqtt.username, 'ihm');
    expect(d.addressLabel, '192.168.0.50:8883 · MQTT · TLS');

    // ── Variável ──
    nav.push(MaterialPageRoute<void>(builder: (_) => TagFormPage(preferDeviceId: d.id)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('campo-endereco')), findsNothing, reason: 'endereço Modbus dá lugar ao tópico');
    expect(find.byKey(const ValueKey('campo-topico')), findsOneWidget);
    expect(find.byKey(const ValueKey('ouvir-broker')), findsOneWidget);
    expect(find.text('Complete o tópico'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('campo-nome-variavel')), 'Temperatura');
    await tester.tap(find.text('Número com vírgula'));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('campo-json')), 'sensores.temp');
    expect(find.byKey(const ValueKey('campo-topico-comando')), findsNothing, reason: 'só aparece quando grava');
    // A lista do formulário (os campos de texto têm rolagem horizontal própria).
    final form = find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).last;
    await tester.scrollUntilVisible(find.byKey(const ValueKey('pode-gravar')), 200, scrollable: form);
    await tester.tap(find.byKey(const ValueKey('pode-gravar')));
    await tester.pump();
    await tester.scrollUntilVisible(find.byKey(const ValueKey('campo-topico-comando')), 200, scrollable: form);
    await tester.enterText(find.byKey(const ValueKey('campo-topico-comando')), 'cortadora/temp/set');
    // Tópico por último e salvar logo: o "Lendo agora" só tenta a rede com
    // tópico válido (e o fim do teste esvazia os relógios de qualquer jeito).
    await tester.scrollUntilVisible(find.byKey(const ValueKey('campo-topico')), -200, scrollable: form);
    await tester.enterText(find.byKey(const ValueKey('campo-topico')), 'cortadora/estado');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('salvar-variavel')));
    await tester.pumpAndSettle();

    final t = c.project.tags.last;
    expect(t.deviceId, d.id);
    expect(t.mqtt, const MqttAddress(topic: 'cortadora/estado', jsonPath: 'sensores.temp', commandTopic: 'cortadora/temp/set'));
    expect(t.canWrite, isTrue);
    expect(t.addressLabel, 'cortadora/estado · sensores.temp');
    await shutdown(tester, c);
  });

  testWidgets('ouvir o broker: lista tópicos e campos; tocar preenche tópico, campo, tipo e nome', (tester) async {
    // Broker de verdade: a rede anda no relógio real (runAsync), a tela no
    // simulado (pump) — os dois se alternam até a lista aparecer.
    final broker = MqttTestBroker();
    await tester.runAsync(broker.start);
    broker.publish('cortadora/estado', '{"sensores": {"temp": 72.5, "porta": true}}', retain: true);
    broker.publish('cortadora/receita', 'Rótulo 330 ml', retain: true);

    final c = await boot(tester);
    final d = Device(id: 'mq', name: 'Sensores', kind: DeviceKind.mqtt, host: '127.0.0.1', port: broker.port, timeoutMs: 1000);
    c.saveDevice(d);
    await tester.pump();
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute<void>(builder: (_) => TagFormPage(preferDeviceId: d.id)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('ouvir-broker')));
    final campo = find.byKey(const ValueKey('ouvido-cortadora/estado-sensores.temp'));
    for (var i = 0; i < 40 && campo.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(campo, findsOneWidget);
    expect(find.byKey(const ValueKey('ouvido-cortadora/receita')), findsOneWidget);
    expect(find.textContaining('Ouvindo'), findsOneWidget);

    await tester.tap(campo);
    await tester.pumpAndSettle();
    expect(find.text('cortadora/estado'), findsOneWidget);
    expect(find.text('sensores.temp'), findsOneWidget);
    expect(find.text('Temp'), findsOneWidget, reason: 'nome de partida vindo do campo');
    await tester.tap(find.byKey(const ValueKey('salvar-variavel')));
    await tester.pumpAndSettle();
    final t = c.project.tags.last;
    expect(t.mqtt, const MqttAddress(topic: 'cortadora/estado', jsonPath: 'sensores.temp'));
    expect(t.dataType, TagDataType.float32, reason: '72.5 pede número com vírgula');

    // O "Lendo agora" pode ter aberto conexão depois da escolha (o tópico
    // ficou válido): deixa ela terminar — rede no relógio real, prazos no
    // simulado — e confere que nada sobrou no broker depois de sair.
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(broker.clientIds, isEmpty);
    await shutdown(tester, c);
    await tester.runAsync(broker.close);
  });
}
