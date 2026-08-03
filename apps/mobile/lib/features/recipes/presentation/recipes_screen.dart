import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';
import 'package:kal_tracker/features/recipes/presentation/recipe_providers.dart';

class RecipesScreen extends ConsumerWidget {
  const RecipesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recipes = ref.watch(visibleRecipesProvider);
    final hasFilters =
        ref.watch(recipeSearchQueryProvider).trim().isNotEmpty ||
        ref.watch(recipeTagFilterProvider) != null ||
        ref.watch(recipeOnlyFavoritesProvider);

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
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 6, 16, 10),
            child: _RecipeFilters(),
          ),
          Expanded(
            child: recipes.when(
              data: (items) => ListView(
                key: const Key('recipes_list'),
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 112),
                children: [
                  const _RecipeIntroCard(),
                  const SizedBox(height: 18),
                  if (!hasFilters) const _SuggestionsSection(),
                  Text(
                    hasFilters ? 'Risultati' : 'Pronte da provare',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 10),
                  if (items.isEmpty)
                    _NoRecipesFound(
                      onReset: () => _resetFilters(ref),
                      hasFilters: hasFilters,
                    )
                  else
                    for (final (index, recipe) in items.indexed) ...[
                      _RecipeCard(
                        recipe: recipe,
                        color: index.isEven
                            ? AppPalette.coralSoft
                            : AppPalette.lilacSoft,
                        accent: index.isEven
                            ? AppPalette.coral
                            : AppPalette.lilac,
                        onOpen: () => _openDetails(context, recipe.id),
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
                    ref.invalidate(visibleRecipesProvider);
                  },
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Riprova'),
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('create_recipe_button'),
        onPressed: () => _openRecipeEditor(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Crea ricetta'),
      ),
    );
  }

  void _resetFilters(WidgetRef ref) {
    ref.read(recipeSearchQueryProvider.notifier).state = '';
    ref.read(recipeTagFilterProvider.notifier).state = null;
    ref.read(recipeOnlyFavoritesProvider.notifier).state = false;
  }

  void _openDetails(BuildContext context, String recipeId) => context.pushNamed(
    'recipe-details',
    pathParameters: {'recipeId': recipeId},
  );

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

class _RecipeFilters extends ConsumerStatefulWidget {
  const _RecipeFilters();

  @override
  ConsumerState<_RecipeFilters> createState() => _RecipeFiltersState();
}

class _RecipeFiltersState extends ConsumerState<_RecipeFilters> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(recipeSearchQueryProvider, (previous, next) {
      if (next != _search.text) {
        _search.text = next;
      }
    });
    final tags = ref.watch(recipeTagCloudProvider);
    final selectedTag = ref.watch(recipeTagFilterProvider);
    final onlyFavorites = ref.watch(recipeOnlyFavoritesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('recipe_search_field'),
          controller: _search,
          onChanged: (value) =>
              ref.read(recipeSearchQueryProvider.notifier).state = value,
          decoration: const InputDecoration(
            hintText: 'Cerca per nome o ingrediente',
            prefixIcon: Icon(Icons.search_rounded),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilterChip(
              key: const Key('recipes_only_favorites_chip'),
              label: const Text('Solo preferite'),
              avatar: Icon(
                onlyFavorites
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                size: 18,
                color: AppPalette.coral,
              ),
              selected: onlyFavorites,
              selectedColor: AppPalette.coralSoft,
              onSelected: (value) =>
                  ref.read(recipeOnlyFavoritesProvider.notifier).state = value,
            ),
            for (final tag in tags)
              FilterChip(
                key: Key('recipe_tag_filter_$tag'),
                label: Text(tag),
                selected: selectedTag == tag,
                selectedColor: AppPalette.mint,
                onSelected: (value) =>
                    ref.read(recipeTagFilterProvider.notifier).state = value
                    ? tag
                    : null,
              ),
          ],
        ),
      ],
    );
  }
}

class _SuggestionsSection extends ConsumerWidget {
  const _SuggestionsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eaten = ref.watch(todayDiaryProvider).valueOrNull?.totals;
    if (eaten == null || eaten.calories <= 0) {
      return const SizedBox.shrink();
    }
    final remaining = ref.watch(remainingMacrosProvider);
    final suggestions = ref
        .watch(recipeSuggestionsProvider)
        .where((suggestion) => suggestion.fitsCalories)
        .take(3)
        .toList(growable: false);
    final number = NumberFormat.decimalPattern('it');

    return Column(
      key: const Key('recipe_suggestions'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Adatte a quello che ti resta oggi',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        Text(
          remaining.calories > 0
              ? 'Ti restano ${number.format(remaining.calories.round())} kcal '
                    'e ${remaining.protein.round()} g di proteine.'
              : 'Per oggi il budget calorico è chiuso.',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: AppPalette.mutedInk),
        ),
        const SizedBox(height: 10),
        if (suggestions.isEmpty)
          Container(
            padding: const EdgeInsets.all(17),
            decoration: BoxDecoration(
              color: AppPalette.yellowSoft,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Row(
              children: [
                Icon(Icons.nights_stay_rounded, color: AppPalette.yellow),
                SizedBox(width: 11),
                Expanded(
                  child: Text(
                    'Nessuna ricetta ci sta nelle calorie rimaste: meglio '
                    'qualcosa di leggero.',
                  ),
                ),
              ],
            ),
          )
        else
          for (final suggestion in suggestions) ...[
            Card(
              color: AppPalette.mintSoft,
              child: ListTile(
                key: Key('recipe_suggestion_${suggestion.recipe.id}'),
                onTap: () => context.pushNamed(
                  'recipe-details',
                  pathParameters: {'recipeId': suggestion.recipe.id},
                ),
                leading: const CircleAvatar(
                  backgroundColor: AppPalette.mint,
                  foregroundColor: AppPalette.forest,
                  child: Icon(Icons.auto_awesome_rounded),
                ),
                title: Text(suggestion.recipe.name),
                subtitle: Text(
                  '${number.format(suggestion.recipe.nutrition.perServing.calories.round())} kcal · '
                  '${suggestion.recipe.nutrition.perServing.protein.toStringAsFixed(1)} g di proteine '
                  'a porzione',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
              ),
            ),
            const SizedBox(height: 8),
          ],
        const SizedBox(height: 12),
      ],
    );
  }
}

class _NoRecipesFound extends StatelessWidget {
  const _NoRecipesFound({required this.onReset, required this.hasFilters});

  final VoidCallback onReset;
  final bool hasFilters;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppPalette.lilacSoft,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        children: [
          const Icon(Icons.search_off_rounded, color: AppPalette.lilac),
          const SizedBox(height: 10),
          Text(
            hasFilters
                ? 'Nessuna ricetta con questi filtri.'
                : 'Il ricettario è vuoto: creane una con il pulsante qui '
                      'sotto.',
            textAlign: TextAlign.center,
          ),
          if (hasFilters) ...[
            const SizedBox(height: 10),
            FilledButton.tonal(
              key: const Key('reset_recipe_filters_button'),
              onPressed: onReset,
              child: const Text('Azzera i filtri'),
            ),
          ],
        ],
      ),
    );
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
                    if (recipe.tags.isNotEmpty) ...[
                      const SizedBox(height: 7),
                      Text(
                        recipe.tags.map((tag) => '#$tag').join(' '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: AppPalette.leaf,
                        ),
                      ),
                    ],
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
