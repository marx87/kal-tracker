import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/routines/domain/routine_models.dart';
import 'package:kal_tracker/features/routines/presentation/routine_providers.dart';
import 'package:kal_tracker/features/workouts/cues/application/workout_cue_engine.dart';
import 'package:kal_tracker/features/workouts/cues/domain/workout_cue.dart';
import 'package:kal_tracker/features/workouts/cues/workout_cue_providers.dart';
import 'package:kal_tracker/features/workouts/domain/circuit_flow.dart';
import 'package:kal_tracker/features/workouts/domain/circuit_result.dart';
import 'package:kal_tracker/features/workouts/domain/countdown.dart';
import 'package:kal_tracker/features/workouts/domain/live_workout_repository.dart';
import 'package:kal_tracker/features/workouts/presentation/live/circuit_workout_plan.dart';
import 'package:kal_tracker/features/workouts/presentation/live/live_workout_providers.dart';
import 'package:kal_tracker/features/workouts/presentation/widgets/circuit_stage.dart';
import 'package:kal_tracker/features/workouts/presentation/widgets/live_workout_exit_guard.dart';

/// Risolve una rotta di produzione in un piano usando prima il checkpoint
/// durevole e poi, se serve, la scheda corrente.
class CircuitWorkoutRouteScreen extends ConsumerStatefulWidget {
  const CircuitWorkoutRouteScreen({
    required this.workoutId,
    required this.kind,
    this.segmentIndex,
    this.rowIndex,
    super.key,
  });

  final String workoutId;
  final CircuitKind kind;
  final int? segmentIndex;
  final int? rowIndex;

  @override
  ConsumerState<CircuitWorkoutRouteScreen> createState() =>
      _CircuitWorkoutRouteScreenState();
}

class _CircuitWorkoutRouteScreenState
    extends ConsumerState<CircuitWorkoutRouteScreen> {
  late final Future<CircuitWorkoutPlan?> _plan = _loadPlan();

  Future<CircuitWorkoutPlan?> _loadPlan() async {
    final workout = await ref
        .read(liveWorkoutRepositoryProvider)
        .getById(widget.workoutId);
    if (workout == null) return null;

    RoutineDetails? routine;
    final routineId = workout.routineId;
    if (routineId != null) {
      try {
        routine = await ref
            .read(routineRepositoryProvider)
            .getRoutine(routineId);
      } catch (_) {
        // Il piano nel checkpoint basta per riprendere anche se la scheda è
        // stata cancellata; se non c'è, sotto mostriamo un errore esplicito.
      }
    }
    return findCircuitWorkoutPlan(
      workout,
      kind: widget.kind,
      segmentIndex: widget.segmentIndex,
      rowIndex: widget.rowIndex,
      routine: routine,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<CircuitWorkoutPlan?>(
      future: _plan,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final plan = snapshot.data;
        if (plan == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const SafeArea(
              child: AdaptiveContent(
                child: AppEmptyState(
                  icon: Icons.timer_off_outlined,
                  title: 'Blocco non disponibile',
                  message:
                      'Non trovo più la configurazione di questa fase. '
                      'Torna alla sessione e avviala di nuovo.',
                ),
              ),
            ),
          );
        }
        return CircuitWorkoutScreen(workoutId: widget.workoutId, plan: plan);
      },
    );
  }
}

/// La fase guidata a tempo: riscaldamento, circuito, blocco a tempo,
/// defaticamento. Quattro cose diverse, una schermata sola, come in Gym.
///
/// Il cervello sta nel dominio (`circuit_flow.dart`): qui ci sono il
/// cronometro, il checkpoint, la vibrazione e il vestito. La distinzione non è
/// estetica — è il motivo per cui la sequenza delle fasi si può verificare
/// senza montare niente.
class CircuitWorkoutScreen extends ConsumerStatefulWidget {
  const CircuitWorkoutScreen({
    required this.workoutId,
    required this.plan,
    this.onCompleted,
    this.now = DateTime.now,
    super.key,
  });

  final String workoutId;
  final CircuitWorkoutPlan plan;

  /// Chiamata quando la fase si è chiusa e le righe sono state scritte.
  final void Function(CircuitFlowState finalState)? onCompleted;

  /// L'orologio. Non è un vezzo da test: tutto il conto alla rovescia è
  /// ancorato a una scadenza ASSOLUTA, e senza poter muovere il tempo la
  /// sequenza delle fasi resterebbe verificabile solo col cronometro in mano.
  final DateTime Function() now;

  @override
  ConsumerState<CircuitWorkoutScreen> createState() =>
      _CircuitWorkoutScreenState();
}

class _CircuitWorkoutScreenState extends ConsumerState<CircuitWorkoutScreen>
    with WidgetsBindingObserver {
  late CircuitFlowState _state;
  Timer? _ticker;

  /// La scadenza ASSOLUTA della fase. È lei a comandare, non la somma dei
  /// tick: se il telefono si blocca in tasca per due minuti, al ritorno la
  /// fase è finita, non congelata.
  DateTime? _phaseDeadline;

  bool _loading = true;
  bool _allowPop = false;
  bool _exitPromptOpen = false;
  bool _isFinalizing = false;
  bool _persisted = false;

  /// La configurazione della scheda è cambiata mentre la fase era sospesa:
  /// il progresso NON si riapplica, e all'utente va detto perché.
  bool _configurationChanged = false;

  Future<void> _checkpointQueue = Future<void>.value();
  Future<void> _cueQueue = Future<void>.value();

  /// Come nella sessione dal vivo: preso una volta, perché le scritture di
  /// chiusura possono partire mentre la rotta si sta già smontando.
  late final LiveWorkoutRepository _repository;
  late final WorkoutCueEngine _cueEngine;

  String get _resumePath => widget.plan.resumePath(widget.workoutId);

  String get _cueId => [
    'circuit',
    widget.workoutId,
    widget.plan.kind.name,
    widget.plan.segmentIndex?.toString() ?? 'none',
    widget.plan.rowIndex?.toString() ?? 'none',
  ].join(':');

  @override
  void initState() {
    super.initState();
    _repository = ref.read(liveWorkoutRepositoryProvider);
    _cueEngine = ref.read(workoutCueEngineProvider);
    WidgetsBinding.instance.addObserver(this);
    _state = CircuitFlowState.initial(
      kind: widget.plan.kind,
      steps: widget.plan.steps,
      restSec: widget.plan.restSec,
      longRestSec: widget.plan.longRestSec,
      totalRounds: widget.plan.rounds,
      segmentIndex: widget.plan.segmentIndex,
    );
    unawaited(_restore());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    unawaited(_deactivateCues(cancelCountdown: false));
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) {
      unawaited(_resumeCuesAndReconcile());
      return;
    }
    if (lifecycle == AppLifecycleState.paused && !_state.isFinished) {
      // Andando in secondo piano si segna comunque una cella il cui lavoro è
      // già scaduto, poi si salva: se l'app viene uccisa, quel lavoro non si
      // perde.
      _reconcile();
      unawaited(_saveCheckpoint());
      unawaited(_setCueSessionActive(false));
    }
  }

  // ── Ripresa ──────────────────────────────────────────────────────────────

  Future<void> _restore() async {
    try {
      final workout = await _repository.getById(widget.workoutId);
      if (!mounted) return;
      if (workout == null) {
        throw StateError('La sessione non esiste più.');
      }
      final fresh = CircuitFlowState.initial(
        kind: widget.plan.kind,
        steps: widget.plan.steps,
        restSec: widget.plan.restSec,
        longRestSec: widget.plan.longRestSec,
        totalRounds: widget.plan.rounds,
        segmentIndex: widget.plan.segmentIndex,
        completed: widget.plan.completedFrom(workout),
      );
      final result = restoreCircuitFlow(
        fresh: fresh,
        checkpoint: workout.circuitCheckpoint,
        now: widget.now(),
      );
      setState(() {
        if (result.state case final restored?) {
          _state = restored;
        } else {
          _state = fresh;
        }
        _configurationChanged =
            result.refusal == CircuitRestoreRefusal.configurationChanged;
        _loading = false;
      });
    } catch (_) {
      // Un checkpoint illeggibile non impedisce di allenarsi: si riparte da
      // capo, che è sempre corretto anche se meno comodo.
      if (!mounted) return;
      setState(() => _loading = false);
    }
    if (!mounted) return;
    if (_state.isFinished) {
      unawaited(_deactivateCues(cancelCountdown: true));
      unawaited(_finish());
      return;
    }
    _startTicker();
    unawaited(_saveCheckpoint());
    unawaited(_activateCues());
  }

  // ── Guida vocale, segnali e schermo attivo ──────────────────────────────

  Future<void> _enqueueCue(Future<void> Function() action) {
    _cueQueue = _cueQueue.catchError((_) {}).then((_) async {
      try {
        await action();
      } catch (_) {
        // La guida è accessoria: non può mai bloccare il timer o il
        // salvataggio delle celle completate.
      }
    });
    return _cueQueue;
  }

  Future<void> _activateCues() => _enqueueCue(() async {
    await _cueEngine.initialize();
    await _cueEngine.setSessionActive(true);
    // Prima recupera l'eventuale scadenza sopravvissuta al processo, poi la
    // riallinea allo stesso deadline assoluto usato dalla schermata.
    await _cueEngine.synchronize();
    if (!mounted || _state.isFinished) return;
    final state = _state;
    final deadline = _phaseDeadline;
    if (state.secondsLeft > 0) {
      await _cueEngine.emit(_cueForState(state));
    }
    await _scheduleCue(state, deadline);
  });

  Future<void> _resumeCuesAndReconcile() async {
    await _enqueueCue(() async {
      await _cueEngine.setSessionActive(true);
      await _cueEngine.synchronize();
    });
    if (!mounted) return;
    _reconcile();
    final state = _state;
    final deadline = _phaseDeadline;
    await _enqueueCue(() => _scheduleCue(state, deadline));
  }

  Future<void> _setCueSessionActive(bool active) =>
      _enqueueCue(() => _cueEngine.setSessionActive(active));

  Future<void> _deactivateCues({required bool cancelCountdown}) =>
      _enqueueCue(() async {
        if (cancelCountdown) {
          await _cueEngine.cancelScheduled(_cueId);
        }
        await _cueEngine.setSessionActive(false);
        await _cueEngine.stopVoice();
      });

  Future<void> _pauseCues() => _enqueueCue(() async {
    await _cueEngine.cancelScheduled(_cueId);
    await _cueEngine.setSessionActive(false);
    await _cueEngine.emit(const WorkoutPausedCue());
  });

  Future<void> _resumeCues() {
    final state = _state;
    final deadline = _phaseDeadline;
    return _enqueueCue(() async {
      await _cueEngine.setSessionActive(true);
      await _cueEngine.emit(const WorkoutResumedCue());
      if (!state.isFinished) await _cueEngine.emit(_cueForState(state));
      await _scheduleCue(state, deadline);
    });
  }

  Future<void> _announceTransition(
    CircuitTransition transition, {
    required DateTime? deadline,
  }) => _enqueueCue(() async {
    final wasPending = _cueEngine.pending.any((cue) => cue.id == _cueId);
    await _cueEngine.cancelScheduled(_cueId);

    // Se il countdown durevole è già scattato, il cue primario è già stato
    // pronunciato. Se era ancora pendente lo prende in carico la transizione
    // UI, evitando sia silenzi sia il doppio annuncio normale.
    if (wasPending) {
      await _cueEngine.emit(_cueForState(transition.state));
    }
    final next = transition.state.nextStep;
    if (transition.state.phase.isResting && next != null) {
      await _cueEngine.emit(
        CircuitPhaseCue(
          phase: WorkoutCircuitPhase.transition,
          exerciseName: next.exerciseName,
        ),
      );
    }

    if (transition.state.isFinished) {
      await _cueEngine.setSessionActive(false);
      return;
    }
    await _scheduleCue(transition.state, deadline);
  });

  Future<void> _announceSkip(
    CircuitTransition transition, {
    required DateTime? deadline,
  }) => _enqueueCue(() async {
    // Uno skip è un gesto esplicito: la vecchia scadenza non deve poter
    // parlare dopo che il cursore è già andato avanti.
    await _cueEngine.cancelScheduled(_cueId);
    if (transition.state.isFinished) {
      await _cueEngine.emit(
        const CircuitPhaseCue(phase: WorkoutCircuitPhase.completed),
      );
      await _cueEngine.setSessionActive(false);
      return;
    }
    await _cueEngine.emit(
      CircuitPhaseCue(
        phase: WorkoutCircuitPhase.transition,
        exerciseName: transition.state.currentStep?.exerciseName,
      ),
    );
    await _scheduleCue(transition.state, deadline);
  });

  Future<void> _scheduleCue(CircuitFlowState state, DateTime? deadline) async {
    if (deadline == null ||
        state.isFinished ||
        state.phase == CircuitPhase.paused) {
      await _cueEngine.cancelScheduled(_cueId);
      return;
    }
    final transition = advanceCircuitPhase(state);
    if (transition.event == CircuitEvent.none) {
      await _cueEngine.cancelScheduled(_cueId);
      return;
    }
    await _cueEngine.scheduleCountdown(
      id: _cueId,
      deadline: deadline,
      completionCue: _cueForState(transition.state),
    );
  }

  WorkoutCue _cueForState(CircuitFlowState state) => switch (state.phase) {
    CircuitPhase.prep => CircuitPhaseCue(
      phase: WorkoutCircuitPhase.transition,
      exerciseName: state.currentStep?.exerciseName,
    ),
    CircuitPhase.work => CircuitPhaseCue(
      phase: WorkoutCircuitPhase.work,
      exerciseName: state.currentStep?.exerciseName,
      duration: _positiveDuration(state.secondsLeft),
    ),
    CircuitPhase.shortRest || CircuitPhase.longRest => CircuitPhaseCue(
      phase: WorkoutCircuitPhase.recovery,
      duration: _positiveDuration(state.secondsLeft),
    ),
    CircuitPhase.done => const CircuitPhaseCue(
      phase: WorkoutCircuitPhase.completed,
    ),
    CircuitPhase.paused => const WorkoutPausedCue(),
  };

  static Duration? _positiveDuration(int seconds) =>
      seconds > 0 ? Duration(seconds: seconds) : null;

  // ── Cronometro ───────────────────────────────────────────────────────────

  void _startTicker() {
    _ticker?.cancel();
    _resetDeadline();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _resetDeadline() {
    if (_state.phase == CircuitPhase.paused || _state.isFinished) {
      _phaseDeadline = null;
      return;
    }
    _phaseDeadline = widget.now().add(Duration(seconds: _state.secondsLeft));
  }

  /// Riallinea i secondi alla scadenza assoluta e segna il lavoro scaduto.
  void _reconcile() {
    final deadline = _phaseDeadline;
    if (deadline == null ||
        _state.phase == CircuitPhase.paused ||
        _state.isFinished) {
      return;
    }
    final seconds = remainingCountdownSeconds(deadline, widget.now());
    if (seconds == _state.secondsLeft) return;
    setState(() => _state = _state.copyWith(secondsLeft: seconds));
    if (seconds <= 0) _advance();
  }

  void _tick() {
    if (_state.phase == CircuitPhase.paused || _state.isFinished) return;
    final deadline = _phaseDeadline;
    if (deadline == null) {
      _resetDeadline();
      return;
    }
    final next = remainingCountdownSeconds(deadline, widget.now());
    if (next == _state.secondsLeft && next > 0) return;

    if (next <= 0) {
      _advance();
    } else {
      setState(() => _state = _state.copyWith(secondsLeft: next));
    }
  }

  void _advance() {
    final transition = advanceCircuitPhase(_state);
    if (transition.event == CircuitEvent.none) return;
    setState(() => _state = transition.state);

    if (transition.event == CircuitEvent.finished) {
      _ticker?.cancel();
      unawaited(_announceTransition(transition, deadline: null));
      unawaited(_finishWithCheckpoint());
      return;
    }
    _resetDeadline();
    unawaited(_announceTransition(transition, deadline: _phaseDeadline));
    unawaited(_saveCheckpoint());
  }

  // ── Comandi ──────────────────────────────────────────────────────────────

  void _togglePause() {
    if (_state.isFinished || _isFinalizing) return;
    final pausing = _state.phase != CircuitPhase.paused;
    setState(() {
      _state = pausing ? pauseCircuit(_state) : resumeCircuit(_state);
    });
    _resetDeadline();
    unawaited(pausing ? _pauseCues() : _resumeCues());
    unawaited(_saveCheckpoint());
  }

  void _skip() {
    if (_state.isFinished || _state.phase == CircuitPhase.paused) return;
    final transition = skipCircuitStep(_state);
    setState(() => _state = transition.state);
    if (transition.event == CircuitEvent.finished) {
      _ticker?.cancel();
      unawaited(_announceSkip(transition, deadline: null));
      unawaited(_finishWithCheckpoint());
      return;
    }
    _resetDeadline();
    unawaited(_announceSkip(transition, deadline: _phaseDeadline));
    unawaited(_saveCheckpoint());
  }

  // ── Scritture ────────────────────────────────────────────────────────────

  Future<void> _saveCheckpoint() {
    final checkpoint = _state.checkpoint(phaseDeadline: _phaseDeadline)
      ..['plan'] = widget.plan.toJson();
    _checkpointQueue = _checkpointQueue
        .catchError((_) {})
        .then(
          (_) => _repository.updateResumeState(
            widget.workoutId,
            resumePath: _resumePath,
            circuitCheckpoint: checkpoint,
          ),
        )
        // Un checkpoint non scritto non deve fermare l'allenamento: al
        // massimo si riparte dalla fase, non si perde la sessione.
        .catchError((_) {});
    return _checkpointQueue;
  }

  Future<void> _finishWithCheckpoint() async {
    // Se il commit fallisce (o l'app viene chiusa proprio allora), anche
    // l'ultima cella appena scaduta deve poter essere recuperata.
    await _saveCheckpoint();
    await _finish();
  }

  /// Chiude la fase: scrive le righe fatte e cancella la rotta di ripresa.
  Future<bool> _finish() async {
    if (_persisted) return true;
    if (_isFinalizing) return false;
    setState(() => _isFinalizing = true);
    try {
      // Nessuna vecchia scrittura di checkpoint deve poter arrivare DOPO il
      // commit e far ricomparire una fase già registrata.
      await _checkpointQueue.catchError((_) {});
      final workout = await _repository.getById(widget.workoutId);
      if (workout == null) {
        throw StateError('La sessione non esiste più.');
      }
      final updated = applyCircuitResultToWorkout(
        workout: workout,
        plan: widget.plan,
        state: _state,
      );
      await _repository.commitCircuitPhase(updated);
      if (!mounted) return true;
      setState(() {
        _persisted = true;
        _isFinalizing = false;
        _allowPop = true;
      });
      widget.onCompleted?.call(_state);
      return true;
    } catch (_) {
      if (!mounted) return false;
      setState(() => _isFinalizing = false);
      showAutoClosingSnackBar(
        ScaffoldMessenger.of(context),
        SnackBar(
          content: const Text(
            'Non ho salvato questo blocco. Il lavoro fatto è ancora qui.',
          ),
          action: SnackBarAction(
            label: 'Riprova',
            onPressed: () => unawaited(_finish()),
          ),
        ),
      );
      return false;
    }
  }

  Future<void> _handleExitRequest() async {
    if (_exitPromptOpen || _isFinalizing) return;
    if (_state.isFinished) {
      if (!_persisted) {
        final saved = await _finish();
        if (!mounted || !saved) return;
      }
      await _deactivateCues(cancelCountdown: true);
      if (!mounted) return;
      setState(() => _allowPop = true);
      Navigator.of(context).pop();
      return;
    }

    _exitPromptOpen = true;
    // Uscendo si mette comunque in pausa: il tempo lontano non deve entrare
    // nella fase, e il checkpoint deve fotografare uno stato fermo.
    final wasRunning = _state.phase != CircuitPhase.paused;
    if (wasRunning) setState(() => _state = pauseCircuit(_state));
    if (wasRunning) {
      await _pauseCues();
    } else {
      await _deactivateCues(cancelCountdown: true);
    }
    if (!mounted) return;
    bool? leave;
    try {
      leave = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
          ),
          title: Text(
            'Esci dal ${widget.plan.kind.label.toLowerCase()}?',
            style: Theme.of(dialogContext).textTheme.headlineSmall,
          ),
          content: Text(
            'Quello che hai già completato resta salvato. Le celle non finite '
            'no: non sono state fatte.',
            style: Theme.of(
              dialogContext,
            ).textTheme.bodyMedium?.copyWith(height: 1.4),
          ),
          actionsOverflowDirection: VerticalDirection.down,
          actions: [
            TextButton(
              key: const Key('circuit_exit_stay'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Resto qui'),
            ),
            FilledButton(
              key: const Key('circuit_exit_leave'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Esci e salva'),
            ),
          ],
        ),
      );
    } finally {
      _exitPromptOpen = false;
    }
    if (!mounted) return;
    if (leave != true) {
      if (wasRunning) {
        setState(() => _state = resumeCircuit(_state));
        _resetDeadline();
        unawaited(_resumeCues());
      }
      return;
    }
    _ticker?.cancel();
    final saved = await _finish();
    if (!mounted || !saved) return;
    await _deactivateCues(cancelCountdown: true);
    if (!mounted) return;
    setState(() => _allowPop = true);
    Navigator.of(context).pop();
  }

  // ── Costruzione ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LiveWorkoutExitGuard(
      allowPop: _allowPop,
      onExitRequested: () => unawaited(_handleExitRequest()),
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            key: const Key('circuit_back'),
            onPressed: () => unawaited(_handleExitRequest()),
            tooltip: 'Esci dal blocco',
            icon: const Icon(Icons.close_rounded),
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.plan.kind.label,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (_state.progressLabel.isNotEmpty)
                Text(
                  _state.progressLabel,
                  key: const Key('circuit_progress_label'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppAccents.of(context).mutedInk,
                  ),
                ),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : SafeArea(
                child: AdaptiveContent(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: _state.isFinished
                        ? _CircuitDoneView(
                            state: _state,
                            saving: _isFinalizing,
                            onLeave: () => unawaited(_handleExitRequest()),
                          )
                        : Column(
                            children: [
                              if (_configurationChanged) ...[
                                const _ConfigurationChangedNotice(),
                                const SizedBox(height: 12),
                              ],
                              Expanded(
                                child: CircuitStage(
                                  state: _state,
                                  onTogglePause: _togglePause,
                                  onSkip: _skip,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
      ),
    );
  }
}

class _ConfigurationChangedNotice extends StatelessWidget {
  const _ConfigurationChangedNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: accents.warningSurface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: accents.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: accents.warning, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'La scheda è cambiata mentre questo blocco era sospeso: '
              'riparto da capo, così il lavoro fatto non finisce sull\'esercizio '
              'sbagliato.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: accents.warning,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CircuitDoneView extends StatelessWidget {
  const _CircuitDoneView({
    required this.state,
    required this.saving,
    required this.onLeave,
  });

  final CircuitFlowState state;
  final bool saving;
  final VoidCallback onLeave;

  @override
  Widget build(BuildContext context) {
    final count = circuitCompletionCount(state);
    final complete = count.done >= count.total;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AppEmptyState(
          icon: complete
              ? Icons.emoji_events_rounded
              : Icons.flag_circle_rounded,
          title: complete ? 'Blocco finito' : 'Blocco interrotto',
          message: complete
              ? 'Tutte le ${count.total} celle sono andate. '
                    'Il lavoro è già nella sessione.'
              : '${count.done} celle su ${count.total}. '
                    'Ho salvato quelle finite davvero, non le altre.',
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          key: const Key('circuit_done_continue'),
          onPressed: saving ? null : onLeave,
          icon: saving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                )
              : const Icon(Icons.arrow_forward_rounded),
          label: Text(saving ? 'Sto salvando…' : 'Torna all\'allenamento'),
        ),
      ],
    );
  }
}
