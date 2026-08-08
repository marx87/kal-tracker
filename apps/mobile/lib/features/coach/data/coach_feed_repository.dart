import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/coach/domain/coach_feed_item.dart';
import 'package:uuid/uuid.dart';

class CoachFeedRepository {
  CoachFeedRepository(this._database, {Uuid? uuid, DateTime Function()? now})
    : _uuid = uuid ?? const Uuid(),
      _now = now ?? AppTime.nowUtc;

  final AppDatabase _database;
  final Uuid _uuid;
  final DateTime Function() _now;

  Stream<List<CoachFeedItem>> watch({
    required String profileId,
    bool includeDismissed = false,
    int limit = 50,
  }) {
    final query = _database.select(_database.coachFeedItems)
      ..where(
        (row) =>
            row.profileId.equals(profileId) &
            row.deletedAt.isNull() &
            (includeDismissed
                ? const Constant(true)
                : row.dismissedAt.isNull()),
      )
      ..orderBy([(row) => OrderingTerm.desc(row.occurredAt)])
      ..limit(limit.clamp(1, 200));
    return query.watch().map(
      (rows) => rows.map(_toDomain).toList(growable: false),
    );
  }

  /// Pubblica o aggiorna la stessa card logica. [externalId] e' obbligatorio:
  /// senza una chiave dell'evento un refresh potrebbe creare infinite copie.
  Future<String> publish({
    required String profileId,
    required String kind,
    required CoachFeedSource source,
    required String externalId,
    required String title,
    required String body,
    required DateTime occurredAt,
    String? actionLabel,
    String? actionPath,
  }) async {
    final cleanKind = _required(kind, 40, 'Tipo');
    final cleanExternalId = _required(externalId, 120, 'Chiave evento');
    final cleanTitle = _required(title, 120, 'Titolo');
    final cleanBody = _required(body, 1200, 'Testo');
    final cleanActionLabel = _optional(actionLabel, 60);
    final cleanActionPath = _optional(actionPath, 200);
    final id = _rowId(
      profileId: profileId,
      source: source,
      externalId: cleanExternalId,
    );
    final now = _now();

    await _database.transaction(() async {
      final existing = await (_database.select(
        _database.coachFeedItems,
      )..where((row) => row.id.equals(id))).getSingleOrNull();
      final createdAt = existing?.createdAt ?? now;
      await _database
          .into(_database.coachFeedItems)
          .insertOnConflictUpdate(
            CoachFeedItemsCompanion(
              id: Value(id),
              profileId: Value(profileId),
              kind: Value(cleanKind),
              source: Value(source.name),
              externalId: Value(cleanExternalId),
              title: Value(cleanTitle),
              body: Value(cleanBody),
              actionLabel: Value(cleanActionLabel),
              actionPath: Value(cleanActionPath),
              occurredAt: Value(occurredAt.toUtc()),
              readAt: Value(existing?.readAt),
              dismissedAt: Value(existing?.dismissedAt),
              createdAt: Value(createdAt),
              updatedAt: Value(now),
              deletedAt: const Value(null),
            ),
          );
      final row = await (_database.select(
        _database.coachFeedItems,
      )..where((item) => item.id.equals(id))).getSingle();
      await _appendOutbox(row, now);
    });
    return id;
  }

  Future<void> markRead(String id) => _updateState(id, read: true);

  Future<void> dismiss(String id) => _updateState(id, dismiss: true);

  Future<void> _updateState(
    String id, {
    bool read = false,
    bool dismiss = false,
  }) async {
    final now = _now();
    await _database.transaction(() async {
      final existing = await (_database.select(
        _database.coachFeedItems,
      )..where((row) => row.id.equals(id))).getSingleOrNull();
      if (existing == null || existing.deletedAt != null) {
        return;
      }
      await (_database.update(
        _database.coachFeedItems,
      )..where((row) => row.id.equals(id))).write(
        CoachFeedItemsCompanion(
          readAt: read ? Value(existing.readAt ?? now) : const Value.absent(),
          dismissedAt: dismiss
              ? Value(existing.dismissedAt ?? now)
              : const Value.absent(),
          updatedAt: Value(now),
        ),
      );
      final row = await (_database.select(
        _database.coachFeedItems,
      )..where((item) => item.id.equals(id))).getSingle();
      await _appendOutbox(row, now);
    });
  }

  Future<void> _appendOutbox(LocalCoachFeedItem row, DateTime now) => _database
      .into(_database.syncOutbox)
      .insert(
        SyncOutboxCompanion.insert(
          id: _uuid.v4(),
          entityType: 'coach_feed_item',
          entityId: row.id,
          operation: 'upsert',
          payloadJson: jsonEncode({
            'id': row.id,
            'profile_id': row.profileId,
            'kind': row.kind,
            'source': row.source,
            'external_id': row.externalId,
            'title': row.title,
            'body': row.body,
            'action_label': row.actionLabel,
            'action_path': row.actionPath,
            'occurred_at': row.occurredAt.toUtc().toIso8601String(),
            'read_at': row.readAt?.toUtc().toIso8601String(),
            'dismissed_at': row.dismissedAt?.toUtc().toIso8601String(),
            'created_at': row.createdAt.toUtc().toIso8601String(),
            'updated_at': row.updatedAt.toUtc().toIso8601String(),
            'deleted_at': row.deletedAt?.toUtc().toIso8601String(),
          }),
          createdAt: now,
        ),
      );

  CoachFeedItem _toDomain(LocalCoachFeedItem row) => CoachFeedItem(
    id: row.id,
    kind: row.kind,
    source: row.source == CoachFeedSource.ai.name
        ? CoachFeedSource.ai
        : CoachFeedSource.deterministic,
    externalId: row.externalId,
    title: row.title,
    body: row.body,
    actionLabel: row.actionLabel,
    actionPath: row.actionPath,
    occurredAt: row.occurredAt.toUtc(),
    readAt: row.readAt?.toUtc(),
    dismissedAt: row.dismissedAt?.toUtc(),
  );

  static String _rowId({
    required String profileId,
    required CoachFeedSource source,
    required String externalId,
  }) => const Uuid().v5(
    Namespace.url.value,
    'https://kal-tracker.local/sync/coach-feed/'
    '$profileId/${source.name}/$externalId',
  );

  static String _required(String value, int max, String label) {
    final clean = value.trim();
    if (clean.isEmpty || clean.length > max) {
      throw FormatException('$label non valido.');
    }
    return clean;
  }

  static String? _optional(String? value, int max) {
    final clean = value?.trim();
    if (clean == null || clean.isEmpty) {
      return null;
    }
    if (clean.length > max) {
      throw const FormatException('Testo troppo lungo.');
    }
    return clean;
  }
}
