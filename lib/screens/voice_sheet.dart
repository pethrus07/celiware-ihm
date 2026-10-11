import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_scope.dart';
import '../core/theme/app_theme.dart';
import '../models/alarm.dart';
import '../services/voice/audio_output.dart';
import '../services/voice/speech_engine.dart';
import '../services/voice/voice_prefs.dart';
import '../widgets/alarms/alarm_widgets.dart';
import '../widgets/common/common.dart';

/// Linha "Voz e avisos" da aba Mais: o estado numa frase e toque para a
/// folha. Falta de voz pt-BR aparece aqui, na cor de alarme — é onde a
/// pessoa procura quando "o fone não falou".
class VoiceSettingsTile extends StatelessWidget {
  const VoiceSettingsTile({super.key});

  @override
  Widget build(BuildContext context) {
    final voice = AppScope.of(context).voice;
    final prefs = VoicePrefsController.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([prefs, ?voice?.status]),
      builder: (context, _) {
        final p = prefs.value;
        final problem = p.enabled && (voice?.status.value.isProblem ?? false);
        final summary = !p.enabled
            ? 'Desligada'
            : problem
                ? 'Falta a voz em português'
                : p.onlyWithHeadset && AudioOutput.canDetectHeadset
                    ? 'Fala os alarmes · só com fone'
                    : 'Fala os alarmes';
        return ListTile(
          key: const ValueKey('voz-e-avisos'),
          leading: Icon(p.enabled ? Icons.record_voice_over_outlined : Icons.voice_over_off_outlined),
          title: const Text('Voz e avisos'),
          subtitle: Text(summary, style: problem ? TextStyle(color: Ind.textFor(Ind.alarm), fontWeight: FontWeight.w600) : null),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => VoiceSheet.show(context),
        );
      },
    );
  }
}

/// Folha de voz: o essencial à vista (ligar, só com fone, volume,
/// velocidade, exemplo); quem fala o quê e a narração em "Mais opções".
///
/// Tudo aqui é do aparelho (`shared_preferences`), não do projeto.
class VoiceSheet extends StatefulWidget {
  const VoiceSheet({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => const VoiceSheet(),
      );

  @override
  State<VoiceSheet> createState() => _VoiceSheetState();
}

class _VoiceSheetState extends State<VoiceSheet> {
  final _moreKey = GlobalKey();

  /// Fone conectado agora (nulo = a plataforma não informa).
  bool? _headset;

  VoicePrefsController get _prefs => VoicePrefsController.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_checkHeadset());
    // Abrir a folha confere de novo: a pessoa pode ter acabado de baixar a voz.
    final voice = AppScope.of(context).voice;
    if (voice != null && _prefs.value.enabled) unawaited(voice.refreshStatus());
  }

  Future<void> _checkHeadset() async {
    final h = await AudioOutput.headsetConnected();
    if (mounted) setState(() => _headset = h);
  }

  void _set(VoicePrefs p) => _prefs.set(p);

  @override
  Widget build(BuildContext context) {
    final voice = AppScope.of(context).voice;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.96,
      builder: (context, scroll) => ListenableBuilder(
        listenable: Listenable.merge([_prefs, ?voice?.status]),
        builder: (context, _) {
          final p = _prefs.value;
          final status = voice?.status.value ?? VoiceStatus.unknown;
          return ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(Ind.page, 0, Ind.page, 32),
            children: [
              Text('Voz e avisos', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 6),
              Text('Fala os alarmes no fone. A faixa no topo e a vibração continuam sempre, com ou sem voz.',
                  style: TextStyle(color: Ind.textDim, height: 1.4)),
              if (p.enabled && status.problem != null) ...[
                const SizedBox(height: Ind.space),
                _MissingVoice(message: status.problem!),
              ],
              const SizedBox(height: Ind.spaceSmall),
              SwitchListTile(
                key: const ValueKey('voz-ligada'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Falar os alarmes'),
                value: p.enabled,
                onChanged: (v) => _set(p.copyWith(enabled: v)),
              ),
              if (p.enabled) ...[
                if (AudioOutput.canDetectHeadset)
                  SwitchListTile(
                    key: const ValueKey('so-com-fone'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Só com fone conectado'),
                    subtitle: const Text('Com fio, Bluetooth ou USB. Sem fone, fica calado.'),
                    value: p.onlyWithHeadset,
                    onChanged: (v) => _set(p.copyWith(onlyWithHeadset: v)),
                  ),
                const SectionHeader('Volume', padding: EdgeInsets.fromLTRB(0, 20, 0, 4)),
                Slider(
                  key: const ValueKey('volume-voz'),
                  value: p.volume.clamp(0.2, 1.0),
                  min: 0.2,
                  max: 1,
                  divisions: 8,
                  label: '${(p.volume * 100).round()}%',
                  // Arrastar só mexe no valor; grava ao soltar.
                  onChanged: (v) => _prefs.value = p.copyWith(volume: v),
                  onChangeEnd: (v) => _set(p.copyWith(volume: v)),
                ),
                const SectionHeader('Velocidade', padding: EdgeInsets.fromLTRB(0, 12, 0, 10)),
                ChoiceCards<VoiceRate>(
                  options: [for (final r in VoiceRate.values) ChoiceOption(value: r, title: r.label)],
                  selected: p.rate,
                  columns: 3,
                  onChanged: (r) => _set(p.copyWith(rate: r)),
                ),
                const SizedBox(height: Ind.spaceLarge),
                OutlinedButton.icon(
                  key: const ValueKey('falar-exemplo'),
                  onPressed: voice?.speakSample,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Falar um exemplo'),
                ),
                if (p.onlyWithHeadset && _headset == false) ...[
                  const SizedBox(height: 8),
                  Text('Sem fone agora: o exemplo sai no alto-falante, mas os alarmes ficam calados até um fone ser conectado.',
                      style: TextStyle(color: Ind.textMuted, fontSize: 13, height: 1.4)),
                ],
                const SizedBox(height: Ind.space),
                Theme(
                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    key: _moreKey,
                    tilePadding: EdgeInsets.zero,
                    onExpansionChanged: (open) => revealAfterExpand(_moreKey, open),
                    title: const Text('Mais opções'),
                    subtitle: Text(_summary(p), style: TextStyle(color: Ind.textMuted, fontSize: 13)),
                    expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                    childrenPadding: const EdgeInsets.only(bottom: 8),
                    children: [
                      for (final pr in AlarmPriority.values) _PriorityMode(priority: pr, mode: p.modeFor(pr), onChanged: (m) => _set(p.withMode(pr, m))),
                      const SectionHeader('Repetir a cada', padding: EdgeInsets.fromLTRB(0, 16, 0, 8)),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        for (final s in VoicePrefs.repeatChoices)
                          ChoiceChip(
                            key: ValueKey('repetir-$s'),
                            label: Text(_seconds(s)),
                            selected: p.repeatSec == s,
                            onSelected: (_) => _set(p.copyWith(repeatSec: s)),
                          ),
                      ]),
                      const SizedBox(height: 12),
                      SwitchListTile(
                        key: const ValueKey('narrar-eventos'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Narrar eventos das variáveis'),
                        subtitle: const Text('Configurado no cadastro de cada variável. Fala depois dos alarmes.'),
                        value: p.narrate,
                        onChanged: (v) => _set(p.copyWith(narrate: v)),
                      ),
                      if (p.narrate) ...[
                        const SectionHeader('Mesmo evento, no máximo a cada', padding: EdgeInsets.fromLTRB(0, 8, 0, 8)),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          for (final s in VoicePrefs.gapChoices)
                            ChoiceChip(label: Text(_seconds(s)), selected: p.narrationGapSec == s, onSelected: (_) => _set(p.copyWith(narrationGapSec: s))),
                        ]),
                      ],
                      const SizedBox(height: Ind.space),
                      Text('Com o app em segundo plano não há voz: a leitura dos equipamentos para junto.',
                          style: TextStyle(color: Ind.textMuted, fontSize: 13, height: 1.4)),
                    ],
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  static String _seconds(int s) => s >= 60 ? '${s ~/ 60} min' : '$s s';

  /// "Alta repete a cada 30 s · média uma vez · baixa não fala".
  static String _summary(VoicePrefs p) {
    String part(AlarmPriority pr) {
      final m = p.modeFor(pr);
      final what = m == VoiceMode.repeat ? 'repete a cada ${_seconds(p.repeatSec)}' : m.label.toLowerCase();
      return '${pr.label} $what';
    }

    final s = AlarmPriority.values.map(part).join(' · ');
    return '${s[0]}${s.substring(1).toLowerCase()}';
  }
}

/// Aviso de voz pt-BR ausente (VZ-6), com o caminho para resolver.
class _MissingVoice extends StatelessWidget {
  const _MissingVoice({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('voz-faltando'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      decoration: BoxDecoration(color: Ind.alarm.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(Ind.radiusSmall)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.voice_over_off_outlined, color: Ind.textFor(Ind.alarm)),
          const SizedBox(width: 12),
          Expanded(child: Text('$message Até lá, os alarmes ficam só na faixa e na vibração.', style: TextStyle(color: Ind.text, height: 1.4))),
        ]),
        if (AudioOutput.canOpenVoiceSettings)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const ValueKey('abrir-ajustes-voz'),
              onPressed: AudioOutput.openVoiceSettings,
              child: const Text('Abrir ajustes de voz'),
            ),
          ),
      ]),
    );
  }
}

/// Quanto fala cada prioridade, com a forma de verdade ao lado.
class _PriorityMode extends StatelessWidget {
  const _PriorityMode({required this.priority, required this.mode, required this.onChanged});
  final AlarmPriority priority;
  final VoiceMode mode;
  final ValueChanged<VoiceMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(children: [
        AlarmShape(priority: priority, size: 22),
        const SizedBox(width: 12),
        SizedBox(width: 56, child: Text(priority.label, style: TextStyle(fontWeight: FontWeight.w600, color: Ind.text))),
        // Celular estreito: as escolhas quebram linha em vez de transbordar.
        Expanded(
          child: Wrap(alignment: WrapAlignment.end, spacing: 6, runSpacing: 6, children: [
          for (final m in VoiceMode.values)
            ChoiceChip(
              key: ValueKey('modo-${priority.name}-${m.name}'),
              label: Text(m.label),
              selected: mode == m,
              visualDensity: VisualDensity.compact,
              onSelected: (_) => onChanged(m),
            ),
          ]),
        ),
      ]),
    );
  }
}
