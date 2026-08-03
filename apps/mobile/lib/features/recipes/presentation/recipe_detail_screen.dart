import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';
import 'package:kal_tracker/features/recipes/presentation/recipe_providers.dart';

class RecipeDetailScreen extends ConsumerStatefulWidget {
  const RecipeDetailScreen({required this.recipeId, super.key});

  final String recipeId;

  @override
  ConsumerState<RecipeDetailScreen> createState() => _RecipeDetailScreenState();
}

class _RecipeDetailScreenState extends ConsumerState<RecipeDetailScreen> {
  MealType _mealType = MealType.lunch;
  bool _adding = false;
  bool _duplicating = false;

  @override
  Widget build(BuildContext context) {
    final details = ref.watch(recipeDetailsProvider(widget.recipeId));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dettaglio ricetta'),
        actions: [
          if (details.valueOrNull case final recipe?)
            IconButton(
              key: const Key('delete_recipe_button'),
              tooltip: 'Elimina ricetta',
              onPressed: () => _delete(recipe),
              icon: const Icon(Icons.delete_outline_rounded),
            ),
        ],
      ),
      body: details.when(
        data: (recipe) => recipe == null
            ? const Center(child: Text('Questa ricetta non è più disponibile.'))
            : _RecipeDetailsBody(
                details: recipe,
                selectedMeal: _mealType,
                adding: _adding,
                duplicating: _duplicating,
                onMealChanged: (value) => setState(() => _mealType = value),
                onAdd: () => _addServing(recipe),
                onFavorite: () => _toggleFavorite(recipe),
                onEdit: _openEditor,
                onDuplicate: _duplicate,
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(
          child: FilledButton.tonalIcon(
            onPressed: () =>
                ref.invalidate(recipeDetailsProvider(widget.recipeId)),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Riprova'),
          ),
        ),
      ),
    );
  }

  Future<void> _openEditor() async {
    final savedId = await context.pushNamed<String>(
      'recipe-edit',
      pathParameters: {'recipeId': widget.recipeId},
    );
    if (!mounted) {
      return;
    }
    ref.invalidate(recipeDetailsProvider(widget.recipeId));
    if (savedId != null) {
      _message('Ricetta aggiornata.');
    }
  }

  Future<void> _duplicate() async {
    setState(() => _duplicating = true);
    try {
      await ref.read(recipeRepositoryProvider).duplicateRecipe(widget.recipeId);
      if (mounted) {
        _message('Ho creato una copia nel tuo ricettario.');
      }
    } on Object {
      if (mounted) {
        _message('Non riesco a duplicare questa ricetta.');
      }
    } finally {
      if (mounted) {
        setState(() => _duplicating = false);
      }
    }
  }

  Future<void> _delete(FitRecipeDetails details) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('delete_recipe_dialog'),
        title: Text('Elimino ${details.summary.name}?'),
        content: const Text(
          'Sparisce dal ricettario, ma le porzioni già nel diario restano.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            key: const Key('confirm_delete_recipe'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Elimina'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(recipeRepositoryProvider).deleteRecipe(widget.recipeId);
      if (mounted) {
        context.pop();
        messenger.showSnackBar(
          SnackBar(content: Text('${details.summary.name} eliminata.')),
        );
      }
    } on Object {
      if (mounted) {
        _message('Non riesco a eliminare questa ricetta.');
      }
    }
  }

  Future<void> _toggleFavorite(FitRecipeDetails details) async {
    try {
      await ref
          .read(recipeRepositoryProvider)
          .setFavorite(details.summary.id, !details.summary.isFavorite);
      ref.invalidate(recipeDetailsProvider(widget.recipeId));
    } on Object {
      if (mounted) {
        _message('Non riesco ad aggiornare i preferiti.');
      }
    }
  }

  Future<void> _addServing(FitRecipeDetails details) async {
    setState(() => _adding = true);
    try {
      final profile = await ref.read(marcoProfileProvider.future);
      final servingGrams =
          details.ingredients.fold<double>(
            0,
            (total, ingredient) => total + ingredient.grams,
          ) /
          details.summary.servings;
      final serving = details.summary.nutrition.perServing;
      final per100Factor = 100 / servingGrams;
      final per100g = Nutrients(
        calories: serving.calories * per100Factor,
        protein: serving.protein * per100Factor,
        carbs: serving.carbs * per100Factor,
        fat: serving.fat * per100Factor,
      );

      await ref
          .read(diaryRepositoryProvider)
          .addManualFood(
            profileId: profile.id,
            input: ManualFoodInput(
              foodName: '${details.summary.name} · 1 porzione',
              grams: servingGrams,
              per100g: per100g,
              mealType: _mealType,
              eatenAt: AppTime.nowInRome(),
            ),
          );
      if (mounted) {
        _message('Una porzione è stata aggiunta al diario di oggi.');
      }
    } on Object {
      if (mounted) {
        _message('Non riesco ad aggiungere questa ricetta al diario.');
      }
    } finally {
      if (mounted) {
        setState(() => _adding = false);
      }
    }
  }

  void _message(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _RecipeDetailsBody extends StatelessWidget {
  const _RecipeDetailsBody({
    required this.details,
    required this.selectedMeal,
    required this.adding,
    required this.duplicating,
    required this.onMealChanged,
    required this.onAdd,
    required this.onFavorite,
    required this.onEdit,
    required this.onDuplicate,
  });

  final FitRecipeDetails details;
  final MealType selectedMeal;
  final bool adding;
  final bool duplicating;
  final ValueChanged<MealType> onMealChanged;
  final VoidCallback onAdd;
  final VoidCallback onFavorite;
  final VoidCallback onEdit;
  final VoidCallback onDuplicate;

  @override
  Widget build(BuildContext context) {
    final summary = details.summary;
    final perServing = summary.nutrition.perServing;
    final calorieLabel = NumberFormat.decimalPattern(
      'it',
    ).format(perServing.calories.round());

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
      children: [
        Card(
          color: AppPalette.coralSoft,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.ramen_dining_rounded,
                      size: 54,
                      color: AppPalette.coral,
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            summary.name,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          if (summary.description case final description?) ...[
                            const SizedBox(height: 5),
                            Text(description),
                          ],
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: summary.isFavorite
                          ? 'Rimuovi dai preferiti'
                          : 'Aggiungi ai preferiti',
                      onPressed: onFavorite,
                      icon: Icon(
                        summary.isFavorite
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        color: AppPalette.coral,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: _NutritionFact(
                        value: calorieLabel,
                        label: 'kcal',
                        color: AppPalette.forest,
                      ),
                    ),
                    Expanded(
                      child: _NutritionFact(
                        value: perServing.protein.toStringAsFixed(1),
                        label: 'proteine',
                        color: AppPalette.coral,
                      ),
                    ),
                    Expanded(
                      child: _NutritionFact(
                        value: perServing.carbs.toStringAsFixed(1),
                        label: 'carbo',
                        color: AppPalette.yellow,
                      ),
                    ),
                    Expanded(
                      child: _NutritionFact(
                        value: perServing.fat.toStringAsFixed(1),
                        label: 'grassi',
                        color: AppPalette.lilac,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (summary.tags.isNotEmpty) ...[
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tag in summary.tags)
                Chip(
                  key: Key('recipe_detail_tag_$tag'),
                  label: Text(tag),
                  backgroundColor: AppPalette.mintSoft,
                ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('edit_recipe_button'),
                onPressed: duplicating ? null : onEdit,
                icon: const Icon(Icons.edit_rounded),
                label: const Text('Modifica'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('duplicate_recipe_button'),
                onPressed: duplicating ? null : onDuplicate,
                icon: duplicating
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.copy_all_rounded),
                label: const Text('Duplica'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text('Ingredienti', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              for (final (index, ingredient) in details.ingredients.indexed)
                Column(
                  children: [
                    ListTile(
                      leading: const Icon(
                        Icons.check_circle_rounded,
                        color: AppPalette.leaf,
                      ),
                      title: Text(ingredient.name),
                      trailing: Text(
                        '${NumberFormat.decimalPattern('it').format(ingredient.grams)} g',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    if (index != details.ingredients.length - 1)
                      const Divider(indent: 56),
                  ],
                ),
            ],
          ),
        ),
        if (details.instructions case final instructions?) ...[
          const SizedBox(height: 20),
          Text('Preparazione', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(17),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.timer_outlined, color: AppPalette.lilac),
                  const SizedBox(width: 12),
                  Expanded(child: Text(instructions)),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 20),
        Text(
          'Dove la aggiungiamo?',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final meal in MealType.values)
              ChoiceChip(
                label: Text(_mealLabel(meal)),
                selected: selectedMeal == meal,
                onSelected: (_) => onMealChanged(meal),
                selectedColor: AppPalette.mint,
              ),
          ],
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const Key('add_recipe_serving_button'),
          onPressed: adding ? null : onAdd,
          icon: adding
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add_rounded),
          label: Text(adding ? 'Aggiunta…' : 'Aggiungi 1 porzione al diario'),
        ),
      ],
    );
  }
}

class _NutritionFact extends StatelessWidget {
  const _NutritionFact({
    required this.value,
    required this.label,
    required this.color,
  });

  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: color,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ],
    );
  }
}

String _mealLabel(MealType meal) => switch (meal) {
  MealType.breakfast => 'Colazione',
  MealType.lunch => 'Pranzo',
  MealType.dinner => 'Cena',
  MealType.snack => 'Spuntino',
};
