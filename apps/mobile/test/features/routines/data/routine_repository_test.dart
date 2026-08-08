import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/exercises/data/exercise_repository.dart';
import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/routines/data/routine_repository.dart';
import 'package:kal_tracker/features/routines/domain/routine_draft.dart';
import 'package:kal_tracker/features/routines/domain/routine_models.dart';

void main() {
  late AppDatabase database;
  late RoutineRepository routines;
  late ExerciseRepository exercises;
  late String profileId;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
    routines = RoutineRepository(database);
    exercises = ExerciseRepository(database);
  });

  tearDown(() => database.close());

  Future<Exercise> seedExercise(
    String name, {
    MuscleGroup group = MuscleGroup.petto,
    ExerciseTrackingMode mode = ExerciseTrackingMode.weightReps,
  }) => exercises.createExercise(
    profileId: profileId,
    draft: ExerciseDraft(name: name, muscleGroup: group, trackingMode: mode),
  );

  DraftExercise draftOf(
    Exercise exercise, {
    String? key,
    bool chained = false,
    int? warmupDurationSec,
    ExercisePrescription prescription = ExercisePrescription.empty,
  }) => DraftExercise(
    key: key ?? exercise.id,
    exerciseRefId: exercise.id,
    name: exercise.name,
    muscleGroup: exercise.muscleGroup,
    trackingMode: exercise.trackingMode,
    inSupersetWithPrevious: chained,
    warmupDurationSec: warmupDurationSec,
    prescription: prescription,
  );

  test(
    'salva i tre blocchi con posizioni dense e la catena delle superserie',
    () async {
      final cat = await seedExercise(
        'Cat-Cow',
        group: MuscleGroup.mobilita,
        mode: ExerciseTrackingMode.timed,
      );
      final panca = await seedExercise('Panca piana');
      final croci = await seedExercise('Croci ai cavi');
      final burpee = await seedExercise('Burpee', group: MuscleGroup.fullbody);

      final id = await routines.saveRoutine(
        profileId: profileId,
        draft: RoutineDraft(
          name: '  Push pesante  ',
          notes: '  Con calma  ',
          isCircuit: true,
          warmup: [draftOf(cat, warmupDurationSec: 45)],
          main: [
            draftOf(
              panca,
              prescription: const ExercisePrescription(
                sets: 4,
                reps: 8,
                restSec: 90,
              ),
            ),
            draftOf(croci, chained: true),
          ],
          finisher: [draftOf(burpee)],
          segments: const [],
        ),
      );

      final saved = (await routines.getRoutine(id))!;
      expect(saved.name, 'Push pesante', reason: 'il nome viene ripulito');
      expect(saved.notes, 'Con calma');
      expect(saved.warmup.single.warmupDurationSec, 45);
      expect(saved.main.map((row) => row.name), [
        'Panca piana',
        'Croci ai cavi',
      ]);
      expect(saved.main.first.prescription.sets, 4);
      expect(saved.main.first.prescription.restSec, 90);
      expect(saved.main[1].inSupersetWithPrevious, isTrue);
      expect(saved.finisher.single.name, 'Burpee');
      expect(saved.supersetGroupCount, 1);

      final rows = await database.select(database.routineExercises).get();
      // Le posizioni ripartono da zero in ogni blocco: è la finestra su cui
      // ragionano i blocchi a tempo.
      expect(
        {for (final row in rows) '${row.block}/${row.position}'},
        {'warmup/0', 'main/0', 'main/1', 'finisher/0'},
      );
      for (final row in rows) {
        expect(
          row.warmupDurationSec != null,
          row.block == 'warmup',
          reason: 'solo il riscaldamento ha una durata',
        );
        expect(row.exerciseId, row.exerciseRefId);
      }
    },
  );

  test(
    'un esercizio che non è in catalogo resta citato ma senza collegamento',
    () async {
      final panca = await seedExercise('Panca piana');

      final id = await routines.saveRoutine(
        profileId: profileId,
        draft: RoutineDraft(
          name: 'Scheda con buco',
          warmup: const [],
          main: [
            draftOf(panca),
            const DraftExercise(
              key: 'orfano',
              exerciseRefId: 'esercizio-sparito',
              name: 'Trazioni alla sbarra',
              muscleGroup: MuscleGroup.schiena,
              trackingMode: ExerciseTrackingMode.bodyweightReps,
              isMissing: true,
            ),
          ],
          finisher: const [],
          segments: const [],
        ),
      );

      final row =
          await (database.select(database.routineExercises)
                ..where((row) => row.exerciseRefId.equals('esercizio-sparito')))
              .getSingle();
      expect(row.exerciseId, isNull, reason: 'la chiave esterna non regge');
      expect(row.exerciseRefId, 'esercizio-sparito');
      expect(row.exerciseNameSnapshot, 'Trazioni alla sbarra');

      final saved = (await routines.getRoutine(id))!;
      expect(saved.main[1].isMissing, isTrue);
      expect(saved.main[1].name, 'Trazioni alla sbarra');
    },
  );

  test(
    'un esercizio cancellato dopo il salvataggio resta leggibile nella scheda',
    () async {
      final panca = await seedExercise('Panca piana');
      final id = await routines.saveRoutine(
        profileId: profileId,
        draft: RoutineDraft(
          name: 'Push',
          warmup: const [],
          main: [draftOf(panca)],
          finisher: const [],
          segments: const [],
        ),
      );

      await exercises.deleteExercise(panca.id);

      final saved = (await routines.getRoutine(id))!;
      expect(saved.main.single.name, 'Panca piana');
      expect(saved.main.single.isMissing, isTrue);
    },
  );

  test('salvare di nuovo riscrive i figli senza duplicarli', () async {
    final panca = await seedExercise('Panca piana');
    final croci = await seedExercise('Croci ai cavi');
    final spinte = await seedExercise('Spinte manubri');

    final id = await routines.saveRoutine(
      profileId: profileId,
      draft: RoutineDraft(
        name: 'Push',
        warmup: const [],
        main: [draftOf(panca), draftOf(croci), draftOf(spinte)],
        finisher: const [],
        segments: const [DraftSegment(memberKeys: [], workSec: 40)],
      ),
    );

    final reloaded = RoutineDraft.fromDetails((await routines.getRoutine(id))!);
    await routines.saveRoutine(
      profileId: profileId,
      draft: reloaded.removeAt(RoutineBlock.main, 1),
    );

    final rows = await database.select(database.routineExercises).get();
    expect(rows, hasLength(2));
    expect(rows.map((row) => row.position).toList()..sort(), [0, 1]);
    final saved = (await routines.getRoutine(id))!;
    expect(saved.main.map((row) => row.name), [
      'Panca piana',
      'Spinte manubri',
    ]);
  });

  test(
    'i blocchi a tempo si salvano numerati e collegati alle posizioni',
    () async {
      final squat = await seedExercise('Squat', group: MuscleGroup.gambe);
      final affondi = await seedExercise('Affondi', group: MuscleGroup.gambe);
      final plank = await seedExercise(
        'Plank',
        group: MuscleGroup.addome,
        mode: ExerciseTrackingMode.timeOnly,
      );

      final id = await routines.saveRoutine(
        profileId: profileId,
        draft: RoutineDraft(
          name: 'Gambe e core',
          warmup: const [],
          main: [
            draftOf(squat, key: 's'),
            draftOf(affondi, key: 'a'),
            draftOf(plank, key: 'p'),
          ],
          finisher: const [],
          segments: const [
            DraftSegment(
              memberKeys: ['a', 'p'],
              workSec: 45,
              restSec: 15,
              longRestSec: 30,
              rounds: 3,
            ),
          ],
        ),
      );

      final saved = (await routines.getRoutine(id))!;
      final segment = saved.segments.single;
      expect(segment.segmentIndex, 0);
      expect(segment.startIdx, 1);
      expect(segment.endIdx, 3);
      expect(segment.workSec, 45);
      expect(segment.rounds, 3);
      expect(saved.segmentAt(0), isNull);
      expect(saved.segmentAt(2), isNotNull);
    },
  );

  test('i valori fuori scala vengono riportati nei limiti invece di far '
      'fallire il salvataggio', () async {
    final squat = await seedExercise('Squat', group: MuscleGroup.gambe);

    final id = await routines.saveRoutine(
      profileId: profileId,
      draft: RoutineDraft(
        name: 'Estremi',
        warmup: const [],
        isCircuit: true,
        // 9000 secondi e 900 giri non esistono: il database li rifiuterebbe,
        // e un salvataggio fallito perderebbe tutta la scheda.
        workSec: 9000,
        rounds: 900,
        main: [
          draftOf(
            squat,
            prescription: const ExercisePrescription(sets: 400, reps: 9000),
          ),
        ],
        finisher: const [],
        segments: const [],
      ),
    );

    final saved = (await routines.getRoutine(id))!;
    expect(saved.workSec, 3600);
    expect(saved.rounds, 50);
    expect(saved.main.single.prescription.sets, 50);
    expect(saved.main.single.prescription.reps, 500);
  });

  test('l\'intervallo di ripetizioni va su disco e torna indietro', () async {
    final squat = await seedExercise('Squat', group: MuscleGroup.gambe);

    final id = await routines.saveRoutine(
      profileId: profileId,
      draft: RoutineDraft(
        name: 'Gambe',
        warmup: const [],
        main: [
          draftOf(
            squat,
            prescription: const ExercisePrescription(
              sets: 3,
              reps: 8,
              repsMin: 8,
              repsMax: 12,
            ),
          ),
        ],
        finisher: const [],
        segments: const [],
      ),
    );

    final row = (await database.select(database.routineExercises).get()).single;
    expect(row.prescRepsMin, 8);
    expect(row.prescRepsMax, 12);

    final saved = (await routines.getRoutine(id))!.main.single.prescription;
    expect(saved.range?.label, '8-12');
    expect(
      saved.summary(ExerciseTrackingMode.weightReps),
      '3×8-12 · rec predefinito',
    );

    // Il gateway deve vedere le due colonne come le vede il database: senza,
    // la scheda sincronizzata tornerebbe a essere un numero fisso.
    final entry = await (database.select(
      database.syncOutbox,
    )..where((row) => row.entityType.equals('routine'))).getSingle();
    final payload = jsonDecode(entry.payloadJson) as Map<String, Object?>;
    final child = (payload['exercises']! as List<Object?>).single;
    expect((child as Map<String, Object?>)['presc_reps_min'], 8);
    expect(child['presc_reps_max'], 12);
  });

  test('un intervallo che non è un intervallo non si salva a metà', () async {
    final squat = await seedExercise('Squat', group: MuscleGroup.gambe);
    final affondi = await seedExercise('Affondi', group: MuscleGroup.gambe);

    final id = await routines.saveRoutine(
      profileId: profileId,
      draft: RoutineDraft(
        name: 'Gambe',
        warmup: const [],
        main: [
          // Un fondo senza tetto e un tetto sotto il fondo: due modi di non
          // essere una banda, e nessuno dei due deve restare su disco a
          // promettere una progressione che non scatterà mai.
          draftOf(
            squat,
            key: 's',
            prescription: const ExercisePrescription(reps: 10, repsMin: 10),
          ),
          draftOf(
            affondi,
            key: 'a',
            prescription: const ExercisePrescription(
              reps: 12,
              repsMin: 12,
              repsMax: 8,
            ),
          ),
        ],
        finisher: const [],
        segments: const [],
      ),
    );

    final rows = await (database.select(
      database.routineExercises,
    )..orderBy([(row) => OrderingTerm.asc(row.position)])).get();
    for (final row in rows) {
      expect(row.prescRepsMin, isNull);
      expect(row.prescRepsMax, isNull);
    }
    final saved = (await routines.getRoutine(id))!.main;
    expect(saved.first.prescription.reps, 10, reason: 'il numero fisso resta');
    expect(saved.first.prescription.range, isNull);
    expect(saved.last.prescription.range, isNull);
  });

  test('una scheda con le sole ripetizioni continua a valere', () async {
    final squat = await seedExercise('Squat', group: MuscleGroup.gambe);

    final id = await routines.saveRoutine(
      profileId: profileId,
      draft: RoutineDraft(
        name: 'Gambe',
        warmup: const [],
        main: [
          draftOf(
            squat,
            prescription: const ExercisePrescription(sets: 4, reps: 10),
          ),
        ],
        finisher: const [],
        segments: const [],
      ),
    );

    final saved = (await routines.getRoutine(id))!.main.single.prescription;
    expect(saved.reps, 10);
    expect(saved.range, isNull);
    expect(
      saved.summary(ExerciseTrackingMode.weightReps),
      '4×10 · rec predefinito',
    );
  });

  test(
    'la scheda importata da Gym resta importata anche dopo una modifica',
    () async {
      final now = AppTime.nowUtc();
      await database
          .into(database.routines)
          .insert(
            RoutinesCompanion.insert(
              id: 'gym-routine',
              profileId: profileId,
              name: 'Full body',
              source: const Value('gym_tracker'),
              externalId: const Value('gym-routine'),
              createdAt: now,
              updatedAt: now,
            ),
          );
      final squat = await seedExercise('Squat', group: MuscleGroup.gambe);

      await routines.saveRoutine(
        profileId: profileId,
        draft: RoutineDraft(
          id: 'gym-routine',
          name: 'Full body rivisto',
          warmup: const [],
          main: [draftOf(squat)],
          finisher: const [],
          segments: const [],
        ),
      );

      final row = await (database.select(
        database.routines,
      )..where((table) => table.id.equals('gym-routine'))).getSingle();
      expect(row.source, 'gym_tracker');
      expect(row.externalId, 'gym-routine');
      expect(row.name, 'Full body rivisto');
    },
  );

  test(
    'la coda di sincronizzazione riceve la scheda con i suoi figli',
    () async {
      final squat = await seedExercise('Squat', group: MuscleGroup.gambe);
      final affondi = await seedExercise('Affondi', group: MuscleGroup.gambe);

      final id = await routines.saveRoutine(
        profileId: profileId,
        draft: RoutineDraft(
          name: 'Gambe',
          warmup: const [],
          main: [
            draftOf(squat, key: 's'),
            draftOf(affondi, key: 'a'),
          ],
          finisher: const [],
          segments: const [
            DraftSegment(memberKeys: ['s', 'a'], workSec: 40, rounds: 2),
          ],
        ),
      );

      final entry = await (database.select(
        database.syncOutbox,
      )..where((row) => row.entityType.equals('routine'))).getSingle();
      expect(entry.entityId, id);
      expect(entry.operation, 'upsert');

      final payload = jsonDecode(entry.payloadJson) as Map<String, Object?>;
      expect(payload['profile_id'], profileId);
      expect(payload['source'], 'manual');
      // Le due liste devono esserci sempre: per il gateway una chiave assente
      // significa «non parlo dei figli», e i figli remoti resterebbero vecchi.
      final children = payload['exercises']! as List<Object?>;
      expect(children, hasLength(2));
      expect(
        (children.last as Map<String, Object?>)['in_superset_with_previous'],
        isFalse,
      );
      final segments = payload['interval_segments']! as List<Object?>;
      expect((segments.single as Map<String, Object?>)['start_idx'], 0);
      expect((segments.single as Map<String, Object?>)['end_idx'], 2);
    },
  );

  test('la cancellazione è morbida e sparisce dall\'elenco', () async {
    final squat = await seedExercise('Squat', group: MuscleGroup.gambe);
    final id = await routines.saveRoutine(
      profileId: profileId,
      draft: RoutineDraft(
        name: 'Gambe',
        warmup: const [],
        main: [draftOf(squat)],
        finisher: const [],
        segments: const [],
      ),
    );

    await routines.deleteRoutine(id);

    expect(await routines.getRoutine(id), isNull);
    expect(await routines.watchRoutines(profileId).first, isEmpty);
    final row = await (database.select(
      database.routines,
    )..where((table) => table.id.equals(id))).getSingle();
    expect(row.deletedAt, isNotNull, reason: 'la riga resta per lo storico');
    final deletion = await (database.select(
      database.syncOutbox,
    )..where((entry) => entry.operation.equals('delete'))).getSingle();
    expect(deletion.entityType, 'routine');
  });

  test('l\'elenco conta esercizi, superserie, blocchi e minuti', () async {
    final squat = await seedExercise('Squat', group: MuscleGroup.gambe);
    final affondi = await seedExercise('Affondi', group: MuscleGroup.gambe);
    final plank = await seedExercise(
      'Plank',
      group: MuscleGroup.addome,
      mode: ExerciseTrackingMode.timeOnly,
    );

    await routines.saveRoutine(
      profileId: profileId,
      draft: RoutineDraft(
        name: 'Gambe e core',
        warmup: [draftOf(plank, key: 'w', warmupDurationSec: 30)],
        main: [
          draftOf(squat, key: 's'),
          draftOf(affondi, key: 'a', chained: true),
        ],
        finisher: const [],
        segments: const [],
      ),
    );

    final summary = (await routines.watchRoutines(profileId).first).single;
    expect(summary.name, 'Gambe e core');
    expect(summary.exerciseCount, 2);
    expect(summary.warmupCount, 1);
    expect(summary.supersetGroupCount, 1);
    expect(summary.segmentCount, 0);
    expect(summary.estimatedMinutes, greaterThan(0));
  });

  test('la ricerca filtra per nome', () async {
    final squat = await seedExercise('Squat', group: MuscleGroup.gambe);
    for (final name in ['Push pesante', 'Pull leggero']) {
      await routines.saveRoutine(
        profileId: profileId,
        draft: RoutineDraft(
          name: name,
          warmup: const [],
          main: [draftOf(squat)],
          finisher: const [],
          segments: const [],
        ),
      );
    }

    final found = await routines
        .watchRoutines(profileId, search: '  pull ')
        .first;
    expect(found.map((routine) => routine.name), ['Pull leggero']);
  });

  test('le schede che usano un esercizio si trovano dal catalogo', () async {
    final squat = await seedExercise('Squat', group: MuscleGroup.gambe);
    final plank = await seedExercise(
      'Plank',
      group: MuscleGroup.addome,
      mode: ExerciseTrackingMode.timeOnly,
    );

    await routines.saveRoutine(
      profileId: profileId,
      draft: RoutineDraft(
        name: 'Gambe',
        warmup: [draftOf(plank, key: 'w', warmupDurationSec: 30)],
        main: [draftOf(squat)],
        finisher: const [],
        segments: const [],
      ),
    );

    final usage = await routines.watchRoutinesUsingExercise(plank.id).first;
    expect(usage.single.routineName, 'Gambe');
    expect(usage.single.block, RoutineBlock.warmup);
  });
}
