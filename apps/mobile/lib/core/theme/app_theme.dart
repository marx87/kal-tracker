import 'package:flutter/material.dart';

/// The shared food-and-wellness palette for Kal Tracker.
///
/// Colors are public so small presentation widgets can stay visually
/// consistent without duplicating magic values.
abstract final class AppPalette {
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
          outline: AppPalette.outline,
          outlineVariant: AppPalette.outline,
        );

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppPalette.cream,
    );

    return base.copyWith(
      textTheme: base.textTheme
          .apply(bodyColor: AppPalette.ink, displayColor: AppPalette.ink)
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
      appBarTheme: const AppBarTheme(
        backgroundColor: AppPalette.cream,
        foregroundColor: AppPalette.ink,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 72,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: AppPalette.paper,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(26),
          side: const BorderSide(color: AppPalette.outline, width: 0.8),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppPalette.paper,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        labelStyle: const TextStyle(color: AppPalette.mutedInk),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppPalette.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: AppPalette.forest, width: 1.6),
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
          backgroundColor: AppPalette.forest,
          foregroundColor: Colors.white,
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          foregroundColor: AppPalette.forest,
          side: const BorderSide(color: AppPalette.outline),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        elevation: 2,
        focusElevation: 3,
        hoverElevation: 3,
        backgroundColor: AppPalette.forest,
        foregroundColor: Colors.white,
        extendedTextStyle: const TextStyle(fontWeight: FontWeight.w800),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppPalette.cream,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: AppPalette.outline,
        dragHandleSize: Size(48, 5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: AppPalette.forestDark,
        contentTextStyle: const TextStyle(color: Colors.white),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dividerTheme: const DividerThemeData(
        color: AppPalette.outline,
        space: 1,
        thickness: 0.8,
      ),
    );
  }
}
