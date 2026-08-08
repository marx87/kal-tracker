import 'package:kal_tracker/features/workouts/cues/domain/workout_cue.dart';

/// Le due superfici dello stesso evento: frase parlata e notifica di sistema.
class WorkoutCueMessage {
  const WorkoutCueMessage({
    required this.speech,
    required this.notificationTitle,
    required this.notificationBody,
  });

  final String speech;
  final String notificationTitle;
  final String notificationBody;
}

WorkoutCueMessage workoutCueMessage(WorkoutCue cue) => switch (cue) {
  WorkoutStartedCue(:final workoutName) => WorkoutCueMessage(
    speech: workoutName == null
        ? 'Allenamento iniziato.'
        : 'Allenamento $workoutName iniziato.',
    notificationTitle: 'Allenamento iniziato',
    notificationBody: workoutName ?? 'Coach360 è pronto.',
  ),
  SetCompletedCue(:final exerciseName, :final setNumber, :final totalSets) =>
    WorkoutCueMessage(
      speech:
          '$exerciseName, serie $setNumber${totalSets == null ? '' : ' di $totalSets'} completata.',
      notificationTitle: 'Serie completata',
      notificationBody: '$exerciseName · serie $setNumber',
    ),
  NextSetCue(:final exerciseName, :final setNumber) => WorkoutCueMessage(
    speech: setNumber == null
        ? 'Adesso $exerciseName.'
        : 'Adesso $exerciseName, serie $setNumber.',
    notificationTitle: 'Prossima serie',
    notificationBody: setNumber == null
        ? exerciseName
        : '$exerciseName · serie $setNumber',
  ),
  RestStartedCue(:final duration, :final nextExerciseName) => WorkoutCueMessage(
    speech:
        'Recupero, ${_durationLabel(duration)}.${nextExerciseName == null ? '' : ' Poi $nextExerciseName.'}',
    notificationTitle: 'Recupero in corso',
    notificationBody:
        '${_durationLabel(duration)}${nextExerciseName == null ? '' : ' · poi $nextExerciseName'}',
  ),
  CountdownCue(:final secondsRemaining) => WorkoutCueMessage(
    speech: '$secondsRemaining',
    notificationTitle: 'Recupero',
    notificationBody: '$secondsRemaining secondi',
  ),
  RestFinishedCue(:final nextExerciseName) => WorkoutCueMessage(
    speech:
        'Recupero finito.${nextExerciseName == null ? '' : ' Tocca a $nextExerciseName.'}',
    notificationTitle: 'Recupero finito',
    notificationBody: nextExerciseName == null
        ? 'Riparti quando sei pronto.'
        : 'Ora: $nextExerciseName',
  ),
  CircuitPhaseCue(:final phase, :final exerciseName, :final duration) =>
    _circuitMessage(phase, exerciseName, duration),
  PersonalRecordCue(:final exerciseName, :final summary) => WorkoutCueMessage(
    speech:
        'Nuovo record su $exerciseName.${summary == null ? '' : ' $summary'}',
    notificationTitle: 'Nuovo record',
    notificationBody: summary ?? exerciseName,
  ),
  WorkoutPausedCue() => const WorkoutCueMessage(
    speech: 'Allenamento in pausa.',
    notificationTitle: 'Allenamento in pausa',
    notificationBody: 'La sessione resta salvata.',
  ),
  WorkoutResumedCue() => const WorkoutCueMessage(
    speech: 'Allenamento ripreso.',
    notificationTitle: 'Allenamento ripreso',
    notificationBody: 'Si continua.',
  ),
  WorkoutCompletedCue(:final workoutName) => WorkoutCueMessage(
    speech: workoutName == null
        ? 'Allenamento completato. Ottimo lavoro.'
        : '$workoutName completato. Ottimo lavoro.',
    notificationTitle: 'Allenamento completato',
    notificationBody: workoutName ?? 'Ottimo lavoro.',
  ),
};

WorkoutCueMessage _circuitMessage(
  WorkoutCircuitPhase phase,
  String? exercise,
  Duration? duration,
) {
  final timing = duration == null ? '' : ' per ${_durationLabel(duration)}';
  return switch (phase) {
    WorkoutCircuitPhase.work => WorkoutCueMessage(
      speech: exercise == null
          ? 'Via, lavoro$timing.'
          : 'Via, $exercise$timing.',
      notificationTitle: 'Circuito: lavoro',
      notificationBody: exercise ?? 'Via.',
    ),
    WorkoutCircuitPhase.recovery => WorkoutCueMessage(
      speech: 'Recupero$timing.',
      notificationTitle: 'Circuito: recupero',
      notificationBody: duration == null
          ? 'Respira.'
          : _durationLabel(duration),
    ),
    WorkoutCircuitPhase.transition => WorkoutCueMessage(
      speech: exercise == null ? 'Cambio stazione.' : 'Cambio. Poi $exercise.',
      notificationTitle: 'Cambio stazione',
      notificationBody: exercise ?? 'Preparati al prossimo esercizio.',
    ),
    WorkoutCircuitPhase.completed => const WorkoutCueMessage(
      speech: 'Circuito completato.',
      notificationTitle: 'Circuito completato',
      notificationBody: 'Ottimo lavoro.',
    ),
  };
}

String _durationLabel(Duration duration) {
  final seconds = duration.inSeconds;
  if (seconds < 60) return '$seconds secondi';
  final minutes = seconds ~/ 60;
  final remainder = seconds % 60;
  if (remainder == 0) {
    return '$minutes ${minutes == 1 ? 'minuto' : 'minuti'}';
  }
  return '$minutes ${minutes == 1 ? 'minuto' : 'minuti'} e $remainder secondi';
}
