import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/notifications/app_notification_ids.dart';
import 'package:kal_tracker/features/workouts/cues/data/workout_cue_store.dart';
import 'package:kal_tracker/features/workouts/cues/domain/workout_cue.dart';
import 'package:kal_tracker/features/workouts/cues/domain/workout_cue_preferences.dart';

void main() {
  late Directory directory;
  late FileWorkoutCueStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('coach360-cues-');
    store = FileWorkoutCueStore(directory: () async => directory);
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('salva preferenze, cue e scadenza senza Drift', () async {
    final deadline = DateTime.utc(2026, 8, 8, 18, 30);
    await store.write(
      WorkoutCuePersistentState(
        preferences: const WorkoutCuePreferences(
          voice: VoiceGuidanceLevel.detailed,
          keepScreenAwake: true,
        ),
        pending: [
          ScheduledWorkoutCue(
            id: 'rest:w1:2',
            cue: const RestFinishedCue(nextExerciseName: 'Rematore'),
            deadline: deadline,
            notificationId: AppNotificationIds.workoutCues.stable('rest:w1:2'),
            countdownSeconds: const {3, 2, 1},
          ),
        ],
      ),
    );

    final restored = await store.read();

    expect(restored.preferences.voice, VoiceGuidanceLevel.detailed);
    expect(restored.preferences.keepScreenAwake, isTrue);
    expect(restored.pending, hasLength(1));
    expect(restored.pending.single.deadline, deadline);
    expect(restored.pending.single.cue, isA<RestFinishedCue>());
    expect(restored.pending.single.countdownSeconds, {3, 2, 1});
  });

  test('un file incompleto riparte da uno stato sicuro', () async {
    await File(
      '${directory.path}/workout-cues-v1.json',
    ).writeAsString('{rotto');

    final restored = await store.read();

    expect(restored.pending, isEmpty);
    expect(restored.preferences.voice, VoiceGuidanceLevel.essential);
  });
}
