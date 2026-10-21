import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/app/project_controller.dart';
import 'package:ihm/main.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/http_config.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/screens/devices/device_form_page.dart';
import 'package:ihm/screens/tags/tag_form_page.dart';
import 'package:ihm/screens/tours.dart';
import 'package:ihm/services/demo/demo_process.dart';
import 'package:ihm/services/demo/demo_project.dart';
import 'package:ihm/services/net/device_vault.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/storage/project_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/http_test_server.dart';

/// Cadastro de equipamento e de variável quando o equipamento fala HTTP: a
/// URL base no lugar do IP, a senha no cofre (nunca no projeto), a requisição
/// e o seletor do valor no lugar do endereço Modbus, e o "Testar" com código,
/// tempo e valor contra um servidor HTTP de verdade.
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  late Directory dir;
  late MemoryDeviceVault vault;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      for (final (id, _, _) in Tours.catalog) for (final v in [1, 2]) 'tour:v$v:$id': true,
    });
    dir = await Directory.systemTemp.createTemp('ihm_http_form');
    DeviceVault.instance = vault = MemoryDeviceVault();
  });

  tearDown(() async {
    DemoRegistry.discard(DemoProject.deviceId);
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } on FileSystemException {/* Windows ainda segurando o arquivo */}
  });

  Future<ProjectController> boot(WidgetTester tester) async {
    // O binding de teste troca o HttpClient por um que responde 400 a tudo;
    // aqui o equipamento é um servidor HTTP de verdade.
    HttpOverrides.global = null;
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
  Future<void> waitFor(WidgetTester tester, Finder finder, {int rounds = 100, Duration step = const Duration(milliseconds: 20)}) async {
    for (var i = 0; i < rounds && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(step);
    }
    expect(finder, findsWidgets);
  }

  /// Rola até [finder] e o põe inteiro na tela (o Salvar cobre o pé).
  Future<void> show(WidgetTester tester, Finder finder, double delta, Finder scrollable) async {
    await tester.scrollUntilVisible(finder, delta, scrollable: scrollable);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }

  HttpTestServer esp32() => HttpTestServer()
    ..json('GET /api/status', {
      'data': {'temperatura': 25.3, 'bomba': true},
      'itens': [
        {'valor': 40},
      ],
    });

  testWidgets('equipamento HTTP: URL no lugar do IP, senha testada antes de salvar e guardada no cofre', (tester) async {
    HttpOverrides.global = null;
    final server = esp32()
      ..user = 'admin'
      ..password = 's3nha';
    await tester.runAsync(server.start);
    final c = await boot(tester);
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute<void>(builder: (_) => const DeviceFormPage()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('campo-nome-equipamento')), 'ESP32 da bomba');
    await tester.enterText(find.widgetWithText(TextFormField, 'IP do equipamento'), '127.0.0.1');
    await tester.ensureVisible(find.text('Mais opções'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mais opções'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('protocolo-http')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('protocolo-http')));
    await tester.pumpAndSettle();
    expect(find.text('Número na rede'), findsNothing, reason: 'HTTP não tem ID do escravo');
    expect(find.text('Marca e modelo'), findsNothing);
    expect(find.text('HTTP · sem senha'), findsOneWidget);

    // A URL nasce do IP que já estava digitado; porta e caminho entram nela.
    await tester.drag(find.byType(ListView).last, const Offset(0, 3000));
    await tester.pumpAndSettle();
    final url = find.widgetWithText(TextFormField, 'Endereço do equipamento');
    expect(tester.widget<TextFormField>(url).controller!.text, 'http://127.0.0.1');
    await tester.ensureVisible(url);
    await tester.enterText(url, 'http://127.0.0.1:${server.port}/api');
    await tester.pumpAndSettle();

    // Sem senha: o equipamento pede.
    await tester.ensureVisible(find.byKey(const ValueKey('testar-conexao')));
    await tester.tap(find.byKey(const ValueKey('testar-conexao')));
    await waitFor(tester, find.byKey(const ValueKey('teste-falhou')));
    await tester.pumpAndSettle();
    expect(find.text('Não conectou: 401: o equipamento pede usuário e senha'), findsOneWidget);
    expect(find.text('O equipamento está na rede, mas não aceitou:'), findsOneWidget);

    final list = find.descendant(of: find.byType(Form), matching: find.byType(Scrollable)).first;
    await show(tester, find.byKey(const ValueKey('http-auth-basic')), 300, list);
    await tester.tap(find.byKey(const ValueKey('http-auth-basic')));
    await tester.pumpAndSettle();
    await show(tester, find.byKey(const ValueKey('campo-senha-http')), 300, list);
    await tester.enterText(find.byKey(const ValueKey('campo-usuario-http')), 'admin');
    await tester.enterText(find.byKey(const ValueKey('campo-senha-http')), 'errada');
    await tester.pumpAndSettle();
    await show(tester, find.byKey(const ValueKey('testar-conexao')), -300, list);
    await tester.tap(find.byKey(const ValueKey('testar-conexao')));
    await waitFor(tester, find.text('Não conectou: 401: o equipamento recusou o usuário ou a senha'));
    expect(find.textContaining('Maiúsculas contam'), findsOneWidget);
    expect(vault.entries, isEmpty, reason: 'testar não grava nada no cofre');

    await show(tester, find.byKey(const ValueKey('campo-senha-http')), 300, list);
    await tester.enterText(find.byKey(const ValueKey('campo-senha-http')), 's3nha');
    await tester.pumpAndSettle();
    await show(tester, find.byKey(const ValueKey('testar-conexao')), -300, list);
    await tester.tap(find.byKey(const ValueKey('testar-conexao')));
    await waitFor(tester, find.byKey(const ValueKey('teste-ok')));
    expect(find.textContaining('Equipamento respondeu'), findsOneWidget);
    expect(server.requests.last.path, '/api', reason: 'o teste pergunta na URL base');

    await tester.tap(find.byKey(const ValueKey('salvar-equipamento')));
    await tester.pumpAndSettle();
    final d = c.project.devices.last;
    expect(d.kind, DeviceKind.http);
    expect((d.host, d.port, d.http.basePath, d.http.auth, d.http.username), ('127.0.0.1', server.port, '/api', HttpAuth.basic, 'admin'));
    expect(d.http.pendingSecret, isNull);
    expect(vault.entries[d.http.secretRef], 's3nha');
    expect(jsonEncode(d.toJson()), isNot(contains('s3nha')), reason: 'a senha nunca vai para o arquivo do projeto');
    expect(d.addressLabel, 'http://127.0.0.1:${server.port}/api · HTTP · admin');

    // Reaberto: a senha vem do cofre (escondida) e nada está pendente.
    nav.push(MaterialPageRoute<void>(builder: (_) => DeviceFormPage(device: d)));
    await tester.pumpAndSettle();
    expect(find.text('HTTP · admin'), findsOneWidget);
    nav.pop();
    await tester.pumpAndSettle();
    expect(find.text('Descartar alterações?'), findsNothing, reason: 'senha lida do cofre não é alteração');

    await shutdown(tester, c);
    await tester.runAsync(server.stop);
  });

  testWidgets('variável HTTP: caminho e campo no lugar do Modbus, Testar com código e tempo, campo escolhido com um toque', (tester) async {
    HttpOverrides.global = null;
    final server = esp32();
    await tester.runAsync(server.start);
    final c = await boot(tester);
    final d = Device(id: 'esp', name: 'ESP32', kind: DeviceKind.http, host: '127.0.0.1', port: server.port, timeoutMs: 3000);
    c.saveDevice(d);
    await tester.pump();
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute<void>(builder: (_) => const TagFormPage(preferDeviceId: 'esp')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('campo-endereco')), findsNothing, reason: 'endereço Modbus dá lugar à requisição');
    expect(find.byKey(const ValueKey('campo-caminho-http')), findsOneWidget);
    final form = find.descendant(of: find.byKey(const ValueKey('formulario-variavel')), matching: find.byType(Scrollable)).first;

    // Caminho que não existe: o Testar diz o código em palavras.
    await tester.enterText(find.byKey(const ValueKey('campo-caminho-http')), '/api/nada');
    await tester.pump();
    expect(find.text('http://127.0.0.1:${server.port}/api/nada'), findsOneWidget, reason: 'a URL inteira embaixo, como prova');
    await show(tester, find.byKey(const ValueKey('testar-http')), 200, form);
    await tester.tap(find.byKey(const ValueKey('testar-http')));
    await waitFor(tester, find.byKey(const ValueKey('http-teste-falhou')));
    expect(tester.widget<Text>(find.byKey(const ValueKey('http-teste-texto'))).data, '404: caminho não existe');
    expect(find.textContaining('404 · '), findsOneWidget);

    // Caminho certo, sem campo: a resposta é um JSON; os campos aparecem para tocar.
    await show(tester, find.byKey(const ValueKey('campo-caminho-http')), -200, form);
    await tester.enterText(find.byKey(const ValueKey('campo-caminho-http')), '/api/status');
    await tester.pump();
    await show(tester, find.byKey(const ValueKey('testar-http')), 200, form);
    await tester.tap(find.byKey(const ValueKey('testar-http')));
    await waitFor(tester, find.byKey(const ValueKey('http-campo-data.temperatura')));
    expect(find.textContaining('A resposta é um JSON: diga qual campo ler'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('http-campo-data.temperatura')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('http-campo-data.temperatura')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('campo-seletor-http'))).controller!.text, 'data.temperatura');
    await show(tester, find.byKey(const ValueKey('campo-nome-variavel')), -300, form);
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('campo-nome-variavel'))).controller!.text, 'Temperatura');

    await show(tester, find.byKey(const ValueKey('testar-http')), 200, form);
    await tester.tap(find.byKey(const ValueKey('testar-http')));
    await waitFor(tester, find.byKey(const ValueKey('http-teste-ok')));
    expect(find.text('Valor: 25,3'), findsOneWidget);
    expect(find.textContaining('200 · '), findsOneWidget);
    await waitFor(tester, find.descendant(of: find.byKey(const ValueKey('lendo-agora')), matching: find.text('25,3')), rounds: 120, step: const Duration(milliseconds: 100));

    // Gravável: o comando aparece, com {valor}.
    await show(tester, find.byKey(const ValueKey('pode-gravar')), 200, form);
    await tester.tap(find.byKey(const ValueKey('pode-gravar')));
    await tester.pumpAndSettle();
    await show(tester, find.byKey(const ValueKey('campo-corpo-gravar-http')), 200, form);
    await tester.enterText(find.byKey(const ValueKey('campo-caminho-gravar-http')), '/api/setpoint');
    await tester.enterText(find.byKey(const ValueKey('campo-corpo-gravar-http')), '{"setpoint": {valor}}');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('salvar-variavel')));
    await tester.pumpAndSettle();
    final t = c.project.tags.last;
    expect(t.deviceId, 'esp');
    expect(t.name, 'Temperatura');
    expect(t.dataType, TagDataType.float32);
    expect(t.decimals, 1, reason: 'casas do valor visto (25,3)');
    expect(t.writable, isTrue);
    expect(t.http, const HttpTagAddress(path: '/api/status', select: 'data.temperatura', writePath: '/api/setpoint', writeBody: '{"setpoint": {valor}}'));
    expect(t.addressLabel, 'GET /api/status · data.temperatura');

    await shutdown(tester, c);
    await tester.runAsync(server.stop);
  });
}
