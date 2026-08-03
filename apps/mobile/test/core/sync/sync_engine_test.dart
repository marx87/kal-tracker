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

const _mealId = '33333333-3333-4333-8333-333333333333';
const _itemId = '22222222-2222-4222-8222-222222222222';

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
      gateway.failBeforeApply = (mutation) => mutation.entityId == poisoned
          ? const SyncGatewayException(
              'Il server ha rifiutato la modifica (codice 23505).',
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
