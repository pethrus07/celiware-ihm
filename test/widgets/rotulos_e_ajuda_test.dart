import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/mqtt_config.dart';
import 'package:ihm/models/opcua_config.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/raw_config.dart';
import 'package:ihm/models/s7_config.dart';
import 'package:ihm/screens/devices/device_form_page.dart';
import 'package:ihm/screens/devices/raw_profile_page.dart';
import 'package:ihm/screens/tags/tag_form_page.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/cameras/camera_vault.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Rodada de QA de 12/10 (textos e ajuda):
///  • termo técnico de "Mais opções" vira rótulo do chão de fábrica, com o
///    termo do manual entre parênteses ou na dica — e nada disso pode sair
///    cortado com "…" no celular pequeno, com as fontes de verdade;
///  • Câmeras e Mais ganham o "?" com o tutorial, como as outras páginas.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  late Directory dir;

  // As fontes do app (IBM Plex), e não a de teste, em que cada letra é um
  // quadrado: "cortado com …" depende da largura real do texto.
  setUpAll(() async {
    for (final (family, files) in [
      ('Plex', ['IBMPlexSans-400', 'IBMPlexSans-500', 'IBMPlexSans-600', 'IBMPlexSans-700']),
      ('PlexCondensed', ['IBMPlexSansCondensed-SemiBold', 'IBMPlexSansCondensed-Bold']),
      ('PlexMono', ['IBMPlexMono-Regular', 'IBMPlexMono-SemiBold']),
    ]) {
      final loader = FontLoader(family);
      for (final f in files) {
        loader.addFont(Future.value(ByteData.sublistView(File('assets/fonts/$f.ttf').readAsBytesSync())));
      }
      await loader.load();
    }
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      // Todas as versões já vistas (a trilha de início está na v2).
      for (final (id, _, _) in Tours.catalog) for (final v in [1, 2]) 'tour:v$v:$id': true,
    });
    CameraVault.instance = MemoryCameraVault();
    dir = await Directory.systemTemp.createTemp('ihm_rotulos');
  });

  tearDown(() async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {/* Windows ainda segurando o arquivo — é só a pasta temporária */}
  });

  // Campos de texto vazios de propósito: vazio, o rótulo fica no tamanho
  // grande, dentro da caixa — o caso em que ele mais corta.
  const devices = [
    Device(id: 'tcp', name: 'CLP Modbus', host: '192.168.0.10'),
    Device(id: 'usb', name: 'Inversor no cabo', kind: DeviceKind.usbSerial),
    Device(id: 's7', name: 'CLP Siemens', kind: DeviceKind.s7, host: '192.168.0.20', port: 102, s7: S7Config(family: S7Family.other, rack: 0, slot: 2)),
    Device(id: 'ua', name: 'Servidor OPC UA', kind: DeviceKind.opcua, host: '192.168.0.30', port: 4840, opcua: OpcUaConfig()),
    Device(id: 'mq', name: 'Broker', kind: DeviceKind.mqtt, host: '192.168.0.40', port: 1883, mqtt: MqttBroker()),
    Device(id: 'raw', name: 'Balança', kind: DeviceKind.raw, host: '192.168.0.50', port: RawConfig.defaultPort),
  ];

  Future<ProjectController> boot(WidgetTester tester, Size dp) async {
    final rt = HmiRuntime();
    final repo = ProjectRepository(directory: dir);
    await tester.runAsync(() => repo.save(const Project(name: 'P', devices: devices)));
    final c = ProjectController(repository: repo, runtime: rt);
    await tester.runAsync(c.load);
    tester.view.physicalSize = dp;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CeliwareIhmApp(controller: c, runtime: rt));
    await live(tester, 600);
    return c;
  }

  Future<void> shutdown(WidgetTester tester, ProjectController c) async {
    await tester.pumpWidget(const SizedBox());
    final done = c.runtime.dispose();
    await live(tester, 1200);
    await done;
    c.dispose();
  }

  Future<void> push(WidgetTester tester, Widget page) async {
    unawaited(tester.state<NavigatorState>(find.byType(Navigator).first).push(MaterialPageRoute<void>(builder: (_) => page)));
    await live(tester, 900);
  }

  Future<void> openMore(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Mais opções').last);
    await live(tester, 200);
    await tester.tap(find.text('Mais opções').last);
    await live(tester, 900);
  }

  /// O texto está na tela e inteiro (sem "…")? Cabeçalho de grupo de opções
  /// é o SectionHeader do app, em caixa alta.
  void whole(WidgetTester tester, String text) {
    final f = find.text(text).evaluate().isEmpty ? find.text(text.toUpperCase()) : find.text(text);
    expect(f, findsOneWidget, reason: text);
    expect(tester.renderObject<RenderParagraph>(f).didExceedMaxLines, isFalse, reason: '"$text" cortado com …');
  }

  for (final width in [320.0, 360.0]) {
    group('${width.toInt()} dp', () {
      // Tela alta: o formulário inteiro aberto, sem precisar rolar.
      final phone = Size(width, 2600);

      for (final (id, texts) in [
        ('tcp', ['Número na rede', 'ID do escravo (Unit ID) no manual. Quase sempre 1.']),
        ('usb', ['Número na rede', 'ID do escravo no manual. Vários na mesma linha RS-485: um cadastro por ID, mesmo adaptador.']),
        ('s7', ['Bastidor (rack)', 'Posição da CPU', 'O slot da CPU, na configuração de hardware do TIA Portal.']),
        ('ua', ['Caminho (endpoint)', 'O que vem depois da porta no endereço (ex.: /OPCUA/SimulationServer).']),
        ('mq', [
          'Tópico de queda (LWT)',
          'Sinal de vida (s)',
          'Avisa o broker que o app está vivo (keep-alive) e percebe Wi-Fi que caiu. 0 desliga.',
          'Nome no broker (client ID)',
        ]),
      ]) {
        testWidgets('equipamento $id: rótulos novos de "Mais opções" inteiros', (tester) async {
          final c = await boot(tester, phone);
          await push(tester, DeviceFormPage(device: devices.firstWhere((d) => d.id == id)));
          await openMore(tester);
          for (final t in texts) {
            whole(tester, t);
          }
          await shutdown(tester, c);
        });
      }

      testWidgets('variável OPC UA nova: "Endereço (NodeId)" inteiro', (tester) async {
        final c = await boot(tester, phone);
        await push(tester, const TagFormPage(preferDeviceId: 'ua'));
        whole(tester, 'Endereço (NodeId)');
        await shutdown(tester, c);
      });

      testWidgets('mensagem do equipamento: conferência e tamanho máximo inteiros', (tester) async {
        final c = await boot(tester, phone);
        await push(tester, RawProfilePage(device: devices.last));
        await openMore(tester);
        whole(tester, 'Conferência da mensagem (checksum)');
        whole(tester, 'Máximo (bytes)');
        whole(tester, 'expressão (regex)');
        await shutdown(tester, c);
      });
    });
  }

  /// Abre o "?" da página à vista e confere o primeiro balão; anda até o fim
  /// e devolve os títulos dos passos que apareceram.
  Future<List<String>> runTour(WidgetTester tester, String firstBody) async {
    await tester.tap(find.byKey(const ValueKey('ajuda')).hitTestable().last);
    await live(tester, 900);
    expect(find.byKey(const ValueKey('tour-balao')), findsOneWidget);
    expect(find.textContaining(firstBody), findsOneWidget);
    final titles = <String>[];
    while (true) {
      final balloon = find.byKey(const ValueKey('tour-balao'));
      final title = tester.widgetList<Text>(find.descendant(of: balloon, matching: find.byType(Text))).elementAt(1).data!;
      titles.add(title);
      if (find.text('Entendi').evaluate().isNotEmpty) break;
      await tester.tap(find.text('Próximo'));
      await live(tester, 900);
    }
    await tester.tap(find.text('Entendi'));
    await live(tester, 600);
    expect(find.byKey(const ValueKey('tour-balao')), findsNothing);
    return titles;
  }

  testWidgets('Ferramentas tem o "?" com o tutorial da aba, e Câmeras o da página', (tester) async {
    final c = await boot(tester, const Size(360, 760));
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Ferramentas')));
    await live(tester, 600);
    expect(await runTour(tester, 'Grava variáveis para ver o histórico'), ['Registros', 'Do projeto aberto', 'Só neste aparelho'],
        reason: 'os passos com alvo lá embaixo também aparecem');

    await tester.ensureVisible(find.byKey(const ValueKey('cameras'), skipOffstage: false));
    await live(tester, 200);
    await tester.tap(find.byKey(const ValueKey('cameras')));
    await live(tester, 900);
    expect(await runTour(tester, 'A máquina ao vivo, em tela cheia'), ['Câmeras', 'Cadastrar', 'Na tela da máquina', 'Senha']);
    await shutdown(tester, c);
  });
}

/// Avança o relógio simulado em passos de 100 ms (varredura e demo andam).
Future<void> live(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
