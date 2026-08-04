import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';
import 'package:kal_tracker/features/recipes/presentation/recipe_providers.dart';
import 'package:kal_tracker/features/weekly_plan/domain/shopping_checks.dart';
import 'package:kal_tracker/features/weekly_plan/domain/shopping_list_builder.dart';
import 'package:kal_tracker/features/weekly_plan/domain/weekly_plan_models.dart';
import 'package:kal_tracker/features/weekly_plan/presentation/shopping_checks_store.dart';
import 'package:kal_tracker/features/weekly_plan/presentation/weekly_plan_providers.dart';

/// Il piano su cui si fa la spesa.
///
/// La sorgente è UNA SOLA: [activeWeeklyPlanProvider], cioè il piano pronto
/// più recente letto dal repository del piano. Qui si aspetta la prima
/// lettura del database prima di rispondere, altrimenti la schermata
/// lampeggerebbe «niente da comprare» mentre la query è ancora in corso.
///
/// La spesa è in sola lettura: non genera, non modifica e non cancella nulla.
final shoppingPlanProvider = FutureProvider<WeeklyPlan?>((ref) async {
  await ref.watch(weeklyPlansProvider.future);
  return ref.read(activeWeeklyPlanProvider);
});

/// La lista della spesa vera e propria.
///
/// Gli ingredienti si leggono UNO A UNO dalle ricette reali: quello che non
/// c'è più non viene inventato, finisce fra le ricette non disponibili.
final shoppingListProvider = FutureProvider<ShoppingList?>((ref) async {
  final recipes = ref.watch(recipeRepositoryProvider);
  final plan = await ref.watch(shoppingPlanProvider.future);
  if (plan == null) {
    return null;
  }
  final details = <String, FitRecipeDetails>{};
  final wanted = <String>{
    for (final slot in plan.slots)
      if (slot.recipeId case final String recipeId) recipeId,
  };
  for (final recipeId in wanted) {
    final recipe = await recipes.getRecipe(recipeId);
    if (recipe != null) {
      details[recipeId] = recipe;
    }
  }
  return ShoppingListBuilder.build(plan: plan, recipes: details);
});

/// Store su file delle spunte: nei test si overrida con un fake in memoria.
final shoppingChecksStoreProvider = Provider<ShoppingChecksStore>(
  (ref) => FileShoppingChecksStore(),
);

final shoppingChecksProvider =
    AsyncNotifierProvider<ShoppingChecksController, ShoppingChecks>(
      ShoppingChecksController.new,
    );

/// Le spunte: stato in memoria subito, file JSON un attimo dopo.
class ShoppingChecksController extends AsyncNotifier<ShoppingChecks> {
  @override
  Future<ShoppingChecks> build() =>
      ref.watch(shoppingChecksStoreProvider).read();

  ShoppingChecks get _current =>
      state.valueOrNull ?? const ShoppingChecks.empty();

  Future<void> toggle({required String planId, required String key}) =>
      _save(_current.toggled(planId: planId, key: key));

  Future<void> reset(String planId) => _save(_current.clearedFor(planId));

  Future<void> _save(ShoppingChecks updated) async {
    state = AsyncData(updated);
    await ref.read(shoppingChecksStoreProvider).write(updated);
  }
}
