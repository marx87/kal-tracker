import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';

void main() {
  test('calcola totale e valori per porzione in modo deterministico', () {
    const ingredients = [
      RecipeIngredientDraft(
        name: 'Avena',
        grams: 100,
        per100g: Nutrients(calories: 389, protein: 16.9, carbs: 66.3, fat: 6.9),
      ),
      RecipeIngredientDraft(
        name: 'Yogurt',
        grams: 200,
        per100g: Nutrients(calories: 59, protein: 10.3, carbs: 3.6, fat: 0.4),
      ),
    ];

    final result = RecipeNutritionCalculator.calculate(
      ingredients: ingredients,
      servings: 2,
    );

    expect(result.total.calories, closeTo(507, 0.0001));
    expect(result.total.protein, closeTo(37.5, 0.0001));
    expect(result.perServing.calories, closeTo(253.5, 0.0001));
    expect(result.perServing.carbs, closeTo(36.75, 0.0001));
  });

  test('rifiuta ricette senza ingredienti o porzioni', () {
    expect(
      () => RecipeNutritionCalculator.calculate(
        ingredients: const [],
        servings: 1,
      ),
      throwsFormatException,
    );
    expect(
      () => RecipeNutritionCalculator.calculate(
        ingredients: const [
          RecipeIngredientDraft(
            name: 'Mela',
            grams: 100,
            per100g: Nutrients(calories: 52, protein: 0.3, carbs: 14, fat: 0.2),
          ),
        ],
        servings: 0,
      ),
      throwsFormatException,
    );
  });

  test('rifiuta testi fuori limite e somme non finite', () {
    expect(
      () => FitRecipeDraft(
        name: 'Troppo descritta',
        description: 'x' * 601,
        servings: 1,
        ingredients: const [
          RecipeIngredientDraft(
            name: 'Mela',
            grams: 100,
            per100g: Nutrients(calories: 52, protein: 0.3, carbs: 14, fat: 0.2),
          ),
        ],
      ).validate(),
      throwsFormatException,
    );
    expect(
      () => RecipeNutritionCalculator.calculate(
        servings: 1,
        ingredients: const [
          RecipeIngredientDraft(
            name: 'Grande uno',
            grams: 100,
            per100g: Nutrients(
              calories: double.maxFinite,
              protein: 0,
              carbs: 0,
              fat: 0,
            ),
          ),
          RecipeIngredientDraft(
            name: 'Grande due',
            grams: 100,
            per100g: Nutrients(
              calories: double.maxFinite,
              protein: 0,
              carbs: 0,
              fat: 0,
            ),
          ),
        ],
      ),
      throwsFormatException,
    );
  });

  group('RecipeTags', () {
    test('normalizza minuscolo, spazi doppi, cancelletti e duplicati', () {
      expect(
        RecipeTags.normalize([
          '  Pranzo  ',
          '#PROTEICO',
          'senza   glutine',
          'pranzo',
          '   ',
          'post, allenamento',
        ]),
        ['pranzo', 'proteico', 'senza glutine', 'post allenamento'],
      );
    });

    test('legge e riscrive il CSV della colonna tags', () {
      expect(RecipeTags.parse(null), isEmpty);
      expect(RecipeTags.parse('   '), isEmpty);
      expect(RecipeTags.parse('Cena, veloce ,cena'), ['cena', 'veloce']);
      expect(RecipeTags.encode(const []), isNull);
      expect(RecipeTags.encode(const ['Cena', ' veloce']), 'cena,veloce');
      expect(RecipeTags.encode(RecipeTags.parse('cena,veloce')), 'cena,veloce');
    });

    test('rifiuta più di otto tag o un tag troppo lungo', () {
      const ingredients = [
        RecipeIngredientDraft(
          name: 'Mela',
          grams: 100,
          per100g: Nutrients(calories: 52, protein: 0.3, carbs: 14, fat: 0.2),
        ),
      ];
      expect(
        () => const FitRecipeDraft(
          name: 'Troppi tag',
          servings: 1,
          tags: ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i'],
          ingredients: ingredients,
        ).validate(),
        throwsFormatException,
      );
      expect(
        () => FitRecipeDraft(
          name: 'Tag lunghissimo',
          servings: 1,
          tags: ['t' * 25],
          ingredients: ingredients,
        ).validate(),
        throwsFormatException,
      );
      expect(
        () => const FitRecipeDraft(
          name: 'Otto tag esatti',
          servings: 1,
          tags: ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'],
          ingredients: ingredients,
        ).validate(),
        returnsNormally,
      );
    });
  });
}
