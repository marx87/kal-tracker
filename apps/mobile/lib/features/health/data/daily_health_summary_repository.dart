import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/health/domain/health_data_gateway.dart';
import 'package:uuid/uuid.dart';

class DailyHealthSummaryRepository {
  DailyHealthSummaryRepository(this._database, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final AppDatabase _database;
  final Uuid _uuid;

  Stream<List<HealthDailySummary>> watch({
    required String profileId,
    required DateTime fromDay,
    required DateTime throughDay,
  }) {
    final from = _day(fromDay);
    final throughExclusive = _day(throughDay).add(const Duration(days: 1));
    final query = _database.select(_database.dailyHealthSummaries)
      ..where(
        (row) =>
            row.profileId.equals(profileId) &
            row.deletedAt.isNull() &
            row.day.isBiggerOrEqualValue(from) &
            row.day.isSmallerThanValue(throughExclusive),
      )
      ..orderBy([(row) => OrderingTerm.asc(row.day)]);
    return query.watch().map(
      (rows) => rows.map(_toDomain).toList(growable: false),
    );
  }

  Future<int> saveAll({
    required String profileId,
    required Iterable<HealthDailySummary> summaries,
  }) async {
    final accepted = summaries.where((summary) => !summary.isEmpty).toList();
    if (accepted.isEmpty) {
      return 0;
    }
    final now = AppTime.nowUtc();
    await _database.transaction(() async {
      for (final summary in accepted) {
        await _save(profileId: profileId, summary: summary, now: now);
      }
    });
    return accepted.length;
  }

  Future<void> _save({
    required String profileId,
    required HealthDailySummary summary,
    required DateTime now,
  }) async {
    final day = _day(summary.day);
    final source = summary.source.trim();
    if (source.isEmpty || source.length > 40) {
      throw const FormatException('Sorgente salute non valida.');
    }
    _range(summary.steps, 0, 200000, 'passi');
    _range(summary.sleepMinutes, 0, 1440, 'minuti di sonno');
    _range(summary.restingHeartRate, 20, 250, 'frequenza a riposo');
    final id = _rowId(profileId: profileId, source: source, day: day);
    final existing =
        await (_database.select(_database.dailyHealthSummaries)..where(
              (row) =>
                  row.profileId.equals(profileId) &
                  row.day.equals(day) &
                  row.source.equals(source),
            ))
            .getSingleOrNull();
    final rowId = existing?.id ?? id;
    final createdAt = existing?.createdAt ?? now;

    await _database
        .into(_database.dailyHealthSummaries)
        .insert(
          DailyHealthSummariesCompanion.insert(
            id: rowId,
            profileId: profileId,
            day: day,
            source: source,
            externalId: Value(_text(summary.externalId, 120)),
            steps: Value(summary.steps),
            sleepMinutes: Value(summary.sleepMinutes),
            restingHeartRate: Value(summary.restingHeartRate),
            createdAt: createdAt,
            updatedAt: now,
          ),
          onConflict: DoUpdate(
            (_) => DailyHealthSummariesCompanion(
              externalId: Value(_text(summary.externalId, 120)),
              steps: Value(summary.steps),
              sleepMinutes: Value(summary.sleepMinutes),
              restingHeartRate: Value(summary.restingHeartRate),
              updatedAt: Value(now),
              deletedAt: const Value(null),
            ),
            target: [
              _database.dailyHealthSummaries.profileId,
              _database.dailyHealthSummaries.day,
              _database.dailyHealthSummaries.source,
            ],
          ),
        );
    await _database
        .into(_database.syncOutbox)
        .insert(
          SyncOutboxCompanion.insert(
            id: _uuid.v4(),
            entityType: 'daily_health_summary',
            entityId: rowId,
            operation: 'upsert',
            payloadJson: jsonEncode({
              'id': rowId,
              'profile_id': profileId,
              'day': _dayText(day),
              'source': source,
              'external_id': _text(summary.externalId, 120),
              'steps': summary.steps,
              'sleep_minutes': summary.sleepMinutes,
              'resting_heart_rate': summary.restingHeartRate,
              'created_at': createdAt.toUtc().toIso8601String(),
              'updated_at': now.toIso8601String(),
              'deleted_at': null,
            }),
            createdAt: now,
          ),
        );
  }

  HealthDailySummary _toDomain(LocalDailyHealthSummary row) =>
      HealthDailySummary(
        day: _day(row.day),
        source: row.source,
        externalId: row.externalId,
        steps: row.steps,
        sleepMinutes: row.sleepMinutes,
        restingHeartRate: row.restingHeartRate,
      );

  static DateTime _day(DateTime value) {
    final utc = value.toUtc();
    return DateTime.utc(utc.year, utc.month, utc.day);
  }

  static String _dayText(DateTime day) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${day.year}-${two(day.month)}-${two(day.day)}';
  }

  static String _rowId({
    required String profileId,
    required String source,
    required DateTime day,
  }) => const Uuid().v5(
    Namespace.url.value,
    'https://kal-tracker.local/sync/daily-health/'
    '$profileId/$source/${_dayText(day)}',
  );

  static String? _text(String? value, int max) {
    final clean = value?.trim();
    if (clean == null || clean.isEmpty) {
      return null;
    }
    return clean.length <= max ? clean : clean.substring(0, max);
  }

  static void _range(int? value, int minimum, int maximum, String label) {
    if (value != null && (value < minimum || value > maximum)) {
      throw FormatException('$label fuori intervallo.');
    }
  }
}
