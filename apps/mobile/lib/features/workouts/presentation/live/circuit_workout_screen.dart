import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/workouts/domain/circuit_flow.dart';
import 'package:kal_tracker/features/workouts/domain/circuit_result.dart';
import 'package:kal_tracker/features/workouts/domain/countdown.dart';
import 'package:kal_tracker/features/workouts/domain/live_workout_repository.dart';
import 'package:kal_tracker/features/workouts/presentation/live/live_workout_providers.dart';
import 'package:kal_tracker/features/workouts/presentation/widgets/circuit_stage.dart';
import 'package:kal_tracker/features/workouts/presentation/widgets/live_workout_exit_guard.dart';

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
    required this.kind,
    required this.steps,
    this.restSec = 20,
    this.longRestSec = 60,
    this.rounds = 1,
    this.segmentIndex,
    this.onCompleted,
    this.now = DateTime.now,
    super.key,
  });

  final String workoutId;
  final CircuitKind kind;
  final List<CircuitStep> steps;
  final int restSec;
  final int longRestSec;
  final int rounds;

  /// L'indice del blocco a tempo dentro la scheda. Solo per
  /// [CircuitKind.segment].
  final int? segmentIndex;

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

  /// Come nella sessione dal vivo: preso una volta, perché le scritture di
  /// chiusura possono partire mentre la rotta si sta già smontando.
  late final LiveWorkoutRepository _repository;

  String get _resumePath {
    final base = '/workout/${widget.workoutId}/phase/${widget.kind.name}';
    if (widget.segmentIndex == null) return base;
    return Uri(
      path: base,
      queryParameters: {'seg': '${widget.segmentIndex}'},
    ).toString();
  }

  @override
  void initState() {
    super.initState();
    _repository = ref.read(liveWorkoutRepositoryProvider);
    WidgetsBinding.instance.addObserver(this);
    _state = CircuitFlowState.initial(
      kind: widget.kind,
      steps: widget.steps,
      restSec: widget.restSec,
      longRestSec: widget.longRestSec,
      totalRounds: widget.rounds,
      segmentIndex: widget.segmentIndex,
    );
    unawaited(_restore());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) {
      _reconcile();
      return;
    }
    if (lifecycle == AppLifecycleState.paused && !_state.isFinished) {
      // Andando in secondo piano si segna comunque una cella il cui lavoro è
      // già scaduto, poi si salva: se l'app viene uccisa, quel lavoro non si
      // perde.
      _reconcile();
      unawaited(_saveCheckpoint());
    }
  }

  // ── Ripresa ──────────────────────────────────────────────────────────────

  Future<void> _restore() async {
    try {
      final workout = await _repository.getById(widget.workoutId);
      if (!mounted) return;
      final result = restoreCircuitFlow(
        fresh: _state,
        checkpoint: workout?.circuitCheckpoint,
        now: widget.now(),
      );
      setState(() {
        if (result.state case final restored?) {
          _state = restored;
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
      unawaited(_finish());
      return;
    }
    _startTicker();
  }

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

    // Il ritmo delle vibrazioni di Gym: leggera a 10 e negli ultimi secondi,
    // media all'ultimo. Senza audio (questa app non ha ancora un motore di
    // suoni) è l'unico segnale che arriva col telefono in tasca.
    if (next == 10 || (next >= 2 && next <= 5)) {
      HapticFeedback.lightImpact();
    } else if (next == 1) {
      HapticFeedback.mediumImpact();
    }

    if (next <= 0) {
      _advance();
    } else {
      setState(() => _state = _state.copyWith(secondsLeft: next));
    }
  }

  void _advance() {
    final transition = advanceCircuitPhase(_state);
    if (transition.event == CircuitEvent.none) return;
    HapticFeedback.mediumImpact();
    setState(() => _state = transition.state);

    if (transition.event == CircuitEvent.finished) {
      _ticker?.cancel();
      unawaited(_finish());
      return;
    }
    _resetDeadline();
    unawaited(_saveCheckpoint());
  }

  // ── Comandi ──────────────────────────────────────────────────────────────

  void _togglePause() {
    if (_state.isFinished || _isFinalizing) return;
    setState(() {
      _state = _state.phase == CircuitPhase.paused
          ? resumeCircuit(_state)
          : pauseCircuit(_state);
    });
    _resetDeadline();
    unawaited(_saveCheckpoint());
  }

  void _skip() {
    if (_state.isFinished || _state.phase == CircuitPhase.paused) return;
    HapticFeedback.lightImpact();
    final transition = skipCircuitStep(_state);
    setState(() => _state = transition.state);
    if (transition.event == CircuitEvent.finished) {
      _ticker?.cancel();
      unawaited(_finish());
      return;
    }
    _resetDeadline();
    unawaited(_saveCheckpoint());
  }

  // ── Scritture ────────────────────────────────────────────────────────────

  Future<void> _saveCheckpoint() {
    final checkpoint = _state.checkpoint(phaseDeadline: _phaseDeadline);
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

  /// Chiude la fase: scrive le righe fatte e cancella la rotta di ripresa.
  Future<void> _finish() async {
    if (_isFinalizing || _persisted) return;
    setState(() => _isFinalizing = true);
    try {
      final workout = await _repository.getById(widget.workoutId);
      if (workout == null) {
        throw StateError('La sessione non esiste più.');
      }
      final rows = circuitAsWorkoutExercises(_state);
      final updated = workout.copyWith(
        exercises: [...workout.exercises, ...rows],
      );
      await _repository.saveWorkout(updated);
      await _repository.updateResumeState(
        widget.workoutId,
        resumePath: null,
        circuitCheckpoint: null,
      );
      if (!mounted) return;
      setState(() {
        _persisted = true;
        _isFinalizing = false;
        _allowPop = true;
      });
      widget.onCompleted?.call(_state);
    } catch (_) {
      if (!mounted) return;
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
    }
  }

  Future<void> _handleExitRequest() async {
    if (_exitPromptOpen || _isFinalizing) return;
    if (_state.isFinished && _persisted) {
      setState(() => _allowPop = true);
      Navigator.of(context).pop();
      return;
    }

    _exitPromptOpen = true;
    // Uscendo si mette comunque in pausa: il tempo lontano non deve entrare
    // nella fase, e il checkpoint deve fotografare uno stato fermo.
    final wasRunning = _state.phase != CircuitPhase.paused;
    if (wasRunning) setState(() => _state = pauseCircuit(_state));
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
            'Esci dal ${widget.kind.label.toLowerCase()}?',
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
      }
      return;
    }
    _ticker?.cancel();
    await _finish();
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
                widget.kind.label,
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
