import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/wellbeing/data/wellbeing_repository.dart';
import 'package:kal_tracker/features/wellbeing/domain/wellbeing_models.dart';

final wellbeingRepositoryProvider = Provider<WellbeingRepository>(
  (ref) => WellbeingRepository(ref.watch(databaseProvider)),
);

final todayWaterProvider = StreamProvider<DailyWaterIntake>((ref) async* {
  final profile = await ref.watch(marcoProfileProvider.future);
  final day = ref.watch(todayProvider);
  yield* ref
      .watch(wellbeingRepositoryProvider)
      .watchWaterDay(profileId: profile.id, day: day);
});

final recentWeightsProvider = StreamProvider<List<WeightMeasurement>>((
  ref,
) async* {
  final profile = await ref.watch(marcoProfileProvider.future);
  yield* ref.watch(wellbeingRepositoryProvider).watchRecentWeights(profile.id);
});
