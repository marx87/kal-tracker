import 'dart:math' as math;

import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';

class RemainingMacros {
  const RemainingMacros({
    required this.calories,
    required this.protein,
    required this.carbs,
    required this.fat,
  });

  const RemainingMacros.zero() : calories = 0, protein = 0, carbs = 0, fat = 0;

  factory RemainingMacros.between({
    required Nutrients goal,
    required Nutrients eaten,
  }) => RemainingMacros(
    calories: goal.calories - eaten.calories,
    protein: goal.protein - eaten.protein,
    carbs: goal.carbs - eaten.carbs,
    fat: goal.fat - eaten.fat,
  );

  final double calories;
  final double protein;
  final double carbs;
  final double fat;
}

class RecipeSuggestion {
  const RecipeSuggestion({
    required this.recipe,
    required this.score,
    required this.fitsCalories,
  });

  final FitRecipeSummary recipe;
  final double score;
  final bool fitsCalories;
}

abstract final class RecipeSuggestionEngine {
  static const double calorieTolerance = 0.1;

  /// Punteggio (più basso = più adatta): sforamento calorico pesato 3, calorie
  /// lasciate libere 0,5, proteine mancanti non coperte 1, sforamento di
  /// carboidrati e grassi 0,5; chi supera le calorie rimanenti oltre il 10%
  /// finisce comunque dopo tutte le ricette compatibili.
  static List<RecipeSuggestion> rank({
    required RemainingMacros remaining,
    required List<FitRecipeSummary> recipes,
  }) {
    final calories = _available(remaining.calories);
    final protein = _available(remaining.protein);
    final carbs = _available(remaining.carbs);
    final fat = _available(remaining.fat);
    final ceiling = calories * (1 + calorieTolerance);

    final suggestions = <RecipeSuggestion>[];
    for (final recipe in recipes) {
      final serving = recipe.nutrition.perServing;
      if (!serving.isValid) {
        continue;
      }
      final score =
          3 * _over(serving.calories, calories) +
          0.5 * _under(serving.calories, calories) +
          _under(serving.protein, protein) +
          0.5 * (_over(serving.carbs, carbs) + _over(serving.fat, fat));
      suggestions.add(
        RecipeSuggestion(
          recipe: recipe,
          score: score,
          fitsCalories: serving.calories <= ceiling,
        ),
      );
    }

    suggestions.sort((first, second) {
      if (first.fitsCalories != second.fitsCalories) {
        return first.fitsCalories ? -1 : 1;
      }
      final byScore = first.score.compareTo(second.score);
      if (byScore != 0) {
        return byScore;
      }
      final byName = first.recipe.name.toLowerCase().compareTo(
        second.recipe.name.toLowerCase(),
      );
      return byName != 0 ? byName : first.recipe.id.compareTo(second.recipe.id);
    });
    return suggestions.toList(growable: false);
  }

  static double _available(double value) =>
      value.isFinite && value > 0 ? value : 0;

  static double _over(double value, double limit) =>
      value <= limit ? 0 : (value - limit) / math.max(limit, 1);

  static double _under(double value, double limit) =>
      value >= limit ? 0 : (limit - value) / math.max(limit, 1);
}
