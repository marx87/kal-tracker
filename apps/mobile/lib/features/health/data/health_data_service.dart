import 'package:kal_tracker/features/health/data/daily_health_summary_repository.dart';
import 'package:kal_tracker/features/health/domain/health_data_gateway.dart';

enum HealthImportState { imported, noData, permissionRequired, unavailable }

class HealthImportResult {
  const HealthImportResult(this.state, {this.imported = 0, this.status});

  final HealthImportState state;
  final int imported;
  final HealthGatewayStatus? status;
}

/// Coordina gateway e persistenza senza conoscere plugin o schermate.
///
/// I permessi non vengono mai richiesti in background: [importDailySummaries]
/// legge solo capacita' gia' concesse. La UI puo' chiamare esplicitamente
/// [requestAuthorization] dopo aver spiegato cosa verra' letto o scritto.
class HealthDataService {
  HealthDataService(this._gateway, this._repository);

  final HealthDataGateway _gateway;
  final DailyHealthSummaryRepository _repository;

  Future<HealthGatewayStatus> status() => _gateway.status();

  Future<HealthGatewayStatus> requestAuthorization(
    Set<HealthCapability> capabilities,
  ) => _gateway.requestAuthorization(capabilities);

  Future<HealthImportResult> importDailySummaries({
    required String profileId,
    required DateTime fromDay,
    required DateTime throughDay,
  }) async {
    final status = await _gateway.status();
    const reads = {
      HealthCapability.readSteps,
      HealthCapability.readSleep,
      HealthCapability.readRestingHeartRate,
    };
    final supported = reads.intersection(status.capabilities);
    if (supported.isEmpty) {
      return HealthImportResult(HealthImportState.unavailable, status: status);
    }
    if (supported.any((capability) => !status.isGranted(capability))) {
      return HealthImportResult(
        HealthImportState.permissionRequired,
        status: status,
      );
    }
    final summaries = await _gateway.readDailySummaries(
      fromDay: fromDay,
      throughDay: throughDay,
    );
    final accepted = [
      for (final summary in summaries)
        HealthDailySummary(
          day: summary.day,
          source: summary.source,
          externalId: summary.externalId,
          steps: supported.contains(HealthCapability.readSteps)
              ? summary.steps
              : null,
          sleepMinutes: supported.contains(HealthCapability.readSleep)
              ? summary.sleepMinutes
              : null,
          restingHeartRate:
              supported.contains(HealthCapability.readRestingHeartRate)
              ? summary.restingHeartRate
              : null,
        ),
    ];
    final imported = await _repository.saveAll(
      profileId: profileId,
      summaries: accepted,
    );
    return HealthImportResult(
      imported == 0 ? HealthImportState.noData : HealthImportState.imported,
      imported: imported,
      status: status,
    );
  }

  Future<HealthWorkoutWriteResult> writeWorkout(
    HealthWorkoutRecord workout,
  ) async {
    final status = await _gateway.status();
    if (!status.supports(HealthCapability.writeWorkout)) {
      return const HealthWorkoutWriteResult(
        HealthWorkoutWriteState.unsupported,
      );
    }
    if (!status.isGranted(HealthCapability.writeWorkout)) {
      return const HealthWorkoutWriteResult(
        HealthWorkoutWriteState.permissionRequired,
      );
    }
    return _gateway.writeWorkout(workout);
  }
}
