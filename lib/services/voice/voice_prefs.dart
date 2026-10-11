import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/alarm.dart';

/// Quanto a voz fala um alarme de uma prioridade.
enum VoiceMode {
  /// Não fala (a faixa e a vibração continuam).
  never,

  /// Fala uma vez, quando dispara.
  once,

  /// Fala quando dispara e repete enquanto ninguém reconhecer nem silenciar.
  repeat,
}

extension VoiceModeMeta on VoiceMode {
  String get label => switch (this) {
        VoiceMode.never => 'Não fala',
        VoiceMode.once => 'Uma vez',
        VoiceMode.repeat => 'Repete',
      };

  static VoiceMode fromName(String? n, VoiceMode fallback) =>
      VoiceMode.values.firstWhere((m) => m.name == n, orElse: () => fallback);
}

/// Velocidade da fala, em três passos (slider de velocidade é ajuste fino
/// que ninguém acerta com luva).
enum VoiceRate { slow, normal, fast }

extension VoiceRateMeta on VoiceRate {
  String get label => switch (this) {
        VoiceRate.slow => 'Devagar',
        VoiceRate.normal => 'Normal',
        VoiceRate.fast => 'Rápida',
      };

  /// Valor do `flutter_tts` (0,5 = velocidade normal do Android).
  double get value => switch (this) {
        VoiceRate.slow => 0.4,
        VoiceRate.normal => 0.5,
        VoiceRate.fast => 0.62,
      };
}

/// Preferências de voz. Imutável.
///
/// São **do aparelho**, não do projeto (como a aparência): o mesmo projeto
/// roda no celular do operador com fone e no tablet preso na máquina, que
/// não tem fone nenhum.
@immutable
class VoicePrefs {
  const VoicePrefs({
    this.enabled = true,
    this.onlyWithHeadset = true,
    this.volume = 1.0,
    this.rate = VoiceRate.normal,
    this.high = VoiceMode.repeat,
    this.medium = VoiceMode.once,
    this.low = VoiceMode.never,
    this.repeatSec = 30,
    this.narrate = true,
    this.narrationGapSec = 10,
  });

  /// Liga a voz (alarmes e narração).
  final bool enabled;

  /// Só fala com fone conectado (com fio, Bluetooth, USB). Ligado por
  /// padrão: no chão de fábrica o alto-falante não se ouve, e no escritório
  /// a voz saindo do bolso assusta mais do que avisa.
  final bool onlyWithHeadset;

  /// 0 a 1, relativo ao volume de mídia do celular.
  final double volume;
  final VoiceRate rate;

  /// Alta repete, média fala uma vez, baixa não fala (VZ-2) — configurável.
  final VoiceMode high;
  final VoiceMode medium;
  final VoiceMode low;

  /// Intervalo da repetição de quem está em [VoiceMode.repeat].
  final int repeatSec;

  /// Fala as narrações configuradas nas variáveis.
  final bool narrate;

  /// No máximo uma fala por narração a cada este tanto de segundos — valor
  /// oscilando em cima do limite não vira metralhadora no ouvido.
  final int narrationGapSec;

  static const repeatChoices = [15, 30, 60, 120];
  static const gapChoices = [5, 10, 30, 60];

  VoiceMode modeFor(AlarmPriority p) => switch (p) {
        AlarmPriority.high => high,
        AlarmPriority.medium => medium,
        AlarmPriority.low => low,
      };

  VoicePrefs withMode(AlarmPriority p, VoiceMode m) => switch (p) {
        AlarmPriority.high => copyWith(high: m),
        AlarmPriority.medium => copyWith(medium: m),
        AlarmPriority.low => copyWith(low: m),
      };

  VoicePrefs copyWith({
    bool? enabled,
    bool? onlyWithHeadset,
    double? volume,
    VoiceRate? rate,
    VoiceMode? high,
    VoiceMode? medium,
    VoiceMode? low,
    int? repeatSec,
    bool? narrate,
    int? narrationGapSec,
  }) =>
      VoicePrefs(
        enabled: enabled ?? this.enabled,
        onlyWithHeadset: onlyWithHeadset ?? this.onlyWithHeadset,
        volume: volume ?? this.volume,
        rate: rate ?? this.rate,
        high: high ?? this.high,
        medium: medium ?? this.medium,
        low: low ?? this.low,
        repeatSec: repeatSec ?? this.repeatSec,
        narrate: narrate ?? this.narrate,
        narrationGapSec: narrationGapSec ?? this.narrationGapSec,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'onlyWithHeadset': onlyWithHeadset,
        'volume': volume,
        'rate': rate.name,
        'high': high.name,
        'medium': medium.name,
        'low': low.name,
        'repeatSec': repeatSec,
        'narrate': narrate,
        'narrationGapSec': narrationGapSec,
      };

  /// Campo ausente ou estranho fica no padrão (preferência de versão antiga
  /// ou mais nova nunca derruba a voz).
  factory VoicePrefs.fromJson(Map<String, dynamic> j) {
    const d = VoicePrefs();
    int sec(Object? v, int fallback) => v is int && v > 0 && v <= 3600 ? v : fallback;
    String? str(Object? v) => v is String ? v : null;
    final vol = j['volume'];
    return VoicePrefs(
      enabled: j['enabled'] is bool ? j['enabled'] as bool : d.enabled,
      onlyWithHeadset: j['onlyWithHeadset'] is bool ? j['onlyWithHeadset'] as bool : d.onlyWithHeadset,
      volume: vol is num ? vol.toDouble().clamp(0.0, 1.0) : d.volume,
      rate: VoiceRate.values.firstWhere((r) => r.name == j['rate'], orElse: () => d.rate),
      high: VoiceModeMeta.fromName(str(j['high']), d.high),
      medium: VoiceModeMeta.fromName(str(j['medium']), d.medium),
      low: VoiceModeMeta.fromName(str(j['low']), d.low),
      repeatSec: sec(j['repeatSec'], d.repeatSec),
      narrate: j['narrate'] is bool ? j['narrate'] as bool : d.narrate,
      narrationGapSec: sec(j['narrationGapSec'], d.narrationGapSec),
    );
  }

  @override
  bool operator ==(Object other) => other is VoicePrefs && mapEquals(toJson(), other.toJson());

  @override
  int get hashCode => Object.hashAll(toJson().values);
}

/// Dono das preferências de voz, guardadas por aparelho no
/// `shared_preferences` (mesmo padrão do [AppearanceController]).
class VoicePrefsController extends ValueNotifier<VoicePrefs> {
  VoicePrefsController() : super(const VoicePrefs());

  static final instance = VoicePrefsController();
  static const _key = 'voz';

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_key);
      if (saved == null) return;
      final raw = jsonDecode(saved);
      if (raw is Map) value = VoicePrefs.fromJson(Map<String, dynamic>.from(raw));
    } catch (_) {/* sem preferência legível: padrão */}
  }

  Future<void> set(VoicePrefs p) async {
    value = p;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(p.toJson()));
    } catch (_) {}
  }
}
