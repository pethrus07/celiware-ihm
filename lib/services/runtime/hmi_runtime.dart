import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../core/comm/comm_error.dart';
import '../../core/modbus/modbus_client.dart';
import '../../core/modbus/modbus_exception.dart';
import '../../models/device.dart';
import '../../models/project.dart';
import '../../models/tag.dart';
import '../calc/calc_graph.dart';
import '../demo/demo_process.dart';
import '../net/local_network.dart';
import 'device_session.dart';
import 'drivers/calc_driver.dart';
import 'drivers/device_driver.dart';
import 'tag_codec.dart';
import 'tag_store.dart';

/// Inscrição de uma tela nas variáveis que ela mostra. Cancelar ao sair.
class TagSubscription {
  TagSubscription._(this._runtime, this.tagIds);
  final HmiRuntime _runtime;
  final Set<String> tagIds;
  bool _cancelled = false;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _runtime._unsubscribe(tagIds);
  }
}

/// Resultado do botão "Testar conexão".
class ProbeResult {
  const ProbeResult({required this.ok, required this.message, this.elapsedMs, this.value, this.refused = false, this.hint, this.network});
  final bool ok;
  final String message;
  final int? elapsedMs;

  /// O equipamento recusou a conexão: está na rede, mas a porta está errada
  /// ou o Modbus TCP desligado (ver [ModbusConnectionError.refused]).
  final bool refused;

  /// Valor lido, quando o teste inclui uma variável.
  final Object? value;

  /// Diagnóstico da rede do celular quando falha ("redes diferentes", "sem
  /// Wi-Fi"). Nulo quando não há o que acrescentar.
  final String? hint;

  /// Por qual rede local a conexão sai ("Wi-Fi 192.168.1.23/24 · sem internet").
  final String? network;
}

/// O motor da IHM em execução — dono das conexões e das leituras.
///
/// As telas não conhecem Modbus: pedem para acompanhar variáveis
/// ([subscribe]), observam os valores ([watch]) e pedem escritas ([write],
/// [press]/[release]). O runtime decide quais equipamentos varrer, agrupa as
/// leituras e mantém uma [DeviceSession] por equipamento.
///
/// **Só é lido o que está em uso.** Cada variável tem uma contagem de
/// inscrições; a varredura de um equipamento inclui apenas as variáveis com
/// contagem > 0. Abrir a "tela de líder" com 6 máquinas liga 6 sessões; voltar
/// para a lista desliga todas. É isso que mantém o tráfego na rede da fábrica
/// no mínimo e a bateria do celular viva.
///
/// **Segurança do botão de pulso.** [press] grava 1 e [release] grava 0. Se a
/// soltura falhar (rede caiu com o dedo no botão), a variável entra numa fila
/// e o runtime tenta gravar 0 a cada segundo até conseguir. [releaseAll] é
/// chamado quando a tela fecha e quando o app vai para segundo plano — um
/// comando momentâneo nunca fica "preso" ligado por causa do celular.
///
/// **Uma conexão por CLP.** Dois equipamentos com o mesmo endereço de
/// conexão ([linkKey]: protocolo, IP, porta e escravo ou rack/slot) dividem
/// uma sessão — a do primeiro da lista. Acontece com as regras da planta:
/// um projeto duplicado traz o mesmo CLP com outro id, e uma segunda
/// conexão TCP derrubaria o CLP que só aceita uma.
class HmiRuntime {
  HmiRuntime({ModbusClient Function(Device)? clientFactory})
      : _clientFactory = clientFactory ?? DeviceSession.defaultClientFactory {
    _releaseTimer = Timer.periodic(const Duration(seconds: 1), (_) => _retryReleases());
  }

  static final Logger _log = Logger('HmiRuntime');

  final ModbusClient Function(Device) _clientFactory;
  final TagStore store = TagStore();

  Project _project = const Project();

  /// Sessões por id do equipamento dono (o primeiro com aquele endereço).
  final Map<String, DeviceSession> _sessions = {};

  /// Equipamento que usa a sessão de outro (mesmo [linkKey]) → id do dono.
  Map<String, String> _alias = const {};
  final Map<String, int> _refs = {};
  final Set<String> _pressed = {};
  final Set<String> _pendingRelease = {};
  late final Timer _releaseTimer;
  bool _paused = false;

  Project get project => _project;

  /// O endereço da conexão, para dois equipamentos dividirem uma sessão;
  /// nulo = sessão própria. Só Modbus TCP, Modbus RTU/ASCII pelo gateway e
  /// S7. Cabo USB fica de fora (a porta já é dividida no `UsbSerialPool`),
  /// como MQTT, OPC UA, Arduino, demonstração e calculadas, em que a
  /// conexão carrega mais que o endereço.
  static String? linkKey(Device d) {
    final host = d.host.trim().toLowerCase();
    if (host.isEmpty) return null;
    return switch (d.kind) {
      DeviceKind.modbusTcp => 'modbus-tcp|$host|${d.port}|${d.unitId}',
      DeviceKind.modbusRtuTcp => 'modbus-gateway|$host|${d.port}|${d.framing.name}|${d.unitId}',
      DeviceKind.s7 => 's7|$host|${d.port}|${d.s7.rack}|${d.s7.slot}',
      _ => null,
    };
  }

  /// Quem usa a sessão de quem: o primeiro equipamento com um [linkKey] é o
  /// dono; os seguintes com o mesmo apontam para ele.
  static Map<String, String> _aliases(Project p) {
    final owner = <String, String>{};
    final alias = <String, String>{};
    for (final d in p.devices) {
      final key = linkKey(d);
      if (key == null) continue;
      final o = owner[key];
      if (o == null) {
        owner[key] = d.id;
      } else {
        alias[d.id] = o;
      }
    }
    return alias;
  }

  String _ownerId(String deviceId) => _alias[deviceId] ?? deviceId;

  // ── Projeto ──────────────────────────────────────────────────────────────────

  /// Aplica um projeto novo (edição, importação). Reaproveita as sessões dos
  /// equipamentos que não mudaram a forma de conectar.
  Future<void> apply(Project next) async {
    final old = _project;
    _project = next;
    _alias = _aliases(next);

    for (final id in _sessions.keys.toList()) {
      final gone = next.device(id) == null;
      // Passou a usar a sessão de outro equipamento (mesmo endereço).
      if (gone || _alias.containsKey(id)) {
        await _sessions.remove(id)!.dispose();
        if (gone) DemoRegistry.discard(id);
        _sessionsRevision.value++;
      }
    }
    for (final d in next.devices) {
      final s = _sessions[d.id];
      if (s != null && old.device(d.id) != null) await s.updateDevice(d);
    }
    for (final t in old.tags) {
      if (next.tag(t.id) == null) store.forget(t.id);
    }
    _refreshSessions();
  }

  // ── Inscrição ────────────────────────────────────────────────────────────────

  TagSubscription subscribe(Iterable<String> tagIds) {
    final ids = tagIds.toSet();
    for (final id in ids) {
      _refs[id] = (_refs[id] ?? 0) + 1;
    }
    _refreshSessions();
    return TagSubscription._(this, ids);
  }

  void _unsubscribe(Set<String> ids) {
    for (final id in ids) {
      final n = (_refs[id] ?? 1) - 1;
      if (n <= 0) {
        _refs.remove(id);
      } else {
        _refs[id] = n;
      }
    }
    _refreshSessions();
  }

  ValueListenable<TagReading> watch(String tagId) => store.watch(tagId);

  /// Saúde da comunicação de um equipamento (nulo se nada dele está em uso).
  ValueListenable<DeviceHealth>? health(String deviceId) => _sessions[_ownerId(deviceId)]?.health;

  final ValueNotifier<int> _sessionsRevision = ValueNotifier(0);

  /// Muda quando uma sessão nasce ou morre — o selo de conexão ouve isto para
  /// trocar de "ocioso" para o estado real assim que a tela começa a ler.
  ValueListenable<int> get sessionsRevision => _sessionsRevision;

  bool _disposed = false;

  /// Recalcula quais variáveis cada sessão deve varrer e liga/desliga sessões.
  void _refreshSessions() {
    // Tela fechando depois do app encerrado cancela inscrição tarde — não
    // pode recriar sessão num runtime já descartado.
    if (_disposed) return;
    final byDevice = <String, List<Tag>>{};
    // Calculada em uso põe as entradas dela em uso também (§6.11).
    for (final id in CalcGraph.expand(_project, _refs.keys)) {
      final tag = _project.tag(id);
      if (tag == null) {
        store.publish(id, const TagReading(quality: TagQuality.configError, message: 'variável apagada'));
        continue;
      }
      if (_project.device(tag.deviceId) == null) {
        store.publish(id, const TagReading(quality: TagQuality.configError, message: 'equipamento apagado'));
        continue;
      }
      // Variável de modelo sem endereço: área e endereço são só o padrão —
      // ler o HR 0 no lugar dela mostraria um número qualquer como se fosse
      // o dado.
      if (tag.addressPending) {
        store.publish(id, const TagReading(quality: TagQuality.configError, message: pendingMessage));
        continue;
      }
      byDevice.putIfAbsent(_ownerId(tag.deviceId), () => []).add(tag);
    }

    for (final d in _project.devices) {
      if (_alias.containsKey(d.id)) continue; // lido pela sessão do dono
      final tags = byDevice[d.id] ?? const [];
      var session = _sessions[d.id];
      if (session == null && tags.isEmpty) continue;
      if (session == null) {
        session = _sessions[d.id] = _newSession(d);
        _sessionsRevision.value++;
      }
      session.setTags(tags);
      if (tags.isEmpty || _paused) {
        unawaited(session.stop());
      } else {
        session.start();
      }
    }
  }

  // ── Escrita ──────────────────────────────────────────────────────────────────

  /// Motivo publicado para a variável com o endereço a configurar.
  static const pendingMessage = 'endereço a configurar';

  Future<void> write(String tagId, Object value) async {
    final tag = _project.tag(tagId);
    if (tag == null) throw const TagValueError('Variável não encontrada');
    // Sem endereço, gravar cairia no endereço 0 — o comando iria para outra
    // memória do equipamento.
    if (tag.addressPending) throw TagValueError('"${tag.name}" ainda está com o endereço a configurar (em Variáveis).');
    final session = _sessionFor(tag);
    await session.write(tag, value);
  }

  /// Botão de pulso apertado: grava 1.
  Future<void> press(String tagId) async {
    // Sem endereço não grava nada — e não fica nada para soltar depois.
    if (_project.tag(tagId)?.addressPending ?? false) return write(tagId, true);
    _pressed.add(tagId);
    _pendingRelease.remove(tagId);
    await write(tagId, true);
  }

  /// Botão de pulso solto: grava 0 (e insiste se falhar).
  Future<void> release(String tagId) async {
    _pressed.remove(tagId);
    if (_project.tag(tagId)?.addressPending ?? false) {
      _pendingRelease.remove(tagId);
      return;
    }
    try {
      await write(tagId, false);
      _pendingRelease.remove(tagId);
    } catch (e) {
      _log.warning('Soltura de $tagId falhou, vai insistir: $e');
      _pendingRelease.add(tagId);
    }
  }

  /// Solta todos os botões de pulso — chamado ao fechar tela e ao pausar o app.
  Future<void> releaseAll() async {
    for (final id in _pressed.toList()) {
      await release(id);
    }
  }

  Future<void> _retryReleases() async {
    for (final id in _pendingRelease.toList()) {
      if (_pressed.contains(id)) continue;
      try {
        await write(id, false);
        _pendingRelease.remove(id);
        _log.info('Soltura pendente de $id concluída');
      } catch (_) {/* tenta de novo no próximo segundo */}
    }
  }

  /// Lê uma variável agora — inclusive uma ainda não salva — pela conexão da
  /// sessão do equipamento (sem abrir socket novo a cada consulta). Usado no
  /// painel "lendo agora" do cadastro de variável. A demonstração precisa do
  /// processo rodando para os valores se mexerem.
  Future<Object> readNow(Tag tag) async {
    if (tag.addressPending) throw TagValueError('"${tag.name}" ainda está com o endereço a configurar (em Variáveis).');
    final session = _sessionFor(tag);
    if (session.device.isDemo) DemoRegistry.forDevice(session.device.id).start();
    return session.readOnce(tag);
  }

  /// Fecha conexões abertas só para leituras avulsas ([readNow]) que ninguém
  /// mais está usando. O cadastro de variável chama ao sair.
  void releaseIdle() => _refreshSessions();

  DeviceSession _sessionFor(Tag tag) {
    if (_project.device(tag.deviceId) == null) throw const TagValueError('Equipamento não encontrado');
    final device = _project.device(_ownerId(tag.deviceId))!;
    var s = _sessions[device.id];
    if (s == null) {
      s = _sessions[device.id] = _newSession(device);
      _sessionsRevision.value++;
    }
    return s;
  }

  /// Sessão nova. O equipamento das calculadas ganha o [CalcDriver], que lê
  /// o projeto e o [TagStore] em vez da rede.
  DeviceSession _newSession(Device d) => DeviceSession(
        device: d,
        store: store,
        clientFactory: _clientFactory,
        driverFactory: d.isCalc ? (_) => CalcDriver(store: store, project: () => _project) : null,
      );

  // ── Ciclo de vida do app ─────────────────────────────────────────────────────

  /// App foi para segundo plano: solta botões e para a varredura.
  Future<void> pause() async {
    await releaseAll();
    _paused = true;
    for (final s in _sessions.values) {
      await s.stop();
    }
  }

  void resume() {
    _paused = false;
    _refreshSessions();
  }

  // ── Teste de conexão ─────────────────────────────────────────────────────────

  /// Conecta num equipamento (ainda não salvo, inclusive) e opcionalmente lê
  /// uma variável — é o "Testar" das telas de cadastro. Usa um driver
  /// próprio, sem mexer nas sessões em andamento.
  Future<ProbeResult> probe(Device device, {Tag? tag}) async {
    if (device.isDemo) DemoRegistry.forDevice(device.id);
    final driver = DeviceDriver.forDevice(device, clientFactory: _clientFactory);
    final sw = Stopwatch()..start();
    try {
      await driver.connect();
      Object? value;
      if (tag != null) {
        value = await driver.readOnce(tag);
      } else {
        await driver.ping();
      }
      // Rede só se diagnostica em equipamento de rede (cabo USB não passa por ela).
      final nets = device.isNetwork ? await LocalNetwork.list() : null;
      return ProbeResult(ok: true, message: 'Conectado', elapsedMs: sw.elapsedMilliseconds, value: value,
          network: LocalNetwork.routeTo(device.host, nets)?.label);
    } on CommError catch (e) {
      final refused = e.refused;
      final nets = device.isNetwork ? await LocalNetwork.list() : null;
      return ProbeResult(ok: false, message: e.userMessage, elapsedMs: sw.elapsedMilliseconds, refused: refused,
          // Recusou = achou o aparelho; a rede está certa, não vale diagnosticar.
          hint: refused ? null : LocalNetwork.diagnose(device.host, nets),
          network: LocalNetwork.routeTo(device.host, nets)?.label);
    } on TagValueError catch (e) {
      return ProbeResult(ok: false, message: e.message);
    } finally {
      await driver.dispose();
    }
  }

  Future<void> dispose() async {
    _releaseTimer.cancel();
    await releaseAll();
    _disposed = true;
    for (final s in _sessions.values) {
      await s.dispose();
    }
    _sessions.clear();
    store.dispose();
    _sessionsRevision.dispose();
  }
}
