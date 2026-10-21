// Tela montada pelo usuário: uma grade com elementos gráficos (e, se o
// usuário quiser, uma imagem de fundo por trás deles — o sinótico).

import 'dart:math' as math;

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

  /// "Fundo transparente" (só vale numa tela com imagem de fundo): sem
  /// cartão, pousado no desenho.
  bool get transparent => props['transparent'] == true;

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

/// Como a imagem de fundo ocupa a tela ([ScreenBackground.fit]).
enum BackgroundFit {
  /// Largura da tela: a imagem inteira na largura da grade, altura pela
  /// proporção dela (a grade cresce até caber). O padrão.
  width,

  /// Tela inteira: cobre a área de [ScreenBackground.rows] linhas, cortando
  /// o que sobra.
  cover,

  /// Caber sem cortar: a imagem inteira dentro da mesma área, com sobra.
  contain,
}

/// Imagem de fundo da tela (item 62 da lista do cliente, "sinótico"): a
/// planta da fábrica, a foto da máquina ou um diagrama, **atrás** da grade e
/// dos elementos.
///
/// Guardada como o elemento imagem: PNG em base64 dentro do arquivo do
/// projeto (exportar leva junto), reduzida antes de entrar
/// ([maxSide], `shrinkImage`). [width] e [height] são os pixels da imagem
/// guardada: com eles a área da imagem sai em células sem decodificar nada —
/// é o que deixa editor e operação desenharem no mesmo lugar.
///
/// Tudo em unidades da grade, nunca da janela: a imagem cresce com a largura
/// como os elementos, então a lâmpada posta sobre a prensa continua sobre a
/// prensa no celular, no tablet e no editor.
class ScreenBackground {
  const ScreenBackground({
    required this.data,
    required this.width,
    required this.height,
    this.fit = BackgroundFit.width,
    this.rows,
    this.dim = 0,
    this.extra = const {},
  });

  /// O mesmo teto das imagens por etapa do elemento imagem (página de PDF,
  /// diagrama): nítido no tablet e ainda leve para mandar por WhatsApp.
  static const int maxSide = 1200;

  /// "Escurecer a imagem" (%), para ler os elementos por cima.
  static const List<int> dimChoices = [0, 30, 60];

  final String data;
  final int width;
  final int height;
  final BackgroundFit fit;

  /// Altura da área em linhas da grade da tela, nos encaixes "tela inteira"
  /// e "caber sem cortar": a tela que o editor mostrava quando o encaixe foi
  /// escolhido. Nulo = a altura da imagem na largura da tela.
  final int? rows;

  /// Quanto atenuar a imagem (0, 30 ou 60 %), na cor de fundo do tema.
  final int dim;

  /// Chaves de uma versão mais nova do app: preservadas ao salvar.
  final Map<String, dynamic> extra;

  /// Linhas da grade de [columns] colunas que a imagem ocupa.
  int areaRows(int columns) {
    final r = rows;
    if (fit != BackgroundFit.width && r != null && r > 0) return r;
    if (width <= 0 || height <= 0) return 0;
    return (columns * height / width - 1e-9).ceil();
  }

  ScreenBackground copyWith({String? data, int? width, int? height, BackgroundFit? fit, int? rows, bool clearRows = false, int? dim}) => ScreenBackground(
        data: data ?? this.data,
        width: width ?? this.width,
        height: height ?? this.height,
        fit: fit ?? this.fit,
        rows: clearRows ? null : rows ?? this.rows,
        dim: dim ?? this.dim,
        extra: extra,
      );

  /// A mesma área numa grade [factor] vezes mais fina (ou mais grossa, com
  /// fator < 1, arredondando para cima: a imagem nunca perde pedaço).
  ScreenBackground scaled(double factor) {
    final r = rows;
    if (r == null) return this;
    return copyWith(rows: math.max(1, (r * factor - 1e-9).ceil()));
  }

  Map<String, dynamic> toJson() => {
        ...extra,
        'data': data,
        'width': width,
        'height': height,
        if (fit != BackgroundFit.width) 'fit': fit.name,
        if (rows != null) 'rows': rows,
        if (dim > 0) 'dim': dim,
      };

  static const _known = {'data', 'width', 'height', 'fit', 'rows', 'dim'};

  /// Nulo quando não há imagem legível (sem `data`).
  static ScreenBackground? fromJson(Object? raw) {
    if (raw is! Map || raw['data'] is! String || (raw['data'] as String).isEmpty) return null;
    final j = Map<String, dynamic>.from(raw);
    return ScreenBackground(
      data: j['data'] as String,
      width: (j['width'] as num?)?.toInt() ?? 0,
      height: (j['height'] as num?)?.toInt() ?? 0,
      fit: BackgroundFit.values.firstWhere((f) => f.name == j['fit'], orElse: () => BackgroundFit.width),
      rows: (j['rows'] as num?)?.toInt(),
      dim: (j['dim'] as num?)?.toInt().clamp(0, 90) ?? 0,
      extra: {for (final k in j.keys) if (!_known.contains(k)) k: j[k]},
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
    this.background,
    this.extra = const {},
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

  /// Imagem de fundo (sinótico), atrás da grade e dos elementos. Campo
  /// opcional: só vai para o arquivo quando existe, e o `schemaVersion`
  /// segue 1. A 1.4.0/1.5.0 não conhece a chave: abre a tela sem desenhar a
  /// imagem (ver docs/ARQUITETURA.md §5.3).
  final ScreenBackground? background;

  /// Chaves da tela que esta versão não conhece (arquivo de versão mais
  /// nova): preservadas ao salvar, como os tipos de elemento desconhecidos.
  final Map<String, dynamic> extra;

  /// Linhas ocupadas pelos elementos (a tela rola se passar da altura do
  /// aparelho).
  int get rows =>
      elements.fold(0, (m, e) => e.bottom > m ? e.bottom : m);

  /// Linhas que a tela desenha: os elementos e a imagem de fundo.
  int get drawnRows => math.max(rows, background?.areaRows(columns) ?? 0);

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
    ScreenBackground? background,
  }) =>
      HmiScreen(
        id: id,
        name: name ?? this.name,
        columns: columns ?? this.columns,
        readOnly: readOnly ?? this.readOnly,
        confirmWrites: confirmWrites ?? this.confirmWrites,
        elements: elements ?? this.elements,
        background: background ?? this.background,
        extra: extra,
      );

  /// A mesma tela com outra imagem de fundo — ou sem nenhuma ([b] nulo).
  HmiScreen withBackground(ScreenBackground? b) => HmiScreen(
        id: id,
        name: name,
        columns: columns,
        readOnly: readOnly,
        confirmWrites: confirmWrites,
        elements: elements,
        background: b,
        // Um fundo ilegível guardado de lado não volta por cima do novo.
        extra: extra.containsKey('background') ? (Map.of(extra)..remove('background')) : extra,
      );

  /// Cópia com outro id e outro nome ("Duplicar"): elementos com ids novos
  /// ([elementId]), a imagem de fundo e o resto vão juntos.
  HmiScreen duplicate({required String id, required String name, required String Function() elementId}) => HmiScreen(
        id: id,
        name: name,
        columns: columns,
        readOnly: readOnly,
        confirmWrites: confirmWrites,
        elements: [
          for (final e in elements) HmiElement(id: elementId(), type: e.type, x: e.x, y: e.y, w: e.w, h: e.h, props: Map.of(e.props)),
        ],
        background: background,
        extra: extra,
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
      ]).withBackground(background?.scaled(k.toDouble()));
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
    ]).withBackground(background?.scaled(0.5));
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
      ]).withBackground(background?.scaled(0.5));

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
        ...extra,
        'id': id,
        'name': name,
        'columns': columns,
        'readOnly': readOnly,
        'confirmWrites': confirmWrites,
        'elements': [for (final e in elements) e.toJson()],
        // Só quando há imagem: tela sem fundo fica igual à da 1.5.0.
        if (background != null) 'background': background!.toJson(),
      };

  static const _known = {'id', 'name', 'columns', 'readOnly', 'confirmWrites', 'elements', 'background'};

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
        background: ScreenBackground.fromJson(j['background']),
        extra: {
          for (final k in j.keys)
            if (!_known.contains(k)) k: j[k],
          // Fundo que esta versão não sabe ler (sem imagem): vai e volta igual.
          if (j['background'] != null && ScreenBackground.fromJson(j['background']) == null) 'background': j['background'],
        },
      );
}
