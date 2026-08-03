import 'package:kal_tracker/features/diary/domain/nutrition.dart';

class RecipeIngredientDraft {
  const RecipeIngredientDraft({
    required this.name,
    required this.grams,
    required this.per100g,
    this.foodId,
  });

  final String name;
  final String? foodId;
  final double grams;
  final Nutrients per100g;

  void validate() {
    if (name.trim().isEmpty || name.trim().length > 160) {
      throw const FormatException('Il nome dell’ingrediente non è valido.');
    }
    NutritionCalculator.scale(per100g: per100g, grams: grams);
  }
}

abstract final class RecipeTags {
  static const int maxTags = 8;
  static const int maxTagLength = 24;

  static String normalizeOne(String value) => value
      .toLowerCase()
      .replaceAll('#', ' ')
      .replaceAll(',', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static List<String> normalize(Iterable<String> values) {
    final normalized = <String>[];
    for (final value in values) {
      final tag = normalizeOne(value);
      if (tag.isEmpty || normalized.contains(tag)) {
        continue;
      }
      normalized.add(tag);
    }
    return normalized.toList(growable: false);
  }

  static List<String> parse(String? raw) => raw == null || raw.trim().isEmpty
      ? const <String>[]
      : normalize(raw.split(','));

  static String? encode(Iterable<String> tags) {
    final normalized = normalize(tags);
    return normalized.isEmpty ? null : normalized.join(',');
  }
}

class FitRecipeDraft {
  const FitRecipeDraft({
    required this.name,
    required this.servings,
    required this.ingredients,
    this.description,
    this.instructions,
    this.tags = const <String>[],
    this.prepMinutes = 0,
    this.isFavorite = false,
  });

  final String name;
  final String? description;
  final String? instructions;
  final List<String> tags;
  final int servings;
  final int prepMinutes;
  final bool isFavorite;
  final List<RecipeIngredientDraft> ingredients;

  void validate() {
    if (name.trim().isEmpty || name.trim().length > 160) {
      throw const FormatException('Il nome della ricetta non è valido.');
    }
    if (description != null && description!.trim().length > 600) {
      throw const FormatException(
        'La descrizione della ricetta è troppo lunga.',
      );
    }
    if (instructions != null && instructions!.trim().length > 4000) {
      throw const FormatException(
        'Le istruzioni della ricetta sono troppo lunghe.',
      );
    }
    if (servings <= 0 || servings > 100) {
      throw const FormatException('Il numero di porzioni non è valido.');
    }
    if (prepMinutes < 0 || prepMinutes > 10080) {
      throw const FormatException('Il tempo di preparazione non è valido.');
    }
    final normalizedTags = RecipeTags.normalize(tags);
    if (normalizedTags.length > RecipeTags.maxTags) {
      throw const FormatException('Puoi usare al massimo 8 tag.');
    }
    for (final tag in normalizedTags) {
      if (tag.length > RecipeTags.maxTagLength) {
        throw const FormatException('Un tag è troppo lungo.');
      }
    }
    if (ingredients.isEmpty) {
      throw const FormatException('Aggiungi almeno un ingrediente.');
    }
    for (final ingredient in ingredients) {
      ingredient.validate();
    }
  }
}

class RecipeNutrition {
  const RecipeNutrition({required this.total, required this.perServing});

  final Nutrients total;
  final Nutrients perServing;
}

abstract final class RecipeNutritionCalculator {
  static RecipeNutrition calculate({
    required List<RecipeIngredientDraft> ingredients,
    required int servings,
  }) {
    if (servings <= 0 || servings > 100) {
      throw const FormatException('Il numero di porzioni non è valido.');
    }
    if (ingredients.isEmpty) {
      throw const FormatException('Aggiungi almeno un ingrediente.');
    }

    var total = const Nutrients.zero();
    for (final ingredient in ingredients) {
      ingredient.validate();
      final nextTotal =
          total +
          NutritionCalculator.scale(
            per100g: ingredient.per100g,
            grams: ingredient.grams,
          );
      if (!nextTotal.isValid) {
        throw const FormatException(
          'I valori della ricetta sono troppo grandi.',
        );
      }
      total = nextTotal;
    }
    final divisor = servings.toDouble();
    return RecipeNutrition(
      total: total,
      perServing: Nutrients(
        calories: total.calories / divisor,
        protein: total.protein / divisor,
        carbs: total.carbs / divisor,
        fat: total.fat / divisor,
      ),
    );
  }
}

class FitRecipeSummary {
  const FitRecipeSummary({
    required this.id,
    required this.name,
    required this.servings,
    required this.prepMinutes,
    required this.isFavorite,
    required this.nutrition,
    required this.updatedAt,
    this.description,
    this.tags = const <String>[],
  });

  final String id;
  final String name;
  final String? description;
  final List<String> tags;
  final int servings;
  final int prepMinutes;
  final bool isFavorite;
  final RecipeNutrition nutrition;
  final DateTime updatedAt;
}

class FitRecipeDetails {
  const FitRecipeDetails({
    required this.summary,
    required this.ingredients,
    this.instructions,
  });

  final FitRecipeSummary summary;
  final String? instructions;
  final List<RecipeIngredientDraft> ingredients;
}
