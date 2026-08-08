import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:kal_tracker/features/workouts/cues/domain/workout_cue.dart';
import 'package:kal_tracker/features/workouts/cues/domain/workout_cue_preferences.dart';
import 'package:path_provider/path_provider.dart';

@immutable
class ScheduledWorkoutCue {
  ScheduledWorkoutCue({
    required this.id,
    required this.cue,
    required this.deadline,
    required this.notificationId,
    Iterable<int> countdownSeconds = const <int>[],
  }) : assert(id != ''),
       assert(notificationId >= 0),
       countdownSeconds = Set.unmodifiable(
         countdownSeconds.where((seconds) => seconds > 0),
       );

  final String id;
  final WorkoutCue cue;
  final DateTime deadline;
  final int notificationId;
  final Set<int> countdownSeconds;

  Map<String, Object?> toJson() => {
    'id': id,
    'cue': cue.toJson(),
    'deadline': deadline.toUtc().toIso8601String(),
    'notification_id': notificationId,
    'countdown_seconds': countdownSeconds.toList()..sort((a, b) => b - a),
  };

  factory ScheduledWorkoutCue.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('Il cue pianificato deve essere un oggetto.');
    }
    final json = value.cast<String, Object?>();
    final id = json['id'];
    final deadline = json['deadline'];
    final notificationId = json['notification_id'];
    if (id is! String || id.trim().isEmpty) {
      throw const FormatException('Id del cue pianificato mancante.');
    }
    if (deadline is! String) {
      throw const FormatException('Scadenza del cue pianificato mancante.');
    }
    if (notificationId is! int || notificationId < 0) {
      throw const FormatException('Id notifica del cue non valido.');
    }
    final parsedDeadline = DateTime.tryParse(deadline);
    if (parsedDeadline == null) {
      throw const FormatException('Scadenza del cue non valida.');
    }
    final countdown = switch (json['countdown_seconds']) {
      final List values =>
        values
            .whereType<num>()
            .map((item) => item.toInt())
            .where((seconds) => seconds > 0)
            .toSet(),
      _ => const <int>{},
    };
    return ScheduledWorkoutCue(
      id: id.trim(),
      cue: WorkoutCue.fromJson(json['cue']),
      deadline: parsedDeadline.toUtc(),
      notificationId: notificationId,
      countdownSeconds: countdown,
    );
  }
}

@immutable
class WorkoutCuePersistentState {
  WorkoutCuePersistentState({
    this.preferences = const WorkoutCuePreferences(),
    Iterable<ScheduledWorkoutCue> pending = const <ScheduledWorkoutCue>[],
  }) : pending = List.unmodifiable(pending);

  static const schemaVersion = 1;

  final WorkoutCuePreferences preferences;
  final List<ScheduledWorkoutCue> pending;

  Map<String, Object?> toJson() => {
    'schema': schemaVersion,
    'preferences': preferences.toJson(),
    'pending': pending.map((cue) => cue.toJson()).toList(),
  };

  factory WorkoutCuePersistentState.fromJson(Object? value) {
    if (value is! Map) return WorkoutCuePersistentState();
    final json = value.cast<String, Object?>();
    if (json['schema'] != schemaVersion) return WorkoutCuePersistentState();
    final pending = <ScheduledWorkoutCue>[];
    if (json['pending'] case final List values) {
      for (final value in values) {
        try {
          pending.add(ScheduledWorkoutCue.fromJson(value));
        } on FormatException {
          // Una riga rotta non deve cancellare le altre scadenze valide.
        }
      }
    }
    return WorkoutCuePersistentState(
      preferences: WorkoutCuePreferences.fromJson(json['preferences']),
      pending: pending,
    );
  }
}

abstract interface class WorkoutCueStore {
  Future<WorkoutCuePersistentState> read();
  Future<void> write(WorkoutCuePersistentState state);
}

/// File piccolo e indipendente da Drift: sopravvive a processo e riavvio.
class FileWorkoutCueStore implements WorkoutCueStore {
  FileWorkoutCueStore({
    Future<Directory> Function()? directory,
    this.fileName = 'workout-cues-v1.json',
  }) : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;
  final String fileName;

  @override
  Future<WorkoutCuePersistentState> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return WorkoutCuePersistentState();
      return WorkoutCuePersistentState.fromJson(
        jsonDecode(await file.readAsString()),
      );
    } on FileSystemException {
      return WorkoutCuePersistentState();
    } on FormatException {
      return WorkoutCuePersistentState();
    }
  }

  @override
  Future<void> write(WorkoutCuePersistentState state) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(state.toJson()), flush: true);
  }

  Future<File> _file() async {
    final directory = await _directory();
    return File('${directory.path}/$fileName');
  }
}

class InMemoryWorkoutCueStore implements WorkoutCueStore {
  InMemoryWorkoutCueStore([WorkoutCuePersistentState? initial])
    : state = initial ?? WorkoutCuePersistentState();

  WorkoutCuePersistentState state;

  @override
  Future<WorkoutCuePersistentState> read() async => state;

  @override
  Future<void> write(WorkoutCuePersistentState state) async {
    this.state = state;
  }
}
