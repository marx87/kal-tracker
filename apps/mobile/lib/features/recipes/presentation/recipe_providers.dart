import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/recipes/data/recipe_repository.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';

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
