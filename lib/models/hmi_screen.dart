// Tela montada pelo usuário: uma grade com elementos gráficos.

/// Tipos de elemento — o conjunto "principal do mercado" das IHMs.
///
/// A ordem aqui é a ordem da paleta no editor. Para acrescentar um tipo:
/// valor novo aqui + entrada no [ElementCatalog] + um renderizador em
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

  /// Todas as variáveis que a tela precisa ler — é isso que liga a varredura.
  Set<String> get tagIds => {for (final e in elements) ...e.tagIds};

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
