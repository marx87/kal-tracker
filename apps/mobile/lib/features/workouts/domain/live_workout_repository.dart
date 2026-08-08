/// Il contratto che la sessione dal vivo chiede alla persistenza.
///
/// È un'interfaccia e non una classe concreta perché `features/workouts/data/`
/// non è mia: l'implementazione Drift la scrive un altro agente. Qui c'è
/// SOLO ciò che la schermata usa davvero, con scritto accanto perché — un
/// metodo senza una ragione visibile diventa, sei mesi dopo, un metodo che
/// nessuno sa se può cambiare.
library;

import 'package:kal_tracker/features/workouts/domain/kcal_estimator.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';

abstract interface class LiveWorkoutRepository {
  /// La sessione aperta del profilo, se c'è.
  ///
  /// Il database ne ammette UNA sola: `idx_workouts_one_active` è un indice
  /// unico parziale su `(profile_id) WHERE ended_at IS NULL AND deleted_at IS
  /// NULL`. Questo metodo serve a chiederlo PRIMA di provare a inserire, così
  /// il secondo avvio diventa un messaggio con «riprendi» invece di un'eccezione
  /// di vincolo che l'utente non può leggere.
  Future<Workout?> activeWorkout();

  /// Apre una sessione nuova.
  ///
  /// Può comunque fallire per violazione dell'indice unico — fra il controllo
  /// e l'inserimento ci può stare un altro dispositivo — e in quel caso deve
  /// lanciare [ActiveWorkoutAlreadyOpen], non un errore Drift grezzo: chi
  /// chiama non deve conoscere il messaggio di SQLite.
  Future<Workout> startWorkout({
    String? routineId,
    String? routineName,
    required List<WorkoutExercise> exercises,
  });

  Future<Workout?> getById(String workoutId);

  /// Salva l'istantanea di lavoro: esercizi, serie, note.
  ///
  /// Le scritture della sessione dal vivo sono serializzate dalla schermata
  /// (una coda `Future`), quindi qui non serve un lock: serve però che la
  /// scrittura sia TRANSAZIONALE, perché una serie spuntata e la sua riga
  /// esercizio non possono finire in due stati diversi.
  ///
  /// Ogni riga scritta deve portare `muscleGroupSnapshot`: lasciarlo nullo
  /// fa ricadere `estimateKcal` su 5.0 MET e sbaglia le calorie del 20-40% su
  /// gambe e cardio. Vedi `muscle_group_snapshot.dart`.
  Future<void> saveWorkout(Workout workout);

  /// Registra il risultato di una fase a tempo e cancella il suo checkpoint
  /// nella STESSA transazione.
  ///
  /// È idempotente: le righe della sessione esistono già e vengono riscritte
  /// con le sole serie concluse. Se l'app cade dopo il commit, al riavvio non
  /// trova un checkpoint da rieseguire; se cade prima, ritenta senza duplicare.
  Future<void> commitCircuitPhase(Workout workout);

  /// Chiude la sessione con l'istantanea costruita da
  /// `finalizeWorkoutSnapshot`: `endedAt`, durata e calorie insieme.
  ///
  /// Deve essere un'unica transazione: una chiusura senza le sue metriche è
  /// peggio di una sessione ancora aperta, perché non si vede.
  Future<void> finalizeWorkout(Workout snapshot);

  /// Aggiorna solo pausa e pause accumulate, senza toccare gli esercizi.
  Future<void> updatePauseState(
    String workoutId, {
    required DateTime? pausedAt,
    required int accumulatedPauseSeconds,
  });

  /// Aggiorna solo la rotta di ripresa e il checkpoint del circuito.
  ///
  /// Separato da [saveWorkout] apposta: il circuito lo chiama a ogni cambio di
  /// fase, e riscrivere tutte le serie a ogni beep sarebbe assurdo.
  Future<void> updateResumeState(
    String workoutId, {
    required String? resumePath,
    required Map<String, dynamic>? circuitCheckpoint,
  });

  /// Le sessioni chiuse più recenti, per calcolare i record personali su cui
  /// confrontare la serie appena fatta. La sessione in corso va esclusa da chi
  /// chiama (`recordsFromHistory(excludeWorkoutId: ...)`).
  Future<List<Workout>> recentClosedWorkouts({int limit = 200});

  /// Le pesate più recenti. Serve `pickBodyKg`, che prende SEMPRE l'ultima
  /// pesata reale e non un peso congelato nel profilo.
  Future<List<BodyWeightSample>> recentBodyWeights({int limit = 10});
}

/// Il profilo ha già una sessione aperta.
///
/// Porta con sé quella che c'è: senza, la schermata potrebbe solo dire «non
/// puoi», mentre la cosa utile da offrire è «riprendi quella di prima».
class ActiveWorkoutAlreadyOpen implements Exception {
  const ActiveWorkoutAlreadyOpen(this.existing);

  final Workout existing;

  @override
  String toString() =>
      'ActiveWorkoutAlreadyOpen(${existing.id}, iniziata ${existing.startedAt})';
}

/// L'esito di un tentativo di avvio, come lo vede la schermata.
sealed class StartWorkoutResult {
  const StartWorkoutResult();
}

/// Sessione aperta: si può entrare.
final class WorkoutStarted extends StartWorkoutResult {
  const WorkoutStarted(this.workout);

  final Workout workout;
}

/// Ce n'era già una aperta. NON è un errore da mostrare come tale: è una
/// situazione normale (l'app è stata chiusa a metà allenamento) e la risposta
/// giusta è proporre di riprenderla.
final class WorkoutAlreadyRunning extends StartWorkoutResult {
  const WorkoutAlreadyRunning(this.existing);

  final Workout existing;

  /// Il messaggio da mostrare. Dice da quando è aperta, perché è il dato con
  /// cui l'utente decide se riprenderla o chiuderla.
  String message(DateTime now) {
    final elapsed = now.difference(existing.startedAt);
    if (elapsed.inMinutes < 1) {
      return 'Hai già un allenamento aperto, iniziato adesso.';
    }
    if (elapsed.inHours < 1) {
      return 'Hai già un allenamento aperto da ${elapsed.inMinutes} minuti.';
    }
    if (elapsed.inHours < 24) {
      final ore = elapsed.inHours;
      return 'Hai già un allenamento aperto da $ore ${ore == 1 ? 'ora' : 'ore'}.';
    }
    final giorni = elapsed.inDays;
    return 'Hai un allenamento rimasto aperto da $giorni '
        '${giorni == 1 ? 'giorno' : 'giorni'}.';
  }
}

/// L'avvio è fallito per un motivo tecnico (disco pieno, database chiuso).
final class WorkoutStartFailed extends StartWorkoutResult {
  const WorkoutStartFailed(this.error);

  final Object error;
}
