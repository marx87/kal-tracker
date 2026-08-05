import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/features/workouts/domain/circuit_flow.dart';
import 'package:kal_tracker/features/workouts/domain/exercise_kind.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';
import 'package:kal_tracker/features/workouts/presentation/live/circuit_workout_screen.dart';
import 'package:kal_tracker/features/workouts/presentation/live/live_workout_providers.dart';

import 'fake_live_workout_repository.dart';

/// Il circuito montato davvero, con il tempo in mano.
///
/// L'orologio è iniettato: il conto alla rovescia è ancorato a una scadenza
/// assoluta, quindi far avanzare i timer di Flutter senza far avanzare anche
/// `now` non farebbe scendere nessun secondo — è la stessa ragione per cui il
/// countdown sopravvive a un giro in secondo piano.
class _Clock {
  DateTime value = DateTime(2026, 8, 5, 18);

  DateTime call() => value;

  void advance(Duration by) => value = value.add(by);
}

Future<void> _tick(WidgetTester tester, _Clock clock, int seconds) async {
  for (var second = 0; second < seconds; second++) {
    clock.advance(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }
  await tester.pump(const Duration(milliseconds: 50));
}

final _steps = [
  const CircuitStep(
    exerciseId: 'jumping',
    exerciseName: 'Jumping jack',
    workSec: 30,
    muscleGroup: MuscleGroup.cardio,
    hint: 'Braccia sopra la testa.',
  ),
  const CircuitStep(
    exerciseId: 'squat',
    exerciseName: 'Squat a corpo libero',
    workSec: 30,
    muscleGroup: MuscleGroup.gambe,
  ),
];

Workout _workout({Map<String, dynamic>? checkpoint}) => Workout(
  id: 'w1',
  startedAt: DateTime(2026, 8, 5, 17, 30),
  circuitCheckpoint: checkpoint,
  exercises: const [],
);

Widget _app(
  FakeLiveWorkoutRepository repository,
  _Clock clock, {
  int rounds = 1,
  CircuitKind kind = CircuitKind.main,
  void Function(CircuitFlowState)? onCompleted,
}) => ProviderScope(
  overrides: [liveWorkoutRepositoryProvider.overrideWithValue(repository)],
  child: MaterialApp(
    theme: AppTheme.light,
    home: CircuitWorkoutScreen(
      workoutId: 'w1',
      kind: kind,
      steps: _steps,
      restSec: 15,
      longRestSec: 45,
      rounds: rounds,
      now: clock.call,
      onCompleted: onCompleted,
    ),
  ),
);

String _seconds(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('circuit_seconds'))).data!;

String _phase(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('circuit_phase_label'))).data!;

void main() {
  testWidgets('parte da «pronti» e dopo cinque secondi si lavora', (
    tester,
  ) async {
    final clock = _Clock();
    final repository = FakeLiveWorkoutRepository(initial: _workout());

    await tester.pumpWidget(_app(repository, clock));
    await tester.pump();
    await tester.pump();

    expect(_phase(tester), 'PRONTI…');
    expect(_seconds(tester), '5');
    // Già in preparazione si annuncia il primo esercizio.
    expect(find.text('Poi: Jumping jack'), findsOneWidget);

    await _tick(tester, clock, 5);

    expect(_phase(tester), 'LAVORO');
    expect(_seconds(tester), '30');
    expect(find.text('Jumping jack'), findsOneWidget);
    expect(find.text('Braccia sopra la testa.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('finito il lavoro si riposa e si annuncia il prossimo', (
    tester,
  ) async {
    final clock = _Clock();
    final repository = FakeLiveWorkoutRepository(initial: _workout());

    await tester.pumpWidget(_app(repository, clock));
    await tester.pump();
    await _tick(tester, clock, 5 + 30);

    expect(_phase(tester), 'RIPOSO');
    expect(_seconds(tester), '15');
    expect(find.text('Poi: Squat a corpo libero'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('la pausa ferma il conto e il pulsante cambia', (tester) async {
    final clock = _Clock();
    final repository = FakeLiveWorkoutRepository(initial: _workout());

    await tester.pumpWidget(_app(repository, clock));
    await tester.pump();
    await _tick(tester, clock, 7);

    expect(_phase(tester), 'LAVORO');
    final before = _seconds(tester);

    await tester.tap(find.byKey(const Key('circuit_toggle_pause')));
    await tester.pump();

    expect(_phase(tester), 'PAUSA');
    // Il tempo passa, ma non per il circuito.
    await _tick(tester, clock, 10);
    expect(_seconds(tester), before);
    expect(find.text('Riprendi'), findsOneWidget);
    // In pausa non si può saltare: sarebbe un comando senza uno stato.
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('circuit_skip')))
          .onPressed,
      isNull,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('saltare porta al passo dopo senza contarlo come fatto', (
    tester,
  ) async {
    final clock = _Clock();
    final repository = FakeLiveWorkoutRepository(initial: _workout());
    CircuitFlowState? finalState;

    await tester.pumpWidget(
      _app(repository, clock, onCompleted: (state) => finalState = state),
    );
    await tester.pump();
    await _tick(tester, clock, 6);

    expect(_phase(tester), 'LAVORO');
    await tester.tap(find.byKey(const Key('circuit_skip')));
    await tester.pump();

    expect(_phase(tester), 'PRONTI…');
    expect(_seconds(tester), '3');
    expect(find.text('Poi: Squat a corpo libero'), findsOneWidget);

    // Si finisce il secondo esercizio: solo QUELLO risulta fatto.
    await _tick(tester, clock, 3 + 30);
    await tester.pump(const Duration(milliseconds: 200));

    expect(finalState, isNotNull);
    expect(finalState!.completed.completedRoundsForStep(0), 0);
    expect(finalState!.completed.completedRoundsForStep(1), 1);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'alla fine scrive solo le celle finite, col gruppo muscolare, e pulisce '
    'la rotta di ripresa',
    (tester) async {
      final clock = _Clock();
      final repository = FakeLiveWorkoutRepository(initial: _workout());

      await tester.pumpWidget(_app(repository, clock));
      await tester.pump();
      // pronti 5 + lavoro 30 + riposo 15 + lavoro 30.
      await _tick(tester, clock, 5 + 30 + 15 + 30);
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Blocco finito'), findsOneWidget);

      final written = repository.saved.last.exercises;
      expect(written, hasLength(2));
      expect(written.first.muscleGroup, MuscleGroup.cardio);
      expect(written.last.muscleGroup, MuscleGroup.gambe);
      expect(written.first.sets.single.durationSec, 30);
      expect(written.first.sets.single.completed, isTrue);

      // Finito il blocco non c'è più niente da riprendere.
      expect(repository.resumeWrites.last.resumePath, isNull);
      expect(repository.resumeWrites.last.checkpoint, isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a ogni cambio di fase scrive un checkpoint riprendibile', (
    tester,
  ) async {
    final clock = _Clock();
    final repository = FakeLiveWorkoutRepository(initial: _workout());

    await tester.pumpWidget(_app(repository, clock));
    await tester.pump();
    await _tick(tester, clock, 5 + 30);

    final checkpoint = repository.resumeWrites.last.checkpoint;
    expect(checkpoint, isNotNull);
    expect(checkpoint!['phase'], 'shortRest');
    expect(checkpoint['completedSteps'], ['1:0']);
    expect(checkpoint['configSignature'], isNotNull);
    expect(repository.resumeWrites.last.resumePath, '/workout/w1/phase/main');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('riprende dal checkpoint invece di ricominciare', (tester) async {
    final clock = _Clock();
    final fresh = CircuitFlowState.initial(
      kind: CircuitKind.main,
      steps: _steps,
      restSec: 15,
      longRestSec: 45,
      totalRounds: 1,
    );
    final repository = FakeLiveWorkoutRepository(
      initial: _workout(
        checkpoint: {
          'kind': 'main',
          'segmentIndex': null,
          'phase': 'work',
          'round': 1,
          'stepIndex': 1,
          'secondsLeft': 12,
          'phaseEndsAtMs': clock.value
              .add(const Duration(seconds: 12))
              .millisecondsSinceEpoch,
          'manuallyPaused': false,
          'completedSteps': ['1:0'],
          'configSignature': fresh.configSignature,
        },
      ),
    );

    await tester.pumpWidget(_app(repository, clock));
    await tester.pump();
    await tester.pump();

    expect(_phase(tester), 'LAVORO');
    expect(_seconds(tester), '12');
    expect(find.text('Squat a corpo libero'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'se la scheda è cambiata lo dice e riparte da capo invece di attribuire '
    'il lavoro all\'esercizio sbagliato',
    (tester) async {
      final clock = _Clock();
      final repository = FakeLiveWorkoutRepository(
        initial: _workout(
          checkpoint: {
            'kind': 'main',
            'segmentIndex': null,
            'phase': 'work',
            'round': 1,
            'stepIndex': 1,
            'secondsLeft': 12,
            'completedSteps': ['1:0'],
            'configSignature': 'la-firma-di-un-altro-circuito',
          },
        ),
      );

      await tester.pumpWidget(_app(repository, clock));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('La scheda è cambiata'), findsOneWidget);
      expect(_phase(tester), 'PRONTI…');
      expect(_seconds(tester), '5');

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('uscire chiede conferma e salva il lavoro già fatto', (
    tester,
  ) async {
    final clock = _Clock();
    final repository = FakeLiveWorkoutRepository(initial: _workout());

    await tester.pumpWidget(_app(repository, clock));
    await tester.pump();
    // Prima cella completata, poi si esce durante il riposo.
    await _tick(tester, clock, 5 + 30 + 2);

    await tester.tap(find.byKey(const Key('circuit_back')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Esci dal circuito?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('circuit_exit_leave')));
    await tester.pumpAndSettle();

    final written = repository.saved.last.exercises;
    expect(written, hasLength(1));
    expect(written.single.exerciseId, 'jumping');

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
