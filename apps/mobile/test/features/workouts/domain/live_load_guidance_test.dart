import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/workouts/domain/load_progression.dart';
import 'package:kal_tracker/features/workouts/domain/live_load_guidance.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';

void main() {
  const history = [
    WorkoutSet(weightKg: 20, reps: 12, rpe: 8, completed: true),
    WorkoutSet(weightKg: 20, reps: 12, rpe: 9, completed: true),
  ];

  test('porta la progressione nella sessione di oggi', () {
    const advice = LoadProgressionAdvice(
      verdict: ProgressionVerdict.salire,
      reason: 'Intervallo completato.',
      countedSets: 2,
      allSetsAtTop: true,
      marginDeclared: true,
      currentKg: 20,
      proposedKg: 22,
      proposedReps: 8,
    );

    final guidance = LiveLoadGuidance.from(
      lastSets: history,
      plannedSets: const [WorkoutSet(reps: 12), WorkoutSet(reps: 12)],
      advice: advice,
    );

    expect(guidance.lastWeightKg, 20);
    expect(guidance.lastRpe, 9);
    expect(guidance.proposedWeightKg, 22);
    expect(guidance.proposedReps, 8);
    expect(guidance.isProgression, isTrue);
  });

  test('un tocco modifica solo le serie rimaste', () {
    const advice = LoadProgressionAdvice(
      verdict: ProgressionVerdict.salire,
      reason: 'Intervallo completato.',
      countedSets: 2,
      allSetsAtTop: true,
      marginDeclared: true,
      currentKg: 20,
      proposedKg: 22,
      proposedReps: 8,
    );
    final guidance = LiveLoadGuidance.from(
      lastSets: history,
      plannedSets: const [WorkoutSet(reps: 12)],
      advice: advice,
    );
    const exercise = WorkoutExercise(
      exerciseId: 'squat',
      exerciseName: 'Squat',
      sets: [
        WorkoutSet(weightKg: 10, reps: 10, isWarmup: true, completed: false),
        WorkoutSet(weightKg: 20, reps: 12, completed: true),
        WorkoutSet(reps: 12),
      ],
    );

    final updated = guidance.applyToRemaining(exercise);

    expect(updated.sets[0].weightKg, 10);
    expect(updated.sets[1].weightKg, 20);
    expect(updated.sets[2].weightKg, 22);
    expect(updated.sets[2].reps, 8);
  });

  test('senza gradino ripropone in modo prudente ultimo carico e piano', () {
    const advice = LoadProgressionAdvice(
      verdict: ProgressionVerdict.restare,
      reason: 'Continua dentro l’intervallo.',
      countedSets: 2,
      allSetsAtTop: false,
      marginDeclared: true,
      currentKg: 20,
    );
    final guidance = LiveLoadGuidance.from(
      lastSets: history,
      plannedSets: const [WorkoutSet(reps: 10)],
      advice: advice,
    );

    expect(guidance.proposedWeightKg, 20);
    expect(guidance.proposedReps, 10);
    expect(guidance.isProgression, isFalse);
  });
}
