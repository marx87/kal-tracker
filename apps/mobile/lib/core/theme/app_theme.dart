import 'package:flutter/material.dart';

/// The shared food-and-wellness palette for Coach360.
///
/// Colors are public so small presentation widgets can stay visually
/// consistent without duplicating magic values.
abstract final class AppPalette {
  // --- Toni di giorno ---------------------------------------------------
  static const forest = Color(0xFF245B45);
  static const forestDark = Color(0xFF173D2F);
  static const leaf = Color(0xFF4E8C68);
  static const cream = Color(0xFFFBF7ED);
  static const paper = Color(0xFFFFFDF8);
  static const ink = Color(0xFF21322B);
  static const mutedInk = Color(0xFF65726C);
  static const outline = Color(0xFFE5E0D4);

  static const mint = Color(0xFFDCEBDD);
  static const mintSoft = Color(0xFFF0F6EE);
  static const coral = Color(0xFFE86F5B);
  static const coralSoft = Color(0xFFFFE5DF);
  static const yellow = Color(0xFFE3B63F);
  static const yellowSoft = Color(0xFFFFF1C7);
  static const lilac = Color(0xFF8875B8);
  static const lilacSoft = Color(0xFFECE5F8);

  /// Versioni «inchiostro» degli accenti: su fondo tenue il colore pieno
  /// non arriva mai a 4.5:1, quindi testo e icone usano queste, non
  /// `coral`/`yellow`/`lilac`, che restano decorativi.
  static const coralInk = Color(0xFFA83A26);
  static const amberInk = Color(0xFF8A5B08);
  static const lilacInk = Color(0xFF5E4A94);

  static const creamShade = Color(0xFFF6F1E5);
  static const creamShadeStrong = Color(0xFFEBE5D6);

  // --- Toni di notte ----------------------------------------------------
  // Non sono l'inverso meccanico dei chiari. Lo sfondo resta un verde bosco
  // quasi nero (non un grigio neutro) e l'inchiostro conserva la temperatura
  // calda della crema: di notte deve essere la stessa app, non un'altra.
  static const nightCanvas = Color(0xFF101613);
  static const nightPaper = Color(0xFF1E2723);
  static const nightPaperHigh = Color(0xFF253029);
  static const nightPaperHighest = Color(0xFF2C3831);
  static const nightSunken = Color(0xFF0B100E);
  static const nightOutline = Color(0xFF333D38);
  static const nightInk = Color(0xFFE8E3D6);
  static const nightMutedInk = Color(0xFF9AA69F);

  /// Il verde bosco pieno su fondo scuro sparisce: di notte il primario è
  /// una foglia schiarita, e i «container» diventano le versioni profonde
  /// degli stessi accenti.
  static const leafLight = Color(0xFF78BE95);
  static const forestDeep = Color(0xFF0B2117);
  static const mintShade = Color(0xFF1F4535);
  static const mintOnShade = Color(0xFFBFE3CC);
  static const coralLight = Color(0xFFF08C79);
  static const coralShade = Color(0xFF54241B);
  static const coralOnShade = Color(0xFFFFD9D1);
  static const yellowLight = Color(0xFFE8C56A);
  static const yellowShade = Color(0xFF41340F);
  static const lilacLight = Color(0xFFB3A2E0);
  static const lilacShade = Color(0xFF3A2F5C);
  static const lilacOnShade = Color(0xFFE4DBF7);
}

/// Colori *di ruolo* che il `ColorScheme` di Material non ha: il grigio dei
/// testi secondari e le quattro coppie semantiche buono / attenzione /
/// critico / informativo, ciascuna con il proprio fondo tenue.
///
/// Sta qui e non nei singoli widget perché il tema scuro deve poterli
/// riscrivere in un posto solo: chi disegna una schermata chiede
/// `AppAccents.of(context)` e non sa se è giorno o notte.
@immutable
final class AppAccents extends ThemeExtension<AppAccents> {
  const AppAccents({
    required this.mutedInk,
    required this.positive,
    required this.positiveSurface,
    required this.warning,
    required this.warningSurface,
    required this.critical,
    required this.criticalSurface,
    required this.info,
    required this.infoSurface,
  });

  /// Testo secondario: etichette, didascalie, unità di misura.
  final Color mutedInk;

  final Color positive;
  final Color positiveSurface;
  final Color warning;
  final Color warningSurface;
  final Color critical;
  final Color criticalSurface;
  final Color info;
  final Color infoSurface;

  static const light = AppAccents(
    mutedInk: AppPalette.mutedInk,
    positive: AppPalette.forestDark,
    positiveSurface: AppPalette.mint,
    warning: AppPalette.amberInk,
    warningSurface: AppPalette.yellowSoft,
    critical: AppPalette.coralInk,
    criticalSurface: AppPalette.coralSoft,
    info: AppPalette.lilacInk,
    infoSurface: AppPalette.lilacSoft,
  );

  static const dark = AppAccents(
    mutedInk: AppPalette.nightMutedInk,
    positive: AppPalette.leafLight,
    positiveSurface: AppPalette.mintShade,
    warning: AppPalette.yellowLight,
    warningSurface: AppPalette.yellowShade,
    critical: AppPalette.coralLight,
    criticalSurface: AppPalette.coralShade,
    info: AppPalette.lilacLight,
    infoSurface: AppPalette.lilacShade,
  );

  /// Ripiega sul set chiaro quando il tema non è quello dell'app: i widget
  /// condivisi finiscono spesso dentro un `MaterialApp` spoglio nei test
  /// altrui, e lì devono disegnarsi lo stesso invece di lanciare.
  static AppAccents of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<AppAccents>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  @override
  AppAccents copyWith({
    Color? mutedInk,
    Color? positive,
    Color? positiveSurface,
    Color? warning,
    Color? warningSurface,
    Color? critical,
    Color? criticalSurface,
    Color? info,
    Color? infoSurface,
  }) {
    return AppAccents(
      mutedInk: mutedInk ?? this.mutedInk,
      positive: positive ?? this.positive,
      positiveSurface: positiveSurface ?? this.positiveSurface,
      warning: warning ?? this.warning,
      warningSurface: warningSurface ?? this.warningSurface,
      critical: critical ?? this.critical,
      criticalSurface: criticalSurface ?? this.criticalSurface,
      info: info ?? this.info,
      infoSurface: infoSurface ?? this.infoSurface,
    );
  }

  @override
  AppAccents lerp(covariant AppAccents? other, double t) {
    if (other == null) {
      return this;
    }
    return AppAccents(
      mutedInk: Color.lerp(mutedInk, other.mutedInk, t)!,
      positive: Color.lerp(positive, other.positive, t)!,
      positiveSurface: Color.lerp(positiveSurface, other.positiveSurface, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningSurface: Color.lerp(warningSurface, other.warningSurface, t)!,
      critical: Color.lerp(critical, other.critical, t)!,
      criticalSurface: Color.lerp(criticalSurface, other.criticalSurface, t)!,
      info: Color.lerp(info, other.info, t)!,
      infoSurface: Color.lerp(infoSurface, other.infoSurface, t)!,
    );
  }

  // Confronto per valore: durante l'animazione tra chiaro e scuro il tema
  // viene ricostruito a ogni frame, e senza questo ogni widget che legge gli
  // accenti si ridisegnerebbe anche quando i colori non sono cambiati.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is AppAccents &&
        other.mutedInk == mutedInk &&
        other.positive == positive &&
        other.positiveSurface == positiveSurface &&
        other.warning == warning &&
        other.warningSurface == warningSurface &&
        other.critical == critical &&
        other.criticalSurface == criticalSurface &&
        other.info == info &&
        other.infoSurface == infoSurface;
  }

  @override
  int get hashCode => Object.hash(
    mutedInk,
    positive,
    positiveSurface,
    warning,
    warningSurface,
    critical,
    criticalSurface,
    info,
    infoSurface,
  );
}

abstract final class AppTheme {
  static ThemeData get light {
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: AppPalette.forest,
          brightness: Brightness.light,
          surface: AppPalette.cream,
        ).copyWith(
          primary: AppPalette.forest,
          onPrimary: Colors.white,
          primaryContainer: AppPalette.mint,
          onPrimaryContainer: AppPalette.forestDark,
          secondary: AppPalette.coral,
          onSecondary: Colors.white,
          secondaryContainer: AppPalette.coralSoft,
          onSecondaryContainer: AppPalette.ink,
          tertiary: AppPalette.lilac,
          onTertiary: Colors.white,
          tertiaryContainer: AppPalette.lilacSoft,
          onTertiaryContainer: AppPalette.ink,
          surface: AppPalette.cream,
          onSurface: AppPalette.ink,
          onSurfaceVariant: AppPalette.mutedInk,
          // I livelli di superficie generati dal seme virano al grigio-verde:
          // riscritti a mano restano nella famiglia della crema.
          surfaceContainerLowest: AppPalette.paper,
          surfaceContainerLow: AppPalette.paper,
          surfaceContainer: AppPalette.creamShade,
          surfaceContainerHigh: AppPalette.creamShade,
          surfaceContainerHighest: AppPalette.creamShadeStrong,
          outline: AppPalette.outline,
          outlineVariant: AppPalette.outline,
        );

    return _build(
      colorScheme: colorScheme,
      accents: AppAccents.light,
      cardColor: AppPalette.paper,
      snackBackground: AppPalette.forestDark,
      snackForeground: Colors.white,
      // Il primario è verde bosco quanto il fondo della snackbar: «Annulla»
      // deve schiarirsi, altrimenti sparisce.
      snackAction: AppPalette.mintOnShade,
    );
  }

  /// Tema di notte. Non è l'inverso del chiaro: il verde bosco diventa una
  /// foglia schiarita per restare leggibile, il fondo resta caldo e le card
  /// stanno ~20% sopra lo sfondo così da distinguersi anche senza ombre
  /// (elevation 0 è una scelta di stile, non un dettaglio).
  static ThemeData get dark {
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: AppPalette.forest,
          brightness: Brightness.dark,
          surface: AppPalette.nightCanvas,
        ).copyWith(
          primary: AppPalette.leafLight,
          onPrimary: AppPalette.forestDeep,
          primaryContainer: AppPalette.mintShade,
          onPrimaryContainer: AppPalette.mintOnShade,
          secondary: AppPalette.coralLight,
          onSecondary: AppPalette.coralShade,
          secondaryContainer: AppPalette.coralShade,
          onSecondaryContainer: AppPalette.coralOnShade,
          tertiary: AppPalette.lilacLight,
          onTertiary: AppPalette.lilacShade,
          tertiaryContainer: AppPalette.lilacShade,
          onTertiaryContainer: AppPalette.lilacOnShade,
          surface: AppPalette.nightCanvas,
          onSurface: AppPalette.nightInk,
          onSurfaceVariant: AppPalette.nightMutedInk,
          surfaceContainerLowest: AppPalette.nightSunken,
          surfaceContainerLow: AppPalette.nightPaper,
          surfaceContainer: AppPalette.nightPaper,
          surfaceContainerHigh: AppPalette.nightPaperHigh,
          surfaceContainerHighest: AppPalette.nightPaperHighest,
          outline: AppPalette.nightOutline,
          outlineVariant: AppPalette.nightOutline,
        );

    return _build(
      colorScheme: colorScheme,
      accents: AppAccents.dark,
      cardColor: AppPalette.nightPaper,
      // Di notte la snackbar non può essere quasi-nera come lo sfondo:
      // sale di due gradini per staccarsi senza accendere lo schermo.
      snackBackground: AppPalette.nightPaperHighest,
      snackForeground: AppPalette.nightInk,
      snackAction: AppPalette.leafLight,
    );
  }

  /// La forma dell'app — raggi, altezze, pesi — è una sola: cambiano solo i
  /// colori. Tenerla in un builder condiviso evita che i due temi divergano.
  static ThemeData _build({
    required ColorScheme colorScheme,
    required AppAccents accents,
    required Color cardColor,
    required Color snackBackground,
    required Color snackForeground,
    required Color snackAction,
  }) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
    );

    return base.copyWith(
      extensions: <ThemeExtension<dynamic>>[accents],
      textTheme: base.textTheme
          .apply(
            bodyColor: colorScheme.onSurface,
            displayColor: colorScheme.onSurface,
          )
          .copyWith(
            headlineLarge: base.textTheme.headlineLarge?.copyWith(
              fontWeight: FontWeight.w900,
              letterSpacing: -1,
            ),
            headlineMedium: base.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w900,
              letterSpacing: -0.7,
            ),
            headlineSmall: base.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: -0.35,
            ),
            titleLarge: base.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: -0.25,
            ),
            titleMedium: base.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 72,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: cardColor,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(26),
          side: BorderSide(color: colorScheme.outline, width: 0.8),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cardColor,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        labelStyle: TextStyle(color: accents.mutedInk),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colorScheme.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colorScheme.primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colorScheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: colorScheme.error, width: 1.6),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          foregroundColor: colorScheme.primary,
          side: BorderSide(color: colorScheme.outline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          // 48 di lato: è il bersaglio minimo, anche quando l'etichetta è
          // corta come «Apri».
          minimumSize: const Size(48, 48),
          foregroundColor: colorScheme.primary,
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 2,
        focusElevation: 3,
        hoverElevation: 3,
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        extendedTextStyle: const TextStyle(fontWeight: FontWeight.w800),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: colorScheme.outline,
        dragHandleSize: const Size(48, 5),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: snackBackground,
        contentTextStyle: TextStyle(color: snackForeground),
        actionTextColor: snackAction,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dividerTheme: DividerThemeData(
        color: colorScheme.outline,
        space: 1,
        thickness: 0.8,
      ),
    );
  }
}
