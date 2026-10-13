import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/core/modbus/modbus_framing.dart';
import 'package:ihm/core/modbus/modbus_memory.dart';
import 'package:ihm/core/modbus/modbus_tcp_server.dart';
import 'package:ihm/core/theme/app_theme.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/mqtt_config.dart';
import 'package:ihm/models/opcua_config.dart';
import 'package:ihm/models/raw_config.dart';
import 'package:ihm/models/serial_config.dart';
import 'package:ihm/screens/devices/device_form_page.dart';
import 'package:ihm/screens/devices/network_scan_sheet.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/net/local_network.dart';
import 'package:ihm/services/net/modbus_discovery.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cadastro de equipamento: "Procurar na rede" (item 94) e os três achados
/// do QA visual de 12/10 — sair sem salvar pergunta, o erro do IP some quando
/// o IP é corrigido, e o teclado não volta depois da folha de marca e modelo.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  late Directory dir;

  const wifi = LocalNet(type: 'wifi', ip: '192.168.7.40', prefix: 24);
  const ipError = 'Informe o IP do equipamento (ex.: 192.168.0.10)';

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      for (final (id, _, _) in Tours.catalog) 'tour:v1:$id': true,
    });
    dir = await Directory.systemTemp.createTemp('ihm_device_form');
  });

  tearDown(() async {
    ModbusDiscovery.debugReset();
    DemoRegistry.discard(DemoProject.deviceId);
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {/* Windows ainda segurando o arquivo */}
  });

  /// [tall]: janela alta o bastante para "Mais opções" aberto caber inteiro
  /// (nada sai da tela e deixa de ser construído pela lista). [dp]: janela
  /// medida em dp (densidade 1), como no QA visual.
  Future<ProjectController> boot(WidgetTester tester, {bool tall = false, Size? dp}) async {
    final runtime = HmiRuntime();
    final c = ProjectController(repository: ProjectRepository(directory: dir), runtime: runtime);
    await tester.runAsync(c.load);
    tester.view.physicalSize = dp ?? Size(1080, tall ? 6000 : 2400);
    tester.view.devicePixelRatio = dp == null ? 2.75 : 1;
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

  Future<void> open(WidgetTester tester, [Device? device]) async {
    unawaited(tester.state<NavigatorState>(find.byType(Navigator).first).push(MaterialPageRoute<void>(builder: (_) => DeviceFormPage(device: device))));
    await tester.pumpAndSettle();
  }

  final ipField = find.widgetWithText(TextFormField, 'IP do equipamento');
  final form = find.byType(DeviceFormPage);
  final discard = find.byKey(const ValueKey('descartar-alteracoes'));

  String ipText(WidgetTester tester) => tester.widget<TextFormField>(ipField).controller!.text;

  /// O teclado está fechado e nenhum campo de texto tem o foco.
  void expectKeyboardClosed(WidgetTester tester) {
    expect(tester.testTextInput.isVisible, isFalse, reason: 'o teclado não pode voltar sozinho');
    expect(FocusManager.instance.primaryFocus?.context?.widget, isNot(isA<EditableText>()));
  }

  group('sair sem salvar', () {
    testWidgets('sem alteração sai direto, em qualquer protocolo', (tester) async {
      final c = await boot(tester);
      final devices = [
        const Device(id: 'tcp', name: 'CLP', host: '192.168.0.10', profile: 'inovance-h3u'),
        const Device(id: 'rtu', name: 'Gateway', kind: DeviceKind.modbusRtuTcp, framing: ModbusFraming.ascii, host: '192.168.0.11', port: 4001, unitId: 3),
        const Device(id: 'mq', name: 'Broker', kind: DeviceKind.mqtt, host: '192.168.0.12', port: 1883, mqtt: MqttBroker(username: 'ihm', password: 'x', statusTopic: 'a/status')),
        const Device(id: 's7', name: 'S7', kind: DeviceKind.s7, host: '192.168.0.13', port: 102),
        const Device(id: 'ua', name: 'Servidor', kind: DeviceKind.opcua, host: '192.168.0.14', port: 4840, opcua: OpcUaConfig(path: '/OPCUA/Sim')),
        const Device(id: 'raw', name: 'Arduino', kind: DeviceKind.raw, host: '192.168.0.15', port: RawConfig.defaultPort),
        const Device(id: 'usb', name: 'Inversor', kind: DeviceKind.usbSerial, serial: SerialConfig()),
        c.project.device(DemoProject.deviceId)!,
      ];
      for (final d in devices) {
        c.saveDevice(d);
      }
      await tester.pump();
      for (final d in [null, ...devices]) {
        await open(tester, d);
        await tester.tap(find.byTooltip('Voltar'));
        await tester.pumpAndSettle();
        expect(discard, findsNothing, reason: d?.kind.name ?? 'novo');
        expect(form, findsNothing, reason: d?.kind.name ?? 'novo');
      }
      await shutdown(tester, c);
    });

    testWidgets('com alteração pergunta "Descartar alterações?": continuar, descartar ou salvar', (tester) async {
      final c = await boot(tester);
      final before = c.project.devices.length;
      await open(tester);
      await tester.enterText(find.byKey(const ValueKey('campo-nome-equipamento')), 'Prensa');
      await tester.pump();

      await tester.tap(find.byTooltip('Voltar'));
      await tester.pumpAndSettle();
      expect(discard, findsOneWidget);
      expect(find.text('Descartar alterações?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('continuar-editando')));
      await tester.pumpAndSettle();
      expect(form, findsOneWidget);
      expect(find.text('Prensa'), findsOneWidget, reason: 'o que foi digitado continua lá');

      // O "voltar" do Android passa pela mesma pergunta.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(discard, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('descartar')));
      await tester.pumpAndSettle();
      expect(form, findsNothing);
      expect(c.project.devices, hasLength(before));

      // Editando: "Salvar" no diálogo grava e sai.
      c.saveDevice(const Device(id: 'clp', name: 'CLP', host: '192.168.0.10'));
      await tester.pump();
      await open(tester, c.project.device('clp'));
      await tester.enterText(find.byKey(const ValueKey('campo-nome-equipamento')), 'CLP da prensa');
      await tester.tap(find.byTooltip('Voltar'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('salvar-e-sair')));
      await tester.pumpAndSettle();
      expect(form, findsNothing);
      expect(c.project.device('clp')!.name, 'CLP da prensa');
      await shutdown(tester, c);
    });
  });

  testWidgets('o erro do IP some quando o IP é corrigido, sem testar de novo', (tester) async {
    final c = await boot(tester);
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('testar-conexao')));
    await tester.pump();
    expect(find.text(ipError), findsOneWidget);
    expect(find.text('Dê um nome'), findsNothing, reason: 'o teste só confere o IP');

    await tester.enterText(ipField, '192.168');
    await tester.pump();
    expect(find.text(ipError), findsNothing);
    expect(find.text('IP incompleto: são 4 números separados por ponto'), findsOneWidget, reason: 'enquanto corrige, diz o que falta');
    await tester.enterText(ipField, '192.168.0.10');
    await tester.pump();
    expect(find.textContaining('IP incompleto'), findsNothing);
    expect(find.text(ipError), findsNothing);
    expect(find.text('Dê um nome'), findsNothing);

    // O mesmo depois do Salvar: o "Dê um nome" some ao dar o nome.
    await tester.tap(find.byKey(const ValueKey('salvar-equipamento')));
    await tester.pump();
    expect(find.text('Dê um nome'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('campo-nome-equipamento')), 'Prensa');
    await tester.pump();
    expect(find.text('Dê um nome'), findsNothing);
    await shutdown(tester, c);
  });

  testWidgets('escolher marca e modelo não reabre o teclado', (tester) async {
    final c = await boot(tester, tall: true);
    await open(tester);
    await tester.enterText(find.byKey(const ValueKey('campo-nome-equipamento')), 'CLP');
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.tap(find.text('Mais opções'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('marca-modelo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('marca-modelo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('perfil-inovance-h3u')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const ValueKey('marca-modelo')), matching: find.text('Inovance H3U')), findsOneWidget);
    expectKeyboardClosed(tester);

    // Fechar a folha sem escolher também não.
    await tester.enterText(find.byKey(const ValueKey('campo-nome-equipamento')), 'CLP 2');
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('marca-modelo')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('marca-modelo')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('perfil-generico')), findsNothing);
    expectKeyboardClosed(tester);
    await shutdown(tester, c);
  });

  group('Procurar na rede', () {
    testWidgets('acha, separa quem fala Modbus, e tocar preenche IP e porta', (tester) async {
      final bound = <String>[];
      late _Answering scan;
      ModbusDiscovery.debugOverride(
        networks: () async => const [LocalNet(type: 'cabo', ip: '10.0.0.5', prefix: 24), wifi],
        bind: (ip) async => bound.add(ip),
        create: (ports) => scan = _Answering(ports, {'192.168.7.10:502': true, '192.168.7.37:5020': false}),
      );
      final c = await boot(tester);
      c.saveDevice(const Device(id: 'clp', name: 'CLP da cortadora', host: '192.168.7.10'));
      await tester.pump();
      await open(tester);
      await tester.enterText(ipField, '192.');
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('procurar-na-rede')));
      await tester.pumpAndSettle();
      expect(bound, ['192.168.7.40'], reason: 'as conexões saem pelo Wi-Fi (não pelo cabo, nem pelo 4G)');
      expect(scan.ports, [502, 5020]);
      expect(scan.tried, hasLength(253 * 2), reason: 'só a /24 do Wi-Fi, sem o próprio celular');
      expect(scan.tried, isNot(contains('192.168.7.40:502')));
      expect(find.text('Achados no Wi-Fi 192.168.7.x. Toque para usar.'), findsOneWidget);

      final plc = find.byKey(const ValueKey('achado-192.168.7.10:502'));
      final other = find.byKey(const ValueKey('achado-192.168.7.37:5020'));
      expect(find.descendant(of: plc, matching: find.text('Responde Modbus · porta 502\nJá cadastrado: CLP da cortadora')), findsOneWidget);
      expect(find.descendant(of: other, matching: find.text('Porta 5020 aberta, sem resposta Modbus')), findsOneWidget);
      expect(tester.getTopLeft(plc).dy, lessThan(tester.getTopLeft(other).dy), reason: 'em ordem de IP');
      expect(tester.getSize(other).height, greaterThanOrEqualTo(48));

      await tester.tap(other);
      await tester.pumpAndSettle();
      expect(find.byType(NetworkScanSheet), findsNothing);
      expect(ipText(tester), '192.168.7.37');
      expect(find.text('Modbus TCP · Porta 5020 · ID 1'), findsOneWidget, reason: 'a porta veio junto');
      expectKeyboardClosed(tester);
      await shutdown(tester, c);
    });

    testWidgets('Parar: nada novo começa, o achado fica; fechar a folha também para', (tester) async {
      final scans = <_Hanging>[];
      ModbusDiscovery.debugOverride(networks: () async => const [wifi], bind: (_) async {}, create: (ports) {
        final s = _Hanging(ports);
        scans.add(s);
        return s;
      });
      final c = await boot(tester, tall: true);
      await open(tester);
      // Porta mexida à mão entra na procura.
      await tester.tap(find.text('Mais opções'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, 'Porta'), '503');
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('procurar-na-rede')));
      // A folha sobe (a procura fica no ar: nada de pumpAndSettle).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final scan = scans.single;
      expect(scan.ports, [502, 5020, 503]);
      expect(scan.started, 32, reason: '32 tentativas por vez');
      expect(find.text('Procurando no Wi-Fi 192.168.7.x…'), findsOneWidget);
      expect(find.byKey(const ValueKey('procura-progresso')), findsOneWidget);

      scan.answer('192.168.7.1:502', modbus: true);
      await tester.pump();
      expect(find.byKey(const ValueKey('achado-192.168.7.1:502')), findsOneWidget, reason: 'aparece na hora, antes do fim');
      final progress = tester.widget<LinearProgressIndicator>(find.byKey(const ValueKey('procura-progresso'))).value!;
      expect(progress, closeTo(1 / (253 * 3), 1e-9));

      await tester.tap(find.byKey(const ValueKey('parar-procura')));
      await tester.pump();
      expect(scan.cancelled, isTrue);
      final started = scan.started;
      await tester.pump(const Duration(milliseconds: 300));
      expect(scan.started, started, reason: 'parou de verdade');
      expect(find.text('Procura parada no Wi-Fi 192.168.7.x.'), findsOneWidget);
      expect(find.byKey(const ValueKey('procura-progresso')), findsNothing);
      expect(find.byKey(const ValueKey('achado-192.168.7.1:502')), findsOneWidget, reason: 'o que achou continua tocável');

      // De novo, e fechar no meio: a procura para junto.
      await tester.tap(find.byKey(const ValueKey('procurar-de-novo')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(scans, hasLength(2));
      expect(find.byKey(const ValueKey('achado-192.168.7.1:502')), findsNothing, reason: 'recomeça do zero');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(NetworkScanSheet), findsNothing);
      expect(scans.last.cancelled, isTrue);
      expect(form, findsOneWidget, reason: 'fechou só a folha');
      await shutdown(tester, c);
    });

    testWidgets('sem Wi-Fi diz o que fazer; fora do Android, pede o IP', (tester) async {
      List<LocalNet>? nets = const [];
      var created = 0;
      ModbusDiscovery.debugOverride(networks: () async => nets, bind: (_) async {}, create: (ports) {
        created++;
        return ModbusDiscovery(ports: ports);
      });
      final c = await boot(tester);
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('procurar-na-rede')));
      await tester.pumpAndSettle();
      expect(find.text('O celular não está em nenhum Wi-Fi. Conecte ao Wi-Fi da máquina e procure de novo.'), findsOneWidget);
      expect(find.byKey(const ValueKey('procurar-de-novo')), findsOneWidget);

      nets = null;
      await tester.tap(find.byKey(const ValueKey('procurar-de-novo')));
      await tester.pumpAndSettle();
      expect(find.text('Este aparelho não informa a rede. Digite o IP do equipamento.'), findsOneWidget);
      expect(find.byKey(const ValueKey('procurar-de-novo')), findsNothing);
      expect(created, 0, reason: 'sem rede, nada é varrido');
      await shutdown(tester, c);
    });

    testWidgets('só no Modbus TCP', (tester) async {
      final c = await boot(tester, tall: true);
      await open(tester);
      expect(find.byKey(const ValueKey('procurar-na-rede')), findsOneWidget);
      await tester.tap(find.text('Mais opções'));
      await tester.pumpAndSettle();
      for (final p in ['mqtt', 's7', 'rtu', 'opcua', 'raw']) {
        await tester.ensureVisible(find.byKey(ValueKey('protocolo-$p')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('protocolo-$p')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('procurar-na-rede')), findsNothing, reason: p);
      }
      await tester.ensureVisible(find.byKey(const ValueKey('protocolo-tcp')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('protocolo-tcp')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('procurar-na-rede')), findsOneWidget);
      await shutdown(tester, c);
    });

    testWidgets('de ponta a ponta: servidor Modbus de verdade numa porta local', (tester) async {
      // Rede no relógio real (runAsync), tela no simulado (pump), como no
      // "ouvir o broker". A faixa da rede já tem teste próprio: aqui a
      // procura de verdade (socket, cliente Modbus) vai só ao 127.0.0.1.
      final server = ModbusTcpServer(ModbusMemory(holdingRegisters: 10));
      await tester.runAsync(server.start);
      ModbusDiscovery.debugOverride(
        networks: () async => const [wifi],
        bind: (_) async {},
        create: (_) => _Loopback(server.port),
      );
      final c = await boot(tester);
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('procurar-na-rede')));
      final row = find.byKey(ValueKey('achado-127.0.0.1:${server.port}'));
      for (var i = 0; i < 100 && find.byKey(const ValueKey('procurar-de-novo')).evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('Responde Modbus · porta ${server.port}')), findsOneWidget);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(ipText(tester), '127.0.0.1');
      expect(find.text('Modbus TCP · Porta ${server.port} · ID 1'), findsOneWidget);
      await shutdown(tester, c);
      for (var i = 0; i < 10 && server.clientCount > 0; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      }
      expect(server.clientCount, 0, reason: 'a confirmação fechou a conexão');
      await tester.runAsync(server.stop);
    });
  });

  group('320 dp, com as fontes reais', () {
    // IBM Plex de verdade, não a fonte de teste: "cortado com …" depende da
    // largura real do texto.
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

    testWidgets('o erro do IP aparece inteiro e a lupa não fica vermelha junto', (tester) async {
      final c = await boot(tester, dp: const Size(320, 720));
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('testar-conexao')));
      // Até o fim da transição: a cor do erro chega animada.
      await tester.pumpAndSettle();
      expect(tester.renderObject<RenderParagraph>(find.text(ipError)).didExceedMaxLines, isFalse, reason: 'era "Informe o IP do equipamento (ex.: 192…"');
      final icon = find.byIcon(Icons.wifi_find_rounded);
      expect(IconTheme.of(tester.element(icon)).color, Ind.textDim, reason: 'a lupa é ação, não estado');
      expect(tester.getSize(find.byKey(const ValueKey('procurar-na-rede'))), const Size(48, 48));
      await shutdown(tester, c);
    });
  });
}

/// A procura de verdade, mas só no 127.0.0.1 (onde está o servidor do teste).
class _Loopback extends ModbusDiscovery {
  _Loopback(int port) : super(ports: [port]);

  @override
  Future<List<DiscoveredDevice>> scan(List<String> hosts, {void Function(DiscoveredDevice found)? onFound, void Function(int done, int total)? onProgress}) =>
      super.scan(const ['127.0.0.1'], onFound: onFound, onProgress: onProgress);
}

/// Procura que responde na hora, pelo roteiro: verdadeiro = fala Modbus,
/// falso = só abriu a porta; fora do roteiro, ninguém.
class _Answering extends ModbusDiscovery {
  _Answering(List<int> ports, this.script) : super(ports: ports);
  final Map<String, bool> script;
  final List<String> tried = [];

  @override
  Future<DiscoveredDevice?> probe(String host, int port) async {
    tried.add('$host:$port');
    final modbus = script['$host:$port'];
    return modbus == null ? null : DiscoveredDevice(host: host, port: port, modbus: modbus);
  }
}

/// Procura em que cada tentativa fica no ar até o teste responder — ou até
/// ser cancelada, como as conexões de verdade.
class _Hanging extends ModbusDiscovery {
  _Hanging(List<int> ports) : super(ports: ports);
  final Map<String, Completer<DiscoveredDevice?>> _pending = {};
  int started = 0;

  @override
  Future<DiscoveredDevice?> probe(String host, int port) {
    started++;
    return (_pending['$host:$port'] = Completer<DiscoveredDevice?>()).future;
  }

  void answer(String key, {required bool modbus}) {
    final i = key.lastIndexOf(':');
    _pending.remove(key)!.complete(DiscoveredDevice(host: key.substring(0, i), port: int.parse(key.substring(i + 1)), modbus: modbus));
  }

  @override
  void cancel() {
    super.cancel();
    for (final c in _pending.values) {
      c.complete(null);
    }
    _pending.clear();
  }
}
