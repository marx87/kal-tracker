import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/app.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/quick_add/barcode_scan_screen.dart';

Widget _app(AppDatabase database, {List<Override> overrides = const []}) =>
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        appConfigProvider.overrideWithValue(const AppConfig.offline()),
        ...overrides,
      ],
      child: const KalTrackerApp(),
    );

Future<void> _disposeApp(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(database.close);
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('add_food_button')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('il FAB apre il menu smart con le quattro azioni', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());

    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    await _openMenu(tester);

    expect(find.byKey(const Key('quick_add_manual')), findsOneWidget);
    expect(find.byKey(const Key('quick_add_catalog')), findsOneWidget);
    expect(find.byKey(const Key('quick_add_photo')), findsOneWidget);
    expect(find.byKey(const Key('quick_add_barcode')), findsOneWidget);

    await _disposeApp(tester, database);
  });

  testWidgets('la voce manuale apre lo sheet di sempre e salva nel diario', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());

    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    await _openMenu(tester);
    await tester.tap(find.byKey(const Key('quick_add_manual')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('food_name_field')),
      'Riso basmati',
    );
    await tester.enterText(find.byKey(const Key('grams_field')), '150');
    await tester.enterText(find.byKey(const Key('calories_field')), '130');
    await tester.enterText(find.byKey(const Key('protein_field')), '2,7');
    await tester.enterText(find.byKey(const Key('carbs_field')), '28');
    await tester.enterText(find.byKey(const Key('fat_field')), '0,3');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();

    final saveButton = find.byKey(const Key('save_food_button'));
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    expect(find.text('Riso basmati'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('daily_calories'))).data,
      '195 kcal',
    );

    await _disposeApp(tester, database);
  });

  testWidgets('la voce catalogo porta alla schermata Alimenti', (tester) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());

    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    await _openMenu(tester);
    await tester.tap(find.byKey(const Key('quick_add_catalog')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('food_search_field')), findsOneWidget);

    // Il ritorno rapido al diario: la tab «Oggi» è sempre lì.
    await tester.tap(find.byKey(const Key('nav_today')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('add_food_button')), findsOneWidget);

    await _disposeApp(tester, database);
  });

  testWidgets('la voce foto senza cloud configurato avvisa senza crash', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());

    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    await _openMenu(tester);
    await tester.tap(find.byKey(const Key('quick_add_photo')));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'La foto del pasto non è attiva su questa installazione: puoi '
        'aggiungere a mano, dal catalogo o col codice a barre.',
      ),
      findsOneWidget,
    );

    await _disposeApp(tester, database);
  });

  testWidgets('la voce barcode apre lo scanner sulla rotta barcode-scan', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());

    await tester.pumpWidget(
      _app(
        database,
        overrides: [
          // Mai il plugin reale nei test: i platform channel non esistono.
          barcodeScannerViewBuilderProvider.overrideWithValue(
            (context, onBarcode) =>
                const Placeholder(key: Key('fake_scanner_view')),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await _openMenu(tester);
    await tester.tap(find.byKey(const Key('quick_add_barcode')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('barcode_scan_screen')), findsOneWidget);
    expect(find.byKey(const Key('fake_scanner_view')), findsOneWidget);

    await _disposeApp(tester, database);
  });
}
