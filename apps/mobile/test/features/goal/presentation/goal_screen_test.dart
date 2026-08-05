import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/goal/data/goal_store.dart';
import 'package:kal_tracker/features/goal/domain/body_state.dart';
import 'package:kal_tracker/features/goal/domain/definition_level.dart';
import 'package:kal_tracker/features/goal/domain/goal.dart';
import 'package:kal_tracker/features/goal/domain/tdee.dart';
import 'package:kal_tracker/features/goal/presentation/goal_providers.dart';
import 'package:kal_tracker/features/goal/presentation/goal_screen.dart';

import '../marco.dart';

BodyState bodyState({
  double? weightKg = marcoWeight,
  double? fatFreeMassKg = marcoFatFreeMass,
  double? sevenDayAverageKg = 95.3,
  TdeeSample? sample,
}) => BodyState(
  latest: weightKg == null
      ? null
      : WeightPoint(at: DateTime.now().toUtc(), weightKg: weightKg),
  fatFreeMassKg: fatFreeMassKg,
  fatFreeMassMeasuredAt: fatFreeMassKg == null ? null : DateTime.now().toUtc(),
  sevenDayAverageKg: sevenDayAverageKg,
  tdeeSample: sample,
);

Goal goalOf({
  GoalPhase phase = GoalPhase.approach,
  double targetWeightKg = 80.5,
  DefinitionLevel level = DefinitionLevel.defined,
}) => Goal(
  id: 'goal-1',
  targetWeightKg: targetWeightKg,
  targetLevel: level,
  paceKgPerWeek: 0.5,
  startedAt: DateTime.now().toUtc().subtract(const Duration(days: 30)),
  startWeightKg: 98,
  startFatFreeMassKg: marcoFatFreeMass,
  phase: phase,
  phaseStartedAt: DateTime.now().toUtc().subtract(const Duration(days: 30)),
);

void main() {
  setUpAll(() => initializeDateFormatting('it'));
  setUp(AppTime.initialize);

  /// [theme] nullo significa «MaterialApp spoglio»: serve a verificare che i
  /// mattoni condivisi ripieghino sui colori di default invece di lanciare.
  Widget host({required BodyState state, GoalStore? store, ThemeData? theme}) =>
      ProviderScope(
        overrides: [
          goalStoreProvider.overrideWithValue(store ?? InMemoryGoalStore()),
          bodyStateProvider.overrideWith((ref) => Stream.value(state)),
        ],
        child: MaterialApp(
          theme: theme,
          locale: const Locale('it'),
          supportedLocales: const [Locale('it')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const GoalScreen(),
        ),
      );

  Widget themedHost({required BodyState state, GoalStore? store}) =>
      host(state: state, store: store, theme: AppTheme.light);

  /// La lista è pigra: quello che sta sotto la piega non esiste ancora nel
  /// tree, quindi va portato dentro con uno scorrimento vero.
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.dragUntilVisible(
      finder,
      find.byKey(const Key('goal_list')),
      const Offset(0, -140),
    );
    await tester.pumpAndSettle();
  }

  group('senza dati non si rompe niente', () {
    testWidgets('senza pesate invita a pesarsi, non dà errore', (tester) async {
      await tester.pumpWidget(
        themedHost(state: bodyState(weightKg: null, fatFreeMassKg: null)),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('goal_needs_weight')), findsOneWidget);
      expect(find.byKey(const Key('goal_empty_state')), findsNothing);
    });

    testWidgets('con il solo peso spiega cosa manca e rassicura sul resto', (
      tester,
    ) async {
      await tester.pumpWidget(
        themedHost(state: bodyState(fatFreeMassKg: null)),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('goal_needs_composition')), findsOneWidget);
      expect(find.textContaining('funzionano'), findsOneWidget);
    });

    testWidgets('senza obiettivo l\'app dice che va bene così', (tester) async {
      await tester.pumpWidget(themedHost(state: bodyState()));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('goal_empty_state')), findsOneWidget);
      expect(find.textContaining('L\'app funziona lo stesso'), findsOneWidget);
      expect(find.text('Scegli un traguardo'), findsOneWidget);
    });
  });

  group('con un obiettivo', () {
    Future<void> pumpWithGoal(
      WidgetTester tester, {
      GoalPhase phase = GoalPhase.approach,
      BodyState? state,
    }) async {
      final store = InMemoryGoalStore(
        GoalHistory(current: goalOf(phase: phase)),
      );
      await tester.pumpWidget(
        themedHost(state: state ?? bodyState(), store: store),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('il traguardo si legge in linguaggio umano', (tester) async {
      await pumpWithGoal(tester);

      expect(
        tester.widget<Text>(find.byKey(const Key('goal_headline'))).data,
        '80,5 kg definito',
      );
      // Mai una percentuale di grasso, in nessuna card.
      expect(find.textContaining('% di grasso'), findsNothing);
    });

    testWidgets('mostra peso, grasso da perdere e data stimata', (
      tester,
    ) async {
      await pumpWithGoal(tester);

      expect(find.byKey(const Key('goal_current_weight')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('goal_fat_to_lose')),
          matching: find.text('15,0'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('goal_estimated_date')), findsOneWidget);
      expect(find.byKey(const Key('goal_progress')), findsOneWidget);
    });

    testWidgets('la fase corrente è scritta, non solo colorata', (
      tester,
    ) async {
      await pumpWithGoal(tester);
      // In testa alla schermata la fase è una pastiglia con la parola
      // dentro, non un pallino colorato.
      expect(find.byKey(const Key('goal_phase_badge')), findsOneWidget);

      await scrollTo(tester, find.byKey(const Key('goal_phase_card')));
      expect(find.text('Avvicinamento — adesso'), findsOneWidget);
    });

    testWidgets('dice cosa comporta oggi: calorie e proteine', (tester) async {
      await pumpWithGoal(tester);
      await scrollTo(tester, find.byKey(const Key('goal_targets_card')));

      expect(
        find.descendant(
          of: find.byKey(const Key('goal_daily_protein')),
          matching: find.text('143'),
        ),
        findsOneWidget,
      );
      // Senza dati reali il consumo è dichiarato come stima, non spacciato
      // per misura.
      expect(find.byKey(const Key('goal_tdee_source')), findsOneWidget);
      expect(find.textContaining('Stima da metabolismo'), findsOneWidget);
    });

    testWidgets('in mantenimento compare la banda al posto della data', (
      tester,
    ) async {
      await pumpWithGoal(
        tester,
        phase: GoalPhase.maintenance,
        state: bodyState(weightKg: 80.8, sevenDayAverageKg: 80.9),
      );
      expect(find.byKey(const Key('goal_estimated_date')), findsOneWidget);
      await scrollTo(tester, find.byKey(const Key('goal_band_card')));

      expect(find.text('79,5 – 81,5 kg'), findsOneWidget);
      expect(find.text('Dentro la banda'), findsOneWidget);
    });
  });

  group('il piano non si spegne da solo', () {
    testWidgets('arrivati al traguardo si passa al consolidamento, e lo dice', (
      tester,
    ) async {
      final store = InMemoryGoalStore(GoalHistory(current: goalOf()));
      await tester.pumpWidget(
        themedHost(
          state: bodyState(weightKg: 80.4, sevenDayAverageKg: 80.5),
          store: store,
        ),
      );
      await tester.pumpAndSettle();

      expect((await store.read()).current!.phase, GoalPhase.consolidation);
      // L'aumento di peso da glicogeno va spiegato adesso, non dopo lo
      // scoraggiamento.
      expect(find.textContaining('glicogeno e acqua'), findsOneWidget);
      expect(find.text('Consolidamento'), findsWidgets);
    });

    testWidgets('finché il traguardo è lontano la fase non si muove', (
      tester,
    ) async {
      final store = InMemoryGoalStore(GoalHistory(current: goalOf()));
      await tester.pumpWidget(themedHost(state: bodyState(), store: store));
      await tester.pumpAndSettle();

      expect((await store.read()).current!.phase, GoalPhase.approach);
    });
  });

  group('cambiare idea', () {
    testWidgets('impostare il primo traguardo lo salva e lo mostra', (
      tester,
    ) async {
      final store = InMemoryGoalStore();
      await tester.pumpWidget(themedHost(state: bodyState(), store: store));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Scegli un traguardo'));
      await tester.pumpAndSettle();

      final save = find.byKey(const Key('goal_sheet_save'));
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.byKey(const Key('goal_headline'))).data,
        '86,5 kg asciutto',
      );
      expect((await store.read()).current!.targetWeightKg, 86.5);
      expect(find.textContaining('Traguardo impostato'), findsOneWidget);
    });

    testWidgets('cambiarlo archivia il precedente e offre l\'annullamento', (
      tester,
    ) async {
      final store = InMemoryGoalStore(GoalHistory(current: goalOf()));
      await tester.pumpWidget(themedHost(state: bodyState(), store: store));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cambia'));
      await tester.pumpAndSettle();

      await tester.drag(
        find.byKey(const Key('goal_dial')),
        const Offset(60, 0),
      );
      await tester.pumpAndSettle();
      final save = find.byKey(const Key('goal_sheet_save'));
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(find.textContaining('Lo storico è rimasto'), findsOneWidget);
      expect(find.text('Annulla'), findsOneWidget);
      expect((await store.read()).past, hasLength(1));

      await tester.tap(find.text('Annulla'));
      await tester.pumpAndSettle();

      // L'annullamento rimette in corsa quello di prima, storico compreso.
      expect(
        tester.widget<Text>(find.byKey(const Key('goal_headline'))).data,
        '80,5 kg definito',
      );
      expect((await store.read()).past, isEmpty);
    });

    testWidgets('la snackbar con «Annulla» si chiude da sola', (tester) async {
      final store = InMemoryGoalStore(GoalHistory(current: goalOf()));
      await tester.pumpWidget(themedHost(state: bodyState(), store: store));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cambia'));
      await tester.pumpAndSettle();
      final save = find.byKey(const Key('goal_sheet_save'));
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(find.text('Annulla'), findsOneWidget);

      // Su questo Flutter le snackbar CON azione non si chiudono mai da
      // sole: l'helper è l'unica ragione per cui questo test passa.
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();

      expect(find.text('Annulla'), findsNothing);
    });

    testWidgets('il ritmo si cambia senza toccare il traguardo', (
      tester,
    ) async {
      final store = InMemoryGoalStore(GoalHistory(current: goalOf()));
      await tester.pumpWidget(themedHost(state: bodyState(), store: store));
      await tester.pumpAndSettle();

      final action = find.text('Ritmo');
      await scrollTo(tester, action);
      await tester.tap(action);
      await tester.pumpAndSettle();

      // Il tocco su una Slider porta subito il valore sotto il dito: serve
      // uno spostamento ampio per finire davvero altrove.
      await tester.drag(
        find.byKey(const Key('pace_dial')),
        const Offset(-150, 0),
      );
      await tester.pumpAndSettle();
      final save = find.byKey(const Key('pace_save'));
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();

      final saved = (await store.read()).current!;
      expect(saved.id, 'goal-1');
      expect(saved.targetWeightKg, 80.5);
      expect(saved.paceKgPerWeek, isNot(0.5));
      expect(find.textContaining('Ritmo aggiornato'), findsOneWidget);
    });
  });

  testWidgets('funziona anche senza il tema dell\'app', (tester) async {
    // I mattoni condivisi ripiegano sugli accenti di default: la schermata
    // non deve lanciare se finisce in un MaterialApp spoglio.
    await tester.pumpWidget(host(state: bodyState()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('goal_empty_state')), findsOneWidget);
  });
}
