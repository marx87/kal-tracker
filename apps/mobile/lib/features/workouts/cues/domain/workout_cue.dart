import 'package:flutter/foundation.dart';

/// Quanto è importante interrompere il silenzio per questo evento.
enum WorkoutCueImportance { detail, essential, critical }

/// Le fasi che un circuito può annunciare senza dipendere dal widget che le
/// mostra.
enum WorkoutCircuitPhase { work, recovery, transition, completed }

/// Un fatto dell'allenamento che può diventare voce, vibrazione o notifica.
///
/// Gli eventi sono dati di dominio, non frasi già pronte. In questo modo la UI
/// può emettere `RestFinishedCue` e lasciare a un solo traduttore la scelta di
/// parole, segnali e priorità.
@immutable
sealed class WorkoutCue {
  const WorkoutCue();

  String get type;
  WorkoutCueImportance get importance;
  Map<String, Object?> get data;

  Map<String, Object?> toJson() => <String, Object?>{'type': type, ...data};

  static WorkoutCue fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('Il cue deve essere un oggetto JSON.');
    }
    final json = value.cast<String, Object?>();
    return switch (_requiredString(json, 'type')) {
      WorkoutStartedCue.typeName => WorkoutStartedCue(
        workoutName: _optionalString(json, 'workout_name'),
      ),
      SetCompletedCue.typeName => SetCompletedCue(
        exerciseName: _requiredString(json, 'exercise_name'),
        setNumber: _requiredPositiveInt(json, 'set_number'),
        totalSets: _optionalPositiveInt(json, 'total_sets'),
      ),
      NextSetCue.typeName => NextSetCue(
        exerciseName: _requiredString(json, 'exercise_name'),
        setNumber: _optionalPositiveInt(json, 'set_number'),
        totalSets: _optionalPositiveInt(json, 'total_sets'),
      ),
      RestStartedCue.typeName => RestStartedCue(
        duration: Duration(
          seconds: _requiredPositiveInt(json, 'duration_seconds'),
        ),
        nextExerciseName: _optionalString(json, 'next_exercise_name'),
      ),
      CountdownCue.typeName => CountdownCue(
        secondsRemaining: _requiredPositiveInt(json, 'seconds_remaining'),
      ),
      RestFinishedCue.typeName => RestFinishedCue(
        nextExerciseName: _optionalString(json, 'next_exercise_name'),
      ),
      CircuitPhaseCue.typeName => CircuitPhaseCue(
        phase: _enumValue(
          WorkoutCircuitPhase.values,
          _requiredString(json, 'phase'),
          'phase',
        ),
        exerciseName: _optionalString(json, 'exercise_name'),
        duration: _optionalDuration(json, 'duration_seconds'),
      ),
      PersonalRecordCue.typeName => PersonalRecordCue(
        exerciseName: _requiredString(json, 'exercise_name'),
        summary: _optionalString(json, 'summary'),
      ),
      WorkoutPausedCue.typeName => const WorkoutPausedCue(),
      WorkoutResumedCue.typeName => const WorkoutResumedCue(),
      WorkoutCompletedCue.typeName => WorkoutCompletedCue(
        workoutName: _optionalString(json, 'workout_name'),
      ),
      final unknown => throw FormatException('Tipo cue sconosciuto: $unknown'),
    };
  }
}

final class WorkoutStartedCue extends WorkoutCue {
  const WorkoutStartedCue({this.workoutName});

  static const typeName = 'workout_started';
  final String? workoutName;

  @override
  String get type => typeName;

  @override
  WorkoutCueImportance get importance => WorkoutCueImportance.essential;

  @override
  Map<String, Object?> get data => {'workout_name': workoutName};
}

final class SetCompletedCue extends WorkoutCue {
  const SetCompletedCue({
    required this.exerciseName,
    required this.setNumber,
    this.totalSets,
  }) : assert(setNumber > 0),
       assert(totalSets == null || totalSets > 0);

  static const typeName = 'set_completed';
  final String exerciseName;
  final int setNumber;
  final int? totalSets;

  @override
  String get type => typeName;

  @override
  WorkoutCueImportance get importance => WorkoutCueImportance.detail;

  @override
  Map<String, Object?> get data => {
    'exercise_name': exerciseName,
    'set_number': setNumber,
    'total_sets': totalSets,
  };
}

final class NextSetCue extends WorkoutCue {
  const NextSetCue({required this.exerciseName, this.setNumber, this.totalSets})
    : assert(setNumber == null || setNumber > 0),
      assert(totalSets == null || totalSets > 0);

  static const typeName = 'next_set';
  final String exerciseName;
  final int? setNumber;
  final int? totalSets;

  @override
  String get type => typeName;

  @override
  WorkoutCueImportance get importance => WorkoutCueImportance.essential;

  @override
  Map<String, Object?> get data => {
    'exercise_name': exerciseName,
    'set_number': setNumber,
    'total_sets': totalSets,
  };
}

final class RestStartedCue extends WorkoutCue {
  const RestStartedCue({required this.duration, this.nextExerciseName});

  static const typeName = 'rest_started';
  final Duration duration;
  final String? nextExerciseName;

  @override
  String get type => typeName;

  @override
  WorkoutCueImportance get importance => WorkoutCueImportance.detail;

  @override
  Map<String, Object?> get data => {
    'duration_seconds': duration.inSeconds,
    'next_exercise_name': nextExerciseName,
  };
}

final class CountdownCue extends WorkoutCue {
  const CountdownCue({required this.secondsRemaining})
    : assert(secondsRemaining > 0);

  static const typeName = 'countdown';
  final int secondsRemaining;

  @override
  String get type => typeName;

  @override
  WorkoutCueImportance get importance => secondsRemaining <= 3
      ? WorkoutCueImportance.essential
      : WorkoutCueImportance.detail;

  @override
  Map<String, Object?> get data => {'seconds_remaining': secondsRemaining};
}

final class RestFinishedCue extends WorkoutCue {
  const RestFinishedCue({this.nextExerciseName});

  static const typeName = 'rest_finished';
  final String? nextExerciseName;

  @override
  String get type => typeName;

  @override
  WorkoutCueImportance get importance => WorkoutCueImportance.critical;

  @override
  Map<String, Object?> get data => {'next_exercise_name': nextExerciseName};
}

final class CircuitPhaseCue extends WorkoutCue {
  const CircuitPhaseCue({
    required this.phase,
    this.exerciseName,
    this.duration,
  });

  static const typeName = 'circuit_phase';
  final WorkoutCircuitPhase phase;
  final String? exerciseName;
  final Duration? duration;

  @override
  String get type => typeName;

  @override
  WorkoutCueImportance get importance => phase == WorkoutCircuitPhase.completed
      ? WorkoutCueImportance.critical
      : WorkoutCueImportance.essential;

  @override
  Map<String, Object?> get data => {
    'phase': phase.name,
    'exercise_name': exerciseName,
    'duration_seconds': duration?.inSeconds,
  };
}

final class PersonalRecordCue extends WorkoutCue {
  const PersonalRecordCue({required this.exerciseName, this.summary});

  static const typeName = 'personal_record';
  final String exerciseName;
  final String? summary;

  @override
  String get type => typeName;

  @override
  WorkoutCueImportance get importance => WorkoutCueImportance.critical;

  @override
  Map<String, Object?> get data => {
    'exercise_name': exerciseName,
    'summary': summary,
  };
}

final class WorkoutPausedCue extends WorkoutCue {
  const WorkoutPausedCue();

  static const typeName = 'workout_paused';

  @override
  String get type => typeName;

  @override
  WorkoutCueImportance get importance => WorkoutCueImportance.essential;

  @override
  Map<String, Object?> get data => const {};
}

final class WorkoutResumedCue extends WorkoutCue {
  const WorkoutResumedCue();

  static const typeName = 'workout_resumed';

  @override
  String get type => typeName;

  @override
  WorkoutCueImportance get importance => WorkoutCueImportance.essential;

  @override
  Map<String, Object?> get data => const {};
}

final class WorkoutCompletedCue extends WorkoutCue {
  const WorkoutCompletedCue({this.workoutName});

  static const typeName = 'workout_completed';
  final String? workoutName;

  @override
  String get type => typeName;

  @override
  WorkoutCueImportance get importance => WorkoutCueImportance.critical;

  @override
  Map<String, Object?> get data => {'workout_name': workoutName};
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = _optionalString(json, key);
  if (value == null) throw FormatException('$key mancante o vuoto.');
  return value;
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key deve essere testo.');
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int _requiredPositiveInt(Map<String, Object?> json, String key) {
  final value = _optionalPositiveInt(json, key);
  if (value == null) throw FormatException('$key deve essere positivo.');
  return value;
}

int? _optionalPositiveInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! num || value.toInt() != value || value <= 0) {
    throw FormatException('$key deve essere un intero positivo.');
  }
  return value.toInt();
}

Duration? _optionalDuration(Map<String, Object?> json, String key) {
  final seconds = _optionalPositiveInt(json, key);
  return seconds == null ? null : Duration(seconds: seconds);
}

T _enumValue<T extends Enum>(List<T> values, String name, String key) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw FormatException('$key non riconosciuto: $name');
}
