import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/notifications/app_notification_ids.dart';
import 'package:kal_tracker/features/workouts/cues/application/workout_cue_engine.dart';
import 'package:kal_tracker/features/workouts/cues/application/workout_cue_ports.dart';
import 'package:kal_tracker/features/workouts/cues/data/workout_cue_store.dart';
import 'package:kal_tracker/features/workouts/cues/domain/workout_cue.dart';
import 'package:kal_tracker/features/workouts/cues/domain/workout_cue_preferences.dart';

void main() {
  late DateTime now;
  late InMemoryWorkoutCueStore store;
  late FakeSpeech speech;
  late FakeSignals signals;
  late FakeNotifications notifications;
  late FakeWakeLock wakeLock;
  late ManualTimerFactory timers;
  late WorkoutCueEngine engine;

  void build({WorkoutCuePersistentState? state}) {
    store = InMemoryWorkoutCueStore(state);
    speech = FakeSpeech();
    signals = FakeSignals();
    notifications = FakeNotifications();
    wakeLock = FakeWakeLock();
    timers = ManualTimerFactory();
    engine = WorkoutCueEngine(
      store: store,
      speech: speech,
      signals: signals,
      notifications: notifications,
      wakeLock: wakeLock,
      now: () => now,
      timerFactory: timers.call,
    );
    addTearDown(engine.dispose);
  }

  setUp(() {
    now = DateTime.utc(2026, 8, 8, 18);
    build();
  });

  test('livello essenziale salta i dettagli ma annuncia la fine', () async {
    final detail = await engine.emit(
      const SetCompletedCue(exerciseName: 'Squat', setNumber: 1),
    );
    final essential = await engine.emit(
      const RestFinishedCue(nextExerciseName: 'Squat'),
    );

    expect(detail.attempted, isNot(contains(WorkoutCueOutputKind.speech)));
    expect(detail.attempted, contains(WorkoutCueOutputKind.signal));
    expect(essential.succeeded, contains(WorkoutCueOutputKind.speech));
    expect(speech.spoken.single.text, contains('Recupero finito'));
  });

  test('voce spenta non spegne vibrazione e beep', () async {
    await engine.updatePreferences(
      engine.preferences.copyWith(voice: VoiceGuidanceLevel.off),
    );

    await engine.emit(const RestFinishedCue());

    expect(speech.spoken, isEmpty);
    expect(signals.played.single.signal, WorkoutCueSignal.attention);
    expect(signals.played.single.beep, isTrue);
    expect(signals.played.single.haptic, isTrue);
  });

  test('un errore TTS resta nel report e non blocca il cue', () async {
    speech.error = StateError('motore voce assente');

    final report = await engine.emit(const WorkoutCompletedCue());

    expect(report.deliveredCleanly, isFalse);
    expect(report.failures.single.output, WorkoutCueOutputKind.speech);
    expect(report.succeeded, contains(WorkoutCueOutputKind.signal));
  });

  test('countdown persiste, usa id riservato e consegna una volta', () async {
    final deadline = now.add(const Duration(seconds: 60));

    final notificationId = await engine.scheduleCountdown(
      id: 'rest:w1:2',
      deadline: deadline,
      completionCue: const RestFinishedCue(nextExerciseName: 'Panca'),
      announceAtSeconds: const {10, 3, 2, 1},
    );

    expect(AppNotificationIds.workoutCues.contains(notificationId), isTrue);
    expect(AppNotificationIds.waterReminders.contains(notificationId), isFalse);
    expect(store.state.pending.single.deadline, deadline);
    expect(notifications.scheduled.single.id, notificationId);
    expect(
      timers.created.map((timer) => timer.delay.inSeconds),
      containsAll(<int>[50, 57, 58, 59, 60]),
    );

    now = now.add(const Duration(seconds: 50));
    timers.withDelay(const Duration(seconds: 50)).fire();
    await _flushCallbacks();
    // A dieci secondi l'essenziale vibra ma non parla.
    expect(speech.spoken, isEmpty);
    expect(signals.played.last.signal, WorkoutCueSignal.countdown);

    now = deadline.subtract(const Duration(seconds: 3));
    timers.withDelay(const Duration(seconds: 57)).fire();
    await _flushCallbacks();
    expect(speech.spoken.last.text, '3');

    now = deadline;
    timers.withDelay(const Duration(seconds: 60)).fire();
    await _flushCallbacks();
    expect(engine.pending, isEmpty);
    expect(store.state.pending, isEmpty);
    expect(notifications.cancelled, contains(notificationId));
    expect(
      speech.spoken.where((entry) => entry.text.contains('Recupero finito')),
      hasLength(1),
    );
  });

  test('al riavvio un cue scaduto viene recuperato e rimosso', () async {
    await engine.dispose();
    final id = AppNotificationIds.workoutCues.stable('rest:old');
    build(
      state: WorkoutCuePersistentState(
        pending: [
          ScheduledWorkoutCue(
            id: 'rest:old',
            cue: const RestFinishedCue(),
            deadline: now.subtract(const Duration(seconds: 1)),
            notificationId: id,
          ),
        ],
      ),
    );
    final reports = <WorkoutCueDispatchReport>[];
    engine.reports.listen(reports.add);

    await engine.initialize();

    expect(reports.single.source, WorkoutCueSource.restored);
    expect(reports.single.cue, isA<RestFinishedCue>());
    expect(store.state.pending, isEmpty);
    expect(notifications.cancelled, [id]);
  });

  test('wakelock segue sessione e preferenza, poi viene rilasciato', () async {
    await engine.updatePreferences(
      engine.preferences.copyWith(keepScreenAwake: true),
    );
    await engine.setSessionActive(true);
    await engine.setSessionActive(false);

    expect(wakeLock.values, containsAllInOrder([false, true, false]));
  });

  test('disattivare gli avvisi cancella solo gli id workout noti', () async {
    final id = await engine.scheduleCountdown(
      id: 'rest:w2:1',
      deadline: now.add(const Duration(minutes: 1)),
      completionCue: const RestFinishedCue(),
    );

    await engine.updatePreferences(
      engine.preferences.copyWith(notificationsEnabled: false),
    );

    expect(notifications.cancelled, contains(id));
    expect(
      notifications.cancelled.any(AppNotificationIds.waterReminders.contains),
      isFalse,
    );
  });
}

Future<void> _flushCallbacks() => Future<void>.delayed(Duration.zero);

class FakeSpeech implements WorkoutSpeechOutput {
  final List<WorkoutCuePreferences> configurations = [];
  final List<({String text, bool interrupt, bool duck})> spoken = [];
  Object? error;
  int stops = 0;

  @override
  Future<void> configure(WorkoutCuePreferences preferences) async {
    configurations.add(preferences);
  }

  @override
  Future<void> speak(
    String text, {
    required bool interrupt,
    required bool duckOtherAudio,
  }) async {
    if (error case final failure?) throw failure;
    spoken.add((text: text, interrupt: interrupt, duck: duckOtherAudio));
  }

  @override
  Future<void> stop() async {
    stops += 1;
  }
}

class FakeSignals implements WorkoutSignalOutput {
  final List<({WorkoutCueSignal signal, bool beep, bool haptic})> played = [];

  @override
  Future<void> play(
    WorkoutCueSignal signal, {
    required bool beep,
    required bool haptic,
  }) async {
    played.add((signal: signal, beep: beep, haptic: haptic));
  }
}

class FakeNotifications implements WorkoutNotificationOutput {
  final List<WorkoutCueNotificationRequest> scheduled = [];
  final List<int> cancelled = [];
  int initializeCount = 0;

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
  }

  @override
  Future<void> initialize() async {
    initializeCount += 1;
  }

  @override
  Future<WorkoutNotificationPermissions> requestPermissions({
    bool requestExactAlarms = false,
  }) async => WorkoutNotificationPermissions(
    notifications: true,
    exactAlarms: requestExactAlarms,
  );

  @override
  Future<void> schedule(WorkoutCueNotificationRequest request) async {
    scheduled.add(request);
  }
}

class FakeWakeLock implements WorkoutWakeLockOutput {
  final List<bool> values = [];

  @override
  Future<void> setEnabled(bool enabled) async {
    values.add(enabled);
  }
}

class ManualTimerFactory {
  final List<ManualTimer> created = [];

  WorkoutCueTimer call(Duration delay, void Function() callback) {
    final timer = ManualTimer(delay, callback);
    created.add(timer);
    return timer;
  }

  ManualTimer withDelay(Duration delay) =>
      created.firstWhere((timer) => timer.delay == delay && timer.isActive);
}

class ManualTimer implements WorkoutCueTimer {
  ManualTimer(this.delay, this._callback);

  final Duration delay;
  final void Function() _callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }
}
