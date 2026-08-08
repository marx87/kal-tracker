import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/workouts/cues/application/live_workout_cue_coordinator.dart';
import 'package:kal_tracker/features/workouts/cues/application/workout_cue_engine.dart';
import 'package:kal_tracker/features/workouts/cues/application/workout_cue_ports.dart';
import 'package:kal_tracker/features/workouts/cues/data/workout_cue_store.dart';
import 'package:kal_tracker/features/workouts/cues/domain/workout_cue.dart';

void main() {
  test(
    'usa un solo recupero durevole per workout e lo può ripristinare',
    () async {
      final now = DateTime(2026, 8, 8, 10);
      final store = InMemoryWorkoutCueStore();
      final engine = WorkoutCueEngine(
        store: store,
        speech: const SilentWorkoutSpeechOutput(),
        signals: const SilentWorkoutSignalOutput(),
        notifications: const SilentWorkoutNotificationOutput(),
        wakeLock: const SilentWorkoutWakeLockOutput(),
        now: () => now,
        timerFactory: _NeverTimer.new,
      );
      addTearDown(engine.dispose);
      final coordinator = LiveWorkoutCueCoordinator(
        engine: engine,
        workoutId: 'workout-1',
      );
      final deadline = now.add(const Duration(seconds: 90));

      await coordinator.startRest(
        duration: const Duration(seconds: 90),
        deadline: deadline,
        nextExerciseName: 'Squat',
      );

      expect(engine.pending.single.id, 'rest:workout-1');
      expect(await coordinator.restoreRestDeadline(), deadline.toUtc());

      await coordinator.cancelRest();
      expect(engine.pending, isEmpty);
    },
  );

  test('traduce i gesti in eventi tipizzati', () async {
    final engine = WorkoutCueEngine(
      store: InMemoryWorkoutCueStore(),
      speech: const SilentWorkoutSpeechOutput(),
      signals: const SilentWorkoutSignalOutput(),
      notifications: const SilentWorkoutNotificationOutput(),
      wakeLock: const SilentWorkoutWakeLockOutput(),
      timerFactory: _NeverTimer.new,
    );
    addTearDown(engine.dispose);
    final coordinator = LiveWorkoutCueCoordinator(
      engine: engine,
      workoutId: 'workout-2',
    );
    final cues = <WorkoutCue>[];
    final subscription = engine.reports.listen(
      (report) => cues.add(report.cue),
    );
    addTearDown(subscription.cancel);

    await coordinator.setCompleted(
      exerciseName: 'Panca',
      setNumber: 1,
      totalSets: 3,
    );
    await coordinator.nextSet(
      exerciseName: 'Panca',
      setNumber: 2,
      totalSets: 3,
    );
    await coordinator.personalRecord(exerciseName: 'Panca');

    expect(cues, [
      isA<SetCompletedCue>(),
      isA<NextSetCue>(),
      isA<PersonalRecordCue>(),
    ]);
  });
}

class _NeverTimer implements WorkoutCueTimer {
  _NeverTimer(Duration _, void Function() _);

  @override
  bool get isActive => true;

  @override
  void cancel() {}
}
