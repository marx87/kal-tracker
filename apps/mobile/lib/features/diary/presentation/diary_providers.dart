import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/data/diary_repository.dart';
import 'package:kal_tracker/features/diary/data/meal_template_repository.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/domain/meal_template.dart';
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

final mealTemplateRepositoryProvider = Provider<MealTemplateRepository>(
  (ref) => MealTemplateRepository(
    ref.watch(databaseProvider),
    diaryRepository: ref.watch(diaryRepositoryProvider),
  ),
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

/// Il giorno scelto si legge una volta sola: con `watch` la mezzanotte
/// riporterebbe l’utente a oggi mentre sta ancora scrivendo su un altro giorno.
final selectedDayProvider = StateProvider<DateTime>(
  (ref) => ref.read(todayProvider),
);

final todayDiaryProvider = StreamProvider<DailyDiary>((ref) async* {
  final profile = await ref.watch(marcoProfileProvider.future);
  final day = ref.watch(todayProvider);
  yield* ref
      .watch(diaryRepositoryProvider)
      .watchDay(profileId: profile.id, day: day);
});

final selectedDiaryProvider = StreamProvider<DailyDiary>((ref) async* {
  final profile = await ref.watch(marcoProfileProvider.future);
  final day = ref.watch(selectedDayProvider);
  yield* ref
      .watch(diaryRepositoryProvider)
      .watchDay(profileId: profile.id, day: day);
});

final mealTemplatesProvider = StreamProvider<List<MealTemplate>>((ref) async* {
  final profile = await ref.watch(marcoProfileProvider.future);
  yield* ref.watch(mealTemplateRepositoryProvider).watchTemplates(profile.id);
});
