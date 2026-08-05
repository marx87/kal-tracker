import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/weekly_plan/domain/plan_week.dart';
import 'package:kal_tracker/features/weekly_plan/domain/weekly_plan_models.dart';

WeeklyPlanSlot _slot(String id, DateTime date, PlanMeal meal) => WeeklyPlanSlot(
  id: id,
  date: date,
  meal: meal,
  recipeId: 'recipe-a',
  recipeName: 'Bowl pollo e riso',
  servings: 1,
);

/// Un piano di 3 giorni da mercoledì 5 agosto 2026 con pranzo e cena.
WeeklyPlan _plan({List<WeeklyPlanSlot> slots = const <WeeklyPlanSlot>[]}) =>
    WeeklyPlan(
      id: 'plan-1',
      startDate: DateTime.utc(2026, 8, 5),
      days: 3,
      meals: const [PlanMeal.pranzo, PlanMeal.cena],
      status: WeeklyPlanStatus.ready,
      slots: slots,
    );

void main() {
  setUp(AppTime.initialize);

  test('ogni giorno prende i suoi pasti e il suo allenamento', () {
    final plan = _plan(
      slots: [
        _slot('slot-1', DateTime.utc(2026, 8, 5), PlanMeal.pranzo),
        _slot('slot-2', DateTime.utc(2026, 8, 5), PlanMeal.cena),
        _slot('slot-3', DateTime.utc(2026, 8, 6), PlanMeal.cena),
      ],
    );

    final week = PlanWeek.build(
      dates: plan.dates,
      plan: plan,
      workouts: const [
        // Mercoledì (5 agosto 2026) e venerdì (7 agosto).
        PlannedWorkout(
          weekday: 3,
          routineId: 'routine-1',
          routineName: 'Spinta',
        ),
        PlannedWorkout(
          weekday: 5,
          routineId: 'routine-2',
          routineName: 'Gambe',
        ),
      ],
    );

    expect(week.map((day) => PlanDate.format(day.date)), [
      '2026-08-05',
      '2026-08-06',
      '2026-08-07',
    ]);
    expect(week[0].workout?.routineName, 'Spinta');
    expect(week[0].meals.map((slot) => slot.id), ['slot-1', 'slot-2']);
    // Giovedì: pasti sì, allenamento no. Non è un giorno vuoto.
    expect(week[1].workout, isNull);
    expect(week[1].meals, hasLength(1));
    expect(week[1].isEmpty, isFalse);
    // Venerdì: allenamento sì, pasti no.
    expect(week[2].workout?.routineName, 'Gambe');
    expect(week[2].meals, isEmpty);
    expect(week[2].hasWorkout, isTrue);
  });

  test('senza piano dei pasti la settimana esiste lo stesso', () {
    // È la promessa «leggibile col Mac spento e senza piano generato».
    final dates = PlanWeek.upcomingDates(DateTime.utc(2026, 8, 5));

    final week = PlanWeek.build(
      dates: dates,
      workouts: const [
        PlannedWorkout(
          weekday: 3,
          routineId: 'routine-1',
          routineName: 'Spinta',
        ),
      ],
    );

    expect(week, hasLength(7));
    expect(PlanDate.format(week.first.date), '2026-08-05');
    expect(PlanDate.format(week.last.date), '2026-08-11');
    // Il 5 agosto 2026 è mercoledì: la scheda si aggancia lì, e una volta
    // sola perché sette giorni da mercoledì arrivano al martedì.
    expect(week.first.workout?.routineName, 'Spinta');
    expect(
      week
          .where((day) => day.hasWorkout)
          .map((day) => PlanDate.format(day.date)),
      ['2026-08-05'],
    );
    expect(week[1].isEmpty, isTrue);
    expect(week.first.meals, isEmpty);
  });

  test('la scheda cancellata resta nel giorno, ma non si avvia', () {
    final week = PlanWeek.build(
      dates: [DateTime.utc(2026, 8, 5)],
      workouts: const [
        PlannedWorkout(weekday: 3, routineName: 'Scheda cancellata'),
      ],
    );

    expect(week.single.workout?.routineName, 'Scheda cancellata');
    expect(week.single.workout?.isMissing, isTrue);
  });
}
