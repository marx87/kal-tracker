import 'package:kal_tracker/features/routines/domain/routine_models.dart';
import 'package:kal_tracker/features/workouts/domain/circuit_flow.dart';
import 'package:kal_tracker/features/workouts/domain/circuit_progress.dart';
import 'package:kal_tracker/features/workouts/domain/circuit_result.dart';
import 'package:kal_tracker/features/workouts/domain/exercise_kind.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';

/// Il piano immutabile di una singola fase guidata.
///
/// Le righe della sessione sono l'unica rappresentazione del lavoro: il
/// circuito non appende copie a fine fase, ma spunta le serie che hanno davvero
/// visto il countdown arrivare a zero. Il piano conserva soltanto come quelle
/// righe vanno eseguite e viene copiato nel checkpoint, così una ripresa non
/// dipende da una scheda che nel frattempo può essere cambiata o cancellata.
class CircuitWorkoutPlan {
  const CircuitWorkoutPlan({
    required this.kind,
    required this.steps,
    required this.exerciseIndices,
    required this.restSec,
    required this.longRestSec,
    required this.rounds,
    this.segmentIndex,
    this.rowIndex,
  }) : assert(steps.length == exerciseIndices.length);

  final CircuitKind kind;
  final List<CircuitStep> steps;
  final List<int> exerciseIndices;
  final int restSec;
  final int longRestSec;
  final int rounds;
  final int? segmentIndex;

  /// Una singola riga a tempo fuori da un circuito o da un segmento.
  final int? rowIndex;

  String resumePath(String workoutId) {
    final query = <String, String>{
      if (segmentIndex != null) 'seg': '$segmentIndex',
      if (rowIndex != null) 'row': '$rowIndex',
    };
    return Uri(
      path: '/workout/$workoutId/phase/${kind.name}',
      queryParameters: query.isEmpty ? null : query,
    ).toString();
  }

  String get actionLabel => switch (kind) {
    CircuitKind.warmup => 'Avvia riscaldamento guidato',
    CircuitKind.main => 'Avvia circuito guidato',
    CircuitKind.cooldown => 'Avvia defaticamento guidato',
    CircuitKind.segment when segmentIndex != null =>
      'Avvia blocco a tempo ${segmentIndex! + 1}',
    CircuitKind.segment =>
      'Avvia timer · ${steps.isEmpty ? 'esercizio' : steps.first.exerciseName}',
  };

  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind.name,
    'segmentIndex': segmentIndex,
    'rowIndex': rowIndex,
    'exerciseIndices': exerciseIndices,
    'restSec': restSec,
    'longRestSec': longRestSec,
    'rounds': rounds,
    'steps': [
      for (final step in steps)
        <String, dynamic>{
          'exerciseId': step.exerciseId,
          'exerciseName': step.exerciseName,
          'workSec': step.workSec,
          'muscleGroup': step.muscleGroup?.name,
          'hint': step.hint,
        },
    ],
  };

  static CircuitWorkoutPlan? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final kind = CircuitKind.tryFromName(map['kind'] as String?);
    final rawSteps = map['steps'];
    final rawIndices = map['exerciseIndices'];
    if (kind == null || rawSteps is! List || rawIndices is! List) return null;

    final steps = <CircuitStep>[];
    for (final rawStep in rawSteps) {
      if (rawStep is! Map) return null;
      final step = Map<String, dynamic>.from(rawStep);
      final id = step['exerciseId'] as String?;
      final name = step['exerciseName'] as String?;
      final workSec = (step['workSec'] as num?)?.toInt();
      if (id == null || name == null || workSec == null || workSec <= 0) {
        return null;
      }
      steps.add(
        CircuitStep(
          exerciseId: id,
          exerciseName: name,
          workSec: workSec,
          muscleGroup: muscleGroupOrNull(step['muscleGroup'] as String?),
          hint: step['hint'] as String?,
        ),
      );
    }
    final indices = rawIndices
        .whereType<num>()
        .map((value) => value.toInt())
        .toList(growable: false);
    if (steps.isEmpty || steps.length != indices.length) return null;

    return CircuitWorkoutPlan(
      kind: kind,
      steps: List.unmodifiable(steps),
      exerciseIndices: List.unmodifiable(indices),
      restSec: ((map['restSec'] as num?)?.toInt() ?? 0).clamp(0, 3600),
      longRestSec: ((map['longRestSec'] as num?)?.toInt() ?? 0).clamp(0, 3600),
      rounds: ((map['rounds'] as num?)?.toInt() ?? 1).clamp(1, 50),
      segmentIndex: (map['segmentIndex'] as num?)?.toInt(),
      rowIndex: (map['rowIndex'] as num?)?.toInt(),
    );
  }

  bool matchesRoute({
    required CircuitKind requestedKind,
    int? requestedSegmentIndex,
    int? requestedRowIndex,
  }) =>
      kind == requestedKind &&
      segmentIndex == requestedSegmentIndex &&
      rowIndex == requestedRowIndex;

  CircuitCompletionTracker completedFrom(Workout workout) {
    final completed = CircuitCompletionTracker();
    for (var stepIndex = 0; stepIndex < exerciseIndices.length; stepIndex++) {
      final exerciseIndex = exerciseIndices[stepIndex];
      if (exerciseIndex < 0 || exerciseIndex >= workout.exercises.length) {
        continue;
      }
      final sets = workout.exercises[exerciseIndex].sets;
      for (var round = 0; round < sets.length; round++) {
        if (sets[round].completed) {
          completed.markCompleted(round: round + 1, stepIndex: stepIndex);
        }
      }
    }
    return completed;
  }
}

/// Tutte le fasi che hanno ancora almeno una serie da eseguire.
List<CircuitWorkoutPlan> circuitPlansForWorkout(
  Workout workout, {
  RoutineDetails? routine,
}) {
  final plans = <CircuitWorkoutPlan>[];
  final covered = <int>{};

  final warmup = <int>[
    for (final (index, exercise) in workout.exercises.indexed)
      if (exercise.isWarmup && _isTimed(exercise)) index,
  ];
  if (_hasIncomplete(workout, warmup)) {
    plans.add(
      _planForIndices(
        workout,
        kind: CircuitKind.warmup,
        indices: warmup,
        restSec:
            routine?.warmupRestSec ??
            workout.exercises[warmup.first].restSeconds ??
            15,
        longRestSec: 0,
        rounds: 1,
      ),
    );
  }
  covered.addAll(warmup);

  final segmentGroups = <int, List<int>>{};
  for (final (index, exercise) in workout.exercises.indexed) {
    final segment = exercise.intervalSegmentIndex;
    if (segment != null && _isTimed(exercise)) {
      (segmentGroups[segment] ??= <int>[]).add(index);
    }
  }
  for (final entry
      in segmentGroups.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key))) {
    final config = _segment(routine, entry.key);
    if (_hasIncomplete(workout, entry.value)) {
      plans.add(
        _planForIndices(
          workout,
          kind: CircuitKind.segment,
          indices: entry.value,
          restSec:
              config?.restSec ??
              workout.exercises[entry.value.first].restSeconds ??
              20,
          longRestSec: config?.longRestSec ?? 0,
          rounds: config?.rounds ?? _rounds(workout, entry.value),
          segmentIndex: entry.key,
        ),
      );
    }
    covered.addAll(entry.value);
  }

  if (routine?.isCircuit == true) {
    final main = <int>[
      for (final (index, exercise) in workout.exercises.indexed)
        if (!exercise.isWarmup &&
            !exercise.isCooldown &&
            !exercise.isFinisher &&
            exercise.intervalSegmentIndex == null &&
            _isTimed(exercise))
          index,
    ];
    if (_hasIncomplete(workout, main)) {
      plans.add(
        _planForIndices(
          workout,
          kind: CircuitKind.main,
          indices: main,
          restSec: routine!.shortRestSec,
          longRestSec: routine.longRestSec,
          rounds: routine.rounds,
        ),
      );
    }
    covered.addAll(main);
  }

  for (final (index, exercise) in workout.exercises.indexed) {
    if (covered.contains(index) ||
        exercise.isCooldown ||
        exercise.isFinisher ||
        !_isTimed(exercise) ||
        exercise.sets.every((set) => set.completed)) {
      continue;
    }
    plans.add(
      _planForIndices(
        workout,
        kind: CircuitKind.segment,
        indices: [index],
        restSec: exercise.restSeconds ?? 0,
        longRestSec: exercise.restSeconds ?? 0,
        rounds: exercise.sets.isEmpty ? 1 : exercise.sets.length,
        rowIndex: index,
      ),
    );
    covered.add(index);
  }

  final cooldown = <int>[
    for (final (index, exercise) in workout.exercises.indexed)
      if (exercise.isCooldown && _isTimed(exercise)) index,
  ];
  if (_hasIncomplete(workout, cooldown)) {
    plans.add(
      _planForIndices(
        workout,
        kind: CircuitKind.cooldown,
        indices: cooldown,
        restSec: workout.exercises[cooldown.first].restSeconds ?? 0,
        longRestSec: 0,
        rounds: 1,
      ),
    );
  }

  return List.unmodifiable(plans);
}

CircuitWorkoutPlan? findCircuitWorkoutPlan(
  Workout workout, {
  required CircuitKind kind,
  int? segmentIndex,
  int? rowIndex,
  RoutineDetails? routine,
}) {
  final stored = CircuitWorkoutPlan.fromJson(
    workout.circuitCheckpoint?['plan'],
  );
  if (stored != null &&
      stored.matchesRoute(
        requestedKind: kind,
        requestedSegmentIndex: segmentIndex,
        requestedRowIndex: rowIndex,
      )) {
    return stored;
  }
  for (final plan in circuitPlansForWorkout(workout, routine: routine)) {
    if (plan.matchesRoute(
      requestedKind: kind,
      requestedSegmentIndex: segmentIndex,
      requestedRowIndex: rowIndex,
    )) {
      return plan;
    }
  }
  return null;
}

/// Applica il registro durevole del countdown alle serie già presenti.
Workout applyCircuitResultToWorkout({
  required Workout workout,
  required CircuitWorkoutPlan plan,
  required CircuitFlowState state,
}) {
  final exercises = List<WorkoutExercise>.of(workout.exercises);
  for (
    var stepIndex = 0;
    stepIndex < plan.exerciseIndices.length;
    stepIndex++
  ) {
    final exerciseIndex = plan.exerciseIndices[stepIndex];
    if (exerciseIndex < 0 || exerciseIndex >= exercises.length) continue;
    final exercise = exercises[exerciseIndex];
    final sets = List<WorkoutSet>.of(exercise.sets);
    for (final round in state.completed.completedRoundIndicesForStep(
      stepIndex,
    )) {
      final setIndex = round - 1;
      if (setIndex >= 0 && setIndex < sets.length) {
        sets[setIndex] = sets[setIndex].copyWith(completed: true);
      }
    }
    exercises[exerciseIndex] = exercise.copyWith(sets: sets);
  }

  var completedIndices = workout.completedIntervalSegmentIndices;
  var completedSignatures = workout.completedIntervalSegmentSignatures;
  var partialIndices = workout.partialIntervalSegmentIndices;
  final segmentIndex = plan.segmentIndex;
  if (plan.kind == CircuitKind.segment && segmentIndex != null) {
    final count = circuitCompletionCount(state);
    final completed = {...completedIndices};
    final signatures = {...completedSignatures};
    final partial = {...partialIndices};
    if (count.done >= count.total && count.total > 0) {
      completed.add(segmentIndex);
      signatures[segmentIndex] = state.configSignature;
      partial.remove(segmentIndex);
    } else if (count.done > 0) {
      partial.add(segmentIndex);
    }
    completedIndices = completed.toList()..sort();
    completedSignatures = signatures;
    partialIndices = partial.toList()..sort();
  }

  return workout.copyWith(
    exercises: exercises,
    completedIntervalSegmentIndices: completedIndices,
    completedIntervalSegmentSignatures: completedSignatures,
    partialIntervalSegmentIndices: partialIndices,
  );
}

CircuitWorkoutPlan _planForIndices(
  Workout workout, {
  required CircuitKind kind,
  required List<int> indices,
  required int restSec,
  required int longRestSec,
  required int rounds,
  int? segmentIndex,
  int? rowIndex,
}) => CircuitWorkoutPlan(
  kind: kind,
  exerciseIndices: List.unmodifiable(indices),
  steps: List.unmodifiable([
    for (final index in indices)
      CircuitStep(
        exerciseId: workout.exercises[index].exerciseId,
        exerciseName: workout.exercises[index].exerciseName,
        workSec: workout.exercises[index].sets.firstOrNull?.durationSec ?? 30,
        muscleGroup: workout.exercises[index].muscleGroup,
      ),
  ]),
  restSec: restSec.clamp(0, 3600),
  longRestSec: longRestSec.clamp(0, 3600),
  rounds: rounds.clamp(1, 50),
  segmentIndex: segmentIndex,
  rowIndex: rowIndex,
);

RoutineIntervalSegment? _segment(RoutineDetails? routine, int index) {
  if (routine == null) return null;
  for (final segment in routine.segments) {
    if (segment.segmentIndex == index) return segment;
  }
  return null;
}

bool _isTimed(WorkoutExercise exercise) => exercise.trackingMode.isTimed;

bool _hasIncomplete(Workout workout, List<int> indices) =>
    indices.isNotEmpty &&
    indices.any(
      (index) => workout.exercises[index].sets.any((set) => !set.completed),
    );

int _rounds(Workout workout, List<int> indices) {
  var rounds = 1;
  for (final index in indices) {
    final count = workout.exercises[index].sets.length;
    if (count > rounds) rounds = count;
  }
  return rounds;
}
