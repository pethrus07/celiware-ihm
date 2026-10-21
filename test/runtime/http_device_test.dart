import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ihm/core/http/http_error.dart';
import 'package:ihm/models/device.dart';
import 'package:ihm/models/http_config.dart';
import 'package:ihm/models/project.dart';
import 'package:ihm/models/tag.dart';
import 'package:ihm/services/net/device_vault.dart';
import 'package:ihm/services/runtime/drivers/http_driver.dart';
import 'package:ihm/services/runtime/hmi_runtime.dart';
import 'package:ihm/services/runtime/tag_codec.dart';
import 'package:ihm/services/runtime/tag_store.dart';

import '../support/http_test_server.dart';

Tag ht(String id, String path, String select,
        {TagDataType type = TagDataType.float32,
        bool writable = false,
        double scale = 1,
        HttpExtract extract = HttpExtract.json,
        HttpMethod method = HttpMethod.get,
        String body = '',
        HttpMethod writeMethod = HttpMethod.post,
        String writePath = '',
        String writeBody = ''}) =>
    Tag(
      id: id,
      name: id,
      deviceId: 'esp',
      dataType: type,
      writable: writable,
      scale: scale,
      http: HttpTagAddress(method: method, path: path, body: body, extract: extract, select: select, writeMethod: writeMethod, writePath: writePath, writeBody: writeBody),
    );

/// Equipamento HTTP pelo caminho de produção — fábrica → HttpDriver → sessão
/// → TagStore — contra um `HttpServer` do `dart:io`, por socket de verdade.
void main() {
  late HttpTestServer server;
  late Device device;
  final runtimes = <HmiRuntime>[];
  var temperatura = 25.3;
  var bomba = 1;
  var setpoint = 40;

  HmiRuntime runtime() {
    final rt = HmiRuntime();
    runtimes.add(rt);
    return rt;
  }

  setUp(() async {
    DeviceVault.instance = MemoryDeviceVault();
    temperatura = 25.3;
    bomba = 1;
    setpoint = 40;
    server = HttpTestServer();
    server.route('GET /api/status', (_) => (200, jsonEncode({'data': {'temperatura': temperatura, 'bomba': bomba == 1}, 'itens': [{'valor': setpoint}]})));
    server.route('GET /texto', (_) => (200, 'T=${temperatura.toStringAsFixed(1)}C'));
    server.route('POST /api/consulta', (r) => (200, jsonEncode({'eco': (jsonDecode(r.body) as Map)['canal']})));
    server.route('POST /api/bomba', (r) {
      bomba = (jsonDecode(r.body) as Map)['ligar'] as int;
      return (200, '{"ok": true}');
    });
    server.route('PUT /api/setpoint', (r) {
      setpoint = int.parse(r.body);
      return (204, '');
    });
    server.route('GET /api/set', (r) {
      setpoint = int.parse(r.uri.queryParameters['v']!);
      return (200, 'ok');
    });
    server.route('GET /quebrado', (_) => (500, 'pane'));
    await server.start();
    device = Device(id: 'esp', name: 'ESP32', kind: DeviceKind.http, host: '127.0.0.1', port: server.port, timeoutMs: 800, pollMs: 50);
  });

  tearDown(() async {
    for (final rt in runtimes) {
      await rt.dispose();
    }
    runtimes.clear();
    await server.stop();
  });

  Future<void> until(bool Function() ok, {int ms = 4000, String? what}) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('não aconteceu em $ms ms${what == null ? '' : ': $what'}');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('lê por intervalo: requisições iguais uma vez por ciclo, várias variáveis da mesma resposta', () async {
    final tags = [
      ht('temp', '/api/status', 'data.temperatura'),
      ht('bomba', '/api/status', 'data.bomba', type: TagDataType.bool),
      ht('sp', '/api/status', 'itens[0].valor', type: TagDataType.uint16),
      ht('texto', '/texto', r'T=(?<valor>[\d.]+)C', extract: HttpExtract.regex),
      ht('post', '/api/consulta', 'eco', type: TagDataType.uint16, method: HttpMethod.post, body: '{"canal": 3}'),
    ];
    final rt = runtime();
    final probe = await rt.probe(device);
    expect(probe.ok, isTrue, reason: probe.message);
    expect((await rt.probe(device, tag: tags.first)).value, 25.3);

    await rt.apply(Project(devices: [device], tags: tags));
    final sub = rt.subscribe(tags.map((t) => t.id));
    await until(() => tags.every((t) => rt.watch(t.id).value.isGood), what: 'todas boas');
    expect(rt.watch('temp').value.value, 25.3);
    expect(rt.watch('bomba').value.value, isTrue);
    expect(rt.watch('sp').value.value, 40);
    expect(rt.watch('texto').value.value, 25.3);
    expect(rt.watch('post').value.value, 3);
    expect(rt.health('esp')!.value.online, isTrue);
    expect(rt.health('esp')!.value.blocks, 3, reason: 'três requisições diferentes por ciclo, não cinco variáveis');

    // Por ciclo, /api/status vai uma vez só para três variáveis.
    server.requests.clear();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final status = server.count('GET', '/api/status'), texto = server.count('GET', '/texto');
    expect(status, greaterThan(1));
    expect((status - texto).abs(), lessThanOrEqualTo(1), reason: 'uma requisição de cada por ciclo');

    temperatura = 31.7;
    await until(() => rt.watch('temp').value.value == 31.7 && rt.watch('texto').value.value == 31.7, what: 'valor novo');
    sub.cancel();
  });

  test('grava pelo comando: {valor} no corpo (POST/PUT) e na URL (GET), escala desfeita', () async {
    final tags = [
      ht('bomba', '/api/status', 'data.bomba', type: TagDataType.bool, writable: true, writePath: '/api/bomba', writeBody: '{"ligar": {valor}}'),
      ht('sp', '/api/status', 'itens[0].valor', type: TagDataType.uint16, writable: true, writeMethod: HttpMethod.put, writePath: '/api/setpoint'),
      ht('sp10', '/api/status', 'itens[0].valor', writable: true, scale: 0.1, writeMethod: HttpMethod.get, writePath: '/api/set?v={valor}'),
      ht('so-leitura', '/api/status', 'data.temperatura'),
    ];
    final rt = runtime();
    await rt.apply(Project(devices: [device], tags: tags));
    final sub = rt.subscribe(tags.map((t) => t.id));
    await until(() => rt.watch('bomba').value.isGood);

    await rt.write('bomba', false);
    expect(bomba, 0);
    final sent = server.requests.lastWhere((r) => r.path == '/api/bomba');
    expect(sent.body, '{"ligar": 0}');
    expect(sent.headers['content-type'], startsWith('application/json'));
    await until(() => rt.watch('bomba').value.value == false, what: 'o elemento mostra o que o equipamento devolveu');

    await rt.write('sp', 55);
    expect(setpoint, 55, reason: 'PUT com o valor no corpo (204 também é sucesso)');
    await rt.write('sp10', 6.2);
    expect(setpoint, 62, reason: 'GET com o valor na URL, sem a escala');
    await expectLater(rt.write('so-leitura', 1), throwsA(isA<TagValueError>()));
    sub.cancel();
  });

  test('erros: 404 só na variável dele, 500 deixa o último valor, tempo esgotado = sem comunicação', () async {
    final tags = [
      ht('temp', '/api/status', 'data.temperatura'),
      ht('perdida', '/api/naoexiste', 'x'),
      ht('pane', '/quebrado', ''),
      ht('campo', '/api/status', 'data.pressao'),
    ];
    final rt = runtime();
    await rt.apply(Project(devices: [device], tags: tags));
    final sub = rt.subscribe(tags.map((t) => t.id));
    await until(() => rt.watch('temp').value.isGood && rt.watch('perdida').value.quality == TagQuality.addressError && rt.watch('pane').value.quality == TagQuality.commLost);
    expect(rt.watch('perdida').value.message, '404: caminho não existe');
    expect(rt.watch('pane').value.quality, TagQuality.commLost);
    expect(rt.watch('pane').value.message, '500: erro interno do equipamento');
    expect(rt.watch('campo').value.quality, TagQuality.configError);
    expect(rt.watch('campo').value.message, 'o campo "data.pressao" não veio na resposta');
    expect(rt.health('esp')!.value.online, isTrue, reason: 'o equipamento respondeu');

    // Equipamento mudo: tudo sem comunicação, com o último valor (nunca zero).
    server.delay = const Duration(seconds: 2);
    await until(() => rt.watch('temp').value.quality == TagQuality.commLost, ms: 5000, what: 'sem comunicação');
    expect(rt.watch('temp').value.value, 25.3);
    expect(rt.watch('temp').value.message, HttpCommError.timeoutText);
    expect(rt.health('esp')!.value.online, isFalse);

    // Voltou: sozinho, com a espera crescente de sempre.
    server.delay = Duration.zero;
    await until(() => rt.watch('temp').value.isGood, ms: 6000, what: 'voltou');
    sub.cancel();
  });

  test('autenticação: Basic e token pelo cofre; 401, 403 e senha fora do aparelho', () async {
    server.user = 'admin';
    server.password = 's3nha';
    final vault = DeviceVault.instance as MemoryDeviceVault;
    final basic = device.copyWith(http: const HttpConfig(auth: HttpAuth.basic, username: 'admin', secretRef: 'hs_a'));
    final rt = runtime();

    // Sem a senha no cofre (projeto importado): nem pergunta.
    var r = await rt.probe(basic);
    expect(r.ok, isFalse);
    expect(r.message, HttpCommError.missingSecret);
    expect(server.requests, isEmpty);

    await vault.write('hs_a', 'errada');
    r = await rt.probe(basic);
    expect((r.ok, r.message, r.refused), (false, HttpCommError.badCredentials, true));

    // A senha digitada no cadastro vale para o teste antes de salvar.
    r = await rt.probe(basic.copyWith(http: basic.http.copyWith(pendingSecret: 's3nha')));
    expect(r.ok, isTrue, reason: r.message);
    expect(server.requests.last.headers['authorization'], 'Basic ${base64.encode(utf8.encode('admin:s3nha'))}');

    // Na sessão: senha errada → sem comunicação; corrigida no cofre → volta.
    final tag = ht('temp', '/api/status', 'data.temperatura');
    await rt.apply(Project(devices: [basic], tags: [tag]));
    final sub = rt.subscribe(['temp']);
    await until(() => rt.watch('temp').value.quality == TagQuality.commLost, what: 'senha errada');
    expect(rt.watch('temp').value.message, HttpCommError.badCredentials);
    await vault.write('hs_a', 's3nha');
    await until(() => rt.watch('temp').value.isGood, ms: 6000, what: 'senha certa');
    sub.cancel();

    // Sem senha cadastrada num equipamento que pede: a mensagem diz isso.
    expect((await rt.probe(device)).message, HttpCommError.needsCredentials);

    // Token num cabeçalho próprio.
    server.user = null;
    server.token = 'abc123';
    server.tokenHeader = 'X-API-Key';
    await vault.write('hs_t', 'abc123');
    final token = device.copyWith(http: const HttpConfig(auth: HttpAuth.token, tokenHeader: 'X-API-Key', secretRef: 'hs_t'));
    expect((await rt.probe(token)).ok, isTrue);
    await vault.write('hs_t', 'outro');
    expect((await rt.probe(token)).message, HttpCommError.forbidden);
  });

  test('Testar da variável: código, tempo e valor; 401, 404 e tempo esgotado em palavras', () async {
    var t = await HttpDriver.test(device, ht('temp', '/api/status', 'data.temperatura'));
    expect((t.ok, t.status, t.value), (true, 200, 25.3));
    expect(t.elapsedMs, isNotNull);
    expect(t.fields.map((f) => f.$1), containsAll(['data.temperatura', 'data.bomba', 'itens.0.valor']));

    t = await HttpDriver.test(device, ht('x', '/api/naoexiste', ''));
    expect((t.ok, t.status, t.error), (false, 404, '404: caminho não existe'));

    t = await HttpDriver.test(device, ht('x', '/api/status', 'data.nada'));
    expect((t.ok, t.status, t.error), (false, 200, 'o campo "data.nada" não veio na resposta'));

    server.user = 'admin';
    server.password = '1';
    await DeviceVault.instance.write('hs_b', '2');
    t = await HttpDriver.test(device.copyWith(http: const HttpConfig(auth: HttpAuth.basic, username: 'admin', secretRef: 'hs_b')), ht('x', '/api/status', ''));
    expect((t.ok, t.status, t.error), (false, 401, '401: o equipamento recusou o usuário ou a senha'));

    server.user = null;
    server.delay = const Duration(seconds: 2);
    t = await HttpDriver.test(device, ht('x', '/api/status', ''));
    expect((t.ok, t.error), (false, HttpCommError.timeoutText));

    // Porta sem servidor: recusou.
    final closed = device.copyWith(port: 1, timeoutMs: 5000);
    final p = await runtime().probe(closed);
    expect((p.ok, p.message, p.refused), (false, HttpCommError.refusedPort('').userMessage, true));
  });

  test('variável de outro protocolo e http:// para IP da internet', () async {
    final rt = runtime();
    const foreign = Tag(id: 'f', name: 'f', deviceId: 'esp');
    await rt.apply(Project(devices: [device], tags: [foreign]));
    final sub = rt.subscribe(['f']);
    await until(() => rt.watch('f').value.quality == TagQuality.configError);
    expect(rt.watch('f').value.message, 'variável sem requisição HTTP');
    sub.cancel();

    final internet = device.copyWith(host: '8.8.8.8');
    final r = await rt.probe(internet);
    expect(r.ok, isFalse);
    expect(r.message, contains('use https://'));
    expect(server.requests, isEmpty);
  });
}
