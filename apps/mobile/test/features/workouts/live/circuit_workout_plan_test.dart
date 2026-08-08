import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/workouts/domain/circuit_flow.dart';
import 'package:kal_tracker/features/workouts/domain/circuit_progress.dart';
import 'package:kal_tracker/features/workouts/domain/exercise_kind.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';
import 'package:kal_tracker/features/workouts/presentation/live/circuit_workout_plan.dart';

const _steps = [
  CircuitStep(exerciseId: 'a', exerciseName: 'A', workSec: 30),
  CircuitStep(exerciseId: 'b', exerciseName: 'B', workSec: 40),
];

final _plan = CircuitWorkoutPlan(
  kind: CircuitKind.segment,
  steps: _steps,
  exerciseIndices: [0, 1],
  restSec: 15,
  longRestSec: 45,
  rounds: 2,
  segmentIndex: 3,
);

Workout _workout({bool firstRoundDone = false}) => Workout(
  id: 'w1',
  startedAt: DateTime.utc(2026, 8, 8),
  exercises: [
    WorkoutExercise(
      exerciseId: 'a',
      exerciseName: 'A',
      trackingMode: ExerciseTrackingMode.timed,
      intervalSegmentIndex: 3,
      sets: [
        WorkoutSet(durationSec: 30, completed: firstRoundDone),
        const WorkoutSet(durationSec: 30),
      ],
    ),
    WorkoutExercise(
      exerciseId: 'b',
      exerciseName: 'B',
      trackingMode: ExerciseTrackingMode.timed,
      intervalSegmentIndex: 3,
      sets: [
        WorkoutSet(durationSec: 40, completed: firstRoundDone),
        const WorkoutSet(durationSec: 40),
      ],
    ),
  ],
);

void main() {
  test('il risultato spunta le righe esistenti senza appenderne copie', () {
    final completed = CircuitCompletionTracker()
      ..markCompleted(round: 2, stepIndex: 0)
      ..markCompleted(round: 1, stepIndex: 1);
    final state = CircuitFlowState.initial(
      kind: CircuitKind.segment,
      steps: _steps,
      restSec: 15,
      longRestSec: 45,
      totalRounds: 2,
      segmentIndex: 3,
      completed: completed,
    );

    final result = applyCircuitResultToWorkout(
      workout: _workout(),
      plan: _plan,
      state: state,
    );

    expect(result.exercises, hasLength(2));
    expect(result.exercises[0].sets.map((set) => set.completed), [false, true]);
    expect(result.exercises[1].sets.map((set) => set.completed), [true, false]);
    expect(result.partialIntervalSegmentIndices, [3]);
    expect(result.completedIntervalSegmentIndices, isEmpty);
  });

  test('una ripresa parte dalla prima cella non ancora registrata', () {
    final workout = _workout(firstRoundDone: true);
    final state = CircuitFlowState.initial(
      kind: _plan.kind,
      steps: _plan.steps,
      restSec: _plan.restSec,
      longRestSec: _plan.longRestSec,
      totalRounds: _plan.rounds,
      segmentIndex: _plan.segmentIndex,
      completed: _plan.completedFrom(workout),
    );

    expect(state.round, 2);
    expect(state.stepIndex, 0);
    expect(state.completed.serialize(), ['1:0', '1:1']);
  });

  test('il piano nel checkpoint conserva anche la rotta del segmento', () {
    final restored = CircuitWorkoutPlan.fromJson(_plan.toJson());

    expect(restored, isNotNull);
    expect(restored!.exerciseIndices, [0, 1]);
    expect(restored.resumePath('w1'), '/workout/w1/phase/segment?seg=3');
  });
}
