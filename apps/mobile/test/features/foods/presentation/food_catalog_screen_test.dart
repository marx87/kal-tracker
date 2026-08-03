import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/app.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/foods/domain/catalog_asset.dart';
import 'package:kal_tracker/features/foods/presentation/food_catalog_providers.dart';

void main() {
  testWidgets('l’aggiunta rapida dice in quale giorno finisce l’alimento', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          appConfigProvider.overrideWithValue(const AppConfig.offline()),
        ],
        child: const KalTrackerApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('previous_day_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav_foods')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('quick_add_seed-banana')));
    await tester.pumpAndSettle();
    final save = find.byKey(const Key('save_food_button'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(find.text('Banana aggiunto al diario di ieri.'), findsOneWidget);

    final meal = await database.select(database.meals).getSingle();
    final item = await database.select(database.mealItems).getSingle();
    expect(item.foodName, 'Banana');
    expect(
      DiaryDay.isSameDay(
        AppTime.inRome(meal.eatenAt),
        DiaryDay.shift(AppTime.nowInRome(), -1),
      ),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(database.close);
  });

  testWidgets('il filtro categoria e gli alias trovano i piatti del catalogo', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final now = DateTime.utc(2026, 8, 1);
    Future<void> insertCatalogFood(String id, String name) => database
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
            source: const Value('catalog'),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await insertCatalogFood('cat-pasta-al-ragu', 'Pasta al ragù');
    await insertCatalogFood('cat-tiramisu', 'Tiramisù');

    final index = CatalogSearchIndex.fromAsset(
      const CatalogAsset(
        version: 1,
        items: [
          CatalogAssetItem(
            id: 'cat-pasta-al-ragu',
            name: 'Pasta al ragù',
            category: 'Primi piatti',
            aliases: ['pasta alla bolognese'],
            per100g: Nutrients(calories: 150, protein: 7, carbs: 20, fat: 4.5),
            portionGrams: 350,
          ),
          CatalogAssetItem(
            id: 'cat-tiramisu',
            name: 'Tiramisù',
            category: 'Colazione, dolci e snack',
            aliases: ['tiramisu della nonna'],
            per100g: Nutrients(calories: 290, protein: 5, carbs: 32, fat: 16),
            portionGrams: 120,
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          appConfigProvider.overrideWithValue(const AppConfig.offline()),
          catalogSearchIndexProvider.overrideWith((ref) => index),
        ],
        child: const KalTrackerApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav_foods')));
    await tester.pumpAndSettle();

    // Il filtro per categoria mostra solo i piatti di quella categoria.
    final primiChip = find.byKey(const Key('food_category_primi-piatti'));
    expect(primiChip, findsOneWidget);
    await tester.tap(primiChip);
    await tester.pumpAndSettle();
    expect(find.text('Pasta al ragù'), findsOneWidget);
    expect(find.text('Tiramisù'), findsNothing);
    expect(find.text('Banana'), findsNothing);

    // Un secondo tocco toglie il filtro.
    await tester.tap(primiChip);
    await tester.pumpAndSettle();
    expect(find.text('Banana'), findsOneWidget);

    // «bolognese» non è nel nome: il piatto arriva dall'alias.
    await tester.enterText(
      find.byKey(const Key('food_search_field')),
      'bolognese',
    );
    await tester.pumpAndSettle();
    expect(find.text('Pasta al ragù'), findsOneWidget);
    expect(find.text('Banana'), findsNothing);

    // La porzione tipica compare già nella card (350 g).
    expect(find.textContaining('350 g'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(database.close);
  });
}
