import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';
import 'package:kal_tracker/features/weekly_plan/domain/shopping_list_builder.dart';
import 'package:kal_tracker/features/weekly_plan/domain/shopping_list_text.dart';
import 'package:kal_tracker/features/weekly_plan/domain/weekly_plan_models.dart';

void main() {
  test('la lista si copia come testo leggibile', () {
    final list = _list();

    final text = ShoppingListText.format(list, checkedKeys: {'zucchina'});

    expect(text, '''
Lista della spesa
5 - 7 agosto 2026

ORTOFRUTTA
[x] Zucchine — 200 g

MACELLERIA
[ ] Petto di pollo — 150 g

BANCO FRIGO E LATTICINI
[ ] Uova — 2 uova (≈ 120 g)

DISPENSA
[ ] Olio extravergine di oliva — 2 cucchiai (≈ 20 g)

Presi 1 di 4.''');
  });

  test('senza spunte il conteggio parte da zero', () {
    expect(ShoppingListText.format(_list()), contains('Presi 0 di 4.'));
  });

  test('gli slot già cucinati sono marcati anche nel testo', () {
    final text = ShoppingListText.format(_list(done: true));

    expect(text, contains('[ ] Zucchine — 200 g · già cucinato'));
  });

  test('le ricette sparite si dichiarano in fondo', () {
    final list = ShoppingListBuilder.build(
      plan: _plan(const [], missing: 'Torta salata'),
      recipes: const <String, FitRecipeDetails>{},
    );

    final text = ShoppingListText.format(list);

    expect(text, contains('Non c’è niente da comprare.'));
    expect(text, contains('Torta salata'));
  });

  group('intervallo di date', () {
    test('stesso mese', () {
      expect(
        ShoppingListText.dateRange(_emptyList(DateTime.utc(2026, 8, 5), 3)),
        '5 - 7 agosto 2026',
      );
    });

    test('a cavallo di due mesi', () {
      expect(
        ShoppingListText.dateRange(_emptyList(DateTime.utc(2026, 7, 28), 7)),
        '28 luglio - 3 agosto 2026',
      );
    });

    test('a cavallo di due anni', () {
      expect(
        ShoppingListText.dateRange(_emptyList(DateTime.utc(2026, 12, 30), 4)),
        '30 dicembre 2026 - 2 gennaio 2027',
      );
    });
  });
}

ShoppingList _emptyList(DateTime startDate, int days) => ShoppingList(
  planId: 'plan-1',
  startDate: startDate,
  days: days,
  departments: const [],
);

ShoppingList _list({bool done = false}) => ShoppingListBuilder.build(
  plan: _plan([
    WeeklyPlanSlot(
      id: 'slot-1',
      date: DateTime.utc(2026, 8, 5),
      meal: PlanMeal.cena,
      recipeId: 'r1',
      recipeName: 'Cena completa',
      servings: 1,
      doneAt: done ? DateTime.utc(2026, 8, 5, 20) : null,
    ),
  ]),
  recipes: {'r1': _recipe()},
);

WeeklyPlan _plan(List<WeeklyPlanSlot> slots, {String? missing}) => WeeklyPlan(
  id: 'plan-1',
  startDate: DateTime.utc(2026, 8, 5),
  days: 3,
  meals: PlanMeal.values,
  status: WeeklyPlanStatus.ready,
  slots: [
    ...slots,
    if (missing != null)
      WeeklyPlanSlot(
        id: 'slot-mancante',
        date: DateTime.utc(2026, 8, 6),
        meal: PlanMeal.pranzo,
        recipeName: missing,
        servings: 1,
      ),
  ],
);

FitRecipeDetails _recipe() {
  const per100g = Nutrients(calories: 100, protein: 10, carbs: 10, fat: 2);
  const ingredients = [
    RecipeIngredientDraft(name: 'Zucchine', grams: 200, per100g: per100g),
    RecipeIngredientDraft(name: 'Petto di pollo', grams: 150, per100g: per100g),
    RecipeIngredientDraft(name: 'Uova', grams: 120, per100g: per100g),
    RecipeIngredientDraft(
      name: 'Olio extravergine di oliva',
      grams: 20,
      per100g: per100g,
    ),
  ];
  return FitRecipeDetails(
    summary: FitRecipeSummary(
      id: 'r1',
      name: 'Cena completa',
      servings: 1,
      prepMinutes: 20,
      isFavorite: false,
      nutrition: RecipeNutritionCalculator.calculate(
        ingredients: ingredients,
        servings: 1,
      ),
      updatedAt: DateTime.utc(2026, 8, 1),
    ),
    ingredients: ingredients,
  );
}
