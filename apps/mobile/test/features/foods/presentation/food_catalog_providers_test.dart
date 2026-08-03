import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/foods/domain/catalog_asset.dart';
import 'package:kal_tracker/features/foods/domain/food_models.dart';
import 'package:kal_tracker/features/foods/presentation/food_catalog_providers.dart';

void main() {
  test('il filtro categoria mostra anche i piatti oltre il limite di default', () async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);

    // Le categorie reali dell'asset contano 70-90 piatti: qui ne bastano 60
    // per superare il limit di default (50) del repository.
    final now = DateTime.utc(2026, 8, 1);
    final items = <CatalogAssetItem>[];
    for (var i = 0; i < 60; i++) {
      final id = 'cat-piatto-${i.toString().padLeft(2, '0')}';
      final name = 'Piatto ${i.toString().padLeft(2, '0')}';
      items.add(
        CatalogAssetItem(
          id: id,
          name: name,
          category: 'Primi piatti',
          aliases: const [],
          per100g: const Nutrients(calories: 150, protein: 7, carbs: 20, fat: 4.5),
          portionGrams: 350,
        ),
      );
      await database
          .into(database.foods)
          .insert(
            FoodsCompanion.insert(
              id: id,
              name: name,
              caloriesPer100g: 150,
              proteinPer100g: 7,
              carbsPer100g: 20,
              fatPer100g: 4.5,
              defaultServingGrams: const Value(350),
              source: const Value(FoodSource.catalog),
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
    final index = CatalogSearchIndex.fromAsset(
      CatalogAsset(version: 1, items: items),
    );

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        catalogSearchIndexProvider.overrideWith((ref) => index),
      ],
    );
    addTearDown(container.dispose);

    // Come la schermata: i provider autoDispose vanno tenuti vivi da un
    // listener, altrimenti il filtro verrebbe azzerato nel gap asincrono.
    container.listen(foodCategoryFilterProvider, (_, _) {});
    container.read(foodCategoryFilterProvider.notifier).state = 'Primi piatti';
    await container.read(catalogSearchIndexProvider.future);
    container.listen(visibleFoodsProvider, (_, _) {});

    final visible = await container.read(visibleFoodsProvider.future);
    expect(visible, hasLength(60));
    expect(
      visible.map((food) => food.name),
      contains('Piatto 59'),
    );
  });
}
