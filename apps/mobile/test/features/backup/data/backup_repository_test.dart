import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull;
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
}) => BackupDocument(
  formatVersion: source.formatVersion,
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
);

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
