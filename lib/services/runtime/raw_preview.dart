import 'dart:async';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../../core/link/byte_link.dart';
import '../../core/modbus/modbus_client_serial.dart' show isConnectionRefused;
import '../../core/rawlink/message_parser.dart';
import '../../core/rawlink/message_profile.dart';
import '../../core/rawlink/raw_link_error.dart';
import '../../core/rawlink/raw_link_pool.dart';
import '../../models/device.dart';
import '../net/local_network.dart';

enum RawPreviewLink { connecting, connected, failed }

/// A prévia ao vivo do editor de perfil (RW-3): ouve o equipamento e mostra
/// o que o perfil **em edição** tira de cada mensagem.
///
/// O segredo é guardar os **bytes** que chegaram, não as mensagens: cada
/// mexida no perfil reinterpreta tudo de novo na hora ([profile]) — a pessoa
/// troca `;` por `,` e vê o efeito nas mensagens que já estão na tela, sem
/// esperar o equipamento mandar outra (equipamento em polling lento, balança
/// que só fala quando estabiliza). Guarda pouco ([maxBytes]): é uma janela
/// para olhar, não um registro.
///
/// Pelo cano compartilhado ([RawLinkPool]): editando um equipamento que as
/// telas já estão lendo, a prévia não disputa a única conexão que o sketch
/// atende. No polling, a prévia manda o pedido do perfil em edição — é o
/// jeito de testar o pedido antes de salvar.
class RawPreview extends ChangeNotifier {
  RawPreview(this.device, MessageProfile profile, {this.maxBytes = 4096, this.maxChunks = 80, this.maxFrames = 12})
      : _profile = profile {
    _reparse();
  }

  /// Onde ouvir: IP, porta, TCP/UDP e a porta local (o perfil vem à parte).
  final Device device;
  final int maxBytes;
  final int maxChunks;
  final int maxFrames;

  MessageProfile _profile;
  ByteLink? _link;
  StreamSubscription<Uint8List>? _sub;
  Timer? _pollTimer;
  bool _disposed = false;

  final List<Uint8List> _chunks = [];
  int _bytes = 0;
  List<RawFrame> _frames = const [];
  List<String> _problems = const [];
  RawPreviewLink _state = RawPreviewLink.connecting;
  String? _error;
  DateTime? _lastAt;

  MessageProfile get profile => _profile;

  /// Troca o perfil e reinterpreta na hora o que já chegou.
  set profile(MessageProfile p) {
    _profile = p;
    _reparse();
    _restartPoll();
    _notify();
  }

  /// As últimas mensagens, da mais velha para a mais nova — boas e com
  /// problema.
  List<RawFrame> get frames => _frames;

  /// O que impede o perfil de funcionar ("fim de linha vazio"). Com algum,
  /// não há mensagens para mostrar.
  List<String> get problems => _problems;

  RawPreviewLink get state => _state;

  /// Por que não conectou, em palavras de operador.
  String? get error => _error;

  /// Chegou algum byte desde que abriu.
  bool get heardAnything => _lastAt != null;
  DateTime? get lastAt => _lastAt;

  bool get isDatagram => device.raw.isUdp;

  // ── Conexão ──────────────────────────────────────────────────────────────────

  Future<void> start() async {
    if (_disposed) return;
    _state = RawPreviewLink.connecting;
    _error = null;
    _notify();
    final raw = device.raw;
    final link = _link ??= RawLinkPool.acquire(
      udp: raw.isUdp,
      host: device.host,
      port: device.port,
      localPort: raw.localPort,
      connectionTimeout: Duration(milliseconds: max(1000, device.timeoutMs)),
      beforeConnect: LocalNetwork.prepare,
    );
    _sub ??= link.input.listen(_onChunk);
    link.onClosed = (_) {
      _pollTimer?.cancel();
      _state = RawPreviewLink.failed;
      _error = 'a conexão caiu';
      _notify();
    };
    try {
      await link.open();
    } catch (e) {
      if (_disposed) return;
      _state = RawPreviewLink.failed;
      _error = isConnectionRefused(e) ? 'o equipamento recusou a conexão nesta porta' : 'sem conexão com o equipamento';
      _notify();
      return;
    }
    if (_disposed) {
      await link.close();
      return;
    }
    _state = RawPreviewLink.connected;
    _restartPoll();
    _notify();
  }

  void _onChunk(Uint8List chunk) {
    _chunks.add(chunk);
    _bytes += chunk.length;
    while (_chunks.length > 1 && (_chunks.length > maxChunks || _bytes > maxBytes)) {
      _bytes -= _chunks.removeAt(0).length;
    }
    _lastAt = clock.now();
    _reparse();
    _notify();
  }

  /// Passa todos os bytes guardados pelo perfil atual, do zero.
  void _reparse() {
    _problems = _profile.problems();
    if (_problems.isNotEmpty) {
      _frames = const [];
      return;
    }
    final MessageParser parser;
    try {
      parser = MessageParser(_profile);
    } on RawProfileError catch (e) {
      _problems = [e.message];
      _frames = const [];
      return;
    }
    final out = <RawFrame>[];
    for (final c in _chunks) {
      out.addAll(parser.add(c));
      if (isDatagram) out.addAll(parser.endOfPacket());
    }
    _frames = out.length > maxFrames ? out.sublist(out.length - maxFrames) : out;
  }

  /// Polling: o pedido do perfil em edição, já na conexão e a cada `pollMs`.
  void _restartPoll() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (_state != RawPreviewLink.connected || _problems.isNotEmpty || _profile.mode != RawMode.polling) return;
    _pollTimer = Timer.periodic(Duration(milliseconds: max(200, _profile.pollMs)), (_) => _poll());
    _poll();
  }

  void _poll() {
    final link = _link;
    if (link == null || !link.isOpen) return;
    try {
      link.write(MessageParser(_profile).pollBytes()).catchError((Object _) {});
    } on RawLinkError {/* pedido que não monta: o editor já mostra o problema */}
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _sub?.cancel();
    _link?.close();
    super.dispose();
  }
}
