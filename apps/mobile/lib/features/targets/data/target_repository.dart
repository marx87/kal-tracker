import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/targets/domain/nutrition_target.dart';
import 'package:uuid/uuid.dart';

class TargetRepository {
  TargetRepository(this._database, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final AppDatabase _database;
  final Uuid _uuid;

  Stream<NutritionTarget?> watchTarget(String profileId) {
    final query = _database.select(
      _database.nutritionTargets,
    )..where((row) => row.profileId.equals(profileId) & row.deletedAt.isNull());
    return query.watchSingleOrNull().map(_toDomain);
  }

  Future<NutritionTarget?> getTarget(String profileId) async {
    final query = _database.select(
      _database.nutritionTargets,
    )..where((row) => row.profileId.equals(profileId) & row.deletedAt.isNull());
    return _toDomain(await query.getSingleOrNull());
  }

  Future<void> upsertTarget({
    required String profileId,
    required NutritionTarget target,
  }) async {
    target.validate();
    final now = AppTime.nowUtc();

    await _database.transaction(() async {
      final existing = await (_database.select(
        _database.nutritionTargets,
      )..where((row) => row.profileId.equals(profileId))).getSingleOrNull();

      await _database
          .into(_database.nutritionTargets)
          .insertOnConflictUpdate(
            NutritionTargetsCompanion.insert(
              profileId: profileId,
              dailyCalories: target.calories,
              dailyProtein: target.protein,
              dailyCarbs: target.carbs,
              dailyFat: target.fat,
              createdAt: existing?.createdAt ?? now,
              updatedAt: now,
              deletedAt: const Value(null),
            ),
          );
      await _appendOutbox(
        entityId: profileId,
        operation: 'upsert',
        payload: {
          'profile_id': profileId,
          'daily_calories': target.calories,
          'daily_protein': target.protein,
          'daily_carbs': target.carbs,
          'daily_fat': target.fat,
          'updated_at': now.toIso8601String(),
        },
        now: now,
      );
    });
  }

  Future<void> deleteTarget(String profileId) async {
    final now = AppTime.nowUtc();
    await _database.transaction(() async {
      final changed =
          await (_database.update(_database.nutritionTargets)..where(
                (row) =>
                    row.profileId.equals(profileId) & row.deletedAt.isNull(),
              ))
              .write(
                NutritionTargetsCompanion(
                  updatedAt: Value(now),
                  deletedAt: Value(now),
                ),
              );
      if (changed == 0) {
        return;
      }
      await _appendOutbox(
        entityId: profileId,
        operation: 'delete',
        payload: {'profile_id': profileId, 'deleted_at': now.toIso8601String()},
        now: now,
      );
    });
  }

  NutritionTarget? _toDomain(LocalNutritionTarget? row) => row == null
      ? null
      : NutritionTarget(
          calories: row.dailyCalories,
          protein: row.dailyProtein,
          carbs: row.dailyCarbs,
          fat: row.dailyFat,
        );

  Future<void> _appendOutbox({
    required String entityId,
    required String operation,
    required Map<String, Object?> payload,
    required DateTime now,
  }) => _database
      .into(_database.syncOutbox)
      .insert(
        SyncOutboxCompanion.insert(
          id: _uuid.v4(),
          entityType: 'nutrition_target',
          entityId: entityId,
          operation: operation,
          payloadJson: jsonEncode(payload),
          createdAt: now,
        ),
      );
}
