import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/targets/data/target_repository.dart';
import 'package:kal_tracker/features/targets/domain/nutrition_target.dart';

final targetRepositoryProvider = Provider<TargetRepository>(
  (ref) => TargetRepository(ref.watch(databaseProvider)),
);

final nutritionTargetProvider = StreamProvider<NutritionTarget>((ref) async* {
  final profile = await ref.watch(marcoProfileProvider.future);
  yield* ref
      .watch(targetRepositoryProvider)
      .watchTarget(profile.id)
      .map((target) => target ?? const NutritionTarget.standard());
});
