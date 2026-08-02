import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';
import 'package:kal_tracker/features/recipes/presentation/recipe_providers.dart';

class RecipesScreen extends ConsumerWidget {
  const RecipesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recipes = ref.watch(recipesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Ricette fit'),
            Text(
              'Idee semplici, valori già calcolati',
              style: TextStyle(
                color: AppPalette.mutedInk,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
      body: recipes.when(
        data: (items) => ListView(
          key: const Key('recipes_list'),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 112),
          children: [
            const _RecipeIntroCard(),
            const SizedBox(height: 18),
            Text(
              'Pronte da provare',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 10),
            for (final (index, recipe) in items.indexed) ...[
              _RecipeCard(
                recipe: recipe,
                color: index.isEven
                    ? AppPalette.coralSoft
                    : AppPalette.lilacSoft,
                accent: index.isEven ? AppPalette.coral : AppPalette.lilac,
                onOpen: () => context.pushNamed(
                  'recipe-details',
                  pathParameters: {'recipeId': recipe.id},
                ),
                onFavorite: () => _toggleFavorite(context, ref, recipe),
              ),
              const SizedBox(height: 12),
            ],
          ],
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(
          child: FilledButton.tonalIcon(
            onPressed: () {
              ref.invalidate(starterRecipesProvider);
              ref.invalidate(recipesProvider);
            },
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Riprova'),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('create_recipe_button'),
        onPressed: () => _openRecipeEditor(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Crea ricetta'),
      ),
    );
  }

  Future<void> _openRecipeEditor(BuildContext context) async {
    final recipeId = await context.pushNamed<String>('recipe-create');
    if (recipeId != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ricetta salvata nel tuo ricettario.')),
      );
    }
  }

  Future<void> _toggleFavorite(
    BuildContext context,
    WidgetRef ref,
    FitRecipeSummary recipe,
  ) async {
    try {
      await ref
          .read(recipeRepositoryProvider)
          .setFavorite(recipe.id, !recipe.isFavorite);
    } on Object {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Non riesco ad aggiornare questa ricetta.'),
          ),
        );
      }
    }
  }
}

class _RecipeIntroCard extends StatelessWidget {
  const _RecipeIntroCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppPalette.mint,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                color: AppPalette.paper,
                borderRadius: BorderRadius.circular(21),
              ),
              child: const Icon(
                Icons.auto_awesome_rounded,
                size: 30,
                color: AppPalette.forest,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Parti con gusto',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Apri una ricetta e aggiungi una porzione al diario con '
                    'un solo tocco.',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecipeCard extends StatelessWidget {
  const _RecipeCard({
    required this.recipe,
    required this.color,
    required this.accent,
    required this.onOpen,
    required this.onFavorite,
  });

  final FitRecipeSummary recipe;
  final Color color;
  final Color accent;
  final VoidCallback onOpen;
  final VoidCallback onFavorite;

  @override
  Widget build(BuildContext context) {
    final calories = NumberFormat.decimalPattern(
      'it',
    ).format(recipe.nutrition.perServing.calories.round());
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('recipe_card_${recipe.id}'),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 74,
                height: 86,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Icon(
                  Icons.ramen_dining_rounded,
                  size: 38,
                  color: accent,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            recipe.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: recipe.isFavorite
                              ? 'Rimuovi dai preferiti'
                              : 'Aggiungi ai preferiti',
                          onPressed: onFavorite,
                          icon: Icon(
                            recipe.isFavorite
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
                            color: recipe.isFavorite
                                ? AppPalette.coral
                                : AppPalette.mutedInk,
                          ),
                        ),
                      ],
                    ),
                    if (recipe.description case final description?) ...[
                      Text(
                        description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppPalette.mutedInk,
                        ),
                      ),
                      const SizedBox(height: 9),
                    ],
                    Wrap(
                      spacing: 10,
                      runSpacing: 5,
                      children: [
                        _RecipeFact(
                          icon: Icons.local_fire_department_outlined,
                          label: '$calories kcal',
                        ),
                        _RecipeFact(
                          icon: Icons.schedule_rounded,
                          label: '${recipe.prepMinutes} min',
                        ),
                        _RecipeFact(
                          icon: Icons.restaurant_rounded,
                          label: '${recipe.servings} porzioni',
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecipeFact extends StatelessWidget {
  const _RecipeFact({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: AppPalette.leaf),
        const SizedBox(width: 3),
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: AppPalette.mutedInk),
        ),
      ],
    );
  }
}
