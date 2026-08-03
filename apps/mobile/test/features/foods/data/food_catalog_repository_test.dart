import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/foods/data/food_catalog_repository.dart';
import 'package:kal_tracker/features/foods/domain/food_models.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

void main() {
  late AppDatabase database;
  late FoodCatalogRepository repository;
  late String profileId;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
    repository = FoodCatalogRepository(database);
  });

  tearDown(() => database.close());

  test('crea il seed essenziale e permette la ricerca', () async {
    final all = await repository.watchCatalog(profileId: profileId).first;
    final chicken = await repository
        .watchCatalog(profileId: profileId, query: 'POLLO')
        .first;

    expect(all, hasLength(12));
    expect(all.every((food) => food.source == 'seed'), isTrue);
    expect(chicken.single.name, 'Petto di pollo');
    expect(chicken.single.per100g.protein, 31);
  });

  test('preferiti e recenti restano associati al profilo', () async {
    await repository.setFavorite(
      profileId: profileId,
      foodId: 'seed-banana',
      isFavorite: true,
    );
    await repository.markUsed(
      profileId: profileId,
      foodId: 'seed-banana',
      usedAt: DateTime.utc(2026, 8, 2, 10),
    );
    await repository.markUsed(
      profileId: profileId,
      foodId: 'seed-apple',
      usedAt: DateTime.utc(2026, 8, 2, 11),
    );

    final favorites = await repository
        .watchFavorites(profileId: profileId)
        .first;
    final recent = await repository.watchRecent(profileId: profileId).first;
    expect(favorites.single.id, 'seed-banana');
    expect(favorites.single.useCount, 1);
    expect(recent.map((food) => food.id), ['seed-apple', 'seed-banana']);

    final now = AppTime.nowUtc();
    await database
        .into(database.appProfiles)
        .insert(
          AppProfilesCompanion.insert(
            id: 'second-profile',
            displayName: 'Secondo',
            createdAt: now,
            updatedAt: now,
          ),
        );
    expect(
      await repository.watchFavorites(profileId: 'second-profile').first,
      isEmpty,
    );
  });

  test('crea e cancella un alimento personalizzato con tombstone', () async {
    final id = await repository.createCustomFood(
      profileId: profileId,
      draft: const FoodDraft(
        name: ' Pancake proteico ',
        brand: 'Casa',
        per100g: Nutrients(calories: 190, protein: 18, carbs: 20, fat: 4),
        defaultServingGrams: 120,
      ),
    );
    final created = await repository.getFood(profileId: profileId, foodId: id);
    expect(created?.name, 'Pancake proteico');
    expect(created?.defaultServingGrams, 120);

    await repository.deleteCustomFood(profileId: profileId, foodId: id);
    await repository.deleteCustomFood(profileId: profileId, foodId: id);
    expect(await repository.getFood(profileId: profileId, foodId: id), isNull);
    final stored = await (database.select(
      database.foods,
    )..where((row) => row.id.equals(id))).getSingle();
    expect(stored.deletedAt, isNotNull);

    final operations = (await database.select(database.syncOutbox).get())
        .where((row) => row.entityId == id)
        .map((row) => row.operation);
    expect(operations, ['upsert', 'delete']);
  });

  test('crea un alimento personale e lo mostra fra i miei', () async {
    final id = await repository.createFood(
      profileId: profileId,
      draft: const FoodDraft(
        name: ' Skyr Milbona ',
        brand: 'Lidl',
        barcode: '4056489123456',
        per100g: Nutrients(calories: 63, protein: 11, carbs: 4, fat: 0.2),
        defaultServingGrams: 150,
      ),
    );

    final mine = await repository.watchMine(profileId: profileId).first;
    expect(mine.single.id, id);
    expect(mine.single.name, 'Skyr Milbona');
    expect(mine.single.brand, 'Lidl');
    expect(mine.single.isSeed, isFalse);
    expect(
      await repository.watchCatalog(profileId: profileId).first,
      hasLength(13),
    );

    final stored = await (database.select(
      database.foods,
    )..where((row) => row.id.equals(id))).getSingle();
    expect(stored.ownerProfileId, profileId);
    expect(stored.source, 'custom');
    expect(stored.defaultServingGrams, 150);

    final outbox = (await database.select(database.syncOutbox).get())
        .where((row) => row.entityId == id)
        .toList();
    expect(outbox.map((row) => row.operation), ['upsert']);
    final payload =
        jsonDecode(outbox.single.payloadJson) as Map<String, Object?>;
    expect(payload['barcode'], '4056489123456');
    expect(payload['default_serving_grams'], 150);
  });

  test('aggiorna un alimento personale mantenendo lo stesso id', () async {
    final id = await repository.createFood(
      profileId: profileId,
      draft: const FoodDraft(
        name: 'Pane proteico',
        per100g: Nutrients(calories: 250, protein: 20, carbs: 25, fat: 7),
      ),
    );

    final updatedId = await repository.updateFood(
      profileId: profileId,
      foodId: id,
      draft: const FoodDraft(
        name: 'Pane proteico integrale',
        brand: 'Panificio',
        per100g: Nutrients(calories: 244, protein: 21, carbs: 23, fat: 7.2),
        defaultServingGrams: 60,
      ),
    );

    expect(updatedId, id);
    final food = await repository.getFood(profileId: profileId, foodId: id);
    expect(food?.name, 'Pane proteico integrale');
    expect(food?.brand, 'Panificio');
    expect(food?.per100g.calories, closeTo(244, 0.0001));
    expect(food?.defaultServingGrams, 60);

    final operations = (await database.select(database.syncOutbox).get())
        .where((row) => row.entityId == id)
        .map((row) => row.operation);
    expect(operations, ['upsert', 'upsert']);
  });

  test('modificare un alimento di base crea una copia personale', () async {
    final copyId = await repository.updateFood(
      profileId: profileId,
      foodId: 'seed-banana',
      draft: const FoodDraft(
        name: 'Banana grande',
        per100g: Nutrients(calories: 89, protein: 1.1, carbs: 22.8, fat: 0.3),
        defaultServingGrams: 180,
      ),
    );

    expect(copyId, isNot('seed-banana'));
    final seed = await repository.getFood(
      profileId: profileId,
      foodId: 'seed-banana',
    );
    expect(seed?.name, 'Banana');
    expect(seed?.defaultServingGrams, 120);

    final copy = await repository.getFood(profileId: profileId, foodId: copyId);
    expect(copy?.name, 'Banana grande');
    expect(copy?.source, 'custom');
    expect(copy?.defaultServingGrams, 180);

    final mine = await repository.watchMine(profileId: profileId).first;
    expect(mine.map((food) => food.id), [copyId]);

    final operations = (await database.select(database.syncOutbox).get())
        .where((row) => row.entityType == 'food')
        .map((row) => row.entityId);
    expect(operations, [copyId]);
  });

  test(
    'un codice a barre duplicato viene rifiutato con un messaggio',
    () async {
      await repository.createFood(
        profileId: profileId,
        draft: const FoodDraft(
          name: 'Barretta proteica',
          barcode: '8001234567890',
          per100g: Nutrients(calories: 350, protein: 30, carbs: 35, fat: 9),
        ),
      );

      await expectLater(
        repository.createFood(
          profileId: profileId,
          draft: const FoodDraft(
            name: 'Barretta gemella',
            barcode: '8001234567890',
            per100g: Nutrients(calories: 350, protein: 30, carbs: 35, fat: 9),
          ),
        ),
        throwsA(
          isA<FoodCatalogException>().having(
            (error) => error.message,
            'message',
            contains('codice a barre'),
          ),
        ),
      );

      expect(
        await repository.watchMine(profileId: profileId).first,
        hasLength(1),
      );
      final outbox = (await database.select(database.syncOutbox).get())
          .where((row) => row.entityType == 'food')
          .toList();
      expect(outbox, hasLength(1));
    },
  );

  test(
    'la cancellazione soft nasconde l’alimento e protegge quelli di base',
    () async {
      final id = await repository.createFood(
        profileId: profileId,
        draft: const FoodDraft(
          name: 'Crema di arachidi',
          per100g: Nutrients(calories: 600, protein: 25, carbs: 12, fat: 50),
        ),
      );

      await repository.deleteFood(profileId: profileId, foodId: id);
      await repository.deleteFood(profileId: profileId, foodId: id);

      expect(await repository.watchMine(profileId: profileId).first, isEmpty);
      expect(
        await repository.watchCatalog(profileId: profileId).first,
        hasLength(12),
      );
      final stored = await (database.select(
        database.foods,
      )..where((row) => row.id.equals(id))).getSingle();
      expect(stored.deletedAt, isNotNull);
      final operations = (await database.select(database.syncOutbox).get())
          .where((row) => row.entityId == id)
          .map((row) => row.operation);
      expect(operations, ['upsert', 'delete']);

      await expectLater(
        repository.deleteFood(profileId: profileId, foodId: 'seed-banana'),
        throwsA(isA<FoodCatalogException>()),
      );
      expect(
        await repository.getFood(profileId: profileId, foodId: 'seed-banana'),
        isNotNull,
      );
    },
  );

  Future<void> insertCatalogFood({
    required String id,
    required String name,
    double calories = 150,
  }) async {
    final now = AppTime.nowUtc();
    await database
        .into(database.foods)
        .insert(
          FoodsCompanion.insert(
            id: id,
            name: name,
            caloriesPer100g: calories,
            proteinPer100g: 7,
            carbsPer100g: 20,
            fatPer100g: 4.5,
            defaultServingGrams: const Value(350),
            source: const Value(FoodSource.catalog),
            createdAt: now,
            updatedAt: now,
          ),
        );
  }

  test(
    'i piatti del catalogo si personalizzano con una copia e non si eliminano',
    () async {
      await insertCatalogFood(id: 'cat-pasta-al-ragu', name: 'Pasta al ragù');

      final copyId = await repository.updateFood(
        profileId: profileId,
        foodId: 'cat-pasta-al-ragu',
        draft: const FoodDraft(
          name: 'Ragù di casa',
          per100g: Nutrients(calories: 140, protein: 8, carbs: 18, fat: 4),
          defaultServingGrams: 400,
        ),
      );

      expect(copyId, isNot('cat-pasta-al-ragu'));
      final original = await repository.getFood(
        profileId: profileId,
        foodId: 'cat-pasta-al-ragu',
      );
      expect(original?.name, 'Pasta al ragù');
      expect(original?.isCatalog, isTrue);
      expect(original?.isBuiltIn, isTrue);
      expect(original?.defaultServingGrams, 350);

      final copy = await repository.getFood(
        profileId: profileId,
        foodId: copyId,
      );
      expect(copy?.name, 'Ragù di casa');
      expect(copy?.source, FoodSource.custom);

      // In outbox finisce solo la copia: il catalogo resta fuori dal push.
      final outbox = (await database.select(database.syncOutbox).get())
          .where((row) => row.entityType == 'food')
          .map((row) => row.entityId);
      expect(outbox, [copyId]);

      await expectLater(
        repository.deleteFood(
          profileId: profileId,
          foodId: 'cat-pasta-al-ragu',
        ),
        throwsA(isA<FoodCatalogException>()),
      );
      expect(
        await repository.getFood(
          profileId: profileId,
          foodId: 'cat-pasta-al-ragu',
        ),
        isNotNull,
      );
    },
  );

  test('la ricerca trova i piatti del catalogo tramite gli alias', () async {
    await insertCatalogFood(id: 'cat-pasta-al-ragu', name: 'Pasta al ragù');

    // «bolognese» non compare in nome o marca: senza alias non esce nulla.
    expect(
      await repository
          .watchCatalog(profileId: profileId, query: 'bolognese')
          .first,
      isEmpty,
    );

    final matches = await repository
        .watchCatalog(
          profileId: profileId,
          query: 'bolognese',
          aliasMatchIds: const ['cat-pasta-al-ragu'],
        )
        .first;
    expect(matches.single.name, 'Pasta al ragù');
  });

  test('restrictToIds limita il catalogo a una categoria', () async {
    await insertCatalogFood(id: 'cat-pasta-al-ragu', name: 'Pasta al ragù');
    await insertCatalogFood(id: 'cat-tiramisu', name: 'Tiramisù');

    final primi = await repository
        .watchCatalog(
          profileId: profileId,
          restrictToIds: const {'cat-pasta-al-ragu'},
        )
        .first;
    expect(primi.map((food) => food.id), ['cat-pasta-al-ragu']);

    expect(
      await repository
          .watchCatalog(profileId: profileId, restrictToIds: const {})
          .first,
      isEmpty,
    );
  });

  test(
    'il filtro categoria non nasconde copie personali e alimenti custom',
    () async {
      await insertCatalogFood(id: 'cat-pasta-al-ragu', name: 'Pasta al ragù');
      final copyId = await repository.updateFood(
        profileId: profileId,
        foodId: 'cat-pasta-al-ragu',
        draft: const FoodDraft(
          name: 'Pasta al ragù di casa',
          per100g: Nutrients(calories: 140, protein: 8, carbs: 18, fat: 4),
          defaultServingGrams: 400,
        ),
      );

      // La copia ha un id nuovo che non è mai nell'indice dell'asset:
      // con la categoria attiva deve restare accanto all'originale.
      final all = await repository
          .watchCatalog(
            profileId: profileId,
            restrictToIds: const {'cat-pasta-al-ragu'},
          )
          .first;
      expect(all.map((food) => food.id).toSet(), {
        'cat-pasta-al-ragu',
        copyId,
      });

      // «Solo i miei» + categoria non deve più dare una lista vuota.
      final mine = await repository
          .watchMine(
            profileId: profileId,
            restrictToIds: const {'cat-pasta-al-ragu'},
          )
          .first;
      expect(mine.map((food) => food.id), [copyId]);
    },
  );

  test(
    'un alimento personalizzato non è visibile agli altri profili',
    () async {
      final id = await repository.createCustomFood(
        profileId: profileId,
        draft: const FoodDraft(
          name: 'Ricetta segreta',
          per100g: Nutrients(calories: 100, protein: 5, carbs: 10, fat: 2),
        ),
      );
      final now = AppTime.nowUtc();
      await database
          .into(database.appProfiles)
          .insert(
            AppProfilesCompanion.insert(
              id: 'other',
              displayName: 'Altro',
              createdAt: now,
              updatedAt: now,
            ),
          );

      expect(await repository.getFood(profileId: 'other', foodId: id), isNull);
    },
  );
}
