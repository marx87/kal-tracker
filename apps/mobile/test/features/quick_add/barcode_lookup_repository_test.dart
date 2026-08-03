import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/foods/data/food_catalog_repository.dart';
import 'package:kal_tracker/features/foods/domain/food_models.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/quick_add/barcode_lookup_repository.dart';

import 'off_test_support.dart';

void main() {
  late AppDatabase database;
  late String profileId;
  late FoodCatalogRepository catalog;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
    catalog = FoodCatalogRepository(database);
  });

  tearDown(() => database.close());

  BarcodeLookupRepository repository(FakeOffAdapter adapter) =>
      BarcodeLookupRepository(catalog: catalog, dio: offDio(adapter));

  FakeOffAdapter neverCalledAdapter() => FakeOffAdapter(
    (options) => fail('Open Food Facts non doveva essere chiamato.'),
  );

  const draft = FoodDraft(
    name: 'Fette biscottate',
    brand: 'Mulino Bianco',
    barcode: '8001120000000',
    per100g: Nutrients(calories: 408, protein: 11, carbs: 72, fat: 6),
    defaultServingGrams: 30,
  );

  test('trova prima nel DB locale senza chiamare Open Food Facts', () async {
    await catalog.createFood(profileId: profileId, draft: draft);
    final adapter = neverCalledAdapter();

    final result = await repository(
      adapter,
    ).lookup(profileId: profileId, barcode: '8001120000000');

    expect(result, isA<BarcodeFoodMatch>());
    final food = (result as BarcodeFoodMatch).food;
    expect(food.name, 'Fette biscottate');
    expect(food.barcode, '8001120000000');
    expect(adapter.calls, 0);
  });

  test('interroga OFF quando il barcode non è locale e ne estrae '
      'nome, marca e per-100 g', () async {
    final adapter = FakeOffAdapter((options) {
      expect(options.uri.path, '/api/v2/product/3017620422003');
      expect(
        options.uri.queryParameters['fields'],
        'product_name,product_name_it,brands,nutriments',
      );
      return offJsonResponse(offNutellaJson);
    });

    final result = await repository(
      adapter,
    ).lookup(profileId: profileId, barcode: '3017620422003');

    expect(result, isA<BarcodeProductProposal>());
    final product = (result as BarcodeProductProposal).product;
    expect(product.barcode, '3017620422003');
    expect(product.name, 'Nutella crema alle nocciole');
    expect(product.brand, 'Ferrero');
    expect(product.caloriesPer100g, 539);
    // Le proteine arrivano come stringa: parsing tollerante.
    expect(product.proteinPer100g, 6.3);
    expect(product.carbsPer100g, 57.5);
    expect(product.fatPer100g, 30.9);
    expect(product.hasCompleteNutrition, isTrue);
    expect(adapter.calls, 1);
  });

  test('senza kcal dichiarate converte i kJ (1 kcal = 4,184 kJ)', () async {
    final adapter = FakeOffAdapter(
      (options) => offJsonResponse(offOnlyKilojoulesJson),
    );

    final result = await repository(
      adapter,
    ).lookup(profileId: profileId, barcode: '8076809513692');

    final product = (result as BarcodeProductProposal).product;
    expect(product.caloriesPer100g, 250);
    expect(product.name, 'Pesto alla genovese');
  });

  test('prodotto sconosciuto a OFF (404, status 0)', () async {
    final adapter = FakeOffAdapter(
      (options) => offJsonResponse(offNotFoundJson, status: 404),
    );

    final result = await repository(
      adapter,
    ).lookup(profileId: profileId, barcode: '4000000000000');

    expect(result, isA<BarcodeUnknownProduct>());
    expect((result as BarcodeUnknownProduct).barcode, '4000000000000');
  });

  test('offline: l’errore di rete diventa BarcodeLookupOffline', () async {
    final adapter = FakeOffAdapter((options) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'niente rete',
      );
    });

    final result = await repository(
      adapter,
    ).lookup(profileId: profileId, barcode: '3017620422003');

    expect(result, isA<BarcodeLookupOffline>());
    expect((result as BarcodeLookupOffline).barcode, '3017620422003');
  });

  test('un codice non numerico non parte nemmeno', () async {
    final adapter = neverCalledAdapter();

    await expectLater(
      repository(
        adapter,
      ).lookup(profileId: profileId, barcode: 'non-un-barcode'),
      throwsFormatException,
    );
    expect(adapter.calls, 0);
  });

  test('il salvataggio crea la riga con source barcode e il secondo '
      'scan resta offline', () async {
    final adapter = FakeOffAdapter(
      (options) => offJsonResponse(offNutellaJson),
    );
    final repo = repository(adapter);

    final first = await repo.lookup(
      profileId: profileId,
      barcode: '3017620422003',
    );
    final product = (first as BarcodeProductProposal).product;

    final food = await repo.saveScannedFood(
      profileId: profileId,
      draft: FoodDraft(
        name: product.name!,
        brand: product.brand,
        barcode: product.barcode,
        per100g: product.per100g!,
        defaultServingGrams: 15,
      ),
    );
    expect(food.barcode, '3017620422003');
    expect(food.source, barcodeFoodSource);
    expect(food.per100g.calories, 539);

    final stored = await (database.select(
      database.foods,
    )..where((row) => row.id.equals(food.id))).getSingle();
    expect(stored.source, 'barcode');
    expect(stored.barcode, '3017620422003');
    expect(stored.ownerProfileId, profileId);

    // L'outbox porta l'upsert col barcode: la sync lo replica com'è.
    final outbox = await database.select(database.syncOutbox).get();
    final upsert = outbox.last;
    expect(upsert.entityType, 'food');
    expect(upsert.operation, 'upsert');
    expect(
      (jsonDecode(upsert.payloadJson) as Map<String, Object?>)['barcode'],
      '3017620422003',
    );

    // Secondo scan: match locale, nessuna nuova chiamata a OFF.
    final second = await repo.lookup(
      profileId: profileId,
      barcode: '3017620422003',
    );
    expect(second, isA<BarcodeFoodMatch>());
    expect((second as BarcodeFoodMatch).food.id, food.id);
    expect(adapter.calls, 1);
  });

  test('la scansione di un alimento eliminato non lo riesuma: ne ripropone '
      'i valori e il tombstone torna vivo solo alla conferma', () async {
    final id = await catalog.createFood(profileId: profileId, draft: draft);
    await catalog.deleteFood(profileId: profileId, foodId: id);
    final adapter = neverCalledAdapter();
    final repo = repository(adapter);

    final result = await repo.lookup(
      profileId: profileId,
      barcode: '8001120000000',
    );

    // Proposta locale coi valori di prima, sempre senza chiamare OFF…
    expect(result, isA<BarcodeProductProposal>());
    final product = (result as BarcodeProductProposal).product;
    expect(product.barcode, '8001120000000');
    expect(product.name, 'Fette biscottate');
    expect(product.caloriesPer100g, 408);
    expect(adapter.calls, 0);

    // …ma la sola scansione non riporta in vita niente: chi chiude lo
    // sheet senza salvare non si ritrova l'alimento risorto né in outbox.
    var stored = await (database.select(
      database.foods,
    )..where((row) => row.id.equals(id))).getSingle();
    expect(stored.deletedAt, isNotNull);
    Future<List<String>> outboxOperations() async =>
        (await database.select(database.syncOutbox).get())
            .where((row) => row.entityType == 'food' && row.entityId == id)
            .map((row) => row.operation)
            .toList();
    expect(await outboxOperations(), ['upsert', 'delete']);

    // Alla conferma la stessa riga torna viva (niente insert doppio che
    // romperebbe il vincolo UNIQUE sul barcode).
    final food = await repo.saveScannedFood(profileId: profileId, draft: draft);
    expect(food.id, id);
    stored = await (database.select(
      database.foods,
    )..where((row) => row.id.equals(id))).getSingle();
    expect(stored.deletedAt, isNull);

    // Storia in outbox: nascita, eliminazione, riesumazione confermata.
    expect(await outboxOperations(), ['upsert', 'delete', 'upsert']);
  });
}
