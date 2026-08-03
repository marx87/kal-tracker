import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/diary_number_field.dart';
import 'package:kal_tracker/features/photo_meal/data/photo_meal_job_store.dart';
import 'package:kal_tracker/features/photo_meal/data/photo_meal_repository.dart';
import 'package:kal_tracker/features/photo_meal/presentation/meal_analysis_result.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_jobs_gateway.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_meal_job.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_review_local_store.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_review_screen.dart';

import 'photo_meal_fakes.dart';

PhotoMealJob _twoFoodsJob() => buildReviewJob(
  foods: [
    buildFood(),
    buildFood(
      name: 'Pollo alla griglia',
      alternatives: const [],
      minimumGrams: 80,
      suggestedGrams: 120,
      maximumGrams: 200,
      confidence: 0.6,
      preparation: 'grilled',
      hiddenIngredients: const [],
      uncertainty: '',
    ),
  ],
);

/// Risultato del worker nuovo: entrambe le voci con le stime per 100 g.
/// Riso 130 kcal × 150 g → 195; pollo 165 kcal × 120 g → 198.
PhotoMealJob _estimatedJob() => buildReviewJob(
  foods: [
    buildFood(
      per100g: const MealAnalysisPer100g(
        energyKcal: 130,
        proteinG: 2,
        carbsG: 28,
        fatG: 0.4,
      ),
    ),
    buildFood(
      name: 'Pollo alla griglia',
      alternatives: const [],
      minimumGrams: 80,
      suggestedGrams: 120,
      maximumGrams: 200,
      confidence: 0.6,
      preparation: 'grilled',
      hiddenIngredients: const [],
      uncertainty: '',
      per100g: const MealAnalysisPer100g(
        energyKcal: 165,
        proteinG: 30,
        carbsG: 0,
        fatG: 5,
      ),
    ),
  ],
);

String _numberFieldText(WidgetTester tester, String key) =>
    tester.widget<DiaryNumberField>(find.byKey(Key(key))).controller.text;

Widget _app({
  required AppDatabase database,
  required FakePhotoJobsGateway gateway,
  required InMemoryPhotoReviewLocalStore store,
  PhotoMealJobStore? jobStore,
  String jobId = 'job-1',
}) => ProviderScope(
  overrides: [
    databaseProvider.overrideWithValue(database),
    appConfigProvider.overrideWithValue(const AppConfig.offline()),
    photoJobsGatewayProvider.overrideWithValue(gateway),
    photoReviewLocalStoreProvider.overrideWithValue(store),
    // Sempre in memoria: il file store reale non risolve nei test widget.
    photoMealJobStoreProvider.overrideWithValue(
      jobStore ?? InMemoryPhotoMealJobStore(),
    ),
  ],
  child: MaterialApp(home: PhotoReviewScreen(jobId: jobId)),
);

Future<void> _disposeApp(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(database.close);
}

void main() {
  testWidgets('mostra le proposte e ricalcola l’anteprima con i grammi', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final gateway = FakePhotoJobsGateway([
      [_twoFoodsJob()],
    ]);
    final store = InMemoryPhotoReviewLocalStore();

    await tester.pumpWidget(
      _app(database: database, gateway: gateway, store: store),
    );
    await tester.pumpAndSettle();

    // Entrambe le proposte del modello sono visibili con i loro dati.
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('food_name_0')))
          .controller!
          .text,
      'Riso basmati',
    );
    expect(find.text('Fiducia 80%'), findsOneWidget);
    expect(find.text('Bollito'), findsOneWidget);
    expect(find.text('Forse: Riso venere'), findsOneWidget);
    expect(find.text('Fiducia 60%'), findsOneWidget);

    final gramsField = find.byKey(const Key('food_grams_0'));
    expect(tester.widget<DiaryNumberField>(gramsField).controller.text, '150');

    // L'anteprima usa NutritionCalculator: 130 kcal/100 g × 150 g = 195.
    await tester.enterText(find.byKey(const Key('food_calories_0')), '130');
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const Key('food_preview_0'))).data,
      '195 kcal · P 0.0 · C 0.0 · G 0.0',
    );

    // Cambiare i grammi ricalcola: 130 × 200 / 100 = 260.
    await tester.enterText(gramsField, '200');
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const Key('food_preview_0'))).data,
      '260 kcal · P 0.0 · C 0.0 · G 0.0',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('review_totals'))).data,
      'Totale selezionato: 260 kcal · P 0.0 · C 0.0 · G 0.0',
    );

    // Un'alternativa sostituisce il nome senza salvare nulla.
    tester.testTextInput.hide();
    final alternativeChip = find.byKey(const Key('food_alternative_0_0'));
    await tester.ensureVisible(alternativeChip);
    await tester.pumpAndSettle();
    await tester.tap(alternativeChip);
    await tester.pump();
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('food_name_0')))
          .controller!
          .text,
      'Riso venere',
    );

    await _disposeApp(tester, database);
  });

  testWidgets('le stime per 100 g precompilano la revisione e ricalcolano '
      'al cambio grammi', (tester) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final gateway = FakePhotoJobsGateway([
      [_estimatedJob()],
    ]);
    final store = InMemoryPhotoReviewLocalStore();

    await tester.pumpWidget(
      _app(database: database, gateway: gateway, store: store),
    );
    await tester.pumpAndSettle();

    // I campi per 100 g partono dalle stime del modello, modificabili.
    expect(_numberFieldText(tester, 'food_calories_0'), '130');
    expect(_numberFieldText(tester, 'food_protein_0'), '2');
    expect(_numberFieldText(tester, 'food_carbs_0'), '28');
    expect(_numberFieldText(tester, 'food_fat_0'), '0.4');

    // Le kcal per voce sono CALCOLATE (mai del modello) e presentate
    // come stime da verificare.
    expect(
      tester.widget<Text>(find.byKey(const Key('food_preview_0'))).data,
      '≈ 195 kcal · P 3.0 · C 42.0 · G 0.6 · stima da foto',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('food_preview_1'))).data,
      '≈ 198 kcal · P 36.0 · C 0.0 · G 6.0 · stima da foto',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('review_totals'))).data,
      'Totale selezionato: ≈ 393 kcal · P 39.0 · C 42.0 · G 6.6',
    );

    // Cambiare i grammi ricalcola voce e totale: 130 × 200 / 100 = 260.
    await tester.enterText(find.byKey(const Key('food_grams_0')), '200');
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const Key('food_preview_0'))).data,
      '≈ 260 kcal · P 4.0 · C 56.0 · G 0.8 · stima da foto',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('review_totals'))).data,
      'Totale selezionato: ≈ 458 kcal · P 40.0 · C 56.0 · G 6.8',
    );

    // Il totale in alto conta le SOLE voci selezionate.
    tester.testTextInput.hide();
    await tester.pump();
    final secondCheckbox = find.byKey(const Key('food_selected_1'));
    await tester.ensureVisible(secondCheckbox);
    await tester.pumpAndSettle();
    await tester.tap(secondCheckbox);
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const Key('review_totals'))).data,
      'Totale selezionato: ≈ 260 kcal · P 4.0 · C 56.0 · G 0.8',
    );

    await _disposeApp(tester, database);
  });

  testWidgets('un risultato vecchio senza per100g parte con i campi da '
      'compilare, come oggi', (tester) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final gateway = FakePhotoJobsGateway([
      [_twoFoodsJob()],
    ]);
    final store = InMemoryPhotoReviewLocalStore();

    await tester.pumpWidget(
      _app(database: database, gateway: gateway, store: store),
    );
    await tester.pumpAndSettle();

    // Nessun crash e nessuna stima inventata: valori a zero da compilare.
    expect(_numberFieldText(tester, 'food_calories_0'), '0');
    expect(_numberFieldText(tester, 'food_protein_0'), '0');
    expect(_numberFieldText(tester, 'food_carbs_0'), '0');
    expect(_numberFieldText(tester, 'food_fat_0'), '0');
    expect(find.textContaining('stima da foto'), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const Key('food_preview_0'))).data,
      '0 kcal · P 0.0 · C 0.0 · G 0.0',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('review_totals'))).data,
      'Totale selezionato: 0 kcal · P 0.0 · C 0.0 · G 0.0',
    );

    await _disposeApp(tester, database);
  });

  testWidgets('la conferma salva i valori corretti da Marco, non le stime '
      'della foto', (tester) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final gateway = FakePhotoJobsGateway([
      [_estimatedJob()],
    ]);
    final store = InMemoryPhotoReviewLocalStore();

    await tester.pumpWidget(
      _app(database: database, gateway: gateway, store: store),
    );
    await tester.pumpAndSettle();

    // Marco corregge la stima delle kcal: 130 → 110 per 100 g.
    await tester.enterText(find.byKey(const Key('food_calories_0')), '110');
    tester.testTextInput.hide();
    await tester.pump();

    final secondCheckbox = find.byKey(const Key('food_selected_1'));
    await tester.ensureVisible(secondCheckbox);
    await tester.pumpAndSettle();
    await tester.tap(secondCheckbox);
    await tester.pump();

    final confirmButton = find.byKey(const Key('confirm_review_button'));
    await tester.ensureVisible(confirmButton);
    await tester.pumpAndSettle();
    await tester.tap(confirmButton);
    await tester.pumpAndSettle();

    // Nel diario entra il valore corretto, non quello proposto dal modello.
    final item = (await database.select(database.mealItems).get()).single;
    expect(item.caloriesPer100g, 110);
    expect(item.grams, 150);
    expect(item.totalCalories, closeTo(165, 0.001));
    expect(item.totalProtein, closeTo(3, 0.001));
    expect(item.totalCarbs, closeTo(42, 0.001));
    expect(item.totalFat, closeTo(0.6, 0.001));

    await _disposeApp(tester, database);
  });

  testWidgets('conferma inserisce SOLO le voci selezionate con i totali '
      'esatti', (tester) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final gateway = FakePhotoJobsGateway([
      [_twoFoodsJob()],
    ]);
    final store = InMemoryPhotoReviewLocalStore();

    await tester.pumpWidget(
      _app(database: database, gateway: gateway, store: store),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('food_calories_0')), '130');
    await tester.enterText(find.byKey(const Key('food_protein_0')), '2,7');
    await tester.enterText(find.byKey(const Key('food_carbs_0')), '28');
    await tester.enterText(find.byKey(const Key('food_fat_0')), '0,3');
    tester.testTextInput.hide();
    await tester.pump();

    // La seconda proposta viene deselezionata: NON deve entrare nel diario.
    final secondCheckbox = find.byKey(const Key('food_selected_1'));
    await tester.ensureVisible(secondCheckbox);
    await tester.pumpAndSettle();
    await tester.tap(secondCheckbox);
    await tester.pump();
    expect(find.text('Esclusa dal diario'), findsOneWidget);

    final confirmButton = find.byKey(const Key('confirm_review_button'));
    await tester.ensureVisible(confirmButton);
    await tester.pumpAndSettle();
    await tester.tap(confirmButton);
    await tester.pumpAndSettle();

    final items = await database.select(database.mealItems).get();
    expect(items, hasLength(1));
    final item = items.single;
    expect(item.foodName, 'Riso basmati');
    expect(item.grams, 150);
    expect(item.caloriesPer100g, 130);
    expect(item.totalCalories, closeTo(195, 0.001));
    expect(item.totalProtein, closeTo(4.05, 0.001));
    expect(item.totalCarbs, closeTo(42, 0.001));
    expect(item.totalFat, closeTo(0.45, 0.001));

    final meals = await database.select(database.meals).get();
    expect(meals.single.mealType, 'lunch');

    // Chiusura locale del job: registro aggiornato e foto rimossa.
    expect(store.outcomes, {'job-1': 'confirmed'});
    expect(gateway.deletedPhotos, ['owner-1/job-1/meal.jpg']);
    expect(find.text('Fatto'), findsOneWidget);

    await _disposeApp(tester, database);
  });

  testWidgets('la conferma registra le voci nel giorno per cui la foto '
      'era stata scattata', (tester) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final gateway = FakePhotoJobsGateway([
      [_twoFoodsJob()],
    ]);
    final store = InMemoryPhotoReviewLocalStore();
    // La foto era per IERI (registro locale del diario): la conferma di
    // oggi non deve spostare la cena nel giorno sbagliato.
    final yesterday = DiaryDay.shift(AppTime.nowInRome(), -1);
    final jobStore = InMemoryPhotoMealJobStore([
      buildLocalJob(day: DiaryDay.instantFor(yesterday)),
    ]);

    await tester.pumpWidget(
      _app(
        database: database,
        gateway: gateway,
        store: store,
        jobStore: jobStore,
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('food_calories_0')), '130');
    tester.testTextInput.hide();
    await tester.pump();

    final secondCheckbox = find.byKey(const Key('food_selected_1'));
    await tester.ensureVisible(secondCheckbox);
    await tester.pumpAndSettle();
    await tester.tap(secondCheckbox);
    await tester.pump();

    final confirmButton = find.byKey(const Key('confirm_review_button'));
    await tester.ensureVisible(confirmButton);
    await tester.pumpAndSettle();
    await tester.tap(confirmButton);
    await tester.pumpAndSettle();

    final meals = await database.select(database.meals).get();
    expect(
      meals.single.eatenAt.toUtc().millisecondsSinceEpoch,
      DiaryDay.instantFor(yesterday).millisecondsSinceEpoch,
    );

    await _disposeApp(tester, database);
  });

  testWidgets('un registro handled che non si scrive non produce voci '
      'duplicate nel diario', (tester) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final gateway = FakePhotoJobsGateway([
      [_twoFoodsJob()],
    ]);
    final store = InMemoryPhotoReviewLocalStore()
      ..markHandledError = Exception('disco pieno');

    await tester.pumpWidget(
      _app(database: database, gateway: gateway, store: store),
    );
    await tester.pumpAndSettle();

    final secondCheckbox = find.byKey(const Key('food_selected_1'));
    await tester.ensureVisible(secondCheckbox);
    await tester.pumpAndSettle();
    await tester.tap(secondCheckbox);
    await tester.pump();

    final confirmButton = find.byKey(const Key('confirm_review_button'));
    await tester.ensureVisible(confirmButton);
    await tester.pumpAndSettle();
    await tester.tap(confirmButton);
    await tester.pumpAndSettle();

    // Registro non scrivibile: NIENTE entra nel diario, così un nuovo
    // tocco non può duplicare nulla.
    expect(find.text('Non riesco a salvare nel diario.'), findsOneWidget);
    expect(await database.select(database.mealItems).get(), isEmpty);
    expect(store.outcomes, isEmpty);

    // Risolto il problema, la stessa conferma produce UNA sola voce.
    store.markHandledError = null;
    await tester.tap(confirmButton);
    await tester.pumpAndSettle();

    expect(await database.select(database.mealItems).get(), hasLength(1));
    expect(store.outcomes, {'job-1': 'confirmed'});
    expect(find.text('Fatto'), findsOneWidget);

    await _disposeApp(tester, database);
  });

  testWidgets('scarta tutto non scrive nulla nel diario', (tester) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final gateway = FakePhotoJobsGateway([
      [_twoFoodsJob()],
    ]);
    final store = InMemoryPhotoReviewLocalStore();

    await tester.pumpWidget(
      _app(database: database, gateway: gateway, store: store),
    );
    await tester.pumpAndSettle();

    final discardButton = find.byKey(const Key('discard_review_button'));
    await tester.ensureVisible(discardButton);
    await tester.pumpAndSettle();
    await tester.tap(discardButton);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('discard_review_dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm_discard_button')));
    await tester.pumpAndSettle();

    // Regola 1: senza conferma niente nel diario, nemmeno una riga.
    expect(await database.select(database.mealItems).get(), isEmpty);
    expect(await database.select(database.meals).get(), isEmpty);
    expect(store.outcomes, {'job-1': 'discarded'});
    expect(gateway.deletedPhotos, ['owner-1/job-1/meal.jpg']);
    expect(find.text('Fatto'), findsOneWidget);

    await _disposeApp(tester, database);
  });

  testWidgets('un job in coda mostra l’attesa senza bloccare '
      'l’inserimento manuale', (tester) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final gateway = FakePhotoJobsGateway([
      [buildActiveJob()],
    ]);
    final store = InMemoryPhotoReviewLocalStore();

    await tester.pumpWidget(
      _app(database: database, gateway: gateway, store: store),
    );
    await tester.pumpAndSettle();

    expect(find.text('Analisi in attesa'), findsOneWidget);
    expect(find.byKey(const Key('manual_add_button')), findsOneWidget);
    expect(find.byKey(const Key('confirm_review_button')), findsNothing);

    await _disposeApp(tester, database);
  });

  testWidgets('un risultato corrotto non manda in crash la revisione', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final corruptJob = PhotoMealJob.fromRow({
      'id': 'job-1',
      'status': 'needs_review',
      'storage_object': 'owner-1/job-1/meal.jpg',
      'analysis_result': {'foods': <Object?>[], 'sorpresa': true},
    });
    final gateway = FakePhotoJobsGateway([
      [corruptJob],
    ]);
    final store = InMemoryPhotoReviewLocalStore();

    await tester.pumpWidget(
      _app(database: database, gateway: gateway, store: store),
    );
    await tester.pumpAndSettle();

    expect(find.text('Risultato non leggibile'), findsOneWidget);
    expect(find.byKey(const Key('confirm_review_button')), findsNothing);
    expect(await database.select(database.mealItems).get(), isEmpty);

    await _disposeApp(tester, database);
  });
}
