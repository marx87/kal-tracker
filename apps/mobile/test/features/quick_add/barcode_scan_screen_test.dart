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
import 'package:kal_tracker/features/quick_add/barcode_lookup_repository.dart';
import 'package:kal_tracker/features/quick_add/barcode_scan_screen.dart';

import 'off_test_support.dart';

Widget _app(
  AppDatabase database, {
  required String scannedBarcode,
  required FakeOffAdapter adapter,
}) => ProviderScope(
  overrides: [
    databaseProvider.overrideWithValue(database),
    appConfigProvider.overrideWithValue(const AppConfig.offline()),
    // Mai il plugin reale nei test: la vista finta emette il codice al tap.
    barcodeScannerViewBuilderProvider.overrideWithValue(
      (context, onBarcode) => Center(
        child: TextButton(
          key: const Key('fake_scan_button'),
          onPressed: () => onBarcode(scannedBarcode),
          child: const Text('Scan!'),
        ),
      ),
    ),
    openFoodFactsDioProvider.overrideWithValue(offDio(adapter)),
  ],
  child: const KalTrackerApp(),
);

Future<void> _disposeApp(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(database.close);
}

Future<void> _openScannerAndScan(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('add_food_button')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('quick_add_barcode')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('barcode_scan_screen')), findsOneWidget);
  await tester.tap(find.byKey(const Key('fake_scan_button')));
  await tester.pumpAndSettle();
}

String _fieldText(WidgetTester tester, Key key) => tester
    .widget<EditableText>(
      find
          .descendant(of: find.byKey(key), matching: find.byType(EditableText))
          .first,
    )
    .controller
    .text;

void main() {
  testWidgets('un barcode già in catalogo apre subito il diario '
      'precompilato, senza rete', (tester) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final profileId = (await LocalProfileRepository(
      database,
    ).getOrCreateMarco()).id;
    await FoodCatalogRepository(database).createFood(
      profileId: profileId,
      draft: const FoodDraft(
        name: 'Fette biscottate',
        barcode: '8001120000000',
        per100g: Nutrients(calories: 408, protein: 11, carbs: 72, fat: 6),
        defaultServingGrams: 30,
      ),
    );
    final adapter = FakeOffAdapter(
      (options) => fail('Open Food Facts non doveva essere chiamato.'),
    );

    await tester.pumpWidget(
      _app(database, scannedBarcode: '8001120000000', adapter: adapter),
    );
    await tester.pumpAndSettle();

    await _openScannerAndScan(tester);

    // Sheet del diario precompilato con la porzione onesta dell'alimento.
    expect(
      _fieldText(tester, const Key('food_name_field')),
      'Fette biscottate',
    );
    expect(_fieldText(tester, const Key('grams_field')), '30');
    expect(_fieldText(tester, const Key('calories_field')), '408');

    final saveButton = find.byKey(const Key('save_food_button'));
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    // Lo scanner si chiude e la voce è nel diario del giorno selezionato.
    expect(find.byKey(const Key('barcode_scan_screen')), findsNothing);
    expect(find.text('Fette biscottate'), findsOneWidget);
    expect(
      find.text('Fette biscottate aggiunto al diario di oggi.'),
      findsOneWidget,
    );
    expect(adapter.calls, 0);

    await _disposeApp(tester, database);
  });

  testWidgets('un prodotto Open Food Facts passa dalla scheda di conferma '
      'e nasce come alimento barcode', (tester) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final adapter = FakeOffAdapter(
      (options) => offJsonResponse(offNutellaJson),
    );

    await tester.pumpWidget(
      _app(database, scannedBarcode: '3017620422003', adapter: adapter),
    );
    await tester.pumpAndSettle();

    await _openScannerAndScan(tester);

    // Scheda di conferma precompilata coi valori OFF, modificabili.
    expect(find.text('Codice 3017620422003'), findsOneWidget);
    expect(
      _fieldText(tester, const Key('barcode_food_name_field')),
      'Nutella crema alle nocciole',
    );
    expect(
      _fieldText(tester, const Key('barcode_food_brand_field')),
      'Ferrero',
    );
    expect(_fieldText(tester, const Key('barcode_food_calories_field')), '539');
    await tester.enterText(
      find.byKey(const Key('barcode_food_serving_field')),
      '15',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();

    final confirmButton = find.byKey(const Key('barcode_food_save_button'));
    await tester.ensureVisible(confirmButton);
    await tester.tap(confirmButton);
    await tester.pumpAndSettle();

    // Poi l'inserimento nel diario, precompilato con la porzione scelta.
    expect(
      _fieldText(tester, const Key('food_name_field')),
      'Nutella crema alle nocciole',
    );
    expect(_fieldText(tester, const Key('grams_field')), '15');

    final saveButton = find.byKey(const Key('save_food_button'));
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('barcode_scan_screen')), findsNothing);
    expect(find.text('Nutella crema alle nocciole'), findsOneWidget);
    expect(adapter.calls, 1);

    // La riga locale c'è, con barcode e source 'barcode': la prossima
    // scansione non tocca la rete.
    final stored = await (database.select(
      database.foods,
    )..where((row) => row.barcode.equals('3017620422003'))).getSingle();
    expect(stored.source, 'barcode');
    expect(stored.name, 'Nutella crema alle nocciole');
    expect(stored.deletedAt, isNull);

    await _disposeApp(tester, database);
  });

  testWidgets('prodotto sconosciuto: editor precompilato col barcode '
      'e messaggio gentile', (tester) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final adapter = FakeOffAdapter(
      (options) => offJsonResponse(offNotFoundJson, status: 404),
    );

    await tester.pumpWidget(
      _app(database, scannedBarcode: '4000000000000', adapter: adapter),
    );
    await tester.pumpAndSettle();

    await _openScannerAndScan(tester);

    expect(find.byKey(const Key('barcode_lookup_message')), findsOneWidget);
    expect(
      find.textContaining('Open Food Facts non conosce questo codice'),
      findsOneWidget,
    );
    expect(find.text('Codice 4000000000000'), findsOneWidget);
    expect(_fieldText(tester, const Key('barcode_food_name_field')), isEmpty);

    // Marco compila dall'etichetta: nasce comunque l'alimento barcode.
    await tester.enterText(
      find.byKey(const Key('barcode_food_name_field')),
      'Cracker di segale',
    );
    await tester.enterText(
      find.byKey(const Key('barcode_food_calories_field')),
      '380',
    );
    await tester.enterText(
      find.byKey(const Key('barcode_food_protein_field')),
      '10',
    );
    await tester.enterText(
      find.byKey(const Key('barcode_food_carbs_field')),
      '70',
    );
    await tester.enterText(
      find.byKey(const Key('barcode_food_fat_field')),
      '5',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();

    final confirmButton = find.byKey(const Key('barcode_food_save_button'));
    await tester.ensureVisible(confirmButton);
    await tester.tap(confirmButton);
    await tester.pumpAndSettle();

    final saveButton = find.byKey(const Key('save_food_button'));
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    expect(find.text('Cracker di segale'), findsOneWidget);
    final stored = await (database.select(
      database.foods,
    )..where((row) => row.barcode.equals('4000000000000'))).getSingle();
    expect(stored.source, 'barcode');

    await _disposeApp(tester, database);
  });

  testWidgets('offline: si prosegue a mano col barcode già valorizzato', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final adapter = FakeOffAdapter((options) {
      throw StateError('niente rete');
    });

    await tester.pumpWidget(
      _app(database, scannedBarcode: '5000159484695', adapter: adapter),
    );
    await tester.pumpAndSettle();

    await _openScannerAndScan(tester);

    expect(find.byKey(const Key('barcode_lookup_message')), findsOneWidget);
    expect(find.textContaining('Ora sei offline'), findsOneWidget);
    expect(find.text('Codice 5000159484695'), findsOneWidget);

    await _disposeApp(tester, database);
  });
}
