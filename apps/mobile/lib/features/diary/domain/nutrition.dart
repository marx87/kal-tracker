class Nutrients {
  const Nutrients({
    required this.calories,
    required this.protein,
    required this.carbs,
    required this.fat,
  });

  const Nutrients.zero() : calories = 0, protein = 0, carbs = 0, fat = 0;

  final double calories;
  final double protein;
  final double carbs;
  final double fat;

  bool get isValid =>
      calories.isFinite &&
      calories >= 0 &&
      protein.isFinite &&
      protein >= 0 &&
      carbs.isFinite &&
      carbs >= 0 &&
      fat.isFinite &&
      fat >= 0;

  Nutrients operator +(Nutrients other) => Nutrients(
    calories: calories + other.calories,
    protein: protein + other.protein,
    carbs: carbs + other.carbs,
    fat: fat + other.fat,
  );
}

abstract final class NutritionCalculator {
  static Nutrients scale({required Nutrients per100g, required double grams}) {
    if (!per100g.isValid) {
      throw const FormatException('I nutrienti devono essere valori positivi.');
    }
    if (!grams.isFinite || grams <= 0) {
      throw const FormatException('I grammi devono essere maggiori di zero.');
    }

    final factor = grams / 100;
    final result = Nutrients(
      calories: per100g.calories * factor,
      protein: per100g.protein * factor,
      carbs: per100g.carbs * factor,
      fat: per100g.fat * factor,
    );
    if (!result.isValid) {
      throw const FormatException('I valori calcolati sono troppo grandi.');
    }
    return result;
  }
}
