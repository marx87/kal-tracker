import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';

class MealTemplateItem {
  const MealTemplateItem({
    required this.foodName,
    required this.grams,
    required this.per100g,
  });

  final String foodName;
  final double grams;
  final Nutrients per100g;

  Nutrients get nutrients =>
      NutritionCalculator.scale(per100g: per100g, grams: grams);

  void validate() {
    if (foodName.trim().isEmpty) {
      throw const FormatException('Inserisci il nome dell’alimento.');
    }
    if (foodName.trim().length > 160) {
      throw const FormatException('Il nome dell’alimento è troppo lungo.');
    }
    NutritionCalculator.scale(per100g: per100g, grams: grams);
  }
}

class MealTemplate {
  const MealTemplate({
    required this.id,
    required this.name,
    required this.mealType,
    required this.items,
    required this.totals,
    required this.updatedAt,
  });

  factory MealTemplate.fromItems({
    required String id,
    required String name,
    required MealType mealType,
    required List<MealTemplateItem> items,
    required DateTime updatedAt,
  }) {
    final totals = items.fold<Nutrients>(
      const Nutrients.zero(),
      (sum, item) => sum + item.nutrients,
    );
    return MealTemplate(
      id: id,
      name: name,
      mealType: mealType,
      items: List.unmodifiable(items),
      totals: totals,
      updatedAt: updatedAt,
    );
  }

  static String normalizeName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Dai un nome al modello.');
    }
    if (trimmed.length > 80) {
      throw const FormatException('Il nome del modello è troppo lungo.');
    }
    return trimmed;
  }

  final String id;
  final String name;
  final MealType mealType;
  final List<MealTemplateItem> items;
  final Nutrients totals;
  final DateTime updatedAt;
}
