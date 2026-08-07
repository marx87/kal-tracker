/// La chiusura della sessione: un'unica istantanea con dentro `endedAt`,
/// durata e calorie.
///
/// Portata da Gym Tracker. L'unica differenza è che i gruppi muscolari non
/// arrivano più dal catalogo ma dagli snapshot già congelati sulle righe.
library;

import 'package:kal_tracker/features/workouts/domain/kcal_estimator.dart';
import 'package:kal_tracker/features/workouts/domain/muscle_group_snapshot.dart';
import 'package:kal_tracker/features/workouts/domain/session_effort.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';

/// Solo una distruzione IMPREVISTA della rotta può usare la copia locale come
/// salvataggio di sicurezza. Le uscite controllate hanno già atteso la loro
/// istantanea, e una sessione chiusa può avere XP, feedback e stato di sync
/// più nuovi lato repository: sovrascriverli con la copia stantia della
/// schermata li perderebbe.
bool shouldFlushWorkoutOnDispose({
  required bool isFinishing,
  required Workout? workout,
}) => !isFinishing && workout?.endedAt == null;

/// Costruisce l'istantanea immutabile che si scrive quando la sessione
/// finisce.
///
/// Tenere `endedAt`, esercizi e calorie NELLO STESSO valore impedisce a un
/// salvataggio ritardato di chiudere la sessione senza le sue metriche finali
/// — o peggio, di riaprirla.
///
/// `finalDurationSeconds` NON viene troncata a 24 ore: il tetto è una regola
/// di lettura (`Workout.duration`), e un CHECK in scrittura rifiuterebbe la
/// chiusura di una sessione dimenticata aperta trenta ore, che in Gym si
/// chiudeva mostrando 24 h.
///
/// [effort] è la risposta ai tre bersagli di fine sessione e sta QUI, nella
/// stessa istantanea di `endedAt`, per la stessa ragione delle calorie: una
/// sessione non deve poter finire scritta senza. Resta però nullable, perché
/// il dominio non decide per le chiusure che non passano dalla domanda —
/// riparazioni e importazioni chiudono sessioni vecchie, e su quelle
/// inventare un livello sarebbe peggio del buco. A esigere la risposta è la
/// schermata, che senza non chiude.
Workout finalizeWorkoutSnapshot({
  required Workout workout,
  required DateTime endedAt,
  required double bodyKg,
  SessionEffort? effort,
}) {
  final rawDuration = endedAt.difference(workout.startedAt);
  final activeDuration =
      rawDuration - Duration(seconds: workout.accumulatedPauseSeconds);
  final ended = workout.copyWith(
    endedAt: endedAt,
    finalDurationSeconds: activeDuration.isNegative
        ? 0
        : activeDuration.inSeconds,
    rpe: effort?.rpe,
    // Chiusa la sessione, la card «riprendi» non deve avere più niente a cui
    // puntare.
    clearResumeState: true,
    clearPausedAt: true,
  );
  final kcal = estimateKcal(
    workout: ended,
    exerciseGroups: muscleGroupsFromSnapshots(ended),
    bodyKg: bodyKg,
  );
  return ended.copyWith(totalKcal: kcal);
}
