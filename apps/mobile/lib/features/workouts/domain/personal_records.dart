/// I record personali (Epley 1RM, migliori carichi, conteggio dei PR).
/// COPIA VERBATIM di `features/workouts/personal_records.dart` di Gym
/// Tracker: cambia solo la riga di import.
///
/// `prCountFromHistory` alimenta i trofei pr_1/pr_10/pr_25 GIÀ SBLOCCATI:
/// qualunque modifica al conteggio riassegnerebbe bonus XP già dati. Per lo
/// stesso motivo i commenti restano in inglese, confrontabili col sorgente.
library;

import 'package:kal_tracker/features/workouts/domain/workout.dart';

/// Personal-record (PR) tracking — pure functions over the workout history,
/// shared by the live-workout celebration, the Records page and the PR
/// achievements.

/// Epley formula: 1RM ≈ weight × (1 + reps/30). Same estimate used by the
/// exercise detail chart and the in-workout hint.
double epley1Rm(double weightKg, int reps) => weightKg * (1 + reps / 30);

/// Best marks for one exercise.
class ExerciseRecord {
  final String exerciseId;
  final String exerciseName;
  final double bestWeight; // heaviest completed set
  final int repsAtBestWeight;
  final DateTime bestWeightDate;
  final double bestE1rm; // best Epley estimate
  final DateTime bestE1rmDate;

  const ExerciseRecord({
    required this.exerciseId,
    required this.exerciseName,
    required this.bestWeight,
    required this.repsAtBestWeight,
    required this.bestWeightDate,
    required this.bestE1rm,
    required this.bestE1rmDate,
  });
}

/// exerciseId → best marks, from completed non-warmup weighted sets.
/// [excludeWorkoutId] leaves the in-progress workout out of the baseline so
/// the live screen can compare "this set" against "everything before today".
Map<String, ExerciseRecord> recordsFromHistory(
  List<Workout> workouts, {
  String? excludeWorkoutId,
}) {
  final out = <String, ExerciseRecord>{};
  for (final w in workouts) {
    if (w.id == excludeWorkoutId) continue;
    for (final ex in w.exercises) {
      for (final s in ex.sets) {
        if (!s.completed || s.isWarmup) continue;
        final kg = s.weightKg;
        final reps = s.reps;
        if (kg == null || kg <= 0 || reps == null || reps <= 0) continue;
        final e1 = epley1Rm(kg, reps);
        final prev = out[ex.exerciseId];
        if (prev == null) {
          out[ex.exerciseId] = ExerciseRecord(
            exerciseId: ex.exerciseId,
            exerciseName: ex.exerciseName,
            bestWeight: kg,
            repsAtBestWeight: reps,
            bestWeightDate: w.startedAt,
            bestE1rm: e1,
            bestE1rmDate: w.startedAt,
          );
        } else {
          final heavier = kg > prev.bestWeight;
          final stronger = e1 > prev.bestE1rm;
          if (heavier || stronger) {
            out[ex.exerciseId] = ExerciseRecord(
              exerciseId: prev.exerciseId,
              exerciseName: prev.exerciseName,
              bestWeight: heavier ? kg : prev.bestWeight,
              repsAtBestWeight: heavier ? reps : prev.repsAtBestWeight,
              bestWeightDate: heavier ? w.startedAt : prev.bestWeightDate,
              bestE1rm: stronger ? e1 : prev.bestE1rm,
              bestE1rmDate: stronger ? w.startedAt : prev.bestE1rmDate,
            );
          }
        }
      }
    }
  }
  return out;
}

/// Counts PR *events* chronologically: every completed weighted set that
/// beats the running best (weight or estimated 1RM) of its exercise counts
/// as one. The very first set of an exercise is the baseline, not a PR.
/// Used by the "Primo record / Da record / Macchina da PR" achievements.
int prCountFromHistory(List<Workout> workouts) {
  final sorted = workouts.where((w) => w.endedAt != null).toList()
    ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
  final bestW = <String, double>{};
  final bestE = <String, double>{};
  var count = 0;
  for (final w in sorted) {
    for (final ex in w.exercises) {
      for (final s in ex.sets) {
        if (!s.completed || s.isWarmup) continue;
        final kg = s.weightKg;
        final reps = s.reps;
        if (kg == null || kg <= 0 || reps == null || reps <= 0) continue;
        final e1 = epley1Rm(kg, reps);
        final pw = bestW[ex.exerciseId];
        final pe = bestE[ex.exerciseId];
        if (pw == null || pe == null) {
          bestW[ex.exerciseId] = kg;
          bestE[ex.exerciseId] = e1;
        } else if (kg > pw + 0.001 || e1 > pe + 0.001) {
          count++;
          if (kg > pw) bestW[ex.exerciseId] = kg;
          if (e1 > pe) bestE[ex.exerciseId] = e1;
        }
      }
    }
  }
  return count;
}

String formatKg(double v) =>
    v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
