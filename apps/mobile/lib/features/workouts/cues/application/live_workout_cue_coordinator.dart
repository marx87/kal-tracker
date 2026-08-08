import 'package:kal_tracker/features/workouts/cues/application/workout_cue_engine.dart';
import 'package:kal_tracker/features/workouts/cues/data/workout_cue_store.dart';
import 'package:kal_tracker/features/workouts/cues/domain/workout_cue.dart';

// ignore_for_file: prefer_initializing_formals

/// Traduce i gesti della sessione live negli eventi del motore di guida.
///
/// Tiene fuori dalla schermata gli ID durevoli del recupero e la sequenza
/// emit/schedule/cancel. L'audio resta sempre accessorio: ogni metodo può
/// essere lanciato senza attenderlo e non modifica mai il salvataggio workout.
class LiveWorkoutCueCoordinator {
  // Il parametro pubblico resta `engine`: esporre `this._engine` renderebbe
  // il costruttore inutilizzabile fuori dalla libreria.
  LiveWorkoutCueCoordinator({
    required WorkoutCueEngine engine,
    required this.workoutId,
  }) : _engine = engine;

  final WorkoutCueEngine _engine;
  final String workoutId;

  String get restCueId => 'rest:$workoutId';

  Future<void> activate({String? workoutName, bool resumed = false}) async {
    await _engine.initialize();
    await _engine.setSessionActive(true);
    await _engine.emit(
      resumed
          ? const WorkoutResumedCue()
          : WorkoutStartedCue(workoutName: workoutName),
    );
  }

  Future<void> deactivate({bool stopVoice = true}) async {
    await _engine.setSessionActive(false);
    if (stopVoice) await _engine.stopVoice();
  }

  /// La scadenza sopravvissuta a sospensione o riavvio del processo.
  Future<DateTime?> restoreRestDeadline() async {
    await _engine.initialize();
    await _engine.synchronize();
    final pending = _engine.pending.where((cue) => cue.id == restCueId);
    if (pending.isEmpty) return null;
    // [synchronize] ha già eliminato le scadenze non future usando lo stesso
    // orologio dell'engine (sostituibile nei test).
    return pending.first.deadline;
  }

  String? get pendingRestNextExerciseName {
    for (final scheduled in _engine.pending) {
      if (scheduled.id != restCueId) continue;
      final cue = scheduled.cue;
      if (cue is RestFinishedCue) return cue.nextExerciseName;
    }
    return null;
  }

  Future<void> setCompleted({
    required String exerciseName,
    required int setNumber,
    required int totalSets,
  }) => _engine.emit(
    SetCompletedCue(
      exerciseName: exerciseName,
      setNumber: setNumber,
      totalSets: totalSets,
    ),
  );

  Future<void> nextSet({
    required String exerciseName,
    int? setNumber,
    int? totalSets,
  }) => _engine.emit(
    NextSetCue(
      exerciseName: exerciseName,
      setNumber: setNumber,
      totalSets: totalSets,
    ),
  );

  Future<void> startRest({
    required Duration duration,
    required DateTime deadline,
    String? nextExerciseName,
  }) async {
    await _engine.emit(
      RestStartedCue(duration: duration, nextExerciseName: nextExerciseName),
    );
    await _engine.scheduleCountdown(
      id: restCueId,
      deadline: deadline,
      completionCue: RestFinishedCue(nextExerciseName: nextExerciseName),
    );
  }

  /// Sposta una scadenza dopo un «+15 / −15» senza ripetere a voce
  /// l'annuncio iniziale del recupero.
  Future<void> rescheduleRest({
    required DateTime deadline,
    String? nextExerciseName,
  }) => _engine.scheduleCountdown(
    id: restCueId,
    deadline: deadline,
    completionCue: RestFinishedCue(nextExerciseName: nextExerciseName),
  );

  /// «Riparti ora»: elimina la notifica vecchia e consegna subito lo stesso
  /// cue che sarebbe arrivato alla scadenza naturale.
  Future<void> finishRestNow({String? nextExerciseName}) async {
    await cancelRest();
    await _engine.emit(RestFinishedCue(nextExerciseName: nextExerciseName));
  }

  Future<void> cancelRest() => _engine.cancelScheduled(restCueId);

  Future<void> personalRecord({
    required String exerciseName,
    String? summary,
  }) => _engine.emit(
    PersonalRecordCue(exerciseName: exerciseName, summary: summary),
  );

  Future<void> paused() => _engine.emit(const WorkoutPausedCue());

  Future<void> resumed() => _engine.emit(const WorkoutResumedCue());

  Future<void> completed({String? workoutName}) async {
    await cancelRest();
    await _engine.emit(WorkoutCompletedCue(workoutName: workoutName));
    await deactivate(stopVoice: false);
  }

  List<ScheduledWorkoutCue> get pending => _engine.pending;
}
