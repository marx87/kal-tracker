import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';

/// Semi per lo storico allenamenti: righe vere, con i CHECK e le foreign key
/// del database acceso. Se una di queste insert smette di passare vuol dire
/// che lo schema ha cambiato idea, ed è un'informazione che vogliamo.

Future<String> seedProfile(AppDatabase database, {String id = 'marco'}) async {
  final now = DateTime.utc(2026, 8, 1);
  await database
      .into(database.appProfiles)
      .insert(
        AppProfilesCompanion.insert(
          id: id,
          displayName: 'Marco',
          createdAt: now,
          updatedAt: now,
        ),
      );
  return id;
}

Future<void> seedRoutine(
  AppDatabase database, {
  required String id,
  required String profileId,
  String name = 'Giorno 1',
}) async {
  final now = DateTime.utc(2026, 8, 1);
  await database
      .into(database.routines)
      .insert(
        RoutinesCompanion.insert(
          id: id,
          profileId: profileId,
          name: name,
          createdAt: now,
          updatedAt: now,
        ),
      );
}

Future<void> seedExercise(
  AppDatabase database, {
  required String id,
  required String profileId,
  String name = 'Panca piana',
  String muscleGroup = 'petto',
  String trackingMode = 'weightReps',
}) async {
  final now = DateTime.utc(2026, 8, 1);
  await database
      .into(database.exercises)
      .insert(
        ExercisesCompanion.insert(
          id: id,
          profileId: profileId,
          name: name,
          muscleGroup: muscleGroup,
          trackingMode: trackingMode,
          createdAt: now,
          updatedAt: now,
        ),
      );
}

Future<void> seedWorkout(
  AppDatabase database, {
  required String id,
  required String profileId,
  required DateTime startedAt,
  DateTime? endedAt,
  int accumulatedPauseSeconds = 0,
  int? finalDurationSeconds,
  bool durationSuspect = false,
  String? routineId,
  String? routineExternalId,
  String? routineName,
  String? notes,
  double? totalKcal,
  int? mood,
  int? rpe,
  int? satisfaction,
  String? feedbackNotes,
  int? xpEarned,
}) async {
  final now = DateTime.utc(2026, 8, 5);
  await database
      .into(database.workouts)
      .insert(
        WorkoutsCompanion.insert(
          id: id,
          profileId: profileId,
          startedAt: startedAt,
          endedAt: Value(endedAt),
          accumulatedPauseSeconds: Value(accumulatedPauseSeconds),
          finalDurationSeconds: Value(finalDurationSeconds),
          durationSuspect: Value(durationSuspect),
          routineId: Value(routineId),
          routineExternalId: Value(routineExternalId ?? routineId),
          routineNameSnapshot: Value(routineName),
          notes: Value(notes),
          totalKcal: Value(totalKcal),
          mood: Value(mood),
          rpe: Value(rpe),
          satisfaction: Value(satisfaction),
          feedbackNotes: Value(feedbackNotes),
          xpEarned: Value(xpEarned),
          createdAt: now,
          updatedAt: now,
        ),
      );
}

Future<void> seedWorkoutExercise(
  AppDatabase database, {
  required String id,
  required String workoutId,
  required int position,
  required String name,
  String? exerciseRefId,
  String? exerciseId,
  String trackingMode = 'weightReps',
  String? muscleGroup,
  int? restSeconds,
  bool isWarmup = false,
  bool isCooldown = false,
  bool isFinisher = false,
  bool inSupersetWithPrevious = false,
  int? intervalSegmentIndex,
}) async {
  await database
      .into(database.workoutExercises)
      .insert(
        WorkoutExercisesCompanion.insert(
          id: id,
          workoutId: workoutId,
          position: position,
          // L'id originale c'è sempre; la FK viva solo se l'esercizio esiste
          // ancora in catalogo, e il CHECK impone che siano lo stesso valore.
          exerciseRefId: exerciseRefId ?? id,
          exerciseId: Value(exerciseId),
          exerciseNameSnapshot: name,
          trackingMode: trackingMode,
          muscleGroupSnapshot: Value(muscleGroup),
          restSeconds: Value(restSeconds),
          isWarmup: Value(isWarmup),
          isCooldown: Value(isCooldown),
          isFinisher: Value(isFinisher),
          isInSupersetWithPrevious: Value(inSupersetWithPrevious),
          intervalSegmentIndex: Value(intervalSegmentIndex),
        ),
      );
}

Future<void> seedSet(
  AppDatabase database, {
  required String id,
  required String workoutExerciseId,
  required int position,
  double? weightKg,
  int? reps,
  int? durationSec,
  double? distanceM,
  int? rpe,
  bool isWarmup = false,
  bool completed = true,
}) async {
  await database
      .into(database.workoutSets)
      .insert(
        WorkoutSetsCompanion.insert(
          id: id,
          workoutExerciseId: workoutExerciseId,
          position: position,
          weightKg: Value(weightKg),
          reps: Value(reps),
          durationSec: Value(durationSec),
          distanceM: Value(distanceM),
          rpe: Value(rpe),
          isWarmup: Value(isWarmup),
          completed: Value(completed),
        ),
      );
}

Future<void> seedCircuitMarker(
  AppDatabase database, {
  required String id,
  required String workoutId,
  required int segmentIndex,
  bool completed = false,
  bool partial = false,
}) async {
  await database
      .into(database.workoutIntervalSegments)
      .insert(
        WorkoutIntervalSegmentsCompanion.insert(
          id: id,
          workoutId: workoutId,
          segmentIndex: segmentIndex,
          completedMarker: Value(completed),
          partialMarker: Value(partial),
        ),
      );
}

Future<void> seedPainPoint(
  AppDatabase database, {
  required String id,
  required String workoutId,
  required String label,
}) async {
  await database
      .into(database.workoutPainPoints)
      .insert(
        WorkoutPainPointsCompanion.insert(
          id: id,
          workoutId: workoutId,
          label: label,
        ),
      );
}
