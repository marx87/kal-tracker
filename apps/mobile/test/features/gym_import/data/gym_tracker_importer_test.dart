import 'dart:convert';

// `isNull`/`isNotNull` esistono in entrambi: qui servono quelli di matcher.
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/gym_import/data/gym_tracker_importer.dart';
import 'package:kal_tracker/features/gym_import/domain/cool_down_sequence.dart';
import 'package:kal_tracker/features/gym_import/domain/gym_import_report.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

import '../gym_fixtures.dart';

/// La sessione rimasta aperta dal 26/06 al 18/07: 536 ore, zero esercizi.
const String _openWorkoutId = '019523c1-0d72-4bfc-a124-2656cdccc4a1';

/// La sessione del 18/07 con 885 secondi di pausa che l'export non conosce.
const String _pausedWorkoutId = '4607943c-df58-4993-9d52-9aae4571b278';

/// La sessione manuale del 4 agosto alle 22:34 locali.
const String _lateEveningWorkoutId = '4a458e4c-3ec5-4c90-8a4c-9a15398870b5';

void main() {
  late AppDatabase database;
  late String profileId;
  late GymTrackerImporter importer;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
    importer = GymTrackerImporter(database);
  });

  tearDown(() => database.close());

  Future<GymImportReport> runImport({
    bool withDump = true,
    bool enqueueSync = false,
    Map<String, Object?>? export,
  }) => importer.importExport(
    profileId: profileId,
    export: export ?? loadGymExport(),
    firestoreDump: withDump ? loadFirestoreDump() : null,
    enqueueSync: enqueueSync,
  );

  test('porta dentro tutto lo storico al primo lancio', () async {
    final report = await runImport();

    expect(report.cooldownPresets, 8);
    expect(report.exercises, 308);
    expect(report.routines, 14);
    expect(report.routineExercises, 176);
    expect(report.routineIntervalSegments, 6);
    expect(report.weeklyPlanDays, 5);
    expect(report.profileStats, 1);
    expect(report.achievements, 22);
    expect(report.workouts, 29);
    expect(report.workoutExercises, 250);
    expect(report.workoutSets, 628);
    expect(report.painPoints, 2);
    expect(report.workoutIntervalSegments, 1);
    expect(report.bodyMeasurements, 3);
    expect(report.bodyMeasurementValues, 1);
    expect(report.isNoop, isFalse);

    final blocks = await database.select(database.routineExercises).get();
    expect(blocks.where((row) => row.block == 'warmup'), hasLength(54));
    expect(blocks.where((row) => row.block == 'main'), hasLength(122));
    expect(blocks.where((row) => row.block == 'finisher'), isEmpty);

    final stats = await database
        .select(database.workoutProfileStats)
        .getSingle();
    expect(stats.totalXp, 11370);
    expect(stats.currentStreak, 2);
    expect(stats.longestStreak, 2);
    expect(stats.weeklyWorkoutGoal, 4);
    expect(stats.reminderEnabled, isTrue);
    expect(stats.healthConnectEnabled, isTrue);
    expect(stats.gymBodyWeightKg, 79.0);
    expect(stats.gymExportedAt, isNotNull);
  });

  test('i preset di defaticamento hanno i nomi veri dello storico', () async {
    await runImport();

    final synthetic = await (database.select(
      database.exercises,
    )..where((row) => row.isSynthetic.equals(true))).get();
    expect(synthetic, hasLength(8));
    expect(synthetic.every((row) => row.source == 'cooldown_preset'), isTrue);
    expect(
      synthetic.every((row) => row.defaultRestSec == CoolDownItem.restSec),
      isTrue,
    );
    expect(synthetic.every((row) => row.notes != null), isTrue);

    // Lo stesso slug non può avere due nomi: quello del catalogo e quello che
    // lo storico ha già registrato devono coincidere per tutti e otto.
    final names = {for (final row in synthetic) row.id: row.name};
    final rows = await (database.select(
      database.workoutExercises,
    )..where((row) => row.isCooldown.equals(true))).get();
    expect(rows, hasLength(12));
    for (final row in rows) {
      expect(names[row.exerciseRefId], row.exerciseNameSnapshot);
    }
    expect(names['cd-spinaltwist-l'], 'Torsione supina (sx)');
    expect(names['cd-spinaltwist-r'], 'Torsione supina (dx)');
    expect(names['cd-hamstring'], 'Ischiocrurali (half splits)');
  });

  test('le righe di defaticamento restano collegate ai preset', () async {
    await runImport();

    final rows = await (database.select(
      database.workoutExercises,
    )..where((row) => row.isCooldown.equals(true))).get();

    for (final row in rows) {
      expect(row.exerciseId, row.exerciseRefId);
      expect(row.exerciseRefId, startsWith('cd-'));
      expect(row.trackingMode, 'timed');
      expect(row.muscleGroupSnapshot, 'mobilita');
    }
  });

  test('rilanciarlo non duplica niente', () async {
    await runImport(enqueueSync: true);
    final before = await _snapshot(database);
    final outboxBefore =
        (await database.select(database.syncOutbox).get()).length;

    final second = await runImport(enqueueSync: true);

    expect(second.isNoop, isTrue);
    expect(second.rowCount, 0);
    expect(second.syncMutations, 0);
    expect(await _snapshot(database), before);
    expect(
      (await database.select(database.syncOutbox).get()).length,
      outboxBefore,
    );
  });

  test('una sessione cancellata non risorge', () async {
    await runImport();
    final now = AppTime.nowUtc();
    await (database.update(database.workouts)
          ..where((row) => row.id.equals(_openWorkoutId)))
        .write(WorkoutsCompanion(updatedAt: Value(now), deletedAt: Value(now)));

    final second = await runImport();

    expect(second.workouts, 0);
    final row = await (database.select(
      database.workouts,
    )..where((r) => r.id.equals(_openWorkoutId))).getSingle();
    expect(row.deletedAt, isNotNull);
  });

  test('una modifica ai figli sopravvive al secondo import', () async {
    await runImport();
    final target =
        await (database.select(database.workoutSets)
              ..orderBy([(row) => OrderingTerm.asc(row.id)])
              ..limit(1))
            .getSingle();
    await (database.update(database.workoutSets)
          ..where((row) => row.id.equals(target.id)))
        .write(const WorkoutSetsCompanion(weightKg: Value(123.5)));

    await runImport();

    final after = await (database.select(
      database.workoutSets,
    )..where((row) => row.id.equals(target.id))).getSingle();
    expect(after.weightKg, 123.5);
  });

  test('le nove sessioni orfane conservano id e nome della scheda', () async {
    final report = await runImport();

    final orphans = await (database.select(
      database.workouts,
    )..where((row) => row.routineId.isNull())).get();
    final withExternal = orphans
        .where((row) => row.routineExternalId != null)
        .toList();
    expect(withExternal, hasLength(9));
    for (final row in withExternal) {
      expect(row.routineNameSnapshot, isNotNull);
    }

    // Vietato ricollegare per nome: esiste una scheda viva omonima con id
    // diverso, e collegarla creerebbe una storia falsa.
    final live =
        await (database.select(database.routines)..where(
              (row) => row.name.equals('Giorno1 spalle petto tricipiti'),
            ))
            .getSingle();
    expect(live.id, '39a3db5e-3919-42db-84de-524df5d0ce7e');
    expect(
      withExternal.any((row) => row.routineExternalId == live.id),
      isFalse,
    );

    const orphanIds = [
      'e2aa0bd6-e398-4cdb-8e25-e967bb112d8f',
      'ff0995e2-6c65-469d-9d46-440a9db48e68',
      '03668bbe-2bd0-4235-9f12-a7acedd0927b',
      'f6b9aa84-c132-4865-9ee9-16bc7a5228e1',
      'c1349deb-1114-4c6e-8a08-047b236bb5ab',
      'e91fda05-245c-4ced-8d0b-60c583b5a19b',
    ];
    for (final id in orphanIds) {
      expect(
        report.warnings.any((warning) => warning.contains(id)),
        isTrue,
        reason: 'la scheda cancellata $id deve essere segnalata',
      );
    }
  });

  test(
    'il piano settimanale tiene anche il giorno che punta nel vuoto',
    () async {
      final report = await runImport();

      final days = await (database.select(
        database.routineWeeklyPlan,
      )..orderBy([(row) => OrderingTerm.asc(row.weekday)])).get();
      expect(days.map((row) => row.weekday), [1, 3, 4, 5, 6]);

      final third = days.firstWhere((row) => row.weekday == 3);
      expect(third.routineId, isNull);
      expect(third.routineExternalId, 'e91fda05-245c-4ced-8d0b-60c583b5a19b');
      // Il nome esiste solo nello storico: è la ragione per cui la mappa dei
      // nomi si costruisce anche dai workout.
      expect(third.routineNameSnapshot, 'Esercizi 1');
      expect(
        report.warnings.any(
          (warning) =>
              warning.contains('giorno 3') && warning.contains('e91fda05'),
        ),
        isTrue,
      );
    },
  );

  test('le otto sessioni senza esercizi entrano comunque', () async {
    await runImport();

    final workouts = await database.select(database.workouts).get();
    final rows = await database.select(database.workoutExercises).get();
    final withRows = rows.map((row) => row.workoutId).toSet();
    final empty = workouts.where((row) => !withRows.contains(row.id)).toList();

    expect(empty, hasLength(8));
    final kcal = empty.fold<double>(
      0,
      (sum, row) => sum + (row.totalKcal ?? 0),
    );
    expect(kcal, closeTo(4978, 0.001));

    final open = empty.firstWhere((row) => row.id == _openWorkoutId);
    expect(open.routineId, isNull);
    expect(open.routineExternalId, isNull);
    expect(open.routineNameSnapshot, isNull);
    expect(open.notes, isNull);
    expect(open.xpEarned, 1465);
  });

  test('la sessione da 536 ore entra grezza e marcata', () async {
    final report = await runImport();

    final open = await (database.select(
      database.workouts,
    )..where((row) => row.id.equals(_openWorkoutId))).getSingle();
    expect(open.durationSuspect, isTrue);
    // Il valore che Gym aveva davvero registrato, non una rettifica a 24 ore.
    expect(open.finalDurationSeconds, 1929475);
    expect(
      report.warnings.any((warning) => warning.contains('536 ore')),
      isTrue,
    );
  });

  test('senza dump la durata resta il solo orologio', () async {
    final report = await runImport(withDump: false);

    final open = await (database.select(
      database.workouts,
    )..where((row) => row.id.equals(_openWorkoutId))).getSingle();
    expect(open.finalDurationSeconds, isNull);
    expect(open.accumulatedPauseSeconds, 0);
    expect(open.durationSuspect, isTrue);

    // Le pause non sono nell'export: le tre sessioni sovrastimate sono
    // indistinguibili dalle altre e nessuno le può marcare.
    final suspects = await (database.select(
      database.workouts,
    )..where((row) => row.durationSuspect.equals(true))).get();
    expect(suspects.map((row) => row.id), [_openWorkoutId]);
    expect(report.usedFirestoreDump, isFalse);
    expect(
      report.notImported.any((line) => line.contains('Prescrizioni')),
      isTrue,
    );
  });

  test('col dump le sessioni sovrastimate si riconoscono', () async {
    await runImport();

    final paused = await (database.select(
      database.workouts,
    )..where((row) => row.id.equals(_pausedWorkoutId))).getSingle();
    expect(paused.accumulatedPauseSeconds, 885);
    expect(paused.finalDurationSeconds, 1329);
    expect(paused.durationSuspect, isTrue);

    final suspects = await (database.select(
      database.workouts,
    )..where((row) => row.durationSuspect.equals(true))).get();
    // La patologica più le quattro in cui l'orologio supera di oltre un minuto
    // la durata che Gym aveva registrato.
    expect(suspects, hasLength(5));
  });

  test('le dieci serie non completate entrano con la loro metrica', () async {
    await runImport();

    final incomplete = await (database.select(
      database.workoutSets,
    )..where((row) => row.completed.equals(false))).get();

    expect(incomplete, hasLength(10));
    expect(incomplete.where((row) => row.durationSec != null), hasLength(6));
    expect(incomplete.where((row) => row.reps != null), hasLength(4));
    final withWeight = incomplete.where((row) => row.weightKg != null).toList();
    expect(withWeight, hasLength(1));
    expect(withWeight.single.weightKg, 6.7);
  });

  test('le date restano nel giorno in cui sono state vissute', () async {
    await runImport();

    final late = await (database.select(
      database.workouts,
    )..where((row) => row.id.equals(_lateEveningWorkoutId))).getSingle();

    expect(AppTime.inRome(late.startedAt).day, 4);
    expect(AppTime.inRome(late.startedAt).hour, 22);
    final dayStart = AppTime.startOfDayUtc(DateTime(2026, 8, 4));
    final dayEnd = AppTime.endOfDayUtc(DateTime(2026, 8, 4));
    expect(late.startedAt.isBefore(dayStart), isFalse);
    expect(late.startedAt.isBefore(dayEnd), isTrue);
  });

  test(
    'lastWorkoutDay è un istante in locale e una data nel payload',
    () async {
      await runImport(enqueueSync: true);

      final stats = await database
          .select(database.workoutProfileStats)
          .getSingle();
      // Drift rilegge i DateTime in ora locale: l'istante è la mezzanotte di
      // Roma del 4 agosto, cioè le 22:00 UTC del 3.
      expect(stats.lastWorkoutDay!.toUtc(), DateTime.utc(2026, 8, 3, 22));

      final payload = await _payloadOf(database, 'workout_profile_stats');
      expect(payload['last_workout_day'], '2026-08-04');
    },
  );

  test('il payload delle stats porta tutto quello che la riga sa', () async {
    await runImport(enqueueSync: true);

    final payload = await _payloadOf(database, 'workout_profile_stats');

    expect(payload['total_xp'], 11370);
    expect(payload['reminder_enabled'], isTrue);
    expect(payload['health_connect_enabled'], isTrue);
    expect(payload['gym_body_weight_kg'], 79.0);
    expect(payload['gym_exported_at'], isNotNull);
    expect(payload['achievements'], hasLength(22));
    expect(payload['weekly_plan'], hasLength(5));

    // Confronto insiemistico con le colonne della tabella: un campo nuovo
    // dello schema che nessuno aggiunge al payload deve far fallire il test.
    final columns =
        database.workoutProfileStats.$columns
            .map((column) => column.name)
            .toSet()
          ..removeAll({'deleted_at'});
    expect(payload.keys.toSet().containsAll(columns), isTrue);
  });

  test('il testo non viene ripulito', () async {
    await runImport();

    final snapshots = (await database.select(database.workouts).get())
        .map((row) => row.routineNameSnapshot)
        .whereType<String>()
        .toSet();

    // Il doppio spazio è l'identità di una scheda cancellata: nessuna delle
    // quattordici vive ne ha uno.
    expect(snapshots.contains('Esercizi  2'), isTrue);
    final live = (await database.select(database.routines).get())
        .map((row) => row.name)
        .toList();
    expect(live.any((name) => name.contains('  ')), isFalse);

    final accented = (await database.select(database.exercises).get())
        .where((row) => row.name.contains('à') || row.name.contains('°'))
        .toList();
    expect(accented, isNotEmpty);
  });

  test(
    'la modalità di misura è quella della sessione, non del catalogo',
    () async {
      await runImport();

      final catalog = {
        for (final row in await database.select(database.exercises).get())
          row.id: row.trackingMode,
      };
      final rows = await database.select(database.workoutExercises).get();
      final divergent = rows
          .where((row) => catalog[row.exerciseRefId] != row.trackingMode)
          .toList();

      expect(divergent, hasLength(72));
      expect(divergent.map((row) => row.exerciseRefId).toSet(), hasLength(22));
    },
  );

  test('gli esercizi ripetuti restano righe distinte', () async {
    await runImport();

    final elastici = await (database.select(
      database.routines,
    )..where((row) => row.name.equals('Oggi elastici 45min 1'))).getSingle();
    final rows =
        await (database.select(database.routineExercises)..where(
              (row) =>
                  row.routineId.equals(elastici.id) & row.block.equals('main'),
            ))
            .get();
    final repeated = rows
        .where(
          (row) => row.exerciseRefId == '8e1685a9-48cd-4573-b1da-2e137703caf7',
        )
        .toList();

    expect(repeated, hasLength(2));
    expect(repeated.map((row) => row.position).toSet(), hasLength(2));
  });

  test(
    'l ordine delle righe e la catena di superserie sono quelli del file',
    () async {
      final export = loadGymExport();
      await runImport(export: export);

      final source = (export['workouts']! as List)
          .cast<Map<String, Object?>>()
          .firstWhere((workout) => (workout['exercises']! as List).isNotEmpty);
      final expected = (source['exercises']! as List)
          .cast<Map<String, Object?>>()
          .map((row) => row['exerciseId'])
          .toList();

      final rows =
          await (database.select(database.workoutExercises)
                ..where((row) => row.workoutId.equals(source['id']! as String))
                ..orderBy([(row) => OrderingTerm.asc(row.position)]))
              .get();
      expect(rows.map((row) => row.exerciseRefId).toList(), expected);

      final all = await database.select(database.workoutExercises).get();
      final chained = all.where((row) => row.isInSupersetWithPrevious).toList();
      expect(chained, hasLength(26));
      expect(chained.every((row) => row.position > 0), isTrue);
    },
  );

  test('le pesate si deduplicano sulla chiave della sorgente', () async {
    await runImport();

    final measurements = await (database.select(
      database.bodyMeasurements,
    )..orderBy([(row) => OrderingTerm.desc(row.measuredAt)])).get();
    expect(measurements, hasLength(3));
    for (final row in measurements) {
      expect(row.source, 'gym_tracker');
      expect(row.externalId, row.id);
    }
    expect(measurements.first.weightKg, 78.8);

    final values = await database.select(database.bodyMeasurementValues).get();
    expect(values, hasLength(1));
    expect(values.single.label, 'Vita');
    expect(values.single.value, 88.4);
    expect(values.single.measurementId, '0c4d13cb-e386-45eb-b04d-9d15cdf8d258');
  });

  test('le prescrizioni e i blocchi a tempo arrivano dal dump', () async {
    await runImport();

    final rows = await database.select(database.routineExercises).get();
    expect(rows.where((row) => row.prescSets != null), hasLength(125));

    final segments = await (database.select(
      database.routineIntervalSegments,
    )..orderBy([(row) => OrderingTerm.asc(row.segmentIndex)])).get();
    expect(segments, hasLength(6));
    expect(segments.map((row) => row.routineId).toSet(), hasLength(3));

    final marker = await database
        .select(database.workoutIntervalSegments)
        .getSingle();
    expect(marker.segmentIndex, 0);
    expect(marker.partialMarker, isTrue);
    expect(marker.completedMarker, isFalse);
    expect(marker.completionSignature, isNull);
  });

  test('senza dump prescrizioni e blocchi restano vuoti', () async {
    await runImport(withDump: false);

    final rows = await database.select(database.routineExercises).get();
    expect(rows.where((row) => row.prescSets != null), isEmpty);
    expect(
      await database.select(database.routineIntervalSegments).get(),
      isEmpty,
    );
    expect(
      await database.select(database.workoutIntervalSegments).get(),
      isEmpty,
    );
  });

  test(
    'un documento a cui manca una chiave non lascia mezzo storico',
    () async {
      final export = loadGymExport();
      (export['workouts']! as List).cast<Map<String, Object?>>()[3].remove(
        'startedAt',
      );

      await expectLater(
        runImport(export: export),
        throwsA(isA<FormatException>()),
      );

      expect(await database.select(database.workouts).get(), isEmpty);
      expect(await database.select(database.exercises).get(), isEmpty);
      expect(await database.select(database.routines).get(), isEmpty);
    },
  );

  test('un file di un altra app viene rifiutato in italiano', () async {
    final wrongApp = loadGymExport()..['app'] = 'kal-tracker';
    final wrongVersion = loadGymExport()..['schemaVersion'] = 2;

    await expectLater(
      runImport(export: wrongApp),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'messaggio',
          contains('non è un export di Gym Tracker'),
        ),
      ),
    );
    await expectLater(
      runImport(export: wrongVersion),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'messaggio',
          contains('so leggere solo'),
        ),
      ),
    );
    expect(await database.select(database.exercises).get(), isEmpty);
  });

  test('spegnendo enqueueSync non accoda niente', () async {
    final report = await runImport();

    expect(report.syncMutations, 0);
    expect(await database.select(database.syncOutbox).get(), isEmpty);
  });

  test('di serie la coda di sincronizzazione è ACCESA', () async {
    // Il parametro non viene passato: si guarda proprio il valore di
    // fabbrica, che è quello con cui l'import gira sul telefono di Marco.
    // Finché era falso lo storico di Gym restava chiuso nel dispositivo.
    final report = await importer.importExport(
      profileId: profileId,
      export: loadGymExport(),
      firestoreDump: loadFirestoreDump(),
    );

    expect(report.syncMutations, greaterThan(0));
    expect(await database.select(database.syncOutbox).get(), isNotEmpty);
  });

  test('con enqueueSync accoda una mutation per ogni entità radice', () async {
    final report = await runImport(enqueueSync: true);

    expect(report.syncMutations, 363);
    final rows = await database.select(database.syncOutbox).get();
    expect(rows, hasLength(363));

    final byType = <String, int>{};
    for (final row in rows) {
      byType[row.entityType] = (byType[row.entityType] ?? 0) + 1;
    }
    expect(byType, {
      'exercise': 316,
      'routine': 14,
      'workout': 29,
      'workout_profile_stats': 1,
      'body_measurement': 3,
    });
    // I preset devono esserci: dodici righe di allenamento li citano e senza
    // la riga remota la FK del server rifiuterebbe il workout.
    expect(rows.where((row) => row.entityId.startsWith('cd-')), hasLength(8));
    expect(rows.every((row) => row.operation == 'upsert'), isTrue);
  });

  test('dice cosa non è entrato invece di lasciarlo cadere', () async {
    final report = await runImport();

    expect(report.usedFirestoreDump, isTrue);
    // I decimi di secondo: Drift salva i DateTime al secondo.
    expect(
      report.notImported.any((line) => line.contains('decimi di secondo')),
      isTrue,
    );
    expect(report.describe(), contains('29 sessioni'));
  });

  test('un campo che nessuna colonna accoglie viene contato', () async {
    final export = loadGymExport();
    final exercises = (export['exercises']! as List)
        .cast<Map<String, Object?>>();
    exercises[0]['difficolta'] = 'alta';
    exercises[1]['difficolta'] = 'media';

    final report = await runImport(export: export);

    expect(
      report.notImported.any(
        (line) => line.contains('esercizio.difficolta') && line.contains('2 '),
      ),
      isTrue,
      reason: 'un campo nuovo della sorgente non deve sparire in silenzio',
    );
  });

  test('il dump riempie anche imageUrl e isPreset del catalogo', () async {
    await runImport();

    final catalog = await database.select(database.exercises).get();
    final fromGym = catalog
        .where((row) => row.source == 'gym_tracker')
        .toList();

    expect(fromGym.where((row) => row.isPreset), hasLength(249));
    expect(fromGym.where((row) => row.imageUrl != null), hasLength(271));
  });

  test('senza dump imageUrl e isPreset restano vuoti', () async {
    await runImport(withDump: false);

    final catalog = await database.select(database.exercises).get();
    final fromGym = catalog
        .where((row) => row.source == 'gym_tracker')
        .toList();

    expect(fromGym.where((row) => row.isPreset), isEmpty);
    expect(fromGym.where((row) => row.imageUrl != null), isEmpty);
  });
}

/// Fotografia dei conteggi di tutte le tabelle toccate dall'import.
Future<Map<String, int>> _snapshot(AppDatabase database) async => {
  'exercises': (await database.select(database.exercises).get()).length,
  'routines': (await database.select(database.routines).get()).length,
  'routineExercises':
      (await database.select(database.routineExercises).get()).length,
  'routineIntervalSegments':
      (await database.select(database.routineIntervalSegments).get()).length,
  'routineWeeklyPlan':
      (await database.select(database.routineWeeklyPlan).get()).length,
  'workouts': (await database.select(database.workouts).get()).length,
  'workoutExercises':
      (await database.select(database.workoutExercises).get()).length,
  'workoutSets': (await database.select(database.workoutSets).get()).length,
  'workoutPainPoints':
      (await database.select(database.workoutPainPoints).get()).length,
  'workoutIntervalSegments':
      (await database.select(database.workoutIntervalSegments).get()).length,
  'workoutProfileStats':
      (await database.select(database.workoutProfileStats).get()).length,
  'workoutAchievements':
      (await database.select(database.workoutAchievements).get()).length,
  'bodyMeasurements':
      (await database.select(database.bodyMeasurements).get()).length,
  'bodyMeasurementValues':
      (await database.select(database.bodyMeasurementValues).get()).length,
};

Future<Map<String, Object?>> _payloadOf(
  AppDatabase database,
  String entityType,
) async {
  final row = await (database.select(
    database.syncOutbox,
  )..where((row) => row.entityType.equals(entityType))).getSingle();
  return jsonDecode(row.payloadJson) as Map<String, Object?>;
}
