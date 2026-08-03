import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/recipes/data/recipe_repository.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_suggestions.dart';
import 'package:kal_tracker/features/targets/domain/nutrition_target.dart';
import 'package:kal_tracker/features/targets/presentation/target_providers.dart';

final recipeRepositoryProvider = Provider<RecipeRepository>(
  (ref) => RecipeRepository(ref.watch(databaseProvider)),
);

final starterRecipesProvider = FutureProvider<void>((ref) async {
  final profile = await ref.watch(marcoProfileProvider.future);
  await ref.watch(recipeRepositoryProvider).ensureStarterRecipes(profile.id);
});

final recipesProvider = StreamProvider<List<FitRecipeSummary>>((ref) async* {
  await ref.watch(starterRecipesProvider.future);
  final profile = await ref.watch(marcoProfileProvider.future);
  yield* ref.watch(recipeRepositoryProvider).watchRecipes(profile.id);
});

final recipeDetailsProvider = FutureProvider.family<FitRecipeDetails?, String>((
  ref,
  recipeId,
) async {
  await ref.watch(starterRecipesProvider.future);
  return ref.watch(recipeRepositoryProvider).getRecipe(recipeId);
});

final recipeSearchQueryProvider = StateProvider.autoDispose<String>(
  (ref) => '',
);

final recipeTagFilterProvider = StateProvider.autoDispose<String?>(
  (ref) => null,
);

final recipeOnlyFavoritesProvider = StateProvider.autoDispose<bool>(
  (ref) => false,
);

final visibleRecipesProvider =
    StreamProvider.autoDispose<List<FitRecipeSummary>>((ref) async* {
      await ref.watch(starterRecipesProvider.future);
      final profile = await ref.watch(marcoProfileProvider.future);
      yield* ref
          .watch(recipeRepositoryProvider)
          .watchRecipes(
            profile.id,
            onlyFavorites: ref.watch(recipeOnlyFavoritesProvider),
            search: ref.watch(recipeSearchQueryProvider),
            tag: ref.watch(recipeTagFilterProvider),
          );
    });

final recipeTagCloudProvider = Provider<List<String>>((ref) {
  final recipes =
      ref.watch(recipesProvider).valueOrNull ?? const <FitRecipeSummary>[];
  final tags = <String>{for (final recipe in recipes) ...recipe.tags}.toList()
    ..sort();
  return tags;
});

final remainingMacrosProvider = Provider<RemainingMacros>((ref) {
  final target =
      ref.watch(nutritionTargetProvider).valueOrNull ??
      const NutritionTarget.standard();
  final eaten = ref.watch(todayDiaryProvider).valueOrNull?.totals;
  return RemainingMacros.between(
    goal: Nutrients(
      calories: target.calories,
      protein: target.protein,
      carbs: target.carbs,
      fat: target.fat,
    ),
    eaten: eaten ?? const Nutrients.zero(),
  );
});

final recipeSuggestionsProvider = Provider<List<RecipeSuggestion>>((ref) {
  final recipes =
      ref.watch(recipesProvider).valueOrNull ?? const <FitRecipeSummary>[];
  return RecipeSuggestionEngine.rank(
    remaining: ref.watch(remainingMacrosProvider),
    recipes: recipes,
  );
});
