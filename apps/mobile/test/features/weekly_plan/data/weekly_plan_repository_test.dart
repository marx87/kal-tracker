import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/sync/sync_gateway.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/data/diary_repository.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/recipes/data/recipe_repository.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';
import 'package:kal_tracker/features/targets/domain/nutrition_target.dart';
import 'package:kal_tracker/features/weekly_plan/data/weekly_plan_gateway.dart';
import 'package:kal_tracker/features/weekly_plan/data/weekly_plan_repository.dart';
import 'package:kal_tracker/features/weekly_plan/domain/weekly_plan_models.dart';

class _FakeGateway implements WeeklyPlanGateway {
  WeeklyPlanAccount? account = const WeeklyPlanAccount(userId: 'owner-1');
  bool failEnqueue = false;
  bool failFetch = false;

  final calls = <String>[];
  Map<String, Object?>? insertedRow;
  Map<String, Object?>? remoteRow;

  @override
  Future<WeeklyPlanAccount?> currentAccount() async {
    calls.add('account');
    return account;
  }

  @override
  Future<String> ensureRemoteProfile(String localProfileId) async {
    calls.add('profile');
    return 'remote-profile-1';
  }

  @override
  Future<void> enqueueJob(Map<String, Object?> row) async {
    calls.add('enqueue');
    if (failEnqueue) {
      throw const WeeklyPlanException('Il server ha rifiutato la richiesta.');
    }
    insertedRow = row;
  }

  @override
  Future<Map<String, Object?>?> fetchJobRow(String jobId) async {
    calls.add('fetch');
    if (failFetch) {
      throw const WeeklyPlanException('Connessione assente.', retryable: true);
    }
    return remoteRow;
  }
}

void main() {
  late AppDatabase database;
  late _FakeGateway gateway;
  late LocalProfile profile;
  late RecipeRepository recipes;
  late Map<String, String> recipeIds;

  var clock = DateTime.utc(2026, 8, 4, 9);

  final startDate = DateTime.utc(2026, 8, 5);

  WeeklyPlanRepository repository() => WeeklyPlanRepository(
    database,
    gateway: gateway,
    recipeRepository: recipes,
    now: () => clock,
  );

  Future<WeeklyPlan> generate({
    int days = 2,
    List<PlanMeal> meals = const [PlanMeal.pranzo, PlanMeal.cena],
    String notes = '',
  }) => repository().generatePlan(
    profileId: profile.id,
    startDate: startDate,
    days: days,
    meals: meals,
    targets: const NutritionTarget.standard(),
    notes: notes,
  );

  /// Risultato ben formato per un piano di 2 giorni × pranzo e cena.
  Map<String, Object?> plannedResult({String? unknownRecipeId}) => {
    'schema': 1,
    'days': [
      {
        'date': '2026-08-05',
        'slots': [
          {
            'meal': 'pranzo',
            'recipeId': unknownRecipeId ?? recipeIds['Riso e pollo'],
            'servings': 1.5,
            'why': 'Proteine alte a metà giornata',
            // Chiave nutrizionale in più: va IGNORATA, mai mostrata.
            'kcal': 999,
          },
          {
            'meal': 'cena',
            'recipeId': recipeIds['Zuppa di lenticchie'],
            'servings': 1,
          },
        ],
      },
      {
        'date': '2026-08-06',
        'slots': [
          {
            'meal': 'pranzo',
            'recipeId': recipeIds['Zuppa di lenticchie'],
            'servings': 2,
          },
          {
            'meal': 'cena',
            'recipeId': recipeIds['Riso e pollo'],
            'servings': 1,
          },
        ],
      },
    ],
    'notes': 'Settimana leggera a cena.',
  };

  setUp(() async {
    AppTime.initialize();
    clock = DateTime.utc(2026, 8, 4, 9);
    database = AppDatabase(NativeDatabase.memory());
    gateway = _FakeGateway();
    profile = await LocalProfileRepository(database).getOrCreateMarco();
    recipes = RecipeRepository(database);
    recipeIds = {
      'Riso e pollo': await recipes.createRecipe(
        profileId: profile.id,
        draft: FitRecipeDraft(
          name: 'Riso e pollo',
          servings: 2,
          prepMinutes: 25,
          tags: const ['pranzo', 'proteico'],
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
      ),
      'Zuppa di lenticchie': await recipes.createRecipe(
        profileId: profile.id,
        draft: FitRecipeDraft(
          name: 'Zuppa di lenticchie',
          servings: 2,
          prepMinutes: 40,
          tags: const ['cena'],
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
      ),
    };
  });

  tearDown(() async {
    await database.close();
  });

  test(
    'la richiesta porta il catalogo reale con i macro per porzione',
    () async {
      final plan = await generate(notes: '  niente funghi  ');

      expect(gateway.calls, ['account', 'profile', 'enqueue']);
      final row = gateway.insertedRow!;
      // SOLO le 5 colonne concesse dal grant, nessuna in più.
      expect(row.keys.toSet(), {
        'id',
        'owner_id',
        'profile_id',
        'request',
        'last_mutation_id',
      });
      expect(row['owner_id'], 'owner-1');
      expect(row['profile_id'], 'remote-profile-1');
      expect(SyncIds.isUuid(row['last_mutation_id']! as String), isTrue);
      expect(row['id'], plan.remoteJobId);

      final request = row['request']! as Map<String, Object?>;
      expect(request['schema'], 1);
      expect(request['days'], 2);
      expect(request['startDate'], '2026-08-05');
      expect(request['meals'], ['pranzo', 'cena']);
      expect(request['notes'], 'niente funghi');
      expect(request['targets'], {
        'calories': 2000.0,
        'protein': 120.0,
        'carbs': 230.0,
        'fat': 65.0,
      });

      final catalog = (request['recipes']! as List)
          .cast<Map<String, Object?>>()
          .map((recipe) => MapEntry(recipe['name'], recipe))
          .fold<Map<Object?, Map<String, Object?>>>(
            {},
            (map, entry) => map..[entry.key] = entry.value,
          );
      expect(
        catalog.keys,
        containsAll(['Riso e pollo', 'Zuppa di lenticchie']),
      );

      // 200 g riso (350 kcal/100 g) + 200 g pollo (165) = 1030 kcal per 2
      // porzioni => 515 kcal a porzione. Numeri dell'app, non del modello.
      final riso = catalog['Riso e pollo']!;
      expect(riso['id'], recipeIds['Riso e pollo']);
      expect(riso['prepMinutes'], 25);
      expect(riso['tags'], ['pranzo', 'proteico']);
      expect(riso['servingKcal'], closeTo(515, 0.05));
      expect(riso['servingProtein'], closeTo(38, 0.05));
      expect(riso['servingCarbs'], closeTo(78, 0.05));
      expect(riso['servingFat'], closeTo(5, 0.05));

      expect(plan.status, WeeklyPlanStatus.generating);
      expect(plan.slots, isEmpty);
      expect(plan.meals, [PlanMeal.pranzo, PlanMeal.cena]);
      // La richiesta resta in locale: serve a rivalidare il risultato.
      final stored = await database.select(database.weeklyPlans).getSingle();
      expect(
        jsonDecode(stored.requestJson),
        isA<Map<String, Object?>>().having(
          (value) => value['startDate'],
          'startDate',
          '2026-08-05',
        ),
      );
    },
  );

  /// La settimana delle schede: mercoledì (il 5 agosto 2026) c'è «Spinta».
  Future<void> planWednesdayWorkout() async {
    await database
        .into(database.routines)
        .insert(
          RoutinesCompanion.insert(
            id: 'routine-spinta',
            profileId: profile.id,
            name: 'Spinta: petto e tricipiti',
            createdAt: clock,
            updatedAt: clock,
          ),
        );
    await database
        .into(database.routineWeeklyPlan)
        .insert(
          RoutineWeeklyPlanCompanion.insert(
            id: 'rwp-mercoledi',
            profileId: profile.id,
            weekday: DateTime.utc(2026, 8, 5).weekday,
            routineId: const Value('routine-spinta'),
            routineExternalId: const Value('routine-spinta'),
            routineNameSnapshot: const Value('Spinta: petto e tricipiti'),
            updatedAt: clock,
          ),
        );
  }

  /// Una sessione vera delle 18 (16 UTC d'estate), chiusa: è da qui che si
  /// misura l'ora in cui Marco si allena.
  Future<void> addEveningWorkout(String id, DateTime startedAt) => database
      .into(database.workouts)
      .insert(
        WorkoutsCompanion.insert(
          id: id,
          profileId: profile.id,
          startedAt: startedAt,
          endedAt: Value(startedAt.add(const Duration(minutes: 50))),
          createdAt: clock,
          updatedAt: clock,
        ),
      );

  test('la richiesta dice al Mac quando ci si allena', () async {
    await planWednesdayWorkout();
    await addEveningWorkout('w-1', DateTime.utc(2026, 7, 29, 16));
    await addEveningWorkout('w-2', DateTime.utc(2026, 8, 1, 16, 20));

    await generate();

    final request = gateway.insertedRow!['request']! as Map<String, Object?>;
    // Solo il 5 (mercoledì): il 6 non ha allenamento. E il pasto proteico è
    // la cena perché Marco si allena alle 18, non perché l'ha detto il
    // modello — che i numeri non li produce mai.
    expect(request['workouts'], [
      {
        'date': '2026-08-05',
        'name': 'Spinta: petto e tricipiti',
        'proteinMeal': 'cena',
      },
    ]);
  });

  test('senza storico non si dichiara un pasto dopo l’allenamento', () async {
    await planWednesdayWorkout();

    await generate();

    final request = gateway.insertedRow!['request']! as Map<String, Object?>;
    expect(request['workouts'], [
      {'date': '2026-08-05', 'name': 'Spinta: petto e tricipiti'},
    ]);
  });

  test(
    'senza settimana di allenamenti la richiesta resta quella di prima',
    () async {
      await generate();

      final request = gateway.insertedRow!['request']! as Map<String, Object?>;
      expect(request['workouts'], isEmpty);
    },
  );

  test('un risultato valido diventa slot leggibili offline', () async {
    final plan = await generate();
    gateway.remoteRow = {
      'id': plan.remoteJobId,
      'status': 'needs_review',
      'result': plannedResult(),
      'error_code': null,
      'attempt_count': 1,
    };

    final ready = (await repository().refreshPlan(plan.id))!;

    expect(ready.status, WeeklyPlanStatus.ready);
    expect(ready.isReady, isTrue);
    expect(ready.notes, 'Settimana leggera a cena.');
    expect(ready.slots, hasLength(4));

    final first = ready.slotsFor(startDate).first;
    expect(first.meal, PlanMeal.pranzo);
    expect(first.recipeName, 'Riso e pollo');
    expect(first.recipeId, recipeIds['Riso e pollo']);
    expect(first.servings, 1.5);
    expect(first.why, 'Proteine alte a metà giornata');
    expect(first.isDone, isFalse);
    expect(ready.slotsFor(startDate).last.meal, PlanMeal.cena);

    // Nessun numero del modello è sopravvissuto: gli slot non hanno campi
    // nutrizionali, li calcola sempre l'app dalle ricette.
    final storedSlots = await database.select(database.weeklyPlanSlots).get();
    expect(storedSlots, hasLength(4));
    expect(storedSlots.every((slot) => slot.doneAt == null), isTrue);

    // Leggibile senza rete: getPlan non tocca il gateway.
    gateway.calls.clear();
    final offline = await repository().getPlan(plan.id);
    expect(offline!.slots, hasLength(4));
    expect(gateway.calls, isEmpty);
  });

  test(
    'una ricetta sconosciuta rifiuta il piano senza scrivere slot',
    () async {
      final plan = await generate();
      gateway.remoteRow = {
        'id': plan.remoteJobId,
        'status': 'needs_review',
        'result': plannedResult(
          unknownRecipeId: '00000000-0000-4000-8000-000000000000',
        ),
      };

      final failed = (await repository().refreshPlan(plan.id))!;

      expect(failed.status, WeeklyPlanStatus.failed);
      expect(failed.notes, contains('non era valido'));
      expect(failed.notes, contains('non è nel ricettario inviato'));
      expect(failed.slots, isEmpty);
      expect(await database.select(database.weeklyPlanSlots).get(), isEmpty);
    },
  );

  test('col Mac spento il piano fallisce con un messaggio onesto e i piani '
      'vecchi restano leggibili', () async {
    final old = await generate();
    gateway.remoteRow = {
      'id': old.remoteJobId,
      'status': 'needs_review',
      'result': plannedResult(),
    };
    await repository().refreshPlan(old.id);

    clock = clock.add(const Duration(minutes: 5));
    final pending = await generate();
    gateway.remoteRow = {'id': pending.remoteJobId, 'status': 'queued'};

    // Poco dopo: si aspetta ancora, nessun verdetto affrettato.
    clock = clock.add(const Duration(minutes: 2));
    expect(
      (await repository().refreshPlan(pending.id))!.status,
      WeeklyPlanStatus.generating,
    );

    // Passata la finestra: messaggio onesto, nessun generatore di riserva.
    clock = clock.add(WeeklyPlanRepository.queuedTimeout);
    final failed = (await repository().refreshPlan(pending.id))!;
    expect(failed.status, WeeklyPlanStatus.failed);
    expect(failed.notes, contains('Il Mac non ha risposto'));

    final plans = await repository().watchPlans(profile.id).first;
    expect(plans, hasLength(2));
    expect(plans.first.id, pending.id);
    expect(plans.last.id, old.id);
    expect(plans.last.status, WeeklyPlanStatus.ready);
    expect(plans.last.slots, hasLength(4));
  });

  test('offline si aspetta, ma non per sempre: passata la finestra il piano '
      'si chiude col motivo vero', () async {
    final plan = await generate();
    gateway.failFetch = true;

    // Poco dopo: l'errore risale alla UI e lo stato locale non si tocca,
    // perché «non riesco a chiedere» non è «il Mac è spento».
    clock = clock.add(const Duration(minutes: 2));
    await expectLater(
      repository().refreshPlan(plan.id),
      throwsA(isA<WeeklyPlanException>()),
    );
    expect(
      (await repository().getPlan(plan.id))!.status,
      WeeklyPlanStatus.generating,
    );

    // Passata la finestra dell'attesa il silenzio va dichiarato: senza questo
    // il piano resterebbe «in preparazione» per sempre, il polling non si
    // fermerebbe mai e non si potrebbe nemmeno generarne un altro.
    clock = clock.add(WeeklyPlanRepository.queuedTimeout);
    final failed = (await repository().refreshPlan(plan.id))!;
    expect(failed.status, WeeklyPlanStatus.failed);
    expect(failed.notes, contains('Non sono riuscito a chiedere al Mac'));

    // E la via d'uscita è aperta: nessun piano in preparazione, se ne può
    // chiedere uno nuovo.
    gateway.failFetch = false;
    final again = await generate();
    expect(again.status, WeeklyPlanStatus.generating);
  });

  test('la riga del job non trovata aspetta comunque la finestra', () async {
    final plan = await generate();
    gateway.remoteRow = null;

    expect(
      (await repository().refreshPlan(plan.id))!.status,
      WeeklyPlanStatus.generating,
    );

    clock = clock.add(WeeklyPlanRepository.queuedTimeout * 2);
    final failed = (await repository().refreshPlan(plan.id))!;
    expect(failed.status, WeeklyPlanStatus.failed);
    expect(failed.notes, contains('Il Mac non ha risposto'));
  });

  test('il worker fallito porta il codice nel messaggio', () async {
    final plan = await generate();
    gateway.remoteRow = {
      'id': plan.remoteJobId,
      'status': 'failed',
      'error_code': 'CLAUDE_TIMEOUT',
    };

    final failed = (await repository().refreshPlan(plan.id))!;
    expect(failed.status, WeeklyPlanStatus.failed);
    expect(failed.notes, contains('CLAUDE_TIMEOUT'));
  });

  test('"Fatto" scrive nel diario del giorno e del pasto giusti, una volta '
      'sola', () async {
    final plan = await generate();
    gateway.remoteRow = {
      'id': plan.remoteJobId,
      'status': 'needs_review',
      'result': plannedResult(),
    };
    final ready = (await repository().refreshPlan(plan.id))!;
    final slot = ready.slotsFor(startDate).first;

    final updated = (await repository().markSlotDone(slot.id))!;
    final done = updated.slots.firstWhere((row) => row.id == slot.id);
    expect(done.isDone, isTrue);
    expect(done.diaryEntryIds, hasLength(1));
    expect(updated.doneCount, 1);

    final diary = DiaryRepository(database);
    final entries = await diary.entriesForMeal(
      profileId: profile.id,
      day: startDate,
      mealType: MealType.lunch,
    );
    expect(entries, hasLength(1));
    expect(entries.single.foodName, 'Riso e pollo · 1,5 porzioni');
    // 515 kcal a porzione × 1,5 = 772,5 kcal, calcolate dalla ricetta vera.
    expect(entries.single.nutrients.calories, closeTo(772.5, 0.1));
    expect(entries.single.grams, closeTo(300, 0.001));

    // Il giorno prima e il giorno dopo restano puliti.
    expect(
      await diary.entriesForMeal(
        profileId: profile.id,
        day: DateTime.utc(2026, 8, 6),
        mealType: MealType.lunch,
      ),
      isEmpty,
    );

    // Due volte no: prima si annulla.
    await expectLater(
      repository().markSlotDone(slot.id),
      throwsA(isA<WeeklyPlanException>()),
    );
    expect(
      await diary.entriesForMeal(
        profileId: profile.id,
        day: startDate,
        mealType: MealType.lunch,
      ),
      hasLength(1),
    );

    final undone = (await repository().undoSlotDone(slot.id))!;
    expect(undone.slots.firstWhere((row) => row.id == slot.id).isDone, isFalse);
    expect(
      await diary.entriesForMeal(
        profileId: profile.id,
        day: startDate,
        mealType: MealType.lunch,
      ),
      isEmpty,
    );
  });

  test(
    '"Sostituisci" cambia ricetta e toglie la motivazione vecchia',
    () async {
      final plan = await generate();
      gateway.remoteRow = {
        'id': plan.remoteJobId,
        'status': 'needs_review',
        'result': plannedResult(),
      };
      final ready = (await repository().refreshPlan(plan.id))!;
      final slot = ready.slotsFor(startDate).first;

      final updated = (await repository().replaceSlotRecipe(
        slotId: slot.id,
        recipeId: recipeIds['Zuppa di lenticchie']!,
      ))!;

      final replaced = updated.slots.firstWhere((row) => row.id == slot.id);
      expect(replaced.recipeId, recipeIds['Zuppa di lenticchie']);
      expect(replaced.recipeName, 'Zuppa di lenticchie');
      expect(replaced.why, isNull);
      expect(replaced.servings, 1.5);
    },
  );

  test(
    'una ricetta cancellata lascia lo slot leggibile ma non più "Fatto"',
    () async {
      final plan = await generate();
      gateway.remoteRow = {
        'id': plan.remoteJobId,
        'status': 'needs_review',
        'result': plannedResult(),
      };
      final ready = (await repository().refreshPlan(plan.id))!;
      final slot = ready.slotsFor(startDate).first;

      await recipes.deleteRecipe(recipeIds['Riso e pollo']!);

      final after = (await repository().getPlan(plan.id))!;
      final orphan = after.slots.firstWhere((row) => row.id == slot.id);
      expect(orphan.recipeName, 'Riso e pollo');
      expect(orphan.hasRecipe, isFalse);
      await expectLater(
        repository().markSlotDone(slot.id),
        throwsA(
          isA<WeeklyPlanException>().having(
            (error) => error.message,
            'message',
            contains('non è più nel ricettario'),
          ),
        ),
      );
    },
  );

  test(
    'senza sessione il piano non parte e il messaggio invita ad accedere',
    () async {
      gateway.account = null;

      await expectLater(
        generate(),
        throwsA(
          isA<WeeklyPlanException>()
              .having((error) => error.authRequired, 'authRequired', isTrue)
              .having(
                (error) => error.message,
                'message',
                contains('Progressi → Sincronizzazione'),
              ),
        ),
      );
      expect(gateway.calls, ['account']);
      expect(await database.select(database.weeklyPlans).get(), isEmpty);
    },
  );

  test('se l\'enqueue fallisce non resta un piano fantasma', () async {
    gateway.failEnqueue = true;

    await expectLater(generate(), throwsA(isA<WeeklyPlanException>()));

    expect(await database.select(database.weeklyPlans).get(), isEmpty);
  });

  test('un solo piano in preparazione alla volta', () async {
    await generate();

    await expectLater(
      generate(),
      throwsA(
        isA<WeeklyPlanException>().having(
          (error) => error.message,
          'message',
          contains('già un piano in preparazione'),
        ),
      ),
    );
    expect(await database.select(database.weeklyPlans).get(), hasLength(1));
  });
}
