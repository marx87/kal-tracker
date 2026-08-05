import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/workouts/domain/circuit_flow.dart';
import 'package:kal_tracker/features/workouts/domain/circuit_progress.dart';
import 'package:kal_tracker/features/workouts/domain/circuit_result.dart';
import 'package:kal_tracker/features/workouts/domain/exercise_kind.dart';

/// La macchina a stati del circuito, verificata senza montare niente.
///
/// È il motivo per cui è stata tirata fuori dalla schermata: in Gym Tracker
/// per sapere se dopo l'ultima cella del round parte il riposo lungo bisognava
/// far girare l'app con un cronometro in mano.

List<CircuitStep> _steps(int count) => [
  for (var index = 0; index < count; index++)
    CircuitStep(
      exerciseId: 'e$index',
      exerciseName: 'Esercizio $index',
      workSec: 40,
      muscleGroup: MuscleGroup.cardio,
    ),
];

CircuitFlowState _initial({int steps = 3, int rounds = 2}) =>
    CircuitFlowState.initial(
      kind: CircuitKind.main,
      steps: _steps(steps),
      restSec: 20,
      longRestSec: 60,
      totalRounds: rounds,
    );

void main() {
  group('sequenza delle fasi', () {
    test('da «pronti» si passa al lavoro con la durata del passo', () {
      final transition = advanceCircuitPhase(_initial());

      expect(transition.event, CircuitEvent.workStarted);
      expect(transition.state.phase, CircuitPhase.work);
      expect(transition.state.secondsLeft, 40);
    });

    test('finito il lavoro di una cella intermedia parte il riposo breve', () {
      final working = advanceCircuitPhase(_initial()).state;

      final transition = advanceCircuitPhase(working);

      expect(transition.event, CircuitEvent.shortRestStarted);
      expect(transition.state.phase, CircuitPhase.shortRest);
      expect(transition.state.secondsLeft, 20);
      // La cella appena finita risulta fatta.
      expect(transition.state.completed.completedRoundsForStep(0), 1);
    });

    test('finita l\'ultima cella del round parte il riposo LUNGO', () {
      var state = _initial(steps: 2, rounds: 2);
      state = advanceCircuitPhase(state).state; // lavoro cella 0
      state = advanceCircuitPhase(state).state; // riposo breve
      state = advanceCircuitPhase(state).state; // lavoro cella 1

      final transition = advanceCircuitPhase(state);

      expect(transition.event, CircuitEvent.longRestStarted);
      expect(transition.state.secondsLeft, 60);
    });

    test('il riposo lungo riporta alla prima cella del round successivo', () {
      var state = _initial(steps: 2, rounds: 2);
      for (var step = 0; step < 4; step++) {
        state = advanceCircuitPhase(state).state;
      }

      final transition = advanceCircuitPhase(state);

      expect(transition.state.phase, CircuitPhase.work);
      expect(transition.state.round, 2);
      expect(transition.state.stepIndex, 0);
    });

    test('l\'ultima cella dell\'ultimo round chiude, e risulta fatta', () {
      var state = _initial(steps: 1, rounds: 1);
      state = advanceCircuitPhase(state).state; // lavoro

      final transition = advanceCircuitPhase(state);

      expect(transition.event, CircuitEvent.finished);
      expect(transition.state.phase, CircuitPhase.done);
      expect(transition.state.completed.completedRoundsForStep(0), 1);
    });
  });

  group('salta', () {
    test('saltare NON conta la cella come fatta', () {
      final working = advanceCircuitPhase(_initial()).state;

      final skipped = skipCircuitStep(working).state;

      expect(skipped.completed.completedRoundsForStep(0), 0);
      expect(skipped.phase, CircuitPhase.prep);
      expect(skipped.stepIndex, 1);
      expect(skipped.secondsLeft, CircuitFlowState.kSkipPrepSeconds);
    });

    test('saltare dall\'ultima cella dell\'ultimo round finisce la fase', () {
      var state = _initial(steps: 1, rounds: 1);
      state = advanceCircuitPhase(state).state;

      final transition = skipCircuitStep(state);

      expect(transition.event, CircuitEvent.finished);
    });

    test('saltare mentre si è già in «pronti» accorcia a un secondo', () {
      final skipped = skipCircuitStep(_initial()).state;

      expect(skipped.phase, CircuitPhase.prep);
      expect(skipped.secondsLeft, 1);
      expect(skipped.stepIndex, 0);
    });
  });

  group('pausa', () {
    test('la pausa ricorda la fase e ci torna', () {
      final working = advanceCircuitPhase(_initial()).state;

      final paused = pauseCircuit(working);
      expect(paused.phase, CircuitPhase.paused);
      expect(paused.manuallyPaused, isTrue);

      final resumed = resumeCircuit(paused);
      expect(resumed.phase, CircuitPhase.work);
      expect(resumed.manuallyPaused, isFalse);
    });

    test('mettere in pausa un lavoro il cui tempo è già scaduto lo conta '
        'comunque come fatto', () {
      // È il caso del telefono in tasca: il countdown è arrivato a zero
      // mentre l'app era sospesa.
      final expired = advanceCircuitPhase(
        _initial(),
      ).state.copyWith(secondsLeft: 0);

      final paused = pauseCircuit(expired);

      expect(paused.completed.completedRoundsForStep(0), 1);
    });
  });

  group('ripresa dal checkpoint', () {
    test('un checkpoint di un\'altra fase non si applica', () {
      final result = restoreCircuitFlow(
        fresh: _initial(),
        checkpoint: {'kind': 'warmup', 'segmentIndex': null},
        now: DateTime(2026, 8, 5, 19),
      );

      expect(result.isRestored, isFalse);
      expect(result.refusal, CircuitRestoreRefusal.notForThisPhase);
    });

    test('una firma diversa fa fallire chiuso: la scheda è cambiata', () {
      final fresh = _initial();
      final result = restoreCircuitFlow(
        fresh: fresh,
        checkpoint: {
          'kind': 'main',
          'segmentIndex': null,
          'phase': 'work',
          'round': 2,
          'stepIndex': 1,
          'secondsLeft': 12,
          'configSignature': 'una-firma-di-un-altro-circuito',
        },
        now: DateTime(2026, 8, 5, 19),
      );

      expect(result.isRestored, isFalse);
      expect(result.refusal, CircuitRestoreRefusal.configurationChanged);
    });

    test(
      'un checkpoint SENZA firma ma con progresso non si applica: gli indici '
      'non sono mappabili',
      () {
        final result = restoreCircuitFlow(
          fresh: _initial(),
          checkpoint: {
            'kind': 'main',
            'segmentIndex': null,
            'phase': 'work',
            'round': 2,
            'stepIndex': 1,
            'secondsLeft': 12,
            'completedSteps': ['1:0'],
          },
          now: DateTime(2026, 8, 5, 19),
        );

        expect(result.refusal, CircuitRestoreRefusal.configurationChanged);
      },
    );

    test('un checkpoint vergine senza firma è invece sicuro', () {
      final result = restoreCircuitFlow(
        fresh: _initial(),
        checkpoint: {
          'kind': 'main',
          'segmentIndex': null,
          'phase': 'prep',
          'round': 1,
          'stepIndex': 0,
          'completedSteps': <String>[],
        },
        now: DateTime(2026, 8, 5, 19),
      );

      expect(result.isRestored, isTrue);
      expect(result.state!.phase, CircuitPhase.prep);
    });

    test(
      'fuori dalla pausa comanda la scadenza assoluta, non i secondi scritti',
      () {
        final fresh = _initial();
        final now = DateTime(2026, 8, 5, 19);
        final result = restoreCircuitFlow(
          fresh: fresh,
          checkpoint: {
            'kind': 'main',
            'segmentIndex': null,
            'phase': 'work',
            'round': 1,
            'stepIndex': 0,
            // Scritti 30, ma la scadenza dice che ne restano 7.
            'secondsLeft': 30,
            'phaseEndsAtMs': now
                .add(const Duration(seconds: 7))
                .millisecondsSinceEpoch,
            'manuallyPaused': false,
            'configSignature': fresh.configSignature,
          },
          now: now,
        );

        expect(result.state!.secondsLeft, 7);
      },
    );

    test('in pausa manuale il tempo NON scorre: valgono i secondi scritti', () {
      final fresh = _initial();
      final now = DateTime(2026, 8, 5, 19);
      final result = restoreCircuitFlow(
        fresh: fresh,
        checkpoint: {
          'kind': 'main',
          'segmentIndex': null,
          'phase': 'work',
          'round': 1,
          'stepIndex': 0,
          'secondsLeft': 30,
          'phaseEndsAtMs': now
              .subtract(const Duration(minutes: 20))
              .millisecondsSinceEpoch,
          'manuallyPaused': true,
          'configSignature': fresh.configSignature,
        },
        now: now,
      );

      expect(result.state!.secondsLeft, 30);
      expect(result.state!.phase, CircuitPhase.paused);
      expect(result.state!.phaseBeforePause, CircuitPhase.work);
    });

    test('il checkpoint scritto è rileggibile da restoreCircuitFlow', () {
      final fresh = _initial();
      var state = advanceCircuitPhase(fresh).state;
      state = advanceCircuitPhase(state).state; // riposo breve, cella 0 fatta
      final deadline = DateTime(2026, 8, 5, 19, 0, 15);

      final result = restoreCircuitFlow(
        fresh: fresh,
        checkpoint: state.checkpoint(phaseDeadline: deadline),
        now: DateTime(2026, 8, 5, 19),
      );

      expect(result.isRestored, isTrue);
      expect(result.state!.phase, CircuitPhase.shortRest);
      expect(result.state!.secondsLeft, 15);
      expect(result.state!.completed.completedRoundsForStep(0), 1);
    });
  });

  group('righe scritte alla fine', () {
    test('un passo mai completato non genera nessuna riga', () {
      final completed = CircuitCompletionTracker()
        ..markCompleted(round: 1, stepIndex: 0);
      final state = CircuitFlowState.initial(
        kind: CircuitKind.main,
        steps: _steps(3),
        restSec: 20,
        longRestSec: 60,
        totalRounds: 2,
        completed: completed,
      );

      final rows = circuitAsWorkoutExercises(state);

      expect(rows, hasLength(1));
      expect(rows.single.exerciseId, 'e0');
      expect(rows.single.sets, hasLength(1));
      expect(rows.single.sets.single.completed, isTrue);
      expect(rows.single.sets.single.durationSec, 40);
    });

    test('ogni riga porta il gruppo muscolare: senza, le calorie del circuito '
        'ricadrebbero sul valore medio', () {
      final completed = CircuitCompletionTracker()
        ..markCompleted(round: 1, stepIndex: 0)
        ..markCompleted(round: 2, stepIndex: 0);
      final state = CircuitFlowState.initial(
        kind: CircuitKind.main,
        steps: _steps(1),
        restSec: 20,
        longRestSec: 60,
        totalRounds: 2,
        completed: completed,
      );

      final rows = circuitAsWorkoutExercises(state);

      expect(rows.single.muscleGroup, MuscleGroup.cardio);
      expect(rows.single.trackingMode, ExerciseTrackingMode.timed);
      expect(rows.single.sets, hasLength(2));
    });

    test('solo un blocco a tempo porta l\'indice di segmento', () {
      final completed = CircuitCompletionTracker()
        ..markCompleted(round: 1, stepIndex: 0);

      final mainRows = circuitAsWorkoutExercises(
        CircuitFlowState.initial(
          kind: CircuitKind.main,
          steps: _steps(1),
          restSec: 20,
          longRestSec: 60,
          totalRounds: 1,
          segmentIndex: 3,
          completed: completed,
        ),
      );
      final segmentRows = circuitAsWorkoutExercises(
        CircuitFlowState.initial(
          kind: CircuitKind.segment,
          steps: _steps(1),
          restSec: 20,
          longRestSec: 60,
          totalRounds: 1,
          segmentIndex: 3,
          completed: completed,
        ),
      );

      expect(mainRows.single.intervalSegmentIndex, isNull);
      expect(segmentRows.single.intervalSegmentIndex, 3);
    });

    test('il defaticamento è marcato tale, il riscaldamento pure', () {
      final completed = CircuitCompletionTracker()
        ..markCompleted(round: 1, stepIndex: 0);

      CircuitFlowState build(CircuitKind kind) => CircuitFlowState.initial(
        kind: kind,
        steps: _steps(1),
        restSec: 10,
        longRestSec: 10,
        totalRounds: 1,
        completed: completed,
      );

      expect(
        circuitAsWorkoutExercises(
          build(CircuitKind.cooldown),
        ).single.isCooldown,
        isTrue,
      );
      expect(
        circuitAsWorkoutExercises(build(CircuitKind.warmup)).single.isWarmup,
        isTrue,
      );
    });
  });

  test('l\'etichetta di avanzamento tace il round quando è uno solo', () {
    expect(_initial(steps: 4, rounds: 1).progressLabel, 'Esercizio 1/4');
    expect(_initial(steps: 4, rounds: 3).progressLabel, 'Round 1/3 · Es. 1/4');
  });
}
