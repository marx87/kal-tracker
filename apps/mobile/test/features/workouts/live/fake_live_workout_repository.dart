import 'package:kal_tracker/features/workouts/domain/kcal_estimator.dart';
import 'package:kal_tracker/features/workouts/domain/live_workout_repository.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';

/// Un repository finto che si comporta come il database VERO sulle due cose
/// che contano: una sola sessione aperta per profilo, e ogni scrittura
/// registrata così da poterla contare.
///
/// Non è un mock generato: la superficie è piccola e scritta a mano si legge.
class FakeLiveWorkoutRepository implements LiveWorkoutRepository {
  FakeLiveWorkoutRepository({
    Workout? initial,
    this.closedHistory = const [],
    this.bodyWeights = const [],
  }) {
    if (initial != null) _workouts[initial.id] = initial;
  }

  final Map<String, Workout> _workouts = {};
  final List<Workout> closedHistory;
  final List<BodyWeightSample> bodyWeights;

  /// Ogni istantanea passata a `saveWorkout`, in ordine.
  final List<Workout> saved = [];
  final List<Workout> circuitCommits = [];

  /// L'istantanea di chiusura, se è arrivata.
  Workout? finalized;

  final List<({DateTime? pausedAt, int accumulated})> pauseWrites = [];
  final List<({String? resumePath, Map<String, dynamic>? checkpoint})>
  resumeWrites = [];

  /// Fa fallire la prossima `saveWorkout`: serve a verificare che la
  /// schermata torni indietro invece di mostrare una serie che non c'è.
  bool failNextSave = false;

  /// Fa fallire `finalizeWorkout`.
  bool failFinalize = false;

  /// Fa fallire il commit atomico di una fase, senza cambiare né righe né
  /// checkpoint: riproduce il rollback della transazione Drift.
  bool failCircuitCommit = false;

  Workout? get current => _workouts.values.firstOrNull;

  @override
  Future<Workout?> activeWorkout() async {
    for (final workout in _workouts.values) {
      if (workout.endedAt == null) return workout;
    }
    return null;
  }

  @override
  Future<Workout> startWorkout({
    String? routineId,
    String? routineName,
    required List<WorkoutExercise> exercises,
  }) async {
    final open = await activeWorkout();
    // Come l'indice unico parziale: la seconda apertura non passa.
    if (open != null) throw ActiveWorkoutAlreadyOpen(open);
    final workout = Workout(
      id: 'w${_workouts.length + 1}',
      startedAt: DateTime.now(),
      routineId: routineId,
      routineName: routineName,
      exercises: exercises,
    );
    _workouts[workout.id] = workout;
    return workout;
  }

  @override
  Future<Workout?> getById(String workoutId) async => _workouts[workoutId];

  @override
  Future<void> saveWorkout(Workout workout) async {
    if (failNextSave) {
      failNextSave = false;
      throw StateError('scrittura fallita');
    }
    saved.add(workout);
    _workouts[workout.id] = workout;
  }

  @override
  Future<void> commitCircuitPhase(Workout workout) async {
    if (failCircuitCommit) {
      throw StateError('commit circuito fallito');
    }
    final committed = workout.copyWith(clearResumeState: true);
    circuitCommits.add(committed);
    _workouts[workout.id] = committed;
  }

  @override
  Future<void> finalizeWorkout(Workout snapshot) async {
    if (failFinalize) throw StateError('chiusura fallita');
    finalized = snapshot;
    _workouts[snapshot.id] = snapshot;
  }

  @override
  Future<void> updatePauseState(
    String workoutId, {
    required DateTime? pausedAt,
    required int accumulatedPauseSeconds,
  }) async {
    pauseWrites.add((pausedAt: pausedAt, accumulated: accumulatedPauseSeconds));
    final workout = _workouts[workoutId];
    if (workout == null) return;
    _workouts[workoutId] = workout.copyWith(
      pausedAt: pausedAt,
      accumulatedPauseSeconds: accumulatedPauseSeconds,
      clearPausedAt: pausedAt == null,
    );
  }

  @override
  Future<void> updateResumeState(
    String workoutId, {
    required String? resumePath,
    required Map<String, dynamic>? circuitCheckpoint,
  }) async {
    resumeWrites.add((resumePath: resumePath, checkpoint: circuitCheckpoint));
    final workout = _workouts[workoutId];
    if (workout == null) return;
    _workouts[workoutId] = workout.copyWith(
      resumePath: resumePath,
      circuitCheckpoint: circuitCheckpoint,
      clearResumeState: resumePath == null && circuitCheckpoint == null,
    );
  }

  @override
  Future<List<Workout>> recentClosedWorkouts({int limit = 200}) async =>
      closedHistory;

  @override
  Future<List<BodyWeightSample>> recentBodyWeights({int limit = 10}) async =>
      bodyWeights;
}
