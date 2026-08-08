import 'package:flutter/foundation.dart';
import 'package:kal_tracker/features/workouts/cues/domain/workout_cue_preferences.dart';

abstract interface class WorkoutSpeechOutput {
  Future<void> configure(WorkoutCuePreferences preferences);

  Future<void> speak(
    String text, {
    required bool interrupt,
    required bool duckOtherAudio,
  });

  Future<void> stop();
}

enum WorkoutCueSignal { selection, countdown, transition, attention, success }

abstract interface class WorkoutSignalOutput {
  Future<void> play(
    WorkoutCueSignal signal, {
    required bool beep,
    required bool haptic,
  });
}

@immutable
class WorkoutCueNotificationRequest {
  const WorkoutCueNotificationRequest({
    required this.id,
    required this.scheduledAt,
    required this.title,
    required this.body,
    required this.payload,
    this.preferExact = true,
  });

  final int id;
  final DateTime scheduledAt;
  final String title;
  final String body;
  final String payload;

  /// L'adapter usa la consegna esatta solo se il sistema l'ha autorizzata.
  final bool preferExact;
}

@immutable
class WorkoutNotificationPermissions {
  const WorkoutNotificationPermissions({
    required this.notifications,
    required this.exactAlarms,
  });

  final bool notifications;
  final bool exactAlarms;
}

abstract interface class WorkoutNotificationOutput {
  Future<void> initialize();

  /// Va chiamato in risposta a un gesto esplicito dell'utente.
  Future<WorkoutNotificationPermissions> requestPermissions({
    bool requestExactAlarms = false,
  });

  Future<void> schedule(WorkoutCueNotificationRequest request);

  /// Mai `cancelAll`: ogni funzione cancella soltanto gli id che possiede.
  Future<void> cancel(int id);
}

abstract interface class WorkoutWakeLockOutput {
  Future<void> setEnabled(bool enabled);
}

/// Implementazioni silenziose utili per configurazioni non mobili e test.
class SilentWorkoutSpeechOutput implements WorkoutSpeechOutput {
  const SilentWorkoutSpeechOutput();

  @override
  Future<void> configure(WorkoutCuePreferences preferences) async {}

  @override
  Future<void> speak(
    String text, {
    required bool interrupt,
    required bool duckOtherAudio,
  }) async {}

  @override
  Future<void> stop() async {}
}

class SilentWorkoutSignalOutput implements WorkoutSignalOutput {
  const SilentWorkoutSignalOutput();

  @override
  Future<void> play(
    WorkoutCueSignal signal, {
    required bool beep,
    required bool haptic,
  }) async {}
}

class SilentWorkoutNotificationOutput implements WorkoutNotificationOutput {
  const SilentWorkoutNotificationOutput();

  @override
  Future<void> cancel(int id) async {}

  @override
  Future<void> initialize() async {}

  @override
  Future<WorkoutNotificationPermissions> requestPermissions({
    bool requestExactAlarms = false,
  }) async => const WorkoutNotificationPermissions(
    notifications: false,
    exactAlarms: false,
  );

  @override
  Future<void> schedule(WorkoutCueNotificationRequest request) async {}
}

class SilentWorkoutWakeLockOutput implements WorkoutWakeLockOutput {
  const SilentWorkoutWakeLockOutput();

  @override
  Future<void> setEnabled(bool enabled) async {}
}
