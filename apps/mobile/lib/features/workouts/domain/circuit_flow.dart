/// La macchina a stati del circuito a tempo, tirata FUORI dalla schermata.
///
/// In Gym Tracker `_advancePhase`, `_skip` e `_togglePause` vivevano dentro
/// `_CircuitWorkoutScreenState`, mescolati a `setState`, audio e voce: la
/// regola («al termine del lavoro segna la cella, poi riposo breve, poi lungo,
/// poi fine») non era verificabile senza montare la schermata. Qui è una
/// funzione pura sopra un valore immutabile, e le transizioni sono quelle,
/// riga per riga.
///
/// Quello che NON è entrato qui è tutto ciò che ha un effetto: beep, voce,
/// vibrazione, scritture. Restano alla schermata, che li appende leggendo
/// [CircuitTransition].
library;

import 'package:kal_tracker/features/workouts/domain/circuit_progress.dart';
import 'package:kal_tracker/features/workouts/domain/exercise_kind.dart';
import 'package:kal_tracker/features/workouts/domain/countdown.dart';

/// Che tipo di fase guidata a tempo si sta eseguendo.
enum CircuitKind {
  warmup('Riscaldamento'),
  main('Circuito'),
  segment('Blocco a tempo'),
  cooldown('Defaticamento');

  const CircuitKind(this.label);

  final String label;

  static CircuitKind? tryFromName(String? name) {
    for (final kind in CircuitKind.values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

/// Un passo a tempo. Ha una durata SUA e non ereditata: nel defaticamento
/// ogni allungamento dura diversamente dagli altri.
class CircuitStep {
  const CircuitStep({
    required this.exerciseId,
    required this.exerciseName,
    required this.workSec,
    this.muscleGroup,
    this.hint,
  });

  final String exerciseId;
  final String exerciseName;
  final int workSec;

  /// Il gruppo muscolare da congelare sulla riga quando il circuito finisce.
  /// Non entra nella firma della configurazione — quella descrive il LAVORO,
  /// e cambiare la classificazione di un esercizio non deve invalidare un
  /// checkpoint — ma senza, le calorie del circuito ricadono su 5.0 MET.
  final MuscleGroup? muscleGroup;

  final String? hint;
}

enum CircuitPhase {
  prep('PRONTI…'),
  work('LAVORO'),
  shortRest('RIPOSO'),
  longRest('RIPOSO TRA ROUND'),
  done('FINE'),
  paused('PAUSA');

  const CircuitPhase(this.label);

  final String label;

  bool get isResting =>
      this == CircuitPhase.shortRest || this == CircuitPhase.longRest;

  static CircuitPhase? tryFromName(String? name) {
    for (final phase in CircuitPhase.values) {
      if (phase.name == name) return phase;
    }
    return null;
  }
}

/// Cosa è successo passando da uno stato al successivo. La schermata la legge
/// per decidere suono e annuncio vocale; il calcolo non ne dipende.
enum CircuitEvent {
  /// Da «pronti» al lavoro, o da un riposo al lavoro successivo.
  workStarted,

  /// Fine di una cella: si riposa poco, poi si cambia esercizio.
  shortRestStarted,

  /// Fine dell'ultima cella del round: riposo lungo prima del round nuovo.
  longRestStarted,

  /// Non c'è più niente da fare: la fase è finita.
  finished,

  /// Nessun cambio: la fase era già finita o in pausa.
  none,
}

/// Lo stato del circuito in un istante. Immutabile: ogni transizione ne
/// restituisce uno nuovo, così il test può fissare la sequenza esatta senza
/// orologi né timer.
class CircuitFlowState {
  const CircuitFlowState({
    required this.kind,
    required this.steps,
    required this.phase,
    required this.stepIndex,
    required this.round,
    required this.totalRounds,
    required this.secondsLeft,
    required this.restSec,
    required this.longRestSec,
    required this.completed,
    this.segmentIndex,
    this.phaseBeforePause = CircuitPhase.prep,
    this.manuallyPaused = false,
  });

  /// Lo stato iniziale: cinque secondi di «pronti» come in Gym.
  factory CircuitFlowState.initial({
    required CircuitKind kind,
    required List<CircuitStep> steps,
    required int restSec,
    required int longRestSec,
    required int totalRounds,
    int? segmentIndex,
    CircuitCompletionTracker? completed,
  }) {
    final safeRounds = totalRounds < 1 ? 1 : totalRounds;
    final tracker = completed ?? CircuitCompletionTracker();
    var firstRound = 1;
    var firstStep = 0;
    var foundPending = steps.isEmpty;
    for (var round = 1; round <= safeRounds && !foundPending; round++) {
      for (var step = 0; step < steps.length; step++) {
        if (!tracker.isCompleted(round: round, stepIndex: step)) {
          firstRound = round;
          firstStep = step;
          foundPending = true;
          break;
        }
      }
    }
    return CircuitFlowState(
      kind: kind,
      steps: List.unmodifiable(steps),
      phase: !foundPending && steps.isNotEmpty
          ? CircuitPhase.done
          : CircuitPhase.prep,
      stepIndex: firstStep,
      round: firstRound,
      totalRounds: safeRounds,
      secondsLeft: !foundPending && steps.isNotEmpty ? 0 : kPrepSeconds,
      restSec: restSec,
      longRestSec: longRestSec,
      segmentIndex: segmentIndex,
      completed: tracker,
    );
  }

  /// I secondi di «pronti» all'avvio della fase.
  static const int kPrepSeconds = 5;

  /// I secondi di riposizionamento dopo un «salta»: meno dell'avvio, perché
  /// l'utente è già in piedi e sta aspettando.
  static const int kSkipPrepSeconds = 3;

  final CircuitKind kind;
  final List<CircuitStep> steps;
  final CircuitPhase phase;
  final int stepIndex;
  final int round;
  final int totalRounds;
  final int secondsLeft;
  final int restSec;
  final int longRestSec;
  final int? segmentIndex;

  /// Il registro durevole delle celle completate. NON è ricostruibile dal
  /// cursore: una stazione in preparazione, in corso o saltata non conta, e
  /// indovinarla dal cursore è esattamente l'errore che questo oggetto evita.
  final CircuitCompletionTracker completed;

  /// La fase a cui tornare uscendo dalla pausa.
  final CircuitPhase phaseBeforePause;

  /// Pausa chiesta dall'utente, distinta da quella causata dal sistema
  /// operativo: alla ripresa dell'app solo la prima resta.
  final bool manuallyPaused;

  CircuitStep? get currentStep =>
      stepIndex >= 0 && stepIndex < steps.length ? steps[stepIndex] : null;

  int get currentWorkSec => currentStep?.workSec ?? 30;

  /// La durata PIENA della fase in corso: è il denominatore della barra di
  /// avanzamento, e serve anche a decidere se annunciare i venti secondi.
  int get phaseTotalSec => switch (phase) {
    CircuitPhase.prep => kPrepSeconds,
    CircuitPhase.work => currentWorkSec,
    CircuitPhase.shortRest => restSec,
    CircuitPhase.longRest => longRestSec,
    CircuitPhase.done || CircuitPhase.paused => 0,
  };

  /// Quanto manca alla fine della fase, da 0 a 1.
  double get phaseProgress {
    final total = phaseTotalSec;
    if (total <= 0) return 0;
    return (1 - secondsLeft / total).clamp(0.0, 1.0);
  }

  /// Avanzamento sull'intera fase guidata, non sulla singola cella.
  double get progress {
    final totalSteps = steps.length * totalRounds;
    if (totalSteps == 0) return 0;
    final doneSteps = (round - 1) * steps.length + stepIndex;
    return (doneSteps / totalSteps).clamp(0.0, 1.0);
  }

  /// «Round 2/3 · Es. 1/5», o solo l'esercizio quando il round è uno solo.
  String get progressLabel {
    if (steps.isEmpty) return '';
    final stepNumber = (stepIndex + 1).clamp(1, steps.length);
    if (totalRounds == 1) {
      return 'Esercizio $stepNumber/${steps.length}';
    }
    return 'Round $round/$totalRounds · Es. $stepNumber/${steps.length}';
  }

  /// Che cosa arriva dopo. Serve a scriverlo sul riposo, così l'utente si
  /// mette in posizione prima che riparta il cronometro.
  CircuitStep? get nextStep {
    if (steps.isEmpty) return null;
    switch (phase) {
      case CircuitPhase.work:
        return _nextPendingCell(this)?.step;
      case CircuitPhase.shortRest:
        return _nextPendingCell(this)?.step;
      case CircuitPhase.longRest:
        return _nextPendingCell(this)?.step;
      case CircuitPhase.prep:
        return currentStep;
      case CircuitPhase.done:
      case CircuitPhase.paused:
        return null;
    }
  }

  bool get isFinished => phase == CircuitPhase.done;

  CircuitFlowState copyWith({
    CircuitPhase? phase,
    int? stepIndex,
    int? round,
    int? secondsLeft,
    CircuitCompletionTracker? completed,
    CircuitPhase? phaseBeforePause,
    bool? manuallyPaused,
  }) => CircuitFlowState(
    kind: kind,
    steps: steps,
    phase: phase ?? this.phase,
    stepIndex: stepIndex ?? this.stepIndex,
    round: round ?? this.round,
    totalRounds: totalRounds,
    secondsLeft: secondsLeft ?? this.secondsLeft,
    restSec: restSec,
    longRestSec: longRestSec,
    segmentIndex: segmentIndex,
    completed: completed ?? this.completed,
    phaseBeforePause: phaseBeforePause ?? this.phaseBeforePause,
    manuallyPaused: manuallyPaused ?? this.manuallyPaused,
  );

  /// La firma della configurazione di questa fase. Un checkpoint con indici
  /// numerici vale SOLO finché questa firma combacia: altrimenti una scheda
  /// riordinata attribuirebbe il lavoro fatto all'esercizio sbagliato.
  String get configSignature => circuitPhaseConfigSignature(
    kind: kind.name,
    segmentIndex: segmentIndex,
    steps: steps.map(
      (step) => (exerciseId: step.exerciseId, workSeconds: step.workSec),
    ),
    restSeconds: restSec,
    longRestSeconds: longRestSec,
    rounds: totalRounds,
  );

  /// Il checkpoint da scrivere su `workouts.circuit_checkpoint`. Le chiavi
  /// sono quelle di Gym: un checkpoint scritto dalla vecchia app deve poter
  /// essere riletto da questa.
  Map<String, dynamic> checkpoint({DateTime? phaseDeadline}) =>
      <String, dynamic>{
        'kind': kind.name,
        'segmentIndex': segmentIndex,
        // In pausa si registra la fase VERA, non «paused»: alla ripresa si
        // torna al lavoro, non a uno stato che non esiste più.
        'phase': (phase == CircuitPhase.paused ? phaseBeforePause : phase).name,
        'round': round,
        'stepIndex': stepIndex,
        'secondsLeft': secondsLeft,
        'phaseEndsAtMs': phaseDeadline?.millisecondsSinceEpoch,
        'manuallyPaused': manuallyPaused,
        'completedSteps': completed.serialize(),
        if (steps.isNotEmpty) 'configSignature': configSignature,
      };
}

/// Il risultato di una transizione: lo stato nuovo e cosa è successo.
class CircuitTransition {
  const CircuitTransition({required this.state, required this.event});

  final CircuitFlowState state;
  final CircuitEvent event;
}

/// Il countdown è arrivato a zero: passa alla fase successiva.
///
/// Portata riga per riga da `_advancePhase`. L'ordine conta: la cella si
/// segna completata PRIMA di decidere dove andare, perché anche l'ultima
/// cella dell'ultimo round — quella che chiude tutto — deve risultare fatta.
CircuitTransition advanceCircuitPhase(CircuitFlowState state) {
  switch (state.phase) {
    case CircuitPhase.prep:
      return CircuitTransition(
        state: state.copyWith(
          phase: CircuitPhase.work,
          secondsLeft: state.currentWorkSec,
        ),
        event: CircuitEvent.workStarted,
      );

    case CircuitPhase.work:
      final completed = _markCompleted(state);
      final withCompletion = state.copyWith(completed: completed);
      final next = _nextPendingCell(withCompletion);
      if (next == null) {
        return CircuitTransition(
          state: withCompletion.copyWith(
            phase: CircuitPhase.done,
            secondsLeft: 0,
          ),
          event: CircuitEvent.finished,
        );
      }
      if (next.round == state.round) {
        return CircuitTransition(
          state: withCompletion.copyWith(
            phase: CircuitPhase.shortRest,
            secondsLeft: state.restSec,
          ),
          event: CircuitEvent.shortRestStarted,
        );
      }
      return CircuitTransition(
        state: withCompletion.copyWith(
          phase: CircuitPhase.longRest,
          secondsLeft: state.longRestSec,
        ),
        event: CircuitEvent.longRestStarted,
      );

    case CircuitPhase.shortRest:
      final next = _nextPendingCell(state);
      if (next == null) {
        return CircuitTransition(
          state: state.copyWith(phase: CircuitPhase.done, secondsLeft: 0),
          event: CircuitEvent.finished,
        );
      }
      return CircuitTransition(
        state: state.copyWith(
          phase: CircuitPhase.work,
          stepIndex: next.stepIndex,
          round: next.round,
          secondsLeft: next.step.workSec,
        ),
        event: CircuitEvent.workStarted,
      );

    case CircuitPhase.longRest:
      final next = _nextPendingCell(state);
      if (next == null) {
        return CircuitTransition(
          state: state.copyWith(phase: CircuitPhase.done, secondsLeft: 0),
          event: CircuitEvent.finished,
        );
      }
      return CircuitTransition(
        state: state.copyWith(
          phase: CircuitPhase.work,
          stepIndex: next.stepIndex,
          round: next.round,
          secondsLeft: next.step.workSec,
        ),
        event: CircuitEvent.workStarted,
      );

    case CircuitPhase.done:
    case CircuitPhase.paused:
      return CircuitTransition(state: state, event: CircuitEvent.none);
  }
}

/// «Salta»: vai al prossimo esercizio ADESSO, con tre secondi per
/// riposizionarti. I tre secondi sono una fase «pronti» che poi scade da sé.
///
/// Nota che saltare NON segna la cella come completata: chi salta non l'ha
/// fatta, e il registro durevole deve dire la verità.
CircuitTransition skipCircuitStep(CircuitFlowState state) {
  if (state.phase == CircuitPhase.done ||
      state.phase == CircuitPhase.paused ||
      state.steps.isEmpty) {
    return CircuitTransition(state: state, event: CircuitEvent.none);
  }

  if (state.phase == CircuitPhase.prep) {
    // Già in preparazione: si accorcia a un secondo così parte subito.
    return CircuitTransition(
      state: state.copyWith(secondsLeft: 1),
      event: CircuitEvent.none,
    );
  }

  final next = _nextPendingCell(state);
  if (next == null) {
    return CircuitTransition(
      state: state.copyWith(phase: CircuitPhase.done, secondsLeft: 0),
      event: CircuitEvent.finished,
    );
  }
  return CircuitTransition(
    state: state.copyWith(
      phase: CircuitPhase.prep,
      stepIndex: next.stepIndex,
      round: next.round,
      secondsLeft: CircuitFlowState.kSkipPrepSeconds,
    ),
    event: CircuitEvent.shortRestStarted,
  );
}

/// Mette in pausa. Prima di fermarsi riconcilia una cella il cui countdown è
/// già scaduto mentre l'app era in secondo piano: senza, un lavoro finito
/// davvero risulterebbe non fatto solo perché il telefono era in tasca.
CircuitFlowState pauseCircuit(CircuitFlowState state, {bool manual = true}) {
  if (state.phase == CircuitPhase.done || state.phase == CircuitPhase.paused) {
    return state;
  }
  final completed = state.secondsLeft <= 0 && state.phase == CircuitPhase.work
      ? _markCompleted(state)
      : state.completed;
  return state.copyWith(
    phase: CircuitPhase.paused,
    phaseBeforePause: state.phase,
    manuallyPaused: manual,
    completed: completed,
  );
}

/// Riprende dalla fase su cui ci si era fermati.
CircuitFlowState resumeCircuit(CircuitFlowState state) {
  if (state.phase != CircuitPhase.paused) return state;
  return state.copyWith(phase: state.phaseBeforePause, manuallyPaused: false);
}

CircuitCompletionTracker _markCompleted(CircuitFlowState state) {
  final next = CircuitCompletionTracker(state.completed.serialize())
    ..markCompleted(round: state.round, stepIndex: state.stepIndex);
  return next;
}

({int round, int stepIndex, CircuitStep step})? _nextPendingCell(
  CircuitFlowState state,
) {
  if (state.steps.isEmpty) return null;
  final start = (state.round - 1) * state.steps.length + state.stepIndex + 1;
  final total = state.totalRounds * state.steps.length;
  for (var linear = start; linear < total; linear++) {
    final round = linear ~/ state.steps.length + 1;
    final stepIndex = linear % state.steps.length;
    if (!state.completed.isCompleted(round: round, stepIndex: stepIndex)) {
      return (round: round, stepIndex: stepIndex, step: state.steps[stepIndex]);
    }
  }
  return null;
}

/// Perché un checkpoint non è stato applicato. Non è un dettaglio da log: le
/// tre ragioni portano a tre schermate diverse.
enum CircuitRestoreRefusal {
  /// Non c'era nessun checkpoint, o era di un'altra fase.
  notForThisPhase,

  /// La scheda è cambiata mentre la fase era sospesa. Il progresso NON si
  /// applica: gli indici punterebbero ad altri esercizi.
  configurationChanged,
}

/// Il risultato del tentativo di ripresa: o lo stato ricostruito, o il motivo
/// per cui si è preferito non ricostruirlo.
class CircuitRestoreResult {
  const CircuitRestoreResult.restored(this.state) : refusal = null;
  const CircuitRestoreResult.refused(this.refusal) : state = null;

  final CircuitFlowState? state;
  final CircuitRestoreRefusal? refusal;

  bool get isRestored => state != null;
}

/// Riapplica un checkpoint sopra uno stato appena costruito.
///
/// Portata da `_restoreCheckpoint`, meno le parti che parlano col repository.
/// La regola che conta è quella in mezzo: un checkpoint SENZA firma vale solo
/// se è ancora quello vergine scritto all'apertura della fase
/// (`isSafeUnsignedCircuitCheckpoint`); appena c'è del progresso senza firma,
/// si fallisce chiuso.
CircuitRestoreResult restoreCircuitFlow({
  required CircuitFlowState fresh,
  required Map<String, dynamic>? checkpoint,
  required DateTime now,
}) {
  if (checkpoint == null ||
      checkpoint['kind'] != fresh.kind.name ||
      checkpoint['segmentIndex'] != fresh.segmentIndex) {
    return const CircuitRestoreResult.refused(
      CircuitRestoreRefusal.notForThisPhase,
    );
  }

  final storedSignature = checkpoint['configSignature'] as String?;
  final unsignedIsUnsafe =
      storedSignature == null && !isSafeUnsignedCircuitCheckpoint(checkpoint);
  if (unsignedIsUnsafe ||
      (storedSignature != null && storedSignature != fresh.configSignature)) {
    return const CircuitRestoreResult.refused(
      CircuitRestoreRefusal.configurationChanged,
    );
  }

  final phase = CircuitPhase.tryFromName(checkpoint['phase'] as String?);
  if (phase == null || phase == CircuitPhase.paused) {
    return const CircuitRestoreResult.refused(
      CircuitRestoreRefusal.notForThisPhase,
    );
  }

  final completed = CircuitCompletionTracker();
  final rawCompleted = checkpoint['completedSteps'];
  if (rawCompleted is List) {
    completed.restore(rawCompleted.whereType<String>());
  }

  if (phase == CircuitPhase.done) {
    return CircuitRestoreResult.restored(
      fresh.copyWith(
        phase: CircuitPhase.done,
        secondsLeft: 0,
        completed: completed,
      ),
    );
  }

  final round = ((checkpoint['round'] as num?)?.toInt() ?? 1).clamp(
    1,
    fresh.totalRounds,
  );
  final stepIndex = ((checkpoint['stepIndex'] as num?)?.toInt() ?? 0).clamp(
    0,
    fresh.steps.isEmpty ? 0 : fresh.steps.length - 1,
  );
  final storedSeconds = (checkpoint['secondsLeft'] as num?)?.toInt() ?? 5;
  final manuallyPaused = checkpoint['manuallyPaused'] as bool? ?? false;
  final deadlineMs = (checkpoint['phaseEndsAtMs'] as num?)?.toInt();

  // In pausa manuale il tempo NON scorre: si riprende dal secondo su cui ci
  // si era fermati. Fuori dalla pausa comanda la scadenza assoluta, perché
  // fra la scrittura e la ripresa il mondo è andato avanti lo stesso.
  final secondsLeft = manuallyPaused || deadlineMs == null
      ? storedSeconds.clamp(0, 3600)
      : remainingCountdownSeconds(
          DateTime.fromMillisecondsSinceEpoch(deadlineMs),
          now,
        ).clamp(0, 3600);

  return CircuitRestoreResult.restored(
    fresh.copyWith(
      phase: manuallyPaused ? CircuitPhase.paused : phase,
      phaseBeforePause: phase,
      manuallyPaused: manuallyPaused,
      round: round,
      stepIndex: stepIndex,
      secondsLeft: secondsLeft,
      completed: completed,
    ),
  );
}
