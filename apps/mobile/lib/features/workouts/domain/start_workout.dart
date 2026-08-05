/// L'avvio di una sessione, con la regola «una sola aperta per profilo».
///
/// Quella regola è un indice unico parziale del database
/// (`idx_workouts_one_active`): se la si lascia scattare da sola, l'utente
/// riceve un errore di vincolo SQLite. Qui la si anticipa, e il secondo avvio
/// diventa una proposta — «ne hai già una aperta, riprendila» — invece di
/// un'eccezione.
///
/// Il controllo NON sostituisce il vincolo: fra la lettura e l'inserimento
/// può passare un altro dispositivo, quindi si cattura comunque
/// [ActiveWorkoutAlreadyOpen] e la si traduce nello stesso esito.
library;

import 'package:kal_tracker/features/workouts/domain/live_workout_repository.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';

Future<StartWorkoutResult> startLiveWorkout(
  LiveWorkoutRepository repository, {
  String? routineId,
  String? routineName,
  required List<WorkoutExercise> exercises,
}) async {
  try {
    final existing = await repository.activeWorkout();
    if (existing != null) {
      return WorkoutAlreadyRunning(existing);
    }
    final started = await repository.startWorkout(
      routineId: routineId,
      routineName: routineName,
      exercises: exercises,
    );
    return WorkoutStarted(started);
  } on ActiveWorkoutAlreadyOpen catch (conflict) {
    // La corsa esiste davvero: due dispositivi, o un doppio tap arrivato
    // mentre la prima lettura era in volo.
    return WorkoutAlreadyRunning(conflict.existing);
  } catch (error) {
    return WorkoutStartFailed(error);
  }
}
