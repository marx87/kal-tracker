import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/foods/data/catalog_seed_importer.dart';
import 'package:kal_tracker/features/foods/data/food_catalog_repository.dart';
import 'package:kal_tracker/features/foods/domain/food_models.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

Map<String, Object?> _item({
  required String id,
  required String name,
  String category = 'Primi piatti',
  List<String> aliases = const [],
  double kcal = 165,
  double protein = 6.5,
  double carbs = 21,
  double fat = 6,
  double portion = 350,
}) => {
  'id': id,
  'name': name,
  'aliases': aliases,
  'category': category,
  'kcalPer100g': kcal,
  'proteinPer100g': protein,
  'carbsPer100g': carbs,
  'fatPer100g': fat,
  'portionGrams': portion,
};

String _asset({int version = 1, required List<Map<String, Object?>> items}) =>
    jsonEncode({'version': version, 'items': items});

void main() {
  late AppDatabase database;
  late Directory stateDirectory;

  final baseItems = [
    _item(
      id: 'cat-pasta-al-ragu',
      name: 'Pasta al ragù',
      aliases: ['pasta alla bolognese', 'tagliatelle al ragù'],
      kcal: 150,
      protein: 7,
      carbs: 20,
      fat: 4.5,
    ),
    _item(
      id: 'cat-tiramisu',
      name: 'Tiramisù',
      category: 'Colazione, dolci e snack',
      aliases: ['tiramisu della nonna'],
      kcal: 290,
      protein: 5,
      carbs: 32,
      fat: 16,
      portion: 120,
    ),
  ];

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    stateDirectory = await Directory.systemTemp.createTemp('kal-catalog-test');
  });

  tearDown(() async {
    await database.close();
    await stateDirectory.delete(recursive: true);
  });

  CatalogSeedImporter importer(String Function() asset) => CatalogSeedImporter(
    database,
    loadAsset: () async => asset(),
    stateDirectory: () async => stateDirectory,
  );

  Future<List<CatalogFood>> catalogRows() => (database.select(
    database.foods,
  )..where((row) => row.source.equals(FoodSource.catalog))).get();

  test(
    'la prima esecuzione importa il catalogo senza righe di outbox',
    () async {
      final result = await importer(
        () => _asset(items: baseItems),
      ).importIfNeeded();

      expect(result.status, CatalogImportStatus.imported);
      expect(result.version, 1);
      expect(result.itemCount, 2);

      final rows = await catalogRows();
      expect(rows, hasLength(2));
      expect(rows.every((row) => row.ownerProfileId == null), isTrue);
      final ragu = rows.singleWhere((row) => row.id == 'cat-pasta-al-ragu');
      expect(ragu.name, 'Pasta al ragù');
      expect(ragu.caloriesPer100g, 150);
      expect(ragu.defaultServingGrams, 350);

      // Come i seed: niente outbox, quindi il push di sync non li vede mai.
      expect(await database.select(database.syncOutbox).get(), isEmpty);

      // Visibili nel catalogo insieme ai 12 seed.
      final profileId = (await LocalProfileRepository(
        database,
      ).getOrCreateMarco()).id;
      final all = await FoodCatalogRepository(
        database,
      ).watchCatalog(profileId: profileId).first;
      expect(all, hasLength(14));
    },
  );

  test(
    'la seconda esecuzione è un no-op grazie alla version importata',
    () async {
      final catalogImporter = importer(() => _asset(items: baseItems));
      await catalogImporter.importIfNeeded();

      // Se il no-op non funzionasse, questa riga tornerebbe alla seconda run.
      await (database.delete(
        database.foods,
      )..where((row) => row.id.equals('cat-tiramisu'))).go();

      final second = await catalogImporter.importIfNeeded();
      expect(second.status, CatalogImportStatus.upToDate);
      expect(second.version, 1);
      expect(await catalogRows(), hasLength(1));
    },
  );

  test(
    'il version bump aggiunge senza toccare catalogo e copie personali',
    () async {
      await importer(() => _asset(items: baseItems)).importIfNeeded();

      final profileId = (await LocalProfileRepository(
        database,
      ).getOrCreateMarco()).id;
      final repository = FoodCatalogRepository(database);
      final copyId = await repository.updateFood(
        profileId: profileId,
        foodId: 'cat-pasta-al-ragu',
        draft: const FoodDraft(
          name: 'Ragù di casa',
          per100g: Nutrients(calories: 140, protein: 8, carbs: 18, fat: 4),
          defaultServingGrams: 400,
        ),
      );

      final bumped = await importer(
        () => _asset(
          version: 2,
          items: [
            // Stesso id con valori diversi: NON deve sovrascrivere.
            _item(id: 'cat-pasta-al-ragu', name: 'Pasta al ragù', kcal: 999),
            ...baseItems.skip(1),
            _item(id: 'cat-lasagne', name: 'Lasagne alla bolognese', kcal: 180),
          ],
        ),
      ).importIfNeeded();

      expect(bumped.status, CatalogImportStatus.imported);
      expect(bumped.version, 2);

      final rows = await catalogRows();
      expect(rows.map((row) => row.id).toSet(), {
        'cat-pasta-al-ragu',
        'cat-tiramisu',
        'cat-lasagne',
      });
      expect(
        rows
            .singleWhere((row) => row.id == 'cat-pasta-al-ragu')
            .caloriesPer100g,
        150,
      );

      final copy = await repository.getFood(
        profileId: profileId,
        foodId: copyId,
      );
      expect(copy?.name, 'Ragù di casa');
      expect(copy?.source, FoodSource.custom);

      // In outbox c'è solo la copia personale, mai i piatti del catalogo.
      final outbox = await database.select(database.syncOutbox).get();
      expect(outbox.map((row) => row.entityId), [copyId]);
    },
  );

  test(
    'i piatti che duplicano i seed per nome non vengono importati',
    () async {
      final result = await importer(
        () => _asset(
          items: [
            ...baseItems,
            // Stesso nome del seed essenziale con valori divergenti: la riga
            // seed deve restare l'unica, senza doppioni in lista.
            _item(
              id: 'cat-banana',
              name: 'Banana',
              category: 'Frutta e frutta secca',
              kcal: 92,
              protein: 1.2,
              carbs: 22,
              fat: 0.3,
              portion: 120,
            ),
          ],
        ),
      ).importIfNeeded();

      expect(result.status, CatalogImportStatus.imported);
      expect(result.itemCount, 2);
      expect((await catalogRows()).map((row) => row.id).toSet(), {
        'cat-pasta-al-ragu',
        'cat-tiramisu',
      });

      // La ricerca trova una sola Banana: quella dei seed.
      final profileId = (await LocalProfileRepository(
        database,
      ).getOrCreateMarco()).id;
      final bananas = await FoodCatalogRepository(
        database,
      ).watchCatalog(profileId: profileId, query: 'banana').first;
      expect(bananas.single.id, 'seed-banana');
    },
  );

  test('un asset illeggibile non blocca: si ritenta al lancio dopo', () async {
    final failed = await importer(
      () => throw Exception('asset mancante'),
    ).importIfNeeded();
    expect(failed.status, CatalogImportStatus.failed);
    expect(await catalogRows(), isEmpty);

    final retried = await importer(
      () => _asset(items: baseItems),
    ).importIfNeeded();
    expect(retried.status, CatalogImportStatus.imported);
    expect(await catalogRows(), hasLength(2));
  });
}
