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

  testWidgets('catalogo e inserimento rapido aggiornano il diario reale', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('main_navigation_bar')), findsOneWidget);
    await tester.tap(find.byKey(const Key('nav_food')));
    await tester.pumpAndSettle();

    expect(find.text('Alimenti'), findsWidgets);
    expect(find.text('Banana'), findsOneWidget);
    await tester.tap(find.byKey(const Key('quick_add_seed-banana')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('food_name_field')))
          .controller
          ?.text,
      'Banana',
    );
    final save = find.byKey(const Key('save_food_button'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('nav_today')));
    await tester.pumpAndSettle();
    expect(find.text('Banana'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('daily_calories'))).data,
      '107 kcal',
    );
    await _disposeApp(tester, database);
  });

  testWidgets('obiettivi e acqua persistono e il ring usa il nuovo target', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav_body')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('body_open_progress_button')));
    await tester.pumpAndSettle();

    expect(find.text('2.000'), findsOneWidget);
    await tester.tap(find.byKey(const Key('add_water_250')));
    await tester.pumpAndSettle();
    expect(find.text('250 / 2000 ml'), findsOneWidget);

    await tester.tap(find.byKey(const Key('edit_targets_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('target_calories_field')),
      '2100',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    final save = find.byKey(const Key('save_targets_button'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    final addWeight = find.byKey(const Key('add_weight_button'));
    await tester.drag(
      find.byKey(const Key('progress_list')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    expect(addWeight, findsOneWidget);
    await tester.tap(addWeight);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('weight_field')), '80,5');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save_weight_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('weight_chart')), findsOneWidget);

    await tester.tap(find.byKey(const Key('nav_today')));
    await tester.pumpAndSettle();
    expect(find.text('su 2.100'), findsOneWidget);
    await _disposeApp(tester, database);
  });

  testWidgets('ricetta starter aggiunge una porzione al diario', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav_food')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('food_open_recipes_button')));
    await tester.pumpAndSettle();

    expect(find.text('Bowl pollo e riso'), findsOneWidget);
    await tester.tap(find.text('Bowl pollo e riso'));
    await tester.pumpAndSettle();
    expect(find.text('Dettaglio ricetta'), findsOneWidget);

    final addServing = find.byKey(const Key('add_recipe_serving_button'));
    await tester.scrollUntilVisible(addServing, 300);
    await tester.tap(addServing);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav_today')));
    await tester.pumpAndSettle();

    expect(find.text('Bowl pollo e riso · 1 porzione'), findsOneWidget);
    await _disposeApp(tester, database);
  });
}

Future<void> _disposeApp(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(database.close);
}
