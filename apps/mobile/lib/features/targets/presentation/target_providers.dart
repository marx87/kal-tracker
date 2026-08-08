import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/targets/data/target_repository.dart';
import 'package:kal_tracker/features/targets/domain/nutrition_target.dart';
import 'package:kal_tracker/features/goal/presentation/goal_providers.dart';

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

/// Il solo target operativo dell'app.
///
/// Quando l'Obiettivo puo' calcolare un piano adattivo, quei numeri governano
/// diario, ricette, piano e coach. In assenza di dati sufficienti resta il
/// target manuale, che continua quindi a essere un fallback modificabile e non
/// una seconda verita' concorrente.
final effectiveNutritionTargetProvider = FutureProvider<NutritionTarget>((
  ref,
) async {
  final goalPlan = ref.watch(goalPlanProvider).valueOrNull;
  if (goalPlan != null) {
    final targets = goalPlan.targets;
    return NutritionTarget(
      calories: targets.calories,
      protein: targets.protein,
      carbs: targets.carbs,
      fat: targets.fat,
    );
  }
  return ref.watch(nutritionTargetProvider.future);
});
