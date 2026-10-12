// Uma câmera aberta em tela cheia (CM-2, CM-3): liga o player, traduz o que
// ele conta para o operador (conectando, ao vivo, sem sinal, senha recusada),
// estima o atraso e reconecta sozinha — com a mesma espera crescente dos
// equipamentos (1, 2, 4, 8, 10 s).
//
// Fechar a tela ou ir para segundo plano **descarta o player**: nada fica
// recebendo nem decodificando vídeo escondido (bateria e Wi-Fi da fábrica).

import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../../models/camera.dart';
import '../net/local_network.dart';
import 'camera_player.dart';
import 'camera_vault.dart';

/// Como a câmera está, para o operador.
enum CameraLink {
  connecting,
  live,

  /// Sem imagem: câmera desligada, fora da rede, parou de mandar. Tenta de
  /// novo sozinha.
  noSignal,

  /// A câmera recusou usuário ou senha. **Não** tenta de novo sozinha: muita
  /// câmera bloqueia o usuário depois de algumas tentativas erradas.
  authFailed,

  /// A câmera tem senha, mas ela não está neste aparelho (projeto importado).
  needsPassword,

  /// App em segundo plano: o vídeo parou de propósito.
  paused,
}

@immutable
class CameraStatus {
  const CameraStatus(this.link, {this.detail = '', this.latency, this.retryInSec, this.resolution});

  final CameraLink link;

  /// O motivo, em palavras ("a câmera recusou a conexão").
  final String detail;

  /// Atraso estimado: o vídeo que já chegou e ainda espera a vez no aparelho.
  /// Não conta a câmera codificando nem a tela — é o piso do atraso real.
  final Duration? latency;

  /// Segundos até a próxima tentativa (sem sinal); 0 = tentando agora.
  final int? retryInSec;

  /// "640 × 360".
  final ({int width, int height})? resolution;

  CameraStatus withRetry(int s) => CameraStatus(link, detail: detail, latency: latency, retryInSec: s, resolution: resolution);

  @override
  bool operator ==(Object other) =>
      other is CameraStatus &&
      other.link == link &&
      other.detail == detail &&
      other.latency == latency &&
      other.retryInSec == retryInSec &&
      other.resolution == resolution;

  @override
  int get hashCode => Object.hash(link, detail, latency, retryInSec, resolution);
}

/// Traduz o erro do player para o operador. O texto vem do ExoPlayer, em
/// inglês e técnico; aqui vira uma frase curta.
class CameraErrors {
  CameraErrors._();

  /// Resposta RTSP com o código ("DESCRIBE 401").
  static bool _status(String e, int code) => RegExp('(options|describe|setup|play) $code(?!\\d)', caseSensitive: false).hasMatch(e);

  /// Usuário ou senha recusados (RTSP 401).
  static bool isAuth(String error) => _status(error, 401) || error.toLowerCase().contains('unauthorized');

  static String describe(String error) {
    final e = error.toLowerCase();
    if (isAuth(error)) return 'a câmera recusou o usuário ou a senha';
    if (e == 'stall') return 'a imagem parou de chegar';
    if (e == 'first-image') return 'a câmera não mandou imagem';
    if (e == 'ended') return 'a câmera parou de mandar imagem';
    if (_status(error, 404) || e.contains('not found')) return 'a câmera não conhece esse endereço: confira o caminho depois do IP';
    if (e.contains('unknownhost') || e.contains('unable to resolve')) return 'nome da câmera não encontrado na rede';
    if (e.contains('ehostunreach') || e.contains('enetunreach') || e.contains('no route') || e.contains('etimedout') || e.contains('timeout')) {
      return 'a câmera não respondeu: está ligada e no mesmo Wi-Fi?';
    }
    if (e.contains('econnrefused') || e.contains('connection refused')) return 'a câmera recusou a conexão: confira o IP e a porta (554)';
    if (e.contains('decod') || e.contains('sprop') || e.contains('no playable track') || e.contains('sdp')) {
      return 'este celular não consegue mostrar o vídeo desta câmera: use o fluxo leve em H.264';
    }
    return 'sem sinal da câmera';
  }
}

class CameraSession extends ChangeNotifier {
  CameraSession(this._camera, {required this.vault, required this.newPlayer});

  /// Espera entre tentativas, a mesma da comunicação com os equipamentos.
  static const backoff = [1, 2, 4, 8, 10];

  /// Conectou e nada de imagem nesse tempo: sem sinal, tenta de novo.
  static const firstImageTimeout = Duration(seconds: 15);

  /// Imagem parada esse tempo (a câmera caiu sem fechar a conexão): sem sinal.
  static const stallTimeout = Duration(seconds: 5);

  final CameraVault vault;
  final CameraPlayerFactory newPlayer;

  IpCamera _camera;
  IpCamera get camera => _camera;

  CameraStatus _status = const CameraStatus(CameraLink.connecting);
  CameraStatus get status => _status;

  CameraPlayer? _player;

  /// O player desta abertura (a tela desenha a imagem dele). Nulo sem vídeo.
  CameraPlayer? get player => _player;

  bool _highQuality = false;

  /// Vendo o fluxo principal em vez do leve.
  bool get highQuality => _highQuality;

  /// Há os dois fluxos para escolher.
  bool get canSwitchQuality => _camera.substreamUrl.isNotEmpty;

  String get _streamUrl => _highQuality || _camera.substreamUrl.isEmpty ? _camera.url : _camera.substreamUrl;

  int _failures = 0;
  int _generation = 0;
  bool _disposed = false;
  bool _paused = false;

  Timer? _watchdog;
  Timer? _countdown;
  DateTime _openedAt = DateTime(0);
  DateTime _lastMove = DateTime(0);
  Duration _lastPosition = Duration.zero;
  bool _played = false;
  double? _latencyMs;

  /// Abre (ou reabre) o vídeo.
  Future<void> start() async {
    if (_disposed) return;
    final gen = ++_generation;
    _stopTimers();
    await _drop();
    String? password;
    final ref = _camera.secretRef;
    if (ref != null) {
      password = await vault.read(ref);
      if (gen != _generation || _disposed) return;
      if (password == null) {
        _set(const CameraStatus(CameraLink.needsPassword, detail: 'a senha desta câmera não está neste aparelho'));
        return;
      }
    }
    // Depois de uma falha, a nova tentativa continua "sem sinal" (com o
    // motivo) até a imagem voltar: "Conectando…" a cada 15 s dava a
    // impressão de que a câmera estava quase voltando.
    _set(_status.link == CameraLink.noSignal
        ? CameraStatus(CameraLink.noSignal, detail: _status.detail, retryInSec: 0)
        : const CameraStatus(CameraLink.connecting));
    // Wi-Fi da fábrica sem internet + 4G ligado: sem o vínculo, o vídeo
    // sairia pela operadora (o mesmo caso dos equipamentos, §4.14).
    final host = CameraUrl.host(_streamUrl);
    if (host != null) await LocalNetwork.prepare(host);
    if (gen != _generation || _disposed) return;
    final p = newPlayer();
    _player = p;
    _openedAt = clock.now();
    _lastMove = _openedAt;
    _lastPosition = Duration.zero;
    _played = false;
    _latencyMs = null;
    p.state.addListener(_onPlayer);
    _watchdog = Timer.periodic(const Duration(milliseconds: 500), (_) => _watch());
    notifyListeners();
    await p.open(CameraUrl.withCredentials(_streamUrl, _camera.username, password));
  }

  /// Câmera editada (senha nova, endereço) ou senha digitada: reabre.
  Future<void> update(IpCamera camera) {
    _camera = camera;
    _failures = 0;
    return _paused ? Future.value() : start();
  }

  /// Troca entre o fluxo leve e o principal.
  Future<void> setHighQuality(bool v) {
    if (v == _highQuality) return Future.value();
    _highQuality = v;
    _failures = 0;
    return start();
  }

  /// App em segundo plano: solta o player na hora.
  void pause() {
    if (_disposed || _paused) return;
    _paused = true;
    _generation++;
    _stopTimers();
    unawaited(_drop());
    _set(const CameraStatus(CameraLink.paused));
  }

  /// De volta ao app: abre de novo.
  void resume() {
    if (_disposed || !_paused) return;
    _paused = false;
    _failures = 0;
    unawaited(start());
  }

  void _onPlayer() {
    final p = _player;
    if (p == null || _disposed || _paused) return;
    final s = p.state.value;
    switch (s.phase) {
      case PlayerPhase.failed:
        _fail(s.error ?? '');
      case PlayerPhase.ended:
        _fail('ended');
      case PlayerPhase.playing:
        _moved(s.position);
        _played = true;
        _failures = 0;
        final buffered = s.bufferedEnd;
        if (buffered != null) {
          // Média móvel: o número na tela não pula a cada pacote.
          final ahead = math.max(0, (buffered - s.position).inMilliseconds).toDouble();
          _latencyMs = _latencyMs == null ? ahead : _latencyMs! * 0.8 + ahead * 0.2;
        }
        final size = s.size;
        _set(CameraStatus(
          CameraLink.live,
          latency: _latencyMs == null ? null : Duration(milliseconds: (_latencyMs! / 100).round() * 100),
          resolution: size == null ? null : (width: size.width.round(), height: size.height.round()),
        ));
      case PlayerPhase.opening:
      case PlayerPhase.buffering:
        // Enchendo de novo depois de tocar: o vigia decide se parou de vez.
        _moved(s.position);
    }
  }

  void _moved(Duration position) {
    if (position == _lastPosition) return;
    _lastPosition = position;
    _lastMove = clock.now();
  }

  void _watch() {
    final p = _player;
    if (p == null) return;
    final now = clock.now();
    _moved(p.state.value.position);
    if (!_played) {
      if (now.difference(_openedAt) > firstImageTimeout) _fail('first-image');
    } else if (now.difference(_lastMove) > stallTimeout) {
      _fail('stall');
    }
  }

  void _fail(String error) {
    if (_disposed || _paused) return;
    _generation++;
    _stopTimers();
    unawaited(_drop());
    if (CameraErrors.isAuth(error)) {
      _set(CameraStatus(CameraLink.authFailed, detail: CameraErrors.describe(error)));
      return;
    }
    final wait = backoff[math.min(_failures, backoff.length - 1)];
    _failures++;
    final gen = _generation;
    _set(CameraStatus(CameraLink.noSignal, detail: CameraErrors.describe(error), retryInSec: wait));
    unawaited(_diagnose(gen));
    var left = wait;
    _countdown = Timer.periodic(const Duration(seconds: 1), (t) {
      if (gen != _generation || _disposed) {
        t.cancel();
        return;
      }
      left--;
      if (left > 0) {
        _set(_status.withRetry(left));
      } else {
        t.cancel();
        unawaited(start());
      }
    });
  }

  /// Celular fora da rede da câmera diz mais que o erro do player.
  Future<void> _diagnose(int gen) async {
    final host = CameraUrl.host(_streamUrl);
    if (host == null || !LocalNetwork.isPrivateIPv4(host)) return;
    final nets = await LocalNetwork.list();
    if (nets == null || LocalNetwork.routeTo(host, nets) != null) return;
    if (gen != _generation || _disposed || _status.link != CameraLink.noSignal) return;
    final detail = nets.isEmpty
        ? 'o celular não está em nenhum Wi-Fi: conecte ao Wi-Fi da câmera'
        : 'o celular está em ${nets.first.rangeLabel} e a câmera em $host: são redes diferentes';
    _set(CameraStatus(CameraLink.noSignal, detail: detail, retryInSec: _status.retryInSec));
  }

  Future<void> _drop() async {
    final p = _player;
    if (p == null) return;
    _player = null;
    p.state.removeListener(_onPlayer);
    if (!_disposed) notifyListeners();
    await p.dispose();
  }

  void _stopTimers() {
    _watchdog?.cancel();
    _watchdog = null;
    _countdown?.cancel();
    _countdown = null;
  }

  void _set(CameraStatus s) {
    if (_disposed || s == _status) return;
    _status = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _stopTimers();
    unawaited(_drop());
    super.dispose();
  }
}
