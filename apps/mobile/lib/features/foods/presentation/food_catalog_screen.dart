import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/diary/presentation/today_diary_screen.dart';
import 'package:kal_tracker/features/foods/domain/catalog_asset.dart';
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
    // La schermata tiene vivo il provider della query: il suo unico altro
    // listener (visibleFoodsProvider) lo perde a ogni rebuild asincrono e
    // un provider autoDispose senza listener verrebbe azzerato.
    final searchQuery = ref.watch(foodSearchQueryProvider);
    final selectedCategory = ref.watch(foodCategoryFilterProvider);
    final categories =
        ref.watch(catalogSearchIndexProvider).valueOrNull?.categories ??
        const <String>[];
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
                suffixIcon: searchQuery.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Cancella ricerca',
                        onPressed: () {
                          _searchController.clear();
                          ref.read(foodSearchQueryProvider.notifier).state = '';
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
                  key: const Key('food_section_mine'),
                  label: 'Solo i miei',
                  icon: Icons.person_rounded,
                  selected: selectedSection == FoodCatalogSection.mine,
                  onSelected: () => _select(FoodCatalogSection.mine),
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
          if (categories.isNotEmpty) ...[
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  for (final category in categories) ...[
                    if (category != categories.first) const SizedBox(width: 8),
                    _SectionChip(
                      key: Key(
                        'food_category_${CatalogSearchIndex.slugify(category)}',
                      ),
                      label: category,
                      selected: selectedCategory == category,
                      onSelected: () => _selectCategory(category),
                    ),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Expanded(
            child: foods.when(
              data: (items) => items.isEmpty
                  ? _CatalogEmptyState(section: selectedSection)
                  : ListView.separated(
                      key: const Key('food_catalog_list'),
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 112),
                      itemCount: items.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 10),
                      itemBuilder: (context, index) => _FoodCard(
                        food: items[index],
                        onFavorite: () => _toggleFavorite(items[index]),
                        onAdd: () => _addFood(items[index]),
                        onEdit: () => _editFood(items[index]),
                        onDelete: () => _deleteFood(items[index]),
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
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('create_food_button'),
        onPressed: _createFood,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Nuovo alimento'),
      ),
    );
  }

  void _select(FoodCatalogSection section) {
    ref.read(foodCatalogSectionProvider.notifier).state = section;
  }

  void _selectCategory(String category) {
    final notifier = ref.read(foodCategoryFilterProvider.notifier);
    notifier.state = notifier.state == category ? null : category;
  }

  Future<void> _createFood() async {
    final savedId = await context.pushNamed<String>('food-create');
    if (savedId != null && mounted) {
      _showMessage('Alimento salvato nel tuo catalogo.');
    }
  }

  Future<void> _editFood(FoodCatalogItem food) async {
    final savedId = await context.pushNamed<String>(
      'food-edit',
      pathParameters: {'foodId': food.id},
    );
    if (savedId == null || !mounted) {
      return;
    }
    _showMessage(
      savedId == food.id
          ? '${food.name} aggiornato.'
          : 'Ho creato la tua copia di ${food.name}.',
    );
  }

  Future<void> _deleteFood(FoodCatalogItem food) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('delete_food_dialog'),
        title: Text('Elimino ${food.name}?'),
        content: const Text(
          'Sparisce dal catalogo, ma resta nel diario dei giorni passati.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            key: const Key('confirm_delete_food'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Elimina'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    try {
      final profile = await ref.read(marcoProfileProvider.future);
      await ref
          .read(foodCatalogRepositoryProvider)
          .deleteFood(profileId: profile.id, foodId: food.id);
      if (mounted) {
        _showMessage('${food.name} eliminato dal catalogo.');
      }
    } on FoodCatalogException catch (error) {
      if (mounted) {
        _showMessage(error.message);
      }
    } on Object {
      if (mounted) {
        _showMessage('Non riesco a eliminare ${food.name}.');
      }
    }
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
    final dayLabel = diaryDayLabel(
      ref.read(selectedDayProvider),
      ref.read(todayProvider),
    ).toLowerCase();

    try {
      final profile = await ref.read(marcoProfileProvider.future);
      await ref
          .read(foodCatalogRepositoryProvider)
          .markUsed(profileId: profile.id, foodId: food.id);
      if (mounted) {
        _showMessage('${food.name} aggiunto al diario di $dayLabel.');
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
    required this.selected,
    required this.onSelected,
    this.icon,
    super.key,
  });

  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      selected: selected,
      onSelected: (_) => onSelected(),
      avatar: icon == null ? null : Icon(icon, size: 18),
      label: Text(label),
      labelStyle: const TextStyle(fontWeight: FontWeight.w700),
      selectedColor: AppPalette.mint,
      side: const BorderSide(color: AppPalette.outline),
    );
  }
}

enum _FoodAction { edit, delete }

class _FoodCard extends StatelessWidget {
  const _FoodCard({
    required this.food,
    required this.onFavorite,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  final FoodCatalogItem food;
  final VoidCallback onFavorite;
  final VoidCallback onAdd;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

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
                    '${food.brand == null ? '' : '${food.brand}  •  '}'
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
            PopupMenuButton<_FoodAction>(
              key: Key('food_menu_${food.id}'),
              tooltip: 'Gestisci ${food.name}',
              onSelected: (action) {
                if (action == _FoodAction.edit) {
                  onEdit();
                  return;
                }
                onDelete();
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  key: Key('edit_food_${food.id}'),
                  value: _FoodAction.edit,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.edit_rounded),
                    title: Text(food.isBuiltIn ? 'Personalizza' : 'Modifica'),
                  ),
                ),
                if (!food.isBuiltIn)
                  PopupMenuItem(
                    key: Key('delete_food_${food.id}'),
                    value: _FoodAction.delete,
                    child: const ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.delete_outline_rounded),
                      title: Text('Elimina'),
                    ),
                  ),
              ],
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
      FoodCatalogSection.mine => (
        Icons.person_add_alt_rounded,
        'Nessun alimento tuo',
        'Tocca “Nuovo alimento” per aggiungere le marche che compri.',
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
