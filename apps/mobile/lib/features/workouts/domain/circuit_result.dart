/// Come un circuito finito diventa righe di sessione.
///
/// In Gym Tracker questa conversione stava dentro `_persistSession`, in mezzo
/// alle scritture Firestore. Qui è una funzione pura, perché è la parte che
/// decide COSA finisce nello storico — e sbagliarla non si vede: le righe
/// esistono comunque, solo con dentro il lavoro sbagliato.
library;

import 'package:kal_tracker/features/workouts/domain/circuit_flow.dart';
import 'package:kal_tracker/features/workouts/domain/exercise_kind.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';

/// Le righe da appendere alla sessione quando la fase a tempo si chiude.
///
/// Una riga per passo, con tante serie quante sono le ripetizioni di quel
/// passo che hanno DAVVERO visto il countdown arrivare a zero. Chi ha saltato
/// o è uscito a metà non ha una serie: il registro
/// [CircuitFlowState.completed] lo sa, il cursore no.
///
/// Un passo con zero round completati non produce nessuna riga: una riga
/// senza serie sarebbe un esercizio che risulta «fatto» a zero.
List<WorkoutExercise> circuitAsWorkoutExercises(CircuitFlowState state) {
  final rows = <WorkoutExercise>[];
  for (var stepIndex = 0; stepIndex < state.steps.length; stepIndex++) {
    final step = state.steps[stepIndex];
    final rounds = state.completed.completedRoundsForStep(stepIndex);
    if (rounds <= 0) continue;
    rows.add(
      WorkoutExercise(
        exerciseId: step.exerciseId,
        exerciseName: step.exerciseName,
        // Le celle a tempo sono `timed` per definizione: è la modalità con
        // cui `kcal_estimator` le conta a 8.0 MET, come il cardio.
        trackingMode: ExerciseTrackingMode.timed,
        muscleGroup: step.muscleGroup,
        restSeconds: state.restSec,
        isWarmup: state.kind == CircuitKind.warmup,
        isCooldown: state.kind == CircuitKind.cooldown,
        // Solo i blocchi a tempo dentro il principale portano l'indice: è
        // quello che li distingue dalle righe base nella stessa lista.
        intervalSegmentIndex: state.kind == CircuitKind.segment
            ? state.segmentIndex
            : null,
        sets: [
          for (var round = 0; round < rounds; round++)
            WorkoutSet(durationSec: step.workSec, completed: true),
        ],
      ),
    );
  }
  return rows;
}

/// Quante celle su quante: serve a dire all'utente, alla fine, se ha
/// completato o interrotto.
({int done, int total}) circuitCompletionCount(CircuitFlowState state) {
  var done = 0;
  for (var stepIndex = 0; stepIndex < state.steps.length; stepIndex++) {
    done += state.completed.completedRoundsForStep(stepIndex);
  }
  return (done: done, total: state.steps.length * state.totalRounds);
}
