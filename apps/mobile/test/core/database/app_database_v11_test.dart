import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

void main() {
  setUpAll(AppTime.initialize);

  test(
    'la v11 aggiunge riepiloghi salute e feed senza perdere il profilo',
    () async {
      final directory = await Directory.systemTemp.createTemp('kal-db-v11');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/kal.sqlite');

      final current = AppDatabase(NativeDatabase(file));
      final profile = await LocalProfileRepository(current).getOrCreateMarco();
      await current.close();

      final migrated = AppDatabase(
        NativeDatabase(
          file,
          setup: (raw) {
            raw
              ..execute('DROP TABLE coach_feed_items')
              ..execute('DROP TABLE daily_health_summaries')
              ..execute('PRAGMA user_version = 10');
          },
        ),
      );
      addTearDown(migrated.close);

      expect(
        (await migrated.select(migrated.appProfiles).getSingle()).id,
        profile.id,
      );
      expect(
        await migrated.select(migrated.dailyHealthSummaries).get(),
        isEmpty,
      );
      expect(await migrated.select(migrated.coachFeedItems).get(), isEmpty);

      final now = DateTime.utc(2026, 8, 8, 8);
      await migrated
          .into(migrated.dailyHealthSummaries)
          .insert(
            DailyHealthSummariesCompanion.insert(
              id: 'health-1',
              profileId: profile.id,
              day: DateTime.utc(2026, 8, 8),
              source: 'health_connect',
              steps: const Value(8421),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await migrated
          .into(migrated.coachFeedItems)
          .insert(
            CoachFeedItemsCompanion.insert(
              id: 'feed-1',
              profileId: profile.id,
              kind: 'weekly_review',
              source: 'deterministic',
              title: 'Settimana completata',
              body: 'Hai rispettato il piano.',
              occurredAt: now,
              createdAt: now,
              updatedAt: now,
            ),
          );

      expect(
        (await migrated.select(migrated.dailyHealthSummaries).getSingle())
            .steps,
        8421,
      );
      expect(
        (await migrated.select(migrated.coachFeedItems).getSingle()).title,
        'Settimana completata',
      );
    },
  );
}
