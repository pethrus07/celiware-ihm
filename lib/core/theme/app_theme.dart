import 'package:flutter/material.dart';

/// Paleta de um tema. Os dois temas têm **os mesmos nomes** (tokens
/// semânticos): o código pede "cartão", "texto secundário", "alarme" — nunca
/// um hex — e cada tema decide o tom. Base: `docs/PESQUISA-UI-UX.md`.
///
/// Regras que valem para os dois (ISA-101 + pesquisa de linguagem visual):
///   • ~90% da tela neutra; cor só para estado e para interação;
///   • profundidade por luminosidade em camadas, borda de 1 px e brilho no
///     topo — não por sombra pesada, gradiente ou vidro;
///   • a face do instrumento (arco, trilho, poço do LED) é **rebaixada**
///     ([well]), mais funda que o cartão;
///   • cor de estado tem versão de preenchimento e versão de texto: amarelo
///     que serve para preencher uma lâmpada não se lê como texto no claro;
///   • curvas de gráfico usam [series], nunca cores de estado.
class IndPalette {
  const IndPalette({
    required this.name,
    required this.dark,
    required this.well,
    required this.bg,
    required this.surface,
    required this.surfaceHigh,
    required this.surfaceHigher,
    required this.raised,
    required this.line,
    required this.lineStrong,
    required this.border,
    required this.edge,
    required this.text,
    required this.textDim,
    required this.textMuted,
    required this.accent,
    required this.onAccent,
    required this.ok,
    required this.okText,
    required this.alarm,
    required this.alarmText,
    required this.warn,
    required this.warnText,
    required this.info,
    required this.infoText,
    required this.off,
    required this.lampOn,
    required this.cardShadow,
    required this.raisedShadow,
    required this.series,
  });

  final String name;
  final bool dark;

  /// Face rebaixada de instrumento: fundo do arco, trilho da barra, poço da lâmpada.
  final Color well;

  /// Fundo da tela.
  final Color bg;

  /// Cartão.
  final Color surface;

  /// Controle sobre o cartão (campo, botão secundário).
  final Color surfaceHigh;

  /// Pressionado / selecionado.
  final Color surfaceHigher;

  /// Folha, diálogo, menu.
  final Color raised;

  final Color line;
  final Color lineStrong;

  /// Borda de 1 px do cartão (quase invisível: separa sem pesar).
  final Color border;

  /// Brilho no topo do cartão — "luz vindo de cima".
  final Color edge;

  final Color text;
  final Color textDim;

  /// Unidade, eixo, rótulo curto. Nunca texto corrido.
  final Color textMuted;

  /// Interação: ação principal, seleção, foco. Verde-água — longe do
  /// amarelo/laranja de alarme (a pesquisa mostrou o âmbar antigo colidindo
  /// com "alarme de prioridade alta").
  final Color accent;
  final Color onAccent;

  final Color ok, okText;
  final Color alarm, alarmText;
  final Color warn, warnText;
  final Color info, infoText;

  /// Desligado / inativo.
  final Color off;

  /// "Ligado" no estilo alto desempenho (ISA-101): brilho, não cor.
  final Color lampOn;

  final List<BoxShadow> cardShadow;
  final List<BoxShadow> raisedShadow;

  /// Curvas e barras de gráfico, na ordem de uso.
  final List<Color> series;

  // ── Escuro: sala de controle, noite, ambiente fechado ─────────────────────
  static const escuro = IndPalette(
    name: 'escuro',
    dark: true,
    well: Color(0xFF0A0C0F),
    bg: Color(0xFF0E1014),
    surface: Color(0xFF171A1F),
    surfaceHigh: Color(0xFF20242B),
    surfaceHigher: Color(0xFF2A2F37),
    raised: Color(0xFF1C2026),
    line: Color(0xFF262A31),
    lineStrong: Color(0xFF3A4049),
    border: Color(0x10FFFFFF),
    edge: Color(0x1FFFFFFF),
    text: Color(0xFFE8EAED),
    textDim: Color(0xFFA1A7B0),
    textMuted: Color(0xFF7C838E),
    accent: Color(0xFF2EC4D0),
    onAccent: Color(0xFF03181A),
    ok: Color(0xFF2FBF71),
    okText: Color(0xFF6CD99A),
    alarm: Color(0xFFF2555A),
    alarmText: Color(0xFFFF8A8D),
    warn: Color(0xFFF5C518),
    warnText: Color(0xFFF7D154),
    info: Color(0xFF4C9EFF),
    infoText: Color(0xFF8CC0FF),
    off: Color(0xFF3A4049),
    lampOn: Color(0xFFF2F4F7),
    cardShadow: [
      BoxShadow(color: Color(0x73000000), blurRadius: 2, offset: Offset(0, 1)),
      BoxShadow(color: Color(0x4D000000), blurRadius: 24, offset: Offset(0, 8)),
    ],
    raisedShadow: [BoxShadow(color: Color(0x80000000), blurRadius: 48, offset: Offset(0, 16))],
    series: [Color(0xFF78A9FF), Color(0xFFA56EFF), Color(0xFFFF7EB6)],
  );

  // ── Claro "campo": chão de fábrica, dia, sol ───────────────────────────────
  // Cinza de sala de controle moderna (Rockwell PlantPAx usa #E0E0E0 de
  // fundo); cartão mais claro que o fundo, texto quase preto (polaridade
  // positiva — o reflexo aparece menos, FAA HFDS §5.3.8).
  static const claro = IndPalette(
    name: 'claro',
    dark: false,
    well: Color(0xFFDADDE2),
    bg: Color(0xFFE4E6EA),
    surface: Color(0xFFF7F8FA),
    surfaceHigh: Color(0xFFEBEDF0),
    surfaceHigher: Color(0xFFDDE0E5),
    raised: Color(0xFFFFFFFF),
    line: Color(0xFFD5D9DF),
    lineStrong: Color(0xFFB3BAC3),
    border: Color(0x14101828),
    edge: Color(0xCCFFFFFF),
    text: Color(0xFF1B1F24),
    textDim: Color(0xFF474E58),
    textMuted: Color(0xFF69717C),
    accent: Color(0xFF00808C),
    onAccent: Color(0xFFFFFFFF),
    ok: Color(0xFF1F9D57),
    okText: Color(0xFF137A41),
    alarm: Color(0xFFD9363C),
    alarmText: Color(0xFFB8262C),
    warn: Color(0xFFF2B705),
    warnText: Color(0xFF8A6400),
    info: Color(0xFF2F7FE0),
    infoText: Color(0xFF1C62B8),
    off: Color(0xFFC4C9D0),
    // No claro, "aceso" = núcleo escuro de alto contraste: branco sobre
    // cartão branco sumiria. Princípio igual ao do escuro — ligado contrasta
    // com o fundo, desligado é o poço vazio.
    lampOn: Color(0xFF2A3038),
    cardShadow: [
      BoxShadow(color: Color(0x14101828), blurRadius: 2, offset: Offset(0, 1)),
      BoxShadow(color: Color(0x0F101828), blurRadius: 14, offset: Offset(0, 5)),
    ],
    raisedShadow: [BoxShadow(color: Color(0x29101828), blurRadius: 40, offset: Offset(0, 14))],
    series: [Color(0xFF2F6FE0), Color(0xFF8A4FE0), Color(0xFFD9468C)],
  );
}

/// Preferência de aparência guardada no aparelho.
enum Appearance { auto, claro, escuro }

/// Identidade visual — "pegada industrial" (ver [IndPalette]).
///
/// Os nomes de cor são **getters** da paleta em uso: trocar de tema troca o
/// tom em todo o app (a raiz reconstrói a árvore; pintores de gráfico olham
/// [revision] no `shouldRepaint`).
class Ind {
  Ind._();

  static IndPalette palette = IndPalette.escuro;

  /// Sobe a cada troca de paleta — pintores comparam para redesenhar.
  static int revision = 0;

  static void use(IndPalette p) {
    if (identical(p, palette)) return;
    palette = p;
    revision++;
  }

  static bool get isDark => palette.dark;

  // ── Superfícies ──────────────────────────────────────────────────────────────
  static Color get well => palette.well;
  static Color get bg => palette.bg;
  static Color get surface => palette.surface;
  static Color get surfaceHigh => palette.surfaceHigh;
  static Color get surfaceHigher => palette.surfaceHigher;
  static Color get raised => palette.raised;
  static Color get line => palette.line;
  static Color get lineStrong => palette.lineStrong;
  static Color get border => palette.border;
  static Color get edge => palette.edge;
  static List<BoxShadow> get cardShadow => palette.cardShadow;
  static List<BoxShadow> get raisedShadow => palette.raisedShadow;

  // ── Texto ────────────────────────────────────────────────────────────────────
  static Color get text => palette.text;
  static Color get textDim => palette.textDim;
  static Color get textMuted => palette.textMuted;

  // ── Interação ────────────────────────────────────────────────────────────────
  static Color get accent => palette.accent;
  static Color get onAccent => palette.onAccent;

  // ── Estado de processo ───────────────────────────────────────────────────────
  static Color get ok => palette.ok;
  static Color get alarm => palette.alarm;
  static Color get warn => palette.warn;
  static Color get info => palette.info;
  static Color get off => palette.off;
  static Color get lampOn => palette.lampOn;
  static List<Color> get series => palette.series;

  /// Versão legível como texto de uma cor de estado (no claro, o amarelo de
  /// preenchimento não se lê; no escuro, o vermelho puro fica escuro demais).
  static Color textFor(Color state) {
    final p = palette;
    if (state == p.ok) return p.okText;
    if (state == p.alarm) return p.alarmText;
    if (state == p.warn) return p.warnText;
    if (state == p.info) return p.infoText;
    return state;
  }

  // ── Tipografia ───────────────────────────────────────────────────────────────
  static const sans = 'Plex';
  static const condensed = 'PlexCondensed';
  static const mono = 'PlexMono';

  /// Número de processo: Plex Condensed SemiBold com dígitos de largura
  /// fixa (tabulares) — o valor não "dança" quando muda, e a condensada põe
  /// mais dígito na mesma largura que a mono (pesquisa de linguagem visual).
  static TextStyle number(double size, {Color? color}) => TextStyle(
        fontFamily: condensed,
        fontWeight: FontWeight.w600,
        fontSize: size,
        color: color ?? text,
        height: 1.0,
        letterSpacing: -0.02 * size,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// Rótulo de elemento — caixa alta, estilo placa de painel.
  static TextStyle tag({double size = 12, Color? color}) => TextStyle(
        fontFamily: sans,
        fontWeight: FontWeight.w600,
        fontSize: size,
        letterSpacing: 0.06 * size,
        color: color ?? textDim,
        height: 1.1,
      );

  // ── Medidas ──────────────────────────────────────────────────────────────────
  static const radius = 16.0;
  static const radiusSmall = 12.0;

  /// Raio de peça interna (poço, trilho) — concêntrico com o cartão.
  static const radiusInner = 10.0;

  /// Espaçamento padrão entre blocos — o respiro da interface. Telas, listas
  /// e formulários usam estes valores, nunca números soltos.
  static const space = 16.0;
  static const spaceSmall = 8.0;
  static const spaceLarge = 28.0;

  /// Margem lateral das páginas.
  static const page = 20.0;

  /// Alvo mínimo de toque (Material/WCAG): 48 dp.
  static const minTouch = 48.0;

  /// Decoração de cartão: cor da camada, borda de 1 px quase invisível e
  /// sombra em duas camadas. O brilho do topo é pintado por [CardEdge].
  static BoxDecoration card({Color? color, Color? border, double width = 1, double radius = Ind.radius, bool shadow = true}) =>
      BoxDecoration(
        color: color ?? surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: border ?? palette.border, width: width),
        boxShadow: shadow ? cardShadow : null,
      );

  /// Face rebaixada (poço): mais funda que o cartão.
  static BoxDecoration wellBox({double radius = Ind.radiusInner}) => BoxDecoration(
        color: well,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: palette.dark ? const Color(0x0AFFFFFF) : const Color(0x0D101828)),
      );

  static ThemeData get theme {
    final p = palette;
    final base0 = p.dark ? const ColorScheme.dark() : const ColorScheme.light();
    final scheme = base0.copyWith(
      primary: p.accent,
      onPrimary: p.onAccent,
      secondary: p.accent,
      onSecondary: p.onAccent,
      surface: p.surface,
      onSurface: p.text,
      error: p.alarm,
      onError: Colors.white,
      outline: p.line,
      surfaceContainerLowest: p.bg,
      surfaceContainerLow: p.surface,
      surfaceContainer: p.surfaceHigh,
      surfaceContainerHigh: p.surfaceHigh,
      surfaceContainerHighest: p.surfaceHigher,
      onSurfaceVariant: p.textDim,
      outlineVariant: p.line,
      // Sem isto o Material usa o roxo padrão nos "containers" (o botão
      // flutuante "Nova tela" saía roxo no tema claro).
      primaryContainer: p.accent,
      onPrimaryContainer: p.onAccent,
      secondaryContainer: p.accent.withValues(alpha: 0.18),
      onSecondaryContainer: p.text,
      tertiary: p.accent,
      onTertiary: p.onAccent,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: p.dark ? Brightness.dark : Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: p.bg,
      fontFamily: sans,
      visualDensity: VisualDensity.standard,
    );

    final tt = base.textTheme.apply(bodyColor: p.text, displayColor: p.text);

    return base.copyWith(
      textTheme: tt.copyWith(
        titleLarge: tt.titleLarge?.copyWith(fontFamily: condensed, fontWeight: FontWeight.w700, letterSpacing: 0.3),
        titleMedium: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        labelLarge: tt.labelLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.2),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: p.bg,
        foregroundColor: p.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(fontFamily: condensed, fontWeight: FontWeight.w700, fontSize: 22, color: p.text, letterSpacing: 0.2),
        titleSpacing: page,
        toolbarHeight: 64,
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: page),
        minVerticalPadding: 14,
        iconColor: p.textDim,
        subtitleTextStyle: TextStyle(color: p.textMuted, fontSize: 13),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.surface,
        indicatorColor: p.accent.withValues(alpha: p.dark ? 0.18 : 0.14),
        height: 68,
        iconTheme: WidgetStateProperty.resolveWith((s) =>
            IconThemeData(color: s.contains(WidgetState.selected) ? p.accent : p.textDim)),
        labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: s.contains(WidgetState.selected) ? p.accent : p.textDim)),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        elevation: 2,
        highlightElevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
      ),
      cardTheme: CardThemeData(
        color: p.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius), side: BorderSide(color: p.border)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 52),
          padding: const EdgeInsets.symmetric(horizontal: 22),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSmall)),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, minTouch),
          foregroundColor: p.text,
          side: BorderSide(color: p.lineStrong),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSmall)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(minimumSize: const Size(48, minTouch)),
      ),
      // Campo sem contorno em repouso (só o fundo); cor de interação ao focar.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surfaceHigh,
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(radiusSmall), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radiusSmall), borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
          borderSide: BorderSide(color: p.accent, width: 2),
        ),
        labelStyle: TextStyle(color: p.textDim),
        helperStyle: TextStyle(color: p.textMuted),
        helperMaxLines: 3,
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: p.surfaceHigh,
        selectedColor: p.accent.withValues(alpha: 0.2),
        side: BorderSide(color: p.line),
        labelStyle: TextStyle(color: p.text, fontWeight: FontWeight.w600),
      ),
      dividerTheme: DividerThemeData(color: p.line, space: 1),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.raised,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      ),
      // Título das caixas na mesma letra dos títulos de tela.
      dialogTheme: DialogThemeData(
        backgroundColor: p.raised,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
        titleTextStyle: TextStyle(fontFamily: condensed, fontWeight: FontWeight.w700, fontSize: 24, color: p.text, height: 1.2),
        contentTextStyle: TextStyle(fontFamily: sans, fontSize: 15.5, color: p.textDim, height: 1.4),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: p.dark ? p.surfaceHigher : const Color(0xFF2A2F37),
        contentTextStyle: TextStyle(color: p.dark ? p.text : Colors.white, fontFamily: sans),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSmall)),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.onAccent : p.textDim),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accent : p.surfaceHigher),
      ),
    );
  }
}

/// Brilho de 1 px no topo do cartão: a borda superior acende e some até
/// ~40% da altura — "luz vindo de cima". Dá relevo sem gradiente no cartão
/// nem sombra pesada (que não aparece em fundo escuro).
class CardEdge extends CustomPainter {
  const CardEdge({this.radius = Ind.radius, this.color, this.rev = 0});
  final double radius;
  final Color? color;
  final int rev;

  @override
  void paint(Canvas canvas, Size size) {
    final c = color ?? Ind.edge;
    final r = RRect.fromRectAndRadius((Offset.zero & size).deflate(0.5), Radius.circular(radius));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [c, c.withValues(alpha: 0)],
        stops: const [0, 0.4],
      ).createShader(Offset.zero & size);
    canvas.drawRRect(r, paint);
  }

  @override
  bool shouldRepaint(CardEdge old) => old.radius != radius || old.color != color || old.rev != rev;
}

/// Paleta de estado que o usuário escolhe nos elementos (lâmpada acesa,
/// botão ligado, faixa do indicador de estado). Salva no projeto pelo
/// **nome**, então o tom exato pode ser ajustado aqui sem quebrar arquivos.
enum StateColor { green, red, amber, blue, neutral }

extension StateColorMeta on StateColor {
  Color get color {
    switch (this) {
      case StateColor.green:
        return Ind.ok;
      case StateColor.red:
        return Ind.alarm;
      case StateColor.amber:
        return Ind.warn;
      case StateColor.blue:
        return Ind.info;
      case StateColor.neutral:
        return Ind.textDim;
    }
  }

  /// Versão para texto (ver [Ind.textFor]).
  Color get textColor => Ind.textFor(color);

  String get label {
    switch (this) {
      case StateColor.green:
        return 'Verde (normal / ligado)';
      case StateColor.red:
        return 'Vermelho (alarme / parada)';
      case StateColor.amber:
        return 'Amarelo (atenção)';
      case StateColor.blue:
        return 'Azul (informação)';
      case StateColor.neutral:
        return 'Cinza (neutro)';
    }
  }

  static StateColor fromName(String? n, [StateColor fallback = StateColor.green]) =>
      StateColor.values.firstWhere((c) => c.name == n, orElse: () => fallback);
}
