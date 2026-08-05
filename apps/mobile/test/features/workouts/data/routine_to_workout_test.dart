import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';
import 'package:kal_tracker/features/routines/domain/routine_models.dart';
import 'package:kal_tracker/features/workouts/data/routine_to_workout.dart';
import 'package:kal_tracker/features/workouts/domain/muscle_group_snapshot.dart';
import 'package:kal_tracker/features/workouts/domain/superset_flow.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';

RoutineExerciseRef _ref(
  String id, {
  String? name,
  MuscleGroup muscleGroup = MuscleGroup.petto,
  ExerciseTrackingMode trackingMode = ExerciseTrackingMode.weightReps,
  bool isMissing = false,
  bool inSuperset = false,
  int? warmupDurationSec,
  ExercisePrescription prescription = ExercisePrescription.empty,
}) => RoutineExerciseRef(
  exerciseRefId: id,
  name: name ?? id,
  muscleGroup: muscleGroup,
  trackingMode: trackingMode,
  isMissing: isMissing,
  inSupersetWithPrevious: inSuperset,
  warmupDurationSec: warmupDurationSec,
  prescription: prescription,
);

RoutineDetails _routine({
  List<RoutineExerciseRef> warmup = const [],
  List<RoutineExerciseRef> main = const [],
  List<RoutineExerciseRef> finisher = const [],
  List<RoutineIntervalSegment> segments = const [],
  bool isCircuit = false,
  int rounds = 3,
  int workSec = 30,
  int shortRestSec = 30,
  int warmupWorkSec = 30,
  int warmupRestSec = 15,
}) => RoutineDetails(
  id: 'r1',
  name: 'Giorno 1',
  warmup: warmup,
  main: main,
  finisher: finisher,
  segments: segments,
  isCircuit: isCircuit,
  rounds: rounds,
  workSec: workSec,
  shortRestSec: shortRestSec,
  warmupWorkSec: warmupWorkSec,
  warmupRestSec: warmupRestSec,
);

void main() {
  test('la prescrizione diventa le celle da spuntare', () {
    final rows = workoutExercisesFromRoutine(
      _routine(
        main: [
          _ref(
            'panca',
            prescription: const ExercisePrescription(
              sets: 4,
              reps: 6,
              restSec: 120,
            ),
          ),
        ],
      ),
    );

    expect(rows, hasLength(1));
    expect(rows.single.sets, hasLength(4));
    expect(rows.single.restSeconds, 120);
    // Le ripetizioni sono già scritte: spuntare una serie andata come previsto
    // costa un tocco.
    expect(rows.single.sets.every((set) => set.reps == 6), isTrue);
    // Il peso no: è l'unica cosa che cambia davvero, e un numero precompilato
    // si spunta per distrazione.
    expect(rows.single.sets.every((set) => set.weightKg == null), isTrue);
    expect(rows.single.sets.every((set) => set.completed), isFalse);
  });

  test('dove la scheda tace valgono i predefiniti che la scheda dichiara', () {
    final rows = workoutExercisesFromRoutine(_routine(main: [_ref('panca')]));

    expect(rows.single.sets, hasLength(PrescriptionDefaults.sets));
    expect(rows.single.sets.first.reps, PrescriptionDefaults.reps);
    expect(rows.single.restSeconds, PrescriptionDefaults.restSec);
  });

  test('un esercizio a tempo riceve la durata, non le ripetizioni', () {
    final rows = workoutExercisesFromRoutine(
      _routine(
        main: [
          _ref(
            'plank',
            trackingMode: ExerciseTrackingMode.timeOnly,
            prescription: const ExercisePrescription(sets: 2, durationSec: 45),
          ),
        ],
      ),
    );

    expect(rows.single.sets, hasLength(2));
    expect(rows.single.sets.first.durationSec, 45);
    expect(rows.single.sets.first.reps, isNull);
  });

  test('il riscaldamento è una cella sola, a tempo e marcata', () {
    final rows = workoutExercisesFromRoutine(
      _routine(
        warmup: [_ref('cyclette', warmupDurationSec: 300)],
        main: [_ref('panca')],
        warmupRestSec: 20,
      ),
    );

    final warmup = rows.first;
    expect(warmup.isWarmup, isTrue);
    expect(warmup.sets, hasLength(1));
    expect(warmup.sets.single.durationSec, 300);
    expect(warmup.sets.single.isWarmup, isTrue);
    expect(warmup.restSeconds, 20);
    // «Solo tempo» e non «tempo (peso facoltativo)»: quest'ultimo vale 8 MET,
    // come il cardio, e gonfierebbe le calorie di un riscaldamento tranquillo.
    expect(warmup.trackingMode, ExerciseTrackingMode.timeOnly);
  });

  test('un passo di riscaldamento già a tempo conserva la sua modalità', () {
    final rows = workoutExercisesFromRoutine(
      _routine(
        warmup: [
          _ref(
            'corsa',
            trackingMode: ExerciseTrackingMode.distanceTime,
            warmupDurationSec: 240,
          ),
        ],
        main: [_ref('panca')],
      ),
    );

    expect(rows.first.trackingMode, ExerciseTrackingMode.distanceTime);
  });

  test('senza durata il passo di riscaldamento prende quella della scheda', () {
    final rows = workoutExercisesFromRoutine(
      _routine(
        warmup: [_ref('mobilita')],
        main: [_ref('panca')],
        warmupWorkSec: 45,
      ),
    );

    expect(rows.first.sets.single.durationSec, 45);
  });

  test('la superserie resta una catena, e non parte dal riscaldamento', () {
    final rows = workoutExercisesFromRoutine(
      _routine(
        warmup: [_ref('cyclette', warmupDurationSec: 300)],
        main: [_ref('curl'), _ref('french press', inSuperset: true)],
      ),
    );

    // Il primo esercizio principale NON è più in posizione 0: senza il
    // controllo esplicito, il riscaldamento finirebbe dentro la superserie.
    expect(rows[1].isInSupersetWithPrevious, isFalse);
    expect(rows[2].isInSupersetWithPrevious, isTrue);

    final workout = Workout(
      id: 'w1',
      startedAt: DateTime.utc(2026, 8, 6, 18),
      exercises: rows,
    );
    expect(supersetGroupContaining(workout, 1), [1, 2]);
    expect(supersetGroupContaining(workout, 0), isNull);
  });

  test('una scheda a circuito diventa round a tempo', () {
    final rows = workoutExercisesFromRoutine(
      _routine(
        main: [_ref('burpee'), _ref('jumping jack')],
        isCircuit: true,
        rounds: 4,
        workSec: 40,
        shortRestSec: 20,
      ),
    );

    expect(rows, hasLength(2));
    expect(rows.first.sets, hasLength(4));
    expect(rows.first.sets.first.durationSec, 40);
    expect(rows.first.restSeconds, 20);
    // 8 MET: è la modalità con cui `kcal_estimator` conta il lavoro a
    // intervalli.
    expect(rows.first.trackingMode, ExerciseTrackingMode.timed);
  });

  test('dentro un blocco a tempo comanda il blocco, non la prescrizione', () {
    final rows = workoutExercisesFromRoutine(
      _routine(
        main: [
          _ref('panca', prescription: const ExercisePrescription(sets: 5)),
          _ref(
            'kettlebell',
            prescription: const ExercisePrescription(sets: 5, reps: 12),
          ),
        ],
        segments: [
          const RoutineIntervalSegment(
            segmentIndex: 0,
            startIdx: 1,
            endIdx: 2,
            workSec: 50,
            restSec: 10,
            rounds: 3,
          ),
        ],
      ),
    );

    expect(rows.first.sets, hasLength(5)); // fuori dal blocco: prescrizione
    expect(rows[1].sets, hasLength(3)); // dentro: round del blocco
    expect(rows[1].sets.first.durationSec, 50);
    expect(rows[1].restSeconds, 10);
    // Le righe pre-costruite NON portano l'indice del blocco: quello marca le
    // righe APPESE da un'esecuzione col cronometro.
    expect(rows[1].intervalSegmentIndex, isNull);
  });

  test('il finisher si esegue con la sua prescrizione, marcato', () {
    final rows = workoutExercisesFromRoutine(
      _routine(
        main: [_ref('panca')],
        finisher: [
          _ref(
            'push up',
            trackingMode: ExerciseTrackingMode.bodyweightReps,
            prescription: const ExercisePrescription(sets: 1, reps: 30),
          ),
        ],
        isCircuit: true,
        rounds: 5,
      ),
    );

    final finisher = rows.last;
    expect(finisher.isFinisher, isTrue);
    expect(finisher.sets, hasLength(1));
    expect(finisher.sets.single.reps, 30);
  });

  /// Il vincolo del compito: senza gruppo muscolare `estimateKcal` ricade su
  /// 5.0 MET e sbaglia del 20-40% su gambe e cardio.
  test('ogni riga porta il suo gruppo muscolare', () {
    final rows = workoutExercisesFromRoutine(
      _routine(
        warmup: [
          _ref(
            'cyclette',
            muscleGroup: MuscleGroup.cardio,
            warmupDurationSec: 300,
          ),
        ],
        main: [_ref('squat', muscleGroup: MuscleGroup.gambe)],
        finisher: [_ref('plank', muscleGroup: MuscleGroup.addome)],
      ),
    );

    final workout = Workout(
      id: 'w1',
      startedAt: DateTime.utc(2026, 8, 6, 18),
      exercises: rows,
    );
    expect(exercisesMissingMuscleGroupSnapshot(workout), isEmpty);
    expect(muscleGroupsFromSnapshots(workout)['squat'], MuscleGroup.gambe);
    expect(muscleGroupsFromSnapshots(workout)['cyclette'], MuscleGroup.cardio);
  });

  test('un esercizio sparito dal catalogo lascia il gruppo VUOTO', () {
    final rows = workoutExercisesFromRoutine(
      _routine(
        main: [
          // La scheda mostra `altro` per poter disegnare la riga: quel ripiego
          // non deve diventare un dato salvato.
          _ref('fantasma', muscleGroup: MuscleGroup.altro, isMissing: true),
        ],
      ),
    );

    expect(rows.single.muscleGroup, isNull);
  });
}
