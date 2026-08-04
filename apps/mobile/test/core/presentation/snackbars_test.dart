import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/presentation/snackbars.dart';

void main() {
  Widget host({required bool accessibleNavigation}) {
    return MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(accessibleNavigation: accessibleNavigation),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const Key('show_snackbar'),
            onPressed: () => showAutoClosingSnackBar(
              ScaffoldMessenger.of(context),
              SnackBar(
                content: const Text('Fatto!'),
                action: SnackBarAction(label: 'Annulla', onPressed: () {}),
              ),
            ),
            child: const Text('mostra'),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'con la navigazione accessibile la snackbar con azione si chiude da sola',
    (tester) async {
      await tester.pumpWidget(host(accessibleNavigation: true));
      await tester.tap(find.byKey(const Key('show_snackbar')));
      await tester.pump();
      expect(find.text('Fatto!'), findsOneWidget);

      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.text('Fatto!'), findsNothing);
    },
  );

  testWidgets('senza navigazione accessibile resta il timeout di sistema', (
    tester,
  ) async {
    await tester.pumpWidget(host(accessibleNavigation: false));
    await tester.tap(find.byKey(const Key('show_snackbar')));
    await tester.pump();
    expect(find.text('Fatto!'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Fatto!'), findsNothing);
  });
}
