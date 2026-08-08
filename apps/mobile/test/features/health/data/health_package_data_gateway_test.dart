import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/health/data/health_package_data_gateway.dart';
import 'package:kal_tracker/features/health/data/health_plugin_facade.dart';
import 'package:kal_tracker/features/health/domain/health_data_gateway.dart';

typedef _ReadCallback =
    Future<List<HealthPluginDataPoint>> Function(
      Set<HealthPluginDataType> types,
      DateTime from,
      DateTime to,
    );

class _FakeHealthPlugin implements HealthPluginFacade {
  _FakeHealthPlugin({
    this.platform = HealthPluginPlatform.androidHealthConnect,
    this.currentAvailability = HealthPluginAvailability.available,
    Set<HealthPluginDataType>? supported,
  }) : supported = supported ?? HealthPluginDataType.values.toSet();

  @override
  final HealthPluginPlatform platform;
  HealthPluginAvailability currentAvailability;
  final Set<HealthPluginDataType> supported;
  bool? permissionResult = true;
  bool authorizationResult = true;
  HealthPluginRuntimePermission runtimePermission =
      HealthPluginRuntimePermission.granted;
  bool workoutWriteResult = true;
  bool configured = false;
  int workoutWrites = 0;
  final List<List<HealthPluginPermission>> permissionChecks = [];
  final List<List<HealthPluginPermission>> authorizationRequests = [];
  final List<({Set<HealthPluginDataType> types, DateTime from, DateTime to})>
  reads = [];
  final Map<DateTime, int?> stepsByStart = {};
  _ReadCallback? onRead;

  @override
  Future<void> configure() async {
    configured = true;
  }

  @override
  Future<HealthPluginAvailability> availability() async => currentAvailability;

  @override
  bool supports(HealthPluginDataType type) => supported.contains(type);

  @override
  Future<bool?> hasPermissions(List<HealthPluginPermission> permissions) async {
    permissionChecks.add(List.of(permissions));
    return permissionResult;
  }

  @override
  Future<bool> requestAuthorization(
    List<HealthPluginPermission> permissions,
  ) async {
    authorizationRequests.add(List.of(permissions));
    return authorizationResult;
  }

  @override
  Future<HealthPluginRuntimePermission> activityRecognitionPermission() async =>
      runtimePermission;

  @override
  Future<HealthPluginRuntimePermission> requestActivityRecognition() async =>
      runtimePermission;

  @override
  Future<List<HealthPluginDataPoint>> read({
    required Set<HealthPluginDataType> types,
    required DateTime from,
    required DateTime to,
  }) async {
    reads.add((types: types, from: from, to: to));
    return onRead?.call(types, from, to) ?? const [];
  }

  @override
  Future<int?> readTotalSteps({
    required DateTime from,
    required DateTime to,
  }) async => stepsByStart[from];

  @override
  Future<bool> writeStrengthWorkout(HealthPluginWorkout workout) async {
    workoutWrites++;
    return workoutWriteResult;
  }
}

void main() {
  setUpAll(AppTime.initialize);

  group('stato e permessi', () {
    test(
      'degrada onestamente quando Health Connect non e disponibile',
      () async {
        final plugin = _FakeHealthPlugin(
          currentAvailability: HealthPluginAvailability.unavailable,
        );
        final gateway = _gateway(plugin);

        final status = await gateway.status();

        expect(status.source, 'health_connect');
        expect(status.capabilities, isEmpty);
        expect(status.detail, contains('Huawei'));
        expect(status.detail, contains('non legge il cloud Huawei'));
      },
    );

    test('distingue non richiesto e negato su Health Connect', () async {
      final plugin = _FakeHealthPlugin(
        supported: const {HealthPluginDataType.steps},
      )..permissionResult = false;
      final gateway = _gateway(plugin);

      expect(
        (await gateway.status()).permissions[HealthCapability.readSteps],
        HealthPermissionState.notRequested,
      );
      plugin.authorizationResult = false;

      final after = await gateway.requestAuthorization(const {
        HealthCapability.readSteps,
      });

      expect(
        after.permissions[HealthCapability.readSteps],
        HealthPermissionState.denied,
      );
      expect(plugin.authorizationRequests, hasLength(1));
    });

    test('non ignora Activity Recognition per i passi Android', () async {
      final plugin = _FakeHealthPlugin(
        supported: const {HealthPluginDataType.steps},
      )..runtimePermission = HealthPluginRuntimePermission.denied;
      final gateway = _gateway(plugin);

      expect(
        (await gateway.status()).permissions[HealthCapability.readSteps],
        HealthPermissionState.notRequested,
      );

      final after = await gateway.requestAuthorization(const {
        HealthCapability.readSteps,
      });

      expect(
        after.permissions[HealthCapability.readSteps],
        HealthPermissionState.denied,
      );
    });

    test('su iOS non finge di poter conoscere un permesso READ', () async {
      final plugin = _FakeHealthPlugin(
        platform: HealthPluginPlatform.iosHealthKit,
        supported: const {HealthPluginDataType.steps},
      )..permissionResult = null;
      final gateway = _gateway(plugin);

      expect(
        (await gateway.status()).permissions[HealthCapability.readSteps],
        HealthPermissionState.notRequested,
      );

      final after = await gateway.requestAuthorization(const {
        HealthCapability.readSteps,
      });

      expect(
        after.permissions[HealthCapability.readSteps],
        HealthPermissionState.granted,
      );
      expect(after.detail, contains('non rivela'));
    });

    test(
      'il workout Android richiede anche i dati usati per verificarlo',
      () async {
        final plugin = _FakeHealthPlugin()..permissionResult = false;
        final gateway = _gateway(plugin);

        await gateway.requestAuthorization(const {
          HealthCapability.writeWorkout,
        });

        final request = plugin.authorizationRequests.single.toSet();
        expect(
          request,
          containsAll({
            const HealthPluginPermission(
              HealthPluginDataType.workout,
              HealthPluginAccess.readWrite,
            ),
            const HealthPluginPermission(
              HealthPluginDataType.steps,
              HealthPluginAccess.read,
            ),
            const HealthPluginPermission(
              HealthPluginDataType.distance,
              HealthPluginAccess.read,
            ),
            const HealthPluginPermission(
              HealthPluginDataType.totalCaloriesBurned,
              HealthPluginAccess.readWrite,
            ),
          }),
        );
      },
    );
  });

  test(
    'unisce gli intervalli sonno e usa la FC a riposo piu recente',
    () async {
      final plugin = _FakeHealthPlugin();
      final day = DateTime.utc(2026, 8, 8);
      plugin.stepsByStart[AppTime.startOfDayUtc(day)] = 9321;
      final points = [
        _point(
          id: 'sleep-whole',
          type: HealthPluginDataType.sleepAsleep,
          from: DateTime.utc(2026, 8, 7, 21),
          to: DateTime.utc(2026, 8, 8, 4),
        ),
        _point(
          id: 'sleep-deep-overlap',
          type: HealthPluginDataType.sleepDeep,
          from: DateTime.utc(2026, 8, 7, 22),
          to: DateTime.utc(2026, 8, 7, 23),
        ),
        _point(
          id: 'rhr-old',
          type: HealthPluginDataType.restingHeartRate,
          from: DateTime.utc(2026, 8, 8, 5),
          to: DateTime.utc(2026, 8, 8, 5),
          numericValue: 52,
        ),
        _point(
          id: 'rhr-latest',
          type: HealthPluginDataType.restingHeartRate,
          from: DateTime.utc(2026, 8, 8, 10),
          to: DateTime.utc(2026, 8, 8, 10),
          numericValue: 55,
        ),
      ];
      plugin.onRead = (types, from, to) async => [
        for (final point in points)
          if (types.contains(point.type)) point,
      ];
      final gateway = _gateway(plugin);

      final summaries = await gateway.readDailySummaries(
        fromDay: day,
        throughDay: day,
      );

      expect(summaries, hasLength(1));
      expect(summaries.single.day, day);
      expect(summaries.single.steps, 9321);
      expect(summaries.single.sleepMinutes, 420);
      expect(summaries.single.restingHeartRate, 55);
      expect(summaries.single.externalId, 'health_connect:2026-08-08');
    },
  );

  group('workout idempotente', () {
    test('verifica pre/post e non scrive una seconda copia', () async {
      final plugin = _FakeHealthPlugin();
      final workout = _workout();
      final writtenPoint = _workoutPoint(workout);
      plugin.onRead = (types, from, to) async =>
          plugin.workoutWrites == 0 ? const [] : [writtenPoint];
      final store = InMemoryHealthAdapterStateStore();
      final gateway = HealthPackageDataGateway(
        facade: plugin,
        stateStore: store,
      );

      final first = await gateway.writeWorkout(workout);
      final second = await gateway.writeWorkout(workout);

      expect(first.state, HealthWorkoutWriteState.written);
      expect(first.externalId, 'native-workout-1');
      expect(second.state, HealthWorkoutWriteState.alreadyPresent);
      expect(second.externalId, 'native-workout-1');
      expect(plugin.workoutWrites, 1);
      expect(
        (await store.workoutReceipt(workout.id))?.externalId,
        'native-workout-1',
      );
    });

    test(
      'blocca il retry se la piattaforma accetta ma non rende verificabile',
      () async {
        final plugin = _FakeHealthPlugin()
          ..onRead = (_, _, _) async => const [];
        final gateway = _gateway(plugin);
        final workout = _workout();

        final first = await gateway.writeWorkout(workout);
        final retry = await gateway.writeWorkout(workout);

        expect(first.state, HealthWorkoutWriteState.failed);
        expect(first.detail, contains('retry automatico'));
        expect(retry.state, HealthWorkoutWriteState.failed);
        expect(plugin.workoutWrites, 1);
      },
    );
  });

  test('lo store file conserva permessi e ricevute tra istanze', () async {
    final directory = await Directory.systemTemp.createTemp('coach360-health-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/state.json');
    final first = FileHealthAdapterStateStore(file);
    await first.saveAuthorizationOutcome(HealthCapability.readSleep, true);
    await first.saveWorkoutReceipt(
      'workout-1',
      const HealthWorkoutReceipt(
        fingerprint: 'fingerprint',
        externalId: 'native-id',
      ),
    );

    final restored = FileHealthAdapterStateStore(file);

    expect(
      await restored.authorizationOutcome(HealthCapability.readSleep),
      isTrue,
    );
    expect(
      (await restored.workoutReceipt('workout-1'))?.externalId,
      'native-id',
    );
  });
}

HealthPackageDataGateway _gateway(_FakeHealthPlugin plugin) =>
    HealthPackageDataGateway(
      facade: plugin,
      stateStore: InMemoryHealthAdapterStateStore(),
    );

HealthWorkoutRecord _workout() => HealthWorkoutRecord(
  id: 'workout-1',
  title: 'Forza A',
  startedAt: DateTime.utc(2026, 8, 8, 16),
  endedAt: DateTime.utc(2026, 8, 8, 17),
  totalKcal: 420,
);

HealthPluginDataPoint _workoutPoint(HealthWorkoutRecord workout) =>
    HealthPluginDataPoint(
      id: 'native-workout-1',
      type: HealthPluginDataType.workout,
      from: workout.startedAt,
      to: workout.endedAt,
      sourceId: 'coach360',
      sourceName: 'Coach360',
      workoutActivityType: 'STRENGTH_TRAINING',
      workoutEnergyKcal: workout.totalKcal?.round(),
    );

HealthPluginDataPoint _point({
  required String id,
  required HealthPluginDataType type,
  required DateTime from,
  required DateTime to,
  num? numericValue,
}) => HealthPluginDataPoint(
  id: id,
  type: type,
  from: from,
  to: to,
  sourceId: 'source-id',
  sourceName: 'source-name',
  numericValue: numericValue,
);
