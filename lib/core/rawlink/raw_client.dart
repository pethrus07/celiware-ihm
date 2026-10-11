import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:logging/logging.dart';

import '../link/byte_link.dart';
import '../modbus/modbus_client_serial.dart' show isConnectionRefused;
import 'message_parser.dart';
import 'message_profile.dart';
import 'raw_link_error.dart';

/// Último valor de um campo e quando ele chegou.
class RawValue {
  const RawValue(this.value, this.at);

  final Object value;
  final DateTime at;

  @override
  String toString() => 'RawValue($value @ $at)';
}

/// Cliente do protocolo cru sobre um [ByteLink] (TCP, UDP ou serial).
///
/// Diferente do Modbus, aqui não existe "pedido → resposta" garantido: no
/// streaming o equipamento fala quando quer; no polling ele responde ao
/// pedido, mas a resposta é uma mensagem como outra qualquer. Por isso o
/// cliente é **orientado a mensagens**: tudo o que chega passa pelo
/// [MessageParser], cada mensagem boa atualiza [latest] (chave → valor +
/// horário) e sai em [frames]. Quem lê pergunta o valor mais recente; quem
/// precisa saber se o equipamento está vivo usa [checkFresh] (validade do
/// perfil).
///
/// Com [autoPoll] (padrão) e perfil em polling, o próprio cliente manda o
/// pedido a cada `pollMs` — os dois modos ficam iguais para quem lê. Sem ele,
/// o dono do laço chama [poll] quando quiser (pedido + espera da resposta).
class RawClient {
  RawClient({
    required this.link,
    required MessageProfile profile,
    this.label = 'cru',
    this.responseTimeout = const Duration(seconds: 2),
    this.autoPoll = true,
  }) : _parser = MessageParser(profile);

  static final Logger _log = Logger('RawClient');

  final ByteLink link;

  /// Para o log ("192.168.0.50:5030", "ESP da estufa").
  final String label;

  /// Espera máxima da resposta de um [poll].
  Duration responseTimeout;
  final bool autoPoll;

  MessageParser _parser;
  final Map<String, RawValue> _latest = {};
  final _frames = StreamController<RawFrame>.broadcast();
  final List<Completer<RawFrame>> _waiters = [];
  StreamSubscription<Uint8List>? _sub;
  Timer? _pollTimer;
  bool _manualDisconnect = true;
  DateTime? _openedAt;
  DateTime? _lastDataAt;
  int _good = 0;
  int _bad = 0;

  /// O cano caiu sozinho (não chamado em [disconnect]).
  void Function(String reason)? onLost;

  MessageProfile get profile => _parser.profile;

  /// Troca o perfil sem reconectar — o editor ajusta e a prévia segue ao
  /// vivo. Lança [RawProfileError] se o perfil novo não fecha (o antigo
  /// continua valendo).
  set profile(MessageProfile p) {
    _parser = MessageParser(p);
    if (link.isOpen) _startPolling();
  }

  bool get isConnected => link.isOpen;

  /// Campo → último valor, de todas as mensagens desde a conexão. Um campo
  /// que deixou de vir mantém o valor e o horário antigos: quem lê decide se
  /// ainda vale.
  Map<String, RawValue> get latest => UnmodifiableMapView(_latest);

  RawValue? valueOf(String key) => _latest[key];

  /// Todas as mensagens, boas e com problema (prévia ao vivo, diagnóstico).
  Stream<RawFrame> get frames => _frames.stream;

  /// Quando chegou a última mensagem com valores.
  DateTime? get lastDataAt => _lastDataAt;
  int get goodFrames => _good;
  int get badFrames => _bad;
  int get discardedBytes => _parser.discardedBytes;

  // ── Conexão ──────────────────────────────────────────────────────────────────

  Future<void> connect() async {
    if (link.isOpen) return;
    _manualDisconnect = false;
    // Assina antes de abrir: nada que chegue logo na abertura se perde.
    _sub ??= link.input.listen(_onData);
    link.onClosed = _onClosed;
    try {
      await link.open();
    } catch (e) {
      throw RawConnectionError('Falha ao abrir $label: $e', refused: isConnectionRefused(e));
    }
    _parser.reset();
    _openedAt = clock.now();
    _startPolling();
    _log.info('Conectado a $label (${profile.mode.name})');
  }

  Future<void> disconnect() async {
    _manualDisconnect = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    await _sub?.cancel();
    _sub = null;
    await link.close();
    _parser.reset();
    _failWaiters(const RawConnectionError('Desconectado'));
  }

  Future<void> dispose() async {
    await disconnect();
    await _frames.close();
  }

  void _onClosed(String reason) {
    _log.warning('$label: $reason');
    _parser.reset(); // meia mensagem de antes da queda não casa com o que vier depois
    _failWaiters(RawConnectionError(reason));
    if (!_manualDisconnect) onLost?.call(reason);
  }

  /// Caiu sem ter sido pedido: a próxima operação reabre, como no Modbus.
  Future<void> _ensureOpen() async {
    if (link.isOpen) return;
    if (_manualDisconnect) throw const RawConnectionError('Cliente desconectado');
    await connect();
  }

  // ── Recepção ─────────────────────────────────────────────────────────────────

  void _onData(Uint8List chunk) {
    final frames = [..._parser.add(chunk), if (link.isDatagram) ..._parser.endOfPacket()];
    for (final f in frames) {
      if (f.ok) {
        final now = clock.now();
        f.fields.forEach((k, v) => _latest[k] = RawValue(v, now));
        _lastDataAt = now;
        _good++;
        final waiting = List.of(_waiters);
        _waiters.clear();
        for (final w in waiting) {
          if (!w.isCompleted) w.complete(f);
        }
      } else {
        _bad++;
        _log.fine('$label: mensagem descartada (${f.problem!.name}): ${f.preview}');
      }
      _frames.add(f);
    }
  }

  void _failWaiters(RawLinkError error) {
    final waiting = List.of(_waiters);
    _waiters.clear();
    for (final w in waiting) {
      if (!w.isCompleted) w.completeError(error);
    }
  }

  /// A próxima mensagem com valores, ou [RawTimeout].
  Future<RawFrame> nextFrame({Duration? timeout}) {
    final c = Completer<RawFrame>();
    _waiters.add(c);
    final t = timeout ?? responseTimeout;
    return c.future.timeout(t, onTimeout: () {
      _waiters.remove(c);
      throw RawTimeout('$label: nenhuma mensagem válida em ${t.inMilliseconds} ms');
    });
  }

  /// Sem mensagem com valores há mais que a validade do perfil = sem
  /// comunicação. Conta desde a conexão: equipamento que nunca falou também
  /// vence. Depois de uma reconexão conta da reconexão — a última mensagem de
  /// antes da queda venceria na hora, antes de o equipamento ter tempo de
  /// falar.
  bool get isStale {
    final ms = profile.staleAfterMs;
    final data = _lastDataAt, opened = _openedAt;
    final since = data == null || (opened != null && opened.isAfter(data)) ? opened : data;
    if (ms <= 0 || since == null) return false;
    return clock.now().difference(since).inMilliseconds > ms;
  }

  /// Lança [RawTimeout] se [isStale] — o "scan" de um driver de streaming.
  void checkFresh() {
    if (isStale) throw RawTimeout('$label: nenhuma mensagem há mais de ${profile.staleAfterMs} ms');
  }

  // ── Envio ────────────────────────────────────────────────────────────────────

  /// Manda o pedido do polling e espera a mensagem de resposta.
  Future<RawFrame> poll() async {
    await _ensureOpen();
    final request = _parser.pollBytes();
    final reply = nextFrame();
    try {
      await _write(request);
    } catch (_) {
      reply.ignore();
      rethrow;
    }
    return reply;
  }

  /// Grava [value] no campo [field] pelo modelo do perfil (o daquele campo
  /// ou o genérico).
  Future<void> write(String field, Object value) async {
    final t = profile.commandFor(field);
    if (t == null) throw RawCommandError('o perfil não tem comando para gravar "$field"');
    await send(_parser.buildCommand(t, field: field, value: value));
  }

  /// Grava [value] no campo [field] com um modelo que não é do perfil (o
  /// comando próprio de uma variável). O checksum e o conjunto de caracteres
  /// continuam os do perfil.
  Future<void> writeWith(CommandTemplate template, String field, Object value) async {
    await send(_parser.buildCommand(template, field: field, value: value));
  }

  /// Manda o comando de nome [name] (botão "Zerar balança").
  Future<void> command(String name, {Object? value, Map<String, Object?> args = const {}}) async {
    final t = profile.commandNamed(name);
    if (t == null) throw RawCommandError('o perfil não tem o comando "$name"');
    await send(_parser.buildCommand(t, field: t.field, value: value, args: args));
  }

  /// Bytes prontos, sem modelo.
  Future<void> send(List<int> bytes) async {
    await _ensureOpen();
    await _write(bytes);
  }

  Future<void> _write(List<int> bytes) async {
    try {
      await link.write(Uint8List.fromList(bytes));
    } catch (e) {
      throw RawConnectionError('$label: falha ao enviar: $e');
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (!autoPoll || profile.mode != RawMode.polling) return;
    _pollTimer = Timer.periodic(Duration(milliseconds: profile.pollMs), (_) => _pollTick());
    _pollTick(); // o primeiro pedido sai na conexão, não um intervalo depois
  }

  void _pollTick() {
    if (!link.isOpen) return; // caiu: quem reconecta é o dono do laço
    _write(_parser.pollBytes()).catchError((Object e) {
      _log.fine('$label: pedido não enviado: $e');
    });
  }
}
