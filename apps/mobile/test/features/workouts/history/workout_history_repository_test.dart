import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/features/workouts/data/workout_history_models.dart';
import 'package:kal_tracker/features/workouts/data/workout_history_repository.dart';

import 'workout_history_fixtures.dart';

void main() {
  late AppDatabase database;
  late WorkoutHistoryRepository repository;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    repository = WorkoutHistoryRepository(database);
    await seedProfile(database);
  });

  tearDown(() async {
    await database.close();
  });

  /// La sessione completa: volume con la regola di Gym, conteggi giusti
  /// nonostante la JOIN a ventaglio, durata dalla registrata.
  test('i totali di una sessione seguono la regola di Gym', () async {
    await seedRoutine(database, id: 'r-live', profileId: 'marco');
    await seedExercise(database, id: 'e-panca', profileId: 'marco');
    final started = DateTime.utc(2026, 7, 20, 16);
    await seedWorkout(
      database,
      id: 'w-forza',
      profileId: 'marco',
      startedAt: started,
      endedAt: started.add(const Duration(minutes: 75)),
      // Gym aveva registrato un'ora attiva: è quella che vince sull'orologio.
      finalDurationSeconds: 3600,
      routineId: 'r-live',
      routineName: 'Giorno 1 petto',
      totalKcal: 420,
    );
    await seedWorkoutExercise(
      database,
      id: 'we-corsa',
      workoutId: 'w-forza',
      position: 0,
      name: 'Corsa leggera',
      trackingMode: 'timeOnly',
      isWarmup: true,
    );
    await seedSet(
      database,
      id: 's-corsa',
      workoutExerciseId: 'we-corsa',
      position: 0,
      durationSec: 300,
    );
    await seedWorkoutExercise(
      database,
      id: 'we-panca',
      workoutId: 'w-forza',
      position: 1,
      name: 'Panca piana',
      exerciseId: 'e-panca',
      exerciseRefId: 'e-panca',
    );
    await seedSet(
      database,
      id: 's-panca-0',
      workoutExerciseId: 'we-panca',
      position: 0,
      weightKg: 40,
      reps: 10,
      isWarmup: true,
    );
    await seedSet(
      database,
      id: 's-panca-1',
      workoutExerciseId: 'we-panca',
      position: 1,
      weightKg: 60,
      reps: 8,
    );
    await seedSet(
      database,
      id: 's-panca-2',
      workoutExerciseId: 'we-panca',
      position: 2,
      weightKg: 60,
      reps: 6,
    );
    await seedWorkoutExercise(
      database,
      id: 'we-croci',
      workoutId: 'w-forza',
      position: 2,
      name: 'Croci',
      inSupersetWithPrevious: true,
    );
    await seedSet(
      database,
      id: 's-croci-0',
      workoutExerciseId: 'we-croci',
      position: 0,
      weightKg: 20,
      reps: 12,
    );
    await seedWorkoutExercise(
      database,
      id: 'we-stretch',
      workoutId: 'w-forza',
      position: 3,
      name: 'Stretch petto',
      trackingMode: 'timeOnly',
      isCooldown: true,
    );
    await seedSet(
      database,
      id: 's-stretch',
      workoutExerciseId: 'we-stretch',
      position: 0,
      durationSec: 60,
    );

    final history = await repository.loadHistory('marco');
    expect(history, hasLength(1));
    final summary = history.single;

    // 60×8 + 60×6 + 20×12. La serie di riscaldamento da 40×10 vale zero,
    // esattamente come in Gym.
    expect(summary.totalVolume, 1080);
    expect(summary.exerciseCount, 4);
    expect(summary.setCount, 6);
    expect(summary.duration, const Duration(hours: 1));
    expect(summary.routineDeleted, isFalse);
    expect(summary.withoutExercises, isFalse);
    expect(summary.hasStrengthWork, isTrue);
    // Le uniche serie a tempo stanno nel riscaldamento e nel defaticamento:
    // per la regola di Gym non fanno di questa sessione un HIIT.
    expect(summary.hasTimedWork, isFalse);
    expect(summary.kind, WorkoutKind.strength);
  });

  test('la sessione che cita una scheda cancellata tiene il nome storico e '
      'non è un errore', () async {
    await seedWorkout(
      database,
      id: 'w-orfana',
      profileId: 'marco',
      startedAt: DateTime.utc(2026, 6, 10, 17),
      endedAt: DateTime.utc(2026, 6, 10, 17, 45),
      finalDurationSeconds: 45 * 60,
      routineExternalId: 'r-cancellata',
      routineName: 'Giorno 3 spalle (vecchia)',
      notes: 'Sessione manuale (registrata a posteriori)',
      totalKcal: 300,
    );

    final summary = (await repository.loadHistory('marco')).single;

    expect(summary.routineDeleted, isTrue);
    expect(summary.routineName, 'Giorno 3 spalle (vecchia)');
    expect(summary.withoutExercises, isTrue);
    expect(summary.exerciseCount, 0);
    expect(summary.totalVolume, 0);
    expect(summary.kind, WorkoutKind.manual);
    expect(summary.duration, const Duration(minutes: 45));
  });

  test(
    'la sessione rimasta aperta conserva la durata grezza, marcata',
    () async {
      final started = DateTime.utc(2026, 5, 1, 9);
      await seedWorkout(
        database,
        id: 'w-aperta',
        profileId: 'marco',
        startedAt: started,
        endedAt: started.add(const Duration(hours: 536)),
        durationSuspect: true,
      );

      final summary = (await repository.loadHistory('marco')).single;

      expect(summary.durationSuspect, isTrue);
      // Nessun tetto sul ramo dell'orologio: rettificarlo qui sarebbe
      // correggere il dato in silenzio.
      expect(summary.duration, const Duration(hours: 536));
      expect(summary.wallClockDuration, const Duration(hours: 536));
    },
  );

  test(
    'la durata registrata resta sotto le 24 ore, come leggeva Gym',
    () async {
      final started = DateTime.utc(2026, 5, 3, 9);
      await seedWorkout(
        database,
        id: 'w-lunga',
        profileId: 'marco',
        startedAt: started,
        endedAt: started.add(const Duration(hours: 31)),
        finalDurationSeconds: 30 * 3600,
        durationSuspect: true,
      );

      final summary = (await repository.loadHistory('marco')).single;

      expect(summary.duration, const Duration(hours: 24));
      expect(summary.registeredDuration, const Duration(hours: 30));
    },
  );

  test('senza durata registrata si sottraggono le pause', () async {
    final started = DateTime.utc(2026, 5, 5, 9);
    await seedWorkout(
      database,
      id: 'w-pause',
      profileId: 'marco',
      startedAt: started,
      endedAt: started.add(const Duration(minutes: 90)),
      accumulatedPauseSeconds: 600,
    );

    final summary = (await repository.loadHistory('marco')).single;

    expect(summary.duration, const Duration(minutes: 80));
  });

  test(
    'lo storico arriva dal più recente e salta le sessioni cancellate',
    () async {
      for (final day in [10, 12, 14]) {
        await seedWorkout(
          database,
          id: 'w-$day',
          profileId: 'marco',
          startedAt: DateTime.utc(2026, 7, day, 18),
          endedAt: DateTime.utc(2026, 7, day, 19),
        );
      }
      await (database.update(
        database.workouts,
      )..where((row) => row.id.equals('w-12'))).write(
        WorkoutsCompanion(deletedAt: Value(DateTime.utc(2026, 7, 20))),
      );

      final history = await repository.watchHistory('marco').first;

      expect(history.map((session) => session.id), ['w-14', 'w-10']);
    },
  );

  test(
    'il dettaglio ricostruisce blocchi, superserie, circuiti e marcatori',
    () async {
      await seedWorkout(
        database,
        id: 'w-misto',
        profileId: 'marco',
        startedAt: DateTime.utc(2026, 7, 25, 17),
        endedAt: DateTime.utc(2026, 7, 25, 18),
        finalDurationSeconds: 3600,
        routineName: 'Full body circuito',
      );
      await seedWorkoutExercise(
        database,
        id: 'we-squat',
        workoutId: 'w-misto',
        position: 0,
        name: 'Squat',
      );
      await seedSet(
        database,
        id: 's-squat',
        workoutExerciseId: 'we-squat',
        position: 0,
        weightKg: 80,
        reps: 5,
        rpe: 8,
      );
      // Riga appesa dal blocco a tempo: in Gym stava in una lista separata.
      await seedWorkoutExercise(
        database,
        id: 'we-jack',
        workoutId: 'w-misto',
        position: 1,
        name: 'Jumping jack',
        trackingMode: 'timed',
        intervalSegmentIndex: 0,
      );
      await seedSet(
        database,
        id: 's-jack',
        workoutExerciseId: 'we-jack',
        position: 0,
        durationSec: 40,
      );
      // Marcata come incatenata alla riga precedente, che però è finita nel
      // circuito: la catena si spezza e questa apre un gruppo nuovo.
      await seedWorkoutExercise(
        database,
        id: 'we-affondi',
        workoutId: 'w-misto',
        position: 2,
        name: 'Affondi',
        inSupersetWithPrevious: true,
      );
      await seedWorkoutExercise(
        database,
        id: 'we-curl',
        workoutId: 'w-misto',
        position: 3,
        name: 'Curl',
        inSupersetWithPrevious: true,
      );
      await seedCircuitMarker(
        database,
        id: 'seg-0',
        workoutId: 'w-misto',
        segmentIndex: 0,
        completed: true,
        partial: true,
      );
      await seedPainPoint(
        database,
        id: 'pain-0',
        workoutId: 'w-misto',
        label: 'Spalla destra',
      );

      final detail = await repository.loadDetail('w-misto');
      expect(detail, isNotNull);
      expect(detail!.painPoints, ['Spalla destra']);

      final sections = buildWorkoutSections(detail);
      expect(sections, hasLength(2));

      final main = sections.first;
      expect(main.isCircuit, isFalse);
      expect(main.block, WorkoutBlock.main);
      expect(
        main.groups.map((group) => group.exercises.map((e) => e.name).toList()),
        [
          ['Squat'],
          ['Affondi', 'Curl'],
        ],
      );

      final circuit = sections.last;
      expect(circuit.isCircuit, isTrue);
      expect(circuit.segmentIndex, 0);
      expect(circuit.groups.single.exercises.single.name, 'Jumping jack');
      // I due marcatori non si escludono: erano due liste indipendenti.
      expect(circuit.marker?.completed, isTrue);
      expect(circuit.marker?.partial, isTrue);

      final squat = main.groups.first.exercises.single;
      expect(squat.sets.single.rpe, 8);
      expect(squat.volume, 400);
      // L'esercizio non è più in catalogo: la FK è nulla, il nome resta.
      expect(squat.exerciseDeleted, isTrue);
    },
  );

  test(
    'il dettaglio di una sessione che non c’è è nullo, non un errore',
    () async {
      expect(await repository.loadDetail('non-esiste'), isNull);
    },
  );

  test('un limite fuori scala viene rifiutato invece di essere corretto', () {
    expect(
      () => repository.watchHistory('marco', limit: 0),
      throwsA(isA<FormatException>()),
    );
  });
}
