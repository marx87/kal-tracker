import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';
import 'package:kal_tracker/features/weekly_plan/domain/shopping_departments.dart';
import 'package:kal_tracker/features/weekly_plan/domain/shopping_list_builder.dart';
import 'package:kal_tracker/features/weekly_plan/domain/weekly_plan_models.dart';

void main() {
  group('somma degli ingredienti', () {
    test('lo stesso alimento in tre ricette diverse finisce su una riga', () {
      // 300 g su 2 porzioni × 1 porzione   = 150 g
      // 400 g su 4 porzioni × 2 porzioni   = 200 g
      //  50 g su 1 porzione  × 0,5 porzioni =  25 g
      final recipes = {
        'r1': _recipe(
          id: 'r1',
          name: 'Pasta al pomodoro',
          servings: 2,
          ingredients: [('Pomodori', 300), ('Pasta', 160)],
        ),
        'r2': _recipe(
          id: 'r2',
          name: 'Zuppa',
          servings: 4,
          ingredients: [('Pomodori', 400)],
        ),
        'r3': _recipe(
          id: 'r3',
          name: 'Bruschetta',
          servings: 1,
          ingredients: [('Pomodoro', 50)],
        ),
      };
      final plan = _plan([
        _slot(day: 5, meal: PlanMeal.pranzo, recipeId: 'r1', servings: 1),
        _slot(day: 6, meal: PlanMeal.cena, recipeId: 'r2', servings: 2),
        _slot(day: 7, meal: PlanMeal.spuntino, recipeId: 'r3', servings: 0.5),
      ]);

      final list = ShoppingListBuilder.build(plan: plan, recipes: recipes);
      final tomatoes = _item(list, 'pomodoro');

      expect(tomatoes.grams, closeTo(375, 0.001));
      expect(tomatoes.quantity.display, '400 g');
      // La grafia mostrata è quella usata più spesso nel piano.
      expect(tomatoes.label, 'Pomodori');
      expect(tomatoes.recipeNames, [
        'Bruschetta',
        'Pasta al pomodoro',
        'Zuppa',
      ]);
    });

    test('le porzioni frazionarie scalano tutto', () {
      final recipes = {
        'r1': _recipe(
          id: 'r1',
          name: 'Bowl',
          servings: 2,
          ingredients: [('Riso basmati', 200), ('Petto di pollo', 300)],
        ),
      };
      final plan = _plan([
        _slot(day: 5, meal: PlanMeal.pranzo, recipeId: 'r1', servings: 0.5),
      ]);

      final list = ShoppingListBuilder.build(plan: plan, recipes: recipes);

      expect(_item(list, 'riso basmati').grams, closeTo(50, 0.001));
      expect(_item(list, 'petto pollo').grams, closeTo(75, 0.001));
    });

    test('un ingrediente con zero grammi o senza nome non entra in lista', () {
      // Riga storta arrivata da un import vecchio: la spesa la salta invece
      // di mostrare «0 g» o una voce senza nome.
      const per100g = Nutrients(calories: 100, protein: 10, carbs: 10, fat: 2);
      final details = FitRecipeDetails(
        summary: FitRecipeSummary(
          id: 'r1',
          name: 'Insalatona',
          servings: 1,
          prepMinutes: 5,
          isFavorite: false,
          nutrition: const RecipeNutrition(
            total: Nutrients.zero(),
            perServing: Nutrients.zero(),
          ),
          updatedAt: DateTime.utc(2026, 8, 1),
        ),
        ingredients: const [
          RecipeIngredientDraft(name: 'Sale', grams: 0, per100g: per100g),
          RecipeIngredientDraft(name: '***', grams: 10, per100g: per100g),
          RecipeIngredientDraft(name: 'Insalata', grams: 100, per100g: per100g),
        ],
      );
      final plan = _plan([
        _slot(day: 5, meal: PlanMeal.cena, recipeId: 'r1', servings: 1),
      ]);

      final list = ShoppingListBuilder.build(
        plan: plan,
        recipes: {'r1': details},
      );

      expect(list.itemCount, 1);
      expect(list.items.single.label, 'Insalata');
    });
  });

  group('slot già segnati "Fatto"', () {
    test('restano in lista, marcati come già cucinati', () {
      final recipes = {
        'r1': _recipe(
          id: 'r1',
          name: 'Frittata',
          servings: 1,
          ingredients: [('Uova', 120)],
        ),
      };
      final plan = _plan([
        _slot(
          day: 5,
          meal: PlanMeal.cena,
          recipeId: 'r1',
          servings: 1,
          doneAt: DateTime.utc(2026, 8, 5, 20),
        ),
      ]);

      final list = ShoppingListBuilder.build(plan: plan, recipes: recipes);
      final eggs = _item(list, 'uovo');

      expect(eggs.grams, closeTo(120, 0.001));
      expect(eggs.usedGrams, closeTo(120, 0.001));
      expect(eggs.isFullyUsed, isTrue);
      expect(eggs.isPartlyUsed, isFalse);
      expect(eggs.quantity.display, '2 uova');
    });

    test('se solo una parte è cucinata la riga lo dice', () {
      final recipes = {
        'r1': _recipe(
          id: 'r1',
          name: 'Frittata',
          servings: 1,
          ingredients: [('Uova', 120)],
        ),
      };
      final plan = _plan([
        _slot(
          day: 5,
          meal: PlanMeal.cena,
          recipeId: 'r1',
          servings: 1,
          doneAt: DateTime.utc(2026, 8, 5, 20),
        ),
        _slot(day: 6, meal: PlanMeal.cena, recipeId: 'r1', servings: 1),
      ]);

      final list = ShoppingListBuilder.build(plan: plan, recipes: recipes);
      final eggs = _item(list, 'uovo');

      expect(eggs.grams, closeTo(240, 0.001));
      expect(eggs.usedGrams, closeTo(120, 0.001));
      expect(eggs.isFullyUsed, isFalse);
      expect(eggs.isPartlyUsed, isTrue);
    });
  });

  group('ricette non più disponibili', () {
    test('non si inventano ingredienti: si dichiara la ricetta mancante', () {
      final recipes = {
        'r1': _recipe(
          id: 'r1',
          name: 'Bowl',
          servings: 1,
          ingredients: [('Riso basmati', 80)],
        ),
      };
      final plan = _plan([
        _slot(day: 5, meal: PlanMeal.pranzo, recipeId: 'r1', servings: 1),
        // Ricetta cancellata dopo la generazione: il tombstone azzera l'id.
        _slot(
          day: 6,
          meal: PlanMeal.cena,
          recipeId: null,
          recipeName: 'Torta salata',
          servings: 1,
        ),
        // Ricetta ancora referenziata ma non più leggibile.
        _slot(
          day: 7,
          meal: PlanMeal.cena,
          recipeId: 'sparita',
          recipeName: 'Vellutata',
          servings: 1,
        ),
      ]);

      final list = ShoppingListBuilder.build(plan: plan, recipes: recipes);

      expect(list.itemCount, 1);
      expect(list.unavailableRecipes, ['Torta salata', 'Vellutata']);
    });

    test('la stessa ricetta mancante si dichiara una volta sola', () {
      final plan = _plan([
        _slot(
          day: 5,
          meal: PlanMeal.pranzo,
          recipeId: null,
          recipeName: 'Torta salata',
          servings: 1,
        ),
        _slot(
          day: 6,
          meal: PlanMeal.cena,
          recipeId: null,
          recipeName: 'Torta salata',
          servings: 2,
        ),
      ]);

      final list = ShoppingListBuilder.build(
        plan: plan,
        recipes: const <String, FitRecipeDetails>{},
      );

      expect(list.unavailableRecipes, ['Torta salata']);
      expect(list.isEmpty, isTrue);
    });
  });

  group('reparti', () {
    test('i gruppi seguono l’ordine del giro fra i banchi', () {
      final recipes = {
        'r1': _recipe(
          id: 'r1',
          name: 'Cena completa',
          servings: 1,
          ingredients: [
            ('Riso basmati', 80),
            ('Petto di pollo', 150),
            ('Zucchine', 200),
            ('Yogurt greco', 125),
            ('Piselli surgelati', 100),
          ],
        ),
      };
      final plan = _plan([
        _slot(day: 5, meal: PlanMeal.cena, recipeId: 'r1', servings: 1),
      ]);

      final list = ShoppingListBuilder.build(plan: plan, recipes: recipes);

      expect(list.departments.map((group) => group.department), [
        ShoppingDepartment.ortofrutta,
        ShoppingDepartment.macelleria,
        ShoppingDepartment.bancoFrigo,
        ShoppingDepartment.dispensa,
        ShoppingDepartment.surgelati,
      ]);
      expect(list.itemCount, 5);
    });

    test('dentro il reparto le voci sono in ordine alfabetico', () {
      final recipes = {
        'r1': _recipe(
          id: 'r1',
          name: 'Verdure miste',
          servings: 1,
          ingredients: [('Zucchine', 100), ('Carote', 100), ('Melanzane', 100)],
        ),
      };
      final plan = _plan([
        _slot(day: 5, meal: PlanMeal.cena, recipeId: 'r1', servings: 1),
      ]);

      final list = ShoppingListBuilder.build(plan: plan, recipes: recipes);

      expect(list.departments.single.items.map((item) => item.label), [
        'Carote',
        'Melanzane',
        'Zucchine',
      ]);
    });
  });

  group('conteggio delle spunte', () {
    test('le spunte appese a voci sparite non contano', () {
      final recipes = {
        'r1': _recipe(
          id: 'r1',
          name: 'Bowl',
          servings: 1,
          ingredients: [('Riso basmati', 80), ('Zucchine', 100)],
        ),
      };
      final plan = _plan([
        _slot(day: 5, meal: PlanMeal.pranzo, recipeId: 'r1', servings: 1),
      ]);

      final list = ShoppingListBuilder.build(plan: plan, recipes: recipes);

      expect(list.checkedCount({'riso basmati', 'roba che non c e piu'}), 1);
      expect(list.checkedCount(const <String>{}), 0);
      expect(list.itemCount, 2);
    });
  });

  group('intestazione', () {
    test('la lista conserva piano, inizio e durata', () {
      final list = ShoppingListBuilder.build(
        plan: _plan(const []),
        recipes: const <String, FitRecipeDetails>{},
      );

      expect(list.planId, 'plan-1');
      expect(list.startDate, DateTime.utc(2026, 8, 5));
      expect(list.days, 3);
      expect(list.endDate, DateTime.utc(2026, 8, 7));
    });
  });
}

ShoppingListItem _item(ShoppingList list, String key) =>
    list.items.firstWhere((item) => item.key == key);

WeeklyPlan _plan(List<WeeklyPlanSlot> slots) => WeeklyPlan(
  id: 'plan-1',
  startDate: DateTime.utc(2026, 8, 5),
  days: 3,
  meals: PlanMeal.values,
  status: WeeklyPlanStatus.ready,
  slots: slots,
);

WeeklyPlanSlot _slot({
  required int day,
  required PlanMeal meal,
  required String? recipeId,
  required double servings,
  String recipeName = 'Ricetta',
  DateTime? doneAt,
}) => WeeklyPlanSlot(
  id: 'slot-$day-${meal.storageValue}',
  date: DateTime.utc(2026, 8, day),
  meal: meal,
  recipeId: recipeId,
  recipeName: recipeName,
  servings: servings,
  doneAt: doneAt,
);

FitRecipeDetails _recipe({
  required String id,
  required String name,
  required int servings,
  required List<(String, double)> ingredients,
}) {
  final drafts = [
    for (final (ingredientName, grams) in ingredients)
      RecipeIngredientDraft(
        name: ingredientName,
        grams: grams,
        per100g: const Nutrients(calories: 100, protein: 10, carbs: 10, fat: 2),
      ),
  ];
  return FitRecipeDetails(
    summary: FitRecipeSummary(
      id: id,
      name: name,
      servings: servings,
      prepMinutes: 15,
      isFavorite: false,
      nutrition: RecipeNutritionCalculator.calculate(
        ingredients: drafts,
        servings: servings,
      ),
      updatedAt: DateTime.utc(2026, 8, 1),
    ),
    ingredients: drafts,
  );
}
