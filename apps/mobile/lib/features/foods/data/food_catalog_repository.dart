import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/foods/domain/food_models.dart';
import 'package:uuid/uuid.dart';

class FoodCatalogRepository {
  FoodCatalogRepository(this._database, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final AppDatabase _database;
  final Uuid _uuid;

  Stream<List<FoodCatalogItem>> watchCatalog({
    required String profileId,
    String query = '',
    int limit = 50,
  }) => _watch(profileId: profileId, query: query, limit: limit);

  Stream<List<FoodCatalogItem>> watchFavorites({
    required String profileId,
    int limit = 50,
  }) => _watch(profileId: profileId, onlyFavorites: true, limit: limit);

  Stream<List<FoodCatalogItem>> watchRecent({
    required String profileId,
    int limit = 20,
  }) => _watch(profileId: profileId, onlyRecent: true, limit: limit);

  Future<FoodCatalogItem?> getFood({
    required String profileId,
    required String foodId,
  }) async {
    final rows = _baseQuery(profileId)
      ..where(_database.foods.id.equals(foodId));
    final result = await rows.getSingleOrNull();
    return result == null ? null : _mapRow(result);
  }

  Future<String> createCustomFood({
    required String profileId,
    required FoodDraft draft,
  }) async {
    draft.validate();
    final id = _uuid.v4();
    final now = AppTime.nowUtc();
    final cleanBrand = _cleanOptional(draft.brand);
    final cleanBarcode = _cleanOptional(draft.barcode);

    await _database.transaction(() async {
      await _database
          .into(_database.foods)
          .insert(
            FoodsCompanion.insert(
              id: id,
              ownerProfileId: Value(profileId),
              name: draft.name.trim(),
              brand: Value(cleanBrand),
              barcode: Value(cleanBarcode),
              caloriesPer100g: draft.per100g.calories,
              proteinPer100g: draft.per100g.protein,
              carbsPer100g: draft.per100g.carbs,
              fatPer100g: draft.per100g.fat,
              defaultServingGrams: Value(draft.defaultServingGrams),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await _appendOutbox(
        entityType: 'food',
        entityId: id,
        operation: 'upsert',
        payload: {
          'id': id,
          'owner_profile_id': profileId,
          'name': draft.name.trim(),
          'brand': cleanBrand,
          'barcode': cleanBarcode,
          'calories_per_100g': draft.per100g.calories,
          'protein_per_100g': draft.per100g.protein,
          'carbs_per_100g': draft.per100g.carbs,
          'fat_per_100g': draft.per100g.fat,
          'default_serving_grams': draft.defaultServingGrams,
          'updated_at': now.toIso8601String(),
        },
        now: now,
      );
    });
    return id;
  }

  Future<void> setFavorite({
    required String profileId,
    required String foodId,
    required bool isFavorite,
  }) async {
    await _requireAccessibleFood(profileId: profileId, foodId: foodId);
    final now = AppTime.nowUtc();
    await _database.transaction(() async {
      final existing =
          await (_database.select(_database.foodPreferences)..where(
                (row) =>
                    row.profileId.equals(profileId) & row.foodId.equals(foodId),
              ))
              .getSingleOrNull();
      await _database
          .into(_database.foodPreferences)
          .insertOnConflictUpdate(
            FoodPreferencesCompanion.insert(
              profileId: profileId,
              foodId: foodId,
              isFavorite: Value(isFavorite),
              useCount: Value(existing?.useCount ?? 0),
              lastUsedAt: Value(existing?.lastUsedAt),
              updatedAt: now,
            ),
          );
      await _appendOutbox(
        entityType: 'food_preference',
        entityId: '$profileId:$foodId',
        operation: 'upsert',
        payload: {
          'profile_id': profileId,
          'food_id': foodId,
          'is_favorite': isFavorite,
          'updated_at': now.toIso8601String(),
        },
        now: now,
      );
    });
  }

  Future<void> markUsed({
    required String profileId,
    required String foodId,
    DateTime? usedAt,
  }) async {
    await _requireAccessibleFood(profileId: profileId, foodId: foodId);
    final now = (usedAt ?? AppTime.nowUtc()).toUtc();
    await _database.transaction(() async {
      final existing =
          await (_database.select(_database.foodPreferences)..where(
                (row) =>
                    row.profileId.equals(profileId) & row.foodId.equals(foodId),
              ))
              .getSingleOrNull();
      await _database
          .into(_database.foodPreferences)
          .insertOnConflictUpdate(
            FoodPreferencesCompanion.insert(
              profileId: profileId,
              foodId: foodId,
              isFavorite: Value(existing?.isFavorite ?? false),
              useCount: Value((existing?.useCount ?? 0) + 1),
              lastUsedAt: Value(now),
              updatedAt: now,
            ),
          );
    });
  }

  Future<void> deleteCustomFood({
    required String profileId,
    required String foodId,
  }) async {
    final now = AppTime.nowUtc();
    await _database.transaction(() async {
      final changed =
          await (_database.update(_database.foods)..where(
                (row) =>
                    row.id.equals(foodId) &
                    row.ownerProfileId.equals(profileId) &
                    row.deletedAt.isNull(),
              ))
              .write(
                FoodsCompanion(updatedAt: Value(now), deletedAt: Value(now)),
              );
      if (changed == 0) {
        return;
      }
      await _appendOutbox(
        entityType: 'food',
        entityId: foodId,
        operation: 'delete',
        payload: {'id': foodId, 'deleted_at': now.toIso8601String()},
        now: now,
      );
    });
  }

  Stream<List<FoodCatalogItem>> _watch({
    required String profileId,
    String query = '',
    bool onlyFavorites = false,
    bool onlyRecent = false,
    required int limit,
  }) {
    if (limit <= 0 || limit > 200) {
      throw const FormatException('Il limite del catalogo non è valido.');
    }
    final statement = _baseQuery(profileId);
    final cleanQuery = query.trim().toLowerCase();
    if (cleanQuery.isNotEmpty) {
      statement.where(
        _database.foods.name.lower().contains(cleanQuery) |
            _database.foods.brand.lower().contains(cleanQuery),
      );
    }
    if (onlyFavorites) {
      statement.where(_database.foodPreferences.isFavorite.equals(true));
    }
    if (onlyRecent) {
      statement.where(_database.foodPreferences.lastUsedAt.isNotNull());
    }
    statement
      ..orderBy(
        onlyRecent
            ? [
                OrderingTerm.desc(_database.foodPreferences.lastUsedAt),
                OrderingTerm.asc(_database.foods.name),
              ]
            : [
                OrderingTerm.desc(_database.foodPreferences.isFavorite),
                OrderingTerm.desc(_database.foodPreferences.lastUsedAt),
                OrderingTerm.asc(_database.foods.name),
              ],
      )
      ..limit(limit);
    return statement.watch().map(
      (rows) => rows.map(_mapRow).toList(growable: false),
    );
  }

  JoinedSelectStatement<HasResultSet, dynamic> _baseQuery(String profileId) {
    final statement = _database.select(_database.foods).join([
      leftOuterJoin(
        _database.foodPreferences,
        _database.foodPreferences.foodId.equalsExp(_database.foods.id) &
            _database.foodPreferences.profileId.equals(profileId),
      ),
    ]);
    statement.where(
      _database.foods.deletedAt.isNull() &
          (_database.foods.ownerProfileId.isNull() |
              _database.foods.ownerProfileId.equals(profileId)),
    );
    return statement;
  }

  FoodCatalogItem _mapRow(TypedResult row) {
    final food = row.readTable(_database.foods);
    final preference = row.readTableOrNull(_database.foodPreferences);
    return FoodCatalogItem(
      id: food.id,
      name: food.name,
      brand: food.brand,
      barcode: food.barcode,
      per100g: Nutrients(
        calories: food.caloriesPer100g,
        protein: food.proteinPer100g,
        carbs: food.carbsPer100g,
        fat: food.fatPer100g,
      ),
      defaultServingGrams: food.defaultServingGrams,
      source: food.source,
      isFavorite: preference?.isFavorite ?? false,
      useCount: preference?.useCount ?? 0,
      lastUsedAt: preference?.lastUsedAt,
    );
  }

  Future<void> _requireAccessibleFood({
    required String profileId,
    required String foodId,
  }) async {
    final query = _database.select(_database.foods)
      ..where(
        (row) =>
            row.id.equals(foodId) &
            row.deletedAt.isNull() &
            (row.ownerProfileId.isNull() |
                row.ownerProfileId.equals(profileId)),
      );
    if (await query.getSingleOrNull() == null) {
      throw StateError('Alimento non trovato.');
    }
  }

  String? _cleanOptional(String? value) {
    final clean = value?.trim();
    return clean == null || clean.isEmpty ? null : clean;
  }

  Future<void> _appendOutbox({
    required String entityType,
    required String entityId,
    required String operation,
    required Map<String, Object?> payload,
    required DateTime now,
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
