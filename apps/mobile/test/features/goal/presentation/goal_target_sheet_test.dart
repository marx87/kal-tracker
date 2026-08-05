import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/features/goal/domain/definition_level.dart';
import 'package:kal_tracker/features/goal/presentation/widgets/goal_target_sheet.dart';

import '../marco.dart';

void main() {
  late GoalTargetChoice? captured;

  Widget host({DefinitionLevel? initialLevel, double? initialWeightKg}) {
    captured = null;
    return MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              captured = await showModalBottomSheet<GoalTargetChoice>(
                context: context,
                isScrollControlled: true,
                builder: (_) => GoalTargetSheet(
                  currentWeightKg: marcoWeight,
                  fatFreeMassKg: marcoFatFreeMass,
                  paceKgPerWeek: 0.5,
                  initialTargetWeightKg: initialWeightKg,
                  initialLevel: initialLevel,
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
    DefinitionLevel? initialLevel,
  }) async {
    await tester.pumpWidget(host(initialLevel: initialLevel));
    await tester.tap(find.text('apri'));
    await tester.pumpAndSettle();
  }

  String textOf(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(Key(key))).data!;

  Future<void> dragDial(WidgetTester tester, double dx) async {
    await tester.drag(find.byKey(const Key('goal_dial')), Offset(dx, 0));
    await tester.pumpAndSettle();
  }

  testWidgets('all\'apertura mostra un peso e la parola che lo descrive', (
    tester,
  ) async {
    await open(tester);

    expect(textOf(tester, 'goal_sheet_weight'), '86,5');
    expect(textOf(tester, 'goal_sheet_level'), 'Asciutto');
    // La percentuale di grasso non compare da nessuna parte: si sceglie in
    // linguaggio umano, non in punti percentuali.
    expect(find.textContaining('%'), findsNothing);
    expect(find.textContaining('grasso corporeo'), findsNothing);
  });

  testWidgets('è una manopola sola: peso e definizione si muovono insieme', (
    tester,
  ) async {
    await open(tester);
    final startWeight = textOf(tester, 'goal_sheet_weight');
    final startLevel = textOf(tester, 'goal_sheet_level');

    await dragDial(tester, -60);

    expect(textOf(tester, 'goal_sheet_weight'), isNot(startWeight));
    expect(textOf(tester, 'goal_sheet_level'), isNot(startLevel));
    // Meno chili vuol dire più asciutto, mai il contrario.
    expect(
      double.parse(textOf(tester, 'goal_sheet_weight').replaceAll(',', '.')),
      lessThan(double.parse(startWeight.replaceAll(',', '.'))),
    );
  });

  testWidgets('sulla curva il verdetto è verde e non propone alternative', (
    tester,
  ) async {
    await open(tester);

    expect(find.byKey(const Key('goal_feasibility')), findsOneWidget);
    expect(find.textContaining('Raggiungibile'), findsOneWidget);
    expect(find.byKey(const Key('goal_take_counter_proposal')), findsNothing);
  });

  testWidgets('trascinando sotto la scala l\'app dice che costa muscolo', (
    tester,
  ) async {
    await open(tester);
    await dragDial(tester, -1000);

    expect(textOf(tester, 'goal_sheet_weight'), '73,0');
    // Nessuna parola descrive quel peso: dirlo è più onesto che chiamarlo
    // «molto definito».
    expect(textOf(tester, 'goal_sheet_level'), 'Fuori scala');
    expect(find.textContaining('Costerebbe'), findsOneWidget);
    expect(find.textContaining('sconsiglio'), findsOneWidget);
  });

  testWidgets('la controproposta riporta davvero sulla curva', (tester) async {
    await open(tester);
    await dragDial(tester, -1000);

    final button = find.byKey(const Key('goal_take_counter_proposal'));
    expect(button, findsOneWidget);
    // Il pulsante promette il numero che poi mette: nessuno scarto di
    // arrotondamento tra l'etichetta e l'effetto.
    expect(find.text('Portami a 79,0 kg'), findsOneWidget);

    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(textOf(tester, 'goal_sheet_weight'), '79,0');
    expect(textOf(tester, 'goal_sheet_level'), 'Molto definito');
    expect(find.textContaining('Raggiungibile'), findsOneWidget);
  });

  testWidgets('bloccando la definizione si può chiedere l\'impossibile: '
      'servirebbe costruire muscolo', (tester) async {
    await open(tester);

    final lock = find.byKey(const Key('goal_lock_level'));
    await tester.ensureVisible(lock);
    await tester.pumpAndSettle();
    await tester.tap(lock);
    await tester.pumpAndSettle();

    await dragDial(tester, 1000);

    expect(textOf(tester, 'goal_sheet_weight'), '100,0');
    // La parola resta ferma: è il senso del blocco.
    expect(textOf(tester, 'goal_sheet_level'), 'Asciutto');
    expect(find.textContaining('Servono'), findsOneWidget);
    // La spiegazione e la controproposta la nominano entrambe: prima una
    // fase di massa, poi il deficit.
    expect(find.textContaining('fase di massa'), findsNWidgets(2));
  });

  testWidgets('il tempo stimato e il grasso da perdere si aggiornano '
      'mentre si trascina', (tester) async {
    await open(tester);
    final fatBefore = find.byKey(const Key('goal_sheet_fat_to_lose'));
    await tester.ensureVisible(fatBefore);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: fatBefore, matching: find.text('9,0')),
      findsOneWidget,
    );

    await dragDial(tester, -1000);

    expect(
      find.descendant(
        of: find.byKey(const Key('goal_sheet_fat_to_lose')),
        matching: find.text('22,5'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('salvando restituisce peso e definizione scelti', (tester) async {
    await open(tester);

    final save = find.byKey(const Key('goal_sheet_save'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.weightKg, 86.5);
    expect(captured!.level, DefinitionLevel.lean);
  });

  testWidgets('riaprendolo su un obiettivo esistente riparte da lì', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(initialWeightKg: 80.5, initialLevel: DefinitionLevel.defined),
    );
    await tester.tap(find.text('apri'));
    await tester.pumpAndSettle();

    expect(textOf(tester, 'goal_sheet_weight'), '80,5');
    expect(textOf(tester, 'goal_sheet_level'), 'Definito');
  });

  testWidgets('chi ascolta sente le stesse due cose che si vedono', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await open(tester);

    // Il cursore annuncia numero **e** parola: «ottantasei virgola cinque»
    // da solo non direbbe cosa si sta scegliendo.
    final dial = tester.widget<Slider>(find.byKey(const Key('goal_dial')));
    expect(dial.semanticFormatterCallback!(86.5), '86,5 chilogrammi, asciutto');

    // E il numero grande è un blocco solo, non tre frammenti.
    expect(
      tester.getSemantics(find.bySemanticsLabel('Traguardo')).value,
      '86,5 chilogrammi, asciutto',
    );

    handle.dispose();
  });
}
