import 'dart:convert';

import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';

/// Asset del ricettario fit (`assets/catalog/ricettario_fit_v1.json`),
/// generato da `scripts/build_recipe_catalog.py`.
class RecipeCatalogAsset {
  const RecipeCatalogAsset({required this.version, required this.recipes});

  factory RecipeCatalogAsset.fromJson(Map<String, Object?> json) {
    final version = json['version'];
    final rawRecipes = json['recipes'];
    if (version is! int || rawRecipes is! List) {
      throw const FormatException('Il formato del ricettario non è valido.');
    }
    return RecipeCatalogAsset(
      version: version,
      recipes: [
        for (final raw in rawRecipes)
          RecipeCatalogEntry.fromJson((raw as Map).cast<String, Object?>()),
      ],
    );
  }

  factory RecipeCatalogAsset.fromJsonString(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Il formato del ricettario non è valido.');
    }
    return RecipeCatalogAsset.fromJson(decoded);
  }

  final int version;
  final List<RecipeCatalogEntry> recipes;
}

class RecipeCatalogEntry {
  const RecipeCatalogEntry({
    required this.slug,
    required this.draft,
    required this.totals,
  });

  factory RecipeCatalogEntry.fromJson(Map<String, Object?> json) {
    final slug = json['slug'];
    final name = json['name'];
    final tags = json['tags'];
    final description = json['description'];
    final instructions = json['instructions'];
    final servings = json['servings'];
    final prepMinutes = json['prepMinutes'];
    final ingredients = json['ingredients'];
    final totals = json['totals'];
    if (slug is! String ||
        slug.isEmpty ||
        name is! String ||
        tags is! List ||
        description is! String ||
        instructions is! String ||
        servings is! int ||
        prepMinutes is! int ||
        ingredients is! List ||
        totals is! Map) {
      throw FormatException('Ricetta del ricettario non valida: $json');
    }
    return RecipeCatalogEntry(
      slug: slug,
      draft: FitRecipeDraft(
        name: name,
        tags: tags.cast<String>(),
        description: description,
        instructions: instructions,
        servings: servings,
        prepMinutes: prepMinutes,
        ingredients: [
          for (final raw in ingredients)
            _ingredientFromJson((raw as Map).cast<String, Object?>()),
        ],
      ),
      totals: _nutrientsFromJson(totals.cast<String, Object?>()),
    );
  }

  final String slug;
  final FitRecipeDraft draft;

  /// Totali precalcolati dallo script di build: servono SOLO da controllo
  /// incrociato nei test, l'app ricalcola sempre dagli ingredienti.
  final Nutrients totals;

  static RecipeIngredientDraft _ingredientFromJson(Map<String, Object?> json) {
    final name = json['name'];
    final per100g = json['per100g'];
    if (name is! String || per100g is! Map) {
      throw FormatException('Ingrediente del ricettario non valido: $json');
    }
    return RecipeIngredientDraft(
      name: name,
      grams: _toDouble(json['grams']),
      per100g: _nutrientsFromJson(per100g.cast<String, Object?>()),
    );
  }

  static Nutrients _nutrientsFromJson(Map<String, Object?> json) => Nutrients(
    calories: _toDouble(json['calories']),
    protein: _toDouble(json['protein']),
    carbs: _toDouble(json['carbs']),
    fat: _toDouble(json['fat']),
  );

  static double _toDouble(Object? value) {
    if (value is! num) {
      throw FormatException('Valore numerico non valido: $value');
    }
    return value.toDouble();
  }
}
