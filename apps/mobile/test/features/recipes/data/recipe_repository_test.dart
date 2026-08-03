import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/recipes/data/recipe_repository.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';

void main() {
  late AppDatabase database;
  late RecipeRepository repository;
  late String profileId;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
    repository = RecipeRepository(database);
  });

  tearDown(() => database.close());

  test('salva ingredienti, porzioni e snapshot nutrizionale', () async {
    final id = await repository.createRecipe(
      profileId: profileId,
      draft: const FitRecipeDraft(
        name: 'Bowl pollo e riso',
        description: 'Completa e proteica',
        instructions: 'Cuoci, unisci e servi.',
        servings: 2,
        prepMinutes: 25,
        isFavorite: true,
        ingredients: [
          RecipeIngredientDraft(
            name: 'Petto di pollo',
            foodId: 'seed-chicken-breast',
            grams: 300,
            per100g: Nutrients(calories: 165, protein: 31, carbs: 0, fat: 3.6),
          ),
          RecipeIngredientDraft(
            name: 'Riso basmati cotto',
            foodId: 'seed-basmati-rice',
            grams: 300,
            per100g: Nutrients(
              calories: 130,
              protein: 2.7,
              carbs: 28.2,
              fat: 0.3,
            ),
          ),
        ],
      ),
    );

    final details = await repository.getRecipe(id);
    final list = await repository.watchRecipes(profileId).first;
    expect(details?.ingredients, hasLength(2));
    expect(details?.summary.nutrition.total.calories, closeTo(885, 0.0001));
    expect(
      details?.summary.nutrition.perServing.calories,
      closeTo(442.5, 0.0001),
    );
    expect(list.single.id, id);
    expect(list.single.isFavorite, isTrue);

    final outbox = await database.select(database.syncOutbox).get();
    expect(
      outbox.where((row) => row.entityType == 'fit_recipe').single.operation,
      'upsert',
    );
  });

  test('il payload di sincronizzazione usa tag CSV e posizioni', () async {
    final id = await repository.createRecipe(
      profileId: profileId,
      draft: const FitRecipeDraft(
        name: 'Bowl da sincronizzare',
        servings: 2,
        tags: ['Pranzo', 'proteico'],
        ingredients: [
          RecipeIngredientDraft(
            name: 'Petto di pollo',
            grams: 300,
            per100g: Nutrients(calories: 165, protein: 31, carbs: 0, fat: 3.6),
          ),
          RecipeIngredientDraft(
            name: 'Broccoli',
            grams: 200,
            per100g: Nutrients(
              calories: 34,
              protein: 2.8,
              carbs: 6.6,
              fat: 0.4,
            ),
          ),
        ],
      ),
    );

    final row = (await database.select(database.syncOutbox).get()).singleWhere(
      (row) => row.entityId == id,
    );
    final payload = jsonDecode(row.payloadJson) as Map<String, Object?>;
    final ingredients = (payload['ingredients']! as List<Object?>)
        .cast<Map<String, Object?>>();
    final stored =
        await (database.select(database.recipeIngredients)
              ..where((row) => row.recipeId.equals(id))
              ..orderBy([(row) => OrderingTerm.asc(row.position)]))
            .get();

    expect(payload['tags'], 'pranzo,proteico');
    expect(ingredients.map((row) => row['position']), [0, 1]);
    expect(ingredients.map((row) => row['id']), stored.map((row) => row.id));
    expect(ingredients.map((row) => row['recipe_id']), [id, id]);
    expect(ingredients.first['name'], 'Petto di pollo');
  });

  test('preferito e cancellazione producono operazioni idempotenti', () async {
    final id = await repository.createRecipe(
      profileId: profileId,
      draft: const FitRecipeDraft(
        name: 'Mela e mandorle',
        servings: 1,
        ingredients: [
          RecipeIngredientDraft(
            name: 'Mela',
            grams: 150,
            per100g: Nutrients(
              calories: 52,
              protein: 0.3,
              carbs: 13.8,
              fat: 0.2,
            ),
          ),
        ],
      ),
    );

    await repository.setFavorite(id, true);
    expect((await repository.getRecipe(id))?.summary.isFavorite, isTrue);
    await repository.deleteRecipe(id);
    await repository.deleteRecipe(id);
    expect(await repository.getRecipe(id), isNull);

    final operations = (await database.select(database.syncOutbox).get())
        .where((row) => row.entityId == id)
        .map((row) => row.operation);
    expect(operations, ['upsert', 'upsert', 'delete']);
  });

  test('una FK ingrediente invalida annulla l’intera transazione', () async {
    await expectLater(
      repository.createRecipe(
        profileId: profileId,
        draft: const FitRecipeDraft(
          name: 'Non valida',
          servings: 1,
          ingredients: [
            RecipeIngredientDraft(
              name: 'Fantasma',
              foodId: 'food-missing',
              grams: 100,
              per100g: Nutrients(calories: 100, protein: 10, carbs: 10, fat: 2),
            ),
          ],
        ),
      ),
      throwsA(isA<Exception>()),
    );

    expect(await database.select(database.fitRecipes).get(), isEmpty);
    expect(await database.select(database.recipeIngredients).get(), isEmpty);
    expect(
      (await database.select(database.syncOutbox).get()).where(
        (row) => row.entityType == 'fit_recipe',
      ),
      isEmpty,
    );
  });

  test(
    'la modifica riduce gli ingredienti e ricompatta le posizioni',
    () async {
      final id = await repository.createRecipe(
        profileId: profileId,
        draft: const FitRecipeDraft(
          name: 'Bowl da rivedere',
          servings: 2,
          tags: ['Pranzo', 'proteico'],
          ingredients: [
            RecipeIngredientDraft(
              name: 'Petto di pollo',
              grams: 300,
              per100g: Nutrients(
                calories: 165,
                protein: 31,
                carbs: 0,
                fat: 3.6,
              ),
            ),
            RecipeIngredientDraft(
              name: 'Riso basmati cotto',
              grams: 300,
              per100g: Nutrients(
                calories: 130,
                protein: 2.7,
                carbs: 28.2,
                fat: 0.3,
              ),
            ),
            RecipeIngredientDraft(
              name: 'Olio extravergine di oliva',
              grams: 20,
              per100g: Nutrients(calories: 884, protein: 0, carbs: 0, fat: 100),
            ),
          ],
        ),
      );

      await repository.updateRecipe(
        id: id,
        draft: const FitRecipeDraft(
          name: 'Bowl leggera',
          servings: 1,
          prepMinutes: 15,
          tags: ['pranzo'],
          ingredients: [
            RecipeIngredientDraft(
              name: 'Petto di pollo',
              grams: 200,
              per100g: Nutrients(
                calories: 165,
                protein: 31,
                carbs: 0,
                fat: 3.6,
              ),
            ),
            RecipeIngredientDraft(
              name: 'Broccoli',
              grams: 250,
              per100g: Nutrients(
                calories: 34,
                protein: 2.8,
                carbs: 6.6,
                fat: 0.4,
              ),
            ),
          ],
        ),
      );

      final details = await repository.getRecipe(id);
      final rows = await (database.select(
        database.recipeIngredients,
      )..where((row) => row.recipeId.equals(id))).get();

      expect(details?.summary.name, 'Bowl leggera');
      expect(details?.summary.servings, 1);
      expect(details?.summary.prepMinutes, 15);
      expect(details?.summary.tags, ['pranzo']);
      expect(details?.ingredients.map((ingredient) => ingredient.name), [
        'Petto di pollo',
        'Broccoli',
      ]);
      expect(details?.summary.nutrition.total.calories, closeTo(415, 0.0001));
      expect(rows.map((row) => row.position).toList()..sort(), [0, 1]);

      final operations = (await database.select(database.syncOutbox).get())
          .where((row) => row.entityId == id)
          .map((row) => row.operation);
      expect(operations, ['upsert', 'upsert']);
    },
  );

  test('la modifica di una ricetta cancellata non è permessa', () async {
    final id = await repository.createRecipe(
      profileId: profileId,
      draft: const FitRecipeDraft(
        name: 'Da cancellare',
        servings: 1,
        ingredients: [
          RecipeIngredientDraft(
            name: 'Mela',
            grams: 150,
            per100g: Nutrients(
              calories: 52,
              protein: 0.3,
              carbs: 13.8,
              fat: 0.2,
            ),
          ),
        ],
      ),
    );
    await repository.deleteRecipe(id);

    await expectLater(
      repository.updateRecipe(
        id: id,
        draft: const FitRecipeDraft(
          name: 'Risorta',
          servings: 1,
          ingredients: [
            RecipeIngredientDraft(
              name: 'Mela',
              grams: 200,
              per100g: Nutrients(
                calories: 52,
                protein: 0.3,
                carbs: 13.8,
                fat: 0.2,
              ),
            ),
          ],
        ),
      ),
      throwsStateError,
    );
  });

  test('duplica la ricetta con nuovi id e senza il preferito', () async {
    final id = await repository.createRecipe(
      profileId: profileId,
      draft: const FitRecipeDraft(
        name: 'Cena di pesce',
        description: 'Leggera e saporita',
        instructions: 'Cuoci e servi.',
        servings: 2,
        prepMinutes: 18,
        isFavorite: true,
        tags: ['cena', 'proteico'],
        ingredients: [
          RecipeIngredientDraft(
            name: 'Salmone',
            grams: 300,
            per100g: Nutrients(
              calories: 208,
              protein: 20.4,
              carbs: 0,
              fat: 13.4,
            ),
          ),
          RecipeIngredientDraft(
            name: 'Broccoli',
            grams: 200,
            per100g: Nutrients(
              calories: 34,
              protein: 2.8,
              carbs: 6.6,
              fat: 0.4,
            ),
          ),
        ],
      ),
    );

    final copyId = await repository.duplicateRecipe(id);
    final original = await repository.getRecipe(id);
    final copy = await repository.getRecipe(copyId);

    expect(copyId, isNot(id));
    expect(copy?.summary.name, 'Cena di pesce (copia)');
    expect(copy?.summary.isFavorite, isFalse);
    expect(copy?.summary.tags, ['cena', 'proteico']);
    expect(copy?.summary.servings, 2);
    expect(copy?.summary.prepMinutes, 18);
    expect(copy?.instructions, 'Cuoci e servi.');
    expect(
      copy?.ingredients.map((ingredient) => ingredient.name),
      original?.ingredients.map((ingredient) => ingredient.name),
    );
    expect(
      copy?.summary.nutrition.total.calories,
      closeTo(original!.summary.nutrition.total.calories, 0.0001),
    );

    final rows = await database.select(database.recipeIngredients).get();
    final originalIds = rows
        .where((row) => row.recipeId == id)
        .map((row) => row.id)
        .toSet();
    final copyIds = rows
        .where((row) => row.recipeId == copyId)
        .map((row) => row.id)
        .toSet();
    expect(copyIds, hasLength(2));
    expect(copyIds.intersection(originalIds), isEmpty);

    final operations = (await database.select(database.syncOutbox).get())
        .where((row) => row.entityId == copyId)
        .map((row) => row.operation);
    expect(operations, ['upsert']);
  });

  test('la ricerca offline copre nome, ingrediente, tag e preferiti', () async {
    await repository.createRecipe(
      profileId: profileId,
      draft: const FitRecipeDraft(
        name: 'Insalata di ceci',
        servings: 1,
        tags: ['pranzo', 'veloce'],
        ingredients: [
          RecipeIngredientDraft(
            name: 'Ceci lessati',
            grams: 200,
            per100g: Nutrients(calories: 120, protein: 7, carbs: 18, fat: 2),
          ),
        ],
      ),
    );
    await repository.createRecipe(
      profileId: profileId,
      draft: const FitRecipeDraft(
        name: 'Cena leggera',
        servings: 1,
        isFavorite: true,
        tags: ['cena'],
        ingredients: [
          RecipeIngredientDraft(
            name: 'Merluzzo',
            grams: 250,
            per100g: Nutrients(calories: 82, protein: 18, carbs: 0, fat: 0.7),
          ),
        ],
      ),
    );

    Future<List<String>> names({
      String search = '',
      String? tag,
      bool onlyFavorites = false,
    }) async {
      final recipes = await repository
          .watchRecipes(
            profileId,
            search: search,
            tag: tag,
            onlyFavorites: onlyFavorites,
          )
          .first;
      return recipes.map((recipe) => recipe.name).toList();
    }

    expect(await names(search: 'CECI'), ['Insalata di ceci']);
    expect(await names(search: 'insala'), ['Insalata di ceci']);
    expect(await names(search: 'merluzzo'), ['Cena leggera']);
    expect(await names(tag: 'Cena'), ['Cena leggera']);
    expect(await names(tag: 'ran'), isEmpty);
    expect(await names(onlyFavorites: true), ['Cena leggera']);
    expect(await names(tag: 'pranzo', onlyFavorites: true), isEmpty);
    expect(await names(search: 'zuppa'), isEmpty);
  });

  test('il catalogo starter viene installato una sola volta', () async {
    await repository.ensureStarterRecipes(profileId);
    await repository.ensureStarterRecipes(profileId);

    final recipes = await repository.watchRecipes(profileId).first;
    final ingredients = await database.select(database.recipeIngredients).get();
    final outbox = (await database.select(database.syncOutbox).get()).where(
      (row) => row.entityType == 'fit_recipe',
    );

    expect(recipes.map((recipe) => recipe.name), contains('Bowl pollo e riso'));
    expect(
      recipes.map((recipe) => recipe.name),
      contains('Overnight oats banana'),
    );
    expect(
      recipes.map((recipe) => recipe.name),
      contains('Riso con salmone e broccoli'),
    );
    expect(recipes, hasLength(6));
    expect(ingredients, hasLength(22));
    expect(outbox, hasLength(6));
  });
}
