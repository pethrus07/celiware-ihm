import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/camera.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/hmi_screen.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/screens/cameras/camera_view_page.dart';
import 'package:ihm/screens/editor/screen_editor_page.dart';
import 'package:ihm/screens/screen_run_page.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/cameras/camera_players.dart';
import 'package:ihm/services/cameras/camera_vault.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_camera_player.dart';

/// Câmeras pela interface (CM-1 a CM-5), com o player trocado por um falso
/// e o cofre em memória: cadastro, senha fora do arquivo, tela cheia com
/// estado e atraso, botão "Abrir câmera", senha pedida depois de importar.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  late Directory dir;
  late MemoryCameraVault vault;
  late FakeCameraHub hub;

  const prensa = Device(id: 'm1', name: 'Prensa', host: '192.168.0.10');
  const cam = IpCamera(
    id: 'cam1',
    name: 'Saída da prensa',
    deviceId: 'm1',
    url: 'rtsp://192.168.1.64:554/Streaming/Channels/101',
    substreamUrl: 'rtsp://192.168.1.64:554/Streaming/Channels/102',
    username: 'admin',
    secretRef: 'ref1',
  );
  const tela = HmiScreen(id: 'a', name: 'Prensa — operação');

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      // Todas as versões já vistas (a trilha de início está na v2).
      for (final (id, _, _) in Tours.catalog) for (final v in [1, 2]) 'tour:v$v:$id': true,
    });
    dir = await Directory.systemTemp.createTemp('ihm_cameras');
    vault = MemoryCameraVault();
    CameraVault.instance = vault;
    hub = FakeCameraHub();
    CameraPlayers.factory = hub.create;
  });

  tearDown(() async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {/* Windows ainda segurando o arquivo */}
  });

  Future<ProjectController> boot(WidgetTester tester, Project project) async {
    final rt = HmiRuntime();
    final repo = ProjectRepository(directory: dir);
    await tester.runAsync(() => repo.save(project));
    final controller = ProjectController(repository: repo, runtime: rt);
    await tester.runAsync(controller.load);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(CeliwareIhmApp(controller: controller, runtime: rt));
    await live(tester, 600);
    return controller;
  }

  Future<void> shutdown(WidgetTester tester, ProjectController c) async {
    await tester.pumpWidget(const SizedBox());
    final done = c.runtime.dispose();
    await live(tester, 1200);
    await done;
    c.dispose();
  }

  Future<void> open(WidgetTester tester, Widget page) async {
    tester.state<NavigatorState>(find.byType(Navigator).first).push(MaterialPageRoute<void>(builder: (_) => page));
    await live(tester, 900);
  }

  /// Mais → Câmeras (a página monta a lista sob demanda: rola até achar).
  Future<void> openCameras(WidgetTester tester) async {
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Ferramentas')));
    await live(tester, 400);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('cameras')), 200, scrollable: find.byType(Scrollable).last);
    await live(tester, 200);
    await tester.tap(find.byKey(const ValueKey('cameras')));
    await live(tester, 700);
  }

  Future<void> tapKey(WidgetTester tester, String key, {int wait = 500}) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await live(tester, 100);
    await tester.tap(find.byKey(ValueKey(key)));
    await live(tester, wait);
  }

  /// "A câmera manda imagem" por [ms]: o vídeo anda e o atraso fica em 0,6 s.
  Future<void> playFor(WidgetTester tester, int ms) async {
    for (var t = 500; t <= ms; t += 500) {
      hub.last.play(Duration(milliseconds: t), ahead: const Duration(milliseconds: 600));
      await live(tester, 500);
    }
  }

  testWidgets('cadastro: URL colada com senha se separa, a senha vai para o cofre e nunca para o arquivo', (tester) async {
    final c = await boot(tester, const Project(name: 'P', devices: [prensa], screens: [tela]));
    await openCameras(tester);
    expect(find.text('Nenhuma câmera'), findsOneWidget);
    await tapKey(tester, 'nova-camera', wait: 700);

    await tester.enterText(find.byKey(const ValueKey('campo-nome-camera')), 'Saída da prensa');
    await tester.enterText(find.byKey(const ValueKey('campo-url-camera')), 'rtsp://admin:s3gr%40d0@192.168.1.64:554/Streaming/Channels/101');
    await live(tester, 400);
    expect(tester.widget<TextField>(find.descendant(of: find.byKey(const ValueKey('campo-url-camera')), matching: find.byType(TextField))).controller!.text,
        'rtsp://192.168.1.64:554/Streaming/Channels/101');
    expect(find.textContaining('Usuário e senha saíram do endereço'), findsOneWidget);
    // Máquina única do projeto já vem escolhida; o fluxo leve é sugerido.
    expect(tester.widget<ChoiceChip>(find.byKey(const ValueKey('maquina-m1'))).selected, isTrue);
    await tapKey(tester, 'sugestao-fluxo-leve');
    await tapKey(tester, 'salvar-camera', wait: 800);

    final saved = c.project.cameras.single;
    expect((saved.name, saved.deviceId, saved.url, saved.substreamUrl, saved.username),
        ('Saída da prensa', 'm1', 'rtsp://192.168.1.64:554/Streaming/Channels/101', 'rtsp://192.168.1.64:554/Streaming/Channels/102', 'admin'));
    expect(vault.entries[saved.secretRef], 's3gr@d0');
    // O que vai para o disco e para o arquivo exportado é este texto.
    final file = String.fromCharCodes(ProjectRepository.encode(c.project));
    expect(file, contains('"secretRef": "cs_'));
    expect(file.contains('s3gr'), isFalse, reason: 'a senha nunca vai para o arquivo do projeto');

    // Na lista, agrupada pela máquina, com o IP.
    expect(find.text('PRENSA'), findsOneWidget);
    expect(find.text('192.168.1.64'), findsOneWidget);
    await shutdown(tester, c);
  });

  // QA visual de 12/10: o IP pela marca abria o teclado de letras, e o
  // rótulo do "Fluxo leve" saía cortado no alto de "Mais opções".
  testWidgets('cadastro: IP da marca com teclado de números; rótulo do fluxo leve inteiro em Mais opções', (tester) async {
    final c = await boot(tester, const Project(name: 'P', devices: [prensa], screens: [tela]));
    await openCameras(tester);
    await tapKey(tester, 'nova-camera', wait: 700);
    await tapKey(tester, 'marca-Hikvision');
    final ip = tester.widget<TextField>(find.byKey(const ValueKey('campo-nome')));
    expect(ip.keyboardType, const TextInputType.numberWithOptions(decimal: true));
    await tester.enterText(find.byKey(const ValueKey('campo-nome')), '192.168.1.64');
    await tapKey(tester, 'ok-nome');
    expect(find.text('rtsp://192.168.1.64:554/Streaming/Channels/101'), findsOneWidget);

    await tester.ensureVisible(find.text('Mais opções'));
    await live(tester, 100);
    await tester.tap(find.text('Mais opções'));
    await live(tester, 900);
    final header = tester.getRect(find.ancestor(of: find.text('Mais opções'), matching: find.byType(ListTile)).first);
    final label = tester.getRect(find.descendant(of: find.byKey(const ValueKey('campo-fluxo-leve')), matching: find.text('Fluxo leve (substream)')));
    expect(label.top, greaterThanOrEqualTo(header.bottom), reason: 'o rótulo flutua acima da caixa e a seção o cortava');
    await shutdown(tester, c);
  });

  testWidgets('tela cheia: conectando → ao vivo com o atraso; segundo plano e fechar soltam o player', (tester) async {
    vault.entries['ref1'] = '1234';
    final c = await boot(tester, const Project(name: 'P', devices: [prensa], screens: [tela], cameras: [cam]));
    await open(tester, const CameraViewPage(cameraId: 'cam1'));
    expect(find.byKey(const ValueKey('estado-camera')), findsOneWidget);
    expect(find.text('Conectando…'), findsOneWidget);
    expect(hub.opened.single, 'rtsp://admin:1234@192.168.1.64:554/Streaming/Channels/102', reason: 'abre o fluxo leve');

    await playFor(tester, 3000);
    expect(find.text('Ao vivo · atraso ~0,6 s'), findsOneWidget);
    expect(find.byKey(const ValueKey('video-falso')), findsOneWidget);
    expect(find.byKey(const ValueKey('estado-camera')), findsNothing, reason: 'ao vivo, só o vídeo e o selo');
    expect(find.byKey(const ValueKey('foto-da-camera')), findsNothing, reason: 'sem endereço de foto, sem botão');

    // Segundo plano: nada fica decodificando; na volta, abre de novo.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await live(tester, 300);
    expect(hub.alive, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await live(tester, 300);
    expect(hub.players, hasLength(2));
    expect(hub.alive, 1);

    // Alta qualidade pelo menu: o fluxo principal.
    await tapKey(tester, 'menu-camera');
    await tester.tap(find.text('Ver em alta qualidade'));
    await live(tester, 500);
    expect(hub.opened.last, 'rtsp://admin:1234@192.168.1.64:554/Streaming/Channels/101');

    // Câmera caiu: sem sinal com o motivo e a contagem.
    hub.last.fail('ERROR_CODE_IO_NETWORK_CONNECTION_FAILED | connect ECONNREFUSED (Connection refused)');
    await live(tester, 200);
    expect(find.text('Sem sinal'), findsOneWidget);
    expect(find.textContaining('recusou a conexão'), findsOneWidget);
    expect(find.text('Sem sinal · de novo em 1 s'), findsOneWidget);

    await tapKey(tester, 'fechar-camera', wait: 800);
    expect(find.byType(CameraViewPage), findsNothing);
    expect(hub.alive, 0, reason: 'fechar para o fluxo');
    await live(tester, 3000);
    expect(hub.alive, 0, reason: 'e não reconecta depois de fechada');
    await shutdown(tester, c);
  });

  testWidgets('senha recusada: botão para digitar, sem insistir; a senha nova abre o vídeo', (tester) async {
    vault.entries['ref1'] = 'errada';
    final c = await boot(tester, const Project(name: 'P', devices: [prensa], screens: [tela], cameras: [cam]));
    await open(tester, const CameraViewPage(cameraId: 'cam1'));
    hub.last.fail('ERROR_CODE_IO_UNSPECIFIED | rtsp DESCRIBE 401');
    await live(tester, 300);
    expect(find.text('Senha recusada'), findsWidgets);
    expect(find.textContaining('recusou o usuário "admin"'), findsOneWidget);
    await live(tester, 20000);
    expect(hub.players, hasLength(1), reason: 'câmera bloqueia o usuário depois de tentativas erradas');

    await tapKey(tester, 'digitar-senha', wait: 600);
    await tester.enterText(find.byKey(const ValueKey('campo-senha-camera-dialogo')), 'certa');
    await tapKey(tester, 'ok-senha-camera', wait: 600);
    expect(vault.entries['ref1'], 'certa');
    expect(hub.opened.last, contains('admin:certa@'));
    await playFor(tester, 1000);
    expect(find.textContaining('Ao vivo'), findsOneWidget);
    await shutdown(tester, c);
  });

  testWidgets('projeto importado: a senha não veio, a lista avisa e a câmera pede antes de abrir o vídeo', (tester) async {
    vault.entries['ref1'] = 'do outro aparelho';
    final imported = const Project(name: 'P', devices: [prensa], screens: [tela], cameras: [cam]).withFreshCameraSecrets();
    final c = await boot(tester, imported);
    await openCameras(tester);
    expect(find.text('192.168.1.64 · falta a senha neste aparelho'), findsOneWidget);

    await tapKey(tester, 'camera-cam1', wait: 900);
    expect(find.byKey(const ValueKey('dialogo-senha-camera')), findsOneWidget, reason: 'pede sozinho');
    expect(hub.players, isEmpty, reason: 'sem senha, nem tenta (não gasta tentativa na câmera)');
    await tester.enterText(find.byKey(const ValueKey('campo-senha-camera-dialogo')), 'nova');
    await tapKey(tester, 'ok-senha-camera', wait: 600);
    final ref = c.project.camera('cam1')!.secretRef!;
    expect(ref, isNot('ref1'));
    expect(vault.entries[ref], 'nova');
    expect(hub.opened.single, contains('admin:nova@'));

    // Trocar o projeto limpa do cofre as senhas que ficaram sem câmera.
    await tester.runAsync(() => vault.prune(const Project().cameraSecretRefs));
    expect(vault.entries, isEmpty);
    await shutdown(tester, c);
  });

  testWidgets('botão "Abrir câmera": escolhe a câmera no editor e abre em tela cheia pela operação', (tester) async {
    vault.entries['ref1'] = '1234';
    final c = await boot(tester, const Project(name: 'P', devices: [prensa], screens: [tela], cameras: [cam]));
    await open(tester, const ScreenEditorPage(screenId: 'a'));
    await tester.tap(find.text('Elemento'));
    await live(tester, 600);
    await tester.tap(find.byKey(const ValueKey('paleta-button')));
    await live(tester, 900);
    await tapKey(tester, 'opcao-ButtonMode.camera');
    expect(find.text('ABRE A CÂMERA'), findsOneWidget);
    expect(find.text('VARIÁVEL'), findsNothing, reason: 'abrir câmera não grava: não pede variável');
    await tapKey(tester, 'escolher-camera-cam1');
    final e = c.project.screen('a')!.elements.single;
    expect((e.props['mode'], e.props['cameraId'], e.props['label'], e.tagId), ('camera', 'cam1', 'Saída da prensa', null));

    // Em operação, mesmo numa tela só de acompanhamento, abre o vídeo.
    c.saveScreen(c.project.screen('a')!.copyWith(readOnly: true));
    tester.state<NavigatorState>(find.byType(Navigator).first).popUntil((r) => r.isFirst);
    await live(tester, 600);
    await open(tester, const ScreenRunPage(screenId: 'a'));
    await tapKey(tester, 'camera-${e.id}', wait: 900);
    expect(find.byType(CameraViewPage), findsOneWidget);
    expect(hub.alive, 1);
    await tapKey(tester, 'fechar-camera', wait: 800);
    expect(find.byType(ScreenRunPage), findsOneWidget, reason: 'voltar devolve a tela de operação');
    expect(hub.alive, 0);

    // Câmera apagada: o botão avisa em vez de abrir uma tela vazia.
    c.deleteCamera('cam1');
    await live(tester, 400);
    expect(find.text('CÂMERA APAGADA'), findsOneWidget);
    await tapKey(tester, 'camera-${e.id}');
    expect(find.text('A câmera deste botão foi apagada.'), findsOneWidget);
    await shutdown(tester, c);
  });
}

Future<void> live(WidgetTester tester, int ms) async {
  for (var t = 0; t < ms; t += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
