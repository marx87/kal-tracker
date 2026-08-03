class NutritionTarget {
  const NutritionTarget({
    required this.calories,
    required this.protein,
    required this.carbs,
    required this.fat,
  });

  const NutritionTarget.standard()
    : calories = 2000,
      protein = 120,
      carbs = 230,
      fat = 65;

  final double calories;
  final double protein;
  final double carbs;
  final double fat;

  void validate() {
    if (!calories.isFinite || calories <= 0) {
      throw const FormatException(
        'L’obiettivo calorico deve essere maggiore di zero.',
      );
    }
    if (![protein, carbs, fat].every((value) => value.isFinite && value >= 0)) {
      throw const FormatException(
        'Gli obiettivi dei macronutrienti non possono essere negativi.',
      );
    }
  }
}
