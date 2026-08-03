import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';
import 'package:uuid/uuid.dart';

class RecipeRepository {
  RecipeRepository(this._database, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final AppDatabase _database;
  final Uuid _uuid;

  Stream<List<FitRecipeSummary>> watchRecipes(
    String profileId, {
    bool onlyFavorites = false,
    String search = '',
    String? tag,
  }) {
    final needle = search.trim().toLowerCase();
    final wantedTag = RecipeTags.normalizeOne(tag ?? '');
    final query = _database.select(_database.fitRecipes)
      ..where((row) {
        var filter = row.profileId.equals(profileId) & row.deletedAt.isNull();
        if (onlyFavorites) {
          filter = filter & row.isFavorite.equals(true);
        }
        if (needle.isNotEmpty) {
          filter =
              filter &
              (row.name.lower().contains(needle) |
                  _hasIngredientNamed(row, needle));
        }
        return filter;
      })
      ..orderBy([
        (row) => OrderingTerm.desc(row.isFavorite),
        (row) => OrderingTerm.desc(row.updatedAt),
      ]);
    return query.watch().map(
      (rows) => rows
          .map(_summaryFromRow)
          .where(
            (recipe) => wantedTag.isEmpty || recipe.tags.contains(wantedTag),
          )
          .toList(growable: false),
    );
  }

  Expression<bool> _hasIngredientNamed($FitRecipesTable row, String needle) =>
      existsQuery(
        _database.select(_database.recipeIngredients)..where(
          (ingredient) =>
              ingredient.recipeId.equalsExp(row.id) &
              ingredient.name.lower().contains(needle),
        ),
      );

  Future<FitRecipeDetails?> getRecipe(String id) async {
    final recipe =
        await (_database.select(_database.fitRecipes)
              ..where((row) => row.id.equals(id) & row.deletedAt.isNull()))
            .getSingleOrNull();
    if (recipe == null) {
      return null;
    }
    return FitRecipeDetails(
      summary: _summaryFromRow(recipe),
      instructions: recipe.instructions,
      ingredients: await _ingredientsOf(id),
    );
  }

  Future<String> createRecipe({
    required String profileId,
    required FitRecipeDraft draft,
  }) async {
    draft.validate();
    final id = _uuid.v4();
    final now = AppTime.nowUtc();
    await _database.transaction(
      () => _insertRecipe(id: id, profileId: profileId, draft: draft, now: now),
    );
    return id;
  }

  /// Riscrive la ricetta e i suoi ingredienti come blocco unico.
  ///
  /// Le righe vecchie vengono cancellate prima di inserire le nuove: è l’unico
  /// ordine che ricompatta le posizioni senza violare UNIQUE (recipe_id,
  /// position) quando gli ingredienti diminuiscono o cambiano ordine.
  Future<void> updateRecipe({
    required String id,
    required FitRecipeDraft draft,
  }) async {
    draft.validate();
    final now = AppTime.nowUtc();
    await _database.transaction(() async {
      final existing =
          await (_database.select(_database.fitRecipes)
                ..where((row) => row.id.equals(id) & row.deletedAt.isNull()))
              .getSingleOrNull();
      if (existing == null) {
        throw StateError('Ricetta non trovata.');
      }
      final nutrition = RecipeNutritionCalculator.calculate(
        ingredients: draft.ingredients,
        servings: draft.servings,
      );
      final description = _cleanOptional(draft.description);
      final instructions = _cleanOptional(draft.instructions);
      final tags = RecipeTags.normalize(draft.tags);

      await (_database.update(
        _database.fitRecipes,
      )..where((row) => row.id.equals(id))).write(
        FitRecipesCompanion(
          name: Value(draft.name.trim()),
          description: Value(description),
          instructions: Value(instructions),
          tags: Value(RecipeTags.encode(tags)),
          servings: Value(draft.servings),
          prepMinutes: Value(draft.prepMinutes),
          totalCalories: Value(nutrition.total.calories),
          totalProtein: Value(nutrition.total.protein),
          totalCarbs: Value(nutrition.total.carbs),
          totalFat: Value(nutrition.total.fat),
          isFavorite: Value(draft.isFavorite),
          updatedAt: Value(now),
        ),
      );
      await (_database.delete(
        _database.recipeIngredients,
      )..where((row) => row.recipeId.equals(id))).go();
      final ingredients = _ingredientRows(recipeId: id, draft: draft);
      await _insertIngredients(ingredients);
      await _appendOutbox(
        entityId: id,
        operation: 'upsert',
        payload: _recipePayload(
          id: id,
          profileId: existing.profileId,
          draft: draft,
          description: description,
          instructions: instructions,
          tags: tags,
          ingredients: ingredients,
          nutrition: nutrition,
          now: now,
        ),
        now: now,
      );
    });
  }

  Future<String> duplicateRecipe(String recipeId) async {
    final id = _uuid.v4();
    final now = AppTime.nowUtc();
    await _database.transaction(() async {
      final source =
          await (_database.select(_database.fitRecipes)..where(
                (row) => row.id.equals(recipeId) & row.deletedAt.isNull(),
              ))
              .getSingleOrNull();
      if (source == null) {
        throw StateError('Ricetta non trovata.');
      }
      await _insertRecipe(
        id: id,
        profileId: source.profileId,
        draft: FitRecipeDraft(
          name: _copyName(source.name),
          description: source.description,
          instructions: source.instructions,
          tags: RecipeTags.parse(source.tags),
          servings: source.servings,
          prepMinutes: source.prepMinutes,
          ingredients: await _ingredientsOf(recipeId),
        ),
        now: now,
      );
    });
    return id;
  }

  /// Installs the small offline starter catalog exactly once per profile.
  ///
  /// Stable recipe IDs make this safe to call at every app start. Deleting a
  /// starter recipe is respected because its tombstone keeps the same ID.
  Future<void> ensureStarterRecipes(String profileId) async {
    final now = AppTime.nowUtc();
    await _database.transaction(() async {
      for (final starter in _starterRecipes) {
        final id = _uuid.v5(
          Namespace.url.value,
          'https://kal-tracker.local/starter/$profileId/${starter.slug}',
        );
        final existing = await (_database.select(
          _database.fitRecipes,
        )..where((row) => row.id.equals(id))).getSingleOrNull();
        if (existing != null) {
          continue;
        }
        await _insertRecipe(
          id: id,
          profileId: profileId,
          draft: starter.draft,
          now: now,
        );
      }
    });
  }

  Future<void> setFavorite(String id, bool isFavorite) async {
    final now = AppTime.nowUtc();
    await _database.transaction(() async {
      final changed =
          await (_database.update(
            _database.fitRecipes,
          )..where((row) => row.id.equals(id) & row.deletedAt.isNull())).write(
            FitRecipesCompanion(
              isFavorite: Value(isFavorite),
              updatedAt: Value(now),
            ),
          );
      if (changed == 0) {
        throw StateError('Ricetta non trovata.');
      }
      await _appendOutbox(
        entityId: id,
        operation: 'upsert',
        payload: {
          'id': id,
          'is_favorite': isFavorite,
          'updated_at': now.toIso8601String(),
        },
        now: now,
      );
    });
  }

  Future<void> deleteRecipe(String id) async {
    final now = AppTime.nowUtc();
    await _database.transaction(() async {
      final changed =
          await (_database.update(
            _database.fitRecipes,
          )..where((row) => row.id.equals(id) & row.deletedAt.isNull())).write(
            FitRecipesCompanion(updatedAt: Value(now), deletedAt: Value(now)),
          );
      if (changed == 0) {
        return;
      }
      await _appendOutbox(
        entityId: id,
        operation: 'delete',
        payload: {'id': id, 'deleted_at': now.toIso8601String()},
        now: now,
      );
    });
  }

  FitRecipeSummary _summaryFromRow(LocalFitRecipe row) {
    final total = Nutrients(
      calories: row.totalCalories,
      protein: row.totalProtein,
      carbs: row.totalCarbs,
      fat: row.totalFat,
    );
    final divisor = row.servings.toDouble();
    return FitRecipeSummary(
      id: row.id,
      name: row.name,
      description: row.description,
      tags: RecipeTags.parse(row.tags),
      servings: row.servings,
      prepMinutes: row.prepMinutes,
      isFavorite: row.isFavorite,
      nutrition: RecipeNutrition(
        total: total,
        perServing: Nutrients(
          calories: total.calories / divisor,
          protein: total.protein / divisor,
          carbs: total.carbs / divisor,
          fat: total.fat / divisor,
        ),
      ),
      updatedAt: row.updatedAt,
    );
  }

  String? _cleanOptional(String? value) {
    final clean = value?.trim();
    return clean == null || clean.isEmpty ? null : clean;
  }

  String _copyName(String name) {
    const suffix = ' (copia)';
    final base = name.trim();
    final room = 160 - suffix.length;
    return base.length > room
        ? '${base.substring(0, room).trim()}$suffix'
        : '$base$suffix';
  }

  Future<List<RecipeIngredientDraft>> _ingredientsOf(String recipeId) async {
    final rows =
        await (_database.select(_database.recipeIngredients)
              ..where((row) => row.recipeId.equals(recipeId))
              ..orderBy([(row) => OrderingTerm.asc(row.position)]))
            .get();
    return rows
        .map(
          (row) => RecipeIngredientDraft(
            name: row.name,
            foodId: row.foodId,
            grams: row.grams,
            per100g: Nutrients(
              calories: row.caloriesPer100g,
              protein: row.proteinPer100g,
              carbs: row.carbsPer100g,
              fat: row.fatPer100g,
            ),
          ),
        )
        .toList(growable: false);
  }

  List<RecipeIngredientsCompanion> _ingredientRows({
    required String recipeId,
    required FitRecipeDraft draft,
  }) => [
    for (final (position, ingredient) in draft.ingredients.indexed)
      RecipeIngredientsCompanion.insert(
        id: _uuid.v4(),
        recipeId: recipeId,
        foodId: Value(ingredient.foodId),
        position: position,
        name: ingredient.name.trim(),
        grams: ingredient.grams,
        caloriesPer100g: ingredient.per100g.calories,
        proteinPer100g: ingredient.per100g.protein,
        carbsPer100g: ingredient.per100g.carbs,
        fatPer100g: ingredient.per100g.fat,
      ),
  ];

  Future<void> _insertIngredients(List<RecipeIngredientsCompanion> rows) =>
      _database.batch(
        (batch) => batch.insertAll(_database.recipeIngredients, rows),
      );

  /// Stessa forma del payload scritto dal ripristino di un backup: i tag sono
  /// una stringa CSV e ogni ingrediente porta id, ricetta e posizione.
  Map<String, Object?> _recipePayload({
    required String id,
    required String profileId,
    required FitRecipeDraft draft,
    required String? description,
    required String? instructions,
    required List<String> tags,
    required List<RecipeIngredientsCompanion> ingredients,
    required RecipeNutrition nutrition,
    required DateTime now,
  }) => {
    'id': id,
    'profile_id': profileId,
    'name': draft.name.trim(),
    'description': description,
    'instructions': instructions,
    'tags': RecipeTags.encode(tags),
    'servings': draft.servings,
    'prep_minutes': draft.prepMinutes,
    'is_favorite': draft.isFavorite,
    'total_calories': nutrition.total.calories,
    'total_protein': nutrition.total.protein,
    'total_carbs': nutrition.total.carbs,
    'total_fat': nutrition.total.fat,
    'ingredients': [
      for (final row in ingredients)
        {
          'id': row.id.value,
          'recipe_id': row.recipeId.value,
          'food_id': row.foodId.value,
          'position': row.position.value,
          'name': row.name.value,
          'grams': row.grams.value,
          'calories_per_100g': row.caloriesPer100g.value,
          'protein_per_100g': row.proteinPer100g.value,
          'carbs_per_100g': row.carbsPer100g.value,
          'fat_per_100g': row.fatPer100g.value,
        },
    ],
    'updated_at': now.toIso8601String(),
  };

  Future<void> _insertRecipe({
    required String id,
    required String profileId,
    required FitRecipeDraft draft,
    required DateTime now,
  }) async {
    draft.validate();
    final nutrition = RecipeNutritionCalculator.calculate(
      ingredients: draft.ingredients,
      servings: draft.servings,
    );
    final description = _cleanOptional(draft.description);
    final instructions = _cleanOptional(draft.instructions);
    final tags = RecipeTags.normalize(draft.tags);

    await _database
        .into(_database.fitRecipes)
        .insert(
          FitRecipesCompanion.insert(
            id: id,
            profileId: profileId,
            name: draft.name.trim(),
            description: Value(description),
            instructions: Value(instructions),
            tags: Value(RecipeTags.encode(tags)),
            servings: draft.servings,
            prepMinutes: Value(draft.prepMinutes),
            totalCalories: nutrition.total.calories,
            totalProtein: nutrition.total.protein,
            totalCarbs: nutrition.total.carbs,
            totalFat: nutrition.total.fat,
            isFavorite: Value(draft.isFavorite),
            createdAt: now,
            updatedAt: now,
          ),
        );
    final ingredients = _ingredientRows(recipeId: id, draft: draft);
    await _insertIngredients(ingredients);
    await _appendOutbox(
      entityId: id,
      operation: 'upsert',
      payload: _recipePayload(
        id: id,
        profileId: profileId,
        draft: draft,
        description: description,
        instructions: instructions,
        tags: tags,
        ingredients: ingredients,
        nutrition: nutrition,
        now: now,
      ),
      now: now,
    );
  }

  Future<void> _appendOutbox({
    required String entityId,
    required String operation,
    required Map<String, Object?> payload,
    required DateTime now,
  }) => _database
      .into(_database.syncOutbox)
      .insert(
        SyncOutboxCompanion.insert(
          id: _uuid.v4(),
          entityType: 'fit_recipe',
          entityId: entityId,
          operation: operation,
          payloadJson: jsonEncode(payload),
          createdAt: now,
        ),
      );
}

const _starterRecipes = <({String slug, FitRecipeDraft draft})>[
  (
    slug: 'bowl-pollo-riso',
    draft: FitRecipeDraft(
      name: 'Bowl pollo e riso',
      tags: ['pranzo', 'proteico'],
      description: 'Completa, colorata e ricca di proteine.',
      instructions:
          'Scalda il riso, cuoci il pollo e i broccoli, poi componi la bowl '
          'con l’olio a crudo.',
      servings: 2,
      prepMinutes: 25,
      isFavorite: true,
      ingredients: [
        RecipeIngredientDraft(
          name: 'Petto di pollo',
          grams: 300,
          per100g: Nutrients(calories: 165, protein: 31, carbs: 0, fat: 3.6),
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
          name: 'Broccoli',
          grams: 300,
          per100g: Nutrients(calories: 34, protein: 2.8, carbs: 6.6, fat: 0.4),
        ),
        RecipeIngredientDraft(
          name: 'Olio extravergine di oliva',
          grams: 20,
          per100g: Nutrients(calories: 884, protein: 0, carbs: 0, fat: 100),
        ),
      ],
    ),
  ),
  (
    slug: 'overnight-oats',
    draft: FitRecipeDraft(
      name: 'Overnight oats banana',
      tags: ['colazione', 'veloce'],
      description: 'Colazione cremosa da preparare la sera prima.',
      instructions:
          'Mescola avena e yogurt, lascia riposare in frigo e completa con '
          'banana e mandorle.',
      servings: 2,
      prepMinutes: 8,
      ingredients: [
        RecipeIngredientDraft(
          name: 'Fiocchi d’avena',
          grams: 100,
          per100g: Nutrients(
            calories: 389,
            protein: 16.9,
            carbs: 66.3,
            fat: 6.9,
          ),
        ),
        RecipeIngredientDraft(
          name: 'Yogurt greco 0%',
          grams: 340,
          per100g: Nutrients(calories: 59, protein: 10.3, carbs: 3.6, fat: 0.4),
        ),
        RecipeIngredientDraft(
          name: 'Banana',
          grams: 160,
          per100g: Nutrients(calories: 89, protein: 1.1, carbs: 22.8, fat: 0.3),
        ),
        RecipeIngredientDraft(
          name: 'Mandorle',
          grams: 20,
          per100g: Nutrients(
            calories: 579,
            protein: 21.2,
            carbs: 21.6,
            fat: 49.9,
          ),
        ),
      ],
    ),
  ),
  (
    slug: 'riso-salmone-broccoli',
    draft: FitRecipeDraft(
      name: 'Riso con salmone e broccoli',
      tags: ['cena', 'proteico'],
      description: 'Un piatto unico ricco di gusto e omega 3.',
      instructions:
          'Cuoci il salmone e i broccoli, uniscili al riso caldo e completa '
          'con l’olio a crudo.',
      servings: 2,
      prepMinutes: 25,
      ingredients: [
        RecipeIngredientDraft(
          name: 'Salmone',
          grams: 300,
          per100g: Nutrients(calories: 208, protein: 20.4, carbs: 0, fat: 13.4),
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
          name: 'Broccoli',
          grams: 300,
          per100g: Nutrients(calories: 34, protein: 2.8, carbs: 6.6, fat: 0.4),
        ),
        RecipeIngredientDraft(
          name: 'Olio extravergine di oliva',
          grams: 10,
          per100g: Nutrients(calories: 884, protein: 0, carbs: 0, fat: 100),
        ),
      ],
    ),
  ),
  (
    slug: 'toast-uova',
    draft: FitRecipeDraft(
      name: 'Toast integrale con uova',
      tags: ['colazione', 'veloce'],
      description: 'Colazione salata o pranzo rapido e saziante.',
      instructions:
          'Tosta il pane, cuoci le uova in padella con poco olio e servi '
          'subito.',
      servings: 2,
      prepMinutes: 12,
      ingredients: [
        RecipeIngredientDraft(
          name: 'Pane integrale',
          grams: 120,
          per100g: Nutrients(calories: 247, protein: 13, carbs: 41, fat: 3.4),
        ),
        RecipeIngredientDraft(
          name: 'Uovo intero',
          grams: 240,
          per100g: Nutrients(
            calories: 143,
            protein: 12.6,
            carbs: 0.7,
            fat: 9.5,
          ),
        ),
        RecipeIngredientDraft(
          name: 'Olio extravergine di oliva',
          grams: 10,
          per100g: Nutrients(calories: 884, protein: 0, carbs: 0, fat: 100),
        ),
      ],
    ),
  ),
  (
    slug: 'coppa-yogurt-mela',
    draft: FitRecipeDraft(
      name: 'Coppa yogurt, mela e mandorle',
      tags: ['spuntino', 'veloce'],
      description: 'Spuntino fresco, croccante e proteico.',
      instructions:
          'Dividi lo yogurt in due coppe e completa con mela a cubetti e '
          'mandorle tritate.',
      servings: 2,
      prepMinutes: 7,
      ingredients: [
        RecipeIngredientDraft(
          name: 'Yogurt greco 0%',
          grams: 340,
          per100g: Nutrients(calories: 59, protein: 10.3, carbs: 3.6, fat: 0.4),
        ),
        RecipeIngredientDraft(
          name: 'Mela',
          grams: 300,
          per100g: Nutrients(calories: 52, protein: 0.3, carbs: 13.8, fat: 0.2),
        ),
        RecipeIngredientDraft(
          name: 'Mandorle',
          grams: 30,
          per100g: Nutrients(
            calories: 579,
            protein: 21.2,
            carbs: 21.6,
            fat: 49.9,
          ),
        ),
      ],
    ),
  ),
  (
    slug: 'pollo-croccante-broccoli',
    draft: FitRecipeDraft(
      name: 'Pollo croccante con broccoli',
      tags: ['cena', 'proteico'],
      description: 'Teglia proteica con una panatura integrale leggera.',
      instructions:
          'Trita il pane, impana il pollo e cuocilo in forno insieme ai '
          'broccoli. Completa con l’olio.',
      servings: 2,
      prepMinutes: 35,
      ingredients: [
        RecipeIngredientDraft(
          name: 'Petto di pollo',
          grams: 300,
          per100g: Nutrients(calories: 165, protein: 31, carbs: 0, fat: 3.6),
        ),
        RecipeIngredientDraft(
          name: 'Pane integrale',
          grams: 120,
          per100g: Nutrients(calories: 247, protein: 13, carbs: 41, fat: 3.4),
        ),
        RecipeIngredientDraft(
          name: 'Broccoli',
          grams: 400,
          per100g: Nutrients(calories: 34, protein: 2.8, carbs: 6.6, fat: 0.4),
        ),
        RecipeIngredientDraft(
          name: 'Olio extravergine di oliva',
          grams: 15,
          per100g: Nutrients(calories: 884, protein: 0, carbs: 0, fat: 100),
        ),
      ],
    ),
  ),
];
