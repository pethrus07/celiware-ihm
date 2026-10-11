// Narração de eventos: "quando a variável passar a valer X, falar '<texto>'
// no fone". Não é alarme — não pede reconhecimento, não entra na lista nem
// no histórico, e fala sempre DEPOIS dos alarmes (ver VoiceAnnouncer).
//
// Caso que motivou (item 12 da lista do cliente): variável inteira de estado
// em que cada valor tem um texto — "1 → A máquina está iniciando",
// "2 → Montagem"... Cada valor vira uma narração da mesma variável.

/// O que dispara a fala. Sempre na **passagem** (a variável chegou lá agora),
/// nunca enquanto continua lá: estado parado não fala de novo.
enum NarrationKind {
  /// Passou a valer exatamente [EventNarration.value] (em liga/desliga:
  /// 1 = ligou, 0 = desligou).
  equals,

  /// Passou de [EventNarration.value] para cima.
  above,

  /// Ficou abaixo de [EventNarration.value].
  below,
}

extension NarrationKindMeta on NarrationKind {
  String get label => switch (this) {
        NarrationKind.equals => 'Valer',
        NarrationKind.above => 'Passar de',
        NarrationKind.below => 'Ficar abaixo de',
      };

  static NarrationKind fromName(String? n) =>
      NarrationKind.values.firstWhere((k) => k.name == n, orElse: () => NarrationKind.equals);
}

/// Uma narração de uma variável. Imutável; mora dentro da [Tag] (viaja no
/// arquivo do projeto e some junto se a variável for apagada), como os
/// alarmes.
class EventNarration {
  const EventNarration({required this.id, this.kind = NarrationKind.equals, this.value = 0, this.text = ''});

  final String id;
  final NarrationKind kind;

  /// Valor na unidade da tela (já com escala). Em liga/desliga: 1 ou 0.
  final double value;

  /// O que o fone fala: "A máquina está iniciando". Vazio não fala (é
  /// descartado por `Tag.normalized`).
  final String text;

  /// Fala longa vira ruído no fone (e atrasa o alarme que vier atrás).
  static const maxText = 80;

  EventNarration copyWith({NarrationKind? kind, double? value, String? text}) =>
      EventNarration(id: id, kind: kind ?? this.kind, value: value ?? this.value, text: text ?? this.text);

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'value': value,
        'text': text,
      };

  factory EventNarration.fromJson(Map<String, dynamic> j) => EventNarration(
        id: j['id'] as String? ?? '',
        kind: NarrationKindMeta.fromName(j['kind'] as String?),
        value: (j['value'] as num?)?.toDouble() ?? 0,
        text: j['text'] as String? ?? '',
      );
}

/// Regra pura da narração — separada para ser testada sem app.
class NarrationLogic {
  NarrationLogic._();

  /// O valor está na condição? Liga/desliga conta como 1/0.
  static bool matches(EventNarration n, Object? value) {
    final v = value is bool ? (value ? 1.0 : 0.0) : (value is num ? value.toDouble() : null);
    if (v == null) return false;
    return switch (n.kind) {
      // Tolerância de ponto flutuante: 75,2 lido com escala ÷ 10 vem 75,200000001.
      NarrationKind.equals => (v - n.value).abs() < 1e-6,
      NarrationKind.above => v > n.value,
      NarrationKind.below => v < n.value,
    };
  }

  /// Fala agora? Só na passagem: antes fora da condição, agora dentro. Sem
  /// leitura anterior (app abrindo, comunicação voltando) não fala — não dá
  /// para saber se o evento aconteceu agora ou há uma hora.
  static bool fires(EventNarration n, {required Object? previous, required Object? current}) =>
      previous != null && !matches(n, previous) && matches(n, current);
}
