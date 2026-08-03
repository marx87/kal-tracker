import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';

void main() {
  group('NutritionCalculator', () {
    test('scala i nutrienti in base ai grammi', () {
      final result = NutritionCalculator.scale(
        per100g: const Nutrients(
          calories: 130,
          protein: 2.7,
          carbs: 28,
          fat: 0.3,
        ),
        grams: 150,
      );

      expect(result.calories, closeTo(195, 0.0001));
      expect(result.protein, closeTo(4.05, 0.0001));
      expect(result.carbs, closeTo(42, 0.0001));
      expect(result.fat, closeTo(0.45, 0.0001));
    });

    test('rifiuta quantità nulle o negative', () {
      expect(
        () => NutritionCalculator.scale(
          per100g: const Nutrients.zero(),
          grams: 0,
        ),
        throwsFormatException,
      );
      expect(
        () => NutritionCalculator.scale(
          per100g: const Nutrients.zero(),
          grams: -20,
        ),
        throwsFormatException,
      );
    });

    test('rifiuta nutrienti negativi o non finiti', () {
      expect(
        () => NutritionCalculator.scale(
          per100g: const Nutrients(
            calories: double.nan,
            protein: 1,
            carbs: 1,
            fat: 1,
          ),
          grams: 100,
        ),
        throwsFormatException,
      );
      expect(
        () => NutritionCalculator.scale(
          per100g: const Nutrients(
            calories: 100,
            protein: -1,
            carbs: 1,
            fat: 1,
          ),
          grams: 100,
        ),
        throwsFormatException,
      );
    });

    test('rifiuta un risultato che va in overflow', () {
      expect(
        () => NutritionCalculator.scale(
          per100g: const Nutrients(
            calories: 1e308,
            protein: 1,
            carbs: 1,
            fat: 1,
          ),
          grams: 1000,
        ),
        throwsFormatException,
      );
    });
  });
}
