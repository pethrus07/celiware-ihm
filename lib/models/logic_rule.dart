// Regra entre máquinas (REQUISITOS-ETAPA4 §9.5, LG-4 a LG-7): "quando
// [condição] durar [T s], então gravar [valor] em [variável]".
//
// O app NUNCA é função de segurança da máquina: celular lendo por Wi-Fi tem
// latência sem limite (Wi-Fi caiu, app fechado, Android matou o processo) e
// não atende NR-12 nem ISO 13849. Por isso o padrão é PROPOR — a regra avisa e
// pergunta; gravar sozinha só se a pessoa escolher, e só para parar (gravar
// desligado/zero), nunca para dar partida.

import 'calc.dart';

/// Como a regra age quando a condição se cumpre.
enum RuleMode {
  /// Avisa e pergunta ("Parar a prensa?") — grava só se a pessoa tocar em
  /// Gravar. Padrão (LG-6).
  propose,

  /// Grava sozinha. Só com o termo aceito e só para parar ou avisar: valor
  /// desligado/zero ([LogicRule.canBeAutomatic]).
  automatic,
}

/// Uma regra. Imutável.
class LogicRule {
  const LogicRule({
    required this.id,
    required this.name,
    this.condition = const CalcSpec(expression: ''),
    this.holdSec = 0,
    this.targetTagId = '',
    this.value = 0,
    this.mode = RuleMode.propose,
    this.enabled = true,
  });

  final String id;

  /// O que a regra faz, em palavras de quem opera: "Parar a prensa". Vira a
  /// pergunta da proposta ("Parar a prensa?").
  final String name;

  /// A condição, na mesma linguagem das variáveis calculadas; precisa dar
  /// liga/desliga (uma comparação, `e`, `ou`, `não`...).
  final CalcSpec condition;

  /// Quanto tempo a condição precisa durar antes de a regra agir — um pico de
  /// uma leitura não dispara nada. 0 = na hora.
  final int holdSec;

  /// A variável onde gravar. Precisa estar marcada "aceita escrita por regra"
  /// (LG-5, [Tag.acceptsRuleWrite]).
  final String targetTagId;

  /// O valor a gravar, na unidade da tela (liga/desliga: 1 ou 0).
  final double value;

  final RuleMode mode;
  final bool enabled;

  static const maxHoldSec = 3600;

  /// Automático só para parar: gravar 0 / desligado. Dar partida sozinha,
  /// nunca (LG-6).
  bool get canBeAutomatic => value == 0;

  LogicRule copyWith({
    String? name,
    CalcSpec? condition,
    int? holdSec,
    String? targetTagId,
    double? value,
    RuleMode? mode,
    bool? enabled,
  }) =>
      LogicRule(
        id: id,
        name: name ?? this.name,
        condition: condition ?? this.condition,
        holdSec: holdSec ?? this.holdSec,
        targetTagId: targetTagId ?? this.targetTagId,
        value: value ?? this.value,
        mode: mode ?? this.mode,
        enabled: enabled ?? this.enabled,
      );

  /// Corrige o impossível vindo de arquivo ou de edição: tempo fora da faixa
  /// e automático que daria partida (volta a propor).
  LogicRule normalized() {
    var r = this;
    if (r.holdSec < 0 || r.holdSec > maxHoldSec) r = r.copyWith(holdSec: r.holdSec.clamp(0, maxHoldSec));
    if (!r.value.isFinite) r = r.copyWith(value: 0);
    if (r.mode == RuleMode.automatic && !r.canBeAutomatic) r = r.copyWith(mode: RuleMode.propose);
    return r;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'condition': condition.toJson(),
        if (holdSec != 0) 'holdSec': holdSec,
        'target': targetTagId,
        'value': value,
        // Só quando foge do padrão (propor, ligada).
        if (mode != RuleMode.propose) 'mode': mode.name,
        if (!enabled) 'enabled': false,
      };

  factory LogicRule.fromJson(Map<String, dynamic> j) => LogicRule(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? 'Regra',
        condition: j['condition'] is Map ? CalcSpec.fromJson(Map<String, dynamic>.from(j['condition'] as Map)) : const CalcSpec(expression: ''),
        holdSec: (j['holdSec'] as num?)?.toInt() ?? 0,
        targetTagId: (j['target'] as String?) ?? '',
        value: (j['value'] as num?)?.toDouble() ?? 0,
        // Modo desconhecido (versão mais nova) cai no seguro: propor.
        mode: RuleMode.values.where((m) => m.name == j['mode']).firstOrNull ?? RuleMode.propose,
        enabled: (j['enabled'] as bool?) ?? true,
      ).normalized();
}
