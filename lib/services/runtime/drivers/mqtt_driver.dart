import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../../../core/modbus/modbus_client.dart';
import '../../../core/mqtt/mqtt_error.dart';
import '../../../core/mqtt/mqtt_topic.dart';
import '../../../models/device.dart';
import '../../../models/tag.dart';
import '../../net/local_network.dart';
import '../mqtt_codec.dart';
import '../tag_codec.dart';
import '../tag_store.dart';
import 'device_driver.dart';

/// Uma mensagem ouvida: tópico e conteúdo (texto UTF-8).
@immutable
class MqttHeard {
  const MqttHeard(this.topic, this.payload, this.at);
  final String topic;
  final String payload;
  final DateTime at;
}

class _Sub {
  _Sub(this.qos, this.since);
  final MqttQos qos;

  /// Quando a assinatura foi pedida — referência da validade enquanto não
  /// chega a primeira mensagem.
  final DateTime since;

  /// O broker respondeu SUBACK 0x80 (permissão, tópico proibido).
  bool failed = false;
}

/// MQTT 3.1.1 atrás do contrato de [DeviceDriver], em modo **assinatura**.
///
/// No Modbus o app pergunta e o equipamento responde; no MQTT o equipamento
/// publica quando quer e o broker repassa. Por isso aqui:
///   • [scan] não lê nada da rede: reconcilia as assinaturas com as variáveis
///     em uso (idempotente — só assina o que falta e tira o que sobrou), aplica
///     o que já tinha chegado e confere a **validade** de cada variável;
///   • as mensagens chegam sozinhas e vão para o [TagStore] na hora — a tela
///     não espera o próximo ciclo;
///   • MQTT não tem qualidade por dado: sensor morto parece valor parado. A
///     validade ([MqttAddress.validitySec]) e o testamento (LWT) do
///     equipamento ([MqttBroker.statusTopic]) é que viram "sem comunicação";
///   • queda do broker vira [MqttCommError] no próximo [scan] — a sessão faz
///     o resto (último valor esmaecido, espera crescente, reconexão).
///
/// Gravar publica no tópico de comando, que costuma ser outro (`.../set`). O
/// elemento só muda quando o equipamento publica o estado novo: a tela mostra
/// o que a máquina confirmou, não o que o operador pediu.
class MqttDriver extends DeviceDriver {
  MqttDriver(this.device);

  final Device device;

  static final Logger _log = Logger('MqttDriver');
  static final Random _rng = Random();

  /// Assinatura de quem só quis ler uma vez ("Lendo agora") fica viva um
  /// pouco: o formulário pergunta de novo a cada segundo, e assinar e tirar a
  /// cada pergunta faria o broker reenviar tudo e perder o que não tem retain.
  static const Duration _adhocTtl = Duration(seconds: 10);

  /// Teto de tópicos lembrados (curinga `#` num broker movimentado).
  static const int _maxTopics = 500;

  final ValueNotifier<ModbusLinkState> _state = ValueNotifier(ModbusLinkState.disconnected);
  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _updates;
  Future<void>? _connecting;
  int _generation = 0;
  bool _disposed = false;

  final Map<String, _Sub> _subs = {};
  final Map<String, DateTime> _adhoc = {};

  /// Última mensagem de cada tópico, da mais velha para a mais nova.
  final Map<String, MqttHeard> _last = {};

  /// Quando cada variável recebeu mensagem pela última vez.
  final Map<String, DateTime> _seen = {};
  final Set<String> _expired = {};
  final List<(String, Completer<MqttHeard?>)> _waiters = [];
  void Function(MqttHeard)? _tap;

  List<Tag> _tags = const [];
  TagStore? _store;

  /// O testamento do equipamento disse que ele caiu.
  bool _deviceOffline = false;

  @override
  ValueListenable<ModbusLinkState> get state => _state;

  @override
  bool get isConnected => _client != null && _state.value == ModbusLinkState.connected;

  /// A varredura aqui não vai à rede: o tempo dela não mede nada.
  @override
  bool get reportsScanTime => false;

  void _setState(ModbusLinkState s) {
    if (!_disposed) _state.value = s;
  }

  // ── Conexão ──────────────────────────────────────────────────────────────────

  @override
  Future<void> connect() {
    if (_disposed) return Future.error(const MqttCommError.noConnection('driver descartado'));
    if (isConnected) return Future.value();
    return _connecting ??= _open().whenComplete(() => _connecting = null);
  }

  Future<void> _open() async {
    final generation = _generation;
    _setState(ModbusLinkState.connecting);
    final b = device.mqtt;
    final timeout = max(1000, device.timeoutMs);
    final c = MqttServerClient.withPort(device.host, _clientId(), device.port, maxConnectionAttempts: 1)
      ..logging(on: false)
      ..keepAlivePeriod = b.keepAliveSec
      // Sem PINGRESP neste prazo, a conexão é dada como morta: é o que pega o
      // Wi-Fi que caiu sem fechar o socket.
      ..disconnectOnNoResponsePeriod = b.keepAliveSec > 0 ? max(2, (timeout / 1000).ceil()) : 0
      ..connectTimeoutPeriod = timeout
      ..connectionTimeout = timeout
      ..secure = b.tls
      ..autoReconnect = false;
    c.setProtocolV311();
    c.onDisconnected = () => _dropped(c);
    c.onSubscribeFail = _subscribeFailed;
    try {
      // Wi-Fi da máquina sem internet + dados móveis: sem isto o broker da
      // rede local seria procurado pelo 4G (ver LocalNetwork).
      await LocalNetwork.prepare(device.host);
      await c.connect(b.username.isEmpty ? null : b.username, b.password.isEmpty ? null : b.password);
      if (c.connectionStatus?.state != MqttConnectionState.connected) throw _describe(null, c);
    } catch (e) {
      // Descreve antes de fechar: o código do CONNACK mora na conexão.
      final err = e is MqttCommError ? e : _describe(e, c);
      _quietDisconnect(c);
      _setState(ModbusLinkState.lost);
      throw err;
    }
    if (_disposed || generation != _generation) {
      // Pediram para desconectar enquanto conectava (saiu da tela).
      _quietDisconnect(c);
      throw const MqttCommError.noConnection('desconexão pedida durante a conexão');
    }
    _client = c;
    _updates = c.updates?.listen(_onMessages);
    _setState(ModbusLinkState.connected);
    _markAwaiting();
  }

  /// Vazio na configuração = um ID novo a cada conexão: dois celulares com o
  /// mesmo projeto nunca disputam o mesmo ID (o broker derrubaria um deles).
  String _clientId() {
    final fixed = device.mqtt.clientId.trim();
    if (fixed.isNotEmpty) return fixed;
    return 'wareiot-${_rng.nextInt(1 << 32).toRadixString(36)}';
  }

  /// A biblioteca só diz "NoConnectionException"; o operador precisa saber se
  /// é a porta, a senha ou a rede.
  MqttCommError _describe(Object? e, MqttServerClient c) {
    final where = '${device.host}:${device.port}';
    if (e is SocketException) {
      return _isRefused(e) ? MqttCommError.refusedPort('$where: $e') : MqttCommError.noConnection('$where: $e');
    }
    if (e is TlsException) {
      return MqttCommError('$where: $e', 'a conexão segura (TLS) falhou: porta sem TLS ou certificado não confiável', refused: true);
    }
    final rc = c.connectionStatus?.returnCode;
    switch (rc) {
      case MqttConnectReturnCode.badUsernameOrPassword:
      case MqttConnectReturnCode.notAuthorized:
        return MqttCommError.credentials('$where: CONNACK $rc');
      case MqttConnectReturnCode.identifierRejected:
        return MqttCommError('$where: CONNACK $rc', 'o broker recusou o ID do cliente', refused: true);
      case MqttConnectReturnCode.unacceptedProtocolVersion:
        return MqttCommError('$where: CONNACK $rc', 'o broker não aceita MQTT 3.1.1', refused: true);
      case MqttConnectReturnCode.brokerUnavailable:
        return MqttCommError('$where: CONNACK $rc', 'o broker está indisponível', refused: true);
      default:
        break;
    }
    if (e is NoConnectionException || e == null) return MqttCommError.timeout('$where: $e');
    return MqttCommError.noConnection('$where: $e');
  }

  /// "Conexão recusada": errno 111 no Linux/Android, 61 no macOS/iOS, 10061
  /// no Windows (mesma regra do Modbus TCP).
  static bool _isRefused(SocketException e) {
    final code = e.osError?.errorCode;
    if (code == 111 || code == 61 || code == 10061) return true;
    return '${e.osError?.message} ${e.message}'.toLowerCase().contains('refused');
  }

  /// Queda sem ter sido pedida (broker caiu, Wi-Fi morreu, keep-alive sem
  /// resposta). Acorda a sessão: o [scan] seguinte tenta reconectar e, se não
  /// der, a sessão marca tudo "sem comunicação".
  void _dropped(MqttServerClient c) {
    if (!identical(c, _client)) return;
    _log.warning('${device.name}: a conexão com o broker caiu');
    _teardown();
    _setState(ModbusLinkState.lost);
    onWake?.call();
  }

  void _teardown() {
    _updates?.cancel();
    _updates = null;
    _client = null;
    _subs.clear();
    // O que chegou antes da queda pode ter mudado: lendo de novo do zero.
    _last.clear();
    _expired.clear();
    _deviceOffline = false;
    for (final w in _waiters) {
      if (!w.$2.isCompleted) w.$2.complete(null);
    }
    _waiters.clear();
  }

  void _quietDisconnect(MqttServerClient c) {
    try {
      c.disconnect();
    } catch (_) {/* já estava fechado */}
  }

  @override
  Future<void> disconnect() async {
    _generation++;
    final c = _client;
    _teardown();
    _setState(ModbusLinkState.disconnected);
    if (c != null) _quietDisconnect(c);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await disconnect();
    _disposed = true;
    _state.dispose();
  }

  @override
  Future<void> ping() => connect();

  // ── Assinaturas ──────────────────────────────────────────────────────────────

  @override
  void tagsChanged(List<Tag> previous, List<Tag> current) {
    final before = {for (final t in previous) t.id: t};
    final ids = <String>{};
    for (final t in current) {
      ids.add(t.id);
      // Variável nova ou editada (tópico, campo, tipo, escala): aplica de
      // novo a última mensagem do tópico no próximo ciclo.
      if (!identical(before[t.id], t)) {
        _seen.remove(t.id);
        _expired.remove(t.id);
      }
    }
    _seen.removeWhere((id, _) => !ids.contains(id));
    _expired.removeWhere((id) => !ids.contains(id));
    _tags = current;
  }

  @override
  Future<int> scan(List<Tag> tags, TagStore store, {required bool Function() stillCurrent}) async {
    _store = store;
    _tags = tags;
    await connect();
    _reconcile();
    final now = DateTime.now();
    for (final t in tags) {
      final a = t.mqtt;
      if (a == null || !a.isValid) {
        _publishProblem(store, t.id, a == null ? 'variável sem tópico MQTT' : 'tópico inválido');
        continue;
      }
      final sub = _subs[a.topic.trim()];
      if (sub != null && sub.failed) {
        _publishProblem(store, t.id, 'o broker recusou a assinatura deste tópico');
        continue;
      }
      // Assinatura que já existia (outra variável no mesmo tópico): o broker
      // não reenvia; o que já chegou vale para esta também.
      if (!_seen.containsKey(t.id)) {
        final m = _latest(a.topic.trim());
        if (m != null) _apply(t, m, store);
      }
      _checkValidity(t, a.validitySec, sub, now, store);
    }
    if (_deviceOffline) throw MqttCommError.offline(device.mqtt.statusTopic);
    return _subs.length;
  }

  /// Validade vencida = "sem comunicação", mantendo o último valor esmaecido.
  /// A referência é a última mensagem ou, antes dela, a hora da assinatura —
  /// assim voltar do segundo plano não vence tudo de uma vez.
  void _checkValidity(Tag t, int seconds, _Sub? sub, DateTime now, TagStore store) {
    if (seconds <= 0 || _expired.contains(t.id)) return;
    final seen = _seen[t.id];
    final since = sub?.since ?? now;
    final ref = seen == null || since.isAfter(seen) ? since : seen;
    if (now.difference(ref) <= Duration(seconds: seconds)) return;
    final cur = store.read(t.id);
    if (cur.quality == TagQuality.configError || cur.quality == TagQuality.addressError) return;
    _expired.add(t.id);
    store.publish(t.id, TagReading(value: cur.value, quality: TagQuality.commLost, message: 'sem mensagem há mais de ${_secs(seconds)}', at: cur.at));
  }

  static String _secs(int s) => s >= 60 && s % 60 == 0 ? '${s ~/ 60} min' : '$s s';

  /// Erro de configuração publicado uma vez só (a varredura roda a cada meio
  /// segundo; republicar redesenharia o elemento à toa).
  void _publishProblem(TagStore store, String id, String message) {
    final cur = store.read(id);
    if (cur.quality == TagQuality.configError && cur.message == message) return;
    store.publish(id, TagReading(quality: TagQuality.configError, message: message, at: DateTime.now()));
  }

  /// Deixa as assinaturas iguais ao que está em uso: variáveis, leituras
  /// avulsas recentes e o tópico do testamento.
  void _reconcile() {
    final c = _client;
    if (c == null) return;
    final now = DateTime.now();
    _adhoc.removeWhere((_, at) => now.difference(at) > _adhocTtl);
    final wanted = <String, MqttQos>{};
    void want(String filter, int qos) {
      final f = filter.trim();
      if (!MqttTopic.isValidFilter(f)) return;
      final q = qos >= 1 ? MqttQos.atLeastOnce : MqttQos.atMostOnce;
      final had = wanted[f];
      if (had == null || q.index > had.index) wanted[f] = q;
    }

    for (final t in _tags) {
      final a = t.mqtt;
      if (a != null) want(a.topic, a.qos);
    }
    for (final f in _adhoc.keys) {
      want(f, 0);
    }
    if (device.mqtt.hasStatusTopic) want(device.mqtt.statusTopic, 1);

    try {
      for (final f in _subs.keys.toList()) {
        if (wanted[f] == _subs[f]!.qos) continue;
        final status = c.getSubscriptionsStatus(f);
        // SUBACK ainda não veio: a biblioteca só tira assinatura confirmada.
        // Fica para o próximo ciclo.
        if (status == MqttSubscriptionStatus.pending) continue;
        if (status == MqttSubscriptionStatus.active) c.unsubscribe(f);
        _subs.remove(f);
      }
      for (final e in wanted.entries) {
        if (_subs.containsKey(e.key)) continue;
        // Registra antes de pedir: a recusa pode voltar na mesma chamada.
        final sub = _subs[e.key] = _Sub(e.value, now);
        if (c.subscribe(e.key, e.value) == null) sub.failed = true;
      }
    } on ConnectionException catch (e) {
      throw MqttCommError.noConnection('$e');
    }
  }

  void _subscribeFailed(String topic) {
    _subs[topic]?.failed = true;
    _log.warning('${device.name}: o broker recusou a assinatura de $topic');
  }

  // ── Mensagens ────────────────────────────────────────────────────────────────

  void _onMessages(List<MqttReceivedMessage<MqttMessage>> batch) {
    for (final r in batch) {
      final pub = r.payload;
      if (pub is! MqttPublishMessage) continue;
      _receive(MqttHeard(r.topic, utf8.decode(pub.payload.message, allowMalformed: true), DateTime.now()));
    }
  }

  void _receive(MqttHeard m) {
    _last.remove(m.topic);
    _last[m.topic] = m;
    if (_last.length > _maxTopics) _last.remove(_last.keys.first);
    _tap?.call(m);

    final b = device.mqtt;
    if (b.hasStatusTopic && MqttTopic.matches(b.statusTopic.trim(), m.topic)) {
      final offline = m.payload.trim().toLowerCase() == b.offlinePayload.trim().toLowerCase();
      if (offline != _deviceOffline) {
        _deviceOffline = offline;
        if (offline) {
          _log.warning('${device.name}: testamento (LWT) em ${m.topic}');
        } else {
          _markAwaiting();
        }
        onWake?.call();
      }
    }

    final store = _store;
    if (store != null) {
      for (final t in _tags) {
        final a = t.mqtt;
        if (a != null && a.isValid && MqttTopic.matches(a.topic.trim(), m.topic)) _apply(t, m, store);
      }
    }
    for (final w in _waiters.toList()) {
      if (!w.$2.isCompleted && MqttTopic.matches(w.$1, m.topic)) {
        w.$2.complete(m);
        _waiters.remove(w);
      }
    }
  }

  void _apply(Tag t, MqttHeard m, TagStore store) {
    _seen[t.id] = m.at;
    _expired.remove(t.id);
    try {
      final v = MqttCodec.decode(t, m.payload);
      store.publish(
          t.id,
          _deviceOffline
              ? TagReading(value: v, quality: TagQuality.commLost, message: MqttCommError.deviceOffline, at: m.at)
              : TagReading(value: v, quality: TagQuality.good, at: m.at));
    } on TagValueError catch (e) {
      store.publish(t.id, TagReading(quality: TagQuality.configError, message: e.message, at: m.at));
    }
  }

  /// Conexão (ou o equipamento) voltou, mas ninguém publicou ainda: o valor
  /// esmaecido continua, agora com o motivo certo — "sem conexão com o
  /// broker" ali, com o selo verde, confundiria.
  void _markAwaiting() {
    final store = _store;
    if (store == null) return;
    for (final t in _tags) {
      final cur = store.read(t.id);
      if (cur.quality == TagQuality.commLost) store.publish(t.id, cur.degrade(TagQuality.commLost, 'aguardando nova mensagem'));
    }
  }

  /// A mensagem mais recente que casa com [filter].
  MqttHeard? _latest(String filter) {
    for (final m in _last.values.toList().reversed) {
      if (MqttTopic.matches(filter, m.topic)) return m;
    }
    return null;
  }

  // ── Leitura avulsa e escrita ─────────────────────────────────────────────────

  /// "Lendo agora": a última mensagem do tópico, ou espera a próxima até o
  /// tempo de resposta do equipamento. Tópico sem retain e sem publicação
  /// recente dá [MqttNoMessageYet] — não é erro.
  @override
  Future<Object> readOnce(Tag tag) async {
    final a = tag.mqtt;
    if (a == null) throw const TagValueError('variável sem tópico MQTT');
    final filter = a.topic.trim();
    if (!MqttTopic.isValidFilter(filter)) throw const TagValueError('tópico inválido');
    await connect();
    if (_deviceOffline) throw MqttCommError.offline(device.mqtt.statusTopic);
    _adhoc[filter] = DateTime.now();
    var m = _latest(filter);
    if (m == null) {
      final entry = (filter, Completer<MqttHeard?>());
      _waiters.add(entry);
      _reconcile();
      m = await entry.$2.future.timeout(Duration(milliseconds: max(1000, device.timeoutMs)), onTimeout: () => null);
      _waiters.remove(entry);
      if (m == null) {
        if (!isConnected) throw const MqttCommError.dropped();
        throw MqttNoMessageYet(filter);
      }
    }
    return MqttCodec.decode(tag, m.payload);
  }

  /// Publica no tópico de comando. Com QoS 1 espera o broker confirmar
  /// (PUBACK): "gravou" quer dizer que chegou ao broker.
  @override
  Future<void> write(Tag tag, Object value) async {
    final a = tag.mqtt;
    if (a == null) throw TagValueError('"${tag.name}" não tem tópico MQTT');
    if (!tag.canWrite) throw TagValueError('"${tag.name}" é só leitura');
    if (tag.isArray) throw TagValueError('"${tag.name}" é uma lista; não é gravável pela tela');
    final payload = MqttCodec.encode(tag, value);
    await connect();
    // Comando para máquina que caiu se perderia calado (ou, com retain,
    // seria executado sabe-se lá quando).
    if (_deviceOffline) throw MqttCommError.offline(device.mqtt.statusTopic);
    final c = _client!;
    final qos = a.qos >= 1 ? MqttQos.atLeastOnce : MqttQos.atMostOnce;
    final data = MqttClientPayloadBuilder().addUTF8String(payload).payload!;
    final acked = Completer<void>();
    int? id;
    final acks = qos == MqttQos.atLeastOnce
        ? c.published?.listen((msg) {
            if (msg.variableHeader?.messageIdentifier == id && !acked.isCompleted) acked.complete();
          })
        : null;
    try {
      id = c.publishMessage(a.publishTopic, qos, data, retain: a.retain);
      if (acks != null) {
        await acked.future.timeout(Duration(milliseconds: max(1000, device.timeoutMs)),
            onTimeout: () => throw MqttCommError.timeout('sem PUBACK em ${a.publishTopic}'));
      }
    } on ConnectionException catch (e) {
      throw MqttCommError.noConnection('$e');
    } on InvalidTopicException {
      throw TagValueError('tópico de comando inválido: ${a.publishTopic}');
    } finally {
      await acks?.cancel();
    }
  }

  // ── Ouvir o broker ───────────────────────────────────────────────────────────

  /// "Ouvir 10 s e listar tópicos e campos" do cadastro de variável: assina
  /// [filter] (tudo, por padrão) e devolve a última mensagem de cada tópico.
  /// [onHeard] recebe cada uma na hora, para a lista crescer na tela.
  /// Conexão própria, que não mexe na sessão do equipamento.
  static Future<List<MqttHeard>> listen(
    Device device, {
    String filter = '#',
    Duration duration = const Duration(seconds: 10),
    void Function(MqttHeard)? onHeard,
    bool Function()? cancelled,
    int maxTopics = 300,
  }) async {
    final d = MqttDriver(device);
    final heard = <String, MqttHeard>{};
    d._tap = (m) {
      if (heard.length >= maxTopics && !heard.containsKey(m.topic)) return;
      heard[m.topic] = m;
      onHeard?.call(m);
    };
    try {
      await d.connect();
      d._adhoc[filter] = DateTime.now();
      d._reconcile();
      final end = DateTime.now().add(duration);
      while (DateTime.now().isBefore(end) && d.isConnected && !(cancelled?.call() ?? false)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } finally {
      await d.dispose();
    }
    return heard.values.toList();
  }
}
