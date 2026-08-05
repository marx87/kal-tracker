import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/workouts/domain/superset_flow.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';
import 'package:kal_tracker/features/workouts/domain/workout_set_mutation.dart';

/// Il flusso della superserie è stato COPIATO, non riscritto: questi test
/// esistono per dimostrare che la copia si comporta come l'originale sui casi
/// che in Gym erano già stati pagati — il gruppo asimmetrico, la cella
/// completata fuori ordine, il recupero che parte solo a fine round.

Workout _workout(List<WorkoutExercise> exercises) => Workout(
  id: 'w1',
  startedAt: DateTime(2026, 8, 5, 18),
  exercises: exercises,
);

WorkoutExercise _exercise(
  String id,
  int sets, {
  bool superset = false,
  List<int> completed = const [],
}) => WorkoutExercise(
  exerciseId: id,
  exerciseName: id.toUpperCase(),
  isInSupersetWithPrevious: superset,
  restSeconds: 90,
  sets: [
    for (var index = 0; index < sets; index++)
      WorkoutSet(reps: 10, weightKg: 40, completed: completed.contains(index)),
  ],
);

void main() {
  group('ordine per round', () {
    test('le celle si susseguono A1, B1, A2, B2 e non A1, A2', () {
      final workout = _workout([
        _exercise('a', 2),
        _exercise('b', 2, superset: true),
      ]);

      final flow = calculateSupersetFlow(workout, [0, 1]);

      expect(flow.roundCount, 2);
      expect(flow.orderedCells, [
        (exerciseIndex: 0, setIndex: 0),
        (exerciseIndex: 1, setIndex: 0),
        (exerciseIndex: 0, setIndex: 1),
        (exerciseIndex: 1, setIndex: 1),
      ]);
    });

    test('un gruppo asimmetrico salta la cella che non esiste', () {
      // A ha tre serie, B due: il terzo round contiene solo A3.
      final workout = _workout([
        _exercise('a', 3),
        _exercise('b', 2, superset: true),
      ]);

      final flow = calculateSupersetFlow(workout, [0, 1]);

      expect(flow.totalCells, 5);
      expect(flow.orderedCells.last, (exerciseIndex: 0, setIndex: 2));
    });
  });

  group('transizione al completamento', () {
    test('dentro il round NON si riposa: si va alla stazione dopo', () {
      final workout = _workout([
        _exercise('a', 2),
        _exercise('b', 2, superset: true),
      ]);

      final transition = calculateSupersetCompletionTransition(
        workout,
        [0, 1],
        (exerciseIndex: 0, setIndex: 0),
      );

      expect(transition.kind, SupersetTransitionKind.nextMember);
      expect(transition.shouldRest, isFalse);
      expect(transition.next, (exerciseIndex: 1, setIndex: 0));
    });

    test('chiudendo il round si riposa', () {
      final workout = _workout([
        _exercise('a', 2, completed: [0]),
        _exercise('b', 2, superset: true),
      ]);

      final transition = calculateSupersetCompletionTransition(
        workout,
        [0, 1],
        (exerciseIndex: 1, setIndex: 0),
      );

      expect(transition.kind, SupersetTransitionKind.nextRound);
      expect(transition.shouldRest, isTrue);
      expect(transition.next, (exerciseIndex: 0, setIndex: 1));
    });

    test('una cella registrata fuori ordine non fa partire il recupero', () {
      final workout = _workout([
        _exercise('a', 2),
        _exercise('b', 2, superset: true),
      ]);

      // Si spunta B1 mentre il fuoco era su A1.
      final transition = calculateSupersetCompletionTransition(
        workout,
        [0, 1],
        (exerciseIndex: 1, setIndex: 0),
      );

      expect(transition.kind, SupersetTransitionKind.loggedOutOfOrder);
      expect(transition.didCompleteCell, isTrue);
      expect(transition.wasCurrent, isFalse);
      expect(transition.shouldRest, isFalse);
      // Il fuoco resta dov'era.
      expect(transition.next, (exerciseIndex: 0, setIndex: 0));
    });

    test('ricompletare una cella già fatta è un no-op', () {
      final workout = _workout([
        _exercise('a', 2, completed: [0]),
        _exercise('b', 2, superset: true),
      ]);

      final transition = calculateSupersetCompletionTransition(
        workout,
        [0, 1],
        (exerciseIndex: 0, setIndex: 0),
      );

      expect(transition.kind, SupersetTransitionKind.noChange);
      expect(transition.didCompleteCell, isFalse);
    });
  });

  group('coda automatica', () {
    test('il recupero è chiesto dall\'ultima cella DISPONIBILE del round, non '
        'dalla posizione nominale', () {
      // B1 è già fatta: l'ultima cella disponibile del primo round è A1,
      // ed è lei a dover chiedere il recupero.
      final workout = _workout([
        _exercise('a', 2),
        _exercise('b', 2, superset: true, completed: [0]),
      ]);

      final queue = buildSupersetAutoQueue(workout, [0, 1]);

      expect(queue.first.cell, (exerciseIndex: 0, setIndex: 0));
      expect(queue.first.endsRound, isTrue);
      expect(queue.first.shouldRestAfter, isTrue);
    });

    test('l\'ultimo round non chiede recupero dopo di sé', () {
      final workout = _workout([
        _exercise('a', 1),
        _exercise('b', 1, superset: true),
      ]);

      final queue = buildSupersetAutoQueue(workout, [0, 1]);

      expect(queue.last.endsRound, isTrue);
      expect(queue.last.shouldRestAfter, isFalse);
    });
  });

  group('appartenenza al gruppo', () {
    test('un esercizio da solo non è una superserie', () {
      final workout = _workout([_exercise('a', 3)]);
      expect(supersetGroupContaining(workout, 0), isNull);
    });

    test('il gruppo si estende in avanti e indietro dal membro toccato', () {
      final workout = _workout([
        _exercise('a', 2),
        _exercise('b', 2, superset: true),
        _exercise('c', 2, superset: true),
        _exercise('d', 2),
      ]);

      expect(supersetGroupContaining(workout, 1), [0, 1, 2]);
      expect(supersetGroupContaining(workout, 3), isNull);
    });
  });

  group('mutazioni della superserie', () {
    test('togliere l\'ultimo round di A=3 e B=2 non tocca B2', () {
      final workout = _workout([
        _exercise('a', 3),
        _exercise('b', 2, superset: true),
      ]);

      final next = removeLastSupersetRound(workout, [0, 1]);

      expect(next.exercises[0].sets, hasLength(2));
      // B aveva due serie e le tiene: il terzo round conteneva solo A3.
      expect(next.exercises[1].sets, hasLength(2));
    });

    test('aggiungere un round pareggia prima i membri più corti', () {
      final workout = _workout([
        _exercise('a', 3),
        _exercise('b', 1, superset: true),
      ]);

      final next = appendSupersetRound(workout, [
        0,
        1,
      ], emptySetFactory: (_) => const WorkoutSet());

      expect(next.exercises[0].sets, hasLength(4));
      expect(next.exercises[1].sets, hasLength(4));
      // Le celle nuove nascono incomplete e senza sforzo ereditato.
      expect(next.exercises[1].sets.last.completed, isFalse);
      expect(next.exercises[1].sets.last.rpe, isNull);
    });
  });
}
