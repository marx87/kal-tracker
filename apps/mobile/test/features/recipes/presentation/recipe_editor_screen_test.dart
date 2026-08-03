import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/app.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';

void main() {
  testWidgets(
    'crea una ricetta dal catalogo con anteprima nutrizionale deterministica',
    (tester) async {
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
      await tester.tap(find.byKey(const Key('nav_recipes')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('create_recipe_button')));
      await tester.pumpAndSettle();

      expect(find.text('Nuova ricetta'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('recipe_name_field')),
        'Colazione di Marco',
      );
      await tester.enterText(
        find.byKey(const Key('recipe_prep_minutes_field')),
        '10',
      );

      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      final addIngredient = find.byKey(
        const Key('add_recipe_ingredient_button'),
      );
      await tester.ensureVisible(addIngredient);
      await tester.tap(addIngredient);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('recipe_food_search_field')),
        'avena',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pick_food_seed-oats')));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(const Key('recipe_preview_calories')),
          matching: find.text('97'),
        ),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('recipe_ingredient_grams_seed-oats')),
        '100',
      );
      await tester.pump();

      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await tester.ensureVisible(addIngredient);
      await tester.tap(addIngredient);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('recipe_food_search_field')),
        'yogurt',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pick_food_seed-greek-yogurt')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('recipe_ingredient_grams_seed-greek-yogurt')),
        '340',
      );
      await tester.pump();

      expect(
        find.descendant(
          of: find.byKey(const Key('recipe_preview_calories')),
          matching: find.text('295'),
        ),
        findsOneWidget,
      );

      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      final save = find.byKey(const Key('save_recipe_button'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      final storedRows = await (database.select(
        database.fitRecipes,
      )..where((row) => row.name.equals('Colazione di Marco'))).get();
      expect(storedRows, hasLength(1));
      final stored = storedRows.single;
      final createdRecipe = find.text('Colazione di Marco');
      await tester.scrollUntilVisible(
        createdRecipe,
        250,
        scrollable: find.descendant(
          of: find.byKey(const Key('recipes_list')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(createdRecipe, findsOneWidget);
      final ingredients = await (database.select(
        database.recipeIngredients,
      )..where((row) => row.recipeId.equals(stored.id))).get();
      expect(stored.servings, 2);
      expect(stored.prepMinutes, 10);
      expect(stored.totalCalories, closeTo(589.6, 0.0001));
      expect(ingredients, hasLength(2));
      expect(
        ingredients.every((ingredient) => ingredient.foodId == null),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      await tester.runAsync(database.close);
    },
  );
}
