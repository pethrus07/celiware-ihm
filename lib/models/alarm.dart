// Alarme: condição anormal de uma variável que o operador precisa ver e
// reconhecer. Segue a ANSI/ISA-18.2 (ver docs/PESQUISA-UI-UX.md §1.2):
// prioridade com cor E forma, estados distintos (não reconhecido pisca,
// reconhecido fica fixo, "voltou ao normal" espera reconhecimento).

/// O que dispara o alarme.
enum AlarmKind {
  /// Número acima do limite.
  above,

  /// Número abaixo do limite.
  below,

  /// Liga/desliga ficou ligado.
  on,

  /// Liga/desliga ficou desligado.
  off,
}

extension AlarmKindMeta on AlarmKind {
  bool get isAnalog => this == AlarmKind.above || this == AlarmKind.below;

  String get label => switch (this) {
        AlarmKind.above => 'Acima de',
        AlarmKind.below => 'Abaixo de',
        AlarmKind.on => 'Quando ligar',
        AlarmKind.off => 'Quando desligar',
      };

  static AlarmKind fromName(String? n) => AlarmKind.values.firstWhere((k) => k.name == n, orElse: () => AlarmKind.above);
}

/// Três prioridades — o mínimo da ISA-18.2 §11.4.2. A cor é reservada (não
/// aparece em nenhum outro elemento com outro sentido) e cada uma tem uma
/// forma própria, para daltônico e para visão periférica.
enum AlarmPriority {
  /// Vermelho, losango, "1": agir agora.
  high,

  /// Laranja, triângulo, "2": agir logo.
  medium,

  /// Amarelo, quadrado, "3": ficar atento.
  low,
}

extension AlarmPriorityMeta on AlarmPriority {
  int get number => index + 1;

  String get label => switch (this) {
        AlarmPriority.high => 'Alta',
        AlarmPriority.medium => 'Média',
        AlarmPriority.low => 'Baixa',
      };

  /// Frase curta que ajuda a escolher (no editor).
  String get hint => switch (this) {
        AlarmPriority.high => 'Agir agora',
        AlarmPriority.medium => 'Agir logo',
        AlarmPriority.low => 'Ficar atento',
      };

  static AlarmPriority fromName(String? n) =>
      AlarmPriority.values.firstWhere((p) => p.name == n, orElse: () => AlarmPriority.medium);
}

/// Uma regra de alarme de uma variável. Imutável; mora dentro da [Tag]
/// (viaja no arquivo do projeto e some junto se a variável for apagada).
class AlarmRule {
  const AlarmRule({
    required this.id,
    required this.kind,
    this.limit = 0,
    this.priority = AlarmPriority.medium,
    this.message = '',
  });

  final String id;
  final AlarmKind kind;

  /// Limite na unidade da tela (já com escala). Só para [AlarmKind.isAnalog].
  final double limit;
  final AlarmPriority priority;

  /// O que o operador lê: "Motor superaquecido". Vazio = gerado da regra.
  final String message;

  AlarmRule copyWith({AlarmKind? kind, double? limit, AlarmPriority? priority, String? message}) => AlarmRule(
        id: id,
        kind: kind ?? this.kind,
        limit: limit ?? this.limit,
        priority: priority ?? this.priority,
        message: message ?? this.message,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        if (kind.isAnalog) 'limit': limit,
        'priority': priority.name,
        if (message.isNotEmpty) 'message': message,
      };

  factory AlarmRule.fromJson(Map<String, dynamic> j) => AlarmRule(
        id: j['id'] as String? ?? '',
        kind: AlarmKindMeta.fromName(j['kind'] as String?),
        limit: (j['limit'] as num?)?.toDouble() ?? 0,
        priority: AlarmPriorityMeta.fromName(j['priority'] as String?),
        message: j['message'] as String? ?? '',
      );
}
