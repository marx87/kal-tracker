import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/workouts/cues/domain/workout_cue.dart';
import 'package:kal_tracker/features/workouts/cues/domain/workout_cue_message.dart';
import 'package:kal_tracker/features/workouts/cues/domain/workout_cue_preferences.dart';

void main() {
  test('un cambio circuito conserva tipo e dati nel file', () {
    const cue = CircuitPhaseCue(
      phase: WorkoutCircuitPhase.work,
      exerciseName: 'Squat',
      duration: Duration(seconds: 40),
    );

    final restored = WorkoutCue.fromJson(cue.toJson());

    expect(restored, isA<CircuitPhaseCue>());
    final circuit = restored as CircuitPhaseCue;
    expect(circuit.phase, WorkoutCircuitPhase.work);
    expect(circuit.exerciseName, 'Squat');
    expect(circuit.duration, const Duration(seconds: 40));
  });

  test('un cue corrotto non viene inventato', () {
    expect(
      () => WorkoutCue.fromJson({'type': 'countdown', 'seconds_remaining': 0}),
      throwsFormatException,
    );
    expect(
      () => WorkoutCue.fromJson({'type': 'future_unknown'}),
      throwsFormatException,
    );
  });

  test('essenziale parla negli ultimi tre secondi, non a dieci', () {
    const preferences = WorkoutCuePreferences(
      voice: VoiceGuidanceLevel.essential,
    );

    expect(
      preferences.shouldSpeak(const CountdownCue(secondsRemaining: 10)),
      isFalse,
    );
    expect(
      preferences.shouldSpeak(const CountdownCue(secondsRemaining: 3)),
      isTrue,
    );
    expect(preferences.shouldSpeak(const RestFinishedCue()), isTrue);
  });

  test('le frasi restano dati derivati e leggibili', () {
    final message = workoutCueMessage(
      const RestFinishedCue(nextExerciseName: 'Panca piana'),
    );

    expect(message.speech, 'Recupero finito. Tocca a Panca piana.');
    expect(message.notificationTitle, 'Recupero finito');
    expect(message.notificationBody, 'Ora: Panca piana');
  });
}
