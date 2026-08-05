/// Le mutazioni pure sulla lista delle serie: sostituzione di una cella,
/// aggiunta e rimozione di un round di superserie. COPIA VERBATIM di
/// `features/workouts/workout_set_mutation.dart` di Gym Tracker: cambia solo
/// la riga di import.
///
/// `removeLastSupersetRound` NON toglie l'ultima serie di ogni membro: con
/// A=3 e B=2 il terzo round contiene solo A3, e B2 va conservata. È il caso
/// che rende il file non riscrivibile a occhio. Commenti in inglese, apposta.
library;

import 'package:kal_tracker/features/workouts/domain/workout.dart';

/// Replaces one set without mutating the input workout.
/// Invalid cursors are safe no-ops, which also protects delayed undo actions
/// after a structural edit.
Workout replaceWorkoutSet(
  Workout workout,
  int exerciseIndex,
  int setIndex,
  WorkoutSet replacement,
) {
  if (exerciseIndex < 0 || exerciseIndex >= workout.exercises.length) {
    return workout;
  }
  final exercise = workout.exercises[exerciseIndex];
  if (setIndex < 0 || setIndex >= exercise.sets.length) return workout;
  final exercises = List<WorkoutExercise>.of(workout.exercises);
  final sets = List<WorkoutSet>.of(exercise.sets);
  sets[setIndex] = replacement;
  exercises[exerciseIndex] = exercise.copyWith(sets: sets);
  return workout.copyWith(exercises: exercises);
}

List<int> _validExerciseIndices(Workout workout, Iterable<int> indices) =>
    indices
        .where((index) => index >= 0 && index < workout.exercises.length)
        .toSet()
        .toList(growable: false);

/// Adds one new logical round to a superset.
///
/// If imported or previously edited members have asymmetric set counts, the
/// shorter members are first brought up to the existing last round and then
/// every member receives the new one. Every generated set is intentionally
/// incomplete and has no inherited RPE.
Workout appendSupersetRound(
  Workout workout,
  Iterable<int> group, {
  required WorkoutSet Function(WorkoutExercise exercise) emptySetFactory,
}) {
  final indices = _validExerciseIndices(workout, group);
  if (indices.isEmpty) return workout;
  final targetCount =
      indices
          .map((index) => workout.exercises[index].sets.length)
          .fold<int>(0, (max, count) => count > max ? count : max) +
      1;
  final exercises = List<WorkoutExercise>.of(workout.exercises);
  for (final index in indices) {
    final exercise = exercises[index];
    final sets = List<WorkoutSet>.of(exercise.sets);
    final template = sets.isNotEmpty ? sets.last : emptySetFactory(exercise);
    while (sets.length < targetCount) {
      sets.add(template.copyWith(completed: false, clearRpe: true));
    }
    exercises[index] = exercise.copyWith(sets: sets);
  }
  return workout.copyWith(exercises: exercises);
}

/// Number of completed cells that belong to the actual last logical round.
int completedSetsInLastSupersetRound(Workout workout, Iterable<int> group) {
  final indices = _validExerciseIndices(workout, group);
  if (indices.isEmpty) return 0;
  final maxCount = indices
      .map((index) => workout.exercises[index].sets.length)
      .fold<int>(0, (max, count) => count > max ? count : max);
  if (maxCount == 0) return 0;
  return indices.where((index) {
    final sets = workout.exercises[index].sets;
    return sets.length == maxCount && sets.last.completed;
  }).length;
}

/// Removes only the cells that belong to the highest logical round.
///
/// This is deliberately different from removing each member's last set: for
/// A=3 and B=2, round three contains A3 only, so B2 must be preserved.
Workout removeLastSupersetRound(Workout workout, Iterable<int> group) {
  final indices = _validExerciseIndices(workout, group);
  if (indices.isEmpty) return workout;
  final maxCount = indices
      .map((index) => workout.exercises[index].sets.length)
      .fold<int>(0, (max, count) => count > max ? count : max);
  if (maxCount <= 1) return workout;
  final exercises = List<WorkoutExercise>.of(workout.exercises);
  for (final index in indices) {
    final exercise = exercises[index];
    if (exercise.sets.length != maxCount) continue;
    exercises[index] = exercise.copyWith(
      sets: List<WorkoutSet>.of(exercise.sets)..removeLast(),
    );
  }
  return workout.copyWith(exercises: exercises);
}
