import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/presentation/snackbars.dart';

void main() {
  var undone = false;

  Widget host() {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const Key('show_snackbar'),
            onPressed: () => showAutoClosingSnackBar(
              ScaffoldMessenger.of(context),
              SnackBar(
                content: const Text('Fatto!'),
                action: SnackBarAction(
                  label: 'Annulla',
                  onPressed: () => undone = true,
                ),
              ),
            ),
            child: const Text('mostra'),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'la snackbar con azione si chiude da sola (su M3 non lo farebbe mai)',
    (tester) async {
      await tester.pumpWidget(host());
      await tester.tap(find.byKey(const Key('show_snackbar')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Fatto!'), findsOneWidget);

      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.text('Fatto!'), findsNothing);
    },
  );

  testWidgets('«Annulla» resta toccabile prima della chiusura', (tester) async {
    undone = false;
    await tester.pumpWidget(host());
    await tester.tap(find.byKey(const Key('show_snackbar')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle(const Duration(seconds: 6));
    expect(undone, isTrue);
    expect(find.text('Fatto!'), findsNothing);
  });
}
