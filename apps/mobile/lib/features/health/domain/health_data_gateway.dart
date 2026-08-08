import 'package:flutter/foundation.dart';

/// Capacita' dichiarate da una sorgente salute concreta.
///
/// Dichiararle a runtime evita di mostrare permessi o pulsanti che il telefono,
/// l'account o l'adapter installato non possono davvero soddisfare.
enum HealthCapability {
  readSteps,
  readSleep,
  readRestingHeartRate,
  writeWorkout,
}

enum HealthPermissionState {
  unavailable,
  notRequested,
  denied,
  granted,
  restricted,
}

@immutable
class HealthGatewayStatus {
  const HealthGatewayStatus({
    required this.source,
    required this.capabilities,
    required this.permissions,
    this.detail,
  });

  const HealthGatewayStatus.unavailable({
    this.source = 'unavailable',
    this.detail,
  }) : capabilities = const {},
       permissions = const {};

  final String source;
  final Set<HealthCapability> capabilities;
  final Map<HealthCapability, HealthPermissionState> permissions;
  final String? detail;

  bool supports(HealthCapability capability) =>
      capabilities.contains(capability);

  bool isGranted(HealthCapability capability) =>
      supports(capability) &&
      permissions[capability] == HealthPermissionState.granted;
}

@immutable
class HealthDailySummary {
  const HealthDailySummary({
    required this.day,
    required this.source,
    this.externalId,
    this.steps,
    this.sleepMinutes,
    this.restingHeartRate,
  });

  final DateTime day;
  final String source;
  final String? externalId;
  final int? steps;
  final int? sleepMinutes;
  final int? restingHeartRate;

  bool get isEmpty =>
      steps == null && sleepMinutes == null && restingHeartRate == null;
}

@immutable
class HealthWorkoutRecord {
  const HealthWorkoutRecord({
    required this.id,
    required this.title,
    required this.startedAt,
    required this.endedAt,
    this.totalKcal,
  });

  final String id;
  final String title;
  final DateTime startedAt;
  final DateTime endedAt;
  final double? totalKcal;
}

enum HealthWorkoutWriteState {
  written,
  alreadyPresent,
  permissionRequired,
  unsupported,
  failed,
}

@immutable
class HealthWorkoutWriteResult {
  const HealthWorkoutWriteResult(this.state, {this.externalId, this.detail});

  final HealthWorkoutWriteState state;
  final String? externalId;
  final String? detail;
}

/// Porta verso Health Connect, HealthKit o un'altra sorgente esplicitamente
/// configurata.
///
/// L'interfaccia non presume che un produttore specifico sia disponibile: lo
/// stato dipende dall'adapter, dai permessi concessi, dall'account e dal
/// dispositivo reale. Un'implementazione deve deduplicare [writeWorkout] con
/// [HealthWorkoutRecord.id] e restituire un esito incerto/failed senza
/// dichiarare riuscita una scrittura che non puo' verificare.
abstract interface class HealthDataGateway {
  Future<HealthGatewayStatus> status();

  Future<HealthGatewayStatus> requestAuthorization(
    Set<HealthCapability> capabilities,
  );

  Future<List<HealthDailySummary>> readDailySummaries({
    required DateTime fromDay,
    required DateTime throughDay,
  });

  Future<HealthWorkoutWriteResult> writeWorkout(HealthWorkoutRecord workout);
}

/// Default onesto finche' non viene installato e configurato un adapter di
/// piattaforma. Non simula dati e non dichiara permessi concessi.
class UnavailableHealthDataGateway implements HealthDataGateway {
  const UnavailableHealthDataGateway({this.detail});

  final String? detail;

  @override
  Future<HealthGatewayStatus> status() async =>
      HealthGatewayStatus.unavailable(detail: detail);

  @override
  Future<HealthGatewayStatus> requestAuthorization(
    Set<HealthCapability> capabilities,
  ) => status();

  @override
  Future<List<HealthDailySummary>> readDailySummaries({
    required DateTime fromDay,
    required DateTime throughDay,
  }) async => const [];

  @override
  Future<HealthWorkoutWriteResult> writeWorkout(
    HealthWorkoutRecord workout,
  ) async => HealthWorkoutWriteResult(
    HealthWorkoutWriteState.unsupported,
    detail: detail,
  );
}
