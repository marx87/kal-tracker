import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/app.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';

/// La barra in basso e i branch del router sono accoppiati solo per
/// posizione: questo test tocca OGNI voce per Key e verifica dove finisce,
/// così spostare una destinazione senza spostare il branch non passa in CI.
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

  testWidgets('ogni voce della barra apre la sua schermata', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.byType(NavigationDestination), findsNWidgets(5));

    const destinations = <String, String>{
      'nav_today': 'daily_calories',
      'nav_foods': 'food_search_field',
      'nav_recipes': 'recipe_search_field',
      'nav_plan': 'weekly_plan_list',
      'nav_progress': 'progress_list',
    };

    for (final entry in destinations.entries) {
      await tester.tap(find.byKey(Key(entry.key)));
      await tester.pumpAndSettle();
      expect(
        find.byKey(Key(entry.value)),
        findsOneWidget,
        reason: '${entry.key} deve aprire ${entry.value}',
      );
    }

    await _disposeApp(tester, database);
  });

  testWidgets('la lista della spesa resta dentro la shell', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav_plan')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('weekly_plan_shopping_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('shopping_list')), findsOneWidget);
    expect(find.byKey(const Key('main_navigation_bar')), findsOneWidget);

    // Ritoccare la voce già selezionata riporta il branch alla rotta
    // iniziale: la lista della spesa si chiude.
    await tester.tap(find.byKey(const Key('nav_plan')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('shopping_list')), findsNothing);
    expect(find.byKey(const Key('weekly_plan_list')), findsOneWidget);

    await _disposeApp(tester, database);
  });

  testWidgets('cinque voci stanno anche su uno schermo stretto', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byKey(const Key('main_navigation_bar')),
        matching: find.text('Piano'),
      ),
      findsOneWidget,
    );
    expect(find.byType(NavigationDestination), findsNWidgets(5));

    await tester.tap(find.byKey(const Key('nav_plan')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('weekly_plan_list')), findsOneWidget);

    await _disposeApp(tester, database);
  });
}

Future<void> _disposeApp(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(database.close);
}
