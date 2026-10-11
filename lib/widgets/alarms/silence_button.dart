import 'package:flutter/material.dart';

import '../../app/app_scope.dart';
import '../../core/theme/app_theme.dart';
import '../../services/alarms/alarm_engine.dart';
import '../../services/voice/voice_announcer.dart';
import '../../services/voice/voice_prefs.dart';

/// **Silenciar**, separado de Reconhecer (VZ-3): cala a voz daquele alarme e
/// ele continua pedindo reconhecimento (piscando, na faixa, na lista).
///
/// Discreto de propósito — o gesto principal do cartão continua sendo
/// Reconhecer. Só aparece onde a voz insiste (prioridade em "Repete"); o
/// alarme que fala uma vez já calou sozinho. Na faixa ([compact]) é só o
/// ícone; no cartão, o texto — e, depois de silenciado, "Voz silenciada".
class SilenceButton extends StatelessWidget {
  const SilenceButton({super.key, required this.entry, this.compact = false});

  final AlarmEntry entry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<VoicePrefs>(
      valueListenable: VoicePrefsController.instance,
      builder: (context, prefs, _) {
        void silence() => AppScope.of(context).alarms.silence(entry.key);
        if (entry.silenced && !compact && entry.phase.unacked && prefs.enabled) {
          return Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.volume_off_outlined, size: 18, color: Ind.textMuted),
              const SizedBox(width: 6),
              Text('Voz silenciada', key: ValueKey('silenciado-${entry.key}'), style: TextStyle(color: Ind.textMuted, fontSize: 13)),
            ]),
          );
        }
        if (!VoiceAnnouncer.canSilence(entry, prefs)) return const SizedBox.shrink();
        if (compact) {
          // Sem tooltip: a faixa fica acima do Navigator, onde não há
          // Overlay para o balão. O nome vai para o leitor de tela.
          return Semantics(
            label: 'Silenciar a voz',
            button: true,
            excludeSemantics: true,
            child: IconButton(
              key: const ValueKey('silenciar-faixa'),
              onPressed: silence,
              icon: Icon(Icons.volume_off_outlined, color: Ind.textDim),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(left: 8),
          child: TextButton.icon(
            key: ValueKey('silenciar-${entry.key}'),
            onPressed: silence,
            style: TextButton.styleFrom(foregroundColor: Ind.textDim),
            icon: const Icon(Icons.volume_off_outlined),
            label: const Text('Silenciar'),
          ),
        );
      },
    );
  }
}
