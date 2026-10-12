// O player de vídeo, visto pela câmera: abrir um endereço RTSP, dizer em
// que pé está e desenhar a imagem. A `CameraSession` decide o resto (estado
// para o operador, latência, reconexão) — e os testes trocam o player por um
// falso, sem rede nem decodificador.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Em que pé o player está.
enum PlayerPhase {
  /// Conectando e esperando o primeiro pedaço de vídeo.
  opening,

  /// Conectado, sem imagem nova agora (ainda enchendo ou a câmera parou).
  buffering,

  /// Imagem andando.
  playing,

  /// O fluxo acabou (a câmera parou de mandar e o player desistiu).
  ended,

  /// Erro; o motivo vem em [PlayerState.error].
  failed,
}

/// Fotografia do player num instante.
@immutable
class PlayerState {
  const PlayerState({
    this.phase = PlayerPhase.opening,
    this.error,
    this.position = Duration.zero,
    this.bufferedEnd,
    this.size,
  });

  final PlayerPhase phase;

  /// O motivo do erro como o player conta (em inglês, técnico). A sessão
  /// traduz; nunca vai cru para o operador.
  final String? error;

  /// Instante do vídeo que está na tela.
  final Duration position;

  /// Até onde já chegou vídeo da câmera. A diferença para [position] é o
  /// vídeo guardado no aparelho esperando a vez — o atraso que o player põe.
  final Duration? bufferedEnd;

  /// Resolução do vídeo (largura × altura), quando já se sabe.
  final Size? size;

  @override
  bool operator ==(Object other) =>
      other is PlayerState &&
      other.phase == phase &&
      other.error == error &&
      other.position == position &&
      other.bufferedEnd == bufferedEnd &&
      other.size == size;

  @override
  int get hashCode => Object.hash(phase, error, position, bufferedEnd, size);
}

/// Um player para uma abertura: [open] uma vez, [dispose] no fim. Para
/// reconectar, a sessão descarta este e cria outro — o player que deu erro
/// não fica pela metade.
abstract class CameraPlayer {
  ValueListenable<PlayerState> get state;

  /// Abre o fluxo (o endereço já vem com usuário e senha, se houver). Não
  /// lança: erro vira [PlayerPhase.failed].
  Future<void> open(String url);

  /// A imagem, do tamanho que couber (proporção do vídeo).
  Widget view();

  /// Para de receber e de decodificar e solta o decodificador.
  Future<void> dispose();
}

/// Fábrica de players: a de verdade em `camera_players.dart`; os testes trocam.
typedef CameraPlayerFactory = CameraPlayer Function();
