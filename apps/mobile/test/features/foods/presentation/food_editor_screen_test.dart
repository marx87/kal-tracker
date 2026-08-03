import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/app.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/foods/data/food_catalog_repository.dart';
import 'package:kal_tracker/features/foods/domain/food_models.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

void main() {
  late AppDatabase database;

  setUp(() {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
  });

  Widget app() => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(database),
      appConfigProvider.overrideWithValue(const AppConfig.offline()),
    ],
    child: const KalTrackerApp(),
  );

  Future<String> seedSkyr() async {
    final profileId = (await LocalProfileRepository(
      database,
    ).getOrCreateMarco()).id;
    return FoodCatalogRepository(database).createFood(
      profileId: profileId,
      draft: const FoodDraft(
        name: 'Skyr Milbona',
        brand: 'Lidl',
        per100g: Nutrients(calories: 63, protein: 11, carbs: 4, fat: 0.2),
        defaultServingGrams: 150,
      ),
    );
  }

  Future<void> openMine(WidgetTester tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav_foods')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('food_section_mine')));
    await tester.pumpAndSettle();
  }

  testWidgets('crea un alimento personale e lo ritrova nel catalogo', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav_foods')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create_food_button')));
    await tester.pumpAndSettle();

    expect(find.text('Nuovo alimento'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('food_editor_name_field')),
      'Skyr Milbona',
    );
    await tester.enterText(
      find.byKey(const Key('food_editor_brand_field')),
      'Lidl',
    );
    await tester.enterText(
      find.byKey(const Key('food_editor_calories_field')),
      '250',
    );
    await tester.enterText(
      find.byKey(const Key('food_editor_protein_field')),
      '11',
    );
    await tester.enterText(
      find.byKey(const Key('food_editor_carbs_field')),
      '4',
    );
    await tester.enterText(
      find.byKey(const Key('food_editor_fat_field')),
      '0,2',
    );
    await tester.enterText(
      find.byKey(const Key('food_editor_serving_field')),
      '150',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('food_editor_atwater_warning')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const Key('food_editor_calories_field')),
      '63',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('food_editor_atwater_warning')), findsNothing);
    expect(find.text('Una porzione da 150 g contiene 95 kcal'), findsOneWidget);

    final save = find.byKey(const Key('save_food_editor_button'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('food_section_mine')));
    await tester.pumpAndSettle();
    expect(find.text('Skyr Milbona'), findsOneWidget);

    final stored = await (database.select(
      database.foods,
    )..where((row) => row.name.equals('Skyr Milbona'))).getSingle();
    expect(stored.source, 'custom');
    expect(stored.brand, 'Lidl');
    expect(stored.caloriesPer100g, 63);
    expect(stored.defaultServingGrams, 150);
    await _disposeApp(tester, database);
  });

  testWidgets('modifica un alimento personale dal menu del catalogo', (
    tester,
  ) async {
    final foodId = await seedSkyr();
    await openMine(tester);

    expect(find.text('Skyr Milbona'), findsOneWidget);
    await tester.tap(find.byKey(Key('food_menu_$foodId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('edit_food_$foodId')));
    await tester.pumpAndSettle();

    expect(find.text('Modifica alimento'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const Key('food_editor_name_field')),
          )
          .controller
          ?.text,
      'Skyr Milbona',
    );
    await tester.enterText(
      find.byKey(const Key('food_editor_name_field')),
      'Skyr Milbona vaniglia',
    );
    await tester.enterText(
      find.byKey(const Key('food_editor_serving_field')),
      '200',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();

    final save = find.byKey(const Key('save_food_editor_button'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(find.text('Skyr Milbona vaniglia'), findsOneWidget);
    final stored = await (database.select(
      database.foods,
    )..where((row) => row.id.equals(foodId))).getSingle();
    expect(stored.name, 'Skyr Milbona vaniglia');
    expect(stored.defaultServingGrams, 200);
    await _disposeApp(tester, database);
  });

  testWidgets('elimina un alimento personale dopo la conferma', (tester) async {
    final foodId = await seedSkyr();
    await openMine(tester);

    await tester.tap(find.byKey(Key('food_menu_$foodId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('delete_food_$foodId')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('delete_food_dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm_delete_food')));
    await tester.pumpAndSettle();

    expect(find.text('Skyr Milbona'), findsNothing);
    expect(find.text('Nessun alimento tuo'), findsOneWidget);
    final stored = await (database.select(
      database.foods,
    )..where((row) => row.id.equals(foodId))).getSingle();
    expect(stored.deletedAt, isNotNull);
    await _disposeApp(tester, database);
  });

  testWidgets('personalizzare un alimento di base ne crea una copia', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav_foods')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('food_search_field')),
      'banana',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('food_menu_seed-banana')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('edit_food_seed-banana')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('food_editor_seed_notice')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('food_editor_name_field')),
      'Banana grande',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();

    final save = find.byKey(const Key('save_food_editor_button'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    final seed = await (database.select(
      database.foods,
    )..where((row) => row.id.equals('seed-banana'))).getSingle();
    expect(seed.name, 'Banana');
    final copies = await (database.select(
      database.foods,
    )..where((row) => row.name.equals('Banana grande'))).get();
    expect(copies, hasLength(1));
    expect(copies.single.source, 'custom');
    await _disposeApp(tester, database);
  });
}

Future<void> _disposeApp(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(database.close);
}
