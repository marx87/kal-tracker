import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';

/// Rapporto di contrasto WCAG tra due colori opachi.
double contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  final lighter = math.max(first, second);
  final darker = math.min(first, second);
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  final light = AppTheme.light;
  final dark = AppTheme.dark;

  group('tema scuro', () {
    test('esiste ed è davvero scuro', () {
      expect(dark.brightness, Brightness.dark);
      expect(dark.colorScheme.brightness, Brightness.dark);
      expect(dark.scaffoldBackgroundColor, AppPalette.nightCanvas);
    });

    test('le card restano distinguibili dallo sfondo', () {
      final card = dark.cardTheme.color!;
      expect(card, isNot(dark.scaffoldBackgroundColor));
      // Senza ombre (elevation 0) la separazione la fanno solo luminanza e
      // bordo: se questo scende, le card spariscono nel fondo.
      expect(
        contrast(card, dark.scaffoldBackgroundColor),
        greaterThan(1.15),
        reason: 'card e sfondo troppo simili',
      );
      final shape = dark.cardTheme.shape! as RoundedRectangleBorder;
      expect(shape.side.color, dark.colorScheme.outline);
      expect(shape.side.width, 0.8);
    });

    test('il verde bosco resta leggibile, non è il primario del chiaro', () {
      expect(dark.colorScheme.primary, isNot(AppPalette.forest));
      // Elemento di interfaccia: minimo 3:1. Qui si sta molto più larghi
      // perché il primario porta anche testo (bottoni, link).
      expect(
        contrast(dark.colorScheme.primary, dark.colorScheme.surface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(dark.colorScheme.primary, dark.colorScheme.onPrimary),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('conserva il carattere caldo: l\'inchiostro non è grigio neutro', () {
      final ink = dark.colorScheme.onSurface;
      // In una crema il rosso supera il blu. Un grigio neutro li avrebbe pari.
      expect(ink.r, greaterThan(ink.b));
      final canvas = dark.scaffoldBackgroundColor;
      // Anche il fondo tiene la sua nota verde invece di essere nero puro.
      expect(canvas.g, greaterThan(canvas.r));
    });
  });

  group('leggibilità nei due temi', () {
    for (final (name, theme) in [('chiaro', light), ('scuro', dark)]) {
      test('tema $name: testo e testo secondario stanno sopra 4.5:1', () {
        final scheme = theme.colorScheme;
        expect(
          contrast(scheme.onSurface, scheme.surface),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(scheme.onSurfaceVariant, scheme.surface),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(scheme.onSurface, theme.cardTheme.color!),
          greaterThanOrEqualTo(4.5),
        );
      });

      test('tema $name: la snackbar si legge, azione compresa', () {
        final snack = theme.snackBarTheme;
        expect(
          contrast(snack.contentTextStyle!.color!, snack.backgroundColor!),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(snack.actionTextColor!, snack.backgroundColor!),
          greaterThanOrEqualTo(4.5),
        );
      });
    }
  });

  group('AppAccents', () {
    for (final (name, accents) in [
      ('chiaro', AppAccents.light),
      ('scuro', AppAccents.dark),
    ]) {
      test('tema $name: ogni stato si legge sul proprio fondo', () {
        final pairs = <String, (Color, Color)>{
          'buono': (accents.positive, accents.positiveSurface),
          'attenzione': (accents.warning, accents.warningSurface),
          'critico': (accents.critical, accents.criticalSurface),
          'informativo': (accents.info, accents.infoSurface),
        };
        for (final entry in pairs.entries) {
          final (foreground, background) = entry.value;
          expect(
            contrast(foreground, background),
            greaterThanOrEqualTo(4.5),
            reason: 'stato ${entry.key} illeggibile nel tema $name',
          );
        }
      });
    }

    test('i temi portano il set giusto', () {
      expect(light.extension<AppAccents>(), AppAccents.light);
      expect(dark.extension<AppAccents>(), AppAccents.dark);
    });

    testWidgets('of() ripiega sul chiaro fuori dal tema dell\'app', (
      tester,
    ) async {
      late AppAccents resolved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              resolved = AppAccents.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(resolved, AppAccents.light);
    });

    test('lerp interpola invece di saltare', () {
      final middle = AppAccents.light.lerp(AppAccents.dark, 0.5);
      expect(middle.positive, isNot(AppAccents.light.positive));
      expect(middle.positive, isNot(AppAccents.dark.positive));
      expect(AppAccents.light.lerp(AppAccents.dark, 0), AppAccents.light);
    });
  });

  group('la forma è la stessa nei due temi', () {
    double cardRadius(ThemeData theme) {
      final shape = theme.cardTheme.shape! as RoundedRectangleBorder;
      return (shape.borderRadius as BorderRadius).topLeft.x;
    }

    test('card: raggio 26, elevation 0, margine zero', () {
      for (final theme in [light, dark]) {
        expect(cardRadius(theme), 26);
        expect(theme.cardTheme.elevation, 0);
        expect(theme.cardTheme.margin, EdgeInsets.zero);
      }
    });

    test('FilledButton alto 52 con raggio 16', () {
      for (final theme in [light, dark]) {
        final style = theme.filledButtonTheme.style!;
        expect(style.minimumSize!.resolve({})!.height, 52);
        final shape = style.shape!.resolve({})! as RoundedRectangleBorder;
        expect((shape.borderRadius as BorderRadius).topLeft.x, 16);
      }
    });

    test('AppBar alta 72, non centrata, senza elevazione', () {
      for (final theme in [light, dark]) {
        expect(theme.appBarTheme.toolbarHeight, 72);
        expect(theme.appBarTheme.centerTitle, isFalse);
        expect(theme.appBarTheme.elevation, 0);
        expect(theme.appBarTheme.scrolledUnderElevation, 0);
      }
    });

    test('bottom sheet: raggio 30 e maniglia di trascinamento', () {
      for (final theme in [light, dark]) {
        final shape = theme.bottomSheetTheme.shape! as RoundedRectangleBorder;
        expect(shape.borderRadius.resolve(TextDirection.ltr).topLeft.x, 30);
        expect(theme.bottomSheetTheme.showDragHandle, isTrue);
      }
    });

    test('titoli headline in w900 con crenatura negativa', () {
      for (final theme in [light, dark]) {
        expect(theme.textTheme.headlineLarge!.fontWeight, FontWeight.w900);
        expect(theme.textTheme.headlineLarge!.letterSpacing, lessThan(0));
        expect(theme.textTheme.titleLarge!.fontWeight, FontWeight.w800);
      }
    });

    test('i bersagli secondari partono da 48', () {
      for (final theme in [light, dark]) {
        expect(
          theme.outlinedButtonTheme.style!.minimumSize!.resolve({}),
          const Size(48, 48),
        );
        expect(
          theme.textButtonTheme.style!.minimumSize!.resolve({}),
          const Size(48, 48),
        );
      }
    });
  });
}
