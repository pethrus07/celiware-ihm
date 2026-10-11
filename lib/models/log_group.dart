// Registro de dados: um grupo de variáveis gravadas no aparelho de tempos em
// tempos, para ver o histórico em gráfico e exportar para planilha
// (REQUISITOS-ETAPA4 §9.4, RG-1). Mercado: "Data Sampling" da Weintek e "Tag
// History" do Ignition (periódico ou ao mudar, banda morta, máximo entre
// amostras).
//
// O grupo mora no projeto (viaja na exportação); o que ele gravou é do
// aparelho e fica num banco ao lado do projeto — ver ARQUITETURA.md,
// "Registro de dados".

import 'tag.dart';

/// Quando uma linha nova vai para o banco.
enum LogMode {
  /// Uma linha a cada intervalo, mudando ou não.
  periodic,

  /// Uma linha só quando alguma variável muda além da banda morta — ou quando
  /// passa o "máximo entre amostras", para provar que o registro estava vivo
  /// (valor parado não pode parecer app fechado).
  onChange,
}

extension LogModeMeta on LogMode {
  String get label => switch (this) {
        LogMode.periodic => 'Sempre',
        LogMode.onChange => 'Ao mudar',
      };

  static LogMode fromName(String? n) => LogMode.values.firstWhere((m) => m.name == n, orElse: () => LogMode.periodic);
}

/// Um grupo de registro. Imutável.
class LogGroup {
  const LogGroup({
    required this.id,
    this.name = 'Registro',
    this.tagIds = const [],
    this.intervalSec = 1,
    this.mode = LogMode.periodic,
    this.deadband = 0,
    this.maxGapSec = 600,
    this.retentionDays = 7,
    this.enabled = true,
  });

  static const minIntervalSec = 1;
  static const maxIntervalSec = 3600;
  static const maxRetentionDays = 365;

  /// Escolhas da tela (1 s a 1 h; guardar de 1 dia a 1 ano).
  static const intervalChoices = [1, 5, 10, 30, 60, 300, 900, 3600];
  static const retentionChoices = [1, 7, 30, 90, 365];
  static const maxGapChoices = [60, 600, 3600];

  final String id;
  final String name;
  final List<String> tagIds;

  /// De quanto em quanto tempo olhar as variáveis (1 s a 1 h). No modo
  /// [LogMode.onChange] é o ritmo da conferência, não de gravação.
  final int intervalSec;
  final LogMode mode;

  /// Só no modo "ao mudar": mudança menor que isto (na unidade de cada
  /// variável, já com escala) não grava. 0 = qualquer mudança. Liga/desliga
  /// grava sempre que troca.
  final double deadband;

  /// Só no modo "ao mudar": grava ao menos a cada tantos segundos, mesmo
  /// parado. Sem isso, um valor estável por horas ficaria igual a um buraco.
  final int maxGapSec;

  /// O que passar disto é apagado (padrão 7 dias).
  final int retentionDays;
  final bool enabled;

  /// Pode entrar num registro: número ou liga/desliga de valor único. Texto
  /// não vira curva nem conta, e lista ocuparia uma coluna por posição.
  static bool canLog(Tag t) => !t.isText && !t.isArray;

  Duration get interval => Duration(seconds: intervalSec);
  Duration get maxGap => Duration(seconds: maxGapSec);

  /// Maior distância esperada entre duas linhas. Mais que isso no histórico
  /// é buraco (app fechado, registro desligado) e a curva é interrompida em
  /// vez de ligar dois pontos que não se conhecem.
  Duration get gapThreshold {
    if (mode == LogMode.onChange) return maxGap + interval * 2;
    final g = interval * 2.5;
    return g < const Duration(seconds: 3) ? const Duration(seconds: 3) : g;
  }

  LogGroup copyWith({
    String? name,
    List<String>? tagIds,
    int? intervalSec,
    LogMode? mode,
    double? deadband,
    int? maxGapSec,
    int? retentionDays,
    bool? enabled,
  }) =>
      LogGroup(
        id: id,
        name: name ?? this.name,
        tagIds: tagIds ?? this.tagIds,
        intervalSec: intervalSec ?? this.intervalSec,
        mode: mode ?? this.mode,
        deadband: deadband ?? this.deadband,
        maxGapSec: maxGapSec ?? this.maxGapSec,
        retentionDays: retentionDays ?? this.retentionDays,
        enabled: enabled ?? this.enabled,
      );

  /// Corrige valores impossíveis vindos de arquivo editado à mão ou antigo.
  LogGroup normalized() {
    final interval = intervalSec.clamp(minIntervalSec, maxIntervalSec);
    return LogGroup(
      id: id,
      name: name.trim().isEmpty ? 'Registro' : name.trim(),
      tagIds: tagIds.toSet().toList(),
      intervalSec: interval,
      mode: mode,
      deadband: deadband.isFinite && deadband > 0 ? deadband : 0,
      // O máximo entre amostras nunca é menor que o próprio intervalo.
      maxGapSec: maxGapSec < interval ? interval : maxGapSec.clamp(interval, 24 * 3600),
      retentionDays: retentionDays.clamp(1, maxRetentionDays),
      enabled: enabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'tagIds': tagIds,
        'intervalSec': intervalSec,
        'mode': mode.name,
        'deadband': deadband,
        'maxGapSec': maxGapSec,
        'retentionDays': retentionDays,
        'enabled': enabled,
      };

  factory LogGroup.fromJson(Map<String, dynamic> j) => LogGroup(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? 'Registro',
        tagIds: [for (final t in (j['tagIds'] as List? ?? const [])) if (t is String) t],
        intervalSec: (j['intervalSec'] as num?)?.toInt() ?? 1,
        mode: LogModeMeta.fromName(j['mode'] as String?),
        deadband: (j['deadband'] as num?)?.toDouble() ?? 0,
        maxGapSec: (j['maxGapSec'] as num?)?.toInt() ?? 600,
        retentionDays: (j['retentionDays'] as num?)?.toInt() ?? 7,
        enabled: j['enabled'] as bool? ?? true,
      ).normalized();

  // ── Tamanho em disco ─────────────────────────────────────────────────────────

  /// Bytes por dia no banco (tabela larga). Calibrado pela medição de
  /// 11/10/2026 (`docs/pesquisa-etapa4/4-…`, seção 4): 20 variáveis a 1 s =
  /// 15,8 MB/dia ≈ 13 B por linha + 8,5 B por número. Liga/desliga custa ~1 B
  /// (o SQLite guarda 0 e 1 só no cabeçalho da linha).
  static double bytesPerDay({required int numbers, required int bools, required int intervalSec}) =>
      (13 + 8.5 * numbers + 1.0 * bools) * (86400 / intervalSec);

  /// Quanto o histórico ocupa cheio (retenção inteira). No modo "ao mudar" é
  /// o teto: mudou em toda conferência.
  double estimateBytes(List<Tag> tags) {
    final bools = tags.where((t) => t.dataType == TagDataType.bool).length;
    return bytesPerDay(numbers: tags.length - bools, bools: bools, intervalSec: intervalSec) * retentionDays;
  }

  // ── Textos ───────────────────────────────────────────────────────────────────

  /// "1 s", "5 min", "1 h".
  static String durationLabel(int seconds) {
    if (seconds >= 3600 && seconds % 3600 == 0) return '${seconds ~/ 3600} h';
    if (seconds >= 60 && seconds % 60 == 0) return '${seconds ~/ 60} min';
    return '$seconds s';
  }

  /// "1 dia", "7 dias", "1 ano".
  static String daysLabel(int days) => days == 365 ? '1 ano' : days == 1 ? '1 dia' : '$days dias';

  /// "850 kB", "3,2 MB", "1,2 GB" — vírgula brasileira, uma casa só quando ajuda.
  static String sizeLabel(double bytes) {
    String one(double v) => (v >= 10 ? v.round().toString() : v.toStringAsFixed(1)).replaceAll('.', ',');
    if (bytes < 1000 * 1000) return '${(bytes / 1000).ceil()} kB';
    if (bytes < 1000 * 1000 * 1000) return '${one(bytes / 1e6)} MB';
    return '${one(bytes / 1e9)} GB';
  }
}
