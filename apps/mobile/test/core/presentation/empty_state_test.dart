import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/presentation/empty_state.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';

void main() {
  Widget host(Widget child, {ThemeData? theme}) => MaterialApp(
    theme: theme ?? AppTheme.light,
    home: Scaffold(
      body: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  );

  testWidgets('mostra icona, titolo e messaggio', (tester) async {
    await tester.pumpWidget(
      host(
        const AppEmptyState(
          title: 'Nessun allenamento',
          message: 'Registra la prima sessione: bastano due serie.',
          icon: Icons.fitness_center_rounded,
        ),
      ),
    );

    expect(find.text('Nessun allenamento'), findsOneWidget);
    expect(
      find.text('Registra la prima sessione: bastano due serie.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.fitness_center_rounded), findsOneWidget);
  });

  testWidgets('l\'azione porta fuori dal vuoto ed è toccabile a 48', (
    tester,
  ) async {
    var tapped = 0;
    await tester.pumpWidget(
      host(
        AppEmptyState(
          message: 'Non hai ancora ricette salvate.',
          actionLabel: 'Crea ricetta',
          onAction: () => tapped++,
        ),
      ),
    );

    final button = find.byType(OutlinedButton);
    expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
    await tester.tap(button);
    expect(tapped, 1);
  });

  testWidgets('la versione compatta è una riga sola, senza azione', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        const AppEmptyState(
          message: 'Il diario di oggi è vuoto.',
          compact: true,
        ),
      ),
    );

    expect(find.text('Il diario di oggi è vuoto.'), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('è letto come un blocco unico', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      host(
        const AppEmptyState(
          title: 'Nessun dato',
          message: 'Torna dopo la prima pesata.',
        ),
      ),
    );

    expect(
      find.bySemanticsLabel('Nessun dato. Torna dopo la prima pesata.'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('il fondo si adatta al tema invece di essere fisso', (
    tester,
  ) async {
    Color backgroundIn(WidgetTester tester) {
      final decorated = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(AppEmptyState),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      return (decorated.decoration as BoxDecoration).color!;
    }

    await tester.pumpWidget(
      host(const AppEmptyState(message: 'Niente da mostrare.')),
    );
    await tester.pumpAndSettle();
    final light = backgroundIn(tester);

    await tester.pumpWidget(
      host(
        const AppEmptyState(message: 'Niente da mostrare.'),
        theme: AppTheme.dark,
      ),
    );
    // Il passaggio tra i temi è animato: si misura a transizione conclusa.
    await tester.pumpAndSettle();
    final dark = backgroundIn(tester);

    expect(light, isNot(dark));
    expect(dark.computeLuminance(), lessThan(light.computeLuminance()));
  });

  test('etichetta e callback non possono essere scompagnate', () {
    expect(
      () => AppEmptyState(message: 'x', actionLabel: 'Crea'),
      throwsAssertionError,
    );
  });
}
