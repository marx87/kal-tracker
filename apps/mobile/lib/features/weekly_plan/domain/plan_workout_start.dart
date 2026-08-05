/// L'avvio dell'allenamento del giorno, visto dal piano.
///
/// Il piano NON sa comporre una sessione: quali esercizi, quante serie e con
/// che recuperi è roba del modulo Palestra, che ha già la sua regola «una
/// sola sessione aperta per profilo» (`startLiveWorkout`). Qui c'è soltanto
/// l'esito, nella forma che serve alla schermata: dove andare, e cosa dire se
/// non si va da nessuna parte.
library;

sealed class PlanWorkoutStartResult {
  const PlanWorkoutStartResult();
}

/// C'è una sessione aperta su cui entrare.
final class PlanWorkoutRunning extends PlanWorkoutStartResult {
  const PlanWorkoutRunning(this.workoutId, {this.resumed = false});

  final String workoutId;

  /// La sessione c'era già (l'app era stata chiusa a metà allenamento). Non è
  /// un errore: si riprende quella, e lo si dice.
  final bool resumed;
}

/// Non si è partiti, e il motivo è già in italiano.
final class PlanWorkoutNotStarted extends PlanWorkoutStartResult {
  const PlanWorkoutNotStarted(this.message);

  final String message;
}
