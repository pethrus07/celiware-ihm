import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../link/byte_link.dart';

/// Uma conexão por equipamento cru, dividida entre quem precisa dela.
///
/// O sketch de Arduino mais comum (`WiFiServer` + `while (client.connected())`)
/// atende **um** cliente TCP por vez: uma segunda conexão é aceita pela rede
/// e nunca recebe nada. No app, várias peças querem ouvir o mesmo equipamento
/// ao mesmo tempo — a varredura das telas, o "Testar conexão", a prévia do
/// editor de perfil, o "Ouvir o equipamento" do cadastro de variável. Se cada
/// uma abrisse o seu socket, a segunda veria "nada chegou" com o equipamento
/// funcionando. No UDP o problema é parecido: o equipamento manda para quem
/// falou por último (ou para a porta gravada no sketch), e dois sockets
/// disputariam a mesma mensagem.
///
/// Por isso cada um recebe um [ByteLink] próprio ([acquire]) que, aberto,
/// pendura-se no cano compartilhado daquele endereço: todos recebem todos os
/// bytes, todos podem mandar, e o socket só fecha quando o último fecha. Uma
/// queda avisa todos; o primeiro que reabrir reabre para todos.
class RawLinkPool {
  RawLinkPool._();

  static final Map<String, _SharedLink> _links = {};

  /// Canos abertos (ou abrindo) agora — para os testes conferirem que nada
  /// ficou para trás.
  @visibleForTesting
  static int get openCount => _links.length;

  /// Um cano para [host]:[port] por TCP ou UDP. Nada é aberto até o
  /// [ByteLink.open] dele.
  static ByteLink acquire({
    required bool udp,
    required String host,
    required int port,
    int localPort = 0,
    Duration connectionTimeout = const Duration(seconds: 5),
    Future<void> Function(String host)? beforeConnect,
  }) {
    final key = '${udp ? 'udp' : 'tcp'}|$host|$port|${udp ? localPort : 0}';
    ByteLink create() => udp
        ? UdpByteLink(host: host, port: port, localPort: localPort, beforeConnect: beforeConnect)
        : TcpByteLink(host: host, port: port, connectionTimeout: connectionTimeout, beforeConnect: beforeConnect);
    return _PooledLink(key, udp, create);
  }
}

/// O cano de verdade e quem está pendurado nele.
class _SharedLink {
  _SharedLink(this.key, this.link) {
    link.onClosed = (reason) {
      for (final u in users.toList()) {
        u.onClosed?.call(reason);
      }
    };
  }

  final String key;
  final ByteLink link;
  final Set<_PooledLink> users = {};
  Future<void>? _opening;

  /// Abre (uma vez só para quem pedir junto) e registra [user]. Se não abrir,
  /// [user] não fica registrado.
  Future<void> attach(_PooledLink user) async {
    if (!link.isOpen) await (_opening ??= link.open().whenComplete(() => _opening = null));
    users.add(user);
    // Quem pegou este cano do mapa logo antes de o último sair dele reabre o
    // mesmo socket — e o devolve ao mapa, para o próximo não abrir outro.
    RawLinkPool._links.putIfAbsent(key, () => this);
  }

  Future<void> detach(_PooledLink user) async {
    users.remove(user);
    if (users.isNotEmpty || _opening != null) return;
    if (identical(RawLinkPool._links[key], this)) RawLinkPool._links.remove(key);
    await link.close();
  }
}

/// O [ByteLink] que cada um recebe. Os bytes chegam pelo controlador próprio,
/// só enquanto está aberto — fechado, não recebe nem atrapalha os outros.
class _PooledLink extends ByteLink {
  _PooledLink(this._key, this._udp, this._create);

  final String _key;
  final bool _udp;
  final ByteLink Function() _create;
  final _input = StreamController<Uint8List>.broadcast();
  _SharedLink? _shared;
  StreamSubscription<Uint8List>? _forward;

  /// Conta os [close]: fechado enquanto abria, a abertura se desfaz.
  int _closes = 0;

  @override
  bool get isDatagram => _udp;

  @override
  bool get isOpen => _shared?.link.isOpen ?? false;

  @override
  Stream<Uint8List> get input => _input.stream;

  @override
  Future<void> open() async {
    final s = _shared ?? RawLinkPool._links.putIfAbsent(_key, () => _SharedLink(_key, _create()));
    // Escuta antes de abrir: nada que chegue logo na abertura se perde.
    _forward ??= s.link.input.listen(_input.add);
    final closes = _closes;
    try {
      await s.attach(this);
    } catch (_) {
      await _undo(s);
      rethrow;
    }
    if (closes != _closes) {
      // Fecharam (saiu da tela) enquanto o socket abria: não fica pendurado.
      await _forward?.cancel();
      _forward = null;
      await s.detach(this);
      throw const SocketException('fechado durante a abertura');
    }
    _shared = s;
  }

  /// Não abriu: solta a escuta e, se ninguém mais usa o cano, tira do mapa.
  Future<void> _undo(_SharedLink s) async {
    if (_shared != null) return; // já estava pendurado (reabertura depois de uma queda)
    await _forward?.cancel();
    _forward = null;
    if (s.users.isEmpty && identical(RawLinkPool._links[_key], s)) RawLinkPool._links.remove(_key);
  }

  @override
  Future<void> write(Uint8List bytes) async {
    final s = _shared;
    if (s == null) throw const SocketException('não conectado');
    await s.link.write(bytes);
  }

  @override
  Future<void> close() async {
    _closes++;
    final s = _shared;
    _shared = null;
    await _forward?.cancel();
    _forward = null;
    if (s != null) await s.detach(this);
  }
}
