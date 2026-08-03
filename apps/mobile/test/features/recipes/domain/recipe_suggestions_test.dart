import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_suggestions.dart';

FitRecipeSummary _recipe({
  required String name,
  required double calories,
  required double protein,
  double carbs = 0,
  double fat = 0,
  String? id,
}) {
  final perServing = Nutrients(
    calories: calories,
    protein: protein,
    carbs: carbs,
    fat: fat,
  );
  return FitRecipeSummary(
    id: id ?? name,
    name: name,
    servings: 1,
    prepMinutes: 10,
    isFavorite: false,
    nutrition: RecipeNutrition(total: perServing, perServing: perServing),
    updatedAt: DateTime.utc(2026, 8, 3),
  );
}

final _catalog = <FitRecipeSummary>[
  _recipe(name: 'leggera', calories: 300, protein: 20),
  _recipe(name: 'media', calories: 600, protein: 45),
  _recipe(name: 'ricca', calories: 900, protein: 70),
  _recipe(name: 'gigante', calories: 1500, protein: 90),
];

void main() {
  group('RecipeSuggestionEngine', () {
    final cases =
        <({String scenario, RemainingMacros remaining, List<String> order})>[
          (
            scenario: 'giornata ancora aperta: vince chi riempie le calorie',
            remaining: const RemainingMacros(
              calories: 620,
              protein: 45,
              carbs: 0,
              fat: 0,
            ),
            order: ['media', 'leggera', 'ricca', 'gigante'],
          ),
          (
            scenario: 'uno sforamento entro il 10% resta la scelta migliore',
            remaining: const RemainingMacros(
              calories: 550,
              protein: 45,
              carbs: 0,
              fat: 0,
            ),
            order: ['media', 'leggera', 'ricca', 'gigante'],
          ),
          (
            scenario:
                'chi sfora oltre il 10% resta dietro anche con più '
                'proteine',
            remaining: const RemainingMacros(
              calories: 500,
              protein: 80,
              carbs: 0,
              fat: 0,
            ),
            order: ['leggera', 'media', 'ricca', 'gigante'],
          ),
          (
            scenario: 'macro rimanenti a zero: ordina dalla più leggera',
            remaining: const RemainingMacros.zero(),
            order: ['leggera', 'media', 'ricca', 'gigante'],
          ),
          (
            scenario: 'macro rimanenti negativi: si comportano come zero',
            remaining: const RemainingMacros(
              calories: -200,
              protein: -10,
              carbs: -30,
              fat: -5,
            ),
            order: ['leggera', 'media', 'ricca', 'gigante'],
          ),
        ];

    for (final testCase in cases) {
      test(testCase.scenario, () {
        final ranked = RecipeSuggestionEngine.rank(
          remaining: testCase.remaining,
          recipes: _catalog,
        );
        expect(
          ranked.map((suggestion) => suggestion.recipe.name),
          testCase.order,
        );
      });
    }

    test('la prima ricetta non sfora mai oltre il 10% se una ci sta', () {
      final ranked = RecipeSuggestionEngine.rank(
        remaining: const RemainingMacros(
          calories: 500,
          protein: 80,
          carbs: 0,
          fat: 0,
        ),
        recipes: _catalog,
      );

      expect(ranked.first.fitsCalories, isTrue);
      expect(ranked.first.recipe.nutrition.perServing.calories, 300);
      expect(
        ranked
            .where((suggestion) => suggestion.fitsCalories)
            .map((suggestion) => suggestion.recipe.name),
        ['leggera'],
      );
    });

    test('con calorie rimanenti a zero nessuna ricetta è compatibile', () {
      final ranked = RecipeSuggestionEngine.rank(
        remaining: const RemainingMacros.zero(),
        recipes: _catalog,
      );

      expect(ranked, hasLength(4));
      expect(ranked.every((suggestion) => !suggestion.fitsCalories), isTrue);
    });

    test('senza ricette non ci sono suggerimenti', () {
      expect(
        RecipeSuggestionEngine.rank(
          remaining: const RemainingMacros(
            calories: 900,
            protein: 60,
            carbs: 100,
            fat: 30,
          ),
          recipes: const [],
        ),
        isEmpty,
      );
    });

    test('a parità di calorie e proteine penalizza carboidrati e grassi', () {
      final ranked = RecipeSuggestionEngine.rank(
        remaining: const RemainingMacros(
          calories: 500,
          protein: 30,
          carbs: 40,
          fat: 15,
        ),
        recipes: [
          _recipe(
            name: 'zuppa',
            calories: 400,
            protein: 30,
            carbs: 90,
            fat: 14,
          ),
          _recipe(
            name: 'piatto unico',
            calories: 400,
            protein: 30,
            carbs: 35,
            fat: 14,
          ),
        ],
      );

      expect(ranked.map((suggestion) => suggestion.recipe.name), [
        'piatto unico',
        'zuppa',
      ]);
    });

    test('a parità di punteggio ordina per nome e poi per id', () {
      final ranked = RecipeSuggestionEngine.rank(
        remaining: const RemainingMacros(
          calories: 600,
          protein: 40,
          carbs: 0,
          fat: 0,
        ),
        recipes: [
          _recipe(id: 'b', name: 'Bowl', calories: 600, protein: 40),
          _recipe(id: 'a2', name: 'Avena', calories: 600, protein: 40),
          _recipe(id: 'a1', name: 'Avena', calories: 600, protein: 40),
        ],
      );

      expect(ranked.map((suggestion) => suggestion.recipe.id), [
        'a1',
        'a2',
        'b',
      ]);
      expect(ranked.every((suggestion) => suggestion.score == 0), isTrue);
    });
  });
}
