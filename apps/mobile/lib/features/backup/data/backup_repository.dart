import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/backup/domain/backup_document.dart';
import 'package:kal_tracker/features/backup/domain/backup_restore.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:uuid/uuid.dart';

class BackupRepository {
  BackupRepository(this._database, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  /// Alimenti forniti dall'app (seed essenziali e catalogo piatti):
  /// sopravvivono al restore «sostituisci tutto» e non generano tombstone.
  static const List<String> _builtInFoodSources = ['seed', 'catalog'];

  final AppDatabase _database;
  final Uuid _uuid;

  Future<BackupDocument> exportBackup({
    required String profileId,
    String appVersion = BackupDocument.unknownAppVersion,
    DateTime? exportedAt,
  }) async {
    final profile = await (_database.select(
      _database.appProfiles,
    )..where((row) => row.id.equals(profileId))).getSingleOrNull();
    if (profile == null) {
      throw StateError('Profilo non trovato.');
    }

    final meals =
        await (_database.select(_database.meals)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();
    final mealIds = meals.map((row) => row.id).toList(growable: false);
    final mealItems = mealIds.isEmpty
        ? const <MealItem>[]
        : await (_database.select(_database.mealItems)
                ..where((row) => row.mealId.isIn(mealIds))
                ..orderBy([(row) => OrderingTerm.asc(row.id)]))
              .get();

    final targets = await (_database.select(
      _database.nutritionTargets,
    )..where((row) => row.profileId.equals(profileId))).get();
    final waterLogs =
        await (_database.select(_database.waterLogs)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();
    final measurements =
        await (_database.select(_database.bodyMeasurements)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();

    final foods =
        await (_database.select(_database.foods)
              ..where((row) => row.ownerProfileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();
    final preferences =
        await (_database.select(_database.foodPreferences)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.foodId)]))
            .get();

    final recipes =
        await (_database.select(_database.fitRecipes)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();
    final recipeIds = recipes.map((row) => row.id).toList(growable: false);
    final ingredients = recipeIds.isEmpty
        ? const <LocalRecipeIngredient>[]
        : await (_database.select(_database.recipeIngredients)
                ..where((row) => row.recipeId.isIn(recipeIds))
                ..orderBy([(row) => OrderingTerm.asc(row.id)]))
              .get();

    final templates =
        await (_database.select(_database.mealTemplates)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();
    final templateIds = templates.map((row) => row.id).toList(growable: false);
    final templateItems = templateIds.isEmpty
        ? const <LocalMealTemplateItem>[]
        : await (_database.select(_database.mealTemplateItems)
                ..where((row) => row.templateId.isIn(templateIds))
                ..orderBy([(row) => OrderingTerm.asc(row.id)]))
              .get();

    return BackupDocument(
      formatVersion: BackupDocument.currentFormatVersion,
      appVersion: appVersion,
      exportedAt: (exportedAt ?? AppTime.nowUtc()).toUtc(),
      profile: BackupProfile(
        id: profile.id,
        displayName: profile.displayName,
        createdAt: profile.createdAt,
        updatedAt: profile.updatedAt,
      ),
      meals: [
        for (final row in meals)
          BackupMeal(
            id: row.id,
            profileId: row.profileId,
            mealType: row.mealType,
            eatenAt: row.eatenAt,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      mealItems: [
        for (final row in mealItems)
          BackupMealItem(
            id: row.id,
            mealId: row.mealId,
            foodName: row.foodName,
            grams: row.grams,
            caloriesPer100g: row.caloriesPer100g,
            proteinPer100g: row.proteinPer100g,
            carbsPer100g: row.carbsPer100g,
            fatPer100g: row.fatPer100g,
            totalCalories: row.totalCalories,
            totalProtein: row.totalProtein,
            totalCarbs: row.totalCarbs,
            totalFat: row.totalFat,
            source: row.source,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      nutritionTargets: [
        for (final row in targets)
          BackupNutritionTarget(
            profileId: row.profileId,
            dailyCalories: row.dailyCalories,
            dailyProtein: row.dailyProtein,
            dailyCarbs: row.dailyCarbs,
            dailyFat: row.dailyFat,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      waterLogs: [
        for (final row in waterLogs)
          BackupWaterLog(
            id: row.id,
            profileId: row.profileId,
            milliliters: row.milliliters,
            loggedAt: row.loggedAt,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      bodyMeasurements: [
        for (final row in measurements)
          BackupBodyMeasurement(
            id: row.id,
            profileId: row.profileId,
            weightKg: row.weightKg,
            measuredAt: row.measuredAt,
            note: row.note,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      foods: [
        for (final row in foods)
          BackupFood(
            id: row.id,
            ownerProfileId: row.ownerProfileId,
            name: row.name,
            brand: row.brand,
            barcode: row.barcode,
            caloriesPer100g: row.caloriesPer100g,
            proteinPer100g: row.proteinPer100g,
            carbsPer100g: row.carbsPer100g,
            fatPer100g: row.fatPer100g,
            defaultServingGrams: row.defaultServingGrams,
            source: row.source,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      foodPreferences: [
        for (final row in preferences)
          BackupFoodPreference(
            profileId: row.profileId,
            foodId: row.foodId,
            isFavorite: row.isFavorite,
            useCount: row.useCount,
            lastUsedAt: row.lastUsedAt,
            updatedAt: row.updatedAt,
          ),
      ],
      fitRecipes: [
        for (final row in recipes)
          BackupRecipe(
            id: row.id,
            profileId: row.profileId,
            name: row.name,
            description: row.description,
            instructions: row.instructions,
            tags: row.tags,
            servings: row.servings,
            prepMinutes: row.prepMinutes,
            totalCalories: row.totalCalories,
            totalProtein: row.totalProtein,
            totalCarbs: row.totalCarbs,
            totalFat: row.totalFat,
            isFavorite: row.isFavorite,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      recipeIngredients: [
        for (final row in ingredients)
          BackupRecipeIngredient(
            id: row.id,
            recipeId: row.recipeId,
            foodId: row.foodId,
            position: row.position,
            name: row.name,
            grams: row.grams,
            caloriesPer100g: row.caloriesPer100g,
            proteinPer100g: row.proteinPer100g,
            carbsPer100g: row.carbsPer100g,
            fatPer100g: row.fatPer100g,
          ),
      ],
      mealTemplates: [
        for (final row in templates)
          BackupMealTemplate(
            id: row.id,
            profileId: row.profileId,
            name: row.name,
            mealType: row.mealType,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      mealTemplateItems: [
        for (final row in templateItems)
          BackupMealTemplateItem(
            id: row.id,
            templateId: row.templateId,
            position: row.position,
            foodName: row.foodName,
            grams: row.grams,
            caloriesPer100g: row.caloriesPer100g,
            proteinPer100g: row.proteinPer100g,
            carbsPer100g: row.carbsPer100g,
            fatPer100g: row.fatPer100g,
          ),
      ],
    );
  }

  Future<BackupRestoreSummary> importBackup(
    String json, {
    required BackupRestoreMode mode,
  }) async {
    final document = BackupDocument.decode(json);
    final now = AppTime.nowUtc();
    try {
      return await _database.transaction(
        () => _restore(document: document, mode: mode, now: now),
      );
    } on BackupFormatException {
      rethrow;
    } on Object {
      throw const BackupFormatException(
        'Ripristino non riuscito: i dati del backup non sono compatibili con '
        'questo diario. Non è stato modificato niente.',
      );
    }
  }

  Future<BackupRestoreSummary> _restore({
    required BackupDocument document,
    required BackupRestoreMode mode,
    required DateTime now,
  }) async {
    final counters = _RestoreCounters();
    final replacing = mode == BackupRestoreMode.replace;
    final removable = replacing
        ? await _existingKeys()
        : const <String, Set<String>>{};
    if (replacing) {
      await _wipeUserTables();
    }

    final profileId = await _restoreProfile(
      profile: document.profile,
      replacing: replacing,
      counters: counters,
      now: now,
    );

    await _restoreFoods(document, profileId, replacing, counters, now);
    await _restoreFoodPreferences(
      document,
      profileId,
      replacing,
      counters,
      now,
    );
    await _restoreMeals(document, profileId, replacing, counters, now);
    await _restoreTargets(document, profileId, replacing, counters, now);
    await _restoreWaterLogs(document, profileId, replacing, counters, now);
    await _restoreMeasurements(document, profileId, replacing, counters, now);
    await _restoreRecipes(document, profileId, replacing, counters, now);
    await _restoreTemplates(document, profileId, replacing, counters, now);

    if (replacing) {
      await _appendTombstones(
        removable: removable,
        restored: _restoredKeys(document, profileId),
        now: now,
      );
    }

    return BackupRestoreSummary(
      mode: mode,
      created: counters.created,
      updated: counters.updated,
      skipped: counters.skipped,
    );
  }

  Future<String> _restoreProfile({
    required BackupProfile profile,
    required bool replacing,
    required _RestoreCounters counters,
    required DateTime now,
  }) async {
    final existing = replacing
        ? null
        : await (_database.select(
            _database.appProfiles,
          )..limit(1)).getSingleOrNull();
    if (existing == null) {
      await _database
          .into(_database.appProfiles)
          .insert(
            AppProfilesCompanion.insert(
              id: profile.id,
              displayName: profile.displayName,
              createdAt: profile.createdAt,
              updatedAt: profile.updatedAt,
            ),
          );
      counters.created++;
      return profile.id;
    }
    if (existing.id == profile.id &&
        profile.updatedAt.isAfter(existing.updatedAt)) {
      await (_database.update(
        _database.appProfiles,
      )..where((row) => row.id.equals(profile.id))).write(
        AppProfilesCompanion(
          displayName: Value(profile.displayName),
          updatedAt: Value(profile.updatedAt),
        ),
      );
      counters.updated++;
    } else {
      counters.skipped++;
    }
    return existing.id;
  }

  Future<void> _restoreFoods(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
    DateTime now,
  ) async {
    for (final food in document.foods) {
      final existing = replacing
          ? null
          : await (_database.select(
              _database.foods,
            )..where((row) => row.id.equals(food.id))).getSingleOrNull();
      if (existing != null && !food.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.foods)
          .insertOnConflictUpdate(
            FoodsCompanion(
              id: Value(food.id),
              ownerProfileId: Value(
                food.ownerProfileId == null ? null : profileId,
              ),
              name: Value(food.name),
              brand: Value(food.brand),
              barcode: Value(food.barcode),
              caloriesPer100g: Value(food.caloriesPer100g),
              proteinPer100g: Value(food.proteinPer100g),
              carbsPer100g: Value(food.carbsPer100g),
              fatPer100g: Value(food.fatPer100g),
              defaultServingGrams: Value(food.defaultServingGrams),
              source: Value(food.source),
              createdAt: Value(food.createdAt),
              updatedAt: Value(food.updatedAt),
              deletedAt: Value(food.deletedAt),
            ),
          );
      _count(counters, existing != null);
      await _appendOutbox(
        entityType: 'food',
        entityId: food.id,
        payload: {
          ...food.toJson(),
          'owner_profile_id': food.ownerProfileId == null ? null : profileId,
        },
        now: now,
      );
    }
  }

  Future<void> _restoreFoodPreferences(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
    DateTime now,
  ) async {
    for (final preference in document.foodPreferences) {
      final existing = replacing
          ? null
          : await (_database.select(_database.foodPreferences)..where(
                  (row) =>
                      row.profileId.equals(profileId) &
                      row.foodId.equals(preference.foodId),
                ))
                .getSingleOrNull();
      if (existing != null &&
          !preference.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.foodPreferences)
          .insertOnConflictUpdate(
            FoodPreferencesCompanion(
              profileId: Value(profileId),
              foodId: Value(preference.foodId),
              isFavorite: Value(preference.isFavorite),
              useCount: Value(preference.useCount),
              lastUsedAt: Value(preference.lastUsedAt),
              updatedAt: Value(preference.updatedAt),
            ),
          );
      _count(counters, existing != null);
      await _appendOutbox(
        entityType: 'food_preference',
        entityId: '$profileId:${preference.foodId}',
        payload: {...preference.toJson(), 'profile_id': profileId},
        now: now,
      );
    }
  }

  Future<void> _restoreMeals(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
    DateTime now,
  ) async {
    for (final meal in document.meals) {
      final existing = replacing
          ? null
          : await (_database.select(
              _database.meals,
            )..where((row) => row.id.equals(meal.id))).getSingleOrNull();
      if (existing != null && !meal.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.meals)
          .insertOnConflictUpdate(
            MealsCompanion(
              id: Value(meal.id),
              profileId: Value(profileId),
              mealType: Value(meal.mealType),
              eatenAt: Value(meal.eatenAt),
              createdAt: Value(meal.createdAt),
              updatedAt: Value(meal.updatedAt),
              deletedAt: Value(meal.deletedAt),
            ),
          );
      _count(counters, existing != null);
    }

    final mealsById = {for (final meal in document.meals) meal.id: meal};
    for (final item in document.mealItems) {
      final existing = replacing
          ? null
          : await (_database.select(
              _database.mealItems,
            )..where((row) => row.id.equals(item.id))).getSingleOrNull();
      if (existing != null && !item.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      final totals = _itemTotals(item);
      await _database
          .into(_database.mealItems)
          .insertOnConflictUpdate(
            MealItemsCompanion(
              id: Value(item.id),
              mealId: Value(item.mealId),
              foodName: Value(item.foodName),
              grams: Value(item.grams),
              caloriesPer100g: Value(item.caloriesPer100g),
              proteinPer100g: Value(item.proteinPer100g),
              carbsPer100g: Value(item.carbsPer100g),
              fatPer100g: Value(item.fatPer100g),
              totalCalories: Value(totals.calories),
              totalProtein: Value(totals.protein),
              totalCarbs: Value(totals.carbs),
              totalFat: Value(totals.fat),
              source: Value(item.source),
              createdAt: Value(item.createdAt),
              updatedAt: Value(item.updatedAt),
              deletedAt: Value(item.deletedAt),
            ),
          );
      _count(counters, existing != null);
      final meal = mealsById[item.mealId];
      await _appendOutbox(
        entityType: 'meal_item',
        entityId: item.id,
        payload: {
          ...item.toJson(),
          ..._totalsJson(totals),
          'profile_id': profileId,
          if (meal != null) 'meal_type': meal.mealType,
          if (meal != null) 'eaten_at': meal.eatenAt.toUtc().toIso8601String(),
        },
        now: now,
      );
    }
  }

  Future<void> _restoreTargets(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
    DateTime now,
  ) async {
    for (final target in document.nutritionTargets) {
      final existing = replacing
          ? null
          : await (_database.select(_database.nutritionTargets)
                  ..where((row) => row.profileId.equals(profileId)))
                .getSingleOrNull();
      if (existing != null && !target.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.nutritionTargets)
          .insertOnConflictUpdate(
            NutritionTargetsCompanion(
              profileId: Value(profileId),
              dailyCalories: Value(target.dailyCalories),
              dailyProtein: Value(target.dailyProtein),
              dailyCarbs: Value(target.dailyCarbs),
              dailyFat: Value(target.dailyFat),
              createdAt: Value(target.createdAt),
              updatedAt: Value(target.updatedAt),
              deletedAt: Value(target.deletedAt),
            ),
          );
      _count(counters, existing != null);
      await _appendOutbox(
        entityType: 'nutrition_target',
        entityId: profileId,
        payload: {...target.toJson(), 'profile_id': profileId},
        now: now,
      );
    }
  }

  Future<void> _restoreWaterLogs(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
    DateTime now,
  ) async {
    for (final log in document.waterLogs) {
      final existing = replacing
          ? null
          : await (_database.select(
              _database.waterLogs,
            )..where((row) => row.id.equals(log.id))).getSingleOrNull();
      if (existing != null && !log.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.waterLogs)
          .insertOnConflictUpdate(
            WaterLogsCompanion(
              id: Value(log.id),
              profileId: Value(profileId),
              milliliters: Value(log.milliliters),
              loggedAt: Value(log.loggedAt),
              createdAt: Value(log.createdAt),
              updatedAt: Value(log.updatedAt),
              deletedAt: Value(log.deletedAt),
            ),
          );
      _count(counters, existing != null);
      await _appendOutbox(
        entityType: 'water_log',
        entityId: log.id,
        payload: {...log.toJson(), 'profile_id': profileId},
        now: now,
      );
    }
  }

  Future<void> _restoreMeasurements(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
    DateTime now,
  ) async {
    for (final measurement in document.bodyMeasurements) {
      final existing = replacing
          ? null
          : await (_database.select(
              _database.bodyMeasurements,
            )..where((row) => row.id.equals(measurement.id))).getSingleOrNull();
      if (existing != null &&
          !measurement.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.bodyMeasurements)
          .insertOnConflictUpdate(
            BodyMeasurementsCompanion(
              id: Value(measurement.id),
              profileId: Value(profileId),
              weightKg: Value(measurement.weightKg),
              measuredAt: Value(measurement.measuredAt),
              note: Value(measurement.note),
              createdAt: Value(measurement.createdAt),
              updatedAt: Value(measurement.updatedAt),
              deletedAt: Value(measurement.deletedAt),
            ),
          );
      _count(counters, existing != null);
      await _appendOutbox(
        entityType: 'body_measurement',
        entityId: measurement.id,
        payload: {...measurement.toJson(), 'profile_id': profileId},
        now: now,
      );
    }
  }

  Future<void> _restoreRecipes(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
    DateTime now,
  ) async {
    final ingredientsByRecipe = <String, List<BackupRecipeIngredient>>{};
    for (final ingredient in document.recipeIngredients) {
      ingredientsByRecipe
          .putIfAbsent(ingredient.recipeId, () => [])
          .add(ingredient);
    }

    for (final recipe in document.fitRecipes) {
      final existing = replacing
          ? null
          : await (_database.select(
              _database.fitRecipes,
            )..where((row) => row.id.equals(recipe.id))).getSingleOrNull();
      if (existing != null && !recipe.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      final ingredients =
          ingredientsByRecipe[recipe.id] ?? const <BackupRecipeIngredient>[];
      final totals = _recipeTotals(ingredients);
      await _database
          .into(_database.fitRecipes)
          .insertOnConflictUpdate(
            FitRecipesCompanion(
              id: Value(recipe.id),
              profileId: Value(profileId),
              name: Value(recipe.name),
              description: Value(recipe.description),
              instructions: Value(recipe.instructions),
              tags: Value(recipe.tags),
              servings: Value(recipe.servings),
              prepMinutes: Value(recipe.prepMinutes),
              totalCalories: Value(totals.calories),
              totalProtein: Value(totals.protein),
              totalCarbs: Value(totals.carbs),
              totalFat: Value(totals.fat),
              isFavorite: Value(recipe.isFavorite),
              createdAt: Value(recipe.createdAt),
              updatedAt: Value(recipe.updatedAt),
              deletedAt: Value(recipe.deletedAt),
            ),
          );
      if (existing != null) {
        await (_database.delete(
          _database.recipeIngredients,
        )..where((row) => row.recipeId.equals(recipe.id))).go();
      }
      for (final ingredient in ingredients) {
        await _database
            .into(_database.recipeIngredients)
            .insertOnConflictUpdate(
              RecipeIngredientsCompanion(
                id: Value(ingredient.id),
                recipeId: Value(ingredient.recipeId),
                foodId: Value(ingredient.foodId),
                position: Value(ingredient.position),
                name: Value(ingredient.name),
                grams: Value(ingredient.grams),
                caloriesPer100g: Value(ingredient.caloriesPer100g),
                proteinPer100g: Value(ingredient.proteinPer100g),
                carbsPer100g: Value(ingredient.carbsPer100g),
                fatPer100g: Value(ingredient.fatPer100g),
              ),
            );
      }
      _count(counters, existing != null);
      await _appendOutbox(
        entityType: 'fit_recipe',
        entityId: recipe.id,
        payload: {
          ...recipe.toJson(),
          ..._totalsJson(totals),
          'profile_id': profileId,
          'ingredients': [
            for (final ingredient in ingredients) ingredient.toJson(),
          ],
        },
        now: now,
      );
    }
  }

  Future<void> _restoreTemplates(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
    DateTime now,
  ) async {
    final itemsByTemplate = <String, List<BackupMealTemplateItem>>{};
    for (final item in document.mealTemplateItems) {
      itemsByTemplate.putIfAbsent(item.templateId, () => []).add(item);
    }

    for (final template in document.mealTemplates) {
      final existing = replacing
          ? null
          : await (_database.select(
              _database.mealTemplates,
            )..where((row) => row.id.equals(template.id))).getSingleOrNull();
      if (existing != null && !template.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.mealTemplates)
          .insertOnConflictUpdate(
            MealTemplatesCompanion(
              id: Value(template.id),
              profileId: Value(profileId),
              name: Value(template.name),
              mealType: Value(template.mealType),
              createdAt: Value(template.createdAt),
              updatedAt: Value(template.updatedAt),
              deletedAt: Value(template.deletedAt),
            ),
          );
      if (existing != null) {
        await (_database.delete(
          _database.mealTemplateItems,
        )..where((row) => row.templateId.equals(template.id))).go();
      }
      final items =
          itemsByTemplate[template.id] ?? const <BackupMealTemplateItem>[];
      for (final item in items) {
        await _database
            .into(_database.mealTemplateItems)
            .insertOnConflictUpdate(
              MealTemplateItemsCompanion(
                id: Value(item.id),
                templateId: Value(item.templateId),
                position: Value(item.position),
                foodName: Value(item.foodName),
                grams: Value(item.grams),
                caloriesPer100g: Value(item.caloriesPer100g),
                proteinPer100g: Value(item.proteinPer100g),
                carbsPer100g: Value(item.carbsPer100g),
                fatPer100g: Value(item.fatPer100g),
              ),
            );
      }
      _count(counters, existing != null);
      await _appendOutbox(
        entityType: 'meal_template',
        entityId: template.id,
        payload: {
          ...template.toJson(),
          'profile_id': profileId,
          'items': [for (final item in items) item.toJson()],
        },
        now: now,
      );
    }
  }

  Future<Map<String, Set<String>>> _existingKeys() async {
    final foods = await (_database.select(
      _database.foods,
    )..where((row) => row.source.isIn(_builtInFoodSources).not())).get();
    final preferences = await _database.select(_database.foodPreferences).get();
    final targets = await _database.select(_database.nutritionTargets).get();
    return {
      'meal_item': {
        for (final row in await _database.select(_database.mealItems).get())
          row.id,
      },
      'water_log': {
        for (final row in await _database.select(_database.waterLogs).get())
          row.id,
      },
      'body_measurement': {
        for (final row
            in await _database.select(_database.bodyMeasurements).get())
          row.id,
      },
      'fit_recipe': {
        for (final row in await _database.select(_database.fitRecipes).get())
          row.id,
      },
      'meal_template': {
        for (final row in await _database.select(_database.mealTemplates).get())
          row.id,
      },
      'food': {for (final row in foods) row.id},
      'food_preference': {
        for (final row in preferences) '${row.profileId}:${row.foodId}',
      },
      'nutrition_target': {for (final row in targets) row.profileId},
    };
  }

  Map<String, Set<String>> _restoredKeys(
    BackupDocument document,
    String profileId,
  ) => {
    'meal_item': {for (final row in document.mealItems) row.id},
    'water_log': {for (final row in document.waterLogs) row.id},
    'body_measurement': {for (final row in document.bodyMeasurements) row.id},
    'fit_recipe': {for (final row in document.fitRecipes) row.id},
    'meal_template': {for (final row in document.mealTemplates) row.id},
    'food': {for (final row in document.foods) row.id},
    'food_preference': {
      for (final row in document.foodPreferences) '$profileId:${row.foodId}',
    },
    'nutrition_target': document.nutritionTargets.isEmpty
        ? const <String>{}
        : {profileId},
  };

  Future<void> _wipeUserTables() async {
    await _database.delete(_database.mealItems).go();
    await _database.delete(_database.meals).go();
    await _database.delete(_database.mealTemplateItems).go();
    await _database.delete(_database.mealTemplates).go();
    await _database.delete(_database.recipeIngredients).go();
    await _database.delete(_database.fitRecipes).go();
    await _database.delete(_database.foodPreferences).go();
    await (_database.delete(
      _database.foods,
    )..where((row) => row.source.isIn(_builtInFoodSources).not())).go();
    await _database.delete(_database.waterLogs).go();
    await _database.delete(_database.bodyMeasurements).go();
    await _database.delete(_database.nutritionTargets).go();
    await _database.delete(_database.appProfiles).go();
  }

  Future<void> _appendTombstones({
    required Map<String, Set<String>> removable,
    required Map<String, Set<String>> restored,
    required DateTime now,
  }) async {
    for (final entry in removable.entries) {
      final survivors = restored[entry.key] ?? const <String>{};
      for (final key in entry.value.difference(survivors)) {
        await _appendOutbox(
          entityType: entry.key,
          entityId: key,
          operation: 'delete',
          payload: {
            ..._identity(entry.key, key),
            'deleted_at': now.toIso8601String(),
          },
          now: now,
        );
      }
    }
  }

  /// Ripete la chiave con cui l’upsert identifica la riga: le tabelle senza
  /// colonna `id` non sarebbero cancellabili con `{'id': ...}`.
  Map<String, Object?> _identity(String entityType, String key) {
    if (entityType == 'food_preference') {
      final parts = key.split(':');
      return {'profile_id': parts.first, 'food_id': parts.last};
    }
    if (entityType == 'nutrition_target') {
      return {'profile_id': key};
    }
    return {'id': key};
  }

  /// I totali non arrivano mai dal file: si ricalcolano da per 100 g × grammi.
  Nutrients _itemTotals(BackupMealItem item) => NutritionCalculator.scale(
    per100g: Nutrients(
      calories: item.caloriesPer100g,
      protein: item.proteinPer100g,
      carbs: item.carbsPer100g,
      fat: item.fatPer100g,
    ),
    grams: item.grams,
  );

  Nutrients _recipeTotals(List<BackupRecipeIngredient> ingredients) {
    var total = const Nutrients.zero();
    for (final ingredient in ingredients) {
      total =
          total +
          NutritionCalculator.scale(
            per100g: Nutrients(
              calories: ingredient.caloriesPer100g,
              protein: ingredient.proteinPer100g,
              carbs: ingredient.carbsPer100g,
              fat: ingredient.fatPer100g,
            ),
            grams: ingredient.grams,
          );
    }
    return total;
  }

  Map<String, Object?> _totalsJson(Nutrients totals) => {
    'total_calories': totals.calories,
    'total_protein': totals.protein,
    'total_carbs': totals.carbs,
    'total_fat': totals.fat,
  };

  void _count(_RestoreCounters counters, bool existed) {
    if (existed) {
      counters.updated++;
    } else {
      counters.created++;
    }
  }

  Future<void> _appendOutbox({
    required String entityType,
    required String entityId,
    required Map<String, Object?> payload,
    required DateTime now,
    String operation = 'upsert',
  }) => _database
      .into(_database.syncOutbox)
      .insert(
        SyncOutboxCompanion.insert(
          id: _uuid.v4(),
          entityType: entityType,
          entityId: entityId,
          operation: operation,
          payloadJson: jsonEncode(payload),
          createdAt: now,
        ),
      );
}

class _RestoreCounters {
  int created = 0;
  int updated = 0;
  int skipped = 0;
}
