/// Da una scheda alla sessione da eseguire.
///
/// È una funzione pura, e sta in `data/` perché è una TRADUZIONE fra due
/// modelli (`RoutineDetails` → `WorkoutExercise`) e non una regola di
/// allenamento: chi la legge deve poter confrontare i due lati senza aprire il
/// database.
///
/// Tre cose sono deliberate e vanno lette insieme:
///
/// 1. **Le serie nascono già scritte.** Una scheda dice «3×8, recupero 90″»:
///    riportare quei numeri nelle celle significa che spuntare una serie andata
///    come previsto costa un tocco invece di due campi da compilare. Dove la
///    prescrizione tace valgono i [PrescriptionDefaults], gli STESSI che la
///    scheda mostra come «(predefinito)» e usa per la durata stimata — se qui
///    ne usassi altri, l'app direbbe due numeri diversi per la stessa scheda.
///    Il peso NON si prevede: è l'unica cosa che cambia davvero da sessione a
///    sessione, e un numero sbagliato precompilato si spunta per distrazione.
///
/// 2. **Il gruppo muscolare viaggia con la riga.** Serve a `kcal_estimator`, e
///    lasciarlo nullo costa il 20-40% sulle calorie di gambe e cardio. Quando
///    l'esercizio non è più in catalogo resta però NULLO e non `altro`: la
///    scheda in quel caso ripiega su `altro` per poterlo mostrare, ma scrivere
///    quel ripiego nella sessione significherebbe salvare una supposizione al
///    posto di un dato mancante — e il repository, che il catalogo lo
///    interroga davvero, non avrebbe più modo di distinguerli.
///
/// 3. **La catena di superserie non può cominciare dalla prima riga.** Con un
///    riscaldamento davanti, il primo esercizio principale NON è più in
///    posizione 0: senza il controllo su `index > 0` il flusso delle superserie
///    incatenerebbe l'ultimo passo di riscaldamento al primo esercizio vero.
library;

import 'package:kal_tracker/features/routines/domain/routine_models.dart';
import 'package:kal_tracker/features/workouts/domain/exercise_kind.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';

/// Le righe di sessione che una scheda produce, nell'ordine di esecuzione:
/// riscaldamento, blocco principale, finisher.
List<WorkoutExercise> workoutExercisesFromRoutine(RoutineDetails routine) {
  final rows = <WorkoutExercise>[];

  for (final step in routine.warmup) {
    rows.add(_warmupRow(step, routine));
  }

  for (var index = 0; index < routine.main.length; index++) {
    // In un circuito comanda la configurazione della scheda, altrimenti
    // comanda il blocco a tempo che contiene questa posizione (se c'è).
    final segment = routine.isCircuit ? null : routine.segmentAt(index);
    rows.add(
      _mainRow(routine.main[index], routine, segment, chainable: index > 0),
    );
  }

  for (final exercise in routine.finisher) {
    rows.add(_finisherRow(exercise));
  }

  return rows;
}

WorkoutExercise _warmupRow(RoutineExerciseRef step, RoutineDetails routine) {
  // Un passo di riscaldamento si misura in secondi. Se l'esercizio ha già una
  // modalità a tempo si tiene la sua — «corsa 5 minuti» resta distanza+tempo,
  // e Marco può registrare i metri — altrimenti diventa «solo tempo», che è
  // quello che il passo è davvero.
  final mode = step.trackingMode.isTimed
      ? step.trackingMode
      : ExerciseTrackingMode.timeOnly;
  return WorkoutExercise(
    exerciseId: step.exerciseRefId,
    exerciseName: step.name,
    trackingMode: mode,
    muscleGroup: _groupOf(step),
    restSeconds: routine.warmupRestSec,
    isWarmup: true,
    sets: [
      WorkoutSet(
        durationSec: step.warmupDurationSec ?? routine.warmupWorkSec,
        isWarmup: true,
      ),
    ],
  );
}

WorkoutExercise _mainRow(
  RoutineExerciseRef exercise,
  RoutineDetails routine,
  RoutineIntervalSegment? segment, {
  required bool chainable,
}) {
  if (routine.isCircuit) {
    return _timedRow(
      exercise,
      rounds: routine.rounds,
      workSec: routine.workSec,
      restSec: routine.shortRestSec,
      chained: chainable && exercise.inSupersetWithPrevious,
    );
  }
  if (segment != null) {
    return _timedRow(
      exercise,
      rounds: segment.rounds,
      workSec: segment.workSec,
      restSec: segment.restSec,
      chained: chainable && exercise.inSupersetWithPrevious,
    );
  }
  return _prescribedRow(
    exercise,
    chained: chainable && exercise.inSupersetWithPrevious,
  );
}

/// Il finisher, anche dentro un circuito, è un esercizio a sé: si esegue dopo
/// i round, con la sua prescrizione e non col cronometro del circuito.
WorkoutExercise _finisherRow(RoutineExerciseRef exercise) =>
    _prescribedRow(exercise, chained: false, isFinisher: true);

/// Riga «a tempo»: tante celle quanti sono i round, ognuna lunga il lavoro.
WorkoutExercise _timedRow(
  RoutineExerciseRef exercise, {
  required int rounds,
  required int workSec,
  required int restSec,
  required bool chained,
}) {
  return WorkoutExercise(
    exerciseId: exercise.exerciseRefId,
    exerciseName: exercise.name,
    // 8.0 MET, come il cardio: è la modalità con cui `kcal_estimator` conta il
    // lavoro a intervalli.
    trackingMode: ExerciseTrackingMode.timed,
    muscleGroup: _groupOf(exercise),
    restSeconds: restSec,
    isInSupersetWithPrevious: chained,
    sets: [
      for (var round = 0; round < rounds; round++)
        WorkoutSet(durationSec: workSec),
    ],
  );
}

/// Riga normale: la prescrizione della scheda diventa le celle da spuntare.
WorkoutExercise _prescribedRow(
  RoutineExerciseRef exercise, {
  required bool chained,
  bool isFinisher = false,
}) {
  final prescription = exercise.prescription;
  final mode = exercise.trackingMode;
  final sets = prescription.sets ?? PrescriptionDefaults.sets;
  final timed = mode.isTimed;
  return WorkoutExercise(
    exerciseId: exercise.exerciseRefId,
    exerciseName: exercise.name,
    trackingMode: mode,
    muscleGroup: _groupOf(exercise),
    restSeconds: prescription.restSec ?? PrescriptionDefaults.restSec,
    isFinisher: isFinisher,
    isInSupersetWithPrevious: chained,
    sets: [
      for (var index = 0; index < sets; index++)
        WorkoutSet(
          reps: timed ? null : (prescription.reps ?? PrescriptionDefaults.reps),
          durationSec: timed
              ? (prescription.durationSec ?? PrescriptionDefaults.durationSec)
              : null,
        ),
    ],
  );
}

/// Il gruppo muscolare della riga, o `null` quando l'esercizio non è più in
/// catalogo: vedi il punto 2 in testa al file.
MuscleGroup? _groupOf(RoutineExerciseRef exercise) =>
    exercise.isMissing ? null : exercise.muscleGroup;
