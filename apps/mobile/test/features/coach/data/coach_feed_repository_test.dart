import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/coach/data/coach_feed_repository.dart';
import 'package:kal_tracker/features/coach/domain/coach_feed_item.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

void main() {
  late AppDatabase database;
  late String profileId;
  var tick = 0;

  setUp(() async {
    AppTime.initialize();
    tick = 0;
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
  });

  tearDown(() => database.close());

  test(
    'pubblicazione idempotente, lettura e dismiss restano sincronizzabili',
    () async {
      final repository = CoachFeedRepository(
        database,
        now: () => DateTime.utc(2026, 8, 8, 10, tick++),
      );

      final first = await repository.publish(
        profileId: profileId,
        kind: 'weekly_review',
        source: CoachFeedSource.deterministic,
        externalId: 'week-2026-32',
        title: 'Prima versione',
        body: 'Tre allenamenti completati.',
        occurredAt: DateTime.utc(2026, 8, 8, 9),
      );
      final second = await repository.publish(
        profileId: profileId,
        kind: 'weekly_review',
        source: CoachFeedSource.deterministic,
        externalId: 'week-2026-32',
        title: 'Rapporto aggiornato',
        body: 'Quattro allenamenti completati.',
        occurredAt: DateTime.utc(2026, 8, 8, 9),
      );
      await repository.markRead(first);
      await repository.dismiss(first);

      expect(second, first);
      final row = await database.select(database.coachFeedItems).getSingle();
      expect(row.title, 'Rapporto aggiornato');
      expect(row.readAt, isNotNull);
      expect(row.dismissedAt, isNotNull);
      final outbox = await database.select(database.syncOutbox).get();
      expect(outbox, hasLength(4));
      expect(
        outbox.every((row) => row.entityType == 'coach_feed_item'),
        isTrue,
      );
      final last = jsonDecode(outbox.last.payloadJson) as Map<String, Object?>;
      expect(last['read_at'], isNotNull);
      expect(last['dismissed_at'], isNotNull);
    },
  );
}
