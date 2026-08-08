import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/sync/sync_engine.dart';
import 'package:kal_tracker/core/sync/sync_gateway.dart';
import 'package:kal_tracker/core/sync/sync_state_store.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/weekly_plan/data/workout_plan_repository.dart';
import 'package:kal_tracker/features/wellbeing/data/wellbeing_repository.dart';

class FakeSyncGateway implements SyncGateway {
  FakeSyncGateway({
    this.account = const SyncAccount(userId: 'user-1', email: 'marco@test.it'),
  });

  SyncAccount? account;
  final List<SyncMutation> received = [];
  final Set<String> appliedMutationIds = {};
  int applied = 0;
  List<RemoteChange> changes = [];
  final List<int> fetchCursors = [];
  SyncGatewayException? Function(SyncMutation mutation)? failBeforeApply;
  bool failAfterApply = false;

  @override
  Future<SyncAccount?> currentAccount() async => account;

  @override
  Future<SyncAccount> signIn({
    required String email,
    required String password,
  }) async {
    account = SyncAccount(userId: 'user-1', email: email);
    return account!;
  }

  @override
  Future<void> signOut() async {
    account = null;
  }

  @override
  Future<void> pushMutation(SyncMutation mutation) async {
    received.add(mutation);
    if (appliedMutationIds.contains(mutation.mutationId)) {
      // Come il ledger sync_changes: il retry identico è un no-op.
      return;
    }
    final failure = failBeforeApply?.call(mutation);
    if (failure != null) {
      throw failure;
    }
    appliedMutationIds.add(mutation.mutationId);
    applied++;
    if (failAfterApply) {
      failAfterApply = false;
      throw const SyncGatewayException('Risposta persa.', retryable: true);
    }
  }

  @override
  Future<List<RemoteChange>> fetchChanges({
    required int afterChangeId,
    int limit = 200,
  }) async {
    fetchCursors.add(afterChangeId);
    return changes
        .where((change) => change.changeId > afterChangeId)
        .take(limit)
        .toList(growable: false);
  }
}

/// Gateway con lo stesso contratto di quello vero: traduce la mutation con
/// [SyncPushMapper] e "invia" soltanto gli op che ne escono. Serve a
/// presidiare il buco per cui una mappatura vuota è indistinguibile da un
/// invio riuscito.
class MappingSyncGateway extends FakeSyncGateway {
  final List<RemoteOp> executed = [];

  @override
  Future<void> pushMutation(SyncMutation mutation) async {
    received.add(mutation);
    executed.addAll(SyncPushMapper.map(mutation).ops);
    applied++;
  }
}

const _mealId = '33333333-3333-4333-8333-333333333333';
const _itemId = '22222222-2222-4222-8222-222222222222';
const _routineId = '77777777-7777-4777-8777-777777777777';
const _workoutId = '88888888-8888-4888-8888-888888888888';
const _exerciseId = '99999999-9999-4999-8999-999999999999';
const _rowId = 'aaaaaaaa-0000-4000-8000-000000000001';
const _setId = 'dddddddd-0000-4000-8000-000000000001';

const _cloudConfig = AppConfig(
  supabaseUrl: 'https://esempio.supabase.co',
  supabasePublishableKey: 'sb_publishable_finta',
  otaManifestUrl: '',
  otaPublicKeyBase64: '',
  otaKeyId: 'ota-test',
  otaChannel: 'personal',
);

void main() {
  late AppDatabase database;
  late String profileId;
  late FakeSyncGateway gateway;
  late SyncStateStore store;
  late Directory tempDir;
  late DateTime now;

  SyncEngine engine() => SyncEngine(
    database: database,
    gateway: gateway,
    stateStore: store,
    now: () => now,
  );

  Future<List<SyncOutboxData>> outbox() =>
      database.select(database.syncOutbox).get();

  setUp(() async {
    AppTime.initialize();
    now = DateTime.utc(2026, 8, 3, 10);
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
    gateway = FakeSyncGateway();
    tempDir = await Directory.systemTemp.createTemp('kal-sync-engine');
    store = SyncStateStore(stateDirectory: () async => tempDir);
  });

  tearDown(() async {
    await database.close();
    await tempDir.delete(recursive: true);
  });

  test('il push drena in ordine e cancella solo dopo la conferma', () async {
    final repository = WellbeingRepository(database);
    final first = await repository.addWater(
      profileId: profileId,
      milliliters: 250,
      loggedAt: DateTime(2026, 8, 3, 8),
    );
    final second = await repository.addWater(
      profileId: profileId,
      milliliters: 500,
      loggedAt: DateTime(2026, 8, 3, 9),
    );
    final third = await repository.addWeight(
      profileId: profileId,
      weightKg: 81,
      measuredAt: DateTime(2026, 8, 3, 7),
    );

    final report = await engine().sync();

    expect(report.pushed, 3);
    expect(report.error, isNull);
    expect(gateway.received.map((mutation) => mutation.entityId).toList(), [
      first,
      second,
      third,
    ]);
    expect(await outbox(), isEmpty);
  });

  test('un errore del server lascia la riga con backoff nel futuro', () async {
    await WellbeingRepository(database).addWater(
      profileId: profileId,
      milliliters: 250,
      loggedAt: DateTime(2026, 8, 3, 8),
    );
    gateway.failBeforeApply = (_) =>
        const SyncGatewayException('Server giù.', retryable: true);

    var report = await engine().sync();
    expect(report.pushed, 0);
    expect(report.error, 'Server giù.');
    var row = (await outbox()).single;
    expect(row.attemptCount, 1);
    expect(row.nextAttemptAt!.toUtc(), now.add(const Duration(minutes: 1)));

    // Prima del backoff la testa della coda resta ferma: zero nuovi invii.
    gateway.failBeforeApply = null;
    final callsBefore = gateway.received.length;
    report = await engine().sync();
    expect(gateway.received.length, callsBefore);
    expect((await outbox()).single.attemptCount, 1);

    // Passato il backoff la coda si svuota.
    now = now.add(const Duration(minutes: 2));
    report = await engine().sync();
    expect(report.pushed, 1);
    expect(await outbox(), isEmpty);
  });

  test(
    'una mutation rifiutata per sempre viene scartata, la coda scorre',
    () async {
      final repository = WellbeingRepository(database);
      final poisoned = await repository.addWater(
        profileId: profileId,
        milliliters: 250,
        loggedAt: DateTime(2026, 8, 3, 8),
      );
      final healthy = await repository.addWater(
        profileId: profileId,
        milliliters: 500,
        loggedAt: DateTime(2026, 8, 3, 9),
      );
      // 23514: un CHECK violato è l'unico rifiuto davvero definitivo, e
      // ritentarlo per sempre bloccherebbe tutta la coda dietro questa riga.
      gateway.failBeforeApply = (mutation) => mutation.entityId == poisoned
          ? const SyncGatewayException(
              'Il server ha rifiutato la modifica (codice 23514).',
            )
          : null;

      final report = await engine().sync();

      // La riga avvelenata viene scartata (non ritentata per sempre) e
      // quella successiva raggiunge comunque il server.
      expect(report.pushed, 1);
      expect(report.error, contains('scartata'));
      expect(await outbox(), isEmpty);
      expect(
        gateway.received.map((mutation) => mutation.entityId),
        contains(healthy),
      );
      expect(gateway.applied, 1);
    },
  );

  test(
    '"Sincronizza ora" scavalca il backoff della testa della coda',
    () async {
      await WellbeingRepository(database).addWater(
        profileId: profileId,
        milliliters: 250,
        loggedAt: DateTime(2026, 8, 3, 8),
      );
      gateway.failBeforeApply = (_) =>
          const SyncGatewayException('Server giù.', retryable: true);
      final container = ProviderContainer(
        overrides: [
          appConfigProvider.overrideWithValue(_cloudConfig),
          databaseProvider.overrideWithValue(database),
          syncGatewayProvider.overrideWithValue(gateway),
          syncStateStoreProvider.overrideWithValue(store),
          syncDebounceProvider.overrideWithValue(const Duration(days: 1)),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(syncControllerProvider.notifier);

      await controller.syncNow();
      expect(container.read(syncControllerProvider).phase, SyncPhase.error);
      expect((await outbox()).single.nextAttemptAt, isNotNull);

      // Il backoff è ancora nel futuro, ma il comando manuale tenta subito.
      gateway.failBeforeApply = null;
      await controller.syncNow();

      expect(await outbox(), isEmpty);
      expect(gateway.applied, 1);
      expect(container.read(syncControllerProvider).phase, SyncPhase.idle);
    },
  );

  test('un errore locale nel pull non fa avanzare il cursore', () async {
    gateway.changes = [
      const RemoteChange(
        changeId: 1,
        entityType: 'meals',
        entityId: _mealId,
        operation: 'upsert',
        payload: {
          'id': _mealId,
          'meal_type': 'lunch',
          'eaten_at': '2026-08-02T11:30:00+00:00',
          'created_at': '2026-08-02T11:30:00+00:00',
          'updated_at': '2026-08-02T11:30:00+00:00',
          'deleted_at': null,
        },
      ),
    ];
    // Simula un errore transitorio del DB locale (lock, disco pieno).
    await database.customStatement(
      'CREATE TRIGGER kal_test_meals_busy BEFORE INSERT ON meals '
      "BEGIN SELECT RAISE(ABORT, 'database occupato'); END",
    );

    var report = await engine().sync();
    expect(report.pulled, 0);
    expect(
      report.error,
      'Salvataggio locale non riuscito: riproverò più tardi.',
    );
    expect(
      (await store.read()).lastChangeId,
      0,
      reason: 'il cursore non deve superare la riga non applicata',
    );

    // Passato il problema, la stessa riga viene riscaricata e applicata.
    await database.customStatement('DROP TRIGGER kal_test_meals_busy');
    report = await engine().sync();
    expect(report.pulled, 1);
    expect(report.error, isNull);
    expect((await store.read()).lastChangeId, 1);
    final meal = await (database.select(
      database.meals,
    )..where((t) => t.id.equals(_mealId))).getSingle();
    expect(meal.mealType, 'lunch');
  });

  test('il retry con lo stesso mutation id non duplica nulla', () async {
    await WellbeingRepository(database).addWater(
      profileId: profileId,
      milliliters: 250,
      loggedAt: DateTime(2026, 8, 3, 8),
    );
    // Crash simulato: il server applica ma la conferma non arriva.
    gateway.failAfterApply = true;

    await engine().sync();
    expect(gateway.applied, 1);
    expect(await outbox(), hasLength(1));

    now = now.add(const Duration(minutes: 2));
    final report = await engine().sync();
    expect(report.pushed, 1);
    expect(gateway.applied, 1, reason: 'il retry deve restare un no-op');
    expect(await outbox(), isEmpty);
  });

  test('il pull applica upsert e tombstone e fa avanzare il cursore', () async {
    gateway.changes = [
      const RemoteChange(
        changeId: 1,
        entityType: 'meals',
        entityId: _mealId,
        operation: 'upsert',
        payload: {
          'id': _mealId,
          'meal_type': 'lunch',
          'eaten_at': '2026-08-02T11:30:00+00:00',
          'created_at': '2026-08-02T11:30:00+00:00',
          'updated_at': '2026-08-02T11:30:00+00:00',
          'deleted_at': null,
        },
      ),
      const RemoteChange(
        changeId: 2,
        entityType: 'meal_items',
        entityId: _itemId,
        operation: 'upsert',
        payload: {
          'id': _itemId,
          'meal_id': _mealId,
          'food_name_snapshot': 'Riso basmati cotto',
          'quantity_g': 150.0,
          'energy_kcal_per_100g': 130.0,
          'protein_g_per_100g': 2.7,
          'carbohydrate_g_per_100g': 28.2,
          'fat_g_per_100g': 0.3,
          'food_source_snapshot': 'manual',
          'created_at': '2026-08-02T11:31:00+00:00',
          'updated_at': '2026-08-02T11:31:00+00:00',
          'deleted_at': null,
        },
      ),
      const RemoteChange(
        changeId: 3,
        entityType: 'meal_items',
        entityId: _itemId,
        operation: 'delete',
        payload: {
          'id': _itemId,
          'meal_id': _mealId,
          'food_name_snapshot': 'Riso basmati cotto',
          'quantity_g': 150.0,
          'energy_kcal_per_100g': 130.0,
          'protein_g_per_100g': 2.7,
          'carbohydrate_g_per_100g': 28.2,
          'fat_g_per_100g': 0.3,
          'updated_at': '2026-08-02T11:32:00+00:00',
          'deleted_at': '2026-08-02T11:32:00+00:00',
        },
      ),
    ];

    final report = await engine().sync();
    expect(report.pulled, 3);
    expect(report.error, isNull);

    final meal = await (database.select(
      database.meals,
    )..where((t) => t.id.equals(_mealId))).getSingle();
    expect(meal.mealType, 'lunch');
    expect(meal.profileId, profileId);

    final item = await (database.select(
      database.mealItems,
    )..where((t) => t.id.equals(_itemId))).getSingle();
    expect(item.foodName, 'Riso basmati cotto');
    // Totali sempre da NutritionCalculator.scale: 130 × 150 / 100.
    expect(item.totalCalories, closeTo(195, 0.001));
    expect(item.deletedAt, isNotNull);

    // Cursore persistito: un motore nuovo riparte da 3.
    expect((await store.read()).lastChangeId, 3);
    await engine().sync();
    expect(gateway.fetchCursors.last, 3);
  });

  test('il conflitto lo vince sempre l’updated_at più recente', () async {
    final id = await WellbeingRepository(database).addWeight(
      profileId: profileId,
      weightKg: 80,
      measuredAt: DateTime.utc(2026, 8, 1),
    );
    // Isola il pull: l'outbox non deve interferire.
    await database.delete(database.syncOutbox).go();

    gateway.changes = [
      RemoteChange(
        changeId: 1,
        entityType: 'body_measurements',
        entityId: id,
        operation: 'upsert',
        payload: {
          'id': id,
          'weight_kg': 75.0,
          'measured_at': '2026-07-01T00:00:00+00:00',
          'updated_at': '2020-01-01T00:00:00+00:00',
          'deleted_at': null,
        },
      ),
    ];
    await engine().sync();
    var row = await (database.select(
      database.bodyMeasurements,
    )..where((t) => t.id.equals(id))).getSingle();
    expect(row.weightKg, 80, reason: 'il remoto più vecchio non sovrascrive');

    gateway.changes = [
      RemoteChange(
        changeId: 2,
        entityType: 'body_measurements',
        entityId: id,
        operation: 'upsert',
        payload: {
          'id': id,
          'weight_kg': 75.0,
          'measured_at': '2026-07-01T00:00:00+00:00',
          'updated_at': '2030-01-01T00:00:00+00:00',
          'deleted_at': null,
        },
      ),
    ];
    await engine().sync();
    row = await (database.select(
      database.bodyMeasurements,
    )..where((t) => t.id.equals(id))).getSingle();
    expect(row.weightKg, 75, reason: 'il remoto più nuovo vince');
  });

  test('gli id locali non-uuid mantengono l’alias tra push e pull', () async {
    await database
        .into(database.syncOutbox)
        .insert(
          SyncOutboxCompanion.insert(
            id: '99999999-9999-4999-8999-999999999999',
            entityType: 'food',
            entityId: 'seed-oats',
            operation: 'upsert',
            payloadJson: jsonEncode({
              'id': 'seed-oats',
              'name': 'Fiocchi d’avena',
              'calories_per_100g': 389.0,
              'protein_per_100g': 16.9,
              'carbs_per_100g': 66.3,
              'fat_per_100g': 6.9,
              'default_serving_grams': 50.0,
              'updated_at': '2026-08-03T09:00:00+00:00',
            }),
            createdAt: now,
          ),
        );

    await engine().sync();
    final remoteId = SyncIds.remoteId('seed-oats');
    expect((await store.read()).remoteToLocalIds, {remoteId: 'seed-oats'});

    gateway.changes = [
      RemoteChange(
        changeId: 1,
        entityType: 'foods',
        entityId: remoteId,
        operation: 'upsert',
        payload: {
          'id': remoteId,
          'name': 'Avena bio',
          'energy_kcal_per_100g': 380.0,
          'protein_g_per_100g': 16.0,
          'carbohydrate_g_per_100g': 65.0,
          'fat_g_per_100g': 6.5,
          'serving_size_g': 40.0,
          'updated_at': '2030-01-01T00:00:00+00:00',
          'deleted_at': null,
        },
      ),
    ];
    await engine().sync();

    final food = await (database.select(
      database.foods,
    )..where((t) => t.id.equals('seed-oats'))).getSingle();
    expect(food.name, 'Avena bio', reason: 'il pull ritrova la riga seed');
    expect(food.defaultServingGrams, 40);
  });

  test(
    'senza account il motore segnala signedOut e non tocca la coda',
    () async {
      await WellbeingRepository(database).addWater(
        profileId: profileId,
        milliliters: 250,
        loggedAt: DateTime(2026, 8, 3, 8),
      );
      gateway.account = null;

      final report = await engine().sync();
      expect(report.signedOut, isTrue);
      expect(gateway.received, isEmpty);
      expect(await outbox(), hasLength(1));
    },
  );

  test('un tipo che il mapper non conosce non svuota la coda', () async {
    final mapping = MappingSyncGateway();
    gateway = mapping;
    await database
        .into(database.syncOutbox)
        .insert(
          SyncOutboxCompanion.insert(
            id: '90000000-0000-4000-8000-000000000001',
            entityType: 'entita_del_futuro',
            entityId: _workoutId,
            operation: 'upsert',
            payloadJson: jsonEncode({'id': _workoutId}),
            createdAt: now,
          ),
        );

    final report = await engine().sync();

    // Prima della correzione il mapper ritornava zero op, il push riusciva
    // e la riga spariva contata come inviata: perdita silenziosa.
    expect(report.pushed, 0);
    expect(report.error, isNotNull);
    expect(mapping.executed, isEmpty);
    final row = (await outbox()).single;
    expect(row.entityType, 'entita_del_futuro');
    expect(row.attemptCount, 1);
  });

  test('un allenamento accodato raggiunge davvero le tabelle remote', () async {
    final mapping = MappingSyncGateway();
    gateway = mapping;
    await database
        .into(database.syncOutbox)
        .insert(
          SyncOutboxCompanion.insert(
            id: '90000000-0000-4000-8000-000000000002',
            entityType: 'workout',
            entityId: _workoutId,
            operation: 'upsert',
            payloadJson: jsonEncode({
              'id': _workoutId,
              'profile_id': profileId,
              'started_at': '2026-08-04T20:34:30.000Z',
              'updated_at': '2026-08-05T10:00:00.000Z',
              'exercises': [
                {
                  'id': _rowId,
                  'position': 0,
                  'exercise_ref_id': 'cd-childpose',
                  'exercise_name_snapshot': 'Child pose',
                  'tracking_mode': 'timed',
                  'sets': [
                    {'id': _setId, 'position': 0, 'duration_sec': 40},
                  ],
                },
              ],
            }),
            createdAt: now,
          ),
        );

    final report = await engine().sync();

    expect(report.pushed, 1);
    expect(await outbox(), isEmpty);
    final tables = [
      for (final op in mapping.executed)
        switch (op) {
          RemoteUpsert() => op.table,
          RemotePatch() => op.table,
          RemoteChildrenSwap() => op.table,
        },
    ];
    expect(tables, contains('workouts'));
    expect(tables, contains('workout_exercises'));
    expect(tables, contains('workout_sets'));
  });

  test('la settimana composta a mano arriva al server, giorno tolto '
      'compreso', () async {
    final mapping = MappingSyncGateway();
    gateway = mapping;
    await database
        .into(database.routines)
        .insert(
          RoutinesCompanion.insert(
            id: _routineId,
            profileId: profileId,
            name: 'Giorno1 spalle petto tricipiti',
            createdAt: now,
            updatedAt: now,
          ),
        );
    final plan = WorkoutPlanRepository(database);

    // Martedì Giorno1, poi ci si ripensa e il martedì torna riposo.
    await plan.setDay(profileId: profileId, weekday: 2, routineId: _routineId);
    await plan.clearDay(profileId: profileId, weekday: 2);

    final report = await engine().sync();

    expect(report.pushed, 2);
    expect(await outbox(), isEmpty);
    final swaps = mapping.executed.whereType<RemoteChildrenSwap>().toList();
    expect(swaps, hasLength(2));
    expect(swaps.every((swap) => swap.table == 'routine_weekly_plan'), isTrue);
    expect(swaps.first.rows.single['weekday'], 2);
    expect(swaps.first.rows.single['routine_id'], _routineId);
    // Il ripensamento non manda un tombstone per il martedì: manda una
    // settimana senza martedì, e lo swap se ne accorge da solo. Se mandasse
    // una lista vuota di senso opposto — cioè «non parlo dei giorni» — la
    // riga resterebbe viva sul server e il tablet la rivedrebbe al pull.
    expect(swaps.last.rows, isEmpty);
    expect(swaps.last.tombstoneTargets(['una-riga-viva']), ['una-riga-viva']);
  });

  test('un 23503 non scarta la mutation: resta in coda col backoff', () async {
    await database
        .into(database.syncOutbox)
        .insert(
          SyncOutboxCompanion.insert(
            id: '90000000-0000-4000-8000-000000000003',
            entityType: 'workout',
            entityId: _workoutId,
            operation: 'upsert',
            payloadJson: jsonEncode({
              'id': _workoutId,
              'profile_id': profileId,
              'started_at': '2026-08-04T20:34:30.000Z',
            }),
            createdAt: now,
          ),
        );
    // L'esercizio citato non è ancora arrivato sul server: la FK risponde
    // 23503. Scartare la riga farebbe sparire l'intero allenamento.
    gateway.failBeforeApply = (_) => SyncGatewayException(
      'Il server non ha ancora tutti i dati collegati (codice 23503).',
      retryable: SyncRetryPolicy.isRetryable('23503'),
    );

    final report = await engine().sync();

    expect(report.pushed, 0);
    expect(report.error, isNot(contains('scartat')));
    final row = (await outbox()).single;
    expect(row.entityId, _workoutId);
    expect(row.attemptCount, 1);
    expect(row.nextAttemptAt, isNotNull);
  });

  test('il pull ricostruisce una sessione con esercizi e serie', () async {
    final exerciseRemoteId = SyncIds.remoteId('cd-childpose');
    // L'alias slug -> uuid nasce dal push dell'esercizio: senza, il pull non
    // saprebbe che `cd-childpose` e quell'uuid sono la stessa riga.
    await database
        .into(database.syncOutbox)
        .insert(
          SyncOutboxCompanion.insert(
            id: '90000000-0000-4000-8000-000000000004',
            entityType: 'exercise',
            entityId: 'cd-childpose',
            operation: 'upsert',
            payloadJson: jsonEncode({
              'id': 'cd-childpose',
              'profile_id': profileId,
              'name': 'Child pose',
              'muscle_group': 'mobilita',
              'tracking_mode': 'timed',
              'source': 'cooldown_preset',
              'external_id': 'cd-childpose',
              'updated_at': '2026-08-05T10:00:00.000Z',
            }),
            createdAt: now,
          ),
        );
    await engine().sync();
    expect(
      (await store.read()).remoteToLocalIds[exerciseRemoteId],
      'cd-childpose',
    );

    gateway.changes = [
      RemoteChange(
        changeId: 1,
        entityType: 'exercises',
        entityId: exerciseRemoteId,
        operation: 'upsert',
        payload: {
          'id': exerciseRemoteId,
          'name': 'Child pose',
          'muscle_group': 'mobilita',
          'tracking_mode': 'timed',
          'is_synthetic': true,
          'source': 'cooldown_preset',
          'external_id': 'cd-childpose',
          'updated_at': '2030-01-01T00:00:00+00:00',
          'deleted_at': null,
        },
      ),
      const RemoteChange(
        changeId: 2,
        entityType: 'workouts',
        entityId: _workoutId,
        operation: 'upsert',
        payload: {
          'id': _workoutId,
          'started_at': '2026-08-04T20:34:30+00:00',
          'ended_at': '2026-08-04T21:10:00+00:00',
          'total_kcal': 477.7840476190476,
          'duration_suspect': false,
          // La scheda non esiste più: la FK resta vuota, id e nome no.
          'routine_id': null,
          'routine_external_id': _routineId,
          'routine_name_snapshot': 'Esercizi  2',
          'source': 'gym_tracker',
          'external_id': _workoutId,
          'updated_at': '2026-08-05T10:00:00+00:00',
          'deleted_at': null,
        },
      ),
      RemoteChange(
        changeId: 3,
        entityType: 'workout_exercises',
        entityId: _rowId,
        operation: 'upsert',
        payload: {
          'id': _rowId,
          'workout_id': _workoutId,
          'position': 0,
          'exercise_ref_id': exerciseRemoteId,
          'exercise_id': exerciseRemoteId,
          'exercise_name_snapshot': 'Child pose',
          'tracking_mode': 'timed',
          'muscle_group_snapshot': 'mobilita',
          'is_cooldown': true,
          'deleted_at': null,
        },
      ),
      const RemoteChange(
        changeId: 4,
        entityType: 'workout_sets',
        entityId: _setId,
        operation: 'upsert',
        payload: {
          'id': _setId,
          'workout_id': _workoutId,
          'workout_exercise_id': _rowId,
          'position': 0,
          'duration_sec': 40,
          'completed': true,
          'deleted_at': null,
        },
      ),
    ];

    final report = await engine().sync();
    expect(report.pulled, 4);
    expect(report.error, isNull);

    final workout = await (database.select(
      database.workouts,
    )..where((t) => t.id.equals(_workoutId))).getSingle();
    expect(workout.profileId, profileId);
    expect(workout.routineId, isNull);
    expect(workout.routineExternalId, _routineId);
    expect(workout.routineNameSnapshot, 'Esercizi  2');
    expect(workout.totalKcal, 477.7840476190476);

    final row = await (database.select(
      database.workoutExercises,
    )..where((t) => t.id.equals(_rowId))).getSingle();
    // L'alias riporta lo slug: senza, exercise_ref_id resterebbe un uuid che
    // qui non corrisponde a nessun esercizio e i record personali si
    // spezzerebbero in due gruppi.
    expect(row.exerciseRefId, 'cd-childpose');
    expect(row.exerciseId, 'cd-childpose');
    expect(row.isCooldown, isTrue);

    final set = await (database.select(
      database.workoutSets,
    )..where((t) => t.id.equals(_setId))).getSingle();
    expect(set.workoutExerciseId, _rowId);
    expect(set.durationSec, 40);
    expect(set.weightKg, isNull, reason: '«non inserito» non è zero');
  });

  test(
    'una riga figlia senza padre locale si salta invece di esplodere',
    () async {
      gateway.changes = [
        const RemoteChange(
          changeId: 1,
          entityType: 'workout_sets',
          entityId: _setId,
          operation: 'upsert',
          payload: {
            'id': _setId,
            'workout_id': _workoutId,
            'workout_exercise_id': _rowId,
            'position': 0,
            'reps': 10,
            'deleted_at': null,
          },
        ),
      ];

      final report = await engine().sync();
      expect(report.pulled, 0);
      expect(report.skipped, 1);
      expect(report.error, isNull, reason: 'non è un errore locale');
      expect(await database.select(database.workoutSets).get(), isEmpty);
    },
  );

  test('last_workout_day torna dal server come giorno di Roma', () async {
    gateway.changes = [
      RemoteChange(
        changeId: 1,
        entityType: 'workout_profile_stats',
        entityId: _exerciseId,
        operation: 'upsert',
        payload: {
          'id': _exerciseId,
          'total_xp': 11370,
          'current_streak': 2,
          'longest_streak': 2,
          // Colonna remota `date`: arriva senza fuso.
          'last_workout_day': '2026-08-04',
          'weekly_workout_goal': 4,
          'reminder_enabled': true,
          'health_connect_enabled': true,
          'gym_body_weight_kg': 94.7,
          'updated_at': '2026-08-05T10:00:00+00:00',
          'deleted_at': null,
        },
      ),
    ];

    final report = await engine().sync();
    expect(report.pulled, 1);

    final stats = await (database.select(
      database.workoutProfileStats,
    )..where((t) => t.profileId.equals(profileId))).getSingle();
    expect(stats.totalXp, 11370);
    expect(stats.gymBodyWeightKg, 94.7);
    // Mezzanotte di Roma, non mezzanotte UTC: leggerla come UTC farebbe
    // arretrare il giorno di due ore e spezzerebbe lo streak.
    expect(stats.lastWorkoutDay!.toUtc(), DateTime.utc(2026, 8, 3, 22));
  });

  test('il pull ricostruisce Renpho, profilo atleta, salute e feed', () async {
    gateway.changes = const [
      RemoteChange(
        changeId: 1,
        entityType: 'body_measurements',
        entityId: _itemId,
        operation: 'upsert',
        payload: {
          'id': _itemId,
          'weight_kg': 82.4,
          'measured_at': '2026-08-08T06:30:00.000Z',
          'has_impedance': true,
          'impedance_ohm': 512.5,
          'body_fat_pct': 22.1,
          'water_pct': 55.8,
          'source': 'renpho_ble',
          'external_id': 'renpho-reading-1',
          'device_model': 'RENPHO 8 electrodes',
          'raw_payload': 'a1b2c3',
          'updated_at': '2026-08-08T06:31:00.000Z',
        },
      ),
      RemoteChange(
        changeId: 2,
        entityType: 'body_impedance_readings',
        entityId: _rowId,
        operation: 'upsert',
        payload: {
          'id': _rowId,
          'measurement_id': _itemId,
          'segment': 'whole',
          'frequency_hz': 50000,
          'ohm': 512.5,
        },
      ),
      RemoteChange(
        changeId: 3,
        entityType: 'daily_check_ins',
        entityId: _setId,
        operation: 'upsert',
        payload: {
          'id': _setId,
          'day': '2026-08-08',
          'sleep_hours': 7.5,
          'energy_score': 4,
          'steps': 9000,
          'updated_at': '2026-08-08T07:00:00.000Z',
        },
      ),
      RemoteChange(
        changeId: 4,
        entityType: 'goals',
        entityId: _exerciseId,
        operation: 'upsert',
        payload: {
          'id': _exerciseId,
          'target_weight_kg': 78.0,
          'target_level': 'defined',
          'pace_kg_per_week': 0.4,
          'started_at': '2026-08-08T06:00:00.000Z',
          'start_weight_kg': 82.4,
          'start_fat_free_mass_kg': 64.2,
          'phase': 'approach',
          'updated_at': '2026-08-08T07:00:00.000Z',
        },
      ),
      RemoteChange(
        changeId: 5,
        entityType: 'training_profiles',
        entityId: _routineId,
        operation: 'upsert',
        payload: {
          'equipment': 'manubri,panca',
          'sessions_per_week': 4,
          'minutes_per_session': 60,
          'preferred_days': 'lun,mar,gio,sab',
          'deload_preference': 'suggerito',
          'updated_at': '2026-08-08T07:00:00.000Z',
        },
      ),
      RemoteChange(
        changeId: 6,
        entityType: 'training_limitations',
        entityId: _workoutId,
        operation: 'upsert',
        payload: {
          'id': _workoutId,
          'body_part': 'spalla_dx',
          'severity': 'fastidio',
          'started_at': '2026-08-08T06:00:00.000Z',
          'updated_at': '2026-08-08T07:00:00.000Z',
        },
      ),
      RemoteChange(
        changeId: 7,
        entityType: 'daily_health_summaries',
        entityId: _mealId,
        operation: 'upsert',
        payload: {
          'id': _mealId,
          'day': '2026-08-08',
          'source': 'health_connect',
          'steps': 9100,
          'sleep_minutes': 450,
          'resting_heart_rate': 54,
          'updated_at': '2026-08-08T07:00:00.000Z',
        },
      ),
      RemoteChange(
        changeId: 8,
        entityType: 'coach_feed_items',
        entityId: _mealId,
        operation: 'upsert',
        payload: {
          'id': _mealId,
          'kind': 'weekly_review',
          'source': 'deterministic',
          'title': 'Rapporto',
          'body': 'Settimana completata.',
          'occurred_at': '2026-08-08T07:00:00.000Z',
          'updated_at': '2026-08-08T07:00:00.000Z',
        },
      ),
    ];

    final report = await engine().sync();

    expect(report.pulled, 8);
    expect(report.error, isNull);
    final measurement = await database
        .select(database.bodyMeasurements)
        .getSingle();
    expect(measurement.bodyFatPct, 22.1);
    expect(measurement.deviceModel, 'RENPHO 8 electrodes');
    expect(
      (await database.select(database.bodyImpedanceReadings).getSingle()).ohm,
      512.5,
    );
    expect(
      (await database.select(database.dailyCheckIns).getSingle()).steps,
      9000,
    );
    expect(
      (await database.select(database.goals).getSingle()).targetWeightKg,
      78,
    );
    expect(
      (await database.select(database.trainingProfiles).getSingle())
          .sessionsPerWeek,
      4,
    );
    expect(
      (await database.select(database.trainingLimitations).getSingle())
          .bodyPart,
      'spalla_dx',
    );
    expect(
      (await database.select(database.dailyHealthSummaries).getSingle())
          .sleepMinutes,
      450,
    );
    expect(
      (await database.select(database.coachFeedItems).getSingle()).title,
      'Rapporto',
    );
  });

  test('senza configurazione il motore resta spento: zero chiamate', () async {
    final container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(const AppConfig.offline()),
        databaseProvider.overrideWithValue(database),
        syncGatewayProvider.overrideWithValue(gateway),
        syncStateStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);

    final controller = container.read(syncControllerProvider.notifier);
    await controller.syncNow();

    expect(container.read(syncControllerProvider).phase, SyncPhase.disabled);
    expect(gateway.received, isEmpty);
    expect(gateway.fetchCursors, isEmpty);
  });
}
