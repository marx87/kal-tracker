/// I numeri del piano li calcola SEMPRE l'app.
///
/// Il pianificatore sceglie solo ricetta e porzioni: kcal e macro di uno slot
/// escono da qui, dai valori reali della ricetta moltiplicati per le porzioni,
/// passando per `NutritionCalculator` come ogni altro numero dell'app.
library;

import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';

/// Base di calcolo di UNA porzione di ricetta: grammi e valori per 100 g.
///
/// È la stessa conversione usata dal dettaglio ricetta quando si aggiunge una
/// porzione al diario: il diario ragiona in grammi + per-100 g, la ricetta in
/// porzioni. Serve quindi sia per mostrare i numeri sia per scrivere la voce.
class PlanServingBasis {
  const PlanServingBasis({required this.servingGrams, required this.per100g});

  factory PlanServingBasis.of(FitRecipeDetails details) {
    final totalGrams = details.ingredients.fold<double>(
      0,
      (total, ingredient) => total + ingredient.grams,
    );
    final servings = details.summary.servings;
    if (totalGrams <= 0 || servings <= 0) {
      throw const FormatException(
        'Questa ricetta non ha ingredienti: non posso calcolarne la porzione.',
      );
    }
    final servingGrams = totalGrams / servings;
    final perServing = details.summary.nutrition.perServing;
    final per100Factor = 100 / servingGrams;
    return PlanServingBasis(
      servingGrams: servingGrams,
      per100g: Nutrients(
        calories: perServing.calories * per100Factor,
        protein: perServing.protein * per100Factor,
        carbs: perServing.carbs * per100Factor,
        fat: perServing.fat * per100Factor,
      ),
    );
  }

  final double servingGrams;
  final Nutrients per100g;

  double gramsFor(double servings) => servingGrams * servings;

  Nutrients nutrientsFor(double servings) =>
      NutritionCalculator.scale(per100g: per100g, grams: gramsFor(servings));
}

abstract final class PlanNutrition {
  /// Valori di uno slot: porzioni reali della ricetta, mai numeri del modello.
  ///
  /// `NutritionCalculator.scale` moltiplica per `grammi / 100`: passando
  /// `porzioni * 100` grammi il fattore diventa esattamente il numero di
  /// porzioni, così anche questo conto passa dall'unica formula dell'app.
  static Nutrients forServings({
    required Nutrients perServing,
    required double servings,
  }) => NutritionCalculator.scale(per100g: perServing, grams: servings * 100);

  static Nutrients sum(Iterable<Nutrients> values) =>
      values.fold(const Nutrients.zero(), (total, value) => total + value);
}
