import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/health/data/daily_health_summary_repository.dart';
import 'package:kal_tracker/features/health/data/health_data_service.dart';
import 'package:kal_tracker/features/health/domain/health_data_gateway.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

class _Gateway implements HealthDataGateway {
  _Gateway(this.currentStatus, {this.summaries = const []});

  HealthGatewayStatus currentStatus;
  List<HealthDailySummary> summaries;
  int reads = 0;
  int writes = 0;

  @override
  Future<HealthGatewayStatus> status() async => currentStatus;

  @override
  Future<HealthGatewayStatus> requestAuthorization(
    Set<HealthCapability> capabilities,
  ) async => currentStatus;

  @override
  Future<List<HealthDailySummary>> readDailySummaries({
    required DateTime fromDay,
    required DateTime throughDay,
  }) async {
    reads++;
    return summaries;
  }

  @override
  Future<HealthWorkoutWriteResult> writeWorkout(
    HealthWorkoutRecord workout,
  ) async {
    writes++;
    return const HealthWorkoutWriteResult(HealthWorkoutWriteState.written);
  }
}

void main() {
  late AppDatabase database;
  late String profileId;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
  });

  tearDown(() => database.close());

  test('importa solo dopo consenso e salva il riepilogo con outbox', () async {
    final gateway = _Gateway(
      const HealthGatewayStatus(
        source: 'health_connect',
        capabilities: {HealthCapability.readSteps, HealthCapability.readSleep},
        permissions: {
          HealthCapability.readSteps: HealthPermissionState.granted,
          HealthCapability.readSleep: HealthPermissionState.granted,
        },
      ),
      summaries: [
        HealthDailySummary(
          day: DateTime.utc(2026, 8, 8),
          source: 'health_connect',
          steps: 10000,
          sleepMinutes: 455,
          restingHeartRate: 52,
        ),
      ],
    );
    final service = HealthDataService(
      gateway,
      DailyHealthSummaryRepository(database),
    );

    final result = await service.importDailySummaries(
      profileId: profileId,
      fromDay: DateTime.utc(2026, 8, 8),
      throughDay: DateTime.utc(2026, 8, 8),
    );

    expect(result.state, HealthImportState.imported);
    expect(gateway.reads, 1);
    final row = await database
        .select(database.dailyHealthSummaries)
        .getSingle();
    expect(row.steps, 10000);
    expect(row.sleepMinutes, 455);
    expect(row.restingHeartRate, isNull, reason: 'capacita non dichiarata');
    expect(
      (await database.select(database.syncOutbox).getSingle()).entityType,
      'daily_health_summary',
    );
  });

  test('non legge e non scrive quando manca il permesso', () async {
    final gateway = _Gateway(
      const HealthGatewayStatus(
        source: 'health_connect',
        capabilities: {
          HealthCapability.readSteps,
          HealthCapability.writeWorkout,
        },
        permissions: {
          HealthCapability.readSteps: HealthPermissionState.denied,
          HealthCapability.writeWorkout: HealthPermissionState.notRequested,
        },
      ),
    );
    final service = HealthDataService(
      gateway,
      DailyHealthSummaryRepository(database),
    );

    final import = await service.importDailySummaries(
      profileId: profileId,
      fromDay: DateTime.utc(2026, 8, 8),
      throughDay: DateTime.utc(2026, 8, 8),
    );
    final write = await service.writeWorkout(
      HealthWorkoutRecord(
        id: 'workout-1',
        title: 'Palestra',
        startedAt: DateTime.utc(2026, 8, 8, 7),
        endedAt: DateTime.utc(2026, 8, 8, 8),
      ),
    );

    expect(import.state, HealthImportState.permissionRequired);
    expect(write.state, HealthWorkoutWriteState.permissionRequired);
    expect(gateway.reads, 0);
    expect(gateway.writes, 0);
  });
}
