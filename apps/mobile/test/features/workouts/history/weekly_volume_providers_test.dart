import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/workouts/domain/exercise_kind.dart';
import 'package:kal_tracker/features/workouts/domain/weekly_muscle_volume.dart';
import 'package:kal_tracker/features/workouts/presentation/history/weekly_volume_providers.dart';

import 'workout_history_fixtures.dart';

/// Il cablaggio fra il database e `weeklyMuscleVolume`.
///
/// Il dominio ha già i suoi test: qui si verifica che le sessioni arrivino
/// davvero fin lì, che la finestra sia la settimana giusta e che le esclusioni
/// non si perdano per strada — cioè le tre cose che si rompono quando si
/// collega un conto a un archivio vero.

/// Venerdì 7 agosto 2026, ora di Roma. La settimana è lunedì 3 – domenica 9.
final _today = DateTime.utc(2026, 8, 7, 12);

/// Mezzogiorno di un giorno della settimana in corso, in istante UTC: a
/// mezzogiorno nessun cambio d'ora sposta il giorno.
DateTime _dayOfWeek(int isoWeekday, {int weeksAgo = 0}) => DateTime.utc(
  2026,
  8,
  3,
  10,
).add(Duration(days: isoWeekday - 1 - 7 * weeksAgo));

void main() {
  late AppDatabase database;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    await seedProfile(database);
  });

  tearDown(() async {
    await database.close();
  });

  ProviderContainer containerWith() {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        // «Oggi» fisso: senza, la settimana in corso cambierebbe con il
        // giorno in cui gira la suite e metà asserzioni fallirebbero di
        // lunedì.
        todayProvider.overrideWithValue(_today),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// La banda della settimana selezionata, a lettura completata.
  Future<WeeklyMuscleVolume> readVolume(ProviderContainer container) async {
    // Un ascoltatore vivo: senza, il derivato non verrebbe ricalcolato
    // quando la lettura del database si conclude.
    container.listen(weeklyMuscleVolumeProvider, (previous, next) {});
    await container.read(weekWorkoutsProvider.future);
    return container.read(weeklyMuscleVolumeProvider).value!;
  }

  /// Una sessione con un esercizio e le sue serie.
  Future<void> seedSession({
    required String id,
    required DateTime startedAt,
    required String exerciseName,
    String? muscleGroup,
    int sets = 3,
    bool completed = true,
    bool warmupBlock = false,
    bool open = false,
  }) async {
    await seedWorkout(
      database,
      id: id,
      profileId: 'marco',
      startedAt: startedAt,
      endedAt: open ? null : startedAt.add(const Duration(minutes: 50)),
      finalDurationSeconds: open ? null : 3000,
    );
    await seedWorkoutExercise(
      database,
      id: '$id-ex',
      workoutId: id,
      position: 0,
      name: exerciseName,
      muscleGroup: muscleGroup,
      isWarmup: warmupBlock,
    );
    for (var index = 0; index < sets; index++) {
      await seedSet(
        database,
        id: '$id-set-$index',
        workoutExerciseId: '$id-ex',
        position: index,
        weightKg: 20,
        reps: 12,
        completed: completed,
      );
    }
  }

  group('la settimana arriva dal database', () {
    test('le serie della settimana si contano, quelle di prima no', () async {
      await seedSession(
        id: 'w-lun',
        startedAt: _dayOfWeek(DateTime.monday),
        exerciseName: 'Alzate laterali',
        muscleGroup: 'spalle',
        sets: 4,
      );
      await seedSession(
        id: 'w-prima',
        startedAt: _dayOfWeek(DateTime.wednesday, weeksAgo: 1),
        exerciseName: 'Alzate laterali',
        muscleGroup: 'spalle',
        sets: 9,
      );

      final container = containerWith();
      final volume = await readVolume(container);

      expect(volume.firstDay, DateTime.utc(2026, 8, 3));
      expect(volume.lastDay, DateTime.utc(2026, 8, 9));
      expect(volume.forGroup(MuscleGroup.spalle)!.sets, 4);
      expect(volume.sessions, 1);
    });

    test('la sessione ancora aperta porta le serie già spuntate', () async {
      await seedSession(
        id: 'w-aperta',
        startedAt: _dayOfWeek(DateTime.friday),
        exerciseName: 'Crunch',
        muscleGroup: 'addome',
        sets: 3,
        open: true,
      );

      final container = containerWith();
      final volume = await readVolume(container);

      expect(volume.forGroup(MuscleGroup.addome)!.sets, 3);
      expect(volume.sessions, 1);
    });

    test('un gruppo dell\'obiettivo rimasto a zero si vede', () async {
      await seedSession(
        id: 'w-lun',
        startedAt: _dayOfWeek(DateTime.monday),
        exerciseName: 'Curl',
        muscleGroup: 'bicipiti',
        sets: 6,
      );

      final container = containerWith();
      final volume = await readVolume(container);

      expect(volume.focus, declaredFocusMuscleGroups);
      // Braccia, spalle e addome: quattro gruppi, e tre di loro sono vuoti.
      expect(volume.focusGroups.length, 4);
      expect(
        [for (final entry in volume.emptyBandedGroups) entry.group],
        containsAll([
          MuscleGroup.spalle,
          MuscleGroup.tricipiti,
          MuscleGroup.addome,
        ]),
      );
    });

    test(
      'riscaldamento e righe senza gruppo restano fuori, e si dicono',
      () async {
        await seedSession(
          id: 'w-lun',
          startedAt: _dayOfWeek(DateTime.monday),
          exerciseName: 'Mobilità spalle',
          muscleGroup: 'spalle',
          sets: 2,
          warmupBlock: true,
        );
        await seedSession(
          id: 'w-mar',
          startedAt: _dayOfWeek(DateTime.tuesday),
          exerciseName: 'Esercizio senza catalogo',
          sets: 5,
        );

        final container = containerWith();
        final volume = await readVolume(container);

        expect(volume.warmupAndCooldownSets, 2);
        expect(volume.setsWithoutMuscleGroup, 5);
        expect(volume.hasExclusions, isTrue);
        // Le spalle restano vuote: quelle due serie erano riscaldamento.
        expect(volume.forGroup(MuscleGroup.spalle)!.sets, 0);
      },
    );

    test('le serie non spuntate non sono stimolo', () async {
      await seedSession(
        id: 'w-lun',
        startedAt: _dayOfWeek(DateTime.monday),
        exerciseName: 'Push down',
        muscleGroup: 'tricipiti',
        sets: 4,
        completed: false,
      );

      final container = containerWith();
      final volume = await readVolume(container);

      expect(volume.forGroup(MuscleGroup.tricipiti)!.sets, 0);
      expect(volume.sessions, 0);
    });
  });

  group('la settimana si può spostare indietro', () {
    test('con un passo indietro si conta la settimana prima', () async {
      await seedSession(
        id: 'w-prima',
        startedAt: _dayOfWeek(DateTime.wednesday, weeksAgo: 1),
        exerciseName: 'Alzate laterali',
        muscleGroup: 'spalle',
        sets: 9,
      );

      final container = containerWith();
      expect(
        (await readVolume(container)).forGroup(MuscleGroup.spalle)!.sets,
        0,
      );

      container.read(weeklyVolumeWeekOffsetProvider.notifier).state = 1;
      final before = await readVolume(container);

      expect(before.firstDay, DateTime.utc(2026, 7, 27));
      expect(before.forGroup(MuscleGroup.spalle)!.sets, 9);
    });
  });

  group('la lente', () {
    test('senza obiettivo attivo si legge col mantenimento', () async {
      final container = containerWith();

      expect(container.read(volumeIntentProvider), VolumeIntent.maintenance);
      expect(
        container.read(proposedVolumeIntentProvider),
        VolumeIntent.maintenance,
      );
    });

    test('cambiarla stringe la banda senza rileggere il database', () async {
      await seedSession(
        id: 'w-lun',
        startedAt: _dayOfWeek(DateTime.monday),
        exerciseName: 'Curl',
        muscleGroup: 'bicipiti',
        sets: 8,
      );

      final container = containerWith();
      final maintenance = await readVolume(container);
      expect(
        maintenance.forGroup(MuscleGroup.bicipiti)!.status,
        VolumeBandStatus.inside,
      );

      container.read(volumeIntentOverrideProvider.notifier).state =
          VolumeIntent.growth;
      // Nessun `await`: il conto è una funzione pura sulle sessioni già
      // lette, e se qui servisse un giro di database vorrebbe dire che la
      // lente sta ricaricando la settimana.
      final growth = container.read(weeklyMuscleVolumeProvider).value!;

      expect(growth.intent, VolumeIntent.growth);
      expect(
        growth.forGroup(MuscleGroup.bicipiti)!.status,
        VolumeBandStatus.below,
      );
    });
  });
}
