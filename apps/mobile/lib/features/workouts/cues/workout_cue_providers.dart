import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/workouts/cues/application/workout_cue_engine.dart';
import 'package:kal_tracker/features/workouts/cues/application/workout_cue_ports.dart';
import 'package:kal_tracker/features/workouts/cues/data/workout_cue_platform_adapters.dart';
import 'package:kal_tracker/features/workouts/cues/data/workout_cue_store.dart';

final workoutCueStoreProvider = Provider<WorkoutCueStore>(
  (ref) => FileWorkoutCueStore(),
);

final workoutSpeechOutputProvider = Provider<WorkoutSpeechOutput>(
  (ref) => FlutterTtsWorkoutSpeechOutput(),
);

final workoutSignalOutputProvider = Provider<WorkoutSignalOutput>(
  (ref) => const SystemWorkoutSignalOutput(),
);

final workoutNotificationOutputProvider = Provider<WorkoutNotificationOutput>(
  (ref) => FlutterWorkoutNotificationOutput(),
);

final workoutWakeLockOutputProvider = Provider<WorkoutWakeLockOutput>(
  (ref) => const WakelockPlusWorkoutOutput(),
);

/// Provider sincrono: ogni metodo dell'engine inizializza pigramente file e
/// plugin, quindi il widget chiamante non deve gestire un AsyncValue.
final workoutCueEngineProvider = Provider<WorkoutCueEngine>((ref) {
  final engine = WorkoutCueEngine(
    store: ref.watch(workoutCueStoreProvider),
    speech: ref.watch(workoutSpeechOutputProvider),
    signals: ref.watch(workoutSignalOutputProvider),
    notifications: ref.watch(workoutNotificationOutputProvider),
    wakeLock: ref.watch(workoutWakeLockOutputProvider),
  );
  ref.onDispose(() => unawaited(engine.dispose()));
  return engine;
});

/// Utile per una schermata impostazioni che vuole leggere le preferenze già
/// caricate prima del primo allenamento.
final workoutCueReadyProvider = FutureProvider<WorkoutCueEngine>((ref) async {
  final engine = ref.watch(workoutCueEngineProvider);
  await engine.initialize();
  return engine;
});
