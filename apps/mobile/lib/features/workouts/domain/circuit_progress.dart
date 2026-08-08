/// Il registro durevole dei blocchi a tempo: quali celle del circuito hanno
/// visto il countdown arrivare a zero, e la firma della configurazione con cui
/// erano state completate. COPIA VERBATIM di
/// `features/workouts/circuit_progress.dart` di Gym Tracker.
///
/// `circuitPhaseConfigSignature` produce un JSON canonico che finisce
/// VERBATIM in `workout_interval_segments.completion_signature`: il confronto
/// avviene contro firme già scritte, quindi il formato non è modificabile.
/// Commenti in inglese come nel sorgente, apposta.
library;

import 'dart:convert';

/// Durable record of timed circuit cells whose work countdown reached zero.
///
/// Keeping explicit round/step keys means an early exit never guesses from the
/// current cursor: a station in prep, in progress or skipped is not counted.
class CircuitCompletionTracker {
  CircuitCompletionTracker([Iterable<String> serialized = const []]) {
    restore(serialized);
  }

  final Set<String> _keys = {};

  void markCompleted({required int round, required int stepIndex}) {
    if (round < 1 || stepIndex < 0) return;
    _keys.add('$round:$stepIndex');
  }

  bool isCompleted({required int round, required int stepIndex}) =>
      round >= 1 && stepIndex >= 0 && _keys.contains('$round:$stepIndex');

  int completedRoundsForStep(int stepIndex) {
    if (stepIndex < 0) return 0;
    return _keys.where((key) {
      final separator = key.indexOf(':');
      if (separator <= 0 || separator == key.length - 1) return false;
      return int.tryParse(key.substring(separator + 1)) == stepIndex;
    }).length;
  }

  /// I round esatti completati per una stazione, in ordine crescente.
  ///
  /// Il solo conteggio non basta quando si riprende dopo un'uscita: se è
  /// stata saltata la cella del round 1 ma completata quella del round 2, va
  /// spuntata la seconda serie e non inventata la prima.
  List<int> completedRoundIndicesForStep(int stepIndex) {
    if (stepIndex < 0) return const [];
    final rounds = <int>[];
    for (final key in _keys) {
      final parts = key.split(':');
      if (parts.length != 2 || int.tryParse(parts[1]) != stepIndex) continue;
      final round = int.tryParse(parts[0]);
      if (round != null && round >= 1) rounds.add(round);
    }
    rounds.sort();
    return List.unmodifiable(rounds);
  }

  List<String> serialize() => _keys.toList()..sort();

  void restore(Iterable<String> serialized) {
    _keys
      ..clear()
      ..addAll(
        serialized.where((key) {
          final parts = key.split(':');
          if (parts.length != 2) return false;
          final round = int.tryParse(parts[0]);
          final step = int.tryParse(parts[1]);
          return round != null && round >= 1 && step != null && step >= 0;
        }),
      );
  }
}

int? nextPendingIntervalSegmentIndex({
  required int segmentCount,
  required Iterable<int> completedIndices,
  Map<int, String> completedSignatures = const {},
  Iterable<String>? currentSignatures,
}) {
  if (segmentCount <= 0) return null;
  final completed = completedIndices.toSet();
  final signatures = currentSignatures?.toList(growable: false);
  for (var index = 0; index < segmentCount; index++) {
    var isCurrentCompletion = completed.contains(index);
    if (isCurrentCompletion && signatures != null) {
      isCurrentCompletion =
          index < signatures.length &&
          isCurrentIntervalSegmentCompletion(
            markerPresent: true,
            storedSignature: completedSignatures[index],
            currentSignature: signatures[index],
          );
    }
    if (!isCurrentCompletion) return index;
  }
  return null;
}

bool isCurrentIntervalSegmentCompletion({
  required bool markerPresent,
  required String? storedSignature,
  required String currentSignature,
}) =>
    markerPresent &&
    (storedSignature == null || storedSignature == currentSignature);

enum CompletedIntervalSegmentStatus {
  committed,
  alreadyCommitted,
  partialExitPending,
  configurationChanged,
  workoutClosed,
}

enum PartialIntervalSegmentStatus {
  committed,
  alreadyPending,
  alreadyCompleted,
  configurationChanged,
  workoutClosed,
}

CompletedIntervalSegmentStatus decideCompletedIntervalSegmentStatus({
  required bool workoutClosed,
  required bool alreadyCompleted,
  required bool partialExitPending,
  required bool configurationMatches,
}) {
  if (workoutClosed) return CompletedIntervalSegmentStatus.workoutClosed;
  if (alreadyCompleted) {
    return CompletedIntervalSegmentStatus.alreadyCommitted;
  }
  if (partialExitPending) {
    return CompletedIntervalSegmentStatus.partialExitPending;
  }
  if (!configurationMatches) {
    return CompletedIntervalSegmentStatus.configurationChanged;
  }
  return CompletedIntervalSegmentStatus.committed;
}

PartialIntervalSegmentStatus decidePartialIntervalSegmentStatus({
  required bool workoutClosed,
  required bool alreadyCompleted,
  required bool partialExitPending,
  required bool configurationMatches,
}) {
  if (workoutClosed) return PartialIntervalSegmentStatus.workoutClosed;
  if (alreadyCompleted) {
    return PartialIntervalSegmentStatus.alreadyCompleted;
  }
  if (partialExitPending) {
    return PartialIntervalSegmentStatus.alreadyPending;
  }
  if (!configurationMatches) {
    return PartialIntervalSegmentStatus.configurationChanged;
  }
  return PartialIntervalSegmentStatus.committed;
}

/// Stable fingerprint for the phase definition behind an in-progress
/// checkpoint. Index-only progress is safe to restore only while this value
/// still matches; otherwise a reordered routine could attribute completed
/// work to the wrong exercise.
String circuitPhaseConfigSignature({
  required String kind,
  required int? segmentIndex,
  required Iterable<({String exerciseId, int workSeconds})> steps,
  required int restSeconds,
  required int longRestSeconds,
  required int rounds,
}) => jsonEncode(<String, dynamic>{
  'kind': kind,
  'segmentIndex': segmentIndex,
  'steps': [
    for (final step in steps)
      <String, dynamic>{
        'exerciseId': step.exerciseId,
        'workSeconds': step.workSeconds,
      },
  ],
  'restSeconds': restSeconds,
  'longRestSeconds': longRestSeconds,
  'rounds': rounds,
});

String? intervalSegmentConfigSignature({
  required int segmentIndex,
  required List<String> exerciseIds,
  required int start,
  required int end,
  required int workSeconds,
  required int restSeconds,
  required int longRestSeconds,
  required int rounds,
}) {
  if (segmentIndex < 0 ||
      start < 0 ||
      start >= exerciseIds.length ||
      end <= start ||
      end > exerciseIds.length) {
    return null;
  }
  return circuitPhaseConfigSignature(
    kind: 'segment',
    segmentIndex: segmentIndex,
    steps: exerciseIds
        .sublist(start, end)
        .map(
          (exerciseId) => (exerciseId: exerciseId, workSeconds: workSeconds),
        ),
    restSeconds: restSeconds,
    longRestSeconds: longRestSeconds,
    rounds: rounds,
  );
}

/// New sessions initially store a route checkpoint before the phase has
/// loaded enough data to calculate its configuration signature. That exact
/// untouched shape is safe to accept; any unsigned checkpoint with progress
/// must fail closed because its numeric indices cannot be mapped reliably.
bool isSafeUnsignedCircuitCheckpoint(Map<String, dynamic> checkpoint) {
  final completed = checkpoint['completedSteps'];
  final hasCompletedSteps = completed is List && completed.isNotEmpty;
  return checkpoint['phase'] == 'prep' &&
      ((checkpoint['round'] as num?)?.toInt() ?? 1) == 1 &&
      ((checkpoint['stepIndex'] as num?)?.toInt() ?? 0) == 0 &&
      !hasCompletedSteps &&
      checkpoint['phaseEndsAtMs'] == null &&
      checkpoint['exitPending'] != true &&
      checkpoint['manuallyPaused'] != true;
}
