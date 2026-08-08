import 'dart:io';

import 'package:health/health.dart';
import 'package:permission_handler/permission_handler.dart';

/// Piattaforme realmente coperte dal package `health`.
enum HealthPluginPlatform { androidHealthConnect, iosHealthKit, unsupported }

enum HealthPluginAvailability { available, providerUpdateRequired, unavailable }

enum HealthPluginDataType {
  steps,
  sleepAsleep,
  sleepDeep,
  sleepLight,
  sleepRem,
  sleepUnknown,
  restingHeartRate,
  workout,
  distance,
  totalCaloriesBurned,
}

enum HealthPluginAccess { read, write, readWrite }

enum HealthPluginRuntimePermission {
  granted,
  denied,
  permanentlyDenied,
  restricted,
  notApplicable,
}

class HealthPluginPermission {
  const HealthPluginPermission(this.type, this.access);

  final HealthPluginDataType type;
  final HealthPluginAccess access;

  @override
  bool operator ==(Object other) =>
      other is HealthPluginPermission &&
      other.type == type &&
      other.access == access;

  @override
  int get hashCode => Object.hash(type, access);
}

class HealthPluginDataPoint {
  const HealthPluginDataPoint({
    required this.id,
    required this.type,
    required this.from,
    required this.to,
    required this.sourceId,
    required this.sourceName,
    this.numericValue,
    this.workoutActivityType,
    this.workoutEnergyKcal,
  });

  final String id;
  final HealthPluginDataType type;
  final DateTime from;
  final DateTime to;
  final String sourceId;
  final String sourceName;
  final num? numericValue;
  final String? workoutActivityType;
  final int? workoutEnergyKcal;
}

class HealthPluginWorkout {
  const HealthPluginWorkout({
    required this.title,
    required this.startedAt,
    required this.endedAt,
    this.totalKcal,
  });

  final String title;
  final DateTime startedAt;
  final DateTime endedAt;
  final int? totalKcal;
}

/// Confine iniettabile attorno ai platform channel di `health`.
///
/// I test del gateway usano una fake di questa porta e non caricano mai il
/// plugin nativo.
abstract interface class HealthPluginFacade {
  HealthPluginPlatform get platform;

  Future<void> configure();

  Future<HealthPluginAvailability> availability();

  bool supports(HealthPluginDataType type);

  Future<bool?> hasPermissions(List<HealthPluginPermission> permissions);

  Future<bool> requestAuthorization(List<HealthPluginPermission> permissions);

  Future<HealthPluginRuntimePermission> activityRecognitionPermission();

  Future<HealthPluginRuntimePermission> requestActivityRecognition();

  Future<List<HealthPluginDataPoint>> read({
    required Set<HealthPluginDataType> types,
    required DateTime from,
    required DateTime to,
  });

  Future<int?> readTotalSteps({required DateTime from, required DateTime to});

  Future<bool> writeStrengthWorkout(HealthPluginWorkout workout);
}

/// Adapter sottile che usa esclusivamente le API pubbliche di `health` 13.3.1.
class PackageHealthPluginFacade implements HealthPluginFacade {
  PackageHealthPluginFacade({Health? health}) : _health = health ?? Health();

  final Health _health;

  @override
  HealthPluginPlatform get platform {
    if (Platform.isAndroid) {
      return HealthPluginPlatform.androidHealthConnect;
    }
    if (Platform.isIOS) {
      return HealthPluginPlatform.iosHealthKit;
    }
    return HealthPluginPlatform.unsupported;
  }

  @override
  Future<void> configure() => _health.configure();

  @override
  Future<HealthPluginAvailability> availability() async {
    if (platform == HealthPluginPlatform.iosHealthKit) {
      return HealthPluginAvailability.available;
    }
    if (platform != HealthPluginPlatform.androidHealthConnect) {
      return HealthPluginAvailability.unavailable;
    }
    return switch (await _health.getHealthConnectSdkStatus()) {
      HealthConnectSdkStatus.sdkAvailable => HealthPluginAvailability.available,
      HealthConnectSdkStatus.sdkUnavailableProviderUpdateRequired =>
        HealthPluginAvailability.providerUpdateRequired,
      _ => HealthPluginAvailability.unavailable,
    };
  }

  @override
  bool supports(HealthPluginDataType type) {
    if (platform == HealthPluginPlatform.unsupported) {
      return false;
    }
    return _health.isDataTypeAvailable(_toPackageType(type));
  }

  @override
  Future<bool?> hasPermissions(List<HealthPluginPermission> permissions) async {
    final normalized = _normalizePermissions(permissions);
    return _health.hasPermissions(
      [for (final permission in normalized) _toPackageType(permission.type)],
      permissions: [
        for (final permission in normalized)
          _toPackageAccess(permission.access),
      ],
    );
  }

  @override
  Future<bool> requestAuthorization(
    List<HealthPluginPermission> permissions,
  ) async {
    final normalized = _normalizePermissions(permissions);
    return _health.requestAuthorization(
      [for (final permission in normalized) _toPackageType(permission.type)],
      permissions: [
        for (final permission in normalized)
          _toPackageAccess(permission.access),
      ],
    );
  }

  @override
  Future<HealthPluginRuntimePermission> activityRecognitionPermission() async {
    if (platform != HealthPluginPlatform.androidHealthConnect) {
      return HealthPluginRuntimePermission.notApplicable;
    }
    return _fromPermissionStatus(await Permission.activityRecognition.status);
  }

  @override
  Future<HealthPluginRuntimePermission> requestActivityRecognition() async {
    if (platform != HealthPluginPlatform.androidHealthConnect) {
      return HealthPluginRuntimePermission.notApplicable;
    }
    return _fromPermissionStatus(
      await Permission.activityRecognition.request(),
    );
  }

  @override
  Future<List<HealthPluginDataPoint>> read({
    required Set<HealthPluginDataType> types,
    required DateTime from,
    required DateTime to,
  }) async {
    final available = types.where(supports).toList(growable: false);
    if (available.isEmpty) {
      return const [];
    }
    final points = await _health.getHealthDataFromTypes(
      types: [for (final type in available) _toPackageType(type)],
      startTime: from,
      endTime: to,
    );
    return points.map(_fromPackagePoint).toList(growable: false);
  }

  @override
  Future<int?> readTotalSteps({required DateTime from, required DateTime to}) =>
      _health.getTotalStepsInInterval(from, to);

  @override
  Future<bool> writeStrengthWorkout(HealthPluginWorkout workout) {
    final activity = platform == HealthPluginPlatform.iosHealthKit
        ? HealthWorkoutActivityType.TRADITIONAL_STRENGTH_TRAINING
        : HealthWorkoutActivityType.STRENGTH_TRAINING;
    return _health.writeWorkoutData(
      activityType: activity,
      start: workout.startedAt,
      end: workout.endedAt,
      totalEnergyBurned: workout.totalKcal,
      totalEnergyBurnedUnit: HealthDataUnit.KILOCALORIE,
      title: workout.title,
      recordingMethod: RecordingMethod.automatic,
    );
  }
}

List<HealthPluginPermission> _normalizePermissions(
  List<HealthPluginPermission> permissions,
) {
  final byType = <HealthPluginDataType, HealthPluginAccess>{};
  for (final permission in permissions) {
    final current = byType[permission.type];
    if (current == null || current == permission.access) {
      byType[permission.type] = permission.access;
    } else {
      byType[permission.type] = HealthPluginAccess.readWrite;
    }
  }
  return [
    for (final entry in byType.entries)
      HealthPluginPermission(entry.key, entry.value),
  ];
}

HealthDataType _toPackageType(HealthPluginDataType type) => switch (type) {
  HealthPluginDataType.steps => HealthDataType.STEPS,
  HealthPluginDataType.sleepAsleep => HealthDataType.SLEEP_ASLEEP,
  HealthPluginDataType.sleepDeep => HealthDataType.SLEEP_DEEP,
  HealthPluginDataType.sleepLight => HealthDataType.SLEEP_LIGHT,
  HealthPluginDataType.sleepRem => HealthDataType.SLEEP_REM,
  HealthPluginDataType.sleepUnknown => HealthDataType.SLEEP_UNKNOWN,
  HealthPluginDataType.restingHeartRate => HealthDataType.RESTING_HEART_RATE,
  HealthPluginDataType.workout => HealthDataType.WORKOUT,
  HealthPluginDataType.distance => HealthDataType.DISTANCE_DELTA,
  HealthPluginDataType.totalCaloriesBurned =>
    HealthDataType.TOTAL_CALORIES_BURNED,
};

HealthDataAccess _toPackageAccess(HealthPluginAccess access) =>
    switch (access) {
      HealthPluginAccess.read => HealthDataAccess.READ,
      HealthPluginAccess.write => HealthDataAccess.WRITE,
      HealthPluginAccess.readWrite => HealthDataAccess.READ_WRITE,
    };

HealthPluginRuntimePermission _fromPermissionStatus(PermissionStatus status) =>
    switch (status) {
      PermissionStatus.granted ||
      PermissionStatus.limited ||
      PermissionStatus.provisional => HealthPluginRuntimePermission.granted,
      PermissionStatus.permanentlyDenied =>
        HealthPluginRuntimePermission.permanentlyDenied,
      PermissionStatus.restricted => HealthPluginRuntimePermission.restricted,
      PermissionStatus.denied => HealthPluginRuntimePermission.denied,
    };

HealthPluginDataPoint _fromPackagePoint(HealthDataPoint point) {
  final value = point.value;
  return HealthPluginDataPoint(
    id: point.uuid,
    type: _fromPackageType(point.type),
    from: point.dateFrom,
    to: point.dateTo,
    sourceId: point.sourceId,
    sourceName: point.sourceName,
    numericValue: value is NumericHealthValue ? value.numericValue : null,
    workoutActivityType: value is WorkoutHealthValue
        ? value.workoutActivityType.name
        : null,
    workoutEnergyKcal: value is WorkoutHealthValue
        ? value.totalEnergyBurned
        : null,
  );
}

HealthPluginDataType _fromPackageType(HealthDataType type) => switch (type) {
  HealthDataType.STEPS => HealthPluginDataType.steps,
  HealthDataType.SLEEP_ASLEEP => HealthPluginDataType.sleepAsleep,
  HealthDataType.SLEEP_DEEP => HealthPluginDataType.sleepDeep,
  HealthDataType.SLEEP_LIGHT => HealthPluginDataType.sleepLight,
  HealthDataType.SLEEP_REM => HealthPluginDataType.sleepRem,
  HealthDataType.SLEEP_UNKNOWN => HealthPluginDataType.sleepUnknown,
  HealthDataType.RESTING_HEART_RATE => HealthPluginDataType.restingHeartRate,
  HealthDataType.WORKOUT => HealthPluginDataType.workout,
  HealthDataType.DISTANCE_DELTA => HealthPluginDataType.distance,
  HealthDataType.TOTAL_CALORIES_BURNED =>
    HealthPluginDataType.totalCaloriesBurned,
  _ => throw StateError('Tipo health inatteso: ${type.name}'),
};
