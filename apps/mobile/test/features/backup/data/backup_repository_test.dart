import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/backup/data/backup_repository.dart';
import 'package:kal_tracker/features/backup/domain/backup_document.dart';
import 'package:kal_tracker/features/backup/domain/backup_restore.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

const _rice = Nutrients(calories: 130, protein: 2.7, carbs: 28.2, fat: 0.3);
const _chicken = Nutrients(calories: 165, protein: 31, carbs: 0, fat: 3.6);
const _yogurt = Nutrients(calories: 59, protein: 10.3, carbs: 3.6, fat: 0.4);

void main() {
  late AppDatabase database;
  late BackupRepository repository;
  late String profileId;

  final moment = DateTime.utc(2026, 8, 1, 10, 30);
  final exportedAt = DateTime.utc(2026, 8, 3, 8);

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
    repository = BackupRepository(database);
  });

  tearDown(() => database.close());

  test('esporta tutte le collezioni del profilo e ignora i seed', () async {
    await _seed(database, profileId, moment);

    final document = await repository.exportBackup(
      profileId: profileId,
      appVersion: '0.2.0+2',
      exportedAt: exportedAt,
    );

    expect(document.formatVersion, BackupDocument.currentFormatVersion);
    expect(document.profile.id, profileId);
    expect(document.meals, hasLength(1));
    expect(document.mealItems, hasLength(2));
    expect(document.nutritionTargets, hasLength(1));
    expect(document.waterLogs, hasLength(1));
    expect(document.bodyMeasurements, hasLength(1));
    expect(document.foods.map((row) => row.id), ['food-1']);
    expect(document.foodPreferences, hasLength(1));
    expect(document.fitRecipes.single.tags, 'pranzo,proteico');
    expect(document.recipeIngredients, hasLength(2));
    expect(document.mealTemplates, hasLength(1));
    expect(document.mealTemplateItems, hasLength(1));
    expect(document.mealItems.last.deletedAt, isNotNull);
  });

  test('due export dello stesso database producono lo stesso file', () async {
    await _seed(database, profileId, moment);

    final first = await repository.exportBackup(
      profileId: profileId,
      exportedAt: exportedAt,
    );
    final second = await repository.exportBackup(
      profileId: profileId,
      exportedAt: exportedAt,
    );

    expect(second.encode(), first.encode());
    expect(second.checksum, first.checksum);
  });

  test('il ripristino su un telefono nuovo ricrea lo stesso diario', () async {
    await _seed(database, profileId, moment);
    final original = await repository.exportBackup(
      profileId: profileId,
      exportedAt: exportedAt,
    );

    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final fresh = AppDatabase(NativeDatabase.memory());
    addTearDown(() {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = false;
      return fresh.close();
    });
    await LocalProfileRepository(fresh).getOrCreateMarco();
    final freshRepository = BackupRepository(fresh);

    final summary = await freshRepository.importBackup(
      original.encode(),
      mode: BackupRestoreMode.replace,
    );

    expect(summary.mode, BackupRestoreMode.replace);
    expect(summary.updated, 0);
    expect(summary.skipped, 0);
    expect(summary.created, greaterThan(0));

    final restored = await freshRepository.exportBackup(
      profileId: profileId,
      exportedAt: exportedAt,
    );
    expect(restored.encode(), original.encode());
    expect((await fresh.select(fresh.appProfiles).get()).map((row) => row.id), [
      profileId,
    ]);
    expect(
      (await fresh.select(fresh.foods).get()).where(
        (row) => row.source == 'seed',
      ),
      hasLength(12),
    );
  });

  test('la sostituzione cancella i dati che il backup non contiene', () async {
    await _seed(database, profileId, moment);
    final document = await repository.exportBackup(
      profileId: profileId,
      exportedAt: exportedAt,
    );

    final later = moment.add(const Duration(days: 1));
    await database
        .into(database.mealItems)
        .insert(
          MealItemsCompanion.insert(
            id: 'item-fuori-backup',
            mealId: 'meal-1',
            foodName: 'Pane integrale',
            grams: 60,
            caloriesPer100g: 247,
            proteinPer100g: 13,
            carbsPer100g: 41,
            fatPer100g: 3.4,
            totalCalories: 148.2,
            totalProtein: 7.8,
            totalCarbs: 24.6,
            totalFat: 2.04,
            createdAt: later,
            updatedAt: later,
          ),
        );

    await repository.importBackup(
      document.encode(),
      mode: BackupRestoreMode.replace,
    );

    final items = await database.select(database.mealItems).get();
    expect(items.map((row) => row.id), ['item-1', 'item-2']);
    final tombstones = (await database.select(database.syncOutbox).get()).where(
      (row) => row.operation == 'delete',
    );
    expect(tombstones.map((row) => row.entityId), ['item-fuori-backup']);
  });

  test(
    'unendo un backup vecchio i dati recenti non vengono sovrascritti',
    () async {
      await _seed(database, profileId, moment);
      final document = await repository.exportBackup(
        profileId: profileId,
        exportedAt: exportedAt,
      );

      final later = moment.add(const Duration(days: 2));
      await (database.update(
        database.mealItems,
      )..where((row) => row.id.equals('item-1'))).write(
        MealItemsCompanion(
          foodName: const Value('Riso basmati cotto (corretto)'),
          grams: const Value(180),
          updatedAt: Value(later),
        ),
      );
      await (database.delete(
        database.mealItems,
      )..where((row) => row.id.equals('item-2'))).go();
      final outboxBefore =
          (await database.select(database.syncOutbox).get()).length;

      final summary = await repository.importBackup(
        document.encode(),
        mode: BackupRestoreMode.merge,
      );

      final items = await database.select(database.mealItems).get();
      final corrected = items.firstWhere((row) => row.id == 'item-1');
      expect(corrected.foodName, 'Riso basmati cotto (corretto)');
      expect(corrected.grams, 180);
      expect(items.map((row) => row.id), containsAll(['item-1', 'item-2']));
      expect(summary.created, 1);
      expect(summary.updated, 0);
      expect(summary.skipped, greaterThan(0));
      expect(
        (await database.select(database.syncOutbox).get()).length,
        outboxBefore + 1,
      );
    },
  );

  test('una voce senza pasto annulla tutto il ripristino', () async {
    await _seed(database, profileId, moment);
    final document = await repository.exportBackup(
      profileId: profileId,
      exportedAt: exportedAt,
    );
    final later = moment.add(const Duration(days: 3));
    final broken = _copy(
      document,
      mealItems: [
        BackupMealItem.fromJson({
          ...document.mealItems.first.toJson(),
          'food_name': 'Voce corretta a mano',
          'updated_at': later.toIso8601String(),
        }),
        BackupMealItem.fromJson({
          ...document.mealItems.first.toJson(),
          'id': 'item-orfano',
          'meal_id': 'pasto-inesistente',
          'updated_at': later.toIso8601String(),
        }),
      ],
    );

    await expectLater(
      repository.importBackup(broken.encode(), mode: BackupRestoreMode.merge),
      throwsA(isA<BackupFormatException>()),
    );

    final items = await database.select(database.mealItems).get();
    expect(items, hasLength(2));
    expect(
      items.firstWhere((row) => row.id == 'item-1').foodName,
      'Riso basmati cotto',
    );
    expect(await database.select(database.syncOutbox).get(), isEmpty);
  });

  test('il ripristino ricalcola i totali dal valore per 100 g', () async {
    await _seed(database, profileId, moment);
    final document = await repository.exportBackup(
      profileId: profileId,
      exportedAt: exportedAt,
    );
    final later = moment.add(const Duration(days: 1));
    final gonfiato = _copy(
      document,
      mealItems: [
        BackupMealItem.fromJson({
          ...document.mealItems.first.toJson(),
          'grams': 100.0,
          'calories_per_100g': 50.0,
          'total_calories': 5000.0,
          'updated_at': later.toIso8601String(),
        }),
      ],
      fitRecipes: [
        BackupRecipe.fromJson({
          ...document.fitRecipes.single.toJson(),
          'total_calories': 0.0,
          'total_protein': 0.0,
          'total_carbs': 0.0,
          'total_fat': 0.0,
          'updated_at': later.toIso8601String(),
        }),
      ],
    );

    await repository.importBackup(
      gonfiato.encode(),
      mode: BackupRestoreMode.merge,
    );

    final item = await (database.select(
      database.mealItems,
    )..where((row) => row.id.equals('item-1'))).getSingle();
    final recipe = await (database.select(
      database.fitRecipes,
    )..where((row) => row.id.equals('recipe-1'))).getSingle();
    expect(item.totalCalories, 50);
    expect(recipe.totalCalories, closeTo(595.3, 0.0001));

    final payloads = {
      for (final row in await database.select(database.syncOutbox).get())
        row.entityType: jsonDecode(row.payloadJson) as Map<String, Object?>,
    };
    expect(payloads['meal_item']?['total_calories'], 50);
    expect(payloads['fit_recipe']?['total_calories'], closeTo(595.3, 0.0001));
  });

  test('i tombstone usano la chiave con cui l’entità è identificata', () async {
    await _seed(database, profileId, moment);
    final document = await repository.exportBackup(
      profileId: profileId,
      exportedAt: exportedAt,
    );

    await repository.importBackup(
      _copy(
        document,
        foodPreferences: const [],
        nutritionTargets: const [],
      ).encode(),
      mode: BackupRestoreMode.replace,
    );

    final tombstones = {
      for (final row in await database.select(database.syncOutbox).get())
        if (row.operation == 'delete')
          row.entityType: jsonDecode(row.payloadJson) as Map<String, Object?>,
    };
    expect(tombstones['food_preference'], {
      'profile_id': profileId,
      'food_id': 'food-1',
      'deleted_at': isA<String>(),
    });
    expect(tombstones['nutrition_target'], {
      'profile_id': profileId,
      'deleted_at': isA<String>(),
    });
  });

  test('esporta anche gli allenamenti del profilo', () async {
    await _seed(database, profileId, moment);
    await _seedWorkouts(database, profileId, moment);

    final document = await repository.exportBackup(
      profileId: profileId,
      exportedAt: exportedAt,
    );

    expect(document.formatVersion, 2);
    expect(document.exercises.map((row) => row.id), ['cd-childpose', 'ex-1']);
    expect(document.routines, hasLength(1));
    expect(document.routineExercises, hasLength(2));
    expect(document.routineIntervalSegments, hasLength(1));
    expect(document.routineWeeklyPlan, hasLength(2));
    expect(document.workouts, hasLength(2));
    expect(document.workoutExercises, hasLength(2));
    expect(document.workoutSets, hasLength(3));
    expect(document.workoutPainPoints.single.label, 'Spalla destra');
    expect(document.workoutIntervalSegments.single.completedMarker, isTrue);
    expect(document.workoutIntervalSegments.single.partialMarker, isTrue);
    expect(document.workoutProfileStats.single.totalXp, 11370);
    expect(document.workoutAchievements, hasLength(2));
    expect(document.bodyMeasurementValues.single.label, 'Vita');
    // Le pesate portano la composizione corporea, non solo il peso.
    expect(document.bodyMeasurements.single.bodyFatPct, 24.3);
    expect(document.bodyMeasurements.single.source, 'renpho_ble');
  });

  test(
    'il ripristino su un telefono nuovo ricrea anche gli allenamenti',
    () async {
      await _seed(database, profileId, moment);
      await _seedWorkouts(database, profileId, moment);
      final original = await repository.exportBackup(
        profileId: profileId,
        exportedAt: exportedAt,
      );

      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final fresh = AppDatabase(NativeDatabase.memory());
      addTearDown(() {
        driftRuntimeOptions.dontWarnAboutMultipleDatabases = false;
        return fresh.close();
      });
      await LocalProfileRepository(fresh).getOrCreateMarco();
      final freshRepository = BackupRepository(fresh);

      await freshRepository.importBackup(
        original.encode(),
        mode: BackupRestoreMode.replace,
      );

      final restored = await freshRepository.exportBackup(
        profileId: profileId,
        exportedAt: exportedAt,
      );
      expect(restored.encode(), original.encode());

      final sets = await fresh.select(fresh.workoutSets).get();
      expect(sets, hasLength(3));
      expect(sets.firstWhere((row) => row.id == 'set-1').weightKg, 62.5);
      expect(sets.firstWhere((row) => row.id == 'set-3').completed, isFalse);
      final rows = await fresh.select(fresh.workoutExercises).get();
      final orphan = rows.firstWhere((row) => row.id == 'workout-exercise-2');
      expect(orphan.exerciseId, isNull);
      expect(orphan.exerciseRefId, 'ex-sparito');
      expect(orphan.exerciseNameSnapshot, 'Esercizio cancellato');
      expect(
        (await fresh.select(fresh.workoutProfileStats).getSingle()).totalXp,
        11370,
      );
      expect(await fresh.select(fresh.workoutAchievements).get(), hasLength(2));
      expect(
        (await fresh.select(fresh.bodyMeasurementValues).getSingle()).value,
        96,
      );
      final measurement = await fresh
          .select(fresh.bodyMeasurements)
          .getSingle();
      expect(measurement.impedanceOhm, 512);
      expect(measurement.externalId, 'renpho-1');
    },
  );

  test(
    'gli allenamenti non finiscono nella coda di sincronizzazione',
    () async {
      await _seed(database, profileId, moment);
      await _seedWorkouts(database, profileId, moment);
      final document = await repository.exportBackup(
        profileId: profileId,
        exportedAt: exportedAt,
      );

      await repository.importBackup(
        document.encode(),
        mode: BackupRestoreMode.replace,
      );

      final types = (await database.select(database.syncOutbox).get())
          .map((row) => row.entityType)
          .toSet();
      expect(
        types.intersection({
          'workout',
          'exercise',
          'routine',
          'workout_profile_stats',
        }),
        isEmpty,
      );
    },
  );

  test(
    'un backup senza allenamenti non può sostituire quelli che ci sono',
    () async {
      await _seed(database, profileId, moment);
      await _seedWorkouts(database, profileId, moment);
      final legacy = _asLegacy(
        await repository.exportBackup(
          profileId: profileId,
          exportedAt: exportedAt,
        ),
      );

      await expectLater(
        repository.importBackup(
          legacy.encode(),
          mode: BackupRestoreMode.replace,
        ),
        throwsA(
          isA<BackupWouldLoseDataException>().having(
            (error) => error.message,
            'message',
            allOf(contains('2 sessioni'), contains('Unisci')),
          ),
        ),
      );

      expect(await database.select(database.workouts).get(), hasLength(2));
      expect(await database.select(database.workoutSets).get(), hasLength(3));
      expect(await database.select(database.meals).get(), hasLength(1));
      expect(await database.select(database.syncOutbox).get(), isEmpty);
    },
  );

  test(
    'un backup senza allenamenti sostituisce tutto se non ce ne sono',
    () async {
      await _seed(database, profileId, moment);
      final legacy = _asLegacy(
        await repository.exportBackup(
          profileId: profileId,
          exportedAt: exportedAt,
        ),
      );

      final summary = await repository.importBackup(
        legacy.encode(),
        mode: BackupRestoreMode.replace,
      );

      // Il blocco scatta solo se c'è qualcosa da perdere: su un telefono senza
      // allenamenti un backup vecchio deve restare ripristinabile com'era.
      expect(summary.created, greaterThan(0));
      expect(await database.select(database.meals).get(), hasLength(1));
      expect(await database.select(database.workouts).get(), isEmpty);
    },
  );

  test('un backup senza allenamenti si può comunque unire', () async {
    await _seed(database, profileId, moment);
    await _seedWorkouts(database, profileId, moment);
    final legacy = _asLegacy(
      await repository.exportBackup(
        profileId: profileId,
        exportedAt: exportedAt,
      ),
    );

    final summary = await repository.importBackup(
      legacy.encode(),
      mode: BackupRestoreMode.merge,
    );

    expect(summary.mode, BackupRestoreMode.merge);
    expect(await database.select(database.workouts).get(), hasLength(2));
    expect(await database.select(database.workoutSets).get(), hasLength(3));
    expect(await database.select(database.exercises).get(), hasLength(2));
  });

  test(
    'sostituendo con un backup del formato 2 le sessioni assenti spariscono',
    () async {
      await _seed(database, profileId, moment);
      await _seedWorkouts(database, profileId, moment);
      final document = await repository.exportBackup(
        profileId: profileId,
        exportedAt: exportedAt,
      );

      await repository.importBackup(
        _withoutSessions(document).encode(),
        mode: BackupRestoreMode.replace,
      );

      // Il file COPRE le sessioni e non ne ha: sostituire vuol dire toglierle.
      // Il catalogo, che il file ha, resta.
      expect(await database.select(database.workouts).get(), isEmpty);
      expect(await database.select(database.workoutSets).get(), isEmpty);
      expect(await database.select(database.exercises).get(), hasLength(2));
      expect(await database.select(database.routines).get(), hasLength(1));
    },
  );

  test(
    'unendo, una sessione corretta dopo il backup non torna indietro',
    () async {
      await _seed(database, profileId, moment);
      await _seedWorkouts(database, profileId, moment);
      final document = await repository.exportBackup(
        profileId: profileId,
        exportedAt: exportedAt,
      );

      final later = moment.add(const Duration(days: 2));
      await (database.update(database.workoutSets)
            ..where((row) => row.id.equals('set-1')))
          .write(const WorkoutSetsCompanion(weightKg: Value(70)));
      await (database.update(database.workouts)
            ..where((row) => row.id.equals('workout-1')))
          .write(WorkoutsCompanion(updatedAt: Value(later)));

      final summary = await repository.importBackup(
        document.encode(),
        mode: BackupRestoreMode.merge,
      );

      final set = await (database.select(
        database.workoutSets,
      )..where((row) => row.id.equals('set-1'))).getSingle();
      expect(set.weightKg, 70);
      expect(summary.skipped, greaterThan(0));
      expect(await database.select(database.workoutSets).get(), hasLength(3));
    },
  );

  test('rifiuta un backup danneggiato senza toccare il database', () async {
    await _seed(database, profileId, moment);
    final document = await repository.exportBackup(
      profileId: profileId,
      exportedAt: exportedAt,
    );
    final tampered = jsonDecode(document.encode()) as Map<String, Object?>;
    final data = tampered['data']! as Map<String, Object?>;
    final meals = data['meals']! as List<Object?>;
    (meals.first! as Map<String, Object?>)['meal_type'] = 'dinner';

    await expectLater(
      repository.importBackup(
        jsonEncode(tampered),
        mode: BackupRestoreMode.replace,
      ),
      throwsA(isA<BackupFormatException>()),
    );

    final meal = await database.select(database.meals).getSingle();
    expect(meal.mealType, 'lunch');
    expect(await database.select(database.syncOutbox).get(), isEmpty);
  });
}

BackupDocument _copy(
  BackupDocument source, {
  List<BackupMealItem>? mealItems,
  List<BackupNutritionTarget>? nutritionTargets,
  List<BackupFoodPreference>? foodPreferences,
  List<BackupRecipe>? fitRecipes,
  int? formatVersion,
  bool keepWorkouts = true,
  bool keepSessions = true,
}) => BackupDocument(
  formatVersion: formatVersion ?? source.formatVersion,
  appVersion: source.appVersion,
  exportedAt: source.exportedAt,
  profile: source.profile,
  meals: source.meals,
  mealItems: mealItems ?? source.mealItems,
  nutritionTargets: nutritionTargets ?? source.nutritionTargets,
  waterLogs: source.waterLogs,
  bodyMeasurements: source.bodyMeasurements,
  foods: source.foods,
  foodPreferences: foodPreferences ?? source.foodPreferences,
  fitRecipes: fitRecipes ?? source.fitRecipes,
  recipeIngredients: source.recipeIngredients,
  mealTemplates: source.mealTemplates,
  mealTemplateItems: source.mealTemplateItems,
  bodyMeasurementValues: keepWorkouts ? source.bodyMeasurementValues : const [],
  exercises: keepWorkouts ? source.exercises : const [],
  routines: keepWorkouts ? source.routines : const [],
  routineExercises: keepWorkouts ? source.routineExercises : const [],
  routineIntervalSegments: keepWorkouts
      ? source.routineIntervalSegments
      : const [],
  routineWeeklyPlan: keepWorkouts ? source.routineWeeklyPlan : const [],
  workouts: keepWorkouts && keepSessions ? source.workouts : const [],
  workoutExercises: keepWorkouts && keepSessions
      ? source.workoutExercises
      : const [],
  workoutSets: keepWorkouts && keepSessions ? source.workoutSets : const [],
  workoutPainPoints: keepWorkouts && keepSessions
      ? source.workoutPainPoints
      : const [],
  workoutIntervalSegments: keepWorkouts && keepSessions
      ? source.workoutIntervalSegments
      : const [],
  workoutProfileStats: keepWorkouts ? source.workoutProfileStats : const [],
  workoutAchievements: keepWorkouts ? source.workoutAchievements : const [],
);

/// Il file com'era prima che il backup conoscesse gli allenamenti: versione 1
/// del formato e nessuna delle sezioni nuove.
BackupDocument _asLegacy(BackupDocument source) =>
    _copy(source, formatVersion: 1, keepWorkouts: false);

/// Un file della versione 2 che il catalogo ce l'ha ma le sessioni no.
BackupDocument _withoutSessions(BackupDocument source) =>
    _copy(source, keepSessions: false);

Future<void> _seed(
  AppDatabase database,
  String profileId,
  DateTime moment,
) async {
  final riceTotals = NutritionCalculator.scale(per100g: _rice, grams: 150);
  final chickenTotals = NutritionCalculator.scale(
    per100g: _chicken,
    grams: 200,
  );
  final recipeTotals =
      NutritionCalculator.scale(per100g: _yogurt, grams: 170) +
      NutritionCalculator.scale(per100g: _chicken, grams: 300);
  await database
      .into(database.meals)
      .insert(
        MealsCompanion.insert(
          id: 'meal-1',
          profileId: profileId,
          mealType: 'lunch',
          eatenAt: moment,
          createdAt: moment,
          updatedAt: moment,
        ),
      );
  await database
      .into(database.mealItems)
      .insert(
        MealItemsCompanion.insert(
          id: 'item-1',
          mealId: 'meal-1',
          foodName: 'Riso basmati cotto',
          grams: 150,
          caloriesPer100g: _rice.calories,
          proteinPer100g: _rice.protein,
          carbsPer100g: _rice.carbs,
          fatPer100g: _rice.fat,
          totalCalories: riceTotals.calories,
          totalProtein: riceTotals.protein,
          totalCarbs: riceTotals.carbs,
          totalFat: riceTotals.fat,
          createdAt: moment,
          updatedAt: moment,
        ),
      );
  await database
      .into(database.mealItems)
      .insert(
        MealItemsCompanion.insert(
          id: 'item-2',
          mealId: 'meal-1',
          foodName: 'Petto di pollo',
          grams: 200,
          caloriesPer100g: _chicken.calories,
          proteinPer100g: _chicken.protein,
          carbsPer100g: _chicken.carbs,
          fatPer100g: _chicken.fat,
          totalCalories: chickenTotals.calories,
          totalProtein: chickenTotals.protein,
          totalCarbs: chickenTotals.carbs,
          totalFat: chickenTotals.fat,
          createdAt: moment,
          updatedAt: moment,
          deletedAt: Value(moment),
        ),
      );
  await database
      .into(database.nutritionTargets)
      .insert(
        NutritionTargetsCompanion.insert(
          profileId: profileId,
          dailyCalories: 2100,
          dailyProtein: 150,
          dailyCarbs: 230,
          dailyFat: 65,
          createdAt: moment,
          updatedAt: moment,
        ),
      );
  await database
      .into(database.waterLogs)
      .insert(
        WaterLogsCompanion.insert(
          id: 'water-1',
          profileId: profileId,
          milliliters: 500,
          loggedAt: moment,
          createdAt: moment,
          updatedAt: moment,
        ),
      );
  await database
      .into(database.bodyMeasurements)
      .insert(
        BodyMeasurementsCompanion.insert(
          id: 'weight-1',
          profileId: profileId,
          weightKg: 80.5,
          measuredAt: moment,
          hasImpedance: const Value(true),
          impedanceOhm: const Value(512),
          bodyFatPct: const Value(24.3),
          formulaVersion: const Value('renpho-1'),
          source: const Value('renpho_ble'),
          externalId: const Value('renpho-1'),
          note: const Value('dopo la corsa'),
          createdAt: moment,
          updatedAt: moment,
        ),
      );
  await database
      .into(database.foods)
      .insert(
        FoodsCompanion.insert(
          id: 'food-1',
          ownerProfileId: Value(profileId),
          name: 'Yogurt del contadino',
          brand: const Value('Fattoria'),
          caloriesPer100g: _yogurt.calories,
          proteinPer100g: _yogurt.protein,
          carbsPer100g: _yogurt.carbs,
          fatPer100g: _yogurt.fat,
          defaultServingGrams: const Value(170),
          createdAt: moment,
          updatedAt: moment,
        ),
      );
  await database
      .into(database.foodPreferences)
      .insert(
        FoodPreferencesCompanion.insert(
          profileId: profileId,
          foodId: 'food-1',
          isFavorite: const Value(true),
          useCount: const Value(3),
          lastUsedAt: Value(moment),
          updatedAt: moment,
        ),
      );
  await database
      .into(database.fitRecipes)
      .insert(
        FitRecipesCompanion.insert(
          id: 'recipe-1',
          profileId: profileId,
          name: 'Bowl di Marco',
          description: const Value('La bowl del sabato.'),
          tags: const Value('pranzo,proteico'),
          servings: 2,
          prepMinutes: const Value(25),
          totalCalories: recipeTotals.calories,
          totalProtein: recipeTotals.protein,
          totalCarbs: recipeTotals.carbs,
          totalFat: recipeTotals.fat,
          isFavorite: const Value(true),
          createdAt: moment,
          updatedAt: moment,
        ),
      );
  await database
      .into(database.recipeIngredients)
      .insert(
        RecipeIngredientsCompanion.insert(
          id: 'ingredient-1',
          recipeId: 'recipe-1',
          foodId: const Value('food-1'),
          position: 0,
          name: 'Yogurt del contadino',
          grams: 170,
          caloriesPer100g: _yogurt.calories,
          proteinPer100g: _yogurt.protein,
          carbsPer100g: _yogurt.carbs,
          fatPer100g: _yogurt.fat,
        ),
      );
  await database
      .into(database.recipeIngredients)
      .insert(
        RecipeIngredientsCompanion.insert(
          id: 'ingredient-2',
          recipeId: 'recipe-1',
          position: 1,
          name: 'Petto di pollo',
          grams: 300,
          caloriesPer100g: _chicken.calories,
          proteinPer100g: _chicken.protein,
          carbsPer100g: _chicken.carbs,
          fatPer100g: _chicken.fat,
        ),
      );
  await database
      .into(database.mealTemplates)
      .insert(
        MealTemplatesCompanion.insert(
          id: 'template-1',
          profileId: profileId,
          name: 'Colazione tipo',
          mealType: 'breakfast',
          createdAt: moment,
          updatedAt: moment,
        ),
      );
  await database
      .into(database.mealTemplateItems)
      .insert(
        MealTemplateItemsCompanion.insert(
          id: 'template-item-1',
          templateId: 'template-1',
          position: 0,
          foodName: 'Fiocchi d’avena',
          grams: 50,
          caloriesPer100g: 389,
          proteinPer100g: 16.9,
          carbsPer100g: 66.3,
          fatPer100g: 6.9,
        ),
      );
}

/// Un pezzo di storico realistico: catalogo con un preset sintetico, una
/// scheda a circuito, una sessione chiusa e una ancora aperta.
Future<void> _seedWorkouts(
  AppDatabase database,
  String profileId,
  DateTime moment,
) async {
  await database
      .into(database.exercises)
      .insert(
        ExercisesCompanion.insert(
          id: 'ex-1',
          profileId: profileId,
          name: 'Panca piana',
          muscleGroup: 'petto',
          trackingMode: 'weightReps',
          notes: const Value('Scapole strette.'),
          defaultRestSec: const Value(90),
          source: const Value('gym_tracker'),
          externalId: const Value('gym-ex-1'),
          createdAt: moment,
          updatedAt: moment,
        ),
      );
  await database
      .into(database.exercises)
      .insert(
        ExercisesCompanion.insert(
          id: 'cd-childpose',
          profileId: profileId,
          name: 'Posizione del bambino',
          muscleGroup: 'mobilita',
          trackingMode: 'timed',
          defaultRestSec: const Value(10),
          isPreset: const Value(true),
          isSynthetic: const Value(true),
          source: const Value('cooldown_preset'),
          createdAt: moment,
          updatedAt: moment,
        ),
      );
  await database
      .into(database.routines)
      .insert(
        RoutinesCompanion.insert(
          id: 'routine-1',
          profileId: profileId,
          name: 'Giorno1 spalle petto tricipiti',
          isCircuit: const Value(true),
          rounds: const Value(4),
          source: const Value('gym_tracker'),
          externalId: const Value('gym-routine-1'),
          createdAt: moment,
          updatedAt: moment,
        ),
      );
  await database
      .into(database.routineExercises)
      .insert(
        RoutineExercisesCompanion.insert(
          id: 'routine-exercise-1',
          routineId: 'routine-1',
          block: 'warmup',
          position: 0,
          exerciseRefId: 'cd-childpose',
          exerciseId: const Value('cd-childpose'),
          exerciseNameSnapshot: 'Posizione del bambino',
          warmupDurationSec: const Value(30),
        ),
      );
  await database
      .into(database.routineExercises)
      .insert(
        RoutineExercisesCompanion.insert(
          id: 'routine-exercise-2',
          routineId: 'routine-1',
          block: 'main',
          position: 0,
          exerciseRefId: 'ex-1',
          exerciseId: const Value('ex-1'),
          exerciseNameSnapshot: 'Panca piana',
          prescSets: const Value(4),
          prescReps: const Value(8),
          prescRestSec: const Value(90),
        ),
      );
  await database
      .into(database.routineIntervalSegments)
      .insert(
        RoutineIntervalSegmentsCompanion.insert(
          id: 'routine-segment-1',
          routineId: 'routine-1',
          segmentIndex: 0,
          startIdx: 0,
          endIdx: 1,
          workSec: const Value(40),
          restSec: const Value(20),
          rounds: const Value(3),
        ),
      );
  await database
      .into(database.routineWeeklyPlan)
      .insert(
        RoutineWeeklyPlanCompanion.insert(
          id: 'plan-lunedi',
          profileId: profileId,
          weekday: 1,
          routineId: const Value('routine-1'),
          routineExternalId: const Value('routine-1'),
          routineNameSnapshot: const Value('Giorno1 spalle petto tricipiti'),
          updatedAt: moment,
        ),
      );
  // Il giorno che punta a una scheda cancellata: la FK è nulla ma il nome e
  // l'id originale restano.
  await database
      .into(database.routineWeeklyPlan)
      .insert(
        RoutineWeeklyPlanCompanion.insert(
          id: 'plan-mercoledi',
          profileId: profileId,
          weekday: 3,
          routineExternalId: const Value('e91fda05-scomparsa'),
          routineNameSnapshot: const Value('Esercizi 1'),
          updatedAt: moment,
        ),
      );
  await database
      .into(database.workouts)
      .insert(
        WorkoutsCompanion.insert(
          id: 'workout-1',
          profileId: profileId,
          startedAt: moment,
          endedAt: Value(moment.add(const Duration(minutes: 70))),
          accumulatedPauseSeconds: const Value(300),
          finalDurationSeconds: const Value(3900),
          routineId: const Value('routine-1'),
          routineExternalId: const Value('routine-1'),
          routineNameSnapshot: const Value('Giorno1 spalle petto tricipiti'),
          notes: const Value('Bene la panca.'),
          totalKcal: const Value(477.7840476190476),
          mood: const Value(4),
          rpe: const Value(7),
          satisfaction: const Value(5),
          xpEarned: const Value(120),
          source: const Value('gym_tracker'),
          externalId: const Value('gym-workout-1'),
          createdAt: moment,
          updatedAt: moment,
        ),
      );
  await database
      .into(database.workouts)
      .insert(
        WorkoutsCompanion.insert(
          id: 'workout-2',
          profileId: profileId,
          startedAt: moment.add(const Duration(days: 1)),
          durationSuspect: const Value(true),
          createdAt: moment,
          updatedAt: moment,
        ),
      );
  await database
      .into(database.workoutExercises)
      .insert(
        WorkoutExercisesCompanion.insert(
          id: 'workout-exercise-1',
          workoutId: 'workout-1',
          position: 0,
          exerciseRefId: 'ex-1',
          exerciseId: const Value('ex-1'),
          exerciseNameSnapshot: 'Panca piana',
          trackingMode: 'weightReps',
          muscleGroupSnapshot: const Value('petto'),
          restSeconds: const Value(90),
        ),
      );
  // La riga di un esercizio cancellato dal catalogo: exercise_id nullo,
  // exercise_ref_id no.
  await database
      .into(database.workoutExercises)
      .insert(
        WorkoutExercisesCompanion.insert(
          id: 'workout-exercise-2',
          workoutId: 'workout-1',
          position: 1,
          exerciseRefId: 'ex-sparito',
          exerciseNameSnapshot: 'Esercizio cancellato',
          trackingMode: 'timeOnly',
          isInSupersetWithPrevious: const Value(true),
          intervalSegmentIndex: const Value(0),
        ),
      );
  await database
      .into(database.workoutSets)
      .insert(
        WorkoutSetsCompanion.insert(
          id: 'set-1',
          workoutExerciseId: 'workout-exercise-1',
          position: 0,
          weightKg: const Value(62.5),
          reps: const Value(8),
          completed: const Value(true),
        ),
      );
  await database
      .into(database.workoutSets)
      .insert(
        WorkoutSetsCompanion.insert(
          id: 'set-2',
          workoutExerciseId: 'workout-exercise-1',
          position: 1,
          weightKg: const Value(62.5),
          reps: const Value(6),
          rpe: const Value(9),
          completed: const Value(true),
        ),
      );
  // Serie non completata e con la sola durata: la metrica non segue la
  // modalità, e il ripristino non deve inventarla.
  await database
      .into(database.workoutSets)
      .insert(
        WorkoutSetsCompanion.insert(
          id: 'set-3',
          workoutExerciseId: 'workout-exercise-2',
          position: 0,
          durationSec: const Value(45),
        ),
      );
  await database
      .into(database.workoutPainPoints)
      .insert(
        WorkoutPainPointsCompanion.insert(
          id: 'pain-1',
          workoutId: 'workout-1',
          label: 'Spalla destra',
        ),
      );
  await database
      .into(database.workoutIntervalSegments)
      .insert(
        WorkoutIntervalSegmentsCompanion.insert(
          id: 'workout-segment-1',
          workoutId: 'workout-1',
          segmentIndex: 0,
          completedMarker: const Value(true),
          partialMarker: const Value(true),
          completionSignature: const Value('{"work":40,"rest":20}'),
        ),
      );
  await database
      .into(database.workoutProfileStats)
      .insert(
        WorkoutProfileStatsCompanion.insert(
          id: 'stats-1',
          profileId: profileId,
          totalXp: const Value(11370),
          currentStreak: const Value(2),
          longestStreak: const Value(2),
          lastWorkoutDay: Value(moment),
          weeklyWorkoutGoal: const Value(4),
          reminderEnabled: const Value(true),
          healthConnectEnabled: const Value(true),
          gymBodyWeightKg: const Value(94.7),
          gymExportedAt: Value(moment),
          createdAt: moment,
          updatedAt: moment,
        ),
      );
  await database
      .into(database.workoutAchievements)
      .insert(
        WorkoutAchievementsCompanion.insert(
          id: 'achievement-1',
          profileId: profileId,
          slug: 'pr_10',
        ),
      );
  await database
      .into(database.workoutAchievements)
      .insert(
        WorkoutAchievementsCompanion.insert(
          id: 'achievement-2',
          profileId: profileId,
          slug: 'streak_2',
          unlockedAt: Value(moment),
        ),
      );
  await database
      .into(database.bodyMeasurementValues)
      .insert(
        BodyMeasurementValuesCompanion.insert(
          id: 'girth-1',
          measurementId: 'weight-1',
          label: 'Vita',
          value: 96,
        ),
      );
}
