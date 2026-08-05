import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/weekly_plan/domain/post_workout_meal.dart';
import 'package:kal_tracker/features/weekly_plan/domain/weekly_plan_models.dart';

void main() {
  setUp(AppTime.initialize);

  group('typicalTrainingHour', () {
    test('senza storico non si inventa un orario', () {
      expect(typicalTrainingHour(const <DateTime>[]), isNull);
    });

    test('legge le sessioni a Roma, non in UTC', () {
      // 16:00 UTC d'estate sono le 18:00 a Roma: leggerle come UTC
      // sposterebbe l'allenamento di due ore, e con lui il pasto dopo.
      expect(
        typicalTrainingHour([DateTime.utc(2026, 8, 4, 16, 30)]),
        18,
        reason: 'l’ora è quella dell’orologio di Marco',
      );
    });

    test('la mediana non si lascia spostare da una sessione anomala', () {
      final hours = typicalTrainingHour([
        DateTime.utc(2026, 8, 3, 16), // 18 a Roma
        DateTime.utc(2026, 8, 4, 16), // 18
        DateTime.utc(2026, 8, 5, 17), // 19
        DateTime.utc(2026, 8, 6, 3), // 5, una sveglia all'alba
        DateTime.utc(2026, 8, 7, 16), // 18
      ]);

      expect(hours, 18);
    });
  });

  group('postWorkoutMeal', () {
    test('senza ora nota non si indica nessun pasto', () {
      expect(
        postWorkoutMeal(meals: PlanMeal.values, trainingHour: null),
        isNull,
      );
    });

    test('sceglie il primo pasto che viene dopo l’allenamento', () {
      expect(
        postWorkoutMeal(
          meals: const [PlanMeal.colazione, PlanMeal.pranzo, PlanMeal.cena],
          trainingHour: 18,
        ),
        PlanMeal.cena,
      );
      expect(
        postWorkoutMeal(
          meals: const [PlanMeal.colazione, PlanMeal.pranzo, PlanMeal.cena],
          trainingHour: 11,
        ),
        PlanMeal.pranzo,
      );
    });

    test('lo spuntino conta per la sua ora, non per il suo posto in coda', () {
      // Nel contratto lo spuntino è l'ultimo pasto elencato, ma nella
      // giornata cade fra pranzo e cena: dopo un allenamento alle 15 è lui.
      expect(
        postWorkoutMeal(
          meals: const [PlanMeal.pranzo, PlanMeal.cena, PlanMeal.spuntino],
          trainingHour: 15,
        ),
        PlanMeal.spuntino,
      );
    });

    test('un pasto alla stessa ora non è «dopo»', () {
      expect(
        postWorkoutMeal(
          meals: const [PlanMeal.pranzo, PlanMeal.cena],
          trainingHour: PlanMeal.pranzo.usualHour,
        ),
        PlanMeal.cena,
      );
    });

    test('se nessun pasto richiesto viene dopo, non si suggerisce nulla', () {
      expect(
        postWorkoutMeal(
          meals: const [PlanMeal.colazione, PlanMeal.pranzo],
          trainingHour: 21,
        ),
        isNull,
      );
    });
  });
}
