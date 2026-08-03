import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/sync/sync_gateway.dart';
import 'package:kal_tracker/core/time/app_time.dart';

const _mutationId = '11111111-1111-4111-8111-111111111111';
const _itemId = '22222222-2222-4222-8222-222222222222';
const _mealId = '33333333-3333-4333-8333-333333333333';
const _profileId = '44444444-4444-4444-8444-444444444444';
const _recipeId = '55555555-5555-4555-8555-555555555555';

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
}
