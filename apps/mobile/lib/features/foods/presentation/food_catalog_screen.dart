import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/diary/presentation/today_diary_screen.dart';
import 'package:kal_tracker/features/foods/domain/food_models.dart';
import 'package:kal_tracker/features/foods/presentation/food_catalog_providers.dart';

class FoodCatalogScreen extends ConsumerStatefulWidget {
  const FoodCatalogScreen({super.key});

  @override
  ConsumerState<FoodCatalogScreen> createState() => _FoodCatalogScreenState();
}

class _FoodCatalogScreenState extends ConsumerState<FoodCatalogScreen> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectedSection = ref.watch(foodCatalogSectionProvider);
    final foods = ref.watch(visibleFoodsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Alimenti'),
            Text(
              'Il tuo catalogo veloce',
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: TextField(
              key: const Key('food_search_field'),
              controller: _searchController,
              textInputAction: TextInputAction.search,
              onChanged: (value) =>
                  ref.read(foodSearchQueryProvider.notifier).state = value,
              decoration: InputDecoration(
                hintText: 'Cerca pollo, banana, yogurt…',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Cancella ricerca',
                        onPressed: () {
                          _searchController.clear();
                          ref.read(foodSearchQueryProvider.notifier).state = '';
                          setState(() {});
                        },
                        icon: const Icon(Icons.close_rounded),
                      ),
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _SectionChip(
                  key: const Key('food_section_all'),
                  label: 'Tutti',
                  icon: Icons.grid_view_rounded,
                  selected: selectedSection == FoodCatalogSection.all,
                  onSelected: () => _select(FoodCatalogSection.all),
                ),
                const SizedBox(width: 8),
                _SectionChip(
                  key: const Key('food_section_favorites'),
                  label: 'Preferiti',
                  icon: Icons.favorite_rounded,
                  selected: selectedSection == FoodCatalogSection.favorites,
                  onSelected: () => _select(FoodCatalogSection.favorites),
                ),
                const SizedBox(width: 8),
                _SectionChip(
                  key: const Key('food_section_recent'),
                  label: 'Recenti',
                  icon: Icons.history_rounded,
                  selected: selectedSection == FoodCatalogSection.recent,
                  onSelected: () => _select(FoodCatalogSection.recent),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: foods.when(
              data: (items) => items.isEmpty
                  ? _CatalogEmptyState(section: selectedSection)
                  : ListView.separated(
                      key: const Key('food_catalog_list'),
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      itemCount: items.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 10),
                      itemBuilder: (context, index) => _FoodCard(
                        food: items[index],
                        onFavorite: () => _toggleFavorite(items[index]),
                        onAdd: () => _addFood(items[index]),
                      ),
                    ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stackTrace) => _CatalogError(
                onRetry: () => ref.invalidate(visibleFoodsProvider),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _select(FoodCatalogSection section) {
    ref.read(foodCatalogSectionProvider.notifier).state = section;
  }

  Future<void> _toggleFavorite(FoodCatalogItem food) async {
    try {
      final profile = await ref.read(marcoProfileProvider.future);
      await ref
          .read(foodCatalogRepositoryProvider)
          .setFavorite(
            profileId: profile.id,
            foodId: food.id,
            isFavorite: !food.isFavorite,
          );
    } on Object {
      if (mounted) {
        _showMessage('Non riesco ad aggiornare i preferiti.');
      }
    }
  }

  Future<void> _addFood(FoodCatalogItem food) async {
    final added = await showModalBottomSheet<bool>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => AddManualFoodSheet(
        initialFoodName: food.name,
        initialGrams: food.defaultServingGrams,
        initialPer100g: food.per100g,
      ),
    );
    if (added != true || !mounted) {
      return;
    }

    try {
      final profile = await ref.read(marcoProfileProvider.future);
      await ref
          .read(foodCatalogRepositoryProvider)
          .markUsed(profileId: profile.id, foodId: food.id);
      if (mounted) {
        _showMessage('${food.name} aggiunto al diario di oggi.');
      }
    } on Object {
      if (mounted) {
        _showMessage('${food.name} è nel diario, ma non nei recenti.');
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _SectionChip extends StatelessWidget {
  const _SectionChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      selected: selected,
      onSelected: (_) => onSelected(),
      avatar: Icon(icon, size: 18),
      label: Text(label),
      labelStyle: const TextStyle(fontWeight: FontWeight.w700),
      selectedColor: AppPalette.mint,
      side: const BorderSide(color: AppPalette.outline),
    );
  }
}

class _FoodCard extends StatelessWidget {
  const _FoodCard({
    required this.food,
    required this.onFavorite,
    required this.onAdd,
  });

  final FoodCatalogItem food;
  final VoidCallback onFavorite;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final serving = NutritionCalculator.scale(
      per100g: food.per100g,
      grams: food.defaultServingGrams,
    );
    final number = NumberFormat.decimalPattern('it');

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: food.isFavorite
                    ? AppPalette.coralSoft
                    : AppPalette.mintSoft,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                food.isFavorite
                    ? Icons.favorite_rounded
                    : Icons.restaurant_rounded,
                color: food.isFavorite ? AppPalette.coral : AppPalette.leaf,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    food.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${number.format(food.defaultServingGrams)} g  •  '
                    '${number.format(serving.calories.round())} kcal',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: AppPalette.mutedInk),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'P ${serving.protein.toStringAsFixed(1)}  '
                    'C ${serving.carbs.toStringAsFixed(1)}  '
                    'G ${serving.fat.toStringAsFixed(1)}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: AppPalette.mutedInk,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: food.isFavorite
                  ? 'Rimuovi ${food.name} dai preferiti'
                  : 'Aggiungi ${food.name} ai preferiti',
              onPressed: onFavorite,
              icon: Icon(
                food.isFavorite
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                color: food.isFavorite ? AppPalette.coral : AppPalette.mutedInk,
              ),
            ),
            IconButton.filled(
              key: Key('quick_add_${food.id}'),
              tooltip: 'Aggiungi ${food.name} al diario',
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _CatalogEmptyState extends StatelessWidget {
  const _CatalogEmptyState({required this.section});

  final FoodCatalogSection section;

  @override
  Widget build(BuildContext context) {
    final (icon, title, message) = switch (section) {
      FoodCatalogSection.all => (
        Icons.search_off_rounded,
        'Nessun risultato',
        'Prova con un nome più semplice.',
      ),
      FoodCatalogSection.favorites => (
        Icons.favorite_border_rounded,
        'Nessun preferito',
        'Tocca il cuore sugli alimenti che usi spesso.',
      ),
      FoodCatalogSection.recent => (
        Icons.history_rounded,
        'Ancora nessun recente',
        'Gli alimenti aggiunti al diario appariranno qui.',
      ),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: AppPalette.leaf),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppPalette.mutedInk),
            ),
          ],
        ),
      ),
    );
  }
}

class _CatalogError extends StatelessWidget {
  const _CatalogError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FilledButton.tonalIcon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('Riprova'),
      ),
    );
  }
}
