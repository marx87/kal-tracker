/// La macchina a stati della superserie, in ordine «per round» (A1, B1, C1,
/// A2, B2, C2...). COPIA VERBATIM di
/// `features/workouts/superset_flow.dart` di Gym Tracker: cambia solo la riga
/// di import.
///
/// I commenti sono rimasti in inglese APPOSTA. Questo file ha mesi d'uso
/// dietro e va potuto confrontare riga per riga con il sorgente: tradurlo
/// renderebbe invisibile, nel diff, l'unica cosa che conta — che non è stato
/// toccato.
library;

import 'package:kal_tracker/features/workouts/domain/workout.dart';

/// One concrete set cell inside a superset.
///
/// [exerciseIndex] is the absolute index in [Workout.exercises], while
/// [setIndex] is both the set index for that exercise and the zero-based round
/// index in the superset.
typedef SupersetCell = ({int exerciseIndex, int setIndex});

/// How completing a cell changes the active superset flow.
enum SupersetTransitionKind {
  /// The requested cell is missing or was already completed.
  noChange,

  /// A non-current cell was logged. Progress stays on the previous current
  /// cell and no automatic recovery is started.
  loggedOutOfOrder,

  /// Continue with another available member in the same round.
  nextMember,

  /// The round is over and the next available cell belongs to a later round.
  nextRound,

  /// No incomplete cells remain in the group.
  complete,
}

/// Immutable, round-major view of a superset.
///
/// Cells are ordered A1, B1, C1, A2, B2, C2... Missing cells in asymmetric
/// groups are simply skipped. Invalid or repeated member indices are ignored.
class SupersetFlowState {
  SupersetFlowState._({
    required List<int> memberIndices,
    required List<SupersetCell> orderedCells,
    required List<SupersetCell> incompleteCells,
    required this.roundCount,
  }) : memberIndices = List.unmodifiable(memberIndices),
       orderedCells = List.unmodifiable(orderedCells),
       incompleteCells = List.unmodifiable(incompleteCells);

  final List<int> memberIndices;
  final List<SupersetCell> orderedCells;
  final List<SupersetCell> incompleteCells;
  final int roundCount;

  int get totalCells => orderedCells.length;
  int get completedCells => totalCells - incompleteCells.length;
  SupersetCell? get current => incompleteCells.firstOrNull;
  bool get hasCells => orderedCells.isNotEmpty;
  bool get isComplete => hasCells && incompleteCells.isEmpty;
}

/// Result of virtually completing one superset cell.
///
/// The input workout is not modified. Callers should persist the completed set
/// themselves, then use [next] and [shouldRest] to drive UI, voice and timers.
class SupersetTransition {
  const SupersetTransition({
    required this.kind,
    required this.completed,
    required this.next,
    required this.didCompleteCell,
    required this.wasCurrent,
    required this.shouldRest,
  });

  final SupersetTransitionKind kind;
  final SupersetCell completed;
  final SupersetCell? next;

  /// False when [completed] is missing from the group or was already done.
  final bool didCompleteCell;

  /// True only when [completed] was the first incomplete cell before the
  /// transition. Out-of-order logging never advances timers automatically.
  final bool wasCurrent;
  final bool shouldRest;

  bool get isGroupComplete => kind == SupersetTransitionKind.complete;
  bool get advances =>
      kind == SupersetTransitionKind.nextMember ||
      kind == SupersetTransitionKind.nextRound ||
      kind == SupersetTransitionKind.complete;
}

/// One remaining cell in the automatic superset queue.
class SupersetAutoStep {
  const SupersetAutoStep({
    required this.cell,
    required this.roundIndex,
    required this.endsRound,
    required this.shouldRestAfter,
  });

  final SupersetCell cell;
  final int roundIndex;

  /// True for the last *available incomplete* cell in this round. This remains
  /// correct when the nominal final member is missing or already completed.
  final bool endsRound;

  /// True when [endsRound] and another incomplete round follows.
  final bool shouldRestAfter;
}

/// Builds the canonical round-major flow for [memberIndices].
SupersetFlowState calculateSupersetFlow(
  Workout workout,
  List<int> memberIndices,
) {
  final members = _validMemberIndices(workout, memberIndices);
  var roundCount = 0;
  for (final exerciseIndex in members) {
    final count = workout.exercises[exerciseIndex].sets.length;
    if (count > roundCount) roundCount = count;
  }

  final ordered = <SupersetCell>[];
  final incomplete = <SupersetCell>[];
  for (var round = 0; round < roundCount; round++) {
    for (final exerciseIndex in members) {
      final sets = workout.exercises[exerciseIndex].sets;
      if (round >= sets.length) continue;
      final cell = (exerciseIndex: exerciseIndex, setIndex: round);
      ordered.add(cell);
      if (!sets[round].completed) incomplete.add(cell);
    }
  }

  return SupersetFlowState._(
    memberIndices: members,
    orderedCells: ordered,
    incompleteCells: incomplete,
    roundCount: roundCount,
  );
}

/// Shared "what is next?" query for the live CTA and voice commands.
SupersetCell? nextIncompleteSupersetCell(
  Workout workout,
  List<int> memberIndices,
) => calculateSupersetFlow(workout, memberIndices).current;

/// Calculates the flow change caused by completing [cell] in [workout].
///
/// [workout] must be the snapshot *before* the completion. The function
/// virtually removes [cell] from the incomplete sequence, which keeps the
/// decision deterministic and makes repeated completion calls idempotent.
SupersetTransition calculateSupersetCompletionTransition(
  Workout workout,
  List<int> memberIndices,
  SupersetCell cell,
) {
  final state = calculateSupersetFlow(workout, memberIndices);
  final isKnown = state.orderedCells.contains(cell);
  final isIncomplete = state.incompleteCells.contains(cell);
  final current = state.current;

  if (!isKnown || !isIncomplete) {
    return SupersetTransition(
      kind: SupersetTransitionKind.noChange,
      completed: cell,
      next: current,
      didCompleteCell: false,
      wasCurrent: false,
      shouldRest: false,
    );
  }

  final wasCurrent = current == cell;
  if (!wasCurrent) {
    return SupersetTransition(
      kind: SupersetTransitionKind.loggedOutOfOrder,
      completed: cell,
      next: current,
      didCompleteCell: true,
      wasCurrent: false,
      shouldRest: false,
    );
  }

  SupersetCell? next;
  for (final candidate in state.incompleteCells) {
    if (candidate != cell) {
      next = candidate;
      break;
    }
  }

  if (next == null) {
    return SupersetTransition(
      kind: SupersetTransitionKind.complete,
      completed: cell,
      next: null,
      didCompleteCell: true,
      wasCurrent: true,
      shouldRest: false,
    );
  }

  final changesRound = next.setIndex != cell.setIndex;
  return SupersetTransition(
    kind: changesRound
        ? SupersetTransitionKind.nextRound
        : SupersetTransitionKind.nextMember,
    completed: cell,
    next: next,
    didCompleteCell: true,
    wasCurrent: true,
    shouldRest: changesRound,
  );
}

/// Builds an automatic queue from the cells that are incomplete right now.
///
/// The final real cell of every non-final remaining round requests recovery;
/// the nominal position of a member is deliberately irrelevant. This avoids
/// skipping recovery when, for example, B1 is already done and only A1 remains.
List<SupersetAutoStep> buildSupersetAutoQueue(
  Workout workout,
  List<int> memberIndices,
) {
  final state = calculateSupersetFlow(workout, memberIndices);
  if (state.incompleteCells.isEmpty) return const [];

  final rounds = <int, List<SupersetCell>>{};
  for (final cell in state.incompleteCells) {
    rounds.putIfAbsent(cell.setIndex, () => <SupersetCell>[]).add(cell);
  }
  final remainingRounds = rounds.keys.toList()..sort();
  final queue = <SupersetAutoStep>[];

  for (
    var roundPosition = 0;
    roundPosition < remainingRounds.length;
    roundPosition++
  ) {
    final roundIndex = remainingRounds[roundPosition];
    final cells = rounds[roundIndex]!;
    final hasLaterRound = roundPosition < remainingRounds.length - 1;
    for (var cellPosition = 0; cellPosition < cells.length; cellPosition++) {
      final endsRound = cellPosition == cells.length - 1;
      queue.add(
        SupersetAutoStep(
          cell: cells[cellPosition],
          roundIndex: roundIndex,
          endsRound: endsRound,
          shouldRestAfter: endsRound && hasLaterRound,
        ),
      );
    }
  }

  return List.unmodifiable(queue);
}

/// Returns the consecutive superset group containing [exerciseIndex].
///
/// The data model marks every member after the head with
/// `isInSupersetWithPrevious`. A single exercise is not returned as a group.
List<int>? supersetGroupContaining(Workout workout, int exerciseIndex) {
  final exercises = workout.exercises;
  if (exerciseIndex < 0 || exerciseIndex >= exercises.length) return null;

  var start = exerciseIndex;
  while (start > 0 && exercises[start].isInSupersetWithPrevious) {
    start--;
  }

  final members = <int>[start];
  var next = start + 1;
  while (next < exercises.length && exercises[next].isInSupersetWithPrevious) {
    members.add(next);
    next++;
  }
  return members.length > 1 ? List.unmodifiable(members) : null;
}

List<int> _validMemberIndices(Workout workout, List<int> memberIndices) {
  final result = <int>[];
  final seen = <int>{};
  for (final index in memberIndices) {
    if (index < 0 || index >= workout.exercises.length || !seen.add(index)) {
      continue;
    }
    result.add(index);
  }
  return result;
}
