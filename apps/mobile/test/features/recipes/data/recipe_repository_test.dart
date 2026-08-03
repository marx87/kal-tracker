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
