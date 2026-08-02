import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/foods/domain/food_models.dart';
import 'package:kal_tracker/features/foods/presentation/food_catalog_providers.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';
import 'package:kal_tracker/features/recipes/presentation/recipe_providers.dart';

class RecipeEditorScreen extends ConsumerStatefulWidget {
  const RecipeEditorScreen({super.key});

  @override
  ConsumerState<RecipeEditorScreen> createState() => _RecipeEditorScreenState();
}

class _RecipeEditorScreenState extends ConsumerState<RecipeEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _servings = TextEditingController(text: '2');
  final _prepMinutes = TextEditingController(text: '20');
  final _instructions = TextEditingController();
  final _ingredients = <_SelectedIngredient>[];
  bool _showIngredientError = false;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _servings.dispose();
    _prepMinutes.dispose();
    _instructions.dispose();
    for (final ingredient in _ingredients) {
      ingredient.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final preview = _calculatePreview();
    return Scaffold(
      appBar: AppBar(title: const Text('Nuova ricetta')),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          key: const Key('recipe_editor_list'),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _EditorIntroCard(),
              const SizedBox(height: 18),
              Text('La ricetta', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 10),
              TextFormField(
                key: const Key('recipe_name_field'),
                controller: _name,
                enabled: !_saving,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Nome ricetta'),
                validator: (value) {
                  final clean = value?.trim() ?? '';
                  if (clean.isEmpty) {
                    return 'Inserisci un nome';
                  }
                  if (clean.length > 160) {
                    return 'Massimo 160 caratteri';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 10),
              TextFormField(
                key: const Key('recipe_description_field'),
                controller: _description,
                enabled: !_saving,
                textCapitalization: TextCapitalization.sentences,
                maxLength: 600,
                minLines: 1,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Descrizione (facoltativa)',
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Expanded(
                    child: _IntegerField(
                      key: const Key('recipe_servings_field'),
                      controller: _servings,
                      label: 'Porzioni',
                      minimum: 1,
                      maximum: 100,
                      enabled: !_saving,
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _IntegerField(
                      key: const Key('recipe_prep_minutes_field'),
                      controller: _prepMinutes,
                      label: 'Tempo (min)',
                      minimum: 0,
                      maximum: 10080,
                      enabled: !_saving,
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Ingredienti',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  OutlinedButton.icon(
                    key: const Key('add_recipe_ingredient_button'),
                    onPressed: _saving ? null : _pickIngredient,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Aggiungi'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_ingredients.isEmpty)
                _IngredientEmptyState(showError: _showIngredientError)
              else
                for (final ingredient in _ingredients) ...[
                  _IngredientEditorCard(
                    ingredient: ingredient,
                    enabled: !_saving,
                    onChanged: () => setState(() {}),
                    onRemove: () => _removeIngredient(ingredient),
                  ),
                  const SizedBox(height: 9),
                ],
              const SizedBox(height: 12),
              _NutritionPreview(preview: preview),
              const SizedBox(height: 20),
              Text(
                'Preparazione',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 10),
              TextFormField(
                key: const Key('recipe_instructions_field'),
                controller: _instructions,
                enabled: !_saving,
                textCapitalization: TextCapitalization.sentences,
                minLines: 4,
                maxLines: 8,
                maxLength: 4000,
                decoration: const InputDecoration(
                  labelText: 'Istruzioni (facoltative)',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                key: const Key('save_recipe_button'),
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded),
                label: Text(_saving ? 'Salvataggio…' : 'Salva ricetta'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  RecipeNutrition? _calculatePreview() {
    final servings = int.tryParse(_servings.text.trim());
    if (servings == null || servings <= 0 || servings > 100) {
      return null;
    }
    final drafts = <RecipeIngredientDraft>[];
    for (final selected in _ingredients) {
      final grams = _parseDecimal(selected.grams.text);
      if (grams == null || grams <= 0) {
        return null;
      }
      drafts.add(selected.toDraft(grams));
    }
    if (drafts.isEmpty) {
      return null;
    }
    return RecipeNutritionCalculator.calculate(
      ingredients: drafts,
      servings: servings,
    );
  }

  Future<void> _pickIngredient() async {
    final food = await showModalBottomSheet<FoodCatalogItem>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => const _FoodPickerSheet(),
    );
    if (food == null || !mounted) {
      return;
    }
    if (_ingredients.any((ingredient) => ingredient.food.id == food.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${food.name} è già nella ricetta.')),
      );
      return;
    }
    setState(() {
      _showIngredientError = false;
      _ingredients.add(_SelectedIngredient(food));
    });
  }

  void _removeIngredient(_SelectedIngredient ingredient) {
    setState(() => _ingredients.remove(ingredient));
    ingredient.dispose();
  }

  Future<void> _save() async {
    final formIsValid = _formKey.currentState!.validate();
    if (_ingredients.isEmpty) {
      setState(() => _showIngredientError = true);
      return;
    }
    if (!formIsValid) {
      return;
    }
    final preview = _calculatePreview();
    if (preview == null) {
      return;
    }

    setState(() => _saving = true);
    try {
      final profile = await ref.read(marcoProfileProvider.future);
      final id = await ref
          .read(recipeRepositoryProvider)
          .createRecipe(
            profileId: profile.id,
            draft: FitRecipeDraft(
              name: _name.text,
              description: _description.text,
              instructions: _instructions.text,
              servings: int.parse(_servings.text),
              prepMinutes: int.parse(_prepMinutes.text),
              ingredients: [
                for (final ingredient in _ingredients)
                  ingredient.toDraft(_parseDecimal(ingredient.grams.text)!),
              ],
            ),
          );
      if (mounted) {
        context.pop(id);
      }
    } on Object {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Non riesco a salvare la ricetta.')),
        );
      }
    }
  }
}

class _SelectedIngredient {
  _SelectedIngredient(this.food)
    : grams = TextEditingController(
        text: _editableNumber(food.defaultServingGrams),
      );

  final FoodCatalogItem food;
  final TextEditingController grams;

  RecipeIngredientDraft toDraft(double quantity) => RecipeIngredientDraft(
    name: food.name,
    // Built-in foods use local, human-readable IDs. Their nutrient snapshot is
    // portable; keeping the remote FK null avoids sending a non-UUID value.
    foodId: food.source == 'seed' ? null : food.id,
    grams: quantity,
    per100g: food.per100g,
  );

  void dispose() => grams.dispose();
}

class _EditorIntroCard extends StatelessWidget {
  const _EditorIntroCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppPalette.yellowSoft,
      child: const Padding(
        padding: EdgeInsets.all(17),
        child: Row(
          children: [
            Icon(Icons.lightbulb_rounded, color: AppPalette.yellow, size: 32),
            SizedBox(width: 13),
            Expanded(
              child: Text(
                'Scegli gli ingredienti: calorie e macro vengono calcolati '
                'dai grammi, non stimati.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IngredientEmptyState extends StatelessWidget {
  const _IngredientEmptyState({required this.showError});

  final bool showError;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: showError ? AppPalette.coralSoft : AppPalette.mintSoft,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: showError ? AppPalette.coral : AppPalette.outline,
        ),
      ),
      child: Row(
        children: [
          Icon(
            showError ? Icons.error_outline_rounded : Icons.eco_rounded,
            color: showError ? AppPalette.coral : AppPalette.leaf,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              showError
                  ? 'Aggiungi almeno un ingrediente.'
                  : 'Aggiungi il primo ingrediente dal catalogo.',
            ),
          ),
        ],
      ),
    );
  }
}

class _IngredientEditorCard extends StatelessWidget {
  const _IngredientEditorCard({
    required this.ingredient,
    required this.enabled,
    required this.onChanged,
    required this.onRemove,
  });

  final _SelectedIngredient ingredient;
  final bool enabled;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: AppPalette.mint,
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.restaurant_rounded,
                color: AppPalette.leaf,
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ingredient.food.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    '${ingredient.food.per100g.calories.round()} kcal / 100 g',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: AppPalette.mutedInk),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 88,
              child: TextFormField(
                key: Key('recipe_ingredient_grams_${ingredient.food.id}'),
                controller: ingredient.grams,
                enabled: enabled,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9,.]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Grammi',
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 12,
                  ),
                ),
                onChanged: (_) => onChanged(),
                validator: (value) {
                  final grams = _parseDecimal(value ?? '');
                  return grams == null || grams <= 0 ? 'Non validi' : null;
                },
              ),
            ),
            IconButton(
              tooltip: 'Rimuovi ${ingredient.food.name}',
              onPressed: enabled ? onRemove : null,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _NutritionPreview extends StatelessWidget {
  const _NutritionPreview({required this.preview});

  final RecipeNutrition? preview;

  @override
  Widget build(BuildContext context) {
    final nutrition = preview?.perServing;
    return Card(
      color: AppPalette.lilacSoft,
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.calculate_rounded, color: AppPalette.lilac),
                const SizedBox(width: 9),
                Text(
                  'Anteprima per porzione',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 13),
            if (nutrition == null)
              const Text(
                'Inserisci ingredienti, grammi e porzioni validi.',
                style: TextStyle(color: AppPalette.mutedInk),
              )
            else
              Semantics(
                key: const Key('recipe_nutrition_preview'),
                label:
                    '${nutrition.calories.round()} chilocalorie, '
                    '${nutrition.protein.toStringAsFixed(1)} grammi di proteine, '
                    '${nutrition.carbs.toStringAsFixed(1)} grammi di carboidrati, '
                    '${nutrition.fat.toStringAsFixed(1)} grammi di grassi per porzione',
                child: ExcludeSemantics(
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _PreviewValue(
                              key: const Key('recipe_preview_calories'),
                              value: nutrition.calories.round().toString(),
                              label: 'kcal',
                              color: AppPalette.forest,
                            ),
                          ),
                          Expanded(
                            child: _PreviewValue(
                              value: nutrition.protein.toStringAsFixed(1),
                              label: 'proteine',
                              color: AppPalette.coral,
                            ),
                          ),
                          Expanded(
                            child: _PreviewValue(
                              value: nutrition.carbs.toStringAsFixed(1),
                              label: 'carbo',
                              color: AppPalette.yellow,
                            ),
                          ),
                          Expanded(
                            child: _PreviewValue(
                              value: nutrition.fat.toStringAsFixed(1),
                              label: 'grassi',
                              color: AppPalette.lilac,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Ricetta intera: '
                        '${preview!.total.calories.round()} kcal',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppPalette.mutedInk,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PreviewValue extends StatelessWidget {
  const _PreviewValue({
    required this.value,
    required this.label,
    required this.color,
    super.key,
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

class _IntegerField extends StatelessWidget {
  const _IntegerField({
    required this.controller,
    required this.label,
    required this.minimum,
    required this.maximum,
    required this.enabled,
    required this.onChanged,
    super.key,
  });

  final TextEditingController controller;
  final String label;
  final int minimum;
  final int maximum;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(labelText: label),
      onChanged: onChanged,
      validator: (value) {
        final parsed = int.tryParse(value ?? '');
        if (parsed == null || parsed < minimum || parsed > maximum) {
          return '$minimum–$maximum';
        }
        return null;
      },
    );
  }
}

class _FoodPickerSheet extends ConsumerStatefulWidget {
  const _FoodPickerSheet();

  @override
  ConsumerState<_FoodPickerSheet> createState() => _FoodPickerSheetState();
}

class _FoodPickerSheetState extends ConsumerState<_FoodPickerSheet> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final foods = ref.watch(foodPickerProvider(_query));
    final number = NumberFormat.decimalPattern('it');
    return FractionallySizedBox(
      heightFactor: 0.88,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Scegli un ingrediente',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('recipe_food_search_field'),
                  controller: _search,
                  autofocus: false,
                  onChanged: (value) => setState(() => _query = value),
                  decoration: const InputDecoration(
                    hintText: 'Cerca nel catalogo',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: foods.when(
              data: (items) => items.isEmpty
                  ? const Center(child: Text('Nessun alimento trovato.'))
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                      itemCount: items.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 7),
                      itemBuilder: (context, index) {
                        final food = items[index];
                        return Card(
                          child: ListTile(
                            key: Key('pick_food_${food.id}'),
                            onTap: () => Navigator.of(context).pop(food),
                            leading: const CircleAvatar(
                              backgroundColor: AppPalette.mint,
                              foregroundColor: AppPalette.forest,
                              child: Icon(Icons.eco_rounded),
                            ),
                            title: Text(food.name),
                            subtitle: Text(
                              '${number.format(food.per100g.calories.round())} '
                              'kcal / 100 g',
                            ),
                            trailing: const Icon(Icons.add_circle_rounded),
                          ),
                        );
                      },
                    ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stackTrace) => Center(
                child: FilledButton.tonal(
                  onPressed: () => ref.invalidate(foodPickerProvider(_query)),
                  child: const Text('Riprova'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

double? _parseDecimal(String value) {
  final parsed = double.tryParse(value.trim().replaceAll(',', '.'));
  return parsed != null && parsed.isFinite ? parsed : null;
}

String _editableNumber(double value) => value == value.roundToDouble()
    ? value.round().toString()
    : value.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
