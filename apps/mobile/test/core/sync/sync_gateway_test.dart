import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/sync/sync_gateway.dart';
import 'package:kal_tracker/core/time/app_time.dart';

const _mutationId = '11111111-1111-4111-8111-111111111111';
const _itemId = '22222222-2222-4222-8222-222222222222';
const _mealId = '33333333-3333-4333-8333-333333333333';
const _profileId = '44444444-4444-4444-8444-444444444444';
const _recipeId = '55555555-5555-4555-8555-555555555555';
const _routineId = '77777777-7777-4777-8777-777777777777';
const _workoutId = '88888888-8888-4888-8888-888888888888';
const _exerciseId = '99999999-9999-4999-8999-999999999999';

void main() {
  setUpAll(AppTime.initialize);

  test(
    'meal_item upsert diventa meals + meal_items tradotti, senza totali',
    () {
      const mutation = SyncMutation(
        mutationId: _mutationId,
        entityType: 'meal_item',
        entityId: _itemId,
        operation: 'upsert',
        payload: {
          'id': _itemId,
          'meal_id': _mealId,
          'profile_id': _profileId,
          'meal_type': 'dinner',
          'eaten_at': '2026-08-02T22:30:00.000Z',
          'food_name': 'Riso basmati',
          'grams': 150.0,
          'calories_per_100g': 130.0,
          'protein_per_100g': 2.7,
          'carbs_per_100g': 28.2,
          'fat_per_100g': 0.3,
          'total_calories': 195.0,
          'total_protein': 4.05,
          'total_carbs': 42.3,
          'total_fat': 0.45,
          'updated_at': '2026-08-02T22:31:00.000Z',
        },
      );

      final mapped = SyncPushMapper.map(mutation);
      expect(mapped.profileLocalId, _profileId);
      expect(mapped.ops, hasLength(2));

      final meals = mapped.ops.first as RemoteUpsert;
      expect(meals.table, 'meals');
      final meal = meals.rows.single;
      expect(meal['id'], _mealId);
      expect(meal['profile_id'], _profileId);
      // Le 22:30 UTC d'estate a Roma sono già il giorno dopo.
      expect(meal['local_date'], '2026-08-03');
      expect(meal['time_zone'], 'Europe/Rome');
      expect(meal['meal_type'], 'dinner');
      expect(meal['last_mutation_id'], isNot(_mutationId));

      final items = mapped.ops.last as RemoteUpsert;
      expect(items.table, 'meal_items');
      final item = items.rows.single;
      expect(item['id'], _itemId);
      expect(item['quantity_g'], 150.0);
      expect(item['quantity_value'], 150.0);
      expect(item['quantity_unit'], 'g');
      expect(item['food_name_snapshot'], 'Riso basmati');
      expect(item['energy_kcal_per_100g'], 130.0);
      expect(item['carbohydrate_g_per_100g'], 28.2);
      expect(item['fiber_g_per_100g'], 0);
      expect(item['last_mutation_id'], _mutationId);
      // I totali sono colonne GENERATED sul server: non devono viaggiare.
      expect(item.containsKey('energy_kcal'), isFalse);
      expect(item.containsKey('total_calories'), isFalse);
    },
  );

  test('nutrition_target riceve id sintetico e i default del server', () {
    const mutation = SyncMutation(
      mutationId: _mutationId,
      entityType: 'nutrition_target',
      entityId: _profileId,
      operation: 'upsert',
      payload: {
        'profile_id': _profileId,
        'daily_calories': 2200.0,
        'daily_protein': 150.0,
        'daily_carbs': 220.0,
        'daily_fat': 70.0,
        'updated_at': '2026-08-02T10:00:00.000Z',
      },
    );

    final mapped = SyncPushMapper.map(mutation);
    final upsert = mapped.ops.single as RemoteUpsert;
    final row = upsert.rows.single;
    expect(upsert.table, 'nutrition_targets');
    expect(row['id'], SyncIds.nutritionTargetId(_profileId));
    expect(SyncIds.isUuid(row['id']! as String), isTrue);
    expect(row['effective_from'], '1970-01-01');
    expect(row['goal_type'], 'maintain');
    expect(row['energy_kcal'], 2200.0);
    expect(row['carbohydrate_g'], 220.0);
    expect(row['fiber_g'], 0);
  });

  test('le voci dei template ottengono id e mutation id deterministici', () {
    const mutation = SyncMutation(
      mutationId: _mutationId,
      entityType: 'meal_template',
      entityId: _recipeId,
      operation: 'upsert',
      payload: {
        'id': _recipeId,
        'profile_id': _profileId,
        'name': 'Colazione tipo',
        'meal_type': 'breakfast',
        'updated_at': '2026-08-02T07:00:00.000Z',
        'items': [
          {
            'position': 0,
            'food_name': 'Avena',
            'grams': 50.0,
            'calories_per_100g': 389.0,
            'protein_per_100g': 16.9,
            'carbs_per_100g': 66.3,
            'fat_per_100g': 6.9,
          },
          {
            'position': 1,
            'food_name': 'Banana',
            'grams': 120.0,
            'calories_per_100g': 89.0,
            'protein_per_100g': 1.1,
            'carbs_per_100g': 22.8,
            'fat_per_100g': 0.3,
          },
        ],
      },
    );

    final first = SyncPushMapper.map(mutation);
    final second = SyncPushMapper.map(mutation);
    final swap = first.ops.last as RemoteChildrenSwap;
    final swapAgain = second.ops.last as RemoteChildrenSwap;

    expect(swap.table, 'meal_template_items');
    expect(swap.parentColumn, 'template_id');
    expect(swap.rows, hasLength(2));
    for (final row in swap.rows) {
      expect(SyncIds.isUuid(row['id']! as String), isTrue);
      expect(row['deleted_at'], isNull);
      expect(row.containsKey('food_name_snapshot'), isTrue);
    }
    // Stesso evento => stessi uuid: il retry reinserisce righe identiche.
    expect(
      swap.rows.map((row) => row['id']).toList(),
      swapAgain.rows.map((row) => row['id']).toList(),
    );
    expect(
      swap.tombstoneMutationIdFor('riga-x'),
      swapAgain.tombstoneMutationIdFor('riga-x'),
    );
    expect(
      swap.rows.first['last_mutation_id'],
      isNot(swap.rows.last['last_mutation_id']),
    );
  });

  test('il retry dello swap non tombstona le righe appena inserite', () {
    const mutation = SyncMutation(
      mutationId: _mutationId,
      entityType: 'meal_template',
      entityId: _recipeId,
      operation: 'upsert',
      payload: {
        'id': _recipeId,
        'profile_id': _profileId,
        'name': 'Colazione tipo',
        'meal_type': 'breakfast',
        'updated_at': '2026-08-02T07:00:00.000Z',
        'items': [
          {
            'position': 0,
            'food_name': 'Avena',
            'grams': 50.0,
            'calories_per_100g': 389.0,
          },
        ],
      },
    );
    const previousGeneration = [
      'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    ];

    final swap = SyncPushMapper.map(mutation).ops.last as RemoteChildrenSwap;
    final newIds = [for (final row in swap.rows) row['id']! as String];

    // Primo tentativo: vive solo le righe della generazione precedente,
    // che vanno tombstonate tutte.
    expect(swap.tombstoneTargets(previousGeneration), previousGeneration);
    // Retry dopo risposta persa: le righe vive sono quelle appena
    // inserite e NON vanno tombstonate, altrimenti la re-upsert viene
    // assorbita dal ledger e i figli spariscono per sempre.
    expect(swap.tombstoneTargets(newIds), isEmpty);
    expect(swap.tombstoneTargets([...previousGeneration, ...newIds]), [
      ...previousGeneration,
    ]);
  });

  test('adoptProfile rimappa gli op sul profilo remoto già esistente', () {
    const adoptedProfileId = '66666666-6666-4666-8666-666666666666';
    const upsertMutation = SyncMutation(
      mutationId: _mutationId,
      entityType: 'nutrition_target',
      entityId: _profileId,
      operation: 'upsert',
      payload: {
        'profile_id': _profileId,
        'daily_calories': 2200.0,
        'updated_at': '2026-08-02T10:00:00.000Z',
      },
    );

    final upsert =
        SyncPushMapper.adoptProfile(
              SyncPushMapper.map(upsertMutation).ops.single,
              from: _profileId,
              to: adoptedProfileId,
            )
            as RemoteUpsert;
    final row = upsert.rows.single;
    expect(row['profile_id'], adoptedProfileId);
    // Anche l'id sintetico del target segue il profilo adottato, o la
    // unique (owner_id, profile_id, effective_from) esploderebbe.
    expect(row['id'], SyncIds.nutritionTargetId(adoptedProfileId));
    expect(row['last_mutation_id'], _mutationId);

    const deleteMutation = SyncMutation(
      mutationId: _mutationId,
      entityType: 'nutrition_target',
      entityId: _profileId,
      operation: 'delete',
      payload: {
        'profile_id': _profileId,
        'deleted_at': '2026-08-02T12:00:00.000Z',
      },
    );
    final patch =
        SyncPushMapper.adoptProfile(
              SyncPushMapper.map(deleteMutation).ops.single,
              from: _profileId,
              to: adoptedProfileId,
            )
            as RemotePatch;
    expect(patch.id, SyncIds.nutritionTargetId(adoptedProfileId));
  });

  test('il setFavorite parziale diventa una PATCH mirata', () {
    const mutation = SyncMutation(
      mutationId: _mutationId,
      entityType: 'fit_recipe',
      entityId: _recipeId,
      operation: 'upsert',
      payload: {
        'id': _recipeId,
        'is_favorite': true,
        'updated_at': '2026-08-02T10:00:00.000Z',
      },
    );

    final mapped = SyncPushMapper.map(mutation);
    final patch = mapped.ops.single as RemotePatch;
    expect(patch.table, 'recipes');
    expect(patch.id, _recipeId);
    expect(patch.values['is_favorite'], isTrue);
    expect(patch.values.containsKey('name'), isFalse);
    expect(patch.values['last_mutation_id'], _mutationId);
  });

  test('food_preference non viaggia verso il server', () {
    const mutation = SyncMutation(
      mutationId: _mutationId,
      entityType: 'food_preference',
      entityId: '$_profileId:seed-oats',
      operation: 'upsert',
      payload: {'profile_id': _profileId, 'food_id': 'seed-oats'},
    );

    expect(SyncPushMapper.map(mutation).ops, isEmpty);
  });

  test('un delete diventa una PATCH tombstone con mutation id nuovo', () {
    const mutation = SyncMutation(
      mutationId: _mutationId,
      entityType: 'water_log',
      entityId: _itemId,
      operation: 'delete',
      payload: {'id': _itemId, 'deleted_at': '2026-08-02T12:00:00.000Z'},
    );

    final patch = SyncPushMapper.map(mutation).ops.single as RemotePatch;
    expect(patch.table, 'water_logs');
    expect(patch.values['deleted_at'], '2026-08-02T12:00:00.000Z');
    expect(patch.values['last_mutation_id'], _mutationId);
  });

  test('gli id locali non-uuid diventano uuid remoti stabili', () {
    final remote = SyncIds.remoteId('seed-oats');
    expect(SyncIds.isUuid(remote), isTrue);
    expect(SyncIds.remoteId('seed-oats'), remote);
    expect(SyncIds.remoteId(_itemId), _itemId);
  });

  test('un entityType sconosciuto fa fallire il push, non lo ingoia', () {
    const mutation = SyncMutation(
      mutationId: _mutationId,
      entityType: 'entita_del_futuro',
      entityId: _itemId,
      operation: 'upsert',
      payload: {'id': _itemId},
    );

    // Senza l'eccezione il mapper restituirebbe zero op, pushMutation
    // riuscirebbe e il motore cancellerebbe la riga di outbox contandola
    // come inviata: perdita silenziosa e irreversibile.
    expect(
      () => SyncPushMapper.map(mutation),
      throwsA(
        isA<SyncGatewayException>()
            .having((error) => error.retryable, 'retryable', isTrue)
            .having(
              (error) => error.message,
              'message',
              contains('entita_del_futuro'),
            ),
      ),
    );
  });

  test('il solo tipo senza tabella remota resta food_preference', () {
    const mutation = SyncMutation(
      mutationId: _mutationId,
      entityType: 'food_preference',
      entityId: '$_profileId:seed-oats',
      operation: 'upsert',
      payload: {'profile_id': _profileId},
    );

    expect(SyncPushMapper.map(mutation).ops, isEmpty);
  });

  test('23503 e 23505 restano in coda invece di essere scartati', () {
    // Un FK mancante dice «il padre non è ancora arrivato», non «buttala».
    expect(SyncRetryPolicy.isRetryable('23503'), isTrue);
    expect(SyncRetryPolicy.isRetryable('23505'), isTrue);
    expect(SyncRetryPolicy.isRetryable('503'), isTrue);
    // Un CHECK violato invece è un rifiuto vero: ritentarlo bloccherebbe la
    // coda per sempre.
    expect(SyncRetryPolicy.isRetryable('23514'), isFalse);
    expect(SyncRetryPolicy.isRetryable('22023'), isFalse);
    expect(SyncRetryPolicy.isRetryable(null), isFalse);
  });

  test('il preset di defaticamento viaggia con id derivato e slug intatto', () {
    const mutation = SyncMutation(
      mutationId: _mutationId,
      entityType: 'exercise',
      entityId: 'cd-childpose',
      operation: 'upsert',
      payload: {
        'id': 'cd-childpose',
        'profile_id': _profileId,
        'name': 'Child pose',
        'muscle_group': 'mobilita',
        'tracking_mode': 'timed',
        'notes': 'Talloni sotto ai glutei, braccia distese, fronte a terra.',
        'default_rest_sec': 10,
        'is_preset': false,
        'is_synthetic': true,
        'source': 'cooldown_preset',
        'external_id': 'cd-childpose',
        'updated_at': '2026-08-05T10:38:57.000Z',
      },
    );

    final upsert = SyncPushMapper.map(mutation).ops.single as RemoteUpsert;
    final row = upsert.rows.single;
    expect(upsert.table, 'exercises');
    expect(row['id'], SyncIds.remoteId('cd-childpose'));
    expect(SyncIds.isUuid(row['id']! as String), isTrue);
    // external_id è testo: lo slug resta leggibile e deduplica l'import.
    expect(row['external_id'], 'cd-childpose');
    expect(row['muscle_group'], 'mobilita');
    expect(row['tracking_mode'], 'timed');
    expect(row['is_synthetic'], isTrue);
    expect(row['source'], 'cooldown_preset');
    expect(row['default_rest_sec'], 10);
  });

  test('un gruppo muscolare inventato ricade su altro invece di 23514', () {
    const mutation = SyncMutation(
      mutationId: _mutationId,
      entityType: 'exercise',
      entityId: _exerciseId,
      operation: 'upsert',
      payload: {
        'id': _exerciseId,
        'profile_id': _profileId,
        'name': 'Esercizio strano',
        'muscle_group': 'trapezi',
        'tracking_mode': 'inventata',
        'source': 'chissa',
        'updated_at': '2026-08-05T10:00:00.000Z',
      },
    );

    final row =
        (SyncPushMapper.map(mutation).ops.single as RemoteUpsert).rows.single;
    expect(row['muscle_group'], 'altro');
    expect(row['tracking_mode'], 'weightReps');
    expect(row['source'], 'manual');
  });

  test('la scheda porta con sé le tre liste e i blocchi a tempo', () {
    const mutation = SyncMutation(
      mutationId: _mutationId,
      entityType: 'routine',
      entityId: _routineId,
      operation: 'upsert',
      payload: {
        'id': _routineId,
        'profile_id': _profileId,
        'name': 'Giorno2 hiit fullbody',
        'is_circuit': true,
        'rounds': 4,
        'source': 'gym_tracker',
        'external_id': _routineId,
        'updated_at': '2026-08-05T10:00:00.000Z',
        'exercises': [
          {
            'id': 'aaaaaaaa-0000-4000-8000-000000000001',
            'block': 'warmup',
            'position': 0,
            'exercise_ref_id': _exerciseId,
            'exercise_id': _exerciseId,
            'exercise_name_snapshot': 'Circonduzioni braccia',
            'warmup_duration_sec': 30,
          },
          {
            'id': 'aaaaaaaa-0000-4000-8000-000000000002',
            'block': 'main',
            'position': 1,
            'exercise_ref_id': 'cd-childpose',
            'exercise_name_snapshot': 'Child pose',
            'in_superset_with_previous': true,
          },
        ],
        'interval_segments': [
          {
            'id': 'bbbbbbbb-0000-4000-8000-000000000001',
            'segment_index': 0,
            'start_idx': 0,
            'end_idx': 3,
            'work_sec': 40,
            'rest_sec': 20,
            'rounds': 4,
          },
        ],
      },
    );

    final ops = SyncPushMapper.map(mutation).ops;
    expect(ops, hasLength(3));

    final routine = (ops[0] as RemoteUpsert).rows.single;
    expect((ops[0] as RemoteUpsert).table, 'routines');
    expect(routine['is_circuit'], isTrue);
    expect(routine['rounds'], 4);
    // I default di Gym restano NOT NULL anche se il payload non li cita.
    expect(routine['work_sec'], 30);
    expect(routine['warmup_rest_sec'], 15);

    final exercises = ops[1] as RemoteChildrenSwap;
    expect(exercises.table, 'routine_exercises');
    expect(exercises.parentColumn, 'routine_id');
    expect(exercises.parentId, _routineId);
    expect(exercises.rows, hasLength(2));
    expect(exercises.rows.first['block'], 'warmup');
    expect(exercises.rows.first['warmup_duration_sec'], 30);
    // Lo slug non-uuid passa dalla stessa derivazione dell'esercizio, o la
    // FK remota risponderebbe 23503.
    expect(
      exercises.rows.last['exercise_ref_id'],
      SyncIds.remoteId('cd-childpose'),
    );
    expect(exercises.rows.last['exercise_id'], isNull);

    final segments = ops[2] as RemoteChildrenSwap;
    expect(segments.table, 'routine_interval_segments');
    expect(segments.rows.single['end_idx'], 3);
    expect(segments.rows.single['rounds'], 4);
  });

  test('la sessione porta esercizi, serie, dolori e marker di segmento', () {
    const mutation = SyncMutation(
      mutationId: _mutationId,
      entityType: 'workout',
      entityId: _workoutId,
      operation: 'upsert',
      payload: {
        'id': _workoutId,
        'profile_id': _profileId,
        'started_at': '2026-06-26T06:32:00.000Z',
        'ended_at': '2026-07-18T14:29:00.000Z',
        // Sessione dimenticata aperta 536 ore: entra grezza e marcata.
        'duration_suspect': true,
        'total_kcal': 477.7840476190476,
        'xp_earned': 0,
        'routine_external_id': _routineId,
        'routine_name_snapshot': 'Esercizi  2',
        // Nome della colonna locale (testo): l'importer accoda così.
        'circuit_checkpoint_json': '{"segment":2,"round":1}',
        'source': 'gym_tracker',
        'external_id': _workoutId,
        'updated_at': '2026-08-05T10:00:00.000Z',
        'exercises': [
          {
            'id': 'cccccccc-0000-4000-8000-000000000001',
            'position': 0,
            'exercise_ref_id': 'cd-childpose',
            'exercise_id': 'cd-childpose',
            'exercise_name_snapshot': 'Child pose',
            'tracking_mode': 'timed',
            'muscle_group_snapshot': 'mobilita',
            'is_cooldown': true,
            'sets': [
              {
                'id': 'dddddddd-0000-4000-8000-000000000001',
                'position': 0,
                'duration_sec': 40,
                'completed': true,
              },
              {
                'id': 'dddddddd-0000-4000-8000-000000000002',
                'position': 1,
                'reps': 12,
                'weight_kg': 8.0,
              },
            ],
          },
        ],
        'pain_points': [
          {'id': 'eeeeeeee-0000-4000-8000-000000000001', 'label': 'Spalla dx'},
        ],
        'interval_segments': [
          {
            'id': 'ffffffff-0000-4000-8000-000000000001',
            'segment_index': 0,
            'completed_marker': true,
            'partial_marker': true,
            'completion_signature': '{"work":40}',
          },
        ],
      },
    );

    final ops = SyncPushMapper.map(mutation).ops;
    expect(ops, hasLength(5));

    final workout = (ops[0] as RemoteUpsert).rows.single;
    expect((ops[0] as RemoteUpsert).table, 'workouts');
    expect(workout['duration_suspect'], isTrue);
    expect(workout['total_kcal'], 477.7840476190476);
    // NULL e 0 sono stati diversi: lo zero degli XP non deve sparire.
    expect(workout['xp_earned'], 0);
    expect(workout['routine_id'], isNull);
    expect(workout['routine_external_id'], _routineId);
    expect(workout['routine_name_snapshot'], 'Esercizi  2');
    // La colonna remota è jsonb con CHECK su jsonb_typeof = 'object'.
    expect(workout['circuit_checkpoint'], {'segment': 2, 'round': 1});

    final exercises = ops[1] as RemoteChildrenSwap;
    expect(exercises.table, 'workout_exercises');
    final exerciseRow = exercises.rows.single;
    expect(exerciseRow['exercise_id'], SyncIds.remoteId('cd-childpose'));
    expect(exerciseRow['exercise_ref_id'], exerciseRow['exercise_id']);
    expect(exerciseRow['is_cooldown'], isTrue);
    expect(exerciseRow['is_warmup'], isFalse);

    final sets = ops[2] as RemoteChildrenSwap;
    expect(sets.table, 'workout_sets');
    // Le serie si sostituiscono in blocco dal padre: per questo la tabella
    // remota porta anche workout_id.
    expect(sets.parentColumn, 'workout_id');
    expect(sets.rows, hasLength(2));
    expect(sets.rows.first['workout_exercise_id'], exerciseRow['id']);
    expect(sets.rows.first['duration_sec'], 40);
    expect(sets.rows.first['weight_kg'], isNull);
    expect(sets.rows.last['reps'], 12);
    expect(sets.rows.last['weight_kg'], 8.0);
    expect(sets.rows.last['completed'], isFalse);

    expect((ops[3] as RemoteChildrenSwap).table, 'workout_pain_points');
    expect((ops[3] as RemoteChildrenSwap).rows.single['label'], 'Spalla dx');

    final segments = ops[4] as RemoteChildrenSwap;
    expect(segments.table, 'workout_interval_segments');
    // I due marker sono indipendenti e possono valere insieme.
    expect(segments.rows.single['completed_marker'], isTrue);
    expect(segments.rows.single['partial_marker'], isTrue);
    expect(segments.rows.single['completion_signature'], '{"work":40}');
  });

  test('ogni riga di una sessione ha il suo last_mutation_id', () {
    const mutation = SyncMutation(
      mutationId: _mutationId,
      entityType: 'workout',
      entityId: _workoutId,
      operation: 'upsert',
      payload: {
        'id': _workoutId,
        'profile_id': _profileId,
        'started_at': '2026-08-04T20:34:30.000Z',
        'updated_at': '2026-08-05T10:00:00.000Z',
        'exercises': [
          {
            'position': 0,
            'exercise_ref_id': _exerciseId,
            'exercise_name_snapshot': 'Panca piana',
            'tracking_mode': 'weightReps',
            'sets': [
              {'position': 0, 'reps': 10},
              {'position': 1, 'reps': 8},
            ],
          },
          {
            'position': 1,
            'exercise_ref_id': _exerciseId,
            'exercise_name_snapshot': 'Panca piana',
            'tracking_mode': 'weightReps',
            'sets': [
              {'position': 0, 'reps': 6},
            ],
          },
        ],
      },
    );

    final ops = SyncPushMapper.map(mutation).ops;
    final ids = <String>[];
    final mutationIds = <String>[];
    for (final op in ops) {
      final rows = switch (op) {
        RemoteUpsert() => op.rows,
        RemoteChildrenSwap() => op.rows,
        RemotePatch() => const <Map<String, Object?>>[],
      };
      for (final row in rows) {
        ids.add(row['id']! as String);
        mutationIds.add(row['last_mutation_id']! as String);
      }
    }

    // Il server impone unique (owner_id, last_mutation_id) su ogni tabella:
    // due righe con lo stesso valore si respingono a vicenda con un 23505.
    expect(mutationIds.toSet(), hasLength(mutationIds.length));
    // E senza id nel payload le righe restano comunque distinte fra loro.
    expect(ids.toSet(), hasLength(ids.length));
    for (final id in ids) {
      expect(SyncIds.isUuid(id), isTrue);
    }
  });

  test('le stats mandano una data di calendario, non un istante', () {
    SyncMutation stats(Object? lastWorkoutDay) => SyncMutation(
      mutationId: _mutationId,
      entityType: 'workout_profile_stats',
      entityId: _profileId,
      operation: 'upsert',
      payload: {
        'id': _profileId,
        'profile_id': _profileId,
        'total_xp': 11370,
        'current_streak': 2,
        'longest_streak': 1,
        'last_workout_day': lastWorkoutDay,
        'weekly_workout_goal': 4,
        'reminder_enabled': true,
        'health_connect_enabled': true,
        'gym_body_weight_kg': 94.7,
        'updated_at': '2026-08-05T10:00:00.000Z',
      },
    );

    Map<String, Object?> rowFor(Object? day) =>
        (SyncPushMapper.map(stats(day)).ops.first as RemoteUpsert).rows.single;

    // La mezzanotte di Roma del 4 agosto è le 22:00 UTC del 3: mandata così
    // in una colonna `date` diventerebbe il 3 e lo streak partirebbe da ieri.
    expect(
      rowFor('2026-08-03T22:00:00.000Z')['last_workout_day'],
      '2026-08-04',
    );
    expect(rowFor('2026-08-04')['last_workout_day'], '2026-08-04');
    expect(rowFor(null)['last_workout_day'], isNull);

    final row = rowFor('2026-08-04');
    expect(row['total_xp'], 11370);
    expect(row['reminder_enabled'], isTrue);
    expect(row['health_connect_enabled'], isTrue);
    expect(row['gym_body_weight_kg'], 94.7);
    // Il CHECK remoto pretende longest >= current.
    expect(row['longest_streak'], 2);
  });

  test('trofei e piano settimanale sono figli del profilo', () {
    const mutation = SyncMutation(
      mutationId: _mutationId,
      entityType: 'workout_profile_stats',
      entityId: _profileId,
      operation: 'upsert',
      payload: {
        'id': _profileId,
        'profile_id': _profileId,
        'updated_at': '2026-08-05T10:00:00.000Z',
        'achievements': [
          {
            'id': '10000000-0000-4000-8000-000000000001',
            'slug': 'first_workout',
          },
          {'id': '10000000-0000-4000-8000-000000000002', 'slug': 'hours_24'},
        ],
        'weekly_plan': [
          {
            'id': '20000000-0000-4000-8000-000000000003',
            'weekday': 3,
            'routine_external_id': _routineId,
            'routine_name_snapshot': 'Esercizi 1',
          },
        ],
      },
    );

    final ops = SyncPushMapper.map(mutation).ops;
    final achievements = ops[1] as RemoteChildrenSwap;
    expect(achievements.table, 'workout_achievements');
    expect(achievements.parentColumn, 'profile_id');
    expect(achievements.parentId, _profileId);
    expect(achievements.rows.map((row) => row['slug']), [
      'first_workout',
      'hours_24',
    ]);
    // L'export non dice quando: NULL, non l'istante dell'import.
    expect(achievements.rows.first['unlocked_at'], isNull);

    final plan = ops[2] as RemoteChildrenSwap;
    expect(plan.table, 'routine_weekly_plan');
    expect(plan.parentColumn, 'profile_id');
    // Il giorno 3 punta a una scheda cancellata: la FK resta vuota ma id e
    // nome sopravvivono.
    expect(plan.rows.single['routine_id'], isNull);
    expect(plan.rows.single['routine_external_id'], _routineId);
    expect(plan.rows.single['routine_name_snapshot'], 'Esercizi 1');
  });

  test('adoptProfile segue anche il padre di uno swap sul profilo', () {
    const adoptedProfileId = '66666666-6666-4666-8666-666666666666';
    const mutation = SyncMutation(
      mutationId: _mutationId,
      entityType: 'workout_profile_stats',
      entityId: _profileId,
      operation: 'upsert',
      payload: {
        'id': _profileId,
        'profile_id': _profileId,
        'updated_at': '2026-08-05T10:00:00.000Z',
        'achievements': [
          {
            'id': '10000000-0000-4000-8000-000000000001',
            'slug': 'first_workout',
          },
        ],
      },
    );

    final swap =
        SyncPushMapper.adoptProfile(
              SyncPushMapper.map(mutation).ops[1],
              from: _profileId,
              to: adoptedProfileId,
            )
            as RemoteChildrenSwap;
    // Con il parentId vecchio lo swap cercherebbe le righe vive sotto un
    // profilo che sul server non esiste più.
    expect(swap.parentId, adoptedProfileId);
    expect(swap.rows.single['profile_id'], adoptedProfileId);
  });

  test('la pesata importata conserva sorgente e circonferenze', () {
    const measurementId = '30000000-0000-4000-8000-000000000001';
    const mutation = SyncMutation(
      mutationId: _mutationId,
      entityType: 'body_measurement',
      entityId: measurementId,
      operation: 'upsert',
      payload: {
        'id': measurementId,
        'profile_id': _profileId,
        'weight_kg': 96.2,
        'measured_at': '2026-04-22T07:00:00.000Z',
        'source': 'gym_tracker',
        'external_id': measurementId,
        'updated_at': '2026-08-05T10:00:00.000Z',
        'values': [
          {
            'id': '40000000-0000-4000-8000-000000000001',
            'label': 'Vita',
            'value': 106.0,
          },
        ],
      },
    );

    final ops = SyncPushMapper.map(mutation).ops;
    final measurement = (ops.first as RemoteUpsert).rows.single;
    // Forzare 'kal_tracker' romperebbe la unique (source, external_id) che
    // impedisce di reimportare le stesse pesate.
    expect(measurement['source'], 'gym_tracker');
    expect(measurement['external_id'], measurementId);

    final values = ops.last as RemoteChildrenSwap;
    expect(values.table, 'body_measurement_values');
    expect(values.parentColumn, 'measurement_id');
    expect(values.parentId, measurementId);
    expect(values.rows.single['label'], 'Vita');
    expect(values.rows.single['value'], 106.0);
  });

  test('un aggiornamento parziale della sessione non azzera i figli', () {
    const partial = SyncMutation(
      mutationId: _mutationId,
      entityType: 'workout',
      entityId: _workoutId,
      operation: 'upsert',
      payload: {
        'id': _workoutId,
        'profile_id': _profileId,
        'started_at': '2026-08-04T20:34:30.000Z',
        'ended_at': '2026-08-04T21:10:00.000Z',
        'mood': 4,
        'updated_at': '2026-08-04T21:10:05.000Z',
      },
    );
    const emptied = SyncMutation(
      mutationId: _mutationId,
      entityType: 'workout',
      entityId: _workoutId,
      operation: 'upsert',
      payload: {
        'id': _workoutId,
        'profile_id': _profileId,
        'started_at': '2026-08-04T20:34:30.000Z',
        'updated_at': '2026-08-04T21:10:05.000Z',
        'exercises': <Object?>[],
      },
    );

    // Chiudere una sessione non parla di esercizi: senza la chiave gli swap
    // non partono e le 250 righe restano dove sono.
    expect(SyncPushMapper.map(partial).ops, hasLength(1));
    // Una lista vuota invece è un'affermazione: figli non ce ne sono più.
    final ops = SyncPushMapper.map(emptied).ops;
    expect(ops, hasLength(3));
    expect((ops[1] as RemoteChildrenSwap).rows, isEmpty);
    expect((ops[2] as RemoteChildrenSwap).table, 'workout_sets');
  });

  test('una pesata senza la chiave values non tocca le circonferenze', () {
    const measurementId = '30000000-0000-4000-8000-000000000002';
    const mutation = SyncMutation(
      mutationId: _mutationId,
      entityType: 'body_measurement',
      entityId: measurementId,
      operation: 'upsert',
      payload: {
        'id': measurementId,
        'profile_id': _profileId,
        'weight_kg': 81.0,
        'measured_at': '2026-08-03T06:00:00.000Z',
        'updated_at': '2026-08-03T06:00:00.000Z',
      },
    );

    final ops = SyncPushMapper.map(mutation).ops;
    // Uno swap incondizionato tombstonerebbe le circonferenze a ogni pesata
    // scritta dalla schermata Benessere, che di values non sa niente.
    expect(ops, hasLength(1));
    expect((ops.single as RemoteUpsert).rows.single['source'], 'kal_tracker');
  });

  test('la settimana di allenamenti viaggia intera, non giorno per '
      'giorno', () {
    const dayId = '50000000-0000-4000-8000-000000000002';
    const mutation = SyncMutation(
      mutationId: _mutationId,
      entityType: 'routine_weekly_plan',
      entityId: _profileId,
      operation: 'upsert',
      payload: {
        'profile_id': _profileId,
        'updated_at': '2026-08-06T09:00:00.000Z',
        'days': [
          {
            'id': dayId,
            'weekday': 2,
            'routine_id': _routineId,
            'routine_external_id': _routineId,
            'routine_name_snapshot': 'Giorno1 spalle petto tricipiti',
          },
        ],
      },
    );

    final ops = SyncPushMapper.map(mutation).ops;
    // Una sola operazione, e non è un upsert: è una sostituzione in blocco
    // dei figli del profilo. Solo così il giorno TOLTO — che localmente è una
    // riga sparita e non un tombstone — arriva anche di là.
    expect(ops, hasLength(1));
    final swap = ops.single as RemoteChildrenSwap;
    expect(swap.table, 'routine_weekly_plan');
    expect(swap.parentColumn, 'profile_id');
    expect(swap.parentId, _profileId);
    expect(swap.tombstoneAt, '2026-08-06T09:00:00.000Z');

    final row = swap.rows.single;
    expect(row['id'], dayId);
    expect(row['profile_id'], _profileId);
    expect(row['weekday'], 2);
    expect(row['routine_id'], _routineId);
    expect(row['routine_external_id'], _routineId);
    expect(row['routine_name_snapshot'], 'Giorno1 spalle petto tricipiti');
    expect(row['deleted_at'], isNull);
    expect(SyncIds.isUuid(row['last_mutation_id']! as String), isTrue);

    // Le righe della generazione corrente non si tombstonano: dopo una
    // risposta persa il retry le rivedrebbe «vive» e le azzererebbe.
    expect(swap.tombstoneTargets([dayId, 'altro']), ['altro']);
  });

  test('una settimana vuota tombstona tutti i giorni', () {
    const mutation = SyncMutation(
      mutationId: _mutationId,
      entityType: 'routine_weekly_plan',
      entityId: _profileId,
      operation: 'upsert',
      payload: {
        'profile_id': _profileId,
        'updated_at': '2026-08-06T09:00:00.000Z',
        'days': <Object?>[],
      },
    );

    final swap = SyncPushMapper.map(mutation).ops.single as RemoteChildrenSwap;
    // «Sette giorni di riposo» è un'affermazione, non un'omissione: le righe
    // remote devono sparire tutte.
    expect(swap.rows, isEmpty);
    expect(swap.tombstoneTargets(['a', 'b']), ['a', 'b']);
  });

  test('una settimana senza la chiave days non viene mandata', () {
    const mutation = SyncMutation(
      mutationId: _mutationId,
      entityType: 'routine_weekly_plan',
      entityId: _profileId,
      operation: 'upsert',
      payload: {'profile_id': _profileId},
    );

    // Uno swap con zero righe cancellerebbe la settimana già sincronizzata
    // credendo di aggiornarla: meglio perdere questa riga di coda (che
    // nessun dato locale rappresenta) che il dato di là. Non ritentabile,
    // così la coda prosegue invece di bloccarsi su un payload che non
    // migliorerà da solo.
    expect(
      () => SyncPushMapper.map(mutation),
      throwsA(
        isA<SyncGatewayException>().having(
          (error) => error.retryable,
          'ritentabile',
          isFalse,
        ),
      ),
    );
  });

  test('adoptProfile riporta anche la settimana sul profilo adottato', () {
    const adoptedProfileId = '66666666-6666-4666-8666-666666666666';
    const mutation = SyncMutation(
      mutationId: _mutationId,
      entityType: 'routine_weekly_plan',
      entityId: _profileId,
      operation: 'upsert',
      payload: {
        'profile_id': _profileId,
        'updated_at': '2026-08-06T09:00:00.000Z',
        'days': [
          {
            'id': '50000000-0000-4000-8000-000000000005',
            'weekday': 5,
            'routine_id': _routineId,
            'routine_external_id': _routineId,
            'routine_name_snapshot': 'Gambe',
          },
        ],
      },
    );

    final swap =
        SyncPushMapper.adoptProfile(
              SyncPushMapper.map(mutation).ops.single,
              from: _profileId,
              to: adoptedProfileId,
            )
            as RemoteChildrenSwap;
    expect(swap.parentId, adoptedProfileId);
    expect(swap.rows.single['profile_id'], adoptedProfileId);
  });

  test('training profile e nuovi dati Coach360 non bloccano la coda', () {
    const cases = <(String, String)>[
      ('daily_check_in', 'daily_check_ins'),
      ('goal', 'goals'),
      ('training_profile', 'training_profiles'),
      ('training_limitation', 'training_limitations'),
      ('daily_health_summary', 'daily_health_summaries'),
      ('coach_feed_item', 'coach_feed_items'),
    ];
    for (final (entityType, table) in cases) {
      final mapped = SyncPushMapper.map(
        SyncMutation(
          mutationId: _mutationId,
          entityType: entityType,
          entityId: entityType == 'training_profile' ? _profileId : _itemId,
          operation: 'upsert',
          payload: _coach360Payload(entityType),
        ),
      );
      expect(mapped.ops, isNotEmpty, reason: entityType);
      expect((mapped.ops.single as RemoteUpsert).table, table);
    }
  });

  test(
    'la pesata Renpho porta composizione, provenienza e impedenze figlie',
    () {
      const mutation = SyncMutation(
        mutationId: _mutationId,
        entityType: 'body_measurement',
        entityId: _itemId,
        operation: 'upsert',
        payload: {
          'id': _itemId,
          'profile_id': _profileId,
          'weight_kg': 82.4,
          'measured_at': '2026-08-08T06:30:00.000Z',
          'has_impedance': true,
          'impedance_ohm': 512.5,
          'body_fat_pct': 22.1,
          'muscle_pct': 73.2,
          'water_pct': 55.8,
          'source': 'renpho_ble',
          'external_id': 'renpho-reading-1',
          'device_model': 'RENPHO 8 electrodes',
          'raw_payload': 'a1b2c3',
          'updated_at': '2026-08-08T06:31:00.000Z',
          'impedance_readings': [
            {
              'id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              'segment': 'whole',
              'frequency_hz': 50000,
              'ohm': 512.5,
            },
          ],
        },
      );

      final ops = SyncPushMapper.map(mutation).ops;
      expect(ops, hasLength(2));
      final parent = (ops.first as RemoteUpsert).rows.single;
      expect(parent['body_fat_pct'], 22.1);
      expect(parent['device_model'], 'RENPHO 8 electrodes');
      expect(parent['raw_payload'], 'a1b2c3');
      final children = ops.last as RemoteChildrenSwap;
      expect(children.table, 'body_impedance_readings');
      expect(children.rows.single['frequency_hz'], 50000);
      expect(children.rows.single['ohm'], 512.5);
    },
  );
}

Map<String, Object?> _coach360Payload(String entityType) {
  const base = <String, Object?>{
    'id': _itemId,
    'profile_id': _profileId,
    'created_at': '2026-08-08T06:00:00.000Z',
    'updated_at': '2026-08-08T06:00:00.000Z',
  };
  return switch (entityType) {
    'daily_check_in' => {
      ...base,
      'day': '2026-08-08',
      'sleep_hours': 7.5,
      'energy_score': 4,
      'steps': 9000,
    },
    'goal' => {
      ...base,
      'target_weight_kg': 78.0,
      'target_level': 'defined',
      'pace_kg_per_week': 0.4,
      'started_at': '2026-08-08T06:00:00.000Z',
      'start_weight_kg': 82.0,
      'start_fat_free_mass_kg': 64.0,
      'phase': 'approach',
    },
    'training_profile' => {
      ...base,
      'profile_id': _profileId,
      'equipment': 'manubri,panca',
      'sessions_per_week': 4,
      'minutes_per_session': 60,
      'preferred_days': 'lun,mar,gio,sab',
      'deload_preference': 'suggerito',
    },
    'training_limitation' => {
      ...base,
      'body_part': 'spalla_dx',
      'severity': 'fastidio',
      'started_at': '2026-08-08T06:00:00.000Z',
    },
    'daily_health_summary' => {
      ...base,
      'day': '2026-08-08',
      'source': 'health_connect',
      'steps': 9000,
    },
    'coach_feed_item' => {
      ...base,
      'kind': 'weekly_review',
      'source': 'deterministic',
      'title': 'Rapporto',
      'body': 'Settimana completata.',
      'occurred_at': '2026-08-08T06:00:00.000Z',
    },
    _ => throw ArgumentError.value(entityType),
  };
}
