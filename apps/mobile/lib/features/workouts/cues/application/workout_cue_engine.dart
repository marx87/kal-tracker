import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:kal_tracker/core/notifications/app_notification_ids.dart';
import 'package:kal_tracker/features/workouts/cues/application/workout_cue_ports.dart';
import 'package:kal_tracker/features/workouts/cues/data/workout_cue_store.dart';
import 'package:kal_tracker/features/workouts/cues/domain/workout_cue.dart';
import 'package:kal_tracker/features/workouts/cues/domain/workout_cue_message.dart';
import 'package:kal_tracker/features/workouts/cues/domain/workout_cue_preferences.dart';

enum WorkoutCueSource { immediate, countdown, scheduled, restored }

enum WorkoutCueOutputKind { speech, signal }

@immutable
class WorkoutCueOutputFailure {
  const WorkoutCueOutputFailure({
    required this.output,
    required this.error,
    required this.stackTrace,
  });

  final WorkoutCueOutputKind output;
  final Object error;
  final StackTrace stackTrace;
}

/// Esito osservabile, ma mai fatale per il salvataggio della sessione.
@immutable
class WorkoutCueDispatchReport {
  WorkoutCueDispatchReport({
    required this.cue,
    required this.source,
    required Iterable<WorkoutCueOutputKind> attempted,
    required Iterable<WorkoutCueOutputKind> succeeded,
    required Iterable<WorkoutCueOutputFailure> failures,
  }) : attempted = Set.unmodifiable(attempted),
       succeeded = Set.unmodifiable(succeeded),
       failures = List.unmodifiable(failures);

  final WorkoutCue cue;
  final WorkoutCueSource source;
  final Set<WorkoutCueOutputKind> attempted;
  final Set<WorkoutCueOutputKind> succeeded;
  final List<WorkoutCueOutputFailure> failures;

  bool get deliveredCleanly => failures.isEmpty;
}

abstract interface class WorkoutCueTimer {
  bool get isActive;
  void cancel();
}

typedef WorkoutCueTimerFactory =
    WorkoutCueTimer Function(Duration delay, VoidCallback callback);

class DartWorkoutCueTimer implements WorkoutCueTimer {
  DartWorkoutCueTimer(Duration delay, VoidCallback callback)
    : _timer = Timer(delay, callback);

  final Timer _timer;

  @override
  bool get isActive => _timer.isActive;

  @override
  void cancel() => _timer.cancel();
}

/// Regia unica per voce, segnali locali e scadenze di sistema.
///
/// Il motore non conosce widget né repository workout. Le schermate emettono
/// eventi tipizzati; se un plugin fallisce il report lo dichiara, ma il gesto
/// che ha completato una serie non fallisce mai per colpa dell'audio.
class WorkoutCueEngine {
  WorkoutCueEngine({
    required this.store,
    required this.speech,
    required this.signals,
    required this.notifications,
    required this.wakeLock,
    DateTime Function()? now,
    WorkoutCueTimerFactory? timerFactory,
  }) : _now = now ?? DateTime.now,
       _timerFactory = timerFactory ?? DartWorkoutCueTimer.new;

  final WorkoutCueStore store;
  final WorkoutSpeechOutput speech;
  final WorkoutSignalOutput signals;
  final WorkoutNotificationOutput notifications;
  final WorkoutWakeLockOutput wakeLock;
  final DateTime Function() _now;
  final WorkoutCueTimerFactory _timerFactory;

  final Map<String, ScheduledWorkoutCue> _pending = {};
  final Map<String, List<WorkoutCueTimer>> _timers = {};
  final Map<String, Set<int>> _announcedCountdowns = {};
  final StreamController<WorkoutCueDispatchReport> _reports =
      StreamController.broadcast(sync: true);

  WorkoutCuePreferences _preferences = const WorkoutCuePreferences();
  Future<void>? _initializing;
  bool _sessionActive = false;
  bool _disposed = false;

  WorkoutCuePreferences get preferences => _preferences;
  List<ScheduledWorkoutCue> get pending => List.unmodifiable(_pending.values);
  Stream<WorkoutCueDispatchReport> get reports => _reports.stream;

  Future<void> initialize() {
    _assertAlive();
    return _initializing ??= _initialize();
  }

  Future<void> _initialize() async {
    WorkoutCuePersistentState state;
    try {
      state = await store.read();
    } on Object {
      state = WorkoutCuePersistentState();
    }
    _preferences = state.preferences;

    var repaired = false;
    for (final saved in state.pending) {
      var cue = saved;
      final idAlreadyUsed = _pending.values.any(
        (other) =>
            other.notificationId == cue.notificationId && other.id != cue.id,
      );
      if (!AppNotificationIds.workoutCues.contains(cue.notificationId) ||
          idAlreadyUsed) {
        cue = ScheduledWorkoutCue(
          id: cue.id,
          cue: cue.cue,
          deadline: cue.deadline,
          notificationId: _notificationIdFor(cue.id),
          countdownSeconds: cue.countdownSeconds,
        );
        repaired = true;
      }
      _pending[cue.id] = cue;
    }

    await _ignoreFailure(notifications.initialize);
    await _ignoreFailure(() => speech.configure(_preferences));

    final overdue = _pending.values
        .where((cue) => !cue.deadline.isAfter(_now()))
        .toList();
    for (final cue in overdue) {
      _pending.remove(cue.id);
      await _ignoreFailure(() => notifications.cancel(cue.notificationId));
      await _dispatch(cue.cue, WorkoutCueSource.restored);
      repaired = true;
    }

    for (final cue in _pending.values) {
      if (_preferences.notificationsEnabled) {
        await _scheduleSystemNotification(cue);
      }
      _arm(cue);
    }
    if (repaired) await _persist();
  }

  Future<WorkoutCueDispatchReport> emit(WorkoutCue cue) async {
    await initialize();
    return _dispatch(cue, WorkoutCueSource.immediate);
  }

  /// Pianifica il cue terminale e, in primo piano, i secondi da pronunciare.
  ///
  /// Nel sistema operativo viene pianificata una sola notifica con suono alla
  /// scadenza; i tick intermedi non riempiono il centro notifiche. La scadenza
  /// e il cue vengono salvati su file, quindi [synchronize] può ricostruire la
  /// regia dopo sospensione o riavvio del processo.
  Future<int> scheduleCountdown({
    required String id,
    required DateTime deadline,
    required WorkoutCue completionCue,
    Iterable<int>? announceAtSeconds,
  }) async {
    await initialize();
    final normalizedId = id.trim();
    if (normalizedId.isEmpty) {
      throw ArgumentError.value(id, 'id', 'non può essere vuoto');
    }

    final previous = _pending.remove(normalizedId);
    if (previous != null) {
      _cancelTimers(normalizedId);
      await _ignoreFailure(() => notifications.cancel(previous.notificationId));
    }

    final countdown = (announceAtSeconds ?? _preferences.countdownSeconds)
        .where((seconds) => seconds > 0)
        .toSet();
    final scheduled = ScheduledWorkoutCue(
      id: normalizedId,
      cue: completionCue,
      deadline: deadline.toUtc(),
      notificationId:
          previous?.notificationId ?? _notificationIdFor(normalizedId),
      countdownSeconds: countdown,
    );
    _pending[normalizedId] = scheduled;
    _announcedCountdowns[normalizedId] = <int>{};
    await _persist();

    if (!scheduled.deadline.isAfter(_now())) {
      await _deliverScheduled(normalizedId, WorkoutCueSource.scheduled);
      return scheduled.notificationId;
    }
    if (_preferences.notificationsEnabled) {
      await _scheduleSystemNotification(scheduled);
    }
    _arm(scheduled);
    return scheduled.notificationId;
  }

  /// Da chiamare al ritorno in primo piano. Non annuncia tick ormai passati.
  Future<void> synchronize() async {
    await initialize();
    for (final cue in _pending.values.toList()) {
      if (!cue.deadline.isAfter(_now())) {
        await _deliverScheduled(cue.id, WorkoutCueSource.restored);
      } else {
        _arm(cue);
      }
    }
  }

  Future<void> cancelScheduled(String id) async {
    await initialize();
    final cue = _pending.remove(id);
    _cancelTimers(id);
    _announcedCountdowns.remove(id);
    if (cue == null) return;
    await _persist();
    await _ignoreFailure(() => notifications.cancel(cue.notificationId));
  }

  /// Cancella solo gli id workout registrati nel piccolo store, mai quelli di
  /// acqua o di altre funzioni.
  Future<void> cancelAllScheduled() async {
    await initialize();
    final cues = _pending.values.toList();
    _pending.clear();
    for (final id in _timers.keys.toList()) {
      _cancelTimers(id);
    }
    _announcedCountdowns.clear();
    await _persist();
    for (final cue in cues) {
      await _ignoreFailure(() => notifications.cancel(cue.notificationId));
    }
  }

  Future<void> updatePreferences(WorkoutCuePreferences preferences) async {
    await initialize();
    final notificationsWereEnabled = _preferences.notificationsEnabled;
    _preferences = preferences;
    await _ignoreFailure(() => speech.configure(preferences));

    if (notificationsWereEnabled && !preferences.notificationsEnabled) {
      for (final cue in _pending.values) {
        await _ignoreFailure(() => notifications.cancel(cue.notificationId));
      }
    } else if (!notificationsWereEnabled && preferences.notificationsEnabled) {
      for (final cue in _pending.values) {
        await _scheduleSystemNotification(cue);
      }
    }
    for (final cue in _pending.values) {
      _arm(cue);
    }
    await _applyWakeLock();
    await _persist();
  }

  Future<WorkoutNotificationPermissions> requestNotificationPermissions({
    bool requestExactAlarms = false,
  }) async {
    await initialize();
    try {
      return await notifications.requestPermissions(
        requestExactAlarms: requestExactAlarms,
      );
    } on Object {
      return const WorkoutNotificationPermissions(
        notifications: false,
        exactAlarms: false,
      );
    }
  }

  Future<void> setSessionActive(bool active) async {
    await initialize();
    _sessionActive = active;
    await _applyWakeLock();
  }

  Future<void> stopVoice() async {
    await initialize();
    await _ignoreFailure(speech.stop);
  }

  Future<WorkoutCueDispatchReport> _dispatch(
    WorkoutCue cue,
    WorkoutCueSource source,
  ) async {
    final attempted = <WorkoutCueOutputKind>{};
    final succeeded = <WorkoutCueOutputKind>{};
    final failures = <WorkoutCueOutputFailure>[];
    final suppressCountdown =
        cue is CountdownCue && !_preferences.countdownEnabled;

    Future<void> attempt(
      WorkoutCueOutputKind kind,
      Future<void> Function() action,
    ) async {
      attempted.add(kind);
      try {
        await action();
        succeeded.add(kind);
      } on Object catch (error, stackTrace) {
        failures.add(
          WorkoutCueOutputFailure(
            output: kind,
            error: error,
            stackTrace: stackTrace,
          ),
        );
      }
    }

    if (!suppressCountdown && _preferences.shouldSpeak(cue)) {
      final message = workoutCueMessage(cue);
      await attempt(
        WorkoutCueOutputKind.speech,
        () => speech.speak(
          message.speech,
          interrupt: cue.importance == WorkoutCueImportance.critical,
          duckOtherAudio: _preferences.duckOtherAudio,
        ),
      );
    }

    final signal = suppressCountdown ? null : _signalFor(cue);
    if (signal != null &&
        (_preferences.beepsEnabled || _preferences.hapticsEnabled)) {
      await attempt(
        WorkoutCueOutputKind.signal,
        () => signals.play(
          signal,
          beep: _preferences.beepsEnabled,
          haptic: _preferences.hapticsEnabled,
        ),
      );
    }

    final report = WorkoutCueDispatchReport(
      cue: cue,
      source: source,
      attempted: attempted,
      succeeded: succeeded,
      failures: failures,
    );
    if (!_reports.isClosed) _reports.add(report);
    return report;
  }

  void _arm(ScheduledWorkoutCue cue) {
    _cancelTimers(cue.id);
    final timers = <WorkoutCueTimer>[];
    final now = _now();

    if (_preferences.countdownEnabled) {
      final thresholds = cue.countdownSeconds.toList()
        ..sort((a, b) => b.compareTo(a));
      for (final seconds in thresholds) {
        final fireAt = cue.deadline.subtract(Duration(seconds: seconds));
        final delay = fireAt.difference(now);
        if (delay <= Duration.zero) continue;
        timers.add(
          _timerFactory(
            delay,
            () => unawaited(_countdownFired(cue.id, seconds)),
          ),
        );
      }
    }

    final completionDelay = cue.deadline.difference(now);
    if (completionDelay > Duration.zero) {
      timers.add(
        _timerFactory(
          completionDelay,
          () =>
              unawaited(_deliverScheduled(cue.id, WorkoutCueSource.scheduled)),
        ),
      );
    }
    _timers[cue.id] = timers;
  }

  Future<void> _countdownFired(String id, int expectedSeconds) async {
    final cue = _pending[id];
    if (cue == null || !_preferences.countdownEnabled) return;
    final remaining = _remainingSeconds(cue.deadline, _now());
    if (remaining <= 0) {
      await _deliverScheduled(id, WorkoutCueSource.scheduled);
      return;
    }
    // Un Timer sospeso in background non deve recitare al ritorno una sequenza
    // vecchia («dieci, cinque, tre») quando il recupero è già quasi finito.
    if (remaining != expectedSeconds) return;
    final announced = _announcedCountdowns.putIfAbsent(id, () => <int>{});
    if (!announced.add(expectedSeconds)) return;
    await _dispatch(
      CountdownCue(secondsRemaining: remaining),
      WorkoutCueSource.countdown,
    );
  }

  Future<void> _deliverScheduled(String id, WorkoutCueSource source) async {
    final cue = _pending.remove(id);
    if (cue == null) return;
    _cancelTimers(id);
    _announcedCountdowns.remove(id);
    await _persist();
    // Se l'app è in primo piano evita il doppio segnale del timer Dart e della
    // notifica. Se è sospesa il Timer non gira e la notifica resta al sistema.
    await _ignoreFailure(() => notifications.cancel(cue.notificationId));
    await _dispatch(cue.cue, source);
  }

  Future<void> _scheduleSystemNotification(ScheduledWorkoutCue cue) async {
    if (!cue.deadline.isAfter(_now())) return;
    final message = workoutCueMessage(cue.cue);
    await _ignoreFailure(
      () => notifications.schedule(
        WorkoutCueNotificationRequest(
          id: cue.notificationId,
          scheduledAt: cue.deadline,
          title: message.notificationTitle,
          body: message.notificationBody,
          payload: 'workout-cue:${cue.id}',
        ),
      ),
    );
  }

  int _notificationIdFor(String key) {
    final namespace = AppNotificationIds.workoutCues;
    var candidate = namespace.stable(key);
    final occupied = _pending.values.map((cue) => cue.notificationId).toSet();
    for (var attempt = 0; attempt < namespace.length; attempt++) {
      if (!occupied.contains(candidate)) return candidate;
      candidate = candidate == namespace.last ? namespace.first : candidate + 1;
    }
    throw StateError('Spazio id notifiche workout esaurito.');
  }

  Future<void> _persist() => _ignoreFailure(
    () => store.write(
      WorkoutCuePersistentState(
        preferences: _preferences,
        pending: _pending.values,
      ),
    ),
  );

  Future<void> _applyWakeLock() => _ignoreFailure(
    () => wakeLock.setEnabled(_sessionActive && _preferences.keepScreenAwake),
  );

  void _cancelTimers(String id) {
    for (final timer in _timers.remove(id) ?? const <WorkoutCueTimer>[]) {
      timer.cancel();
    }
  }

  void _assertAlive() {
    if (_disposed) throw StateError('WorkoutCueEngine già chiuso.');
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final id in _timers.keys.toList()) {
      _cancelTimers(id);
    }
    await _ignoreFailure(speech.stop);
    await _ignoreFailure(() => wakeLock.setEnabled(false));
    await _reports.close();
  }
}

WorkoutCueSignal? _signalFor(WorkoutCue cue) => switch (cue) {
  SetCompletedCue() ||
  RestStartedCue() ||
  WorkoutPausedCue() => WorkoutCueSignal.selection,
  CountdownCue() => WorkoutCueSignal.countdown,
  WorkoutStartedCue() ||
  NextSetCue() ||
  WorkoutResumedCue() => WorkoutCueSignal.transition,
  RestFinishedCue() => WorkoutCueSignal.attention,
  CircuitPhaseCue(:final phase) =>
    phase == WorkoutCircuitPhase.completed
        ? WorkoutCueSignal.success
        : WorkoutCueSignal.transition,
  PersonalRecordCue() || WorkoutCompletedCue() => WorkoutCueSignal.success,
};

int _remainingSeconds(DateTime deadline, DateTime now) {
  final milliseconds = deadline.difference(now).inMilliseconds;
  if (milliseconds <= 0) return 0;
  return (milliseconds + 999) ~/ 1000;
}

Future<void> _ignoreFailure(Future<void> Function() action) async {
  try {
    await action();
  } on Object {
    // L'infrastruttura di guida è accessoria: non invalida mai una serie.
  }
}
