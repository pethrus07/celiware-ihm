import 'package:flutter/material.dart';

/// Identidade visual — "pegada industrial".
///
/// Segue a filosofia da ISA-101 (IHM de alto desempenho): **fundo neutro, e
/// cor só quando comunica estado**. O operador bate o olho e o que tem cor é
/// o que merece atenção. Por isso a interface é grafite, o destaque de marca
/// é o âmbar de sinalização de segurança, e verde/vermelho/amarelo/azul ficam
/// reservados para estado de processo (ver [StateColor]).
///
/// Um tema só, como pedido na reunião: os elementos variam por **função**,
/// nunca por estilo — não existem "cinco tipos de botão visual".
class Ind {
  Ind._();

  // ── Superfícies ──────────────────────────────────────────────────────────────
  static const bg = Color(0xFF121418);
  static const surface = Color(0xFF1B1F25);
  static const surfaceHigh = Color(0xFF232830);
  static const surfaceHigher = Color(0xFF2D333C);
  static const line = Color(0xFF2A3038);
  static const lineStrong = Color(0xFF3D4550);

  // ── Texto ────────────────────────────────────────────────────────────────────
  static const text = Color(0xFFE9EDF1);
  static const textDim = Color(0xFFA3ADB8);
  static const textMuted = Color(0xFF6B7682);

  // ── Marca ────────────────────────────────────────────────────────────────────
  /// Âmbar de sinalização — ação principal, seleção no editor, foco.
  static const accent = Color(0xFFFFB020);
  static const onAccent = Color(0xFF1A1300);

  // ── Estado de processo ───────────────────────────────────────────────────────
  static const ok = Color(0xFF2FBF71);
  static const alarm = Color(0xFFE5484D);
  static const warn = Color(0xFFF5C518);
  static const info = Color(0xFF3E9BFF);
  static const off = Color(0xFF3A414B);

  // ── Tipografia ───────────────────────────────────────────────────────────────
  static const sans = 'Plex';
  static const condensed = 'PlexCondensed';
  static const mono = 'PlexMono';

  /// Número de processo (valor grande de elemento).
  static TextStyle number(double size, {Color color = text}) => TextStyle(
        fontFamily: mono,
        fontWeight: FontWeight.w600,
        fontSize: size,
        color: color,
        height: 1.0,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// Rótulo de elemento — caixa alta condensada, estilo placa de painel.
  static TextStyle tag({double size = 12, Color color = textDim}) => TextStyle(
        fontFamily: condensed,
        fontWeight: FontWeight.w600,
        fontSize: size,
        letterSpacing: 0.6,
        color: color,
        height: 1.1,
      );

  // ── Medidas ──────────────────────────────────────────────────────────────────
  static const radius = 16.0;
  static const radiusSmall = 12.0;

  /// Espaçamento padrão entre blocos — o respiro da interface. Telas, listas
  /// e formulários usam estes valores, nunca números soltos.
  static const space = 16.0;
  static const spaceSmall = 8.0;
  static const spaceLarge = 28.0;

  /// Margem lateral das páginas.
  static const page = 20.0;

  /// Alvo mínimo de toque (Material/WCAG): 48 dp.
  static const minTouch = 48.0;

  static ThemeData get theme {
    final scheme = const ColorScheme.dark(
      primary: accent,
      onPrimary: onAccent,
      secondary: accent,
      onSecondary: onAccent,
      surface: surface,
      onSurface: text,
      error: alarm,
      onError: Colors.white,
      outline: line,
    ).copyWith(
      surfaceContainerLowest: bg,
      surfaceContainerLow: surface,
      surfaceContainer: surfaceHigh,
      surfaceContainerHigh: surfaceHigh,
      surfaceContainerHighest: surfaceHigher,
      onSurfaceVariant: textDim,
      outlineVariant: line,
    );

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      fontFamily: sans,
      visualDensity: VisualDensity.standard,
    );

    final tt = base.textTheme.apply(bodyColor: Ind.text, displayColor: Ind.text);

    return base.copyWith(
      textTheme: tt.copyWith(
        titleLarge: tt.titleLarge?.copyWith(fontFamily: condensed, fontWeight: FontWeight.w700, letterSpacing: 0.3),
        titleMedium: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        labelLarge: tt.labelLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.2),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        foregroundColor: Ind.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(fontFamily: condensed, fontWeight: FontWeight.w700, fontSize: 22, color: Ind.text, letterSpacing: 0.2),
        titleSpacing: page,
        toolbarHeight: 64,
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: page),
        minVerticalPadding: 14,
        iconColor: textDim,
        subtitleTextStyle: TextStyle(color: textMuted, fontSize: 13),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        indicatorColor: accent.withValues(alpha: 0.18),
        height: 68,
        iconTheme: WidgetStateProperty.resolveWith((s) =>
            IconThemeData(color: s.contains(WidgetState.selected) ? accent : textDim)),
        labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: s.contains(WidgetState.selected) ? accent : textDim)),
      ),
      // Cartão sem borda: a separação vem da diferença de tom com o fundo.
      // Menos linhas na tela = menos ruído visual.
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
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
          foregroundColor: Ind.text,
          side: const BorderSide(color: lineStrong),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSmall)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(minimumSize: const Size(48, minTouch)),
      ),
      // Campo sem contorno em repouso (só o fundo); âmbar ao focar.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceHigh,
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusSmall),
          borderSide: const BorderSide(color: accent, width: 2),
        ),
        labelStyle: const TextStyle(color: textDim),
        helperStyle: const TextStyle(color: textMuted),
        helperMaxLines: 3,
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: surfaceHigh,
        selectedColor: accent.withValues(alpha: 0.2),
        side: const BorderSide(color: line),
        labelStyle: const TextStyle(color: Ind.text, fontWeight: FontWeight.w600),
      ),
      dividerTheme: const DividerThemeData(color: line, space: 1),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surface,
        showDragHandle: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      ),
      // Título das caixas na mesma letra dos títulos de tela (o padrão do
      // Material era uma Plex fina, que destoava do resto).
      dialogTheme: DialogThemeData(
        backgroundColor: surfaceHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
        titleTextStyle: const TextStyle(fontFamily: condensed, fontWeight: FontWeight.w700, fontSize: 24, color: Ind.text, height: 1.2),
        contentTextStyle: const TextStyle(fontFamily: sans, fontSize: 15.5, color: Ind.textDim, height: 1.4),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: surfaceHigher,
        contentTextStyle: const TextStyle(color: Ind.text, fontFamily: sans),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusSmall)),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? onAccent : textDim),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : surfaceHigher),
      ),
    );
  }
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
