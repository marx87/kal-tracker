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
