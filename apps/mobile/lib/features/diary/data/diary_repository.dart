import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:uuid/uuid.dart';

class DiaryRepository {
  DiaryRepository(this._database, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final AppDatabase _database;
  final Uuid _uuid;

  Stream<DailyDiary> watchDay({
    required String profileId,
    required DateTime day,
  }) {
    final start = AppTime.startOfDayUtc(day);
    final end = AppTime.endOfDayUtc(day);

    final query = _database.select(_database.mealItems).join([
      innerJoin(
        _database.meals,
        _database.meals.id.equalsExp(_database.mealItems.mealId),
      ),
    ]);

    query
      ..where(
        _database.meals.profileId.equals(profileId) &
            _database.meals.eatenAt.isBiggerOrEqualValue(start) &
            _database.meals.eatenAt.isSmallerThanValue(end) &
            _database.meals.deletedAt.isNull() &
            _database.mealItems.deletedAt.isNull(),
      )
      ..orderBy([
        OrderingTerm.asc(_database.meals.eatenAt),
        OrderingTerm.asc(_database.mealItems.createdAt),
      ]);

    return query.watch().map((rows) {
      final entries = rows
          .map(
            (row) => _toEntry(
              meal: row.readTable(_database.meals),
              item: row.readTable(_database.mealItems),
            ),
          )
          .toList(growable: false);
      return DailyDiary.fromEntries(entries);
    });
  }

  Future<List<DiaryEntry>> entriesForMeal({
    required String profileId,
    required DateTime day,
    required MealType mealType,
  }) async {
    final start = AppTime.startOfDayUtc(day);
    final end = AppTime.endOfDayUtc(day);

    final query = _database.select(_database.mealItems).join([
      innerJoin(
        _database.meals,
        _database.meals.id.equalsExp(_database.mealItems.mealId),
      ),
    ]);

    query
      ..where(
        _database.meals.profileId.equals(profileId) &
            _database.meals.mealType.equals(mealType.storageValue) &
            _database.meals.eatenAt.isBiggerOrEqualValue(start) &
            _database.meals.eatenAt.isSmallerThanValue(end) &
            _database.meals.deletedAt.isNull() &
            _database.mealItems.deletedAt.isNull(),
      )
      ..orderBy([OrderingTerm.asc(_database.mealItems.createdAt)]);

    final rows = await query.get();
    return rows
        .map(
          (row) => _toEntry(
            meal: row.readTable(_database.meals),
            item: row.readTable(_database.mealItems),
          ),
        )
        .toList(growable: false);
  }

  Future<String> addManualFood({
    required String profileId,
    required ManualFoodInput input,
  }) async {
    final ids = await addEntries(profileId: profileId, inputs: [input]);
    return ids.single;
  }

  Future<List<String>> addEntries({
    required String profileId,
    required List<ManualFoodInput> inputs,
  }) async {
    if (inputs.isEmpty) {
      return const [];
    }
    for (final input in inputs) {
      input.validate();
    }
    final now = AppTime.nowUtc();

    return _database.transaction(() async {
      final ids = <String>[];
      for (final input in inputs) {
        final meal = await _findOrCreateMeal(
          profileId: profileId,
          mealType: input.mealType,
          day: input.eatenAt,
          eatenAt: input.eatenAt,
          now: now,
        );
        final itemId = _uuid.v4();
        await _insertItem(
          itemId: itemId,
          meal: meal,
          foodName: input.foodName.trim(),
          grams: input.grams,
          per100g: input.per100g,
          now: now,
        );
        ids.add(itemId);
      }
      return List<String>.unmodifiable(ids);
    });
  }

  Future<void> updateEntry({
    required String itemId,
    String? foodName,
    double? grams,
    Nutrients? per100g,
    MealType? mealType,
  }) async {
    final now = AppTime.nowUtc();
    await _database.transaction(() async {
      final existing = await _requireEditableItem(itemId);
      final currentMeal = await (_database.select(
        _database.meals,
      )..where((meal) => meal.id.equals(existing.mealId))).getSingle();

      final resolvedName = (foodName ?? existing.foodName).trim();
      final resolvedGrams = grams ?? existing.grams;
      final resolvedPer100g = per100g ?? _per100gOf(existing);
      final resolvedMealType =
          mealType ?? MealType.fromStorage(currentMeal.mealType);
      final day = AppTime.inRome(currentMeal.eatenAt);

      ManualFoodInput(
        foodName: resolvedName,
        grams: resolvedGrams,
        per100g: resolvedPer100g,
        mealType: resolvedMealType,
        eatenAt: day,
      ).validate();
      final totals = NutritionCalculator.scale(
        per100g: resolvedPer100g,
        grams: resolvedGrams,
      );

      final targetMeal = resolvedMealType.storageValue == currentMeal.mealType
          ? currentMeal
          : await _findOrCreateMeal(
              profileId: currentMeal.profileId,
              mealType: resolvedMealType,
              day: day,
              eatenAt: currentMeal.eatenAt,
              now: now,
            );

      final changedRows =
          await (_database.update(_database.mealItems)..where(
                (item) => item.id.equals(itemId) & item.deletedAt.isNull(),
              ))
              .write(
                MealItemsCompanion(
                  mealId: Value(targetMeal.id),
                  foodName: Value(resolvedName),
                  grams: Value(resolvedGrams),
                  caloriesPer100g: Value(resolvedPer100g.calories),
                  proteinPer100g: Value(resolvedPer100g.protein),
                  carbsPer100g: Value(resolvedPer100g.carbs),
                  fatPer100g: Value(resolvedPer100g.fat),
                  totalCalories: Value(totals.calories),
                  totalProtein: Value(totals.protein),
                  totalCarbs: Value(totals.carbs),
                  totalFat: Value(totals.fat),
                  updatedAt: Value(now),
                ),
              );
      if (changedRows != 1) {
        throw StateError('La voce del diario è stata modificata.');
      }

      await _writeItemOutbox(
        itemId: itemId,
        meal: targetMeal,
        foodName: resolvedName,
        grams: resolvedGrams,
        per100g: resolvedPer100g,
        totals: totals,
        now: now,
      );
    });
  }

  Future<String> duplicateEntry(
    String itemId, {
    DateTime? toDay,
    MealType? toMealType,
  }) async {
    final existing = await _requireEditableItem(itemId);
    final meal = await (_database.select(
      _database.meals,
    )..where((row) => row.id.equals(existing.mealId))).getSingle();

    final eatenAt = toDay == null
        ? AppTime.inRome(meal.eatenAt)
        : DiaryDay.instantFor(toDay);

    return addManualFood(
      profileId: meal.profileId,
      input: ManualFoodInput(
        foodName: existing.foodName,
        grams: existing.grams,
        per100g: _per100gOf(existing),
        mealType: toMealType ?? MealType.fromStorage(meal.mealType),
        eatenAt: eatenAt,
      ),
    );
  }

  Future<List<String>> copyMeal({
    required String profileId,
    required DateTime fromDay,
    required MealType mealType,
    required DateTime toDay,
  }) async {
    final source = await entriesForMeal(
      profileId: profileId,
      day: fromDay,
      mealType: mealType,
    );
    if (source.isEmpty) {
      return const [];
    }
    final eatenAt = DiaryDay.instantFor(toDay);

    return addEntries(
      profileId: profileId,
      inputs: [
        for (final entry in source)
          ManualFoodInput(
            foodName: entry.foodName,
            grams: entry.grams,
            per100g: entry.per100g,
            mealType: mealType,
            eatenAt: eatenAt,
          ),
      ],
    );
  }

  Future<void> deleteEntry(String itemId) async {
    final now = AppTime.nowUtc();
    await _database.transaction(() async {
      final existing = await (_database.select(
        _database.mealItems,
      )..where((item) => item.id.equals(itemId))).getSingleOrNull();
      if (existing == null) {
        throw StateError('Voce del diario non trovata.');
      }
      if (existing.deletedAt != null) {
        return;
      }

      final changedRows =
          await (_database.update(_database.mealItems)..where(
                (item) => item.id.equals(itemId) & item.deletedAt.isNull(),
              ))
              .write(
                MealItemsCompanion(
                  deletedAt: Value(now),
                  updatedAt: Value(now),
                ),
              );
      if (changedRows != 1) {
        throw StateError('La voce del diario è stata modificata.');
      }
      await _database
          .into(_database.syncOutbox)
          .insert(
            SyncOutboxCompanion.insert(
              id: _uuid.v4(),
              entityType: 'meal_item',
              entityId: itemId,
              operation: 'delete',
              payloadJson: jsonEncode({
                'id': itemId,
                'deleted_at': now.toUtc().toIso8601String(),
              }),
              createdAt: now,
            ),
          );
    });
  }

  Future<MealItem> _requireEditableItem(String itemId) async {
    final existing = await (_database.select(
      _database.mealItems,
    )..where((item) => item.id.equals(itemId))).getSingleOrNull();
    if (existing == null) {
      throw StateError('Voce del diario non trovata.');
    }
    if (existing.deletedAt != null) {
      throw StateError('La voce del diario è già stata cancellata.');
    }
    return existing;
  }

  Future<Meal> _findOrCreateMeal({
    required String profileId,
    required MealType mealType,
    required DateTime day,
    required DateTime eatenAt,
    required DateTime now,
  }) async {
    final dayStart = AppTime.startOfDayUtc(day);
    final dayEnd = AppTime.endOfDayUtc(day);
    final query = _database.select(_database.meals)
      ..where(
        (meal) =>
            meal.profileId.equals(profileId) &
            meal.mealType.equals(mealType.storageValue) &
            meal.eatenAt.isBiggerOrEqualValue(dayStart) &
            meal.eatenAt.isSmallerThanValue(dayEnd) &
            meal.deletedAt.isNull(),
      )
      ..limit(1);

    final existing = await query.getSingleOrNull();
    if (existing != null) {
      return existing;
    }

    final meal = Meal(
      id: _uuid.v4(),
      profileId: profileId,
      mealType: mealType.storageValue,
      eatenAt: eatenAt.toUtc(),
      createdAt: now,
      updatedAt: now,
    );
    await _database
        .into(_database.meals)
        .insert(
          MealsCompanion.insert(
            id: meal.id,
            profileId: meal.profileId,
            mealType: meal.mealType,
            eatenAt: meal.eatenAt,
            createdAt: meal.createdAt,
            updatedAt: meal.updatedAt,
          ),
        );
    return meal;
  }

  Future<void> _insertItem({
    required String itemId,
    required Meal meal,
    required String foodName,
    required double grams,
    required Nutrients per100g,
    required DateTime now,
  }) async {
    final totals = NutritionCalculator.scale(per100g: per100g, grams: grams);
    await _database
        .into(_database.mealItems)
        .insert(
          MealItemsCompanion.insert(
            id: itemId,
            mealId: meal.id,
            foodName: foodName,
            grams: grams,
            caloriesPer100g: per100g.calories,
            proteinPer100g: per100g.protein,
            carbsPer100g: per100g.carbs,
            fatPer100g: per100g.fat,
            totalCalories: totals.calories,
            totalProtein: totals.protein,
            totalCarbs: totals.carbs,
            totalFat: totals.fat,
            createdAt: now,
            updatedAt: now,
          ),
        );
    await _writeItemOutbox(
      itemId: itemId,
      meal: meal,
      foodName: foodName,
      grams: grams,
      per100g: per100g,
      totals: totals,
      now: now,
    );
  }

  Future<void> _writeItemOutbox({
    required String itemId,
    required Meal meal,
    required String foodName,
    required double grams,
    required Nutrients per100g,
    required Nutrients totals,
    required DateTime now,
  }) async {
    await _database
        .into(_database.syncOutbox)
        .insert(
          SyncOutboxCompanion.insert(
            id: _uuid.v4(),
            entityType: 'meal_item',
            entityId: itemId,
            operation: 'upsert',
            payloadJson: jsonEncode({
              'id': itemId,
              'meal_id': meal.id,
              'profile_id': meal.profileId,
              'meal_type': meal.mealType,
              'eaten_at': meal.eatenAt.toUtc().toIso8601String(),
              'food_name': foodName,
              'grams': grams,
              'calories_per_100g': per100g.calories,
              'protein_per_100g': per100g.protein,
              'carbs_per_100g': per100g.carbs,
              'fat_per_100g': per100g.fat,
              'total_calories': totals.calories,
              'total_protein': totals.protein,
              'total_carbs': totals.carbs,
              'total_fat': totals.fat,
              'updated_at': now.toUtc().toIso8601String(),
            }),
            createdAt: now,
          ),
        );
  }

  DiaryEntry _toEntry({required Meal meal, required MealItem item}) {
    return DiaryEntry(
      id: item.id,
      mealId: meal.id,
      foodName: item.foodName,
      grams: item.grams,
      mealType: MealType.fromStorage(meal.mealType),
      eatenAt: meal.eatenAt,
      per100g: _per100gOf(item),
      nutrients: Nutrients(
        calories: item.totalCalories,
        protein: item.totalProtein,
        carbs: item.totalCarbs,
        fat: item.totalFat,
      ),
    );
  }

  Nutrients _per100gOf(MealItem item) => Nutrients(
    calories: item.caloriesPer100g,
    protein: item.proteinPer100g,
    carbs: item.carbsPer100g,
    fat: item.fatPer100g,
  );
}
