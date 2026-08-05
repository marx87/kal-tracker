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
      await tester.tap(find.byKey(const Key('nav_food')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('food_open_recipes_button')));
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

  testWidgets('modifica una ricetta esistente, toglie un ingrediente e '
      'aggiunge un tag', (tester) async {
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
    await tester.tap(find.byKey(const Key('nav_food')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('food_open_recipes_button')));
    await tester.pumpAndSettle();

    final stored = await (database.select(
      database.fitRecipes,
    )..where((row) => row.name.equals('Toast integrale con uova'))).getSingle();

    await tester.enterText(
      find.byKey(const Key('recipe_search_field')),
      'toast',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();

    final card = find.byKey(Key('recipe_card_${stored.id}'));
    await tester.scrollUntilVisible(
      card,
      250,
      scrollable: find.descendant(
        of: find.byKey(const Key('recipes_list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(card);
    await tester.pumpAndSettle();

    final edit = find.byKey(const Key('edit_recipe_button'));
    await tester.ensureVisible(edit);
    await tester.tap(edit);
    await tester.pumpAndSettle();

    expect(find.text('Modifica ricetta'), findsOneWidget);
    expect(find.text('Toast integrale con uova'), findsOneWidget);
    expect(find.byKey(const Key('recipe_tag_chip_colazione')), findsOneWidget);

    final removeOil = find.byTooltip('Rimuovi Olio extravergine di oliva');
    await tester.ensureVisible(removeOil);
    await tester.tap(removeOil);
    await tester.pumpAndSettle();

    final tagField = find.byKey(const Key('recipe_tags_field'));
    await tester.ensureVisible(tagField);
    await tester.enterText(tagField, 'Proteico');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recipe_tag_chip_proteico')), findsOneWidget);

    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    final save = find.byKey(const Key('save_recipe_button'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    final updated = await (database.select(
      database.fitRecipes,
    )..where((row) => row.id.equals(stored.id))).getSingle();
    final ingredients = await (database.select(
      database.recipeIngredients,
    )..where((row) => row.recipeId.equals(stored.id))).get();

    expect(updated.name, 'Toast integrale con uova');
    expect(updated.tags, 'colazione,veloce,proteico');
    expect(updated.totalCalories, closeTo(639.6, 0.0001));
    expect(ingredients, hasLength(2));
    expect(ingredients.map((row) => row.position).toList()..sort(), [0, 1]);
    expect(
      ingredients.any((row) => row.name == 'Olio extravergine di oliva'),
      isFalse,
    );
    expect(find.text('Ricetta aggiornata.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(database.close);
  });
}
