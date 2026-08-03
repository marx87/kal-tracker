import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/data/diary_repository.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase.defaults();
  ref.onDispose(database.close);
  return database;
});

final localProfileRepositoryProvider = Provider<LocalProfileRepository>(
  (ref) => LocalProfileRepository(ref.watch(databaseProvider)),
);

final diaryRepositoryProvider = Provider<DiaryRepository>(
  (ref) => DiaryRepository(ref.watch(databaseProvider)),
);

final marcoProfileProvider = FutureProvider<LocalProfile>(
  (ref) => ref.watch(localProfileRepositoryProvider).getOrCreateMarco(),
);

final todayProvider = Provider<DateTime>((ref) {
  final today = AppTime.nowInRome();
  final untilTomorrow = AppTime.endOfDayUtc(
    today,
  ).difference(DateTime.now().toUtc());
  final timer = Timer(
    untilTomorrow.isNegative ? Duration.zero : untilTomorrow,
    ref.invalidateSelf,
  );
  ref.onDispose(timer.cancel);
  return today;
});

final todayDiaryProvider = StreamProvider<DailyDiary>((ref) async* {
  final profile = await ref.watch(marcoProfileProvider.future);
  final day = ref.watch(todayProvider);
  yield* ref
      .watch(diaryRepositoryProvider)
      .watchDay(profileId: profile.id, day: day);
});
