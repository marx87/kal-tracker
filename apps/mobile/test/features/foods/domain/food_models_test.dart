import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/foods/domain/food_models.dart';

void main() {
  group('AtwaterCalculator', () {
    test('non segnala valori coerenti con i fattori di Atwater', () {
      final check = AtwaterCalculator.check(
        const Nutrients(calories: 63, protein: 11, carbs: 4, fat: 0.2),
      );

      expect(check.estimatedCalories, closeTo(61.8, 0.0001));
      expect(check.deviation, lessThan(AtwaterCheck.tolerance));
      expect(check.isSuspicious, isFalse);
      expect(check.warning, isNull);
    });

    test('accetta uno scostamento esattamente del 20 per cento', () {
      final check = AtwaterCalculator.check(
        const Nutrients(calories: 120, protein: 10, carbs: 15, fat: 0),
      );

      expect(check.estimatedCalories, closeTo(100, 0.0001));
      expect(check.deviation, closeTo(0.2, 0.0001));
      expect(check.isSuspicious, isFalse);
    });

    test('segnala le calorie fuori soglia senza bloccare', () {
      final check = AtwaterCalculator.check(
        const Nutrients(calories: 250, protein: 11, carbs: 4, fat: 0.2),
      );

      expect(check.isSuspicious, isTrue);
      expect(check.warning, contains('250 kcal'));
      expect(check.warning, contains('62 kcal'));
    });

    test('segnala le calorie dichiarate senza macronutrienti', () {
      final zeroMacros = AtwaterCalculator.check(
        const Nutrients(calories: 40, protein: 0, carbs: 0, fat: 0),
      );
      final water = AtwaterCalculator.check(const Nutrients.zero());

      expect(zeroMacros.isSuspicious, isTrue);
      expect(water.isSuspicious, isFalse);
    });

    test('rifiuta nutrienti non validi', () {
      expect(
        () => AtwaterCalculator.check(
          const Nutrients(calories: 100, protein: -1, carbs: 0, fat: 0),
        ),
        throwsFormatException,
      );
    });
  });

  group('FoodDraft', () {
    test('accetta un alimento completo', () {
      const draft = FoodDraft(
        name: 'Skyr Milbona',
        brand: 'Lidl',
        barcode: '4056489123456',
        per100g: Nutrients(calories: 63, protein: 11, carbs: 4, fat: 0.2),
        defaultServingGrams: 150,
      );

      expect(draft.validate, returnsNormally);
    });

    test('rifiuta un codice a barre non numerico', () {
      const draft = FoodDraft(
        name: 'Skyr Milbona',
        barcode: 'ABC-123',
        per100g: Nutrients(calories: 63, protein: 11, carbs: 4, fat: 0.2),
      );

      expect(draft.validate, throwsFormatException);
    });

    test('rifiuta una porzione non positiva', () {
      const draft = FoodDraft(
        name: 'Skyr Milbona',
        per100g: Nutrients(calories: 63, protein: 11, carbs: 4, fat: 0.2),
        defaultServingGrams: 0,
      );

      expect(draft.validate, throwsFormatException);
    });
  });
}
