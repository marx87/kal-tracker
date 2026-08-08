import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/health/data/health_plugin_facade.dart';
import 'package:kal_tracker/features/health/domain/health_data_gateway.dart';
import 'package:path_provider/path_provider.dart';

class HealthWorkoutReceipt {
  const HealthWorkoutReceipt({required this.fingerprint, this.externalId});

  final String fingerprint;
  final String? externalId;
}

/// Stato minimo separato dal database applicativo.
///
/// Conserva solo l'esito del flusso permessi (necessario perché HealthKit non
/// rivela i permessi READ) e le ricevute anti-duplicato dei workout.
abstract interface class HealthAdapterStateStore {
  Future<bool?> authorizationOutcome(HealthCapability capability);

  Future<void> saveAuthorizationOutcome(
    HealthCapability capability,
    bool completedWithoutError,
  );

  Future<HealthWorkoutReceipt?> workoutReceipt(String workoutId);

  Future<void> saveWorkoutReceipt(
    String workoutId,
    HealthWorkoutReceipt receipt,
  );
}

class InMemoryHealthAdapterStateStore implements HealthAdapterStateStore {
  final Map<HealthCapability, bool> _authorization = {};
  final Map<String, HealthWorkoutReceipt> _receipts = {};

  @override
  Future<bool?> authorizationOutcome(HealthCapability capability) async =>
      _authorization[capability];

  @override
  Future<void> saveAuthorizationOutcome(
    HealthCapability capability,
    bool completedWithoutError,
  ) async {
    _authorization[capability] = completedWithoutError;
  }

  @override
  Future<HealthWorkoutReceipt?> workoutReceipt(String workoutId) async =>
      _receipts[workoutId];

  @override
  Future<void> saveWorkoutReceipt(
    String workoutId,
    HealthWorkoutReceipt receipt,
  ) async {
    _receipts[workoutId] = receipt;
  }
}

class FileHealthAdapterStateStore implements HealthAdapterStateStore {
  FileHealthAdapterStateStore(this.file);

  final File file;
  Future<_StoredHealthAdapterState>? _stateFuture;
  Future<void> _writeQueue = Future<void>.value();

  Future<_StoredHealthAdapterState> get _state => _stateFuture ??= _readState();

  @override
  Future<bool?> authorizationOutcome(HealthCapability capability) async =>
      (await _state).authorization[capability.name];

  @override
  Future<void> saveAuthorizationOutcome(
    HealthCapability capability,
    bool completedWithoutError,
  ) async {
    (await _state).authorization[capability.name] = completedWithoutError;
    await _persist();
  }

  @override
  Future<HealthWorkoutReceipt?> workoutReceipt(String workoutId) async =>
      (await _state).receipts[workoutId];

  @override
  Future<void> saveWorkoutReceipt(
    String workoutId,
    HealthWorkoutReceipt receipt,
  ) async {
    (await _state).receipts[workoutId] = receipt;
    await _persist();
  }

  Future<_StoredHealthAdapterState> _readState() async {
    try {
      if (!await file.exists()) {
        return _StoredHealthAdapterState();
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return _StoredHealthAdapterState();
      }
      return _StoredHealthAdapterState.fromJson(decoded);
    } on FormatException {
      return _StoredHealthAdapterState();
    } on FileSystemException {
      return _StoredHealthAdapterState();
    }
  }

  Future<void> _persist() {
    final operation = _writeQueue.then((_) async {
      final state = await _state;
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(state.toJson()), flush: true);
    });
    _writeQueue = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return operation;
  }
}

class _StoredHealthAdapterState {
  _StoredHealthAdapterState({
    Map<String, bool>? authorization,
    Map<String, HealthWorkoutReceipt>? receipts,
  }) : authorization = authorization ?? {},
       receipts = receipts ?? {};

  factory _StoredHealthAdapterState.fromJson(Map<String, dynamic> json) {
    final authorization = <String, bool>{};
    final rawAuthorization = json['authorization'];
    if (rawAuthorization is Map) {
      for (final entry in rawAuthorization.entries) {
        if (entry.key is String && entry.value is bool) {
          authorization[entry.key as String] = entry.value as bool;
        }
      }
    }
    final receipts = <String, HealthWorkoutReceipt>{};
    final rawReceipts = json['workoutReceipts'];
    if (rawReceipts is Map) {
      for (final entry in rawReceipts.entries) {
        final value = entry.value;
        if (entry.key is! String || value is! Map) {
          continue;
        }
        final fingerprint = value['fingerprint'];
        final externalId = value['externalId'];
        if (fingerprint is String &&
            (externalId == null || externalId is String)) {
          receipts[entry.key as String] = HealthWorkoutReceipt(
            fingerprint: fingerprint,
            externalId: externalId as String?,
          );
        }
      }
    }
    return _StoredHealthAdapterState(
      authorization: authorization,
      receipts: receipts,
    );
  }

  final Map<String, bool> authorization;
  final Map<String, HealthWorkoutReceipt> receipts;

  Map<String, Object> toJson() => {
    'version': 1,
    'authorization': authorization,
    'workoutReceipts': {
      for (final entry in receipts.entries)
        entry.key: {
          'fingerprint': entry.value.fingerprint,
          'externalId': ?entry.value.externalId,
        },
    },
  };
}

/// Implementazione concreta del contratto applicativo tramite `health` 13.3.1.
class HealthPackageDataGateway implements HealthDataGateway {
  HealthPackageDataGateway({
    required HealthPluginFacade facade,
    required HealthAdapterStateStore stateStore,
  }) : this._(facade, stateStore);

  HealthPackageDataGateway._(this._facade, this._stateStore);

  /// Costruttore raccomandato nell'app: configura plugin e ricevute persistenti
  /// senza coinvolgere AppDatabase.
  static Future<HealthPackageDataGateway> create() async {
    final support = await getApplicationSupportDirectory();
    return HealthPackageDataGateway(
      facade: PackageHealthPluginFacade(),
      stateStore: FileHealthAdapterStateStore(
        File(
          '${support.path}${Platform.pathSeparator}'
          'health_adapter_state.v1.json',
        ),
      ),
    );
  }

  final HealthPluginFacade _facade;
  final HealthAdapterStateStore _stateStore;
  Future<bool>? _configuration;
  String? _lastError;

  String get _source => switch (_facade.platform) {
    HealthPluginPlatform.androidHealthConnect => 'health_connect',
    HealthPluginPlatform.iosHealthKit => 'apple_health',
    HealthPluginPlatform.unsupported => 'unavailable',
  };

  @override
  Future<HealthGatewayStatus> status() async {
    if (_facade.platform == HealthPluginPlatform.unsupported) {
      return const HealthGatewayStatus.unavailable(
        detail: 'Health Connect e HealthKit non sono disponibili.',
      );
    }
    if (!await _ensureConfigured()) {
      return HealthGatewayStatus.unavailable(
        source: _source,
        detail: _lastError ?? 'Impossibile inizializzare i dati salute.',
      );
    }

    final availability = await _safeAvailability();
    if (availability != HealthPluginAvailability.available) {
      return HealthGatewayStatus.unavailable(
        source: _source,
        detail: _availabilityDetail(availability),
      );
    }

    final capabilities = _supportedCapabilities();
    final permissions = <HealthCapability, HealthPermissionState>{};
    for (final capability in capabilities) {
      permissions[capability] = await _permissionState(capability);
    }
    return HealthGatewayStatus(
      source: _source,
      capabilities: capabilities,
      permissions: permissions,
      detail: _platformDetail(),
    );
  }

  @override
  Future<HealthGatewayStatus> requestAuthorization(
    Set<HealthCapability> capabilities,
  ) async {
    final before = await status();
    final requested = capabilities.intersection(before.capabilities);
    if (requested.isEmpty) {
      return before;
    }
    final permissions = <HealthPluginPermission>[
      for (final capability in requested)
        ..._permissionsFor(capability, statusCheck: false),
    ];
    var activityRecognitionGranted = true;
    bool completed = false;
    try {
      if (requested.any(_requiresActivityRecognition)) {
        activityRecognitionGranted =
            await _facade.requestActivityRecognition() ==
            HealthPluginRuntimePermission.granted;
      }
      completed = await _facade.requestAuthorization(permissions);
      _lastError = null;
    } catch (error) {
      _lastError = 'Autorizzazione salute non completata: $error';
    }
    for (final capability in requested) {
      await _stateStore.saveAuthorizationOutcome(
        capability,
        completed &&
            (!_requiresActivityRecognition(capability) ||
                activityRecognitionGranted),
      );
    }
    return status();
  }

  @override
  Future<List<HealthDailySummary>> readDailySummaries({
    required DateTime fromDay,
    required DateTime throughDay,
  }) async {
    final firstDay = _calendarDay(fromDay);
    final lastDay = _calendarDay(throughDay);
    if (firstDay.isAfter(lastDay)) {
      throw ArgumentError.value(
        throughDay,
        'throughDay',
        'Deve essere uguale o successivo a fromDay.',
      );
    }
    final currentStatus = await status();
    final accumulators = <DateTime, _DailyAccumulator>{};
    for (
      var day = firstDay;
      !day.isAfter(lastDay);
      day = DateTime.utc(day.year, day.month, day.day + 1)
    ) {
      accumulators[day] = _DailyAccumulator(day);
    }

    if (currentStatus.isGranted(HealthCapability.readSteps)) {
      for (final entry in accumulators.entries) {
        try {
          final steps = await _facade.readTotalSteps(
            from: AppTime.startOfDayUtc(entry.key),
            to: AppTime.endOfDayUtc(entry.key),
          );
          if (steps != null && steps >= 0 && steps <= 200000) {
            entry.value.steps = steps;
          }
        } catch (_) {
          // Le altre metriche restano importabili se una sorgente passi fallisce.
        }
      }
    }

    if (currentStatus.isGranted(HealthCapability.readSleep)) {
      await _readSleep(accumulators, firstDay, lastDay);
    }
    if (currentStatus.isGranted(HealthCapability.readRestingHeartRate)) {
      await _readRestingHeartRate(accumulators, firstDay, lastDay);
    }

    return [
      for (final accumulator in accumulators.values)
        if (!accumulator.isEmpty)
          HealthDailySummary(
            day: accumulator.day,
            source: _source,
            externalId: '$_source:${_dateKey(accumulator.day)}',
            steps: accumulator.steps,
            sleepMinutes: accumulator.sleepMinutes,
            restingHeartRate: accumulator.restingHeartRate,
          ),
    ];
  }

  @override
  Future<HealthWorkoutWriteResult> writeWorkout(
    HealthWorkoutRecord workout,
  ) async {
    final currentStatus = await status();
    if (!currentStatus.supports(HealthCapability.writeWorkout)) {
      return HealthWorkoutWriteResult(
        HealthWorkoutWriteState.unsupported,
        detail: currentStatus.detail,
      );
    }
    if (!currentStatus.isGranted(HealthCapability.writeWorkout)) {
      return const HealthWorkoutWriteResult(
        HealthWorkoutWriteState.permissionRequired,
      );
    }
    final validation = _validateWorkout(workout);
    if (validation != null) {
      return HealthWorkoutWriteResult(
        HealthWorkoutWriteState.failed,
        detail: validation,
      );
    }

    final fingerprint = _workoutFingerprint(workout);
    final receipt = await _stateStore.workoutReceipt(workout.id);
    if (receipt != null && receipt.fingerprint != fingerprint) {
      return const HealthWorkoutWriteResult(
        HealthWorkoutWriteState.failed,
        detail: 'Lo stesso ID appartiene gia a un workout diverso.',
      );
    }

    HealthPluginDataPoint? existing;
    try {
      existing = await _findWorkout(workout, expectedId: receipt?.externalId);
    } catch (error) {
      return HealthWorkoutWriteResult(
        HealthWorkoutWriteState.failed,
        detail: 'Impossibile verificare i workout esistenti: $error',
      );
    }
    if (existing != null) {
      final externalId = existing.id.trim().isEmpty ? null : existing.id;
      await _stateStore.saveWorkoutReceipt(
        workout.id,
        HealthWorkoutReceipt(fingerprint: fingerprint, externalId: externalId),
      );
      return HealthWorkoutWriteResult(
        HealthWorkoutWriteState.alreadyPresent,
        externalId: externalId,
      );
    }
    if (receipt != null) {
      return const HealthWorkoutWriteResult(
        HealthWorkoutWriteState.failed,
        detail:
            'Esiste una ricevuta locale, ma la piattaforma non rende il '
            'workout verificabile. Nessuna seconda copia e stata scritta.',
      );
    }

    bool accepted;
    try {
      accepted = await _facade.writeStrengthWorkout(
        HealthPluginWorkout(
          title: workout.title.trim(),
          startedAt: workout.startedAt,
          endedAt: workout.endedAt,
          totalKcal: workout.totalKcal?.round(),
        ),
      );
    } catch (error) {
      return HealthWorkoutWriteResult(
        HealthWorkoutWriteState.failed,
        detail: 'Scrittura workout non riuscita: $error',
      );
    }
    if (!accepted) {
      return const HealthWorkoutWriteResult(
        HealthWorkoutWriteState.failed,
        detail: 'La piattaforma non ha accettato il workout.',
      );
    }

    HealthPluginDataPoint? written;
    try {
      written = await _findWorkout(workout);
    } catch (_) {
      // La ricevuta incerta impedisce un retry che potrebbe duplicare il dato.
    }
    final externalId = written == null || written.id.trim().isEmpty
        ? null
        : written.id;
    await _stateStore.saveWorkoutReceipt(
      workout.id,
      HealthWorkoutReceipt(fingerprint: fingerprint, externalId: externalId),
    );
    if (written == null) {
      return const HealthWorkoutWriteResult(
        HealthWorkoutWriteState.failed,
        detail:
            'La piattaforma ha accettato la richiesta, ma il record non e '
            'verificabile. Il retry automatico e stato bloccato.',
      );
    }
    return HealthWorkoutWriteResult(
      HealthWorkoutWriteState.written,
      externalId: externalId,
    );
  }

  Future<bool> _ensureConfigured() => _configuration ??= _configurePlugin();

  Future<bool> _configurePlugin() async {
    try {
      await _facade.configure();
      return true;
    } catch (error) {
      _lastError = 'Inizializzazione salute non riuscita: $error';
      return false;
    }
  }

  Future<HealthPluginAvailability> _safeAvailability() async {
    try {
      return await _facade.availability();
    } catch (error) {
      _lastError = 'Stato piattaforma salute non disponibile: $error';
      return HealthPluginAvailability.unavailable;
    }
  }

  Set<HealthCapability> _supportedCapabilities() {
    final capabilities = <HealthCapability>{};
    if (_facade.supports(HealthPluginDataType.steps)) {
      capabilities.add(HealthCapability.readSteps);
    }
    if (_sleepTypes.any(_facade.supports)) {
      capabilities.add(HealthCapability.readSleep);
    }
    if (_facade.supports(HealthPluginDataType.restingHeartRate)) {
      capabilities.add(HealthCapability.readRestingHeartRate);
    }
    final workoutTypes =
        _facade.platform == HealthPluginPlatform.androidHealthConnect
        ? const {
            HealthPluginDataType.workout,
            HealthPluginDataType.steps,
            HealthPluginDataType.distance,
            HealthPluginDataType.totalCaloriesBurned,
          }
        : const {HealthPluginDataType.workout};
    if (workoutTypes.every(_facade.supports)) {
      capabilities.add(HealthCapability.writeWorkout);
    }
    return capabilities;
  }

  Future<HealthPermissionState> _permissionState(
    HealthCapability capability,
  ) async {
    final outcome = await _stateStore.authorizationOutcome(capability);
    try {
      if (_requiresActivityRecognition(capability)) {
        final runtime = await _facade.activityRecognitionPermission();
        final blocked = switch (runtime) {
          HealthPluginRuntimePermission.granted ||
          HealthPluginRuntimePermission.notApplicable => null,
          HealthPluginRuntimePermission.denied =>
            outcome == null
                ? HealthPermissionState.notRequested
                : HealthPermissionState.denied,
          HealthPluginRuntimePermission.permanentlyDenied =>
            HealthPermissionState.denied,
          HealthPluginRuntimePermission.restricted =>
            HealthPermissionState.restricted,
        };
        if (blocked != null) {
          return blocked;
        }
      }
      final granted = await _facade.hasPermissions(
        _permissionsFor(capability, statusCheck: true),
      );
      if (granted == true) {
        return HealthPermissionState.granted;
      }
      if (granted == false) {
        return outcome == null
            ? HealthPermissionState.notRequested
            : HealthPermissionState.denied;
      }
      if (_facade.platform == HealthPluginPlatform.iosHealthKit &&
          capability != HealthCapability.writeWorkout) {
        return switch (outcome) {
          true => HealthPermissionState.granted,
          false => HealthPermissionState.denied,
          null => HealthPermissionState.notRequested,
        };
      }
      return outcome == null
          ? HealthPermissionState.notRequested
          : HealthPermissionState.restricted;
    } catch (_) {
      return HealthPermissionState.restricted;
    }
  }

  bool _requiresActivityRecognition(HealthCapability capability) =>
      _facade.platform == HealthPluginPlatform.androidHealthConnect &&
      capability != HealthCapability.readRestingHeartRate;

  List<HealthPluginPermission> _permissionsFor(
    HealthCapability capability, {
    required bool statusCheck,
  }) {
    final permissions = switch (capability) {
      HealthCapability.readSteps => const [
        HealthPluginPermission(
          HealthPluginDataType.steps,
          HealthPluginAccess.read,
        ),
      ],
      HealthCapability.readSleep => [
        for (final type in _sleepTypes)
          if (_facade.supports(type))
            HealthPluginPermission(type, HealthPluginAccess.read),
      ],
      HealthCapability.readRestingHeartRate => const [
        HealthPluginPermission(
          HealthPluginDataType.restingHeartRate,
          HealthPluginAccess.read,
        ),
      ],
      HealthCapability.writeWorkout => _workoutPermissions(
        statusCheck: statusCheck,
      ),
    };
    return permissions.where((entry) => _facade.supports(entry.type)).toList();
  }

  List<HealthPluginPermission> _workoutPermissions({
    required bool statusCheck,
  }) {
    if (_facade.platform == HealthPluginPlatform.iosHealthKit) {
      return [
        HealthPluginPermission(
          HealthPluginDataType.workout,
          statusCheck ? HealthPluginAccess.write : HealthPluginAccess.readWrite,
        ),
      ];
    }
    return const [
      HealthPluginPermission(
        HealthPluginDataType.workout,
        HealthPluginAccess.readWrite,
      ),
      HealthPluginPermission(
        HealthPluginDataType.steps,
        HealthPluginAccess.read,
      ),
      HealthPluginPermission(
        HealthPluginDataType.distance,
        HealthPluginAccess.read,
      ),
      HealthPluginPermission(
        HealthPluginDataType.totalCaloriesBurned,
        HealthPluginAccess.readWrite,
      ),
    ];
  }

  Future<void> _readSleep(
    Map<DateTime, _DailyAccumulator> accumulators,
    DateTime firstDay,
    DateTime lastDay,
  ) async {
    final previousDay = DateTime.utc(
      firstDay.year,
      firstDay.month,
      firstDay.day - 1,
    );
    List<HealthPluginDataPoint> points;
    try {
      points = await _facade.read(
        types: _sleepTypes.where(_facade.supports).toSet(),
        from: AppTime.startOfDayUtc(previousDay),
        to: AppTime.endOfDayUtc(lastDay),
      );
    } catch (_) {
      return;
    }
    final intervals = <DateTime, List<_HealthInterval>>{};
    for (final point in points) {
      if (!_sleepTypes.contains(point.type) || !point.to.isAfter(point.from)) {
        continue;
      }
      final wakeDay = _dayOfInstant(point.to);
      if (!accumulators.containsKey(wakeDay)) {
        continue;
      }
      intervals
          .putIfAbsent(wakeDay, () => [])
          .add(_HealthInterval(point.from.toUtc(), point.to.toUtc()));
    }
    for (final entry in intervals.entries) {
      final minutes = _mergedMinutes(entry.value);
      if (minutes >= 0 && minutes <= 1440) {
        accumulators[entry.key]?.sleepMinutes = minutes;
      }
    }
  }

  Future<void> _readRestingHeartRate(
    Map<DateTime, _DailyAccumulator> accumulators,
    DateTime firstDay,
    DateTime lastDay,
  ) async {
    List<HealthPluginDataPoint> points;
    try {
      points = await _facade.read(
        types: const {HealthPluginDataType.restingHeartRate},
        from: AppTime.startOfDayUtc(firstDay),
        to: AppTime.endOfDayUtc(lastDay),
      );
    } catch (_) {
      return;
    }
    final latest = <DateTime, HealthPluginDataPoint>{};
    for (final point in points) {
      final value = point.numericValue?.round();
      final day = _dayOfInstant(point.to);
      if (value == null ||
          value < 20 ||
          value > 250 ||
          !accumulators.containsKey(day)) {
        continue;
      }
      final current = latest[day];
      if (current == null || point.to.isAfter(current.to)) {
        latest[day] = point;
      }
    }
    for (final entry in latest.entries) {
      accumulators[entry.key]?.restingHeartRate = entry.value.numericValue!
          .round();
    }
  }

  Future<HealthPluginDataPoint?> _findWorkout(
    HealthWorkoutRecord workout, {
    String? expectedId,
  }) async {
    final points = await _facade.read(
      types: const {HealthPluginDataType.workout},
      from: workout.startedAt.subtract(const Duration(seconds: 2)),
      to: workout.endedAt.add(const Duration(seconds: 2)),
    );
    if (expectedId != null) {
      for (final point in points) {
        if (point.id == expectedId) {
          return point;
        }
      }
    }
    for (final point in points) {
      if (_strengthActivities.contains(point.workoutActivityType) &&
          _near(point.from, workout.startedAt) &&
          _near(point.to, workout.endedAt)) {
        return point;
      }
    }
    return null;
  }

  String? _validateWorkout(HealthWorkoutRecord workout) {
    if (workout.id.trim().isEmpty) {
      return 'ID workout mancante.';
    }
    if (workout.title.trim().isEmpty) {
      return 'Titolo workout mancante.';
    }
    if (!workout.endedAt.isAfter(workout.startedAt)) {
      return 'La fine del workout deve essere successiva all inizio.';
    }
    final kcal = workout.totalKcal;
    if (kcal != null && (!kcal.isFinite || kcal < 0 || kcal > 100000)) {
      return 'Calorie workout non valide.';
    }
    return null;
  }

  String _workoutFingerprint(HealthWorkoutRecord workout) => sha256
      .convert(
        utf8.encode(
          '${workout.id.trim()}|${workout.title.trim()}|'
          '${workout.startedAt.toUtc().toIso8601String()}|'
          '${workout.endedAt.toUtc().toIso8601String()}|'
          '${workout.totalKcal?.toStringAsFixed(3) ?? ''}',
        ),
      )
      .toString();

  String _availabilityDetail(HealthPluginAvailability availability) =>
      switch (availability) {
        HealthPluginAvailability.providerUpdateRequired =>
          'Health Connect deve essere installato o aggiornato. Huawei Health '
              'non viene letto direttamente.',
        HealthPluginAvailability.unavailable =>
          'Health Connect non e disponibile su questo dispositivo. Su Huawei '
              'serve un bridge compatibile che pubblichi i dati in Health '
              'Connect; l adapter non legge il cloud Huawei direttamente.',
        HealthPluginAvailability.available => _platformDetail(),
      };

  String _platformDetail() => switch (_facade.platform) {
    HealthPluginPlatform.androidHealthConnect =>
      'I dati arrivano da Health Connect. Huawei Health non e una sorgente '
          'diretta: serve che Huawei o un bridge compatibile vi pubblichi i '
          'dati. Senza il permesso storico, Android limita normalmente le '
          'letture ai 30 giorni precedenti il consenso.',
    HealthPluginPlatform.iosHealthKit =>
      'HealthKit non rivela lo stato dei permessi di lettura. Lo stato '
          'concesso indica che il flusso Apple e stato completato; un risultato '
          'vuoto puo anche significare che la lettura e stata negata.',
    HealthPluginPlatform.unsupported =>
      'Health Connect e HealthKit non sono disponibili.',
  };
}

const _sleepTypes = {
  HealthPluginDataType.sleepAsleep,
  HealthPluginDataType.sleepDeep,
  HealthPluginDataType.sleepLight,
  HealthPluginDataType.sleepRem,
  HealthPluginDataType.sleepUnknown,
};

const _strengthActivities = {
  'STRENGTH_TRAINING',
  'TRADITIONAL_STRENGTH_TRAINING',
  'FUNCTIONAL_STRENGTH_TRAINING',
  'WEIGHTLIFTING',
};

class _DailyAccumulator {
  _DailyAccumulator(this.day);

  final DateTime day;
  int? steps;
  int? sleepMinutes;
  int? restingHeartRate;

  bool get isEmpty =>
      steps == null && sleepMinutes == null && restingHeartRate == null;
}

class _HealthInterval {
  const _HealthInterval(this.from, this.to);

  final DateTime from;
  final DateTime to;
}

int _mergedMinutes(List<_HealthInterval> intervals) {
  if (intervals.isEmpty) {
    return 0;
  }
  intervals.sort((left, right) => left.from.compareTo(right.from));
  var from = intervals.first.from;
  var to = intervals.first.to;
  var milliseconds = 0;
  for (final interval in intervals.skip(1)) {
    if (!interval.from.isAfter(to)) {
      if (interval.to.isAfter(to)) {
        to = interval.to;
      }
      continue;
    }
    milliseconds += to.difference(from).inMilliseconds;
    from = interval.from;
    to = interval.to;
  }
  milliseconds += to.difference(from).inMilliseconds;
  return (milliseconds / Duration.millisecondsPerMinute).round();
}

DateTime _calendarDay(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);

DateTime _dayOfInstant(DateTime value) {
  final inRome = AppTime.inRome(value);
  return DateTime.utc(inRome.year, inRome.month, inRome.day);
}

String _dateKey(DateTime day) {
  final month = day.month.toString().padLeft(2, '0');
  final date = day.day.toString().padLeft(2, '0');
  return '${day.year.toString().padLeft(4, '0')}-$month-$date';
}

bool _near(DateTime left, DateTime right) =>
    left.toUtc().difference(right.toUtc()).abs() <= const Duration(seconds: 2);
