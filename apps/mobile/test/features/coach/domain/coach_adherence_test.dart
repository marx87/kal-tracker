import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/coach/domain/coach_adherence.dart';
import 'package:kal_tracker/features/coach/domain/coach_snapshot.dart';

CoachIntake intake({
  double? kcal = 2000,
  double? protein = 140,
  int days = 7,
}) => CoachIntake(days: days, averageKcal: kcal, averageProteinGrams: protein);

const targets = CoachTargets(
  dailyCalories: 2000,
  dailyProtein: 143,
  weeklyWorkouts: 3,
);

void main() {
  group('le calorie', () {
    test('centrate sono in linea', () {
      final assessment = CoachAdherence.assess(
        intake: intake(),
        workoutsDone: 3,
        targets: targets,
      );

      expect(assessment.calories.grade, AdherenceGrade.onTrack);
      expect(assessment.calories.deltaFromPlan, closeTo(0, 0.001));
    });

    test('sbagliare in eccesso e in difetto pesa uguale', () {
      final over = CoachAdherence.assess(
        intake: intake(kcal: 2400),
        workoutsDone: 3,
        targets: targets,
      );
      final under = CoachAdherence.assess(
        intake: intake(kcal: 1600),
        workoutsDone: 3,
        targets: targets,
      );

      expect(over.calories.grade, AdherenceGrade.off);
      expect(under.calories.grade, AdherenceGrade.off);
    });

    test('un 10% di scarto è uno scostamento, non un fallimento', () {
      final assessment = CoachAdherence.assess(
        intake: intake(kcal: 2200),
        workoutsDone: 3,
        targets: targets,
      );

      expect(assessment.calories.grade, AdherenceGrade.drifting);
    });
  });

  group('le proteine', () {
    test('mangiarne di più non è un errore da segnalare', () {
      final assessment = CoachAdherence.assess(
        intake: intake(protein: 200),
        workoutsDone: 3,
        targets: targets,
      );

      expect(assessment.protein.grade, AdherenceGrade.onTrack);
    });

    test('starci sotto sì', () {
      final assessment = CoachAdherence.assess(
        intake: intake(protein: 100),
        workoutsDone: 3,
        targets: targets,
      );

      expect(assessment.protein.grade, AdherenceGrade.off);
      expect(assessment.protein.ratio, lessThan(0.85));
    });
  });

  group('gli allenamenti', () {
    test('due su tre si scostano, uno su tre no', () {
      final two = CoachAdherence.assess(
        intake: intake(),
        workoutsDone: 2,
        targets: targets,
      );
      final one = CoachAdherence.assess(
        intake: intake(),
        workoutsDone: 1,
        targets: targets,
      );

      expect(two.workouts!.grade, AdherenceGrade.drifting);
      expect(one.workouts!.grade, AdherenceGrade.off);
    });

    test('se non era previsto niente, la riga sparisce', () {
      final assessment = CoachAdherence.assess(
        intake: intake(),
        workoutsDone: 2,
        targets: const CoachTargets(dailyCalories: 2000, dailyProtein: 143),
      );

      expect(assessment.workouts, isNull);
      expect(assessment.lines, hasLength(2));
    });
  });

  group('i buchi', () {
    test('con tre giorni di diario su sette non si giudica', () {
      final assessment = CoachAdherence.assess(
        intake: intake(days: 3),
        workoutsDone: 3,
        targets: targets,
      );

      expect(assessment.calories.grade, AdherenceGrade.unknown);
      expect(assessment.protein.grade, AdherenceGrade.unknown);
      expect(assessment.calories.daysMissing, 4);
      // Gli allenamenti si contano lo stesso: non dipendono dal diario.
      expect(assessment.workouts!.grade, AdherenceGrade.onTrack);
    });

    test(
      'senza obiettivo si dice cosa si è fatto, non quanto ci si scosta',
      () {
        final assessment = CoachAdherence.assess(
          intake: intake(),
          workoutsDone: 2,
        );

        expect(assessment.calories.grade, AdherenceGrade.unknown);
        expect(assessment.calories.actual, closeTo(2000, 0.001));
        expect(assessment.calories.planned, isNull);
        expect(assessment.overall, AdherenceGrade.unknown);
      },
    );
  });

  group('il verdetto complessivo', () {
    test('vale il peggiore fra quelli noti', () {
      final assessment = CoachAdherence.assess(
        intake: intake(kcal: 2200, protein: 100),
        workoutsDone: 3,
        targets: targets,
      );

      expect(assessment.calories.grade, AdherenceGrade.drifting);
      expect(assessment.protein.grade, AdherenceGrade.off);
      expect(assessment.workouts!.grade, AdherenceGrade.onTrack);
      expect(assessment.overall, AdherenceGrade.off);
    });

    test('una riga sconosciuta non trascina giù le altre', () {
      final assessment = CoachAdherence.assess(
        intake: intake(days: 2),
        workoutsDone: 3,
        targets: targets,
      );

      expect(assessment.overall, AdherenceGrade.onTrack);
    });
  });
}
