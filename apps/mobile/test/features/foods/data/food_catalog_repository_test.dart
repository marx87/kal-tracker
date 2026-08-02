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
