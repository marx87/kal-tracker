import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/app.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/data/diary_repository.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/recipes/data/recipe_catalog_importer.dart';
import 'package:kal_tracker/features/recipes/data/recipe_repository.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_catalog_asset.dart';
import 'package:kal_tracker/features/targets/data/target_repository.dart';
import 'package:kal_tracker/features/targets/domain/nutrition_target.dart';

Finder get _recipesScrollable => find.descendant(
  of: find.byKey(const Key('recipes_list')),
  matching: find.byType(Scrollable),
);

Future<void> _openRecipes(WidgetTester tester, AppDatabase database) async {
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
}

Future<Map<String, String>> _recipeIds(AppDatabase database) async {
  final rows = await database.select(database.fitRecipes).get();
  return {for (final row in rows) row.name: row.id};
}

Future<void> _search(WidgetTester tester, String value) async {
  await tester.enterText(find.byKey(const Key('recipe_search_field')), value);
  tester.testTextInput.hide();
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
}

Future<void> _disposeApp(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(database.close);
}

void main() {
  late AppDatabase database;

  setUp(() {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
  });

  testWidgets('la ricerca trova per ingrediente e i filtri restringono la '
      'lista', (tester) async {
    await _openRecipes(tester, database);
    final ids = await _recipeIds(database);

    await _search(tester, 'salmone');
    final salmone = find.byKey(
      Key('recipe_card_${ids['Riso con salmone e broccoli']}'),
    );
    await tester.scrollUntilVisible(
      salmone,
      250,
      scrollable: _recipesScrollable,
    );
    expect(salmone, findsOneWidget);
    expect(find.byIcon(Icons.ramen_dining_rounded), findsOneWidget);
    expect(find.text('Risultati'), findsOneWidget);

    await _search(tester, '');
    await tester.tap(find.byKey(const Key('recipes_only_favorites_chip')));
    await tester.pumpAndSettle();
    final bowl = find.byKey(Key('recipe_card_${ids['Bowl pollo e riso']}'));
    await tester.scrollUntilVisible(bowl, 250, scrollable: _recipesScrollable);
    expect(bowl, findsOneWidget);
    expect(find.byIcon(Icons.ramen_dining_rounded), findsOneWidget);

    await tester.tap(find.byKey(const Key('recipes_only_favorites_chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('recipe_tag_filter_colazione')));
    await tester.pumpAndSettle();
    final toast = find.byKey(
      Key('recipe_card_${ids['Toast integrale con uova']}'),
    );
    await tester.scrollUntilVisible(toast, 250, scrollable: _recipesScrollable);
    expect(toast, findsOneWidget);
    expect(find.byIcon(Icons.ramen_dining_rounded), findsNWidgets(2));

    await _disposeApp(tester, database);
  });

  testWidgets('senza risultati mostra il vuoto e il pulsante azzera i filtri', (
    tester,
  ) async {
    await _openRecipes(tester, database);
    final ids = await _recipeIds(database);

    await _search(tester, 'zuppa di sasso');
    expect(find.text('Nessuna ricetta con questi filtri.'), findsOneWidget);
    expect(find.byIcon(Icons.ramen_dining_rounded), findsNothing);

    final reset = find.byKey(const Key('reset_recipe_filters_button'));
    await tester.ensureVisible(reset);
    await tester.pumpAndSettle();
    await tester.tap(reset);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(find.text('Nessuna ricetta con questi filtri.'), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('recipe_search_field')))
          .controller
          ?.text,
      isEmpty,
    );
    final bowl = find.byKey(Key('recipe_card_${ids['Bowl pollo e riso']}'));
    await tester.scrollUntilVisible(bowl, 250, scrollable: _recipesScrollable);
    expect(bowl, findsOneWidget);

    await _disposeApp(tester, database);
  });

  testWidgets('con il ricettario completo lista, ricerca e tag restano '
      'corretti', (tester) async {
    // Stesso percorso dell'importer al primo avvio: il ricettario intero
    // installato in blocco prima di aprire la schermata.
    final profile = await LocalProfileRepository(database).getOrCreateMarco();
    final asset = RecipeCatalogAsset.fromJsonString(
      File('assets/catalog/ricettario_fit_v1.json').readAsStringSync(),
    );
    await RecipeRepository(database).installMissingRecipes(
      profileId: profile.id,
      entries: [
        for (final entry in asset.recipes)
          (id: RecipeCatalogImporter.recipeId(entry.slug), draft: entry.draft),
      ],
    );

    await _openRecipes(tester, database);
    final ids = await _recipeIds(database);

    // 152 del ricettario + 6 starter, nessun doppione di nome o id.
    expect(ids, hasLength(asset.recipes.length + 6));

    // Il vocabolario controllato dei tag resta piccolo: un chip per tag,
    // più «Solo preferite» e «Tutti i filtri», anche col ricettario pieno.
    expect(find.byType(FilterChip), findsNWidgets(12));
    expect(find.byKey(const Key('recipe_filters_toggle')), findsOneWidget);
    expect(
      find.byKey(const Key('recipe_tag_filter_meal prep')),
      findsOneWidget,
    );

    // La ricerca resta puntuale su 158 ricette.
    await _search(tester, 'teriyaki di pollo');
    final teriyaki = find.byKey(
      Key('recipe_card_${ids['Bowl teriyaki di pollo e broccoli']}'),
    );
    await tester.scrollUntilVisible(
      teriyaki,
      250,
      scrollable: _recipesScrollable,
    );
    expect(teriyaki, findsOneWidget);
    expect(find.byIcon(Icons.ramen_dining_rounded), findsOneWidget);

    // Il filtro tag è un match esatto e la lista lunga resta scorribile.
    await _search(tester, '');
    await tester.tap(find.byKey(const Key('recipe_tag_filter_dolce')));
    await tester.pumpAndSettle();
    final torta = find.byKey(
      Key('recipe_card_${ids['Torta proteica al cacao']}'),
    );
    await tester.scrollUntilVisible(
      torta,
      400,
      maxScrolls: 200,
      scrollable: _recipesScrollable,
    );
    expect(torta, findsOneWidget);

    await _disposeApp(tester, database);
  });

  testWidgets('i suggerimenti usano i macro rimasti nella giornata', (
    tester,
  ) async {
    final profile = await LocalProfileRepository(database).getOrCreateMarco();
    await TargetRepository(database).upsertTarget(
      profileId: profile.id,
      target: const NutritionTarget(
        calories: 900,
        protein: 60,
        carbs: 40,
        fat: 15,
      ),
    );
    await DiaryRepository(database).addManualFood(
      profileId: profile.id,
      input: ManualFoodInput(
        foodName: 'Pranzo di prova',
        grams: 100,
        per100g: const Nutrients(calories: 500, protein: 20, carbs: 0, fat: 0),
        mealType: MealType.lunch,
        eatenAt: AppTime.nowInRome(),
      ),
    );

    await _openRecipes(tester, database);
    final ids = await _recipeIds(database);

    expect(find.text('Adatte a quello che ti resta oggi'), findsOneWidget);
    expect(
      find.text('Ti restano 400 kcal e 40 g di proteine.'),
      findsOneWidget,
    );

    for (final name in const [
      'Overnight oats banana',
      'Toast integrale con uova',
      'Coppa yogurt, mela e mandorle',
    ]) {
      final suggestion = find.byKey(Key('recipe_suggestion_${ids[name]}'));
      await tester.scrollUntilVisible(
        suggestion,
        250,
        scrollable: _recipesScrollable,
      );
      expect(suggestion, findsOneWidget, reason: name);
    }
    expect(
      find.byKey(Key('recipe_suggestion_${ids['Bowl pollo e riso']}')),
      findsNothing,
    );

    await _disposeApp(tester, database);
  });
}
