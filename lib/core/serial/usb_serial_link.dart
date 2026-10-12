import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import 'serial_params.dart';
import 'usb_serial.dart';

/// Portas USB-serial abertas, divididas entre quem precisa delas.
///
/// O Android abre um adaptador uma vez só: um segundo "abrir" no mesmo
/// adaptador falha. E no app várias peças querem a mesma porta ao mesmo
/// tempo:
///   • **vários equipamentos na mesma linha RS-485** — o inversor ID 1 e o
///     ID 2 no mesmo par de fios, cada um com a sua varredura;
///   • a varredura das telas, o "Testar conexão" do cadastro, a prévia do
///     editor de mensagem e o "Ouvir o equipamento".
///
/// Cada um recebe um [SerialLink] próprio ([acquire]) que, aberto, se
/// pendura na porta aberta daquele adaptador: todos recebem todos os bytes,
/// todos podem mandar, e a porta só fecha quando o último fecha. Os pedidos
/// Modbus passam por [SerialLink.exclusive]: um pedido e a resposta dele
/// nunca se misturam com o de outro equipamento da linha, e cada um vai nos
/// parâmetros do seu cadastro (testar 19200 com a tela lendo a 9600 não
/// estraga nem um nem outro).
class UsbSerialPool {
  UsbSerialPool._();

  static final Logger _log = Logger('UsbSerialPool');
  static final Map<String, _UsbPort> _ports = {};

  /// Portas abertas (ou abrindo) agora — para os testes conferirem que nada
  /// ficou para trás.
  @visibleForTesting
  static int get openCount => _ports.length;

  /// Um cano para o adaptador [port] (nulo = o único adaptador plugado).
  /// Nada é aberto até o [SerialLink.open] dele.
  static SerialLink acquire({required UsbPortRef? port, required SerialParams params, bool dtr = false, String label = 'USB'}) =>
      _UsbLink(port, params, dtr, label);

  /// O adaptador plugado agora que corresponde a [ref]. Sem escolha no
  /// cadastro vale o único adaptador serial plugado; com dois ou mais, é
  /// preciso escolher.
  static Future<UsbPortInfo> resolve(UsbPortRef? ref) async {
    final platform = UsbSerial.platform;
    if (!platform.supported) throw const UsbSerialError('USB-OTG fora do Android', UsbProblem.unsupported);
    final all = await platform.list();
    final serial = all.where((p) => p.supported).toList();
    if (ref != null) {
      final found = ref.find(serial);
      if (found != null) return found;
      throw UsbSerialError('${ref.title} não está plugado (há ${serial.length} adaptador(es) serial)', UsbProblem.noAdapter);
    }
    if (serial.length == 1) return serial.single;
    if (serial.isEmpty) throw const UsbSerialError('nenhum adaptador serial plugado', UsbProblem.noAdapter);
    throw UsbSerialError('${serial.length} adaptadores plugados e nenhum escolhido', UsbProblem.notChosen);
  }

  /// Fecha tudo (fim dos testes).
  @visibleForTesting
  static Future<void> reset() async {
    for (final p in _ports.values.toList()) {
      await p._shutdown('reset');
    }
    _ports.clear();
  }
}

/// A porta aberta de verdade e quem está pendurado nela.
class _UsbPort {
  _UsbPort(this.info);

  final UsbPortInfo info;
  final Set<_UsbLink> users = {};
  int? handle;
  SerialParams? _current;
  Future<void>? _opening;
  StreamSubscription<UsbSerialEvent>? _events;
  Duration? _lastAt;
  Future<void> _tail = Future.value();

  bool get isOpen => handle != null;

  Future<void> attach(_UsbLink user) async {
    if (handle == null) {
      await (_opening ??= _open(user).whenComplete(() => _opening = null));
    } else if (_current != user.params) {
      // Quem chega com outra velocidade (o cadastro testando 19200 com a tela
      // lendo a 9600) passa a valer para o que chega sozinho (Arduino); o
      // Modbus reaplica os seus a cada pedido ([exclusive]).
      await _queued(() => _use(user.params));
    }
    users.add(user);
  }

  Future<void> _open(_UsbLink first) async {
    final platform = UsbSerial.platform;
    // Escuta antes de abrir: nada do que chega logo na abertura se perde.
    _events ??= platform.events.listen(_onEvent);
    var port = info;
    if (!port.hasPermission) {
      final ok = await platform.requestPermission(port);
      if (!ok) throw UsbSerialError('permissão negada para ${port.title}', UsbProblem.permission);
      port = port.withPermission(true);
    }
    handle = await platform.open(port, first.params, dtr: first.dtr);
    _current = first.params;
    _lastAt = null;
    UsbSerialPool._log.info('Aberto ${info.title} em ${first.params.label}');
  }

  void _onEvent(UsbSerialEvent e) {
    final h = handle;
    if (h == null) return;
    switch (e) {
      case UsbData(handle: final eh) when eh == h:
        final last = _lastAt;
        _lastAt = e.at;
        final chunk = SerialChunk(e.bytes, gapBefore: last == null ? null : e.at - last);
        for (final u in users.toList()) {
          u._deliver(chunk);
        }
      case UsbClosed(handle: final eh) when eh == h:
        unawaited(_lost(e.reason));
      default:
        break;
    }
  }

  /// Caiu (cabo puxado): avisa todos. A porta morta sai do mapa — o
  /// adaptador plugado de novo ganha outro caminho no Android, e quem
  /// reabrir procura de novo.
  Future<void> _lost(String reason) async {
    final h = handle;
    if (h == null) return;
    handle = null;
    if (identical(UsbSerialPool._ports[info.key], this)) UsbSerialPool._ports.remove(info.key);
    await _events?.cancel();
    _events = null;
    final gone = users.toList();
    users.clear();
    for (final u in gone) {
      u._dropped(reason);
    }
    try {
      await UsbSerial.platform.close(h);
    } catch (_) {}
  }

  Future<void> detach(_UsbLink user) async {
    users.remove(user);
    if (_opening != null) return;
    if (users.isNotEmpty) {
      // Saiu quem tinha mudado a velocidade: volta a de quem ficou.
      // Na fila, sem esperar: quem sai não fica preso ao pedido de outro.
      final stay = users.first.params;
      if (isOpen && _current != stay) {
        unawaited(_queued(() => _use(stay)).catchError((Object _) {/* caiu: quem ficou sabe pelo aviso de queda */}));
      }
      return;
    }
    await _shutdown('ninguém mais usa');
  }

  Future<void> _shutdown(String why) async {
    if (identical(UsbSerialPool._ports[info.key], this)) UsbSerialPool._ports.remove(info.key);
    final h = handle;
    handle = null;
    users.clear();
    await _events?.cancel();
    _events = null;
    if (h != null) {
      UsbSerialPool._log.fine('Fechando ${info.title}: $why');
      await UsbSerial.platform.close(h);
    }
  }

  /// Os parâmetros de quem vai usar a linha agora.
  Future<void> _use(SerialParams params) async {
    final h = handle;
    if (h == null) throw const UsbSerialError('porta fechada', UsbProblem.lost);
    if (_current == params) return;
    await UsbSerial.platform.setParams(h, params);
    _current = params;
  }

  Future<void> write(_UsbLink user, Uint8List bytes) async {
    final h = handle;
    if (h == null) throw const UsbSerialError('porta fechada', UsbProblem.lost);
    try {
      await UsbSerial.platform.write(h, bytes);
    } on UsbSerialError catch (e) {
      // Escrever falhou com a porta "aberta": o adaptador saiu e o aviso do
      // Android ainda não chegou.
      await _lost(e.message);
      rethrow;
    }
  }

  /// Fila da linha: um de cada vez, na ordem em que pediram, cada um nos
  /// próprios parâmetros.
  Future<T> exclusive<T>(_UsbLink user, Future<T> Function() action) => _queued(() async {
        await _use(user.params);
        return action();
      });

  /// Troca de parâmetros também entra na fila: nunca no meio do pedido de outro.
  Future<T> _queued<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }
}

/// O [SerialLink] que cada um recebe.
class _UsbLink extends SerialLink {
  _UsbLink(this.ref, this.params, this.dtr, this.label);

  final UsbPortRef? ref;
  @override
  final SerialParams params;
  final bool dtr;
  final String label;

  _UsbPort? _port;
  final _input = StreamController<Uint8List>.broadcast();
  final _chunks = StreamController<SerialChunk>.broadcast();

  /// Conta os [close]: fechado enquanto abria, a abertura se desfaz.
  int _closes = 0;

  @override
  bool get isOpen {
    final p = _port;
    return p != null && p.isOpen && p.users.contains(this);
  }

  @override
  Stream<Uint8List> get input => _input.stream;

  @override
  Stream<SerialChunk> get chunks => _chunks.stream;

  @override
  Future<void> open() async {
    if (isOpen) return;
    _port = null;
    final info = await UsbSerialPool.resolve(ref);
    final port = UsbSerialPool._ports.putIfAbsent(info.key, () => _UsbPort(info));
    final closes = _closes;
    try {
      await port.attach(this);
    } catch (_) {
      if (port.users.isEmpty && identical(UsbSerialPool._ports[info.key], port)) {
        UsbSerialPool._ports.remove(info.key);
        await port._shutdown('não abriu');
      }
      rethrow;
    }
    if (closes != _closes) {
      // Fecharam (saiu da tela) enquanto o adaptador abria: não fica pendurado.
      await port.detach(this);
      throw const UsbSerialError('fechado durante a abertura', UsbProblem.lost);
    }
    _port = port;
  }

  void _deliver(SerialChunk c) {
    if (!_input.isClosed) _input.add(c.bytes);
    if (!_chunks.isClosed) _chunks.add(c);
  }

  void _dropped(String reason) {
    _port = null;
    onClosed?.call(reason);
  }

  @override
  Future<void> write(Uint8List bytes) async {
    final p = _port;
    if (p == null || !p.isOpen) throw const UsbSerialError('porta fechada', UsbProblem.lost);
    await p.write(this, bytes);
  }

  @override
  Future<T> exclusive<T>(Future<T> Function() action) {
    final p = _port;
    if (p == null || !p.isOpen) return Future.error(const UsbSerialError('porta fechada', UsbProblem.lost));
    return p.exclusive(this, action);
  }

  @override
  Future<void> close() async {
    _closes++;
    final p = _port;
    _port = null;
    if (p != null) await p.detach(this);
  }

  @override
  String toString() => 'UsbSerialLink($label, ${params.label})';
}
