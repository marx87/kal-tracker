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
