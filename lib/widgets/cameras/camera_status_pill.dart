import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../services/cameras/camera_session.dart';

/// "0,8 s".
String secondsLabel(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(1).replaceAll('.', ',')} s';

/// Selo da câmera, sobre o vídeo (fundo preto): o estado numa palavra e, ao
/// vivo, o atraso. Cor só quando comunica — verde ao vivo, vermelho sem
/// imagem, amarelo esperando.
class CameraStatusPill extends StatelessWidget {
  const CameraStatusPill({super.key, required this.status});
  final CameraStatus status;

  static (Color, IconData, String) describe(CameraStatus s) => switch (s.link) {
        CameraLink.connecting => (Ind.warn, Icons.sync_rounded, 'Conectando…'),
        CameraLink.live => (
            Ind.ok,
            Icons.fiber_manual_record_rounded,
            s.latency == null ? 'Ao vivo' : 'Ao vivo · atraso ~${secondsLabel(s.latency!)}',
          ),
        CameraLink.noSignal => (
            Ind.alarm,
            Icons.videocam_off_rounded,
            switch (s.retryInSec) {
              null => 'Sem sinal',
              0 => 'Sem sinal · tentando…',
              final n => 'Sem sinal · de novo em $n s',
            },
          ),
        CameraLink.authFailed => (Ind.alarm, Icons.lock_outline_rounded, 'Senha recusada'),
        CameraLink.needsPassword => (Ind.warn, Icons.key_rounded, 'Falta a senha'),
        CameraLink.paused => (Colors.white54, Icons.pause_rounded, 'Pausada'),
      };

  @override
  Widget build(BuildContext context) {
    final (color, icon, text) = describe(status);
    return Container(
      key: const ValueKey('selo-camera'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.7)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(text,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()])),
        ),
      ]),
    );
  }
}
