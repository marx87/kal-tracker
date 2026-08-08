import 'package:flutter/foundation.dart';
import 'package:kal_tracker/features/workouts/domain/load_progression.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';

/// La proposta mostrata mentre si esegue l'esercizio.
///
/// Non inventa una progressione propria: traduce il verdetto già prodotto da
/// [LoadProgression] in valori applicabili alle sole serie ancora da fare.
@immutable
class LiveLoadGuidance {
  const LiveLoadGuidance({
    required this.verdict,
    required this.reason,
    required this.sourceSets,
    this.lastWeightKg,
    this.lastReps,
    this.lastRpe,
    this.proposedWeightKg,
    this.proposedReps,
  });

  final ProgressionVerdict verdict;
  final String reason;
  final int sourceSets;
  final double? lastWeightKg;
  final int? lastReps;
  final int? lastRpe;
  final double? proposedWeightKg;
  final int? proposedReps;

  bool get hasHistory => sourceSets > 0;
  bool get canApply => proposedWeightKg != null || proposedReps != null;
  bool get isProgression => verdict == ProgressionVerdict.salire;

  /// Costruisce la proposta usando l'ultima seduta e il piano di oggi.
  ///
  /// Il carico di riferimento è il più leggero fra le serie completate: è lo
  /// stesso criterio prudente del motore di doppia progressione, perché il
  /// numero deve essere sostenibile anche nell'ultima serie.
  static LiveLoadGuidance from({
    required List<WorkoutSet> lastSets,
    required List<WorkoutSet> plannedSets,
    required LoadProgressionAdvice advice,
  }) {
    final completed = lastSets
        .where((set) => set.completed && !set.isWarmup)
        .toList(growable: false);
    final weighted = completed
        .where((set) => set.weightKg != null && set.weightKg! > 0)
        .toList(growable: false);
    final repeated = completed
        .where((set) => set.reps != null && set.reps! > 0)
        .toList(growable: false);
    final exerted = completed
        .where((set) => set.rpe != null)
        .toList(growable: false);

    final lastWeight = weighted.isEmpty
        ? null
        : weighted
              .map((set) => set.weightKg!)
              .reduce((left, right) => left < right ? left : right);
    final lastReps = repeated.isEmpty ? null : repeated.first.reps;
    final lastRpe = exerted.isEmpty
        ? null
        : exerted
              .map((set) => set.rpe!)
              .reduce((left, right) => left > right ? left : right);
    final plannedReps = plannedSets
        .where((set) => !set.isWarmup && !set.completed && set.reps != null)
        .map((set) => set.reps)
        .firstOrNull;

    return LiveLoadGuidance(
      verdict: advice.verdict,
      reason: advice.reason,
      sourceSets: completed.length,
      lastWeightKg: lastWeight,
      lastReps: lastReps,
      lastRpe: lastRpe,
      proposedWeightKg: advice.proposedKg ?? advice.currentKg ?? lastWeight,
      proposedReps: advice.proposedReps ?? plannedReps ?? lastReps,
    );
  }

  /// Applica la scelta esplicita alle sole serie di lavoro non completate.
  /// Riscaldamento e risultati già registrati non vengono mai riscritti.
  WorkoutExercise applyToRemaining(WorkoutExercise exercise) {
    if (!canApply) return exercise;
    return exercise.copyWith(
      sets: [
        for (final set in exercise.sets)
          if (set.completed || set.isWarmup)
            set
          else
            set.copyWith(weightKg: proposedWeightKg, reps: proposedReps),
      ],
    );
  }
}
