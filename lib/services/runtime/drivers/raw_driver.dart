import 'dart:async';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../../../core/comm/comm_error.dart';
import '../../../core/link/byte_link.dart';
import '../../../core/modbus/modbus_client.dart';
import '../../../core/rawlink/message_parser.dart';
import '../../../core/rawlink/raw_client.dart';
import '../../../core/rawlink/raw_link_error.dart';
import '../../../core/rawlink/raw_link_pool.dart';
import '../../../core/serial/usb_serial_link.dart';
import '../../../models/device.dart';
import '../../../models/tag.dart';
import '../../net/local_network.dart';
import '../raw_codec.dart';
import '../tag_codec.dart';
import '../tag_store.dart';
import 'device_driver.dart';

/// O problema de uma mensagem em palavras de operador — a prévia do editor,
/// o "Ouvir o equipamento" e o "Testar conexão" falam igual.
extension FrameProblemText on FrameProblem {
  String get label => switch (this) {
        FrameProblem.checksum => 'checksum errado',
        FrameProblem.noFields => 'nenhum campo reconhecido',
        FrameProblem.tooLong => 'mensagem sem fim descartada',
        FrameProblem.incomplete => 'mensagem cortada (começou outra antes do fim)',
      };
}

/// "Testar conexão" de equipamento cru: o cano abriu, mas a mensagem não veio
/// ou o perfil não a entendeu. A rede está certa (no TCP o equipamento aceitou
/// a conexão): o que conferir é o equipamento ou o perfil.
class RawProbeError extends CommError {
  const RawProbeError(super.message, this.userMessage, {this.refused = true});

  @override
  final String userMessage;

  @override
  final bool refused;

  /// Começo da mensagem de "chegou, mas não entendeu" — o cadastro usa para
  /// escolher o que mandar conferir.
  static const String notUnderstood = 'chegou mensagem, mas o perfil não entendeu';

  static String silent(int seconds) => 'conectou, mas nenhuma mensagem chegou em $seconds s';

  static bool isSilent(String userMessage) => userMessage.startsWith('conectou, mas nenhuma mensagem');
}

/// O que o "Ouvir o equipamento" juntou: cada campo com o último valor (na
/// ordem em que apareceram) e as mensagens que o perfil não entendeu.
class RawHeard {
  final Map<String, Object> fields = {};
  int good = 0;
  int bad = 0;
  FrameProblem? lastProblem;

  void add(RawFrame f) {
    if (f.ok) {
      good++;
      fields.addAll(f.fields);
    } else {
      bad++;
      lastProblem = f.problem;
    }
  }
}

/// Protocolo cru (Arduino, ESP, balança) atrás do contrato de
/// [DeviceDriver], em modo **assinatura** — como o `MqttDriver`.
///
/// O equipamento fala quando quer (streaming) ou responde ao pedido que o
/// [RawClient] manda sozinho a cada `pollMs` do perfil (polling): para quem
/// lê, os dois modos são iguais. Por isso aqui:
///   • cada mensagem boa vai para o [TagStore] na hora em que chega — a tela
///     não espera o próximo ciclo;
///   • [scan] não pergunta nada: aplica o que já tinha chegado às variáveis
///     novas, confere a validade de cada campo e a do equipamento — mudo além
///     de `staleAfterMs` do perfil vira [RawTimeout], e a sessão faz o resto
///     (último valor esmaecido, espera crescente);
///   • queda do cano avisa a sessão ([DeviceDriver.onWake]); a próxima
///     varredura reabre.
///
/// Gravar monta o comando pelo modelo (o da variável ou o do perfil) e manda.
/// O elemento só muda quando o equipamento manda o estado novo.
///
/// O socket é do [RawLinkPool]: a varredura, o "Testar conexão", a prévia do
/// editor e o "Ouvir o equipamento" dividem uma conexão só — o sketch comum
/// atende um cliente TCP por vez.
class RawDriver extends DeviceDriver {
  RawDriver(this.device);

  final Device device;

  static final Logger _log = Logger('RawDriver');

  final ValueNotifier<ModbusLinkState> _state = ValueNotifier(ModbusLinkState.disconnected);
  RawClient? _client;
  StreamSubscription<RawFrame>? _frames;
  Future<void>? _connecting;
  int _generation = 0;
  bool _disposed = false;

  /// Quando a conexão atual abriu: referência da validade antes da primeira
  /// mensagem, e o que separa valor de agora de valor de antes da queda.
  DateTime? _connectedAt;

  List<Tag> _tags = const [];
  TagStore? _store;

  /// Quando cada variável recebeu o campo dela pela última vez.
  final Map<String, DateTime> _seen = {};
  final Set<String> _expired = {};

  /// A última varredura achou o equipamento mudo: a próxima mensagem acorda a
  /// sessão, para o selo voltar a verde sem esperar a espera crescente.
  bool _stale = false;

  @override
  ValueListenable<ModbusLinkState> get state => _state;

  @override
  bool get isConnected => (_client?.isConnected ?? false) && _state.value == ModbusLinkState.connected;

  /// A varredura aqui não vai à rede: o tempo dela não mede nada.
  @override
  bool get reportsScanTime => false;

  String get _label => labelFor(device);

  /// "192.168.0.50:5030" ou "cabo USB · CH340".
  static String labelFor(Device d) => d.isUsb ? 'cabo USB · ${d.serial.port?.label ?? 'adaptador'}' : '${d.host}:${d.port}';

  /// O cano compartilhado do equipamento: socket TCP/UDP ([RawLinkPool]) ou
  /// a porta do adaptador USB ([UsbSerialPool]). Varredura, teste, prévia do
  /// editor e "Ouvir o equipamento" pegam cada um o seu, pendurado no mesmo.
  static ByteLink linkFor(Device d, {Duration? connectionTimeout}) {
    if (d.isUsb) return UsbSerialPool.acquire(port: d.serial.port, params: d.serial.params, dtr: d.serial.dtr, label: labelFor(d));
    final raw = d.raw;
    return RawLinkPool.acquire(
      udp: raw.isUdp,
      host: d.host,
      port: d.port,
      localPort: raw.localPort,
      connectionTimeout: connectionTimeout ?? Duration(milliseconds: max(1000, d.timeoutMs)),
      // Wi-Fi da máquina sem internet + dados móveis: sem isto a conexão
      // sairia pelo 4G (ver LocalNetwork).
      beforeConnect: LocalNetwork.prepare,
    );
  }

  Duration get _timeout => Duration(milliseconds: max(1000, device.timeoutMs));

  void _setState(ModbusLinkState s) {
    if (!_disposed) _state.value = s;
  }

  // ── Conexão ──────────────────────────────────────────────────────────────────

  @override
  Future<void> connect() {
    if (_disposed) return Future.error(const RawConnectionError('driver descartado'));
    if (isConnected) return Future.value();
    return _connecting ??= _open().whenComplete(() => _connecting = null);
  }

  Future<void> _open() async {
    final generation = _generation;
    _setState(ModbusLinkState.connecting);
    var c = _client;
    try {
      if (c == null) {
        final raw = device.raw;
        // Perfil que não fecha lança RawProfileError aqui — um CommError: o
        // selo mostra "perfil de mensagem inválido: …".
        c = _client = RawClient(
          link: linkFor(device, connectionTimeout: _timeout),
          profile: raw.profile,
          label: _label,
          responseTimeout: _timeout,
        )..onLost = _dropped;
        _frames = c.frames.listen(_onFrame);
      }
      await c.connect();
    } on CommError {
      // RawLinkError e também o do cabo USB (adaptador não encontrado).
      _setState(ModbusLinkState.lost);
      rethrow;
    }
    if (_disposed || generation != _generation) {
      // Pediram para desconectar enquanto conectava (saiu da tela).
      throw const RawConnectionError('desconexão pedida durante a conexão');
    }
    _connectedAt = clock.now();
    _setState(ModbusLinkState.connected);
    _markAwaiting();
  }

  /// Queda sem ter sido pedida (equipamento reiniciou, cabo, Wi-Fi). Acorda a
  /// sessão: a varredura seguinte reabre ou marca tudo "sem comunicação".
  void _dropped(String reason) {
    _log.warning('${device.name}: $reason');
    _setState(ModbusLinkState.lost);
    onWake?.call();
  }

  @override
  Future<void> disconnect() async {
    _generation++;
    final c = _client;
    _client = null;
    await _frames?.cancel();
    _frames = null;
    _stale = false;
    _setState(ModbusLinkState.disconnected);
    await c?.dispose();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await disconnect();
    _disposed = true;
    _state.dispose();
  }

  RawClient _connected() {
    final c = _client;
    if (c == null) throw const RawConnectionError('desconectado');
    return c;
  }

  /// "Testar conexão": abriu o cano **e** chegou mensagem que o perfil
  /// entende. Espera a validade do perfil (2 a 10 s) — no polling o pedido
  /// sai na conexão e a resposta vem logo. Três mensagens seguidas que o
  /// perfil não entende já respondem: é o perfil.
  @override
  Future<void> ping() async {
    await connect();
    final c = _connected();
    final last = c.lastDataAt;
    if (last != null && !_beforeConnection(last)) return;
    final wait = Duration(milliseconds: device.raw.profile.staleAfterMs.clamp(2000, 10000));
    FrameProblem? problem;
    var bad = 0;
    final done = Completer<bool>();
    final timer = Timer(wait, () {
      if (!done.isCompleted) done.complete(false);
    });
    final sub = c.frames.listen((f) {
      if (f.ok) {
        if (!done.isCompleted) done.complete(true);
      } else {
        problem ??= f.problem;
        if (++bad >= 3 && !done.isCompleted) done.complete(false);
      }
    });
    final ok = await done.future;
    timer.cancel();
    await sub.cancel();
    if (ok) return;
    if (problem != null) throw RawProbeError('$_label: ${problem!.name}', '${RawProbeError.notUnderstood}: ${problem!.label}');
    // UDP "conecta" sempre (só reserva a porta): o silêncio pode ser IP errado.
    throw RawProbeError('$_label: silêncio', RawProbeError.silent(wait.inSeconds), refused: device.isUsb || !device.raw.isUdp);
  }

  // ── Varredura ────────────────────────────────────────────────────────────────

  @override
  void tagsChanged(List<Tag> previous, List<Tag> current) {
    final before = {for (final t in previous) t.id: t};
    final ids = <String>{};
    for (final t in current) {
      ids.add(t.id);
      // Variável nova ou editada (campo, tipo, escala): aplica de novo o
      // último valor do campo no próximo ciclo.
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
    final c = _connected();
    final now = clock.now();
    final keys = <String>{};
    for (final t in tags) {
      final a = t.raw;
      if (a == null || !a.isValid) {
        _publishProblem(store, t.id, a == null ? 'variável sem campo da mensagem' : 'diga qual campo da mensagem');
        continue;
      }
      keys.add(a.key);
      // Campo que já tinha chegado (outra variável lê o mesmo, ou a variável
      // acabou de entrar em uso): vale para esta também.
      if (!_seen.containsKey(t.id)) {
        final v = c.valueOf(a.key);
        if (v != null && !_beforeConnection(v.at)) _apply(t, v.value, v.at, store);
      }
      _checkValidity(t, a.validitySec, now, store);
    }
    if (c.isStale) {
      _stale = true;
      c.checkFresh();
    }
    _stale = false;
    return keys.length;
  }

  bool _beforeConnection(DateTime at) {
    final since = _connectedAt;
    return since != null && at.isBefore(since);
  }

  /// Campo que parou de vir (o resto da mensagem continua chegando) = "sem
  /// comunicação" só nesta variável, com o último valor esmaecido.
  void _checkValidity(Tag t, int seconds, DateTime now, TagStore store) {
    if (seconds <= 0 || _expired.contains(t.id)) return;
    final seen = _seen[t.id];
    final since = _connectedAt ?? now;
    final ref = seen == null || since.isAfter(seen) ? since : seen;
    if (now.difference(ref) <= Duration(seconds: seconds)) return;
    final cur = store.read(t.id);
    if (cur.quality == TagQuality.configError || cur.quality == TagQuality.addressError) return;
    _expired.add(t.id);
    store.publish(t.id, TagReading(value: cur.value, quality: TagQuality.commLost, message: 'o campo ${t.raw!.key} não vem há mais de ${_secs(seconds)}', at: cur.at));
  }

  static String _secs(int s) => s >= 60 && s % 60 == 0 ? '${s ~/ 60} min' : '$s s';

  /// Erro de configuração publicado uma vez só (a varredura roda a cada meio
  /// segundo; republicar redesenharia o elemento à toa).
  void _publishProblem(TagStore store, String id, String message) {
    final cur = store.read(id);
    if (cur.quality == TagQuality.configError && cur.message == message) return;
    store.publish(id, TagReading(quality: TagQuality.configError, message: message, at: clock.now()));
  }

  /// Conexão de volta, mas nada chegou ainda: o valor esmaecido continua,
  /// agora com o motivo certo.
  void _markAwaiting() {
    final store = _store;
    if (store == null) return;
    for (final t in _tags) {
      final cur = store.read(t.id);
      if (cur.quality == TagQuality.commLost) store.publish(t.id, cur.degrade(TagQuality.commLost, 'aguardando nova mensagem'));
    }
  }

  // ── Mensagens ────────────────────────────────────────────────────────────────

  void _onFrame(RawFrame f) {
    if (!f.ok) return;
    if (_stale) {
      _stale = false;
      onWake?.call();
    }
    final store = _store;
    if (store == null) return;
    final now = clock.now();
    for (final t in _tags) {
      final a = t.raw;
      if (a == null || !a.isValid) continue;
      final v = f.fields[a.key];
      if (v != null) _apply(t, v, now, store);
    }
  }

  void _apply(Tag t, Object value, DateTime at, TagStore store) {
    _seen[t.id] = at;
    _expired.remove(t.id);
    try {
      store.publish(t.id, TagReading(value: RawCodec.decode(t, value), quality: TagQuality.good, at: at));
    } on TagValueError catch (e) {
      store.publish(t.id, TagReading(quality: TagQuality.configError, message: e.message, at: at));
    }
  }

  // ── Leitura avulsa e escrita ─────────────────────────────────────────────────

  /// "Lendo agora": o último valor do campo, ou espera ele chegar. Nada
  /// chegou ainda dá [RawNoMessageYet] (tom neutro); chegou mensagem sem o
  /// campo diz quais campos chegam — é o erro de digitação mais comum.
  @override
  Future<Object> readOnce(Tag tag) async {
    final a = tag.raw;
    if (a == null) throw const TagValueError('variável sem campo da mensagem');
    if (!a.isValid) throw const TagValueError('diga qual campo da mensagem');
    await connect();
    final c = _connected();
    c.checkFresh(); // equipamento mudo: "sem mensagem do equipamento"
    final v = c.valueOf(a.key);
    if (v != null && !_beforeConnection(v.at)) return RawCodec.decode(tag, v.value);
    final f = await _next(c, a.key, _timeout);
    if (f != null) return RawCodec.decode(tag, f.fields[a.key]!);
    if (!c.isConnected) throw const RawConnectionError('a conexão caiu');
    final heard = [for (final e in c.latest.entries) if (!_beforeConnection(e.value.at)) e.key];
    if (heard.isEmpty) throw const RawNoMessageYet();
    throw TagValueError('o campo "${a.key}" não veio — chegam ${_list(heard)}');
  }

  static String _list(List<String> keys) {
    final shown = keys.take(6).join(', ');
    return keys.length > 6 ? '$shown…' : shown;
  }

  /// A próxima mensagem boa com o campo [key], ou nulo no prazo. Assinatura
  /// própria, cancelada no fim: o "Lendo agora" pergunta a cada segundo e um
  /// `firstWhere` com prazo deixaria uma escuta pendurada a cada pergunta.
  static Future<RawFrame?> _next(RawClient c, String key, Duration wait) {
    final done = Completer<RawFrame?>();
    final timer = Timer(wait, () {
      if (!done.isCompleted) done.complete(null);
    });
    final sub = c.frames.listen(
      (f) {
        if (f.ok && f.fields.containsKey(key) && !done.isCompleted) done.complete(f);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(null);
      },
    );
    return done.future.whenComplete(() {
      timer.cancel();
      sub.cancel();
    });
  }

  /// Monta o comando — o da variável ou, sem ele, o do perfil para aquele
  /// campo — e manda. Valor que não cabe no modelo vira [TagValueError] sem
  /// mandar nada.
  @override
  Future<void> write(Tag tag, Object value) async {
    final a = tag.raw;
    if (a == null || !a.isValid) throw TagValueError('"${tag.name}" não tem campo da mensagem');
    if (!tag.canWrite) throw TagValueError('"${tag.name}" é só leitura');
    final command = a.command;
    final template = command != null && command.template.trim().isNotEmpty ? command : device.raw.profile.commandFor(a.key);
    if (template == null) {
      throw TagValueError('"${tag.name}": falta o comando para gravar — diga qual no cadastro da variável');
    }
    final v = RawCodec.encode(tag, value);
    await connect();
    try {
      await _connected().writeWith(template, a.key, v);
    } on RawCommandError catch (e) {
      throw TagValueError(e.message);
    }
  }

  // ── Ouvir o equipamento ──────────────────────────────────────────────────────

  /// "Ouvir o equipamento" do cadastro de variável: junta por [duration] os
  /// campos que chegam, com o último valor de cada. [onChange] recebe o
  /// resultado a cada mensagem, para a lista crescer na tela. Pelo cano
  /// compartilhado: não disputa o equipamento com a leitura das telas.
  static Future<RawHeard> listen(
    Device device, {
    Duration duration = const Duration(seconds: 10),
    void Function(RawHeard)? onChange,
    bool Function()? cancelled,
  }) async {
    final d = RawDriver(device);
    final heard = RawHeard();
    try {
      await d.connect();
      final sub = d._connected().frames.listen((f) {
        heard.add(f);
        onChange?.call(heard);
      });
      final end = DateTime.now().add(duration);
      while (DateTime.now().isBefore(end) && d.isConnected && !(cancelled?.call() ?? false)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await sub.cancel();
    } finally {
      await d.dispose();
    }
    return heard;
  }
}
