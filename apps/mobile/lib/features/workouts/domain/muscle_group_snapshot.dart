/// Il ponte fra `muscleGroupSnapshot` (una colonna) e la mappa che
/// `estimateKcal` chiede (`exerciseId -> MuscleGroup`).
///
/// In Gym Tracker quella mappa si costruiva leggendo il CATALOGO al momento
/// del calcolo. Qui no: il gruppo è congelato sulla riga della sessione, e
/// deve esserlo, perché il catalogo cambia e le calorie di una sessione di sei
/// mesi fa non possono cambiare con lui.
library;

import 'package:kal_tracker/features/workouts/domain/exercise_kind.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';

/// La mappa che `estimateKcal` si aspetta, letta dagli snapshot.
///
/// Gli esercizi senza snapshot NON compaiono: `estimateKcal` ci mette sopra
/// `MuscleGroup.altro`, cioè 5.0 MET. È lo stesso ripiego, ma esplicito —
/// e [exercisesMissingMuscleGroupSnapshot] dice quali sono, così il difetto
/// si vede invece di sparire nel numero finale.
Map<String, MuscleGroup> muscleGroupsFromSnapshots(Workout workout) {
  final groups = <String, MuscleGroup>{};
  for (final exercise in workout.exercises) {
    final group = exercise.muscleGroup;
    if (group == null) continue;
    // Righe diverse con lo stesso `exerciseId` (blocchi a tempo appesi)
    // portano lo stesso gruppo: la prima vince e le altre confermano.
    groups.putIfAbsent(exercise.exerciseId, () => group);
  }
  return groups;
}

/// Le righe che finirebbero sui 5.0 MET di ripiego.
///
/// Il defaticamento è escluso di proposito: `estimateKcal` lo salta prima di
/// guardare il gruppo (2.5 MET fissi), quindi lì lo snapshot mancante non
/// cambia niente e segnalarlo sarebbe un falso allarme.
///
/// Sul resto invece pesa: gambe (6.0) e cardio (8.0) contro un ripiego di 5.0
/// sono il 20-40% di errore sulle calorie di quella sessione.
List<WorkoutExercise> exercisesMissingMuscleGroupSnapshot(Workout workout) => [
  for (final exercise in workout.exercises)
    if (!exercise.isCooldown && exercise.muscleGroup == null) exercise,
];

/// Vero quando ogni riga che conta porta il suo gruppo: è la condizione da
/// verificare PRIMA di scrivere, non dopo aver visto un numero strano.
bool hasCompleteMuscleGroupSnapshots(Workout workout) =>
    exercisesMissingMuscleGroupSnapshot(workout).isEmpty;
