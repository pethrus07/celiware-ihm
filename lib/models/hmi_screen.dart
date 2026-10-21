// Tela montada pelo usuário: uma grade com elementos gráficos.

/// Tipos de elemento — o conjunto "principal do mercado" das IHMs.
///
/// Para acrescentar um tipo: valor novo **no fim** + entrada no
/// [ElementCatalog] (a ordem da paleta é a de lá) + um renderizador em
/// `widgets/hmi/`. Tipos desconhecidos num arquivo (versão mais nova do app)
/// são preservados como [ElementType.unknown] em vez de apagados.
enum ElementType {
  button,
  lamp,
  value,
  input,
  multistate,
  bar,
  gauge,
  trend,
  barChart,
  label,
  image,
  unknown,

  /// Tabela de valores (GR-7): várias variáveis, uma por linha.
  table,

  /// OEE (item 8 da lista do cliente): OEE, disponibilidade, desempenho e
  /// qualidade em quatro mostradores.
  oee,
}

extension ElementTypeMeta on ElementType {
  static ElementType fromName(String? n) => ElementType.values
      .firstWhere((t) => t.name == n, orElse: () => ElementType.unknown);
}

/// Um elemento posicionado na grade.
///
/// Posição e tamanho em **células** da grade da tela ([HmiScreen.columns]
/// colunas; linhas crescem para baixo). Células são quadradas e escalam com a
/// largura do aparelho, então a mesma tela fica proporcional num celular e num
/// tablet.
///
/// [props] guarda a configuração específica do tipo (variável ligada, texto,
/// cores, limites...). As chaves de cada tipo estão documentadas no
/// [ElementCatalog] — é o único lugar que interpreta o mapa.
class HmiElement {
  const HmiElement({
    required this.id,
    required this.type,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.props = const {},
  });

  final String id;
  final ElementType type;
  final int x;
  final int y;
  final int w;
  final int h;
  final Map<String, dynamic> props;

  /// Leitura tipada de uma propriedade com valor padrão.
  T prop<T>(String key, T fallback) {
    final v = props[key];
    if (v is T) return v;
    if (T == double && v is int) return v.toDouble() as T;
    return fallback;
  }

  /// Variável principal ligada ao elemento (quase todos têm uma).
  String? get tagId => props['tagId'] as String?;

  /// Todas as variáveis que o elemento precisa ler.
  Iterable<String> get tagIds sync* {
    final main = props['tagId'];
    if (main is String) yield main;
    // Retorno do botão: a memória que confirma o comando.
    final feedback = props['feedbackTagId'];
    if (feedback is String) yield feedback;
    final many = props['tagIds'];
    if (many is List) yield* many.whereType<String>();
  }

  int get right => x + w;
  int get bottom => y + h;

  bool overlaps(HmiElement o) =>
      x < o.right && o.x < right && y < o.bottom && o.y < bottom;

  HmiElement copyWith({int? x, int? y, int? w, int? h, Map<String, dynamic>? props}) =>
      HmiElement(
        id: id,
        type: type,
        x: x ?? this.x,
        y: y ?? this.y,
        w: w ?? this.w,
        h: h ?? this.h,
        props: props ?? this.props,
      );

  /// Cópia com uma propriedade alterada (ou removida, se [value] for nulo).
  HmiElement withProp(String key, Object? value) {
    final next = Map<String, dynamic>.of(props);
    if (value == null) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    return copyWith(props: next);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type == ElementType.unknown
            ? (props['_originalType'] ?? 'unknown')
            : type.name,
        'x': x,
        'y': y,
        'w': w,
        'h': h,
        'props': props,
      };

  factory HmiElement.fromJson(Map<String, dynamic> j) {
    final type = ElementTypeMeta.fromName(j['type'] as String?);
    final props = Map<String, dynamic>.from((j['props'] as Map?) ?? const {});
    if (type == ElementType.unknown) props['_originalType'] = j['type'];
    return HmiElement(
      id: j['id'] as String,
      type: type,
      x: (j['x'] as int?) ?? 0,
      y: (j['y'] as int?) ?? 0,
      w: (j['w'] as int?) ?? 2,
      h: (j['h'] as int?) ?? 1,
      props: props,
    );
  }
}

/// Uma tela nomeada.
class HmiScreen {
  const HmiScreen({
    required this.id,
    required this.name,
    this.columns = defaultColumns,
    this.readOnly = false,
    this.confirmWrites = true,
    this.elements = const [],
  });

  /// 6 colunas: num celular de 390 dp dá células de ~60 dp — acima do mínimo
  /// de toque de 48 dp mesmo no menor elemento (1×1).
  static const int defaultColumns = 6;

  /// Grade fina: cada célula da normal vira 2×2 (mais variáveis por tela e
  /// encaixe mais preciso). Ver [withColumns].
  static const int fineColumns = 12;

  /// Grade extra-fina (pedido do cliente, 21/10/2026): cada célula da fina
  /// vira 2×2, para encaixar elementos com precisão — por exemplo junto do
  /// desenho de um sinótico. A célula fica com ~14 dp no celular, abaixo de
  /// um alvo de toque: por isso o elemento não encolhe (o mínimo é o da fina,
  /// em dobro) e o passo de uma célula vem das setas do editor, não do dedo.
  static const int extraFineColumns = 24;

  /// As três grades, da mais grossa para a mais fina.
  static const List<int> levels = [defaultColumns, fineColumns, extraFineColumns];

  /// Quantas células desta grade cabem numa normal, por lado (1, 2 ou 4).
  static int scaleOf(int columns) => columns >= extraFineColumns ? 4 : columns >= fineColumns ? 2 : 1;

  /// Fina **ou** extra-fina.
  bool get fine => columns >= fineColumns;

  bool get extraFine => columns >= extraFineColumns;

  final String id;
  final String name;
  final int columns;

  /// Tela só de acompanhamento: nenhum elemento escreve no equipamento.
  final bool readOnly;

  /// Pedir confirmação antes de cada escrita (padrão ligado — segurança).
  final bool confirmWrites;

  final List<HmiElement> elements;

  /// Linhas ocupadas (a tela rola se passar da altura do aparelho).
  int get rows =>
      elements.fold(0, (m, e) => e.bottom > m ? e.bottom : m);

  /// Todas as variáveis que a tela usa (equipamentos da faixa, "usada em").
  Set<String> get tagIds => {for (final e in elements) ...e.tagIds};

  /// O que a tela inscreve de uma vez no runtime — é isso que liga a
  /// varredura. A tabela de valores fica de fora: ela mesma inscreve só as
  /// linhas montadas, e uma tabela de 30 que rola lê o que está à vista.
  Set<String> get liveTagIds => {
        for (final e in elements)
          if (e.type != ElementType.table) ...e.tagIds,
      };

  HmiScreen copyWith({
    String? name,
    int? columns,
    bool? readOnly,
    bool? confirmWrites,
    List<HmiElement>? elements,
  }) =>
      HmiScreen(
        id: id,
        name: name ?? this.name,
        columns: columns ?? this.columns,
        readOnly: readOnly ?? this.readOnly,
        confirmWrites: confirmWrites ?? this.confirmWrites,
        elements: elements ?? this.elements,
      );

  /// A mesma tela em outra grade.
  ///
  /// Para uma grade mais fina, **sem mover nada na tela**: posição e tamanho
  /// multiplicam por 2 (6 → 12, 12 → 24) ou por 4 (6 → 24).
  ///
  /// Para uma mais grossa, um degrau de cada vez:
  ///   • 24 → 12 **arredonda as bordas** ([_halfEdge]): o elemento em meia
  ///     célula da fina anda meia célula. Bordas que se encostavam arredondam
  ///     para o mesmo lugar, então nada passa a sobrepor, nada sai da grade e
  ///     o mínimo da fina continua valendo (o da extra-fina é sempre par);
  ///   • 12 → 6 só se todos forem pares — senão devolve nulo (o mínimo de uma
  ///     linha da fina é uma célula, que arredondada podia sumir).
  /// 24 → 6 passa pela fina e dá nulo se a fina arredondada não for toda par.
  /// Grade fora das três (arquivo de versão mais nova) também dá nulo.
  HmiScreen? withColumns(int target) {
    if (target == columns) return this;
    if (!levels.contains(columns) || !levels.contains(target)) return null;
    if (target > columns) {
      final k = target ~/ columns;
      return copyWith(columns: target, elements: [
        for (final e in elements) e.copyWith(x: e.x * k, y: e.y * k, w: e.w * k, h: e.h * k),
      ]);
    }
    if (columns == extraFineColumns) {
      final half = _halved;
      if (half.elements.any(_collapsed)) return null;
      return target == fineColumns ? half : half.withColumns(target);
    }
    // 12 → 6.
    if (elements.any((e) => e.x.isOdd || e.y.isOdd || e.w.isOdd || e.h.isOdd)) return null;
    return copyWith(columns: target, elements: [
      for (final e in elements) e.copyWith(x: e.x ~/ 2, y: e.y ~/ 2, w: e.w ~/ 2, h: e.h ~/ 2),
    ]);
  }

  /// Borda da extra-fina na fina: a metade, arredondando meia célula para
  /// cima. É crescente e `f(v + 2) = f(v) + 1` — é isso que garante que
  /// vizinhos não se sobreponham e que largura par chegue exata.
  static int _halfEdge(int v) => (v + 1) ~/ 2;

  /// A extra-fina arredondada para a fina, sem conferir nada.
  HmiScreen get _halved => copyWith(columns: fineColumns, elements: [
        for (final e in elements)
          e.copyWith(
            x: _halfEdge(e.x),
            y: _halfEdge(e.y),
            w: _halfEdge(e.right) - _halfEdge(e.x),
            h: _halfEdge(e.bottom) - _halfEdge(e.y),
          ),
      ]);

  /// Sumiu no arredondamento. Pelo editor não acontece (o mínimo da
  /// extra-fina é de duas células); só um elemento de uma célula — vindo de
  /// um app antigo, que não conhece a extra-fina — chega aqui.
  static bool _collapsed(HmiElement e) => e.w < 1 || e.h < 1;

  /// Elementos em meia célula da grade de cima: na fina, os que impedem
  /// voltar para a normal; na extra-fina, os que andam meia célula ao voltar
  /// para a fina.
  int get oddElements => elements.where((e) => e.x.isOdd || e.y.isOdd || e.w.isOdd || e.h.isOdd).length;

  /// Quantos elementos impedem ir para [target] (0 = dá para ir).
  int blockersFor(int target) {
    if (withColumns(target) != null) return 0;
    if (columns == extraFineColumns) {
      final half = _halved;
      final collapsed = half.elements.where(_collapsed).length;
      return collapsed > 0 || target == fineColumns ? collapsed : half.oddElements;
    }
    return oddElements;
  }
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'columns': columns,
        'readOnly': readOnly,
        'confirmWrites': confirmWrites,
        'elements': [for (final e in elements) e.toJson()],
      };

  factory HmiScreen.fromJson(Map<String, dynamic> j) => HmiScreen(
        id: j['id'] as String,
        name: j['name'] as String,
        columns: (j['columns'] as int?) ?? defaultColumns,
        readOnly: (j['readOnly'] as bool?) ?? false,
        confirmWrites: (j['confirmWrites'] as bool?) ?? true,
        elements: [
          for (final e in (j['elements'] as List? ?? const []))
            HmiElement.fromJson(Map<String, dynamic>.from(e as Map)),
        ],
      );
}
