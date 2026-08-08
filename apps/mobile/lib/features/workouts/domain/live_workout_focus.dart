/// Il fuoco della sessione dal vivo: quante celle sono fatte, quante ce ne
/// sono e QUALE viene adesso — compreso l'ordine per round delle superserie.
/// COPIA VERBATIM di `features/workouts/live_workout_focus.dart` di Gym
/// Tracker: cambiano solo le due righe di import.
///
/// È la definizione UNICA di «prossima serie»: la schermata, i comandi vocali
/// e i test la leggono da qui e non se la ricalcolano. Commenti in inglese
/// come nel sorgente, apposta.
library;

import 'package:kal_tracker/features/workouts/domain/exercise_kind.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';

typedef WorkoutCursor = ({int exerciseIndex, int setIndex});

/// Pure, UI-independent snapshot of progress through a live workout.
///
/// Keeping the cursor here gives the screen, voice commands and tests one
/// shared definition of "next set", including the round-major order used by
/// supersets (A1, B1, A2, B2...).
class LiveWorkoutFocus {
  const LiveWorkoutFocus({
    required this.completedSets,
    required this.totalSets,
    required this.current,
  });

  final int completedSets;
  final int totalSets;
  final WorkoutCursor? current;

  bool get isComplete => totalSets > 0 && completedSets >= totalSets;

  double get progress =>
      totalSets == 0 ? 0 : (completedSets / totalSets).clamp(0.0, 1.0);
}

LiveWorkoutFocus calculateLiveWorkoutFocus(
  Workout workout, {
  bool finisherPhase = false,
}) {
  final exercises = workout.exercises;

  bool isVisible(WorkoutExercise exercise) {
    // Le righe a tempo vengono completate esclusivamente dal motore guidato:
    // offrirle anche come «Fatta» manuale creerebbe due modi concorrenti di
    // registrare la stessa cella e permetterebbe di saltare il countdown.
    if (exercise.isWarmup ||
        exercise.isCooldown ||
        exercise.trackingMode.isTimed) {
      return false;
    }
    return !finisherPhase || exercise.isFinisher;
  }

  final visible = exercises.where(isVisible);
  final total = visible.fold<int>(0, (sum, e) => sum + e.sets.length);
  final completed = visible.fold<int>(
    0,
    (sum, e) => sum + e.sets.where((s) => s.completed).length,
  );

  List<int>? supersetFor(int index) {
    if (index < 0 || index >= exercises.length) return null;
    var start = index;
    while (start > 0 && exercises[start].isInSupersetWithPrevious) {
      start--;
    }
    final members = <int>[start];
    var next = start + 1;
    while (next < exercises.length &&
        exercises[next].isInSupersetWithPrevious) {
      members.add(next);
      next++;
    }
    return members.length > 1 ? members : null;
  }

  WorkoutCursor? current;
  var exerciseIndex = 0;
  while (exerciseIndex < exercises.length && current == null) {
    final exercise = exercises[exerciseIndex];
    if (!isVisible(exercise)) {
      exerciseIndex++;
      continue;
    }

    final group = supersetFor(exerciseIndex);
    if (group != null && group.first == exerciseIndex) {
      var rounds = 0;
      for (final memberIndex in group) {
        if (isVisible(exercises[memberIndex]) &&
            exercises[memberIndex].sets.length > rounds) {
          rounds = exercises[memberIndex].sets.length;
        }
      }
      for (var round = 0; round < rounds && current == null; round++) {
        for (final memberIndex in group) {
          final member = exercises[memberIndex];
          if (!isVisible(member) || round >= member.sets.length) continue;
          if (!member.sets[round].completed) {
            current = (exerciseIndex: memberIndex, setIndex: round);
            break;
          }
        }
      }
      exerciseIndex = group.last + 1;
      continue;
    }

    for (
      var setIndex = 0;
      setIndex < exercise.sets.length && current == null;
      setIndex++
    ) {
      if (!exercise.sets[setIndex].completed) {
        current = (exerciseIndex: exerciseIndex, setIndex: setIndex);
      }
    }
    exerciseIndex++;
  }

  return LiveWorkoutFocus(
    completedSets: completed,
    totalSets: total,
    current: current,
  );
}

String describeWorkoutSet(WorkoutSet set, ExerciseTrackingMode mode) {
  String number(double value) => value == value.truncateToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(1);

  String duration() {
    final seconds = set.durationSec;
    if (seconds == null) return 'durata da impostare';
    final minutes = seconds ~/ 60;
    final remainder = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$remainder';
  }

  switch (mode) {
    case ExerciseTrackingMode.weightReps:
      if (set.weightKg == null && set.reps == null) {
        return 'Imposta peso e ripetizioni';
      }
      if (set.weightKg == null) return '${set.reps ?? 0} ripetizioni';
      if (set.reps == null) return '${number(set.weightKg!)} kg';
      return '${number(set.weightKg!)} kg × ${set.reps} rip.';
    case ExerciseTrackingMode.bodyweightReps:
      return set.reps == null
          ? 'Imposta le ripetizioni'
          : '${set.reps} ripetizioni';
    case ExerciseTrackingMode.timeOnly:
      return duration();
    case ExerciseTrackingMode.timed:
      return set.weightKg == null
          ? duration()
          : '${duration()} · ${number(set.weightKg!)} kg';
    case ExerciseTrackingMode.distanceTime:
      return set.distanceM == null
          ? duration()
          : '${duration()} · ${number(set.distanceM!)} m';
  }
}
