import 'package:flutter/foundation.dart';

/// Situação de uma leitura — decide como o elemento se desenha.
enum TagQuality {
  /// Ainda não chegou a primeira leitura.
  waiting,

  /// Valor válido e recente.
  good,

  /// A comunicação caiu. [TagReading.value] guarda o **último valor bom**,
  /// que a tela mostra esmaecido — nunca zerado, para o operador não ler um
  /// "0" falso como se fosse real.
  commLost,

  /// O equipamento recusou o endereço (exceção Modbus 0x02) — a variável
  /// aponta para memória que não existe. Erro de configuração, não de rede.
  addressError,

  /// Outro problema de configuração: variável apagada, pedido fora dos
  /// limites, função não suportada pelo equipamento.
  configError,
}

extension TagQualityMeta on TagQuality {
  bool get isProblem => this != TagQuality.good && this != TagQuality.waiting;
}

/// Último estado conhecido de uma variável.
@immutable
class TagReading {
  const TagReading({
    this.value,
    this.quality = TagQuality.waiting,
    this.message = '',
    this.at,
  });

  /// `bool`, `int`, `double` ou `List` deles (variável com [Tag.length] > 1).
  final Object? value;
  final TagQuality quality;

  /// Motivo, quando [quality] é um problema (texto para o operador).
  final String message;

  final DateTime? at;

  bool get isGood => quality == TagQuality.good;

  static const TagReading waiting = TagReading();

  /// Mantém o último valor e só troca a qualidade (queda de comunicação).
  TagReading degrade(TagQuality q, String msg) =>
      TagReading(value: value, quality: q, message: msg, at: at);
}

/// Ponto de amostragem do gráfico de tendência.
class TrendSample {
  const TrendSample(this.at, this.value);
  final DateTime at;
  final double value;
}

/// Todas as leituras do app, observáveis por variável.
///
/// Cada variável tem o seu [ValueNotifier]: quando a "Velocidade" muda, só os
/// elementos ligados a ela se redesenham — não a tela inteira.
///
/// Também guarda um histórico curto (até [trendWindow]) das variáveis
/// numéricas, para o gráfico de tendência abrir já com a curva dos últimos
/// minutos em vez de começar vazio.
class TagStore {
  TagStore({this.trendWindow = const Duration(minutes: 10), this.maxSamples = 1200});

  final Duration trendWindow;
  final int maxSamples;

  final Map<String, ValueNotifier<TagReading>> _readings = {};
  final Map<String, List<TrendSample>> _history = {};
  final ValueNotifier<int> _historyRevision = ValueNotifier(0);

  ValueListenable<TagReading> watch(String tagId) =>
      _readings.putIfAbsent(tagId, () => ValueNotifier(TagReading.waiting));

  TagReading read(String tagId) => _readings[tagId]?.value ?? TagReading.waiting;

  /// Muda a cada amostra nova de qualquer variável — o gráfico ouve isto.
  ValueListenable<int> get historyRevision => _historyRevision;

  List<TrendSample> history(String tagId) => _history[tagId] ?? const [];

  bool _disposed = false;

  void publish(String tagId, TagReading reading) {
    // Uma leitura que estava em voo quando o app fechou chega depois do
    // descarte — ignora em vez de mexer em notificador já destruído.
    if (_disposed) return;
    final n = _readings.putIfAbsent(tagId, () => ValueNotifier(reading));
    n.value = reading;
    final v = reading.value;
    if (reading.isGood && (v is num || v is bool)) {
      _record(tagId, v is bool ? (v ? 1.0 : 0.0) : (v as num).toDouble(), reading.at!);
    }
  }

  void _record(String tagId, double value, DateTime at) {
    final list = _history.putIfAbsent(tagId, () => []);
    list.add(TrendSample(at, value));
    final cutoff = at.subtract(trendWindow);
    var drop = 0;
    while (drop < list.length && (list[drop].at.isBefore(cutoff) || list.length - drop > maxSamples)) {
      drop++;
    }
    if (drop > 0) list.removeRange(0, drop);
    _historyRevision.value++;
  }

  /// Apaga estado de variáveis que deixaram de existir.
  void forget(String tagId) {
    _readings.remove(tagId)?.dispose();
    _history.remove(tagId);
  }

  void dispose() {
    _disposed = true;
    for (final n in _readings.values) {
      n.dispose();
    }
    _readings.clear();
    _history.clear();
    _historyRevision.dispose();
  }
}
