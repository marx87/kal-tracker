import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';
import 'package:kal_tracker/features/routines/data/routine_repository.dart';
import 'package:kal_tracker/features/routines/domain/routine_draft.dart';
import 'package:kal_tracker/features/routines/domain/routine_models.dart';
import 'package:kal_tracker/features/workouts/data/drift_live_workout_repository.dart';
import 'package:kal_tracker/features/workouts/data/routine_to_workout.dart';
import 'package:kal_tracker/features/workouts/domain/kcal_estimator.dart';
import 'package:kal_tracker/features/workouts/domain/live_workout_repository.dart';
import 'package:kal_tracker/features/workouts/domain/muscle_group_snapshot.dart';
import 'package:kal_tracker/features/workouts/domain/start_workout.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';
import 'package:kal_tracker/features/workouts/domain/workout_finalization.dart';

import '../history/workout_history_fixtures.dart';

/// Il repository vero contro il database vero: CHECK accesi, indice unico
/// parziale al suo posto, foreign key vive. Un finto qui non proverebbe
/// niente, perché quasi tutto quello che c'è da sbagliare lo sbaglia SQLite in
/// faccia a chi scrive.
void main() {
  late AppDatabase database;
  late DriftLiveWorkoutRepository repository;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    await seedProfile(database);
    repository = DriftLiveWorkoutRepository.forProfile(database, 'marco');
  });

  tearDown(() async {
    await database.close();
  });

  Future<void> seedCatalog() async {
    await seedExercise(
      database,
      id: 'squat',
      profileId: 'marco',
      name: 'Squat',
      muscleGroup: 'gambe',
    );
    await seedExercise(
      database,
      id: 'panca',
      profileId: 'marco',
      name: 'Panca piana',
      muscleGroup: 'petto',
    );
  }

  WorkoutExercise exercise(
    String id, {
    String? name,
    MuscleGroup? muscleGroup,
    int sets = 2,
    bool isWarmup = false,
    bool isCooldown = false,
    bool chained = false,
    int? restSeconds = 90,
  }) => WorkoutExercise(
    exerciseId: id,
    exerciseName: name ?? id,
    muscleGroup: muscleGroup,
    restSeconds: restSeconds,
    isWarmup: isWarmup,
    isCooldown: isCooldown,
    isInSupersetWithPrevious: chained,
    sets: [
      for (var index = 0; index < sets; index++)
        WorkoutSet(weightKg: 60, reps: 8, isWarmup: isWarmup),
    ],
  );

  group('avvio', () {
    test('apre la sessione con i suoi esercizi e le sue serie', () async {
      await seedCatalog();
      final started = await repository.startWorkout(
        routineName: 'Giorno 1',
        exercises: [exercise('squat'), exercise('panca', sets: 3)],
      );

      expect(started.isRunning, isTrue);
      expect(started.routineName, 'Giorno 1');
      expect(started.exercises, hasLength(2));
      expect(started.exercises.first.sets, hasLength(2));
      expect(started.exercises.last.sets, hasLength(3));
      // Riletta dal database, non tenuta in memoria.
      final reread = await repository.getById(started.id);
      expect(reread!.exercises.last.sets, hasLength(3));
      expect(await repository.activeWorkout(), isNotNull);
    });

    test('collega la scheda e ne congela il nome', () async {
      await seedCatalog();
      await seedRoutine(
        database,
        id: 'r-forza',
        profileId: 'marco',
        name: 'Forza A',
      );
      final started = await repository.startWorkout(
        routineId: 'r-forza',
        routineName: 'Forza A',
        exercises: [exercise('squat')],
      );

      final row = await (database.select(
        database.workouts,
      )..where((table) => table.id.equals(started.id))).getSingle();
      expect(row.routineId, 'r-forza');
      // Il CHECK pretende che i due valori coincidano, e l'id esterno è quello
      // che sopravvive alla cancellazione della scheda.
      expect(row.routineExternalId, 'r-forza');
      expect(row.routineNameSnapshot, 'Forza A');
    });

    test('una scheda che non esiste più non rompe l\'avvio', () async {
      await seedCatalog();
      final started = await repository.startWorkout(
        routineId: 'r-sparita',
        routineName: 'Vecchia scheda',
        exercises: [exercise('squat')],
      );

      final row = await (database.select(
        database.workouts,
      )..where((table) => table.id.equals(started.id))).getSingle();
      expect(row.routineId, isNull);
      expect(row.routineExternalId, 'r-sparita');
      expect(row.routineNameSnapshot, 'Vecchia scheda');
    });

    test('la seconda apertura è un rifiuto leggibile, non un errore di '
        'SQLite', () async {
      await seedCatalog();
      final first = await repository.startWorkout(
        exercises: [exercise('squat')],
      );

      await expectLater(
        repository.startWorkout(exercises: [exercise('panca')]),
        throwsA(
          isA<ActiveWorkoutAlreadyOpen>().having(
            // Porta con sé quella che c'è: senza, si potrebbe solo dire «non
            // puoi» invece di offrire «riprendi quella di prima».
            (error) => error.existing.id,
            'existing',
            first.id,
          ),
        ),
      );

      final open = await (database.select(
        database.workouts,
      )..where((table) => table.endedAt.isNull())).get();
      expect(open, hasLength(1));
    });

    test('l\'avvio dalla schermata diventa «ne hai già una»', () async {
      await seedCatalog();
      final first = await repository.startWorkout(
        exercises: [exercise('squat')],
      );

      final result = await startLiveWorkout(
        repository,
        exercises: [exercise('panca')],
      );
      expect(result, isA<WorkoutAlreadyRunning>());
      expect((result as WorkoutAlreadyRunning).existing.id, first.id);
      expect(
        result.message(first.startedAt.add(const Duration(minutes: 12))),
        contains('12 minuti'),
      );
    });

    test('chiusa una sessione se ne può aprire un\'altra', () async {
      await seedCatalog();
      final first = await repository.startWorkout(
        exercises: [exercise('squat')],
      );
      await repository.finalizeWorkout(
        finalizeWorkoutSnapshot(
          workout: first,
          endedAt: first.startedAt.add(const Duration(minutes: 40)),
          bodyKg: 95.8,
        ),
      );

      final second = await repository.startWorkout(
        exercises: [exercise('panca')],
      );
      expect(second.id, isNot(first.id));
      expect((await repository.activeWorkout())!.id, second.id);
    });
  });

  group('gruppo muscolare', () {
    /// Il vincolo del compito: `muscleGroupSnapshot` va riempito a OGNI
    /// scrittura. Lasciarlo nullo fa ricadere `estimateKcal` su 5.0 MET e
    /// sbaglia le calorie del 20-40% su gambe e cardio.
    test('la riga senza gruppo lo prende dal catalogo, in scrittura', () async {
      await seedCatalog();
      final started = await repository.startWorkout(
        // Nessuno dei due porta il gruppo: lo deve mettere il repository.
        exercises: [exercise('squat'), exercise('panca')],
      );

      final rows = await database.select(database.workoutExercises).get();
      expect(rows.map((row) => row.muscleGroupSnapshot), ['gambe', 'petto']);

      final reread = await repository.getById(started.id);
      expect(exercisesMissingMuscleGroupSnapshot(reread!), isEmpty);
      expect(muscleGroupsFromSnapshots(reread)['squat'], MuscleGroup.gambe);
    });

    test('il gruppo della riga vince su quello del catalogo', () async {
      await seedCatalog();
      // Nello storico 72 righe su 250 divergono dal catalogo: la sessione
      // registra quello che quel giorno era vero.
      await repository.startWorkout(
        exercises: [exercise('squat', muscleGroup: MuscleGroup.fullbody)],
      );

      final row = await database.select(database.workoutExercises).getSingle();
      expect(row.muscleGroupSnapshot, 'fullbody');
    });

    test('un esercizio fuori catalogo resta senza gruppo e si vede', () async {
      final started = await repository.startWorkout(
        exercises: [exercise('esercizio-fantasma')],
      );

      final row = await database.select(database.workoutExercises).getSingle();
      expect(row.muscleGroupSnapshot, isNull);
      // La FK viva è nulla, l'id originale no: è la chiave con cui i record
      // personali raggruppano.
      expect(row.exerciseId, isNull);
      expect(row.exerciseRefId, 'esercizio-fantasma');

      final reread = await repository.getById(started.id);
      expect(exercisesMissingMuscleGroupSnapshot(reread!), hasLength(1));
    });

    test('anche il salvataggio successivo riempie il gruppo', () async {
      await seedCatalog();
      final started = await repository.startWorkout(
        exercises: [exercise('squat', muscleGroup: MuscleGroup.gambe)],
      );

      // Una riga aggiunta a metà sessione (un blocco a tempo appeso, un
      // esercizio in più) non passa dall'avvio: se il buco si richiudesse solo
      // lì, le calorie tornerebbero sbagliate al primo esercizio aggiunto.
      await repository.saveWorkout(
        started.copyWith(exercises: [...started.exercises, exercise('panca')]),
      );

      final rows = await database.select(database.workoutExercises).get();
      expect(rows, hasLength(2));
      expect(rows.map((row) => row.muscleGroupSnapshot).toSet(), {
        'gambe',
        'petto',
      });
    });
  });

  group('salvataggio', () {
    test('la serie spuntata resta spuntata dopo una rilettura', () async {
      await seedCatalog();
      final started = await repository.startWorkout(
        exercises: [exercise('squat')],
      );

      final sets = List<WorkoutSet>.of(started.exercises.first.sets);
      sets[0] = sets[0].copyWith(completed: true, weightKg: 82.5, rpe: 8);
      await repository.saveWorkout(
        started.copyWith(
          exercises: [started.exercises.first.copyWith(sets: sets)],
        ),
      );

      final reread = await repository.getById(started.id);
      final first = reread!.exercises.first.sets.first;
      expect(first.completed, isTrue);
      expect(first.weightKg, 82.5);
      expect(first.rpe, 8);
      expect(reread.exercises.first.sets.last.completed, isFalse);
    });

    /// L'identità di una cella è la sua posizione: se ogni salvataggio
    /// inventasse id nuovi, la stessa serie cambierebbe riga a ogni tocco e il
    /// server vedrebbe righe nuove al posto di aggiornamenti.
    test(
      'gli id delle righe non cambiano da un salvataggio all\'altro',
      () async {
        await seedCatalog();
        final started = await repository.startWorkout(
          exercises: [exercise('squat')],
        );
        final before = await database.select(database.workoutSets).get();

        await repository.saveWorkout(started);
        final after = await database.select(database.workoutSets).get();

        expect(
          after.map((row) => row.id).toSet(),
          before.map((row) => row.id).toSet(),
        );
      },
    );

    test('togliere una serie la toglie anche dal database', () async {
      await seedCatalog();
      final started = await repository.startWorkout(
        exercises: [exercise('squat', sets: 4)],
      );
      expect(await database.select(database.workoutSets).get(), hasLength(4));

      await repository.saveWorkout(
        started.copyWith(
          exercises: [
            started.exercises.first.copyWith(
              sets: started.exercises.first.sets.take(2).toList(),
            ),
          ],
        ),
      );

      expect(await database.select(database.workoutSets).get(), hasLength(2));
    });

    test('la pausa e le pause accumulate si scrivono', () async {
      await seedCatalog();
      final started = await repository.startWorkout(
        exercises: [exercise('squat')],
      );
      final pausedAt = DateTime.utc(2026, 8, 6, 19);

      await repository.saveWorkout(started.copyWith(pausedAt: pausedAt));
      expect((await repository.getById(started.id))!.pausedAt, isNotNull);

      // La ripresa chiude la pausa sommandola: senza, una sessione ripresa il
      // giorno dopo risulterebbe durata quindici ore.
      await repository.saveWorkout(
        started.copyWith(accumulatedPauseSeconds: 900, clearPausedAt: true),
      );
      final reread = await repository.getById(started.id);
      expect(reread!.pausedAt, isNull);
      expect(reread.accumulatedPauseSeconds, 900);
    });

    /// Il checkpoint del circuito viaggia su `updateResumeState` a ogni cambio
    /// di fase: se il salvataggio normale riscrivesse anche quel campo, una
    /// copia vecchia in mano alla schermata cancellerebbe l'ultimo progresso e
    /// la ripresa finirebbe sulla fase sbagliata.
    test('il salvataggio non tocca la rotta di ripresa', () async {
      await seedCatalog();
      final started = await repository.startWorkout(
        exercises: [exercise('squat')],
      );
      await repository.updateResumeState(
        started.id,
        resumePath: '/workout/${started.id}/phase/segment?seg=1',
        circuitCheckpoint: {'round': 2, 'stepIndex': 1},
      );

      // `started` è la copia di PRIMA del checkpoint: è esattamente lo stato
      // in cui la schermata dal vivo si trova.
      await repository.saveWorkout(started);

      final reread = await repository.getById(started.id);
      expect(reread!.resumePath, contains('seg=1'));
      expect(reread.circuitCheckpoint, {'round': 2, 'stepIndex': 1});
    });

    test('salvare una sessione che non c\'è più è un errore, non un '
        'silenzio', () async {
      await expectLater(
        repository.saveWorkout(
          Workout(
            id: 'mai-esistita',
            startedAt: DateTime.utc(2026, 8, 6),
            exercises: const [],
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('ripresa', () {
    test(
      'la sessione interrotta si ritrova con tutto quello che aveva',
      () async {
        await seedCatalog();
        final started = await repository.startWorkout(
          routineName: 'Giorno 1',
          exercises: [exercise('squat'), exercise('panca', chained: true)],
        );
        final sets = List<WorkoutSet>.of(started.exercises.first.sets);
        sets[0] = sets[0].copyWith(completed: true, weightKg: 100);
        await repository.saveWorkout(
          started.copyWith(
            exercises: [
              started.exercises.first.copyWith(sets: sets),
              started.exercises.last,
            ],
            pausedAt: DateTime.utc(2026, 8, 6, 20),
            accumulatedPauseSeconds: 120,
          ),
        );
        await repository.updateResumeState(
          started.id,
          resumePath: '/workout/${started.id}/phase/segment?seg=0',
          circuitCheckpoint: {'phase': 'work', 'secondsLeft': 12},
        );

        // È quello che fa l'app riaprendosi: chiede la sessione aperta e ci
        // rientra.
        final resumed = await repository.activeWorkout();
        expect(resumed, isNotNull);
        expect(resumed!.id, started.id);
        expect(resumed.routineName, 'Giorno 1');
        expect(resumed.exercises.first.sets.first.completed, isTrue);
        expect(resumed.exercises.first.sets.first.weightKg, 100);
        expect(resumed.exercises.last.isInSupersetWithPrevious, isTrue);
        expect(resumed.pausedAt, isNotNull);
        expect(resumed.accumulatedPauseSeconds, 120);
        expect(resumed.resumePath, endsWith('seg=0'));
        expect(resumed.circuitCheckpoint!['secondsLeft'], 12);
      },
    );

    test('un checkpoint illeggibile non impedisce di allenarsi', () async {
      await seedCatalog();
      final started = await repository.startWorkout(
        exercises: [exercise('squat')],
      );
      await (database.update(
        database.workouts,
      )..where((row) => row.id.equals(started.id))).write(
        WorkoutsCompanion(circuitCheckpointJson: const Value('{rotto')),
      );

      final reread = await repository.getById(started.id);
      expect(reread, isNotNull);
      expect(reread!.circuitCheckpoint, isNull);
    });

    test(
      'i marcatori dei blocchi a tempo sopravvivono al salvataggio',
      () async {
        await seedCatalog();
        final started = await repository.startWorkout(
          exercises: [exercise('squat')],
        );

        // Lo stesso indice può stare fra i completati E fra i parziali: sono
        // liste indipendenti, e la ripresa guarda prima i parziali.
        await repository.saveWorkout(
          started.copyWith(
            completedIntervalSegmentIndices: [0, 1],
            completedIntervalSegmentSignatures: {0: '{"work":40}'},
            partialIntervalSegmentIndices: [1],
          ),
        );

        final reread = await repository.getById(started.id);
        expect(reread!.completedIntervalSegmentIndices, [0, 1]);
        expect(reread.partialIntervalSegmentIndices, [1]);
        expect(reread.completedIntervalSegmentSignatures[0], '{"work":40}');
        expect(
          reread.completedIntervalSegmentSignatures.containsKey(1),
          isFalse,
        );
      },
    );
  });

  group('chiusura', () {
    test('scrive fine, durata e calorie insieme', () async {
      await seedCatalog();
      final started = await repository.startWorkout(
        exercises: [exercise('squat', muscleGroup: MuscleGroup.gambe)],
      );
      final completed = started.copyWith(
        exercises: [
          started.exercises.first.copyWith(
            sets: [
              for (final set in started.exercises.first.sets)
                set.copyWith(completed: true),
            ],
          ),
        ],
      );
      final snapshot = finalizeWorkoutSnapshot(
        workout: completed,
        endedAt: started.startedAt.add(const Duration(minutes: 50)),
        bodyKg: 95.8,
      );
      await repository.finalizeWorkout(snapshot);

      final row = await (database.select(
        database.workouts,
      )..where((table) => table.id.equals(started.id))).getSingle();
      expect(row.endedAt, isNotNull);
      expect(row.finalDurationSeconds, 50 * 60);
      // 6.0 MET (gambe) × 95,8 kg × 50/60 h ≈ 479 kcal.
      expect(row.totalKcal, closeTo(479, 2));
      expect(row.durationSuspect, isFalse);
      expect(await repository.activeWorkout(), isNull);
    });

    test('chiudendo si cancella la rotta di ripresa', () async {
      await seedCatalog();
      final started = await repository.startWorkout(
        exercises: [exercise('squat')],
      );
      await repository.updateResumeState(
        started.id,
        resumePath: '/workout/${started.id}/phase/segment?seg=0',
        circuitCheckpoint: {'round': 1},
      );

      final reloaded = await repository.getById(started.id);
      await repository.finalizeWorkout(
        finalizeWorkoutSnapshot(
          workout: reloaded!,
          endedAt: started.startedAt.add(const Duration(minutes: 30)),
          bodyKg: 95.8,
        ),
      );

      final closed = await repository.getById(started.id);
      expect(closed!.resumePath, isNull);
      expect(closed.circuitCheckpoint, isNull);
      expect(closed.pausedAt, isNull);
    });

    /// La sessione dimenticata aperta trenta ore esiste davvero (una, nello
    /// storico, è rimasta aperta 536 ore): si salva GREZZA e si marca, non si
    /// tronca.
    test(
      'una sessione dimenticata aperta si marca, non si rettifica',
      () async {
        await seedCatalog();
        final started = await repository.startWorkout(
          exercises: [exercise('squat')],
        );
        await repository.finalizeWorkout(
          finalizeWorkoutSnapshot(
            workout: started,
            endedAt: started.startedAt.add(const Duration(hours: 30)),
            bodyKg: 95.8,
          ),
        );

        final row = await (database.select(
          database.workouts,
        )..where((table) => table.id.equals(started.id))).getSingle();
        expect(row.finalDurationSeconds, 30 * 3600);
        expect(row.durationSuspect, isTrue);
        // Il tetto di 24 h vale in LETTURA.
        expect(
          (await repository.getById(started.id))!.duration,
          const Duration(hours: 24),
        );
      },
    );

    test('una fine prima dell\'inizio non blocca la chiusura', () async {
      await seedCatalog();
      final started = await repository.startWorkout(
        exercises: [exercise('squat')],
      );

      await repository.finalizeWorkout(
        started.copyWith(
          endedAt: started.startedAt.subtract(const Duration(minutes: 5)),
          finalDurationSeconds: 0,
        ),
      );

      final closed = await repository.getById(started.id);
      expect(closed!.endedAt, isNotNull);
      expect(closed.isRunning, isFalse);
    });

    /// Sul server c'è lo stesso indice unico parziale che c'è qui: spedire una
    /// sessione ancora aperta mentre l'altro dispositivo ne ha una sua sarebbe
    /// un 23505 ritentabile per sempre, cioè una coda ferma in testa.
    test('in coda di sincronizzazione ci va solo la sessione chiusa', () async {
      await seedCatalog();
      final started = await repository.startWorkout(
        exercises: [exercise('squat', muscleGroup: MuscleGroup.gambe)],
      );
      await repository.saveWorkout(started);
      expect(await database.select(database.syncOutbox).get(), isEmpty);

      await repository.finalizeWorkout(
        finalizeWorkoutSnapshot(
          workout: started,
          endedAt: started.startedAt.add(const Duration(minutes: 45)),
          bodyKg: 95.8,
        ),
      );

      final rows = await database.select(database.syncOutbox).get();
      expect(rows, hasLength(1));
      expect(rows.single.entityType, 'workout');
      expect(rows.single.entityId, started.id);

      final payload =
          jsonDecode(rows.single.payloadJson) as Map<String, Object?>;
      expect(payload['profile_id'], 'marco');
      expect(payload['ended_at'], isNotNull);
      // Le tre liste dei figli ci sono sempre: per il gateway una chiave
      // assente significa «questa scrittura non parla dei figli».
      expect(payload.containsKey('exercises'), isTrue);
      expect(payload.containsKey('pain_points'), isTrue);
      expect(payload.containsKey('interval_segments'), isTrue);
      final exercises = payload['exercises']! as List<Object?>;
      final first = exercises.single as Map<String, Object?>;
      expect(first['muscle_group_snapshot'], 'gambe');
      expect((first['sets']! as List<Object?>), hasLength(2));
    });
  });

  group('letture di contorno', () {
    /// Il peso per le calorie MET esce dall'ULTIMA pesata reale, non da un
    /// valore congelato nel profilo.
    test('le pesate arrivano dalla più recente', () async {
      await database
          .into(database.bodyMeasurements)
          .insert(
            BodyMeasurementsCompanion.insert(
              id: 'm1',
              profileId: 'marco',
              weightKg: 96.2,
              measuredAt: DateTime.utc(2026, 7, 1),
              createdAt: DateTime.utc(2026, 7, 1),
              updatedAt: DateTime.utc(2026, 7, 1),
            ),
          );
      await database
          .into(database.bodyMeasurements)
          .insert(
            BodyMeasurementsCompanion.insert(
              id: 'm2',
              profileId: 'marco',
              weightKg: 95.8,
              measuredAt: DateTime.utc(2026, 8, 5),
              createdAt: DateTime.utc(2026, 8, 5),
              updatedAt: DateTime.utc(2026, 8, 5),
            ),
          );

      final samples = await repository.recentBodyWeights();
      expect(samples, hasLength(2));
      expect(pickBodyKg(measurements: samples).kg, 95.8);
      expect(pickBodyKg(measurements: samples).source, 'ultima pesata');
    });

    test('senza nessuna pesata si ripiega, dicendolo', () async {
      final samples = await repository.recentBodyWeights();
      expect(samples, isEmpty);
      expect(pickBodyKg(measurements: samples).kg, kDefaultBodyKg);
    });

    test('lo storico per i record esclude la sessione in corso', () async {
      await seedCatalog();
      final closed = await repository.startWorkout(
        exercises: [exercise('squat')],
      );
      await repository.finalizeWorkout(
        finalizeWorkoutSnapshot(
          workout: closed,
          endedAt: closed.startedAt.add(const Duration(minutes: 30)),
          bodyKg: 95.8,
        ),
      );
      final open = await repository.startWorkout(
        exercises: [exercise('panca')],
      );

      final history = await repository.recentClosedWorkouts();
      expect(history.map((workout) => workout.id), [closed.id]);
      expect(history.single.exercises.first.sets, hasLength(2));
      expect(history.map((workout) => workout.id), isNot(contains(open.id)));
    });
  });

  group('da una scheda vera', () {
    test('la scheda salvata diventa la sessione che dice di essere', () async {
      await seedCatalog();
      final routines = RoutineRepository(database);
      final routineId = await routines.saveRoutine(
        profileId: 'marco',
        draft: RoutineDraft(
          name: 'Gambe pesanti',
          warmup: const [],
          finisher: const [],
          segments: const [],
          main: [
            const DraftExercise(
              key: 'k1',
              exerciseRefId: 'squat',
              name: 'Squat',
              muscleGroup: MuscleGroup.gambe,
              trackingMode: ExerciseTrackingMode.weightReps,
              prescription: ExercisePrescription(
                sets: 5,
                reps: 5,
                restSec: 180,
              ),
            ),
            const DraftExercise(
              key: 'k2',
              exerciseRefId: 'panca',
              name: 'Panca piana',
              muscleGroup: MuscleGroup.petto,
              trackingMode: ExerciseTrackingMode.weightReps,
              inSupersetWithPrevious: true,
            ),
          ],
        ),
      );
      final details = await routines.getRoutine(routineId);

      final started = await repository.startWorkout(
        routineId: details!.id,
        routineName: details.name,
        exercises: workoutExercisesFromRoutine(details),
      );

      expect(started.routineName, 'Gambe pesanti');
      expect(started.exercises.first.sets, hasLength(5));
      expect(started.exercises.first.sets.first.reps, 5);
      expect(started.exercises.first.restSeconds, 180);
      expect(started.exercises.last.isInSupersetWithPrevious, isTrue);
      // Nessuna riga senza gruppo: le calorie non useranno il ripiego a 5 MET.
      expect(exercisesMissingMuscleGroupSnapshot(started), isEmpty);
    });
  });
}
