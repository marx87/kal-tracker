import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/checkin/data/check_in_store.dart';
import 'package:kal_tracker/features/checkin/domain/daily_check_in.dart';
import 'package:kal_tracker/features/checkin/presentation/check_in_providers.dart';
import 'package:kal_tracker/features/diary/data/diary_repository.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/diary/presentation/today_diary_screen.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/playful_empty_state.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/today_recipes_card.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/weekly_plan/data/workout_plan_repository.dart';

/// La schermata si monta senza `app.dart`: qui interessa il diario, non il
/// router, e un guscio spoglio tiene il test indipendente dal resto
/// dell'applicazione.
Widget _host(
  AppDatabase database, {
  CheckInStore? checkInStore,
  ThemeData? theme,
  double textScale = 1,
}) => ProviderScope(
  overrides: [
    databaseProvider.overrideWithValue(database),
    appConfigProvider.overrideWithValue(const AppConfig.offline()),
    checkInStoreProvider.overrideWithValue(
      checkInStore ?? InMemoryCheckInStore(),
    ),
  ],
  child: MaterialApp(
    theme: theme ?? AppTheme.light,
    locale: const Locale('it'),
    supportedLocales: const [Locale('it')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: const TodayDiaryScreen(),
      ),
    ),
  ),
);

Future<void> _dispose(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(database.close);
}

/// Telefono di Marco. Le misure contano: la riserva in fondo alla lista si
/// verifica su uno schermo vero, non sugli 800×600 di default.
void _usePhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<String> _seedProfile(AppDatabase database) async {
  final profile = await LocalProfileRepository(database).getOrCreateMarco();
  return profile.id;
}

Future<void> _seedRoutinePlannedToday(
  AppDatabase database,
  String profileId, {
  required String name,
  bool liveRoutine = true,
}) async {
  final now = AppTime.nowUtc();
  final weekday = AppTime.nowInRome().weekday;
  if (liveRoutine) {
    await database
        .into(database.routines)
        .insert(
          RoutinesCompanion.insert(
            id: 'routine-1',
            profileId: profileId,
            name: name,
            createdAt: now,
            updatedAt: now,
          ),
        );
  }
  await database
      .into(database.routineWeeklyPlan)
      .insert(
        RoutineWeeklyPlanCompanion.insert(
          id: 'plan-$weekday',
          profileId: profileId,
          weekday: weekday,
          routineId: Value(liveRoutine ? 'routine-1' : null),
          routineExternalId: const Value('routine-1'),
          routineNameSnapshot: Value(name),
          updatedAt: now,
        ),
      );
}

void main() {
  setUpAll(() => initializeDateFormatting('it'));
  setUp(AppTime.initialize);

  testWidgets('lo stato vuoto si legge senza scorrere e il FAB non lo copre', (
    tester,
  ) async {
    _usePhone(tester);
    final database = AppDatabase(NativeDatabase.memory());

    await tester.pumpWidget(_host(database));
    await tester.pumpAndSettle();

    final empty = find.text(PlayfulDiaryEmptyState.message);
    expect(empty, findsOneWidget);

    final viewport = tester.getSize(find.byType(Scaffold)).height;
    final emptyRect = tester.getRect(empty);
    final fabRect = tester.getRect(find.byKey(const Key('add_food_button')));

    expect(
      emptyRect.bottom,
      lessThanOrEqualTo(viewport),
      reason: 'l\'invito deve stare nel primo schermo, senza scorrere',
    );
    expect(
      fabRect.overlaps(emptyRect),
      isFalse,
      reason: 'il FAB esteso non deve coprire l\'invito',
    );

    await _dispose(tester, database);
  });

  testWidgets('in fondo alla lista resta spazio sotto il FAB', (tester) async {
    _usePhone(tester);
    final database = AppDatabase(NativeDatabase.memory());

    await tester.pumpWidget(_host(database));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -4000),
    );
    await tester.pumpAndSettle();

    final last = tester.getRect(
      find.byKey(const Key('photo_meal_button_snack')),
    );
    final fabRect = tester.getRect(find.byKey(const Key('add_food_button')));
    expect(fabRect.overlaps(last), isFalse);

    await _dispose(tester, database);
  });

  testWidgets(
    'senza obiettivo, senza pesate e senza piano la schermata regge',
    (tester) async {
      _usePhone(tester);
      final database = AppDatabase(NativeDatabase.memory());

      await tester.pumpWidget(_host(database));
      await tester.pumpAndSettle();

      // Niente piano, niente sessione aperta: la palestra non parla.
      expect(find.byKey(const Key('today_training_planned')), findsNothing);
      expect(find.byKey(const Key('today_training_open')), findsNothing);
      expect(find.byKey(const Key('today_training_rest')), findsNothing);
      // Il check-in invita alla pesata invece di mostrare un buco.
      expect(find.byKey(const Key('check_in_weight_missing')), findsOneWidget);
      expect(tester.takeException(), isNull);

      await _dispose(tester, database);
    },
  );

  testWidgets('le proteine rimanenti stanno in evidenza', (tester) async {
    _usePhone(tester);
    final database = AppDatabase(NativeDatabase.memory());
    final profileId = await _seedProfile(database);
    await DiaryRepository(database).addManualFood(
      profileId: profileId,
      input: ManualFoodInput(
        foodName: 'Petto di pollo',
        grams: 200,
        per100g: const Nutrients(
          calories: 165,
          protein: 31,
          carbs: 0,
          fat: 3.6,
        ),
        mealType: MealType.lunch,
        eatenAt: AppTime.nowInRome(),
      ),
    );

    await tester.pumpWidget(_host(database));
    await tester.pumpAndSettle();

    // Obiettivo standard: 120 g di proteine, 62 mangiate, 58 ancora.
    expect(
      tester.widget<Text>(find.byKey(const Key('remaining_protein'))).data,
      '58 g ancora',
    );

    await _dispose(tester, database);
  });

  testWidgets('l\'allenamento previsto per oggi compare con l\'azione', (
    tester,
  ) async {
    _usePhone(tester);
    final database = AppDatabase(NativeDatabase.memory());
    final profileId = await _seedProfile(database);
    await _seedRoutinePlannedToday(
      database,
      profileId,
      name: 'Giorno1 spalle petto tricipiti',
    );

    await tester.pumpWidget(_host(database));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('today_training_planned')), findsOneWidget);
    expect(find.text('Giorno1 spalle petto tricipiti'), findsOneWidget);
    expect(
      find.byKey(const Key('today_training_start_button')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('today_training_missing_note')), findsNothing);

    await _dispose(tester, database);
  });

  testWidgets('Inizia da Oggi crea la sessione e apre Live', (tester) async {
    _usePhone(tester);
    final database = AppDatabase(NativeDatabase.memory());
    final profileId = await _seedProfile(database);
    await _seedRoutinePlannedToday(
      database,
      profileId,
      name: 'Sessione da Oggi',
    );
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const TodayDiaryScreen()),
        GoRoute(
          path: '/workout/:id',
          builder: (_, state) => Scaffold(
            key: const Key('fake_live_workout'),
            body: Text(state.pathParameters['id']!),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          appConfigProvider.overrideWithValue(const AppConfig.offline()),
          checkInStoreProvider.overrideWithValue(InMemoryCheckInStore()),
        ],
        child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    final start = find.byKey(const Key('today_training_start_button'));
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('fake_live_workout')), findsOneWidget);
    final open = await (database.select(
      database.workouts,
    )..where((row) => row.endedAt.isNull())).getSingle();
    expect(open.routineId, 'routine-1');
    expect(open.routineNameSnapshot, 'Sessione da Oggi');

    await _dispose(tester, database);
  });

  testWidgets('una scheda cancellata resta annunciata, senza fingere', (
    tester,
  ) async {
    _usePhone(tester);
    final database = AppDatabase(NativeDatabase.memory());
    final profileId = await _seedProfile(database);
    await _seedRoutinePlannedToday(
      database,
      profileId,
      name: 'Scheda sparita',
      liveRoutine: false,
    );

    await tester.pumpWidget(_host(database));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('today_training_missing_note')),
      findsOneWidget,
    );

    await _dispose(tester, database);
  });

  testWidgets('la sessione aperta ha la precedenza sul piano', (tester) async {
    _usePhone(tester);
    final database = AppDatabase(NativeDatabase.memory());
    final profileId = await _seedProfile(database);
    await _seedRoutinePlannedToday(database, profileId, name: 'Giorno 1');
    final now = AppTime.nowUtc();
    await database
        .into(database.workouts)
        .insert(
          WorkoutsCompanion.insert(
            id: 'workout-aperto',
            profileId: profileId,
            startedAt: now.subtract(const Duration(minutes: 20)),
            routineNameSnapshot: const Value('Giorno 1'),
            createdAt: now,
            updatedAt: now,
          ),
        );

    await tester.pumpWidget(_host(database));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('today_training_open')), findsOneWidget);
    expect(find.byKey(const Key('today_training_planned')), findsNothing);
    expect(
      find.byKey(const Key('today_training_resume_button')),
      findsOneWidget,
    );

    await _dispose(tester, database);
  });

  testWidgets('il piano che oggi non prevede niente dice «riposo»', (
    tester,
  ) async {
    _usePhone(tester);
    final database = AppDatabase(NativeDatabase.memory());
    final profileId = await _seedProfile(database);
    final now = AppTime.nowUtc();
    // Il piano esiste ma su un altro giorno della settimana.
    final otherWeekday = AppTime.nowInRome().weekday == 7
        ? 1
        : AppTime.nowInRome().weekday + 1;
    await database
        .into(database.routineWeeklyPlan)
        .insert(
          RoutineWeeklyPlanCompanion.insert(
            id: 'plan-altro',
            profileId: profileId,
            weekday: otherWeekday,
            routineExternalId: const Value('routine-9'),
            routineNameSnapshot: const Value('Giorno 2'),
            updatedAt: now,
          ),
        );

    await tester.pumpWidget(_host(database));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('today_training_rest')), findsOneWidget);

    await _dispose(tester, database);
  });

  testWidgets('Oggi reagisce quando cambia il piano settimanale', (
    tester,
  ) async {
    _usePhone(tester);
    final database = AppDatabase(NativeDatabase.memory());
    final profileId = await _seedProfile(database);
    final now = AppTime.nowUtc();
    await database
        .into(database.routines)
        .insert(
          RoutinesCompanion.insert(
            id: 'routine-reactive',
            profileId: profileId,
            name: 'Gambe reattive',
            createdAt: now,
            updatedAt: now,
          ),
        );

    await tester.pumpWidget(_host(database));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('today_training_planned')), findsNothing);

    await WorkoutPlanRepository(database).setDay(
      profileId: profileId,
      weekday: AppTime.nowInRome().weekday,
      routineId: 'routine-reactive',
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('today_training_planned')), findsOneWidget);
    expect(find.text('Gambe reattive'), findsOneWidget);

    await WorkoutPlanRepository(
      database,
    ).clearDay(profileId: profileId, weekday: AppTime.nowInRome().weekday);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('today_training_planned')), findsNothing);
    await _dispose(tester, database);
  });

  testWidgets('le ricette che ci stanno sono su Oggi, non sepolte', (
    tester,
  ) async {
    _usePhone(tester);
    final database = AppDatabase(NativeDatabase.memory());

    await tester.pumpWidget(_host(database));
    await tester.pumpAndSettle();

    final card = find.byKey(const Key('today_recipes_card'));
    expect(card, findsOneWidget);
    // Il motore ne propone al massimo tre: la scelta è il punto, l'elenco no.
    final rows = tester
        .widgetList<Widget>(
          find.byWidgetPredicate(
            (widget) =>
                widget.key is ValueKey<String> &&
                (widget.key! as ValueKey<String>).value.startsWith(
                  'today_recipe_',
                ),
          ),
        )
        .length;
    expect(rows, inInclusiveRange(1, TodayRecipesCard.maxSuggestions));

    await _dispose(tester, database);
  });

  testWidgets('il check-in salva sonno ed energia con un tocco', (
    tester,
  ) async {
    _usePhone(tester);
    final database = AppDatabase(NativeDatabase.memory());
    final store = InMemoryCheckInStore();

    await tester.pumpWidget(_host(database, checkInStore: store));
    await tester.pumpAndSettle();

    final plus = find.byKey(const Key('check_in_sleep_plus'));
    await tester.ensureVisible(plus);
    await tester.pumpAndSettle();
    await tester.tap(plus);
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('check_in_sleep_value'))).data,
      '7,5 h',
    );

    final energy = find.byKey(const Key('check_in_energy_4'));
    await tester.ensureVisible(energy);
    await tester.pumpAndSettle();
    await tester.tap(energy);
    await tester.pumpAndSettle();

    final log = await store.read();
    final entry = log.forDay(checkInDayOf(AppTime.nowInRome()))!;
    expect(entry.sleepHours, 7.5);
    expect(entry.energyScore, 4);
    // Completo: la card si richiude in una riga di riepilogo.
    expect(find.byKey(const Key('check_in_summary')), findsOneWidget);

    await _dispose(tester, database);
  });

  testWidgets('le card nuove reggono il tema scuro e il testo al 150%', (
    tester,
  ) async {
    _usePhone(tester);
    final database = AppDatabase(NativeDatabase.memory());
    final profileId = await _seedProfile(database);
    await _seedRoutinePlannedToday(database, profileId, name: 'Giorno 1');

    await tester.pumpWidget(
      _host(database, theme: AppTheme.dark, textScale: 1.5),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('today_training_planned')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _dispose(tester, database);
  });

  testWidgets('guardando ieri le card di oggi spariscono', (tester) async {
    _usePhone(tester);
    final database = AppDatabase(NativeDatabase.memory());
    final profileId = await _seedProfile(database);
    await _seedRoutinePlannedToday(database, profileId, name: 'Giorno 1');

    await tester.pumpWidget(_host(database));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('today_training_planned')), findsOneWidget);

    await tester.tap(find.byKey(const Key('previous_day_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('today_training_planned')), findsNothing);
    expect(find.byKey(const Key('morning_check_in_card')), findsNothing);
    expect(find.byKey(const Key('today_recipes_card')), findsNothing);

    await _dispose(tester, database);
  });
}
