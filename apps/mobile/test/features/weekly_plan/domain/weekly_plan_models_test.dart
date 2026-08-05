import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';
import 'package:kal_tracker/features/targets/domain/nutrition_target.dart';
import 'package:kal_tracker/features/weekly_plan/domain/weekly_plan_models.dart';

PlanRecipeOption _option(String id, String name) => PlanRecipeOption(
  id: id,
  name: name,
  tags: const ['cena'],
  prepMinutes: 25,
  servingKcal: 520,
  servingProtein: 38,
  servingCarbs: 45,
  servingFat: 18,
);

WeeklyPlanRequest _request({
  int days = 2,
  List<PlanMeal> meals = const [PlanMeal.pranzo, PlanMeal.cena],
  String notes = '',
}) => WeeklyPlanRequest(
  startDate: DateTime.utc(2026, 8, 5),
  days: days,
  meals: meals,
  targets: const NutritionTarget(
    calories: 2400,
    protein: 160,
    carbs: 250,
    fat: 80,
  ),
  recipes: [
    _option('recipe-a', 'Bowl pollo e riso'),
    _option('recipe-b', 'Salmone e broccoli'),
  ],
  notes: notes,
);

Map<String, Object?> _slot(
  String meal,
  String recipeId, {
  double servings = 1,
  String? why,
}) => {'meal': meal, 'recipeId': recipeId, 'servings': servings, 'why': ?why};

Map<String, Object?> _result({
  List<Map<String, Object?>>? days,
  String notes = 'Settimana leggera a inizio e più sostanziosa nel weekend.',
}) => {
  'schema': 1,
  'days':
      days ??
      [
        {
          'date': '2026-08-05',
          'slots': [
            _slot('pranzo', 'recipe-a'),
            _slot('cena', 'recipe-b', servings: 1.5, why: 'Proteine alte'),
          ],
        },
        {
          'date': '2026-08-06',
          'slots': [_slot('cena', 'recipe-a', servings: 0.5)],
        },
      ],
  'notes': notes,
};

void main() {
  group('PlanMeal e PlanMeals', () {
    test('la CSV dei pasti torna in ordine canonico e senza doppioni', () {
      expect(
        PlanMeals.encode([PlanMeal.cena, PlanMeal.colazione, PlanMeal.cena]),
        'colazione,cena',
      );
      expect(PlanMeals.parse('cena,colazione'), [
        PlanMeal.colazione,
        PlanMeal.cena,
      ]);
    });

    test('una voce sconosciuta nella CSV viene saltata, non fa esplodere', () {
      expect(PlanMeals.parse('cena,merenda'), [PlanMeal.cena]);
      expect(PlanMeals.parse(null), isEmpty);
      expect(PlanMeals.parse('  '), isEmpty);
    });

    test('ogni pasto conosce il pasto corrispondente del diario', () {
      expect(PlanMeal.colazione.mealType, MealType.breakfast);
      expect(PlanMeal.pranzo.mealType, MealType.lunch);
      expect(PlanMeal.cena.mealType, MealType.dinner);
      expect(PlanMeal.spuntino.mealType, MealType.snack);
    });

    test('fromStorage rifiuta un pasto inventato', () {
      expect(() => PlanMeal.fromStorage('brunch'), throwsFormatException);
    });
  });

  group('PlanDate', () {
    test('formatta e rilegge una data di calendario', () {
      final date = PlanDate.parse('2026-08-05');
      expect(PlanDate.format(date), '2026-08-05');
      expect(PlanDate.format(PlanDate.addDays(date, 27)), '2026-09-01');
    });

    test('rifiuta formati sbagliati e giorni inesistenti', () {
      expect(() => PlanDate.parse('05/08/2026'), throwsFormatException);
      expect(() => PlanDate.parse('2026-02-30'), throwsFormatException);
      expect(() => PlanDate.parse(20260805), throwsFormatException);
    });

    test('normalizza un istante al giorno che è a Roma', () {
      // Le 23:40 di Roma sono ancora il 5, anche dove è già il 6.
      expect(
        PlanDate.format(PlanDate.normalize(DateTime.utc(2026, 8, 5, 21, 40))),
        '2026-08-05',
      );
      // Le 00:20 di Roma sono già il 6, anche dove è ancora il 5.
      expect(
        PlanDate.format(PlanDate.normalize(DateTime.utc(2026, 8, 5, 22, 20))),
        '2026-08-06',
      );
    });

    test('la forma salvata rilegge sempre lo stesso giorno', () {
      // È la forma con cui i giorni finiscono in `weekly_plans.start_date` e
      // `weekly_plan_slots.date`: drift li rilegge come istanti nel fuso del
      // telefono, e rileggerli NON deve spostare il piano di un giorno.
      final stored = PlanDate.parse('2026-08-05');
      expect(PlanDate.format(PlanDate.normalize(stored)), '2026-08-05');
      expect(
        PlanDate.format(
          PlanDate.normalize(
            DateTime.fromMillisecondsSinceEpoch(stored.millisecondsSinceEpoch),
          ),
        ),
        '2026-08-05',
      );
    });
  });

  group('WeeklyPlanRequest', () {
    test('serializza il contratto con lo schema 1 e le date coperte', () {
      final request = _request(notes: '  niente funghi  ');
      final json = request.toJson();

      expect(json['schema'], 1);
      expect(json['days'], 2);
      expect(json['startDate'], '2026-08-05');
      expect(json['meals'], ['pranzo', 'cena']);
      expect(json['notes'], 'niente funghi');
      expect((json['targets']! as Map)['calories'], 2400);
      expect((json['recipes']! as List), hasLength(2));
      expect(request.dates.map(PlanDate.format), ['2026-08-05', '2026-08-06']);
      expect(request.recipeIds, {'recipe-a', 'recipe-b'});
      expect(request.recipeNamesById['recipe-b'], 'Salmone e broccoli');
    });

    test('sopravvive al giro completo su JSON', () {
      final request = WeeklyPlanRequest.fromJson(_request().toJson());

      expect(PlanDate.format(request.startDate), '2026-08-05');
      expect(request.meals, [PlanMeal.pranzo, PlanMeal.cena]);
      expect(request.recipes.first.name, 'Bowl pollo e riso');
      expect(request.recipes.first.tags, ['cena']);
      expect(request.targets.protein, 160);
    });

    test('rifiuta giorni, pasti e catalogo fuori contratto', () {
      expect(() => _request(days: 0).validate(), throwsFormatException);
      expect(() => _request(days: 15).validate(), throwsFormatException);
      expect(() => _request(meals: const []).validate(), throwsFormatException);
      expect(
        () => WeeklyPlanRequest(
          startDate: DateTime.utc(2026, 8, 5),
          days: 2,
          meals: const [PlanMeal.cena],
          targets: const NutritionTarget.standard(),
          recipes: const [],
        ).validate(),
        throwsFormatException,
      );
      expect(
        () => WeeklyPlanRequest(
          startDate: DateTime.utc(2026, 8, 5),
          days: 2,
          meals: const [PlanMeal.cena],
          targets: const NutritionTarget.standard(),
          recipes: [_option('recipe-a', 'Uno'), _option('recipe-a', 'Due')],
        ).validate(),
        throwsFormatException,
      );
    });

    test('i giorni di allenamento viaggiano con la richiesta, in ordine', () {
      final request = WeeklyPlanRequest(
        startDate: DateTime.utc(2026, 8, 5),
        days: 2,
        meals: const [PlanMeal.pranzo, PlanMeal.cena],
        targets: const NutritionTarget.standard(),
        recipes: [_option('recipe-a', 'Bowl pollo e riso')],
        workouts: [
          PlanWorkoutDay(
            date: DateTime.utc(2026, 8, 6),
            name: 'Gambe',
            proteinMeal: PlanMeal.cena,
          ),
          PlanWorkoutDay(date: DateTime.utc(2026, 8, 5), name: 'Spinta'),
        ],
      );

      final workouts = request.toJson()['workouts']! as List;
      expect(workouts, [
        {'date': '2026-08-05', 'name': 'Spinta'},
        {'date': '2026-08-06', 'name': 'Gambe', 'proteinMeal': 'cena'},
      ]);
      // Il giro completo li rilegge identici: la richiesta salvata è il
      // contratto con cui si valida il piano che tornerà.
      final reread = WeeklyPlanRequest.fromJson(request.toJson());
      expect(reread.workouts.map((workout) => workout.name), [
        'Spinta',
        'Gambe',
      ]);
      expect(reread.workouts.last.proteinMeal, PlanMeal.cena);
    });

    test('una richiesta salvata senza allenamenti resta leggibile', () {
      // Le richieste scritte prima del piano unificato non hanno la chiave.
      final payload = _request().toJson()..remove('workouts');

      expect(WeeklyPlanRequest.fromJson(payload).workouts, isEmpty);
    });

    test(
      'rifiuta allenamenti fuori dal piano, doppi o su un pasto assente',
      () {
        WeeklyPlanRequest withWorkouts(List<PlanWorkoutDay> workouts) =>
            WeeklyPlanRequest(
              startDate: DateTime.utc(2026, 8, 5),
              days: 2,
              meals: const [PlanMeal.pranzo, PlanMeal.cena],
              targets: const NutritionTarget.standard(),
              recipes: [_option('recipe-a', 'Bowl pollo e riso')],
              workouts: workouts,
            );

        expect(
          () => withWorkouts([
            PlanWorkoutDay(date: DateTime.utc(2026, 8, 9), name: 'Gambe'),
          ]).validate(),
          throwsFormatException,
          reason: 'un allenamento fuori dai giorni del piano',
        );
        expect(
          () => withWorkouts([
            PlanWorkoutDay(date: DateTime.utc(2026, 8, 5), name: 'Spinta'),
            PlanWorkoutDay(date: DateTime.utc(2026, 8, 5), name: 'Gambe'),
          ]).validate(),
          throwsFormatException,
          reason: 'due allenamenti nello stesso giorno',
        );
        expect(
          () => withWorkouts([
            PlanWorkoutDay(
              date: DateTime.utc(2026, 8, 5),
              name: 'Spinta',
              proteinMeal: PlanMeal.colazione,
            ),
          ]).validate(),
          throwsFormatException,
          reason: 'il pasto dopo l’allenamento non è fra quelli richiesti',
        );
      },
    );

    test('il nome della scheda si aggiusta invece di far fallire il piano', () {
      // È uno scatto preso dal database: vuoto o lunghissimo non deve
      // costare una settimana di pasti.
      expect(
        PlanWorkoutDay(date: DateTime.utc(2026, 8, 5), name: '   ').name,
        'Allenamento',
      );
      expect(
        PlanWorkoutDay(
          date: DateTime.utc(2026, 8, 5),
          name: 'x' * 300,
        ).name.length,
        PlanWorkoutDay.maxNameLength,
      );
    });

    test('una ricetta reale diventa opzione con i valori per porzione', () {
      final summary = FitRecipeSummary(
        id: 'recipe-real',
        name: 'Bowl pollo e riso',
        tags: const ['pranzo'],
        servings: 3,
        prepMinutes: 20,
        isFavorite: false,
        nutrition: RecipeNutritionCalculator.calculate(
          servings: 3,
          ingredients: [
            const RecipeIngredientDraft(
              name: 'Petto di pollo',
              grams: 300,
              per100g: Nutrients(
                calories: 165,
                protein: 31,
                carbs: 0,
                fat: 3.6,
              ),
            ),
          ],
        ),
        updatedAt: DateTime.utc(2026, 8, 1),
      );
      final option = PlanRecipeOption.fromSummary(summary);

      expect(option.id, 'recipe-real');
      expect(option.servingKcal, closeTo(165, 0.05));
      expect(option.servingProtein, closeTo(31, 0.05));
      expect(option.prepMinutes, 20);
    });
  });

  group('WeeklyPlanResult.fromJson', () {
    test('accetta un piano coerente e ordina gli slot', () {
      final request = _request();
      final result = WeeklyPlanResult.fromJson(_result(), request: request);

      expect(result.slots, hasLength(3));
      expect(
        result.slots.map(
          (slot) =>
              '${PlanDate.format(slot.date)} '
              '${slot.meal.storageValue} ${slot.servings}',
        ),
        ['2026-08-05 pranzo 1.0', '2026-08-05 cena 1.5', '2026-08-06 cena 0.5'],
      );
      expect(result.slots[1].why, 'Proteine alte');
      expect(result.slots.first.recipeName, 'Bowl pollo e riso');
      expect(result.slotsFor(DateTime.utc(2026, 8, 6)), hasLength(1));
      expect(result.notes, startsWith('Settimana leggera'));
    });

    test('il testo libero con cifre sparisce: nessun numero dichiarato dal '
        'modello arriva a schermo', () {
      final result = WeeklyPlanResult.fromJson(
        _result(
          days: [
            {
              'date': '2026-08-05',
              'slots': [
                _slot(
                  'cena',
                  'recipe-a',
                  servings: 1.5,
                  why: 'Circa 600 kcal, leggera per la sera',
                ),
              ],
            },
            {
              'date': '2026-08-06',
              'slots': [_slot('cena', 'recipe-b', why: 'Alterna le proteine')],
            },
          ],
          notes: 'In media 2400 kcal al giorno.',
        ),
        request: _request(),
      );

      expect(result.slots.first.why, isNull);
      expect(result.slots.last.why, 'Alterna le proteine');
      expect(result.notes, isEmpty);
      final serialized = result.toJson().toString();
      expect(serialized, isNot(contains('600')));
      expect(serialized, isNot(contains('2400')));
      expect(serialized, isNot(contains('kcal')));
    });

    test('un recipeId fuori catalogo rende il piano invalido', () {
      expect(
        () => WeeklyPlanResult.fromJson(
          _result(
            days: [
              {
                'date': '2026-08-05',
                'slots': [_slot('cena', 'recipe-inventata')],
              },
              {'date': '2026-08-06', 'slots': const []},
            ],
          ),
          request: _request(),
        ),
        throwsFormatException,
      );
    });

    test('le porzioni stanno fra mezza e quattro, a passi di mezza', () {
      WeeklyPlanResult parseServings(double servings) =>
          WeeklyPlanResult.fromJson(
            _result(
              days: [
                {
                  'date': '2026-08-05',
                  'slots': [_slot('cena', 'recipe-a', servings: servings)],
                },
                {'date': '2026-08-06', 'slots': const []},
              ],
            ),
            request: _request(),
          );

      expect(parseServings(0.5).slots.single.servings, 0.5);
      expect(parseServings(4).slots.single.servings, 4);
      expect(() => parseServings(0.4), throwsFormatException);
      expect(() => parseServings(4.5), throwsFormatException);
      expect(() => parseServings(1.25), throwsFormatException);
    });

    test('i campi con calorie o macro vengono ignorati, mai letti', () {
      final result = WeeklyPlanResult.fromJson(
        _result(
          days: [
            {
              'date': '2026-08-05',
              'slots': [
                {
                  ..._slot('cena', 'recipe-a'),
                  'kcal': 999,
                  'protein': 42,
                  'macros': {'carbs': 10},
                },
              ],
              'totalKcal': 2500,
            },
            {'date': '2026-08-06', 'slots': const []},
          ],
        ),
        request: _request(),
      );

      final slot = result.slots.single;
      expect(slot.recipeId, 'recipe-a');
      expect(
        slot.toJson().keys,
        containsAll(<String>['meal', 'recipeId', 'servings']),
      );
      expect(slot.toJson().containsKey('kcal'), isFalse);
      expect(result.toJson().toString().contains('999'), isFalse);
    });

    test('rifiuta un pasto non richiesto', () {
      expect(
        () => WeeklyPlanResult.fromJson(
          _result(
            days: [
              {
                'date': '2026-08-05',
                'slots': [_slot('colazione', 'recipe-a')],
              },
              {'date': '2026-08-06', 'slots': const []},
            ],
          ),
          request: _request(),
        ),
        throwsFormatException,
      );
    });

    test('rifiuta due slot per lo stesso pasto dello stesso giorno', () {
      expect(
        () => WeeklyPlanResult.fromJson(
          _result(
            days: [
              {
                'date': '2026-08-05',
                'slots': [_slot('cena', 'recipe-a'), _slot('cena', 'recipe-b')],
              },
              {'date': '2026-08-06', 'slots': const []},
            ],
          ),
          request: _request(),
        ),
        throwsFormatException,
      );
    });

    test('le date devono coprire esattamente la finestra richiesta', () {
      List<Map<String, Object?>> days(String first, String second) => [
        {
          'date': first,
          'slots': [_slot('cena', 'recipe-a')],
        },
        {'date': second, 'slots': const []},
      ];

      // Giorno fuori finestra.
      expect(
        () => WeeklyPlanResult.fromJson(
          _result(days: days('2026-08-05', '2026-08-12')),
          request: _request(),
        ),
        throwsFormatException,
      );
      // Giorno duplicato (quindi uno mancante).
      expect(
        () => WeeklyPlanResult.fromJson(
          _result(days: days('2026-08-05', '2026-08-05')),
          request: _request(),
        ),
        throwsFormatException,
      );
      // Numero di giorni sbagliato.
      expect(
        () => WeeklyPlanResult.fromJson(
          _result(
            days: [
              {
                'date': '2026-08-05',
                'slots': [_slot('cena', 'recipe-a')],
              },
            ],
          ),
          request: _request(),
        ),
        throwsFormatException,
      );
    });

    test('rifiuta note troppo lunghe e motivazioni fuori misura', () {
      expect(
        () => WeeklyPlanResult.fromJson(
          _result(notes: 'x' * 401),
          request: _request(),
        ),
        throwsFormatException,
      );
      expect(
        () => WeeklyPlanResult.fromJson(
          _result(
            days: [
              {
                'date': '2026-08-05',
                'slots': [_slot('cena', 'recipe-a', why: 'y' * 201)],
              },
              {'date': '2026-08-06', 'slots': const []},
            ],
          ),
          request: _request(),
        ),
        throwsFormatException,
      );
    });

    test('rifiuta payload strutturalmente sbagliati', () {
      final request = _request();
      expect(
        () => WeeklyPlanResult.fromJson('piano', request: request),
        throwsFormatException,
      );
      expect(
        () => WeeklyPlanResult.fromJson({
          'schema': 2,
          'days': const [],
          'notes': '',
        }, request: request),
        throwsFormatException,
      );
      expect(
        () => WeeklyPlanResult.fromJson({
          'days': 'nessuno',
          'notes': '',
        }, request: request),
        throwsFormatException,
      );
    });

    test('il risultato canonico si rilegge identico', () {
      final request = _request();
      final first = WeeklyPlanResult.fromJson(_result(), request: request);
      final second = WeeklyPlanResult.fromJson(
        first.toJson(),
        request: request,
      );

      expect(second.slots.map((slot) => slot.recipeId), [
        'recipe-a',
        'recipe-b',
        'recipe-a',
      ]);
      expect(second.notes, first.notes);
      expect(second.toJson().toString(), first.toJson().toString());
    });
  });

  group('WeeklyPlan e WeeklyPlanSlot', () {
    test('ordina gli slot per giorno e pasto e conta i fatti', () {
      final plan = WeeklyPlan(
        id: 'plan-1',
        startDate: DateTime.utc(2026, 8, 5),
        days: 2,
        meals: const [PlanMeal.cena, PlanMeal.pranzo],
        status: WeeklyPlanStatus.ready,
        remoteJobId: 'job-1',
        slots: [
          WeeklyPlanSlot(
            id: 'slot-2',
            date: DateTime.utc(2026, 8, 6),
            meal: PlanMeal.pranzo,
            recipeId: 'recipe-b',
            recipeName: 'Salmone e broccoli',
            servings: 1,
          ),
          WeeklyPlanSlot(
            id: 'slot-1',
            date: DateTime.utc(2026, 8, 5, 21),
            meal: PlanMeal.cena,
            recipeId: 'recipe-a',
            recipeName: 'Bowl pollo e riso',
            servings: 1.5,
            doneAt: DateTime.utc(2026, 8, 5, 20, 30),
            diaryEntryIds: const ['entry-1', 'entry-2'],
          ),
        ],
      );

      expect(plan.meals, [PlanMeal.pranzo, PlanMeal.cena]);
      expect(plan.slots.map((slot) => slot.id), ['slot-1', 'slot-2']);
      expect(plan.dates.map(PlanDate.format), ['2026-08-05', '2026-08-06']);
      expect(plan.slotsFor(DateTime.utc(2026, 8, 5)).single.id, 'slot-1');
      expect(plan.doneCount, 1);
      expect(plan.isReady, isTrue);
      expect(plan.slots.first.isDone, isTrue);
      expect(plan.slots.first.diaryEntryIds, ['entry-1', 'entry-2']);
      expect(plan.slots.last.isDone, isFalse);
    });

    test(
      'uno slot senza ricetta resta leggibile ma non è più "Fatto"-abile',
      () {
        final slot = WeeklyPlanSlot(
          id: 'slot-1',
          date: DateTime.utc(2026, 8, 5),
          meal: PlanMeal.cena,
          recipeName: 'Ricetta cancellata',
          servings: 1,
        );

        expect(slot.hasRecipe, isFalse);
        expect(slot.recipeName, 'Ricetta cancellata');
      },
    );

    test('gli stati del piano si leggono dalla colonna', () {
      expect(WeeklyPlanStatus.fromStorage('ready'), WeeklyPlanStatus.ready);
      expect(WeeklyPlanStatus.tryFromStorage('boh'), isNull);
      expect(() => WeeklyPlanStatus.fromStorage('boh'), throwsFormatException);
    });

    test('la CSV delle voci di diario va e torna', () {
      expect(PlanEntryIds.encode(const ['a', ' b ', '']), 'a,b');
      expect(PlanEntryIds.encode(const []), isNull);
      expect(PlanEntryIds.parse('a, b ,'), ['a', 'b']);
      expect(PlanEntryIds.parse(null), isEmpty);
    });
  });
}
