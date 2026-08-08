import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/checkin/data/check_in_store.dart';
import 'package:kal_tracker/features/checkin/presentation/check_in_providers.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/goal/data/activity_settings_store.dart';
import 'package:kal_tracker/features/goal/data/goal_store.dart';
import 'package:kal_tracker/features/goal/domain/activity_multiplier.dart';
import 'package:kal_tracker/features/goal/domain/body_state.dart';
import 'package:kal_tracker/features/goal/domain/definition_level.dart';
import 'package:kal_tracker/features/goal/domain/goal.dart';
import 'package:kal_tracker/features/goal/domain/tdee.dart';
import 'package:kal_tracker/features/goal/presentation/goal_providers.dart';
import 'package:kal_tracker/features/goal/presentation/goal_screen.dart';
import 'package:kal_tracker/features/goal/presentation/widgets/activity_multiplier_card.dart';

import '../marco.dart';

/// **La proposta si vede, e resta una proposta.**
///
/// Il moltiplicatore derivato si calcolava già e non lo leggeva nessuno: il
/// numero non aveva un posto dove comparire, quindi non poteva esserci
/// nessun sì. Qui si verifica quello che il calcolo da solo non garantisce —
/// che la domanda arrivi a schermo, che il sì scriva, e che nient'altro lo
/// faccia al posto di Marco.

/// Stesso «adesso» fisso degli altri test dell'area: le finestre sono sette
/// giorni a ritroso da qui.
final DateTime now = DateTime(2026, 8, 7, 20);

BodyState get marcoBody => BodyState(
  latest: WeightPoint(at: now, weightKg: marcoWeight),
  fatFreeMassKg: marcoFatFreeMass,
  fatFreeMassMeasuredAt: now,
  sevenDayAverageKg: marcoWeight,
);

Goal get marcoGoal => Goal(
  id: 'goal-1',
  targetWeightKg: 85,
  targetLevel: DefinitionLevel.defined,
  paceKgPerWeek: 0.5,
  startedAt: now.subtract(const Duration(days: 30)),
  startWeightKg: 98,
  startFatFreeMassKg: marcoFatFreeMass,
);

/// Tre settimane da tre sedute che portano il derivato a ~1,48: l'esempio
/// della roadmap, quello che deve far comparire la domanda.
ActivityTrainingHistory get threeWeeksOfTraining => (
  sessions: [
    for (var week = 0; week < 3; week++)
      for (final offset in const [1, 3, 5])
        TrainingSessionKcal(
          endedAt: now.subtract(Duration(days: week * 7 + offset)),
          kcal: 1568,
          averageMet: 5,
          muscleGroupsComplete: true,
        ),
  ],
  firstRecordedAt: now.subtract(const Duration(days: 120)),
);

const ActivityTrainingHistory noTraining = (
  sessions: <TrainingSessionKcal>[],
  firstRecordedAt: null,
);

void main() {
  setUpAll(() => initializeDateFormatting('it'));
  setUp(AppTime.initialize);

  /// La card da sola: è lei l'oggetto di questi test, e montarla dentro tutta
  /// la schermata vorrebbe dire scorrere fino a lei prima di ogni tocco.
  /// Dove sta nella schermata lo verifica l'ultimo test.
  Widget host({
    required ActivitySettingsStore store,
    ActivityTrainingHistory? history,
    Widget home = const Scaffold(
      body: SingleChildScrollView(child: ActivityMultiplierCard()),
    ),
  }) => ProviderScope(
    overrides: [
      // Il moltiplicatore legge i passi dal check-in: senza questo override
      // la schermata aprirebbe il database vero.
      checkInStoreProvider.overrideWithValue(InMemoryCheckInStore()),
      activitySettingsStoreProvider.overrideWithValue(store),
      goalStoreProvider.overrideWithValue(
        InMemoryGoalStore(GoalHistory(current: marcoGoal)),
      ),
      bodyStateProvider.overrideWith((ref) => Stream.value(marcoBody)),
      activityTrainingHistoryProvider.overrideWith(
        (ref) async => history ?? noTraining,
      ),
      todayProvider.overrideWithValue(now),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      locale: const Locale('it'),
      supportedLocales: const [Locale('it')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: home,
    ),
  );

  /// Dopo un sì resta in giro la snackbar con «Annulla», che si chiude da
  /// sola dopo cinque secondi: senza aspettarla il test finisce con un timer
  /// pendente, e comunque coprirebbe i bottoni da toccare dopo.
  Future<void> letSnackBarGo(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
  }

  testWidgets('la domanda si vede, con i due numeri', (tester) async {
    await tester.pumpWidget(
      host(
        store: InMemoryActivitySettingsStore(),
        history: threeWeeksOfTraining,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('goal_activity_proposal')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('goal_activity_question'))).data,
      'Le tue ultime 3 settimane dicono 1,48 invece di 1,55 — vuoi '
      'aggiornare?',
    );
    // E da dove viene il numero sta lì accanto, non in un'altra schermata.
    expect(find.textContaining('allenamenti'), findsWidgets);
  });

  testWidgets('senza niente da chiedere la card non c\'è', (tester) async {
    await tester.pumpWidget(host(store: InMemoryActivitySettingsStore()));
    await tester.pumpAndSettle();

    // «Mi servono tre settimane» lo dice già la scheda del consumo: un avviso
    // fisso che non porta a nessuna azione qui non ci va.
    expect(find.byKey(const Key('goal_activity_proposal')), findsNothing);
    expect(find.byKey(const Key('goal_activity_in_use')), findsNothing);
  });

  testWidgets('«non adesso» non applica niente e non insiste', (tester) async {
    final store = InMemoryActivitySettingsStore();
    await tester.pumpWidget(host(store: store, history: threeWeeksOfTraining));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('goal_activity_postpone')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('goal_activity_proposal')), findsNothing);
    expect(store.current.acceptedMultiplier, isNull);
    expect(store.current.declared, ActivityLevel.moderate);
  });

  testWidgets('il sì scrive il derivato, e si vede quale', (tester) async {
    final store = InMemoryActivitySettingsStore();
    await tester.pumpWidget(host(store: store, history: threeWeeksOfTraining));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('goal_activity_accept')));
    await tester.pumpAndSettle();

    expect(store.current.acceptedMultiplier, closeTo(1.48, 0.005));
    // La stessa domanda non torna: il confronto adesso è con quello che è in
    // vigore, non con la voce della tendina rimasta lì sotto.
    expect(find.byKey(const Key('goal_activity_proposal')), findsNothing);
    expect(find.byKey(const Key('goal_activity_in_use')), findsOneWidget);
    expect(find.text('1,48'), findsOneWidget);

    await letSnackBarGo(tester);
  });

  testWidgets('e da lì si torna alla scelta di prima', (tester) async {
    final store = InMemoryActivitySettingsStore();
    await tester.pumpWidget(host(store: store, history: threeWeeksOfTraining));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('goal_activity_accept')));
    await tester.pumpAndSettle();
    await letSnackBarGo(tester);

    await tester.tap(find.byKey(const Key('goal_activity_revoke')));
    await tester.pumpAndSettle();

    expect(store.current.acceptedMultiplier, isNull);
    // Il dichiarato era rimasto lì sotto tutto il tempo, e la domanda torna
    // ad avere senso.
    expect(store.current.declared, ActivityLevel.moderate);
    expect(find.byKey(const Key('goal_activity_proposal')), findsOneWidget);
  });

  testWidgets('sta dove l\'obiettivo si guarda già', (tester) async {
    await tester.pumpWidget(
      host(
        store: InMemoryActivitySettingsStore(),
        history: threeWeeksOfTraining,
        home: const GoalScreen(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.dragUntilVisible(
      find.byKey(const Key('goal_activity_proposal')),
      find.byKey(const Key('goal_list')),
      const Offset(0, -140),
    );
    await tester.pumpAndSettle();

    // Dentro la lista dell'Obiettivo, non in una schermata sua: la domanda
    // parla del consumo, e il consumo si legge qui.
    expect(
      find.ancestor(
        of: find.byKey(const Key('goal_activity_proposal')),
        matching: find.byKey(const Key('goal_list')),
      ),
      findsOneWidget,
    );
  });
}
