import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/workouts/domain/cool_down_sequence.dart';
import 'package:kal_tracker/features/workouts/domain/exercise_kind.dart';
import 'package:kal_tracker/features/workouts/domain/kcal_estimator.dart';
import 'package:kal_tracker/features/workouts/domain/muscle_group_snapshot.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';
import 'package:kal_tracker/features/workouts/domain/workout_finalization.dart';

/// Le calorie e il peso corporeo: i due vincoli espliciti della consegna.
///
/// 1. il peso si legge dall'ULTIMA PESATA REALE, non da un valore congelato;
/// 2. `muscleGroupSnapshot` deve esserci, altrimenti si ricade su 5.0 MET.
/// Il secondo test misura l'errore vero invece di limitarsi a dire «diverso».

Workout _session({required List<WorkoutExercise> exercises, int minutes = 60}) {
  final start = DateTime(2026, 8, 5, 18);
  return Workout(
    id: 'w1',
    startedAt: start,
    endedAt: start.add(Duration(minutes: minutes)),
    exercises: exercises,
  );
}

WorkoutExercise _exercise(
  String id, {
  MuscleGroup? group,
  int completedSets = 4,
  ExerciseTrackingMode mode = ExerciseTrackingMode.weightReps,
}) => WorkoutExercise(
  exerciseId: id,
  exerciseName: id,
  trackingMode: mode,
  muscleGroup: group,
  sets: [
    for (var index = 0; index < completedSets; index++)
      const WorkoutSet(weightKg: 80, reps: 8, completed: true),
  ],
);

/// Calorie e MET medio della sessione, con i gruppi letti dagli snapshot come
/// li legge la chiusura vera.
SessionEnergy _energyOf(Workout workout, {double bodyKg = 94.5}) =>
    estimateKcal(
      workout: workout,
      exerciseGroups: muscleGroupsFromSnapshots(workout),
      bodyKg: bodyKg,
    );

void main() {
  group('peso corporeo', () {
    test('si prende l\'ultima pesata, non la prima della lista', () {
      final result = pickBodyKg(
        measurements: [
          BodyWeightSample(measuredAt: DateTime(2026, 5), kg: 97),
          BodyWeightSample(measuredAt: DateTime(2026, 6, 19), kg: 94.5),
          BodyWeightSample(measuredAt: DateTime(2026, 6), kg: 95.2),
        ],
      );

      expect(result.kg, 94.5);
      expect(result.source, 'ultima pesata');
    });

    test('senza pesate si ripiega, e lo si dice', () {
      final result = pickBodyKg(measurements: const []);

      expect(result.kg, kDefaultBodyKg);
      expect(result.source, contains('ripiego'));
    });
  });

  group('gruppo muscolare congelato', () {
    test('senza snapshot le calorie di una seduta di gambe sbagliano di oltre '
        'il 15%', () {
      final withGroup = _session(
        exercises: [_exercise('squat', group: MuscleGroup.gambe)],
      );
      final withoutGroup = _session(exercises: [_exercise('squat')]);

      final right = estimateKcal(
        workout: withGroup,
        exerciseGroups: muscleGroupsFromSnapshots(withGroup),
        bodyKg: 94.5,
      ).kcal;
      final wrong = estimateKcal(
        workout: withoutGroup,
        exerciseGroups: muscleGroupsFromSnapshots(withoutGroup),
        bodyKg: 94.5,
      ).kcal;

      // 6.0 MET contro 5.0 di ripiego: un sesto in meno.
      expect(wrong, lessThan(right));
      expect((right - wrong) / right, greaterThan(0.15));
    });

    test('sul cardio l\'errore è ancora più grosso', () {
      final withGroup = _session(
        exercises: [_exercise('corsa', group: MuscleGroup.cardio)],
      );
      final withoutGroup = _session(exercises: [_exercise('corsa')]);

      final right = estimateKcal(
        workout: withGroup,
        exerciseGroups: muscleGroupsFromSnapshots(withGroup),
        bodyKg: 94.5,
      ).kcal;
      final wrong = estimateKcal(
        workout: withoutGroup,
        exerciseGroups: muscleGroupsFromSnapshots(withoutGroup),
        bodyKg: 94.5,
      ).kcal;

      // 8.0 contro 5.0: si perde il 37,5%.
      expect((right - wrong) / right, greaterThan(0.35));
    });

    test('le righe senza gruppo si sanno elencare prima di scrivere', () {
      final workout = _session(
        exercises: [
          _exercise('squat', group: MuscleGroup.gambe),
          _exercise('affondi'),
        ],
      );

      expect(hasCompleteMuscleGroupSnapshots(workout), isFalse);
      expect(
        exercisesMissingMuscleGroupSnapshot(workout).single.exerciseId,
        'affondi',
      );
    });

    test(
      'il defaticamento senza gruppo NON è segnalato: lì il gruppo non entra '
      'nel calcolo',
      () {
        final workout = _session(
          exercises: [
            _exercise('squat', group: MuscleGroup.gambe),
            WorkoutExercise(
              exerciseId: 'cd-cobra',
              exerciseName: 'Cobra',
              isCooldown: true,
              sets: const [WorkoutSet(durationSec: 30, completed: true)],
            ),
          ],
        );

        expect(exercisesMissingMuscleGroupSnapshot(workout), isEmpty);
      },
    );
  });

  group('il MET medio esce insieme alle calorie', () {
    test('una seduta di sole gambe esce a 6,0', () {
      final workout = _session(
        exercises: [_exercise('squat', group: MuscleGroup.gambe)],
      );

      expect(_energyOf(workout).averageMet, 6.0);
    });

    test('la media pesa le serie completate, non gli esercizi', () {
      // Quattro serie di gambe (6,0) e due di polpacci (4,0): la media resta
      // vicina alle gambe, che è dove il tempo è passato davvero.
      final workout = _session(
        exercises: [
          _exercise('squat', group: MuscleGroup.gambe),
          _exercise('calf', group: MuscleGroup.polpacci, completedSets: 2),
        ],
      );

      expect(_energyOf(workout).averageMet, closeTo((6 * 4 + 4 * 2) / 6, 1e-9));
    });

    test('gli allungamenti non abbassano l\'intensità della seduta', () {
      final base = _session(
        exercises: [_exercise('squat', group: MuscleGroup.gambe)],
      );
      final withCoolDown = base.copyWith(
        exercises: [...base.exercises, ...coolDownAsWorkoutExercises()],
      );

      // 2,5 MET di mobilità in mezzo alla media direbbero che si è spinto
      // meno: il defaticamento esce dal tempo attivo, non dall'intensità.
      expect(_energyOf(withCoolDown).averageMet, 6.0);
    });

    test('le calorie tornano dal MET: MET × peso × ore', () {
      // È l'invariante di chi il riposo lo deve togliere: dal lordo si risale
      // alla quota netta solo se il MET è QUELLO con cui il lordo è uscito.
      final workout = _session(
        exercises: [_exercise('squat', group: MuscleGroup.gambe)],
        minutes: 90,
      );

      final energy = _energyOf(workout);

      expect(energy.kcal, closeTo(energy.averageMet * 94.5 * 1.5, 1e-9));
    });

    test('senza minuti attivi il MET è quello del riposo, non zero', () {
      // Sotto l'unità il moltiplicatore di attività legge un difetto a monte
      // e butta la settimana intera: una sessione aperta e chiusa per sbaglio
      // non deve avere quel potere.
      final energy = _energyOf(
        _session(
          exercises: [_exercise('squat', group: MuscleGroup.gambe)],
          minutes: 0,
        ),
      );

      expect(energy.kcal, 0);
      expect(energy.averageMet, 1);
    });

    test('la sessione senza esercizi dichiara il suo 5,0 di ripiego', () {
      expect(_energyOf(_session(exercises: const [])).averageMet, 5.0);
    });
  });

  group('defaticamento', () {
    test('le righe generate portano mobilità e nascono già fatte', () {
      final rows = coolDownAsWorkoutExercises();

      expect(rows, hasLength(kCoolDownSequence.length));
      expect(
        rows.every((row) => row.muscleGroup == MuscleGroup.mobilita),
        isTrue,
      );
      expect(rows.every((row) => row.isCooldown), isTrue);
      expect(rows.every((row) => row.sets.single.completed), isTrue);
      // Gli slug restano quelli dell'export: cambiarli spezzerebbe lo storico.
      expect(rows.first.exerciseId, 'cd-childpose');
    });

    test('gli allungamenti non gonfiano le calorie', () {
      final base = _session(
        exercises: [_exercise('squat', group: MuscleGroup.gambe)],
      );
      final withCoolDown = base.copyWith(
        exercises: [...base.exercises, ...coolDownAsWorkoutExercises()],
      );

      final without = estimateKcal(
        workout: base,
        exerciseGroups: muscleGroupsFromSnapshots(base),
        bodyKg: 94.5,
      ).kcal;
      final with_ = estimateKcal(
        workout: withCoolDown,
        exerciseGroups: muscleGroupsFromSnapshots(withCoolDown),
        bodyKg: 94.5,
      ).kcal;

      // Il defaticamento toglie i suoi minuti dal tempo attivo invece di
      // aggiungerne: non si guadagnano calorie stando a terra a respirare.
      expect(with_, lessThan(without));
    });
  });

  group('chiusura', () {
    test('la durata finale toglie le pause e le calorie arrivano insieme', () {
      final start = DateTime(2026, 8, 5, 18);
      final workout = Workout(
        id: 'w1',
        startedAt: start,
        accumulatedPauseSeconds: 600,
        resumePath: '/workout/w1/phase/main',
        pausedAt: start.add(const Duration(minutes: 30)),
        exercises: [_exercise('squat', group: MuscleGroup.gambe)],
      );

      final snapshot = finalizeWorkoutSnapshot(
        workout: workout,
        endedAt: start.add(const Duration(minutes: 70)),
        bodyKg: 94.5,
      );

      expect(snapshot.finalDurationSeconds, 60 * 60);
      expect(snapshot.totalKcal, greaterThan(0));
      // Chiusa la sessione, non c'è più niente da riprendere.
      expect(snapshot.resumePath, isNull);
      expect(snapshot.pausedAt, isNull);
    });

    test(
      'una sessione dimenticata aperta trenta ore si chiude senza troncare il '
      'dato scritto, e si LEGGE come 24',
      () {
        final start = DateTime(2026, 8, 5, 18);
        final snapshot = finalizeWorkoutSnapshot(
          workout: Workout(id: 'w1', startedAt: start, exercises: const []),
          endedAt: start.add(const Duration(hours: 30)),
          bodyKg: 94.5,
        );

        expect(snapshot.finalDurationSeconds, 30 * 3600);
        expect(snapshot.duration, const Duration(hours: 24));
      },
    );

    test('la copia locale si riversa solo su una distruzione imprevista', () {
      final open = Workout(
        id: 'w1',
        startedAt: DateTime(2026, 8, 5, 18),
        exercises: const [],
      );
      final closed = open.copyWith(endedAt: DateTime(2026, 8, 5, 19));

      expect(
        shouldFlushWorkoutOnDispose(isFinishing: false, workout: open),
        isTrue,
      );
      // Uscita controllata: l'istantanea è già stata attesa.
      expect(
        shouldFlushWorkoutOnDispose(isFinishing: true, workout: open),
        isFalse,
      );
      // Sessione chiusa: lato repository ci sono dati più nuovi.
      expect(
        shouldFlushWorkoutOnDispose(isFinishing: false, workout: closed),
        isFalse,
      );
    });
  });
}
