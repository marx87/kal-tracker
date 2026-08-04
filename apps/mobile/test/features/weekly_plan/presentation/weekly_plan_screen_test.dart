import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/app.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/data/diary_repository.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/recipes/data/recipe_repository.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';
import 'package:kal_tracker/features/targets/domain/nutrition_target.dart';
import 'package:kal_tracker/features/weekly_plan/data/weekly_plan_gateway.dart';
import 'package:kal_tracker/features/weekly_plan/data/weekly_plan_repository.dart';
import 'package:kal_tracker/features/weekly_plan/domain/weekly_plan_models.dart';

class _FakeGateway implements WeeklyPlanGateway {
  WeeklyPlanAccount? account = const WeeklyPlanAccount(userId: 'owner-1');

  Map<String, Object?>? insertedRow;
  Map<String, Object?>? remoteRow;

  @override
  Future<WeeklyPlanAccount?> currentAccount() async => account;

  @override
  Future<String> ensureRemoteProfile(String localProfileId) async =>
      'remote-profile-1';

  @override
  Future<void> enqueueJob(Map<String, Object?> row) async => insertedRow = row;

  @override
  Future<Map<String, Object?>?> fetchJobRow(String jobId) async => remoteRow;
}

final _startDate = DateTime.utc(2026, 8, 5);

/// Orologio del piano già pronto: il tentativo fallito che segue è più
/// recente, così l'ordine dei piani nella lista è deciso, non casuale.
final _seedClock = DateTime.utc(2026, 8, 4, 9);

void main() {
  testWidgets('la schermata di avvio chiede pasti, giorni e note e accoda '
      'il piano', (tester) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final gateway = _FakeGateway();

    await tester.pumpWidget(_app(database, gateway));
    await tester.pumpAndSettle();
    await _openPlanTab(tester);

    expect(find.byKey(const Key('weekly_plan_form')), findsOneWidget);
    for (final meal in PlanMeal.values) {
      expect(
        find.byKey(Key('plan_meal_${meal.storageValue}')),
        findsOneWidget,
        reason: 'manca la casella di ${meal.label}',
      );
    }
    expect(
      tester.widget<ChoiceChip>(find.byKey(const Key('plan_days_7'))).selected,
      isTrue,
      reason: 'sette giorni è il valore di partenza',
    );
    // Nessun piano ancora: niente attesa e niente errori.
    expect(find.byKey(const Key('plan_generating_card')), findsNothing);
    expect(find.byKey(const Key('plan_failed_card')), findsNothing);

    await tester.tap(find.byKey(const Key('plan_meal_colazione')));
    await tester.tap(find.byKey(const Key('plan_meal_spuntino')));
    await tester.pumpAndSettle();

    final notes = find.byKey(const Key('plan_notes_field'));
    await tester.ensureVisible(notes);
    await tester.pumpAndSettle();
    await tester.enterText(notes, '  niente funghi  ');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();

    await _tap(tester, const Key('generate_plan_button'));

    final request = gateway.insertedRow!['request']! as Map<String, Object?>;
    expect(request['meals'], ['pranzo', 'cena', 'spuntino']);
    expect(request['days'], 7);
    expect(request['notes'], 'niente funghi');
    // Il catalogo REALE viaggia con la richiesta: l'AI sceglie solo qui.
    expect(request['recipes'], isA<List<Object?>>());
    expect((request['recipes']! as List).isNotEmpty, isTrue);

    // Attesa non bloccante: si può uscire e tornare.
    expect(find.byKey(const Key('plan_generating_card')), findsOneWidget);
    expect(find.textContaining('Il Mac sta preparando il piano'), findsWidgets);

    await _disposeApp(tester, database);
  });

  testWidgets('senza accesso al cloud il messaggio invita ad accedere', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final gateway = _FakeGateway()..account = null;

    await tester.pumpWidget(_app(database, gateway));
    await tester.pumpAndSettle();
    await _openPlanTab(tester);

    await _tap(tester, const Key('generate_plan_button'));

    expect(find.byKey(const Key('weekly_plan_error')), findsOneWidget);
    expect(find.textContaining('Progressi → Sincronizzazione'), findsOneWidget);
    expect(gateway.insertedRow, isNull);

    await _disposeApp(tester, database);
  });

  testWidgets('il piano pronto mostra i valori calcolati e "Fatto" scrive '
      'nel diario', (tester) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final gateway = _FakeGateway();
    final seed = await _seed(tester, database, gateway);
    final plan = seed.plan;
    final lunch = plan.slotsFor(_startDate).first;

    await tester.pumpWidget(_app(database, gateway));
    await tester.pumpAndSettle();
    await _openPlanTab(tester);

    expect(find.byKey(const Key('weekly_plan_header')), findsOneWidget);
    expect(find.text('Il tuo piano di 2 giorni'), findsOneWidget);
    expect(find.text('Settimana leggera a cena.'), findsOneWidget);
    expect(find.byKey(const Key('open_shopping_list')), findsOneWidget);
    // Nessun piano da generare: il modulo resta chiuso.
    expect(find.byKey(const Key('weekly_plan_form')), findsNothing);

    // 515 kcal a porzione × 1,5: numeri dell'app, non del modello (che
    // aveva provato a infilare un 'kcal' nel risultato).
    expect(
      _textOf(tester, Key('plan_slot_macros_${lunch.id}')),
      '1,5 porzioni · 773 kcal · P 57.0 · C 117.0 · G 7.5',
    );
    expect(find.text('999 kcal'), findsNothing);
    expect(
      _textOf(tester, const Key('plan_day_total_2026-08-05')),
      '947 / 2.000 kcal',
    );
    expect(find.byKey(Key('plan_slot_why_${lunch.id}')), findsOneWidget);
    expect(find.text('Proteine alte a metà giornata'), findsOneWidget);

    await _tap(tester, Key('plan_slot_done_${lunch.id}'));

    final diary = DiaryRepository(database);
    var entries = await diary.entriesForMeal(
      profileId: seed.profileId,
      day: _startDate,
      mealType: MealType.lunch,
    );
    expect(entries, hasLength(1));
    expect(entries.single.foodName, 'Riso e pollo · 1,5 porzioni');
    expect(entries.single.nutrients.calories, closeTo(772.5, 0.1));
    expect(find.byKey(Key('plan_slot_undo_${lunch.id}')), findsOneWidget);
    expect(find.byKey(Key('plan_slot_done_${lunch.id}')), findsNothing);

    // «Annulla» dalla snackbar: la voce esce dal diario e lo slot si riapre.
    await tester.tap(find.text('Annulla').first);
    await tester.pumpAndSettle();

    entries = await diary.entriesForMeal(
      profileId: seed.profileId,
      day: _startDate,
      mealType: MealType.lunch,
    );
    expect(entries, isEmpty);
    expect(find.byKey(Key('plan_slot_done_${lunch.id}')), findsOneWidget);

    await _disposeApp(tester, database);
  });

  testWidgets('"Sostituisci" sceglie un\'altra ricetta del ricettario', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final gateway = _FakeGateway();
    final seed = await _seed(tester, database, gateway);
    final lunch = seed.plan.slotsFor(_startDate).first;

    await tester.pumpWidget(_app(database, gateway));
    await tester.pumpAndSettle();
    await _openPlanTab(tester);

    await _tap(tester, Key('plan_slot_replace_${lunch.id}'));

    expect(find.byKey(const Key('plan_replace_sheet')), findsOneWidget);
    await _tap(tester, Key('plan_replace_option_${seed.soupId}'));

    expect(
      _textOf(tester, Key('plan_slot_recipe_${lunch.id}')),
      'Zuppa di lenticchie',
    );
    // La motivazione parlava della ricetta di prima: sparisce.
    expect(find.byKey(Key('plan_slot_why_${lunch.id}')), findsNothing);

    await _disposeApp(tester, database);
  });

  testWidgets('dallo slot si apre la ricetta vera', (tester) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final gateway = _FakeGateway();
    final seed = await _seed(tester, database, gateway);
    final lunch = seed.plan.slotsFor(_startDate).first;

    await tester.pumpWidget(_app(database, gateway));
    await tester.pumpAndSettle();
    await _openPlanTab(tester);

    await _tap(tester, Key('plan_slot_open_${lunch.id}'));

    expect(find.text('Dettaglio ricetta'), findsOneWidget);
    expect(find.byKey(const Key('recipe_detail_list')), findsOneWidget);
    expect(find.text('Riso e pollo'), findsWidgets);

    await _disposeApp(tester, database);
  });

  testWidgets('col Mac spento il messaggio è onesto e il piano vecchio '
      'resta consultabile', (tester) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final gateway = _FakeGateway();
    final seed = await _seed(tester, database, gateway);

    // Secondo tentativo: il Mac non prende mai in carico il job.
    await tester.runAsync(() async {
      var clock = _seedClock.add(const Duration(hours: 3));
      final repository = WeeklyPlanRepository(
        database,
        gateway: gateway,
        now: () => clock,
      );
      final pending = await repository.generatePlan(
        profileId: seed.profileId,
        startDate: _startDate,
        days: 2,
        meals: const [PlanMeal.pranzo, PlanMeal.cena],
        targets: const NutritionTarget.standard(),
      );
      gateway.remoteRow = {'id': pending.remoteJobId, 'status': 'queued'};
      clock = clock.add(WeeklyPlanRepository.queuedTimeout * 2);
      await repository.refreshPlan(pending.id);
      gateway.remoteRow = null;
    });

    await tester.pumpWidget(_app(database, gateway));
    await tester.pumpAndSettle();
    await _openPlanTab(tester);

    expect(find.byKey(const Key('plan_failed_card')), findsOneWidget);
    expect(find.textContaining('Il Mac non ha risposto'), findsOneWidget);
    expect(find.byKey(const Key('plan_retry_button')), findsOneWidget);
    // Il piano già generato resta lì, leggibile.
    expect(find.byKey(const Key('weekly_plan_header')), findsOneWidget);
    expect(
      find.byKey(Key('plan_slot_${seed.plan.slots.first.id}')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('plan_retry_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('weekly_plan_form')), findsOneWidget);

    await _disposeApp(tester, database);
  });
}

typedef _Seed = ({
  String profileId,
  String riceId,
  String soupId,
  WeeklyPlan plan,
});

/// Un piano pronto di 2 giorni × pranzo e cena, generato e materializzato
/// dal repository vero (stesso percorso del telefono di Marco).
Future<_Seed> _seedReadyPlan(AppDatabase database, _FakeGateway gateway) async {
  final profile = await LocalProfileRepository(database).getOrCreateMarco();
  final recipes = RecipeRepository(database);
  final riceId = await recipes.createRecipe(
    profileId: profile.id,
    draft: FitRecipeDraft(
      name: 'Riso e pollo',
      servings: 2,
      prepMinutes: 25,
      tags: const ['pranzo'],
      ingredients: [
        RecipeIngredientDraft(
          name: 'Riso',
          grams: 200,
          per100g: const Nutrients(
            calories: 350,
            protein: 7,
            carbs: 78,
            fat: 1,
          ),
        ),
        RecipeIngredientDraft(
          name: 'Pollo',
          grams: 200,
          per100g: const Nutrients(
            calories: 165,
            protein: 31,
            carbs: 0,
            fat: 4,
          ),
        ),
      ],
    ),
  );
  final soupId = await recipes.createRecipe(
    profileId: profile.id,
    draft: FitRecipeDraft(
      name: 'Zuppa di lenticchie',
      servings: 2,
      prepMinutes: 40,
      tags: const ['pranzo', 'cena'],
      ingredients: [
        RecipeIngredientDraft(
          name: 'Lenticchie',
          grams: 300,
          per100g: const Nutrients(
            calories: 116,
            protein: 9,
            carbs: 20,
            fat: 0.4,
          ),
        ),
      ],
    ),
  );

  final repository = WeeklyPlanRepository(
    database,
    gateway: gateway,
    recipeRepository: recipes,
    now: () => _seedClock,
  );
  final plan = await repository.generatePlan(
    profileId: profile.id,
    startDate: _startDate,
    days: 2,
    meals: const [PlanMeal.pranzo, PlanMeal.cena],
    targets: const NutritionTarget.standard(),
  );
  gateway.remoteRow = {
    'id': plan.remoteJobId,
    'status': 'needs_review',
    'result': {
      'schema': 1,
      'days': [
        {
          'date': '2026-08-05',
          'slots': [
            {
              'meal': 'pranzo',
              'recipeId': riceId,
              'servings': 1.5,
              'why': 'Proteine alte a metà giornata',
              // Numero del modello: va ignorato, mai mostrato.
              'kcal': 999,
            },
            {'meal': 'cena', 'recipeId': soupId, 'servings': 1},
          ],
        },
        {
          'date': '2026-08-06',
          'slots': [
            {'meal': 'pranzo', 'recipeId': soupId, 'servings': 2},
            {'meal': 'cena', 'recipeId': riceId, 'servings': 1},
          ],
        },
      ],
      'notes': 'Settimana leggera a cena.',
    },
  };
  final ready = (await repository.refreshPlan(plan.id))!;
  gateway.remoteRow = null;
  return (profileId: profile.id, riceId: riceId, soupId: soupId, plan: ready);
}

/// Il seeding usa il database vero: va fatto fuori dallo zone finto dei
/// widget test, altrimenti gli stream di drift non emettono mai.
Future<_Seed> _seed(
  WidgetTester tester,
  AppDatabase database,
  _FakeGateway gateway,
) async => (await tester.runAsync(() => _seedReadyPlan(database, gateway)))!;

/// Porta il bersaglio a schermo, aspetta lo scorrimento e tocca.
Future<void> _tap(WidgetTester tester, Key key) async {
  final target = find.byKey(key);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _openPlanTab(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('nav_plan')));
  await tester.pumpAndSettle();
}

String? _textOf(WidgetTester tester, Key key) =>
    tester.widget<Text>(find.byKey(key)).data;

Widget _app(AppDatabase database, WeeklyPlanGateway gateway) => ProviderScope(
  overrides: [
    databaseProvider.overrideWithValue(database),
    appConfigProvider.overrideWithValue(const AppConfig.offline()),
    weeklyPlanGatewayProvider.overrideWithValue(gateway),
  ],
  child: const KalTrackerApp(),
);

Future<void> _disposeApp(WidgetTester tester, AppDatabase database) async {
  // Smaltisce il timer di chiusura forzata delle snackbar con azione
  // (showAutoClosingSnackBar), altrimenti il teardown fallisce.
  await tester.pump(const Duration(seconds: 9));
  await tester.pumpAndSettle();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(database.close);
}
