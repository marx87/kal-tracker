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
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/recipes/data/recipe_repository.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';

void main() {
  testWidgets('duplica una ricetta dal dettaglio e la copia entra nel '
      'ricettario', (tester) async {
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

    final source =
        await (database.select(
              database.fitRecipes,
            )..where((row) => row.name.equals('Coppa yogurt, mela e mandorle')))
            .getSingle();

    await tester.enterText(
      find.byKey(const Key('recipe_search_field')),
      'coppa',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    final card = find.byKey(Key('recipe_card_${source.id}'));
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

    expect(find.byKey(const Key('recipe_detail_tag_spuntino')), findsOneWidget);
    final duplicate = find.byKey(const Key('duplicate_recipe_button'));
    await tester.ensureVisible(duplicate);
    await tester.pumpAndSettle();
    await tester.tap(duplicate);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(
      find.text('Ho creato una copia nel tuo ricettario.'),
      findsOneWidget,
    );

    final copy =
        await (database.select(database.fitRecipes)..where(
              (row) => row.name.equals('Coppa yogurt, mela e mandorle (copia)'),
            ))
            .getSingle();
    final copyIngredients = await (database.select(
      database.recipeIngredients,
    )..where((row) => row.recipeId.equals(copy.id))).get();

    expect(copy.id, isNot(source.id));
    expect(copy.isFavorite, isFalse);
    expect(copy.tags, source.tags);
    expect(copy.totalCalories, closeTo(source.totalCalories, 0.0001));
    expect(copyIngredients, hasLength(3));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(database.close);
  });

  testWidgets('aggiunge 1,5 porzioni al diario con i totali esatti', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final profile = await LocalProfileRepository(database).getOrCreateMarco();
    final recipeId = await RecipeRepository(database).createRecipe(
      profileId: profile.id,
      draft: const FitRecipeDraft(
        name: 'Zuppa di prova porzioni',
        servings: 2,
        ingredients: [
          RecipeIngredientDraft(
            name: 'Legumi misti',
            grams: 400,
            per100g: Nutrients(calories: 100, protein: 10, carbs: 20, fat: 5),
          ),
        ],
      ),
    );

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

    await tester.enterText(
      find.byKey(const Key('recipe_search_field')),
      'zuppa',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('recipe_card_$recipeId')));
    await tester.pumpAndSettle();

    final detailScrollable = find.descendant(
      of: find.byKey(const Key('recipe_detail_list')),
      matching: find.byType(Scrollable),
    );
    final option = find.byKey(const Key('serving_option_1_5'));
    await tester.scrollUntilVisible(option, 250, scrollable: detailScrollable);
    await tester.pumpAndSettle();
    await tester.tap(option);
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('recipe_add_preview'))).data,
      '1,5 porzioni · 300 kcal · P 30.0 · C 60.0 · G 15.0',
    );

    final addButton = find.byKey(const Key('add_recipe_serving_button'));
    await tester.scrollUntilVisible(
      addButton,
      250,
      scrollable: detailScrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(addButton);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(
      find.text('1,5 porzioni aggiunte al diario di oggi.'),
      findsOneWidget,
    );

    final item =
        await (database.select(database.mealItems)..where(
              (row) =>
                  row.foodName.equals('Zuppa di prova porzioni · 1,5 porzioni'),
            ))
            .getSingle();
    expect(item.grams, closeTo(300, 0.000001));
    expect(item.totalCalories, closeTo(300, 0.000001));
    expect(item.totalProtein, closeTo(30, 0.000001));
    expect(item.totalCarbs, closeTo(60, 0.000001));
    expect(item.totalFat, closeTo(15, 0.000001));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(database.close);
  });

  testWidgets('elimina una ricetta dal dettaglio dopo la conferma', (
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
    await tester.tap(find.byKey(const Key('nav_recipes')));
    await tester.pumpAndSettle();

    final source = await (database.select(
      database.fitRecipes,
    )..where((row) => row.name.equals('Toast integrale con uova'))).getSingle();

    await tester.enterText(
      find.byKey(const Key('recipe_search_field')),
      'toast',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('recipe_card_${source.id}')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('delete_recipe_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('delete_recipe_dialog')), findsOneWidget);

    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle();
    expect(find.text('Dettaglio ricetta'), findsOneWidget);

    await tester.tap(find.byKey(const Key('delete_recipe_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm_delete_recipe')));
    await tester.pumpAndSettle();

    expect(find.text('Dettaglio ricetta'), findsNothing);
    expect(find.text('Toast integrale con uova eliminata.'), findsOneWidget);
    final deleted = await (database.select(
      database.fitRecipes,
    )..where((row) => row.id.equals(source.id))).getSingle();
    expect(deleted.deletedAt, isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(database.close);
  });
}
