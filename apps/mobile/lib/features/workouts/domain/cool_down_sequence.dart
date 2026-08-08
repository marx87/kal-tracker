/// Il defaticamento guidato: ~3:30 di allungamenti, uguali a ogni sessione.
///
/// La LISTA non è qui. Vive già in
/// `features/gym_import/domain/cool_down_sequence.dart`, copiata verbatim
/// dall'export, e da lì la riesporto: due copie degli stessi otto slug
/// finirebbero prima o poi con due nomi diversi per lo stesso `cd-*`, e nel
/// database resterebbero entrambi per sempre.
library;

import 'package:kal_tracker/features/gym_import/domain/cool_down_sequence.dart';
import 'package:kal_tracker/features/workouts/domain/exercise_kind.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';

export 'package:kal_tracker/features/gym_import/domain/cool_down_sequence.dart'
    show CoolDownItem, kCoolDownSequence;

/// Le righe di sessione che il repository scrive quando si accetta il
/// defaticamento.
///
/// Portata invariata da Gym, con due aggiunte che il database esige:
/// - [MuscleGroup.mobilita] come snapshot, che vale 2.5 MET. Senza,
///   `estimateKcal` userebbe il ripiego a 5.0 e gli allungamenti conterebbero
///   il doppio di quello che valgono;
/// - [completed] resta `true` per import e storico; la sessione dal vivo passa
///   `false`, lascia che sia il motore a tempo a spuntare ogni allungamento e
///   non attribuisce lavoro solo perché l'utente ha accettato la proposta.
List<WorkoutExercise> coolDownAsWorkoutExercises({bool completed = true}) => [
  for (final item in kCoolDownSequence)
    WorkoutExercise(
      exerciseId: item.slug,
      exerciseName: item.name,
      trackingMode: ExerciseTrackingMode.timed,
      muscleGroup: MuscleGroup.mobilita,
      restSeconds: CoolDownItem.restSec,
      isCooldown: true,
      sets: [WorkoutSet(durationSec: item.durationSec, completed: completed)],
    ),
];

/// Quanto dura il defaticamento completo, recuperi compresi: serve per dirlo
/// all'utente prima che accetti, non dopo.
Duration get coolDownTotalDuration {
  var seconds = 0;
  for (final item in kCoolDownSequence) {
    seconds += item.durationSec;
  }
  // Fra un allungamento e il successivo, non dopo l'ultimo.
  seconds += CoolDownItem.restSec * (kCoolDownSequence.length - 1);
  return Duration(seconds: seconds);
}
