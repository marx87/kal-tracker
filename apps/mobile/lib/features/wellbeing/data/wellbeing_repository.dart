import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/wellbeing/domain/wellbeing_models.dart';
import 'package:uuid/uuid.dart';

class WellbeingRepository {
  WellbeingRepository(this._database, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final AppDatabase _database;
  final Uuid _uuid;

  Stream<DailyWaterIntake> watchWaterDay({
    required String profileId,
    required DateTime day,
  }) {
    final start = AppTime.startOfDayUtc(day);
    final end = AppTime.endOfDayUtc(day);
    final query = _database.select(_database.waterLogs)
      ..where(
        (row) =>
            row.profileId.equals(profileId) &
            row.loggedAt.isBiggerOrEqualValue(start) &
            row.loggedAt.isSmallerThanValue(end) &
            row.deletedAt.isNull(),
      )
      ..orderBy([(row) => OrderingTerm.asc(row.loggedAt)]);

    return query.watch().map(
      (rows) => DailyWaterIntake.fromEntries(
        rows
            .map(
              (row) => WaterIntakeEntry(
                id: row.id,
                milliliters: row.milliliters,
                loggedAt: row.loggedAt,
              ),
            )
            .toList(growable: false),
      ),
    );
  }

  Future<String> addWater({
    required String profileId,
    required int milliliters,
    required DateTime loggedAt,
  }) async {
    if (milliliters <= 0 || milliliters > 10000) {
      throw const FormatException('La quantità d’acqua non è valida.');
    }
    final id = _uuid.v4();
    final now = AppTime.nowUtc();
    final instant = loggedAt.toUtc();
    await _database.transaction(() async {
      await _database
          .into(_database.waterLogs)
          .insert(
            WaterLogsCompanion.insert(
              id: id,
              profileId: profileId,
              milliliters: milliliters,
              loggedAt: instant,
              createdAt: now,
              updatedAt: now,
            ),
          );
      await _appendOutbox(
        entityType: 'water_log',
        entityId: id,
        operation: 'upsert',
        payload: {
          'id': id,
          'profile_id': profileId,
          'milliliters': milliliters,
          'logged_at': instant.toIso8601String(),
          'updated_at': now.toIso8601String(),
        },
        now: now,
      );
    });
    return id;
  }

  Future<void> deleteWater(String id) => _softDeleteWater(id);

  Stream<List<WeightMeasurement>> watchRecentWeights(
    String profileId, {
    int limit = 30,
  }) {
    if (limit <= 0 || limit > 3650) {
      throw const FormatException('Il numero di misurazioni non è valido.');
    }
    final query = _database.select(_database.bodyMeasurements)
      ..where((row) => row.profileId.equals(profileId) & row.deletedAt.isNull())
      ..orderBy([(row) => OrderingTerm.desc(row.measuredAt)])
      ..limit(limit);
    return query.watch().map(
      (rows) => rows
          .map(
            (row) => WeightMeasurement(
              id: row.id,
              weightKg: row.weightKg,
              measuredAt: row.measuredAt,
              note: row.note,
            ),
          )
          .toList(growable: false),
    );
  }

  Future<String> addWeight({
    required String profileId,
    required double weightKg,
    required DateTime measuredAt,
    String? note,
  }) async {
    if (!weightKg.isFinite || weightKg < 20 || weightKg > 500) {
      throw const FormatException(
        'Il peso deve essere compreso tra 20 e 500 kg.',
      );
    }
    final cleanNote = note?.trim();
    if (cleanNote != null && cleanNote.length > 240) {
      throw const FormatException('La nota è troppo lunga.');
    }
    final id = _uuid.v4();
    final now = AppTime.nowUtc();
    final instant = measuredAt.toUtc();
    await _database.transaction(() async {
      await _database
          .into(_database.bodyMeasurements)
          .insert(
            BodyMeasurementsCompanion.insert(
              id: id,
              profileId: profileId,
              weightKg: weightKg,
              measuredAt: instant,
              note: Value(
                cleanNote == null || cleanNote.isEmpty ? null : cleanNote,
              ),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await _appendOutbox(
        entityType: 'body_measurement',
        entityId: id,
        operation: 'upsert',
        payload: {
          'id': id,
          'profile_id': profileId,
          'weight_kg': weightKg,
          'measured_at': instant.toIso8601String(),
          'note': cleanNote,
          'updated_at': now.toIso8601String(),
        },
        now: now,
      );
    });
    return id;
  }

  Future<void> deleteWeight(String id) => _softDeleteWeight(id);

  Future<void> _softDeleteWater(String id) async {
    final now = AppTime.nowUtc();
    await _database.transaction(() async {
      final changed =
          await (_database.update(
            _database.waterLogs,
          )..where((row) => row.id.equals(id) & row.deletedAt.isNull())).write(
            WaterLogsCompanion(updatedAt: Value(now), deletedAt: Value(now)),
          );
      if (changed == 0) {
        return;
      }
      await _appendOutbox(
        entityType: 'water_log',
        entityId: id,
        operation: 'delete',
        payload: {'id': id, 'deleted_at': now.toIso8601String()},
        now: now,
      );
    });
  }

  Future<void> _softDeleteWeight(String id) async {
    final now = AppTime.nowUtc();
    await _database.transaction(() async {
      final changed =
          await (_database.update(
            _database.bodyMeasurements,
          )..where((row) => row.id.equals(id) & row.deletedAt.isNull())).write(
            BodyMeasurementsCompanion(
              updatedAt: Value(now),
              deletedAt: Value(now),
            ),
          );
      if (changed == 0) {
        return;
      }
      await _appendOutbox(
        entityType: 'body_measurement',
        entityId: id,
        operation: 'delete',
        payload: {'id': id, 'deleted_at': now.toIso8601String()},
        now: now,
      );
    });
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
