import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/features/goal/presentation/widgets/goal_pace_sheet.dart';

import '../marco.dart';

void main() {
  late double? captured;

  Widget host({double paceKgPerWeek = 0.5, double fatToLoseKg = 15}) {
    captured = null;
    return MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              captured = await showModalBottomSheet<double>(
                context: context,
                isScrollControlled: true,
                builder: (_) => GoalPaceSheet(
                  currentWeightKg: marcoWeight,
                  fatToLoseKg: fatToLoseKg,
                  paceKgPerWeek: paceKgPerWeek,
                ),
              );
            },
            child: const Text('apri'),
          ),
        ),
      ),
    );
  }

  Future<void> open(
    WidgetTester tester, {
    double paceKgPerWeek = 0.5,
    double fatToLoseKg = 15,
  }) async {
    await tester.pumpWidget(
      host(paceKgPerWeek: paceKgPerWeek, fatToLoseKg: fatToLoseKg),
    );
    await tester.tap(find.text('apri'));
    await tester.pumpAndSettle();
  }

  String textOf(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(Key(key))).data!;

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('mostra il ritmo in chili e con il suo nome, mai in '
      'percentuale', (tester) async {
    await open(tester);

    expect(textOf(tester, 'pace_value'), '0,50 kg');
    expect(textOf(tester, 'pace_label'), 'Costante');
    expect(find.textContaining('%'), findsNothing);
  });

  testWidgets('il deficit segue il ritmo', (tester) async {
    await open(tester);

    expect(
      find.descendant(
        of: find.byKey(const Key('pace_deficit')),
        matching: find.text('550'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('un ritmo dentro il limite si salva e basta', (tester) async {
    await open(tester);

    expect(find.byKey(const Key('pace_refusal')), findsNothing);
    await tapVisible(tester, find.byKey(const Key('pace_save')));

    expect(captured, 0.5);
  });

  testWidgets('oltre il limite l\'app RIFIUTA: spiega, propone e chiude '
      'il salvataggio', (tester) async {
    await open(tester);
    await tester.drag(find.byKey(const Key('pace_dial')), const Offset(600, 0));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pace_refusal')), findsOneWidget);
    expect(find.textContaining('oltre il limite'), findsOneWidget);
    expect(find.textContaining('0,67'), findsWidgets);

    // Rifiutato vuol dire rifiutato: il pulsante è spento, non «spento con
    // un avviso che si può ignorare».
    final save = tester.widget<FilledButton>(
      find.byKey(const Key('pace_save')),
    );
    expect(save.onPressed, isNull);
  });

  testWidgets('la controproposta riporta al massimo sicuro e riapre il '
      'salvataggio', (tester) async {
    await open(tester);
    await tester.drag(find.byKey(const Key('pace_dial')), const Offset(600, 0));
    await tester.pumpAndSettle();

    await tapVisible(
      tester,
      find.byKey(const Key('pace_accept_counter_proposal')),
    );

    expect(find.byKey(const Key('pace_refusal')), findsNothing);
    expect(textOf(tester, 'pace_value'), '0,65 kg');

    await tapVisible(tester, find.byKey(const Key('pace_save')));
    expect(captured, closeTo(0.65, 0.001));
  });

  testWidgets('senza grasso da perdere non promette nessuna data', (
    tester,
  ) async {
    await open(tester, fatToLoseKg: 0);

    expect(find.byKey(const Key('pace_horizon')), findsNothing);
    expect(find.byKey(const Key('pace_deficit')), findsOneWidget);
  });

  // 15 kg di grasso da perdere: un anno con calma, cinque mesi decisi. Sono
  // due test separati perché riaprire il foglio nello stesso `tester`
  // lascerebbe aperto il primo.
  testWidgets('con calma i 15 kg diventano un anno', (tester) async {
    await open(tester, paceKgPerWeek: 0.3);
    expect(find.text('12 mesi'), findsOneWidget);
  });

  testWidgets('al ritmo deciso gli stessi 15 kg diventano cinque mesi', (
    tester,
  ) async {
    await open(tester, paceKgPerWeek: 0.65);
    expect(find.text('5 mesi'), findsOneWidget);
  });
}
