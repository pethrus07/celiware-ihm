import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/comm/comm_error.dart';
import '../../../core/http/http_error.dart';
import '../../../core/http/http_link.dart';
import '../../../core/modbus/modbus_client.dart';
import '../../../models/device.dart';
import '../../../models/http_config.dart';
import '../../../models/tag.dart';
import '../../net/device_vault.dart';
import '../../net/local_network.dart';
import '../http_codec.dart';
import '../tag_codec.dart';
import '../tag_store.dart';
import 'device_driver.dart';

/// Equipamento HTTP/HTTPS atrás do contrato de [DeviceDriver], em modo
/// **varredura**, como o Modbus e o OPC UA (itens 56, 169 e 173 da lista).
///
/// A cada ciclo da sessão (`Device.pollMs`, nunca abaixo de 500 ms) cada
/// requisição diferente em uso é feita **uma vez** — variáveis com o mesmo
/// método, caminho e corpo ([HttpTagAddress.requestKey]) saem da mesma
/// resposta, cada uma com o seu seletor (caminho JSON ou expressão regular).
///
/// | Situação | Na tela |
/// |---|---|
/// | Sem resposta, porta fechada, rede fora | `HttpCommError` → sem comunicação com o último valor, espera crescente |
/// | 401/403 | `HttpCommError` (recusou): usuário/senha ou token; tudo sem comunicação |
/// | 5xx | só as variáveis daquela requisição sem comunicação (o equipamento está de pé) |
/// | 404, 400, 405… | erro de cadastro só das variáveis daquela requisição ("404: caminho não existe") |
/// | Campo que não veio, texto onde se esperava número | erro de cadastro daquela variável só |
///
/// Gravar faz o comando da variável (POST/PUT/GET com `{valor}` no corpo ou
/// no caminho) e acorda a sessão, que relê: o elemento mostra o valor que o
/// equipamento devolver.
class HttpDriver extends DeviceDriver {
  HttpDriver(this.device)
      : link = HttpLink(
          timeout: Duration(milliseconds: device.timeoutMs),
          acceptSelfSigned: device.http.acceptSelfSigned,
          beforeRequest: _route,
        );

  final Device device;
  final HttpLink link;
  final ValueNotifier<ModbusLinkState> _state = ValueNotifier(ModbusLinkState.disconnected);

  /// Segredo lido do cofre, guardado até o cofre mudar ([DeviceVault.revision]):
  /// abrir o Keystore a cada leitura de meio segundo seria desperdício.
  String? _secret;
  int _secretRevision = -1;

  HttpConfig get _cfg => device.http;

  bool _disposed = false;

  /// Pedido no ar quando a sessão troca de driver: a resposta chega depois do
  /// descarte e não pode mexer no estado.
  void _set(ModbusLinkState s) {
    if (!_disposed) _state.value = s;
  }

  /// Vincula ao Wi-Fi da máquina (§4.14) e devolve a rede escolhida — mudou
  /// a rede, o cliente troca de conexões.
  static Future<Object?> _route(String host) async {
    final n = await LocalNetwork.prepare(host);
    return n == null ? null : '${n.type} ${n.ip}/${n.prefix}';
  }

  @override
  ValueListenable<ModbusLinkState> get state => _state;

  @override
  Future<void> connect() async => _checkConfig();

  @override
  Future<void> disconnect() async {
    link.close();
    _set(ModbusLinkState.disconnected);
  }

  void _checkConfig() {
    if (device.host.trim().isEmpty) throw const HttpCommError('sem endereço', 'falta o endereço do equipamento');
    final clear = HttpConfig.cleartextProblem(device.host, https: _cfg.https);
    if (clear != null) throw HttpCommError.cleartext('http:// para ${device.host}', clear);
  }

  Future<String?> _readSecret() async {
    final pending = _cfg.pendingSecret;
    if (pending != null) return pending;
    final ref = _cfg.secretRef;
    if (ref == null) return null;
    if (_secretRevision != DeviceVault.revision) {
      _secretRevision = DeviceVault.revision;
      _secret = await DeviceVault.instance.read(ref);
    }
    return _secret;
  }

  /// Cabeçalhos de um pedido: autenticação, os extras do cadastro e o tipo
  /// do corpo (o extra "Content-Type", se houver, ganha).
  Future<Map<String, String>> _headers(String? body) async {
    final h = <String, String>{'Accept': 'application/json, text/plain, */*'};
    if (body != null) h['Content-Type'] = HttpCodec.contentTypeFor(body);
    if (_cfg.needsSecret) {
      final secret = await _readSecret();
      if (secret == null || secret.isEmpty) throw const HttpCommError.secretMissing();
      if (_cfg.auth == HttpAuth.basic) {
        h['Authorization'] = 'Basic ${base64.encode(utf8.encode('${_cfg.username}:$secret'))}';
      } else {
        h[_cfg.tokenHeader.trim().isEmpty ? HttpConfig.defaultTokenHeader : _cfg.tokenHeader.trim()] = secret;
      }
    }
    for (final x in _cfg.headers) {
      h.removeWhere((k, _) => k.toLowerCase() == x.name.toLowerCase());
      h[x.name] = x.value;
    }
    return h;
  }

  /// A URL do pedido. Caminho que não cabe numa URL é erro da variável
  /// ([TagValueError]), não da comunicação.
  Uri _uri(String path) {
    try {
      return _cfg.resolve(device.host, device.port, path);
    } on FormatException catch (e) {
      throw TagValueError('caminho que não forma uma URL: ${e.message}');
    }
  }

  /// Um pedido ao equipamento. 401/403 sobem como [HttpCommError] (o
  /// equipamento recusou quem pergunta); os outros códigos voltam na
  /// resposta, para quem chamou decidir.
  Future<HttpReply> request(HttpRequestPlan plan) async {
    _checkConfig();
    if (_state.value != ModbusLinkState.connected) _set(ModbusLinkState.connecting);
    try {
      final headers = await _headers(plan.body);
      final reply = await link.send(plan.method.verb, _uri(plan.path), headers: headers, body: plan.body);
      if (reply.status == 401 || reply.status == 403) throw HttpCommError.auth(reply.status, sentCredentials: _cfg.needsSecret);
      _set(ModbusLinkState.connected);
      return reply;
    } on CommError {
      _set(ModbusLinkState.lost);
      rethrow;
    }
  }

  @override
  Future<int> scan(List<Tag> tags, TagStore store, {required bool Function() stillCurrent}) async {
    final groups = <String, (HttpRequestPlan, List<Tag>)>{};
    for (final t in tags) {
      try {
        final plan = HttpCodec.readPlan(t);
        groups.putIfAbsent(t.http!.requestKey, () => (plan, <Tag>[])).$2.add(t);
      } on TagValueError catch (e) {
        _publishProblem(store, t.id, e.message);
      }
    }
    var count = 0;
    for (final (plan, group) in groups.values) {
      if (!stillCurrent()) break;
      final HttpReply reply;
      try {
        reply = await request(plan);
      } on TagValueError catch (e) {
        for (final t in group) {
          _publishProblem(store, t.id, e.message);
        }
        continue;
      }
      count++;
      if (!stillCurrent()) break;
      final now = DateTime.now();
      if (!reply.ok) {
        final text = HttpCommError.statusText(reply.status);
        for (final t in group) {
          if (reply.status >= 500) {
            // O equipamento está de pé, mas falhou: o último valor fica.
            store.publish(t.id, store.read(t.id).degrade(TagQuality.commLost, text));
          } else {
            store.publish(t.id, TagReading(quality: reply.status == 404 ? TagQuality.addressError : TagQuality.configError, message: text, at: now));
          }
        }
        continue;
      }
      for (final t in group) {
        try {
          store.publish(t.id, TagReading(value: HttpCodec.decode(t, reply.body), quality: TagQuality.good, at: now));
        } on TagValueError catch (e) {
          store.publish(t.id, TagReading(quality: TagQuality.configError, message: e.message, at: now));
        }
      }
    }
    return count;
  }

  /// Erro de cadastro publicado uma vez só (republicar a cada ciclo
  /// redesenharia o elemento à toa).
  void _publishProblem(TagStore store, String id, String message) {
    final cur = store.read(id);
    if (cur.quality == TagQuality.configError && cur.message == message) return;
    store.publish(id, TagReading(quality: TagQuality.configError, message: message, at: DateTime.now()));
  }

  /// "Lendo agora" do cadastro e o teste com variável.
  @override
  Future<Object> readOnce(Tag tag) async {
    final reply = await request(HttpCodec.readPlan(tag));
    _failOn(reply);
    return HttpCodec.decode(tag, reply.body);
  }

  @override
  Future<void> write(Tag tag, Object value) async {
    if (!tag.canWrite) throw TagValueError('"${tag.name}" é só leitura');
    if (tag.isArray) throw TagValueError('"${tag.name}" é uma lista; não é gravável pela tela');
    _failOn(await request(HttpCodec.writePlan(tag, value)));
  }

  static void _failOn(HttpReply reply) {
    if (reply.ok) return;
    if (reply.status >= 500) throw HttpCommError.server(reply.status);
    throw HttpStatusError(reply.status);
  }

  /// Um GET na URL base: qualquer resposta prova que há um servidor HTTP ali
  /// (muito ESP32 responde 404 na raiz). Só 401/403 falham — usuário, senha
  /// ou token errados.
  @override
  Future<void> ping() async {
    await request(const HttpRequestPlan(HttpMethod.get, '', null));
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    link.close();
    _state.dispose();
  }

  // ── Testar (cadastro de variável) ────────────────────────────────────────────

  /// O "Testar" do cadastro de variável: faz a requisição de [tag] numa
  /// conexão própria e diz o código, o tempo, o valor que o seletor tirou
  /// (ou por que não tirou) e os campos da resposta JSON, para escolher
  /// com um toque.
  static Future<HttpTestResult> test(Device device, Tag tag) async {
    final d = HttpDriver(device);
    final sw = Stopwatch()..start();
    try {
      final reply = await d.request(HttpCodec.readPlan(tag));
      final fields = HttpCodec.fields(reply.body);
      final preview = reply.body.length > 300 ? '${reply.body.substring(0, 300)}…' : reply.body;
      if (!reply.ok) {
        return HttpTestResult(status: reply.status, elapsedMs: reply.elapsedMs, error: HttpCommError.statusText(reply.status), preview: preview);
      }
      try {
        return HttpTestResult(status: reply.status, elapsedMs: reply.elapsedMs, value: HttpCodec.decode(tag, reply.body), fields: fields, preview: preview);
      } on TagValueError catch (e) {
        return HttpTestResult(status: reply.status, elapsedMs: reply.elapsedMs, error: e.message, fields: fields, preview: preview);
      }
    } on HttpCommError catch (e) {
      return HttpTestResult(status: e.status, elapsedMs: sw.elapsedMilliseconds, error: e.userMessage);
    } on CommError catch (e) {
      return HttpTestResult(elapsedMs: sw.elapsedMilliseconds, error: e.userMessage);
    } on TagValueError catch (e) {
      return HttpTestResult(error: e.message);
    } finally {
      await d.dispose();
    }
  }
}

/// Resultado do "Testar" de uma variável HTTP.
@immutable
class HttpTestResult {
  const HttpTestResult({this.status, this.elapsedMs, this.value, this.error, this.fields = const [], this.preview = ''});

  /// Código HTTP (nulo = nem houve resposta).
  final int? status;
  final int? elapsedMs;

  /// O valor que o seletor tirou da resposta.
  final Object? value;

  /// Por que não deu, em português ("404: caminho não existe", "tempo
  /// esgotado…", "o campo "x" não veio na resposta").
  final String? error;

  /// Campos da resposta JSON (caminho → valor), para escolher com um toque.
  final List<(String, Object?)> fields;

  /// Começo da resposta, para quem precisa ver o que veio.
  final String preview;

  bool get ok => error == null;
}
