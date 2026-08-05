import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/exercises/data/exercise_repository.dart';
import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

void main() {
  late AppDatabase database;
  late ExerciseRepository repository;
  late String profileId;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
    repository = ExerciseRepository(database);
  });

  tearDown(() => database.close());

  Future<Exercise> create(
    String name, {
    MuscleGroup group = MuscleGroup.petto,
    ExerciseTrackingMode mode = ExerciseTrackingMode.weightReps,
    String? notes,
    int? restSec,
  }) => repository.createExercise(
    profileId: profileId,
    draft: ExerciseDraft(
      name: name,
      muscleGroup: group,
      trackingMode: mode,
      notes: notes,
      defaultRestSec: restSec,
    ),
  );

  test('crea un esercizio mio, non uno di libreria', () async {
    final created = await create(
      '  Panca piana  ',
      notes: '  Scapole strette  ',
      restSec: 120,
    );

    expect(created.name, 'Panca piana');
    expect(created.notes, 'Scapole strette');
    expect(created.isPreset, isFalse);
    expect(created.origin, ExerciseOrigin.mine);
    expect(created.source, 'manual');

    final row = await (database.select(
      database.exercises,
    )..where((table) => table.id.equals(created.id))).getSingle();
    expect(row.muscleGroup, 'petto');
    expect(row.trackingMode, 'weightReps');
    expect(row.defaultRestSec, 120);
    expect(row.isSynthetic, isFalse);
  });

  test('la modifica non trasforma un esercizio importato in uno mio', () async {
    final now = AppTime.nowUtc();
    await database
        .into(database.exercises)
        .insert(
          ExercisesCompanion.insert(
            id: 'gym-1',
            profileId: profileId,
            name: 'Trazioni',
            muscleGroup: 'schiena',
            trackingMode: 'bodyweightReps',
            isPreset: const Value(true),
            source: const Value('gym_tracker'),
            externalId: const Value('gym-1'),
            createdAt: now,
            updatedAt: now,
          ),
        );

    await repository.updateExercise(
      'gym-1',
      const ExerciseDraft(
        name: 'Trazioni presa larga',
        muscleGroup: MuscleGroup.schiena,
        trackingMode: ExerciseTrackingMode.bodyweightReps,
      ),
    );

    final row = await (database.select(
      database.exercises,
    )..where((table) => table.id.equals('gym-1'))).getSingle();
    expect(row.name, 'Trazioni presa larga');
    expect(row.isPreset, isTrue);
    expect(row.source, 'gym_tracker');
    expect(row.externalId, 'gym-1');

    final payload =
        jsonDecode(
              (await (database.select(database.syncOutbox)
                        ..where((entry) => entry.entityId.equals('gym-1')))
                      .getSingle())
                  .payloadJson,
            )
            as Map<String, Object?>;
    expect(payload['is_preset'], isTrue);
    expect(payload['source'], 'gym_tracker');
    expect(payload['external_id'], 'gym-1');
  });

  test(
    'svuotare le note le cancella invece di lasciare la stringa vuota',
    () async {
      final created = await create('Panca piana', notes: 'Vecchia nota');

      await repository.updateExercise(
        created.id,
        created.toDraft().copyWith(notes: '   '),
      );

      final reloaded = await repository.getExercise(created.id);
      expect(reloaded!.notes, isNull);
    },
  );

  test(
    'la cancellazione è morbida: sparisce dal catalogo, resta la riga',
    () async {
      final created = await create('Panca piana');

      await repository.deleteExercise(created.id);

      expect(await repository.getExercise(created.id), isNull);
      expect(await repository.watchExercises(profileId).first, isEmpty);
      final row = await (database.select(
        database.exercises,
      )..where((table) => table.id.equals(created.id))).getSingle();
      expect(row.deletedAt, isNotNull);
      final deletion = await (database.select(
        database.syncOutbox,
      )..where((entry) => entry.operation.equals('delete'))).getSingle();
      expect(deletion.entityType, 'exercise');
    },
  );

  test(
    'gli stretch sintetici del defaticamento non sono in catalogo',
    () async {
      final now = AppTime.nowUtc();
      await database
          .into(database.exercises)
          .insert(
            ExercisesCompanion.insert(
              id: 'cd-childpose',
              profileId: profileId,
              name: 'Child pose',
              muscleGroup: 'mobilita',
              trackingMode: 'timed',
              isSynthetic: const Value(true),
              source: const Value('cooldown_preset'),
              externalId: const Value('cd-childpose'),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await create('Panca piana');

      final catalog = await repository.watchExercises(profileId).first;
      expect(catalog.map((exercise) => exercise.name), ['Panca piana']);
    },
  );

  test(
    'la ricerca trova per nome e per gruppo muscolare scritto per esteso',
    () async {
      await create('Panca piana');
      await create(
        'Corsa',
        group: MuscleGroup.cardio,
        mode: ExerciseTrackingMode.distanceTime,
      );
      await create('Saluto al sole', group: MuscleGroup.mobilita);

      Future<List<String>> search(String query) async =>
          (await repository.watchExercises(profileId, search: query).first)
              .map((exercise) => exercise.name)
              .toList();

      expect(await search('panc'), ['Panca piana']);
      // «Mobilità» non è scritto in nessuna colonna: sta solo nell'etichetta.
      expect(await search('mobilità'), ['Saluto al sole']);
      expect(await search('distanza'), ['Corsa']);
      expect(await search('nulla'), isEmpty);
    },
  );

  test('i filtri per gruppo e per origine si combinano', () async {
    final now = AppTime.nowUtc();
    await database
        .into(database.exercises)
        .insert(
          ExercisesCompanion.insert(
            id: 'base-squat',
            profileId: profileId,
            name: 'Squat',
            muscleGroup: 'gambe',
            trackingMode: 'weightReps',
            isPreset: const Value(true),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await create('Affondi bulgari', group: MuscleGroup.gambe);
    await create('Panca piana');

    final gambe = await repository
        .watchExercises(profileId, muscleGroup: MuscleGroup.gambe)
        .first;
    expect(gambe.map((exercise) => exercise.name), [
      'Affondi bulgari',
      'Squat',
    ]);

    final mine = await repository
        .watchExercises(
          profileId,
          muscleGroup: MuscleGroup.gambe,
          origin: ExerciseOrigin.mine,
        )
        .first;
    expect(mine.map((exercise) => exercise.name), ['Affondi bulgari']);

    final base = await repository
        .watchExercises(profileId, origin: ExerciseOrigin.base)
        .first;
    expect(base.map((exercise) => exercise.name), ['Squat']);
  });

  test('gli esercizi di una scheda si leggono in una volta sola', () async {
    final panca = await create('Panca piana');
    final croci = await create('Croci ai cavi');

    final byId = await repository.exercisesByIds([
      panca.id,
      croci.id,
      'inesistente',
    ]);

    expect(byId.keys, {panca.id, croci.id});
    expect(byId[panca.id]!.name, 'Panca piana');
    expect(await repository.exercisesByIds(const []), isEmpty);
  });
}
