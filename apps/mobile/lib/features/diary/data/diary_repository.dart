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
          .map((row) {
            final meal = row.readTable(_database.meals);
            final item = row.readTable(_database.mealItems);
            return DiaryEntry(
              id: item.id,
              mealId: meal.id,
              foodName: item.foodName,
              grams: item.grams,
              mealType: MealType.fromStorage(meal.mealType),
              eatenAt: meal.eatenAt,
              nutrients: Nutrients(
                calories: item.totalCalories,
                protein: item.totalProtein,
                carbs: item.totalCarbs,
                fat: item.totalFat,
              ),
            );
          })
          .toList(growable: false);
      return DailyDiary.fromEntries(entries);
    });
  }

  Future<String> addManualFood({
    required String profileId,
    required ManualFoodInput input,
  }) async {
    input.validate();
    final now = AppTime.nowUtc();
    final dayStart = AppTime.startOfDayUtc(input.eatenAt);
    final dayEnd = AppTime.endOfDayUtc(input.eatenAt);
    final totals = NutritionCalculator.scale(
      per100g: input.per100g,
      grams: input.grams,
    );

    return _database.transaction(() async {
      final mealQuery = _database.select(_database.meals)
        ..where(
          (meal) =>
              meal.profileId.equals(profileId) &
              meal.mealType.equals(input.mealType.storageValue) &
              meal.eatenAt.isBiggerOrEqualValue(dayStart) &
              meal.eatenAt.isSmallerThanValue(dayEnd) &
              meal.deletedAt.isNull(),
        )
        ..limit(1);

      final existingMeal = await mealQuery.getSingleOrNull();
      final mealId = existingMeal?.id ?? _uuid.v4();
      if (existingMeal == null) {
        await _database
            .into(_database.meals)
            .insert(
              MealsCompanion.insert(
                id: mealId,
                profileId: profileId,
                mealType: input.mealType.storageValue,
                eatenAt: input.eatenAt.toUtc(),
                createdAt: now,
                updatedAt: now,
              ),
            );
      }

      final itemId = _uuid.v4();
      await _database
          .into(_database.mealItems)
          .insert(
            MealItemsCompanion.insert(
              id: itemId,
              mealId: mealId,
              foodName: input.foodName.trim(),
              grams: input.grams,
              caloriesPer100g: input.per100g.calories,
              proteinPer100g: input.per100g.protein,
              carbsPer100g: input.per100g.carbs,
              fatPer100g: input.per100g.fat,
              totalCalories: totals.calories,
              totalProtein: totals.protein,
              totalCarbs: totals.carbs,
              totalFat: totals.fat,
              createdAt: now,
              updatedAt: now,
            ),
          );

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
                'meal_id': mealId,
                'profile_id': profileId,
                'meal_type': input.mealType.storageValue,
                'eaten_at': input.eatenAt.toUtc().toIso8601String(),
                'food_name': input.foodName.trim(),
                'grams': input.grams,
                'calories_per_100g': input.per100g.calories,
                'protein_per_100g': input.per100g.protein,
                'carbs_per_100g': input.per100g.carbs,
                'fat_per_100g': input.per100g.fat,
                'total_calories': totals.calories,
                'total_protein': totals.protein,
                'total_carbs': totals.carbs,
                'total_fat': totals.fat,
                'updated_at': now.toUtc().toIso8601String(),
              }),
              createdAt: now,
            ),
          );

      return itemId;
    });
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
}
