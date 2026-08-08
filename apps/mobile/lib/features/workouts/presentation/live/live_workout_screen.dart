import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/workouts/domain/cool_down_sequence.dart';
import 'package:kal_tracker/features/workouts/domain/kcal_estimator.dart';
import 'package:kal_tracker/features/workouts/domain/live_workout_focus.dart';
import 'package:kal_tracker/features/workouts/domain/live_workout_repository.dart';
import 'package:kal_tracker/features/workouts/domain/muscle_group_snapshot.dart';
import 'package:kal_tracker/features/workouts/domain/personal_records.dart';
import 'package:kal_tracker/features/workouts/domain/rest_timer_controller.dart';
import 'package:kal_tracker/features/workouts/domain/session_effort.dart';
import 'package:kal_tracker/features/workouts/domain/set_completion_guard.dart';
import 'package:kal_tracker/features/workouts/domain/superset_flow.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';
import 'package:kal_tracker/features/workouts/domain/workout_finalization.dart';
import 'package:kal_tracker/features/workouts/domain/workout_set_mutation.dart';
import 'package:kal_tracker/features/workouts/presentation/live/live_workout_providers.dart';
import 'package:kal_tracker/features/workouts/presentation/widgets/exercise_block_card.dart';
import 'package:kal_tracker/features/workouts/presentation/widgets/live_workout_exit_guard.dart';
import 'package:kal_tracker/features/workouts/presentation/widgets/rest_timer_banner.dart';
import 'package:kal_tracker/features/workouts/presentation/widgets/session_effort_sheet.dart';

/// La sessione dal vivo: l'unica schermata dell'app che si usa con le mani
/// sporche di magnesite, quindi quella dove ogni bersaglio è grande e nessuna
/// azione è irreversibile senza conferma.
///
/// Regge il flusso di Gym Tracker: serie da spuntare, recupero automatico,
/// superserie in ordine per round, record personali celebrati sul momento,
/// uscita protetta con «continua / pausa / chiudi», ripresa dopo la pausa e
/// proposta di defaticamento alla fine.
///
/// Una cosa in più rispetto a Gym: la sessione non si chiude finché non si è
/// detto com'è andata. È l'unica domanda obbligatoria dell'app, e c'è perché
/// la risposta facoltativa arrivava in 17 sessioni su 29.
class LiveWorkoutScreen extends ConsumerStatefulWidget {
  const LiveWorkoutScreen({
    required this.workoutId,
    this.onOpenPhase,
    this.onClosed,
    super.key,
  });

  final String workoutId;

  /// Riporta dentro un blocco a tempo lasciato a metà. Il collegamento alla
  /// rotta lo fa chi possiede il router: qui c'è solo il pulsante.
  final void Function(String resumePath)? onOpenPhase;

  /// Chiamata dopo una chiusura andata a buon fine, con la sessione conclusa.
  final void Function(Workout closed)? onClosed;

  @override
  ConsumerState<LiveWorkoutScreen> createState() => _LiveWorkoutScreenState();
}

class _LiveWorkoutScreenState extends ConsumerState<LiveWorkoutScreen>
    with WidgetsBindingObserver {
  Workout? _workout;
  Object? _loadError;
  bool _loading = true;

  /// Vero da quando parte una chiusura o una pausa: da lì in poi la schermata
  /// non accetta più modifiche, altrimenti l'istantanea finale cambierebbe
  /// sotto ai piedi della scrittura.
  bool _isFinishing = false;
  bool _allowPop = false;
  bool _exitPromptOpen = false;

  /// La risposta sui tre bersagli, tenuta da parte appena arriva.
  ///
  /// Una chiusura fallita riparte da capo dalla snackbar «Riprova»: chiedere
  /// di nuovo com'è andata farebbe pagare a chi si allena un errore di
  /// scrittura, e la seconda risposta sarebbe pure meno sincera della prima.
  SessionEffort? _effort;

  Duration _elapsed = Duration.zero;
  Timer? _elapsedTicker;

  final RestTimerController _rest = RestTimerController();

  /// Due tocchi rapidi sullo stesso «fatta» arrivano prima che la scrittura
  /// finisca: il lucchetto li fa diventare uno solo.
  final SetCompletionGuard _completionGuard = SetCompletionGuard();
  WorkoutCursor? _busyCursor;

  /// I record PRIMA di oggi. Confrontare con lo storico compreso l'allenamento
  /// in corso farebbe «battere sé stessi» a ogni serie.
  Map<String, ExerciseRecord> _recordBaseline = const {};

  double _bodyKg = kDefaultBodyKg;
  String _bodyKgSource = '';

  /// Le scritture sono in coda: la sessione dal vivo ne genera molte e
  /// ravvicinate, e due `await` paralleli sullo stesso allenamento si
  /// sovrascriverebbero a vicenda.
  Future<void> _saveQueue = Future<void>.value();
  Timer? _saveDebounce;

  /// La superserie che sta guidando il recupero, se ce n'è una.
  List<int>? _guidedGroup;

  /// Preso UNA volta e tenuto: `ref` non è più leggibile dentro `dispose`,
  /// e proprio lì serve — è dove sta la rete di sicurezza del salvataggio.
  late final LiveWorkoutRepository _repository;

  @override
  void initState() {
    super.initState();
    _repository = ref.read(liveWorkoutRepositoryProvider);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _elapsedTicker?.cancel();
    _saveDebounce?.cancel();
    _rest.dispose();
    // Rete di sicurezza per la sola distruzione IMPREVISTA: un'uscita
    // controllata ha già atteso la sua istantanea, e una sessione chiusa ha
    // lato repository dati più nuovi di questa copia.
    final workout = _workout;
    if (shouldFlushWorkoutOnDispose(
          isFinishing: _isFinishing,
          workout: workout,
        ) &&
        workout != null) {
      unawaited(_repository.saveWorkout(workout).catchError((_) {}));
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Al ritorno in primo piano i timer periodici sono stati sospesi ma le
    // scadenze assolute no: si riallinea tutto invece di riprendere a contare
    // da dove si era rimasti.
    _rest.synchronize();
    _refreshElapsed();
  }

  // ── Caricamento e ripresa ────────────────────────────────────────────────

  Future<void> _load() async {
    try {
      final workout = await _repository.getById(widget.workoutId);
      if (workout == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _loadError = 'Questo allenamento non esiste più.';
        });
        return;
      }

      final resumed = _resumeFromPause(workout);
      final weights = await _repository.recentBodyWeights();
      final history = await _repository.recentClosedWorkouts();

      if (!mounted) return;
      final body = pickBodyKg(measurements: weights);
      setState(() {
        _workout = resumed;
        _bodyKg = body.kg;
        _bodyKgSource = body.source;
        _recordBaseline = recordsFromHistory(
          history,
          excludeWorkoutId: workout.id,
        );
        _loading = false;
      });
      if (resumed.pausedAt == null && workout.pausedAt != null) {
        // La ripresa è una scrittura vera: se l'app muore adesso, il tempo di
        // pausa deve restare contato.
        await _enqueueSave(resumed);
      }
      _startElapsedTicker();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error;
      });
    }
  }

  /// Chiude la pausa in corso sommandola alle pause accumulate.
  ///
  /// È il pezzo che rende onesto il tempo: senza, una sessione ripresa il
  /// giorno dopo risulterebbe durata quindici ore, e le calorie con lei.
  Workout _resumeFromPause(Workout workout) {
    final pausedAt = workout.pausedAt;
    if (pausedAt == null) return workout;
    final away = DateTime.now().difference(pausedAt).inSeconds;
    return workout.copyWith(
      accumulatedPauseSeconds:
          workout.accumulatedPauseSeconds + (away > 0 ? away : 0),
      clearPausedAt: true,
    );
  }

  void _startElapsedTicker() {
    _refreshElapsed();
    _elapsedTicker?.cancel();
    _elapsedTicker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _refreshElapsed(),
    );
  }

  void _refreshElapsed() {
    final workout = _workout;
    if (workout == null || !mounted) return;
    final raw = DateTime.now().difference(workout.startedAt);
    final active = raw - Duration(seconds: workout.accumulatedPauseSeconds);
    setState(() => _elapsed = active.isNegative ? Duration.zero : active);
  }

  // ── Scritture ────────────────────────────────────────────────────────────

  Future<void> _enqueueSave(Workout snapshot) {
    _saveQueue = _saveQueue
        .catchError((_) {})
        .then((_) => _repository.saveWorkout(snapshot));
    return _saveQueue;
  }

  /// Le modifiche ai campi (peso, ripetizioni, sforzo) arrivano a raffica
  /// mentre si trascina: si scrivono dopo un attimo di quiete, non a ogni
  /// pixel.
  void _saveSoon() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 700), () {
      final workout = _workout;
      if (workout != null) unawaited(_enqueueSave(workout));
    });
  }

  Future<void> _flushSave(Workout snapshot) {
    _saveDebounce?.cancel();
    return _enqueueSave(snapshot);
  }

  // ── Gesti sulle serie ────────────────────────────────────────────────────

  void _onSetChanged(int exerciseIndex, int setIndex, WorkoutSet set) {
    final workout = _workout;
    if (workout == null || _isFinishing) return;
    setState(
      () => _workout = replaceWorkoutSet(workout, exerciseIndex, setIndex, set),
    );
    _saveSoon();
  }

  Future<void> _onSetComplete(int exerciseIndex, int setIndex) async {
    final before = _workout;
    if (before == null || _isFinishing) return;
    if (!_completionGuard.acquire(exerciseIndex, setIndex)) return;

    setState(
      () => _busyCursor = (exerciseIndex: exerciseIndex, setIndex: setIndex),
    );
    try {
      final set = before.exercises[exerciseIndex].sets[setIndex];
      final toggled = set.copyWith(completed: !set.completed);
      final next = replaceWorkoutSet(before, exerciseIndex, setIndex, toggled);
      setState(() => _workout = next);
      HapticFeedback.selectionClick();
      await _flushSave(next);
      if (!mounted) return;

      if (toggled.completed) {
        _celebratePersonalRecord(exerciseIndex, toggled);
        _startRestAfter(before, exerciseIndex, setIndex);
      } else {
        // Riaprire una serie ferma il recupero che quella serie aveva
        // avviato: continuare a contare non avrebbe più un riferimento.
        _rest.cancel();
        _guidedGroup = null;
      }
    } catch (error) {
      if (!mounted) return;
      // La copia in memoria è avanti rispetto al database: va riportata
      // indietro, altrimenti l'utente crede di aver registrato una serie che
      // non c'è.
      setState(() => _workout = before);
      showAutoClosingSnackBar(
        ScaffoldMessenger.of(context),
        SnackBar(
          content: const Text('Serie non salvata. Riprova.'),
          action: SnackBarAction(
            label: 'Riprova',
            onPressed: () => unawaited(_onSetComplete(exerciseIndex, setIndex)),
          ),
        ),
      );
    } finally {
      _completionGuard.release(exerciseIndex, setIndex);
      if (mounted) setState(() => _busyCursor = null);
    }
  }

  /// Avvia il recupero giusto per la cella appena completata.
  ///
  /// Dentro una superserie il recupero NON parte fra un membro e l'altro:
  /// parte solo quando il round si chiude. È la regola che
  /// `calculateSupersetCompletionTransition` conosce, e per questo riceve
  /// l'istantanea PRIMA del completamento.
  void _startRestAfter(Workout before, int exerciseIndex, int setIndex) {
    final exercise = before.exercises[exerciseIndex];
    if (exercise.isCooldown) return;

    final group = supersetGroupContaining(before, exerciseIndex);
    if (group != null) {
      final transition = calculateSupersetCompletionTransition(before, group, (
        exerciseIndex: exerciseIndex,
        setIndex: setIndex,
      ));
      if (!transition.shouldRest) {
        // Prossima stazione subito: è il senso della superserie.
        _guidedGroup = group;
        final next = transition.next;
        if (next != null && mounted) {
          _announce(
            'Vai su ${before.exercises[next.exerciseIndex].exerciseName}',
          );
        }
        return;
      }
      _guidedGroup = group;
    } else {
      _guidedGroup = null;
    }

    final seconds = exercise.restSeconds ?? 0;
    if (seconds <= 0) return;
    _rest.start(Duration(seconds: seconds));
  }

  /// Confronta la serie appena chiusa con i record precedenti a oggi.
  void _celebratePersonalRecord(int exerciseIndex, WorkoutSet set) {
    final workout = _workout;
    if (workout == null || set.isWarmup) return;
    final kg = set.weightKg;
    final reps = set.reps;
    if (kg == null || kg <= 0 || reps == null || reps <= 0) return;

    final exercise = workout.exercises[exerciseIndex];
    final previous = _recordBaseline[exercise.exerciseId];
    if (previous == null) return; // La prima volta è la base, non un record.

    final estimated = epley1Rm(kg, reps);
    final heavier = kg > previous.bestWeight + 0.001;
    final stronger = estimated > previous.bestE1rm + 0.001;
    if (!heavier && !stronger) return;

    HapticFeedback.mediumImpact();
    final message = heavier
        ? 'Record: ${formatKg(kg)} kg su ${exercise.exerciseName}, '
              'più di ${formatKg(previous.bestWeight)}.'
        : 'Record: ${exercise.exerciseName} vale ora '
              '${formatKg(estimated)} kg di massimale stimato.';
    _announce(message, emphasis: true);
  }

  void _announce(String message, {bool emphasis = false}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    // Senza azione la snackbar si chiude da sola; con azione no, su questo
    // Flutter, ed è il motivo dell'helper.
    messenger.showSnackBar(
      SnackBar(
        content: Row(
          children: [
            if (emphasis) ...[
              const Icon(Icons.emoji_events_rounded, size: 20),
              const SizedBox(width: 10),
            ],
            Expanded(child: Text(message)),
          ],
        ),
        duration: Duration(seconds: emphasis ? 5 : 3),
      ),
    );
  }

  void _addRound(List<int> exerciseIndices) {
    final workout = _workout;
    if (workout == null || _isFinishing) return;
    final next = appendSupersetRound(
      workout,
      exerciseIndices,
      emptySetFactory: (exercise) => WorkoutSet(isWarmup: exercise.isWarmup),
    );
    setState(() => _workout = next);
    unawaited(_flushSave(next));
  }

  Future<void> _editRest(List<int> exerciseIndices) async {
    final workout = _workout;
    if (workout == null || exerciseIndices.isEmpty) return;
    final current = workout.exercises[exerciseIndices.first].restSeconds ?? 60;
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (sheetContext) => _RestPickerSheet(initialSeconds: current),
    );
    if (picked == null || !mounted) return;

    final exercises = List<WorkoutExercise>.of(workout.exercises);
    for (final index in exerciseIndices) {
      exercises[index] = exercises[index].copyWith(restSeconds: picked);
    }
    final next = workout.copyWith(exercises: exercises);
    setState(() => _workout = next);
    unawaited(_flushSave(next));
  }

  // ── Uscita, pausa, chiusura ──────────────────────────────────────────────

  Future<void> _handleExitRequest() async {
    if (_isFinishing || _exitPromptOpen) return;
    _exitPromptOpen = true;
    WorkoutExitChoice? choice;
    try {
      choice = await askWorkoutExitChoice(context);
    } finally {
      _exitPromptOpen = false;
    }
    if (!mounted) return;
    switch (choice) {
      case WorkoutExitChoice.pause:
        await _pauseAndLeave();
      case WorkoutExitChoice.finish:
        await _finish();
      case WorkoutExitChoice.continueWorkout:
      case null:
        break;
    }
  }

  Future<void> _pauseAndLeave() async {
    final workout = _workout;
    if (workout == null || _isFinishing) return;
    setState(() => _isFinishing = true);
    _rest.cancel();
    _elapsedTicker?.cancel();
    try {
      final paused = workout.copyWith(pausedAt: DateTime.now());
      await _flushSave(paused);
      if (!mounted) return;
      setState(() {
        _workout = paused;
        _allowPop = true;
      });
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _isFinishing = false);
      _startElapsedTicker();
      showAutoClosingSnackBar(
        ScaffoldMessenger.of(context),
        SnackBar(
          content: const Text('Pausa non salvata: sei ancora dentro.'),
          action: SnackBarAction(
            label: 'Riprova',
            onPressed: () => unawaited(_pauseAndLeave()),
          ),
        ),
      );
    }
  }

  Future<void> _finish() async {
    final workout = _workout;
    if (workout == null || _isFinishing) return;

    final withCoolDown = await _offerCoolDown(workout);
    if (!mounted) return;
    // Il defaticamento accettato si tiene SUBITO, prima di chiedere altro.
    // Restava una variabile locale fino al salvataggio finale, e con la
    // domanda dello sforzo in mezzo bastava che il sistema smontasse quel
    // foglio perché gli esercizi appena accettati sparissero — e alla ripresa
    // «Defaticamento?» ripartiva da capo, come se non avesse mai risposto.
    _workout = withCoolDown;

    final effort = _effort ?? await askSessionEffort(context);
    if (!mounted) return;
    // Nessuna risposta vuol dire che il foglio è stato smontato dal sistema,
    // non che la domanda si possa saltare: la sessione resta aperta, che è
    // dove il lavoro registrato è comunque al sicuro.
    if (effort == null) return;
    _effort = effort;

    setState(() => _isFinishing = true);
    _rest.cancel();
    _elapsedTicker?.cancel();
    try {
      final snapshot = finalizeWorkoutSnapshot(
        workout: withCoolDown,
        endedAt: DateTime.now(),
        bodyKg: _bodyKg,
        effort: effort,
      );
      await _flushSave(withCoolDown);
      await _repository.finalizeWorkout(snapshot);
      if (!mounted) return;
      setState(() {
        _workout = snapshot;
        _allowPop = true;
      });
      widget.onClosed?.call(snapshot);
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() => _isFinishing = false);
      _startElapsedTicker();
      showAutoClosingSnackBar(
        ScaffoldMessenger.of(context),
        SnackBar(
          content: const Text(
            'Chiusura non riuscita: l\'allenamento è ancora aperto.',
          ),
          action: SnackBarAction(
            label: 'Riprova',
            onPressed: () => unawaited(_finish()),
          ),
        ),
      );
    }
  }

  /// Propone il defaticamento prima di chiudere.
  ///
  /// Si offre una volta sola e solo se non c'è già: rifiutare deve costare un
  /// tocco, non una discussione.
  Future<Workout> _offerCoolDown(Workout workout) async {
    final alreadyThere = workout.exercises.any(
      (exercise) => exercise.isCooldown,
    );
    if (alreadyThere) return workout;

    final minutes = coolDownTotalDuration.inMinutes;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
        title: Text(
          'Defaticamento?',
          style: Theme.of(dialogContext).textTheme.headlineSmall,
        ),
        content: Text(
          '$minutes minuti di allungamenti guidati, poi chiudo. '
          'Non contano come lavoro: entrano nella sessione con la loro '
          'intensità vera.',
          style: Theme.of(
            dialogContext,
          ).textTheme.bodyMedium?.copyWith(height: 1.4),
        ),
        actions: [
          TextButton(
            key: const Key('cooldown_skip'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Chiudi e basta'),
          ),
          FilledButton(
            key: const Key('cooldown_accept'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Sì, defatico'),
          ),
        ],
      ),
    );
    if (accepted != true) return workout;
    return workout.copyWith(
      exercises: [...workout.exercises, ...coolDownAsWorkoutExercises()],
    );
  }

  // ── Costruzione ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final workout = _workout;

    return LiveWorkoutExitGuard(
      allowPop: _allowPop || workout == null,
      onExitRequested: _handleExitRequest,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            key: const Key('live_workout_back'),
            onPressed: _handleExitRequest,
            tooltip: 'Esci dall\'allenamento',
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                workout?.routineName ?? 'Allenamento',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (workout != null)
                Text(
                  'In corso da ${_formatDuration(_elapsed)}',
                  key: const Key('live_workout_elapsed'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppAccents.of(context).mutedInk,
                  ),
                ),
            ],
          ),
        ),
        body: _buildBody(),
        bottomNavigationBar: workout == null
            ? null
            : _BottomBar(
                rest: _rest,
                guided: _guidedGroup != null,
                onStopGuided: () {
                  _rest.cancel();
                  setState(() => _guidedGroup = null);
                },
                focus: calculateLiveWorkoutFocus(workout),
                workout: workout,
                busy: _busyCursor != null || _isFinishing,
                onCompleteCurrent: (cursor) => unawaited(
                  _onSetComplete(cursor.exerciseIndex, cursor.setIndex),
                ),
                onFinish: () => unawaited(_finish()),
              ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _loadError;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: AppEmptyState(
            icon: Icons.cloud_off_rounded,
            title: 'Non riesco ad aprirlo',
            message: error is String
                ? error
                : 'L\'allenamento non si è caricato. Riprova fra un istante.',
            actionLabel: 'Riprova',
            onAction: () {
              setState(() {
                _loading = true;
                _loadError = null;
              });
              unawaited(_load());
            },
          ),
        ),
      );
    }

    final workout = _workout!;
    final focus = calculateLiveWorkoutFocus(workout);
    final actions = WorkoutBlockActions(
      onSetChanged: _onSetChanged,
      onSetComplete: (exerciseIndex, setIndex) =>
          unawaited(_onSetComplete(exerciseIndex, setIndex)),
      onAddRound: _addRound,
      onEditRest: (indices) => unawaited(_editRest(indices)),
    );

    return AdaptiveContent(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _ProgressCard(
            workout: workout,
            focus: focus,
            elapsed: _elapsed,
            bodyKg: _bodyKg,
            bodyKgSource: _bodyKgSource,
          ),
          if (workout.resumePath case final path?)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _ResumePhaseCard(
                onOpen: widget.onOpenPhase == null
                    ? null
                    : () => widget.onOpenPhase!(path),
              ),
            ),
          const SizedBox(height: 12),
          ..._buildBlocks(workout, focus, actions),
        ],
      ),
    );
  }

  /// Costruisce i blocchi saltando i membri di superserie già assorbiti dal
  /// loro capogruppo: la superserie è UNA card, non due mezze.
  List<Widget> _buildBlocks(
    Workout workout,
    LiveWorkoutFocus focus,
    WorkoutBlockActions actions,
  ) {
    final blocks = <Widget>[];
    var index = 0;
    while (index < workout.exercises.length) {
      final group = supersetGroupContaining(workout, index);
      if (group != null && group.first == index) {
        blocks.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: SupersetGroupCard(
              key: ValueKey('superset-${group.join('-')}'),
              workout: workout,
              memberIndices: group,
              actions: actions,
              current: focus.current,
              busyCursor: _busyCursor,
            ),
          ),
        );
        index = group.last + 1;
        continue;
      }
      blocks.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: ExerciseBlockCard(
            key: ValueKey('exercise-$index'),
            exercise: workout.exercises[index],
            exerciseIndex: index,
            actions: actions,
            current: focus.current,
            busyCursor: _busyCursor,
          ),
        ),
      );
      index++;
    }
    return blocks;
  }
}

/// Il riepilogo in cima: quanto manca, quanto hai spostato, quante calorie.
class _ProgressCard extends StatelessWidget {
  const _ProgressCard({
    required this.workout,
    required this.focus,
    required this.elapsed,
    required this.bodyKg,
    required this.bodyKgSource,
  });

  final Workout workout;
  final LiveWorkoutFocus focus;
  final Duration elapsed;
  final double bodyKg;
  final String bodyKgSource;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final missingGroups = exercisesMissingMuscleGroupSnapshot(workout);

    // Le calorie si stimano sul tempo GIÀ trascorso: la sessione non è chiusa,
    // quindi `Workout.duration` è ancora nulla e serve una proiezione.
    final projected = workout.copyWith(
      endedAt: DateTime.now(),
      finalDurationSeconds: elapsed.inSeconds,
    );
    final kcal = estimateKcal(
      workout: projected,
      exerciseGroups: muscleGroupsFromSnapshots(workout),
      bodyKg: bodyKg,
    ).kcal;

    return SectionCard(
      title: 'A che punto sei',
      subtitle: focus.totalSets == 0
          ? 'Nessuna serie in programma'
          : '${focus.completedSets} serie su ${focus.totalSets}',
      icon: Icons.timeline_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            label: 'Avanzamento',
            value: '${(focus.progress * 100).round()} per cento',
            child: ExcludeSemantics(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  key: const Key('live_workout_progress'),
                  value: focus.progress,
                  minHeight: 10,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          StatRow(
            label: 'Durata',
            value: _formatDuration(elapsed),
            caption: 'Le pause fuori dall\'app non contano',
            icon: Icons.schedule_rounded,
          ),
          StatRow(
            label: 'Volume',
            value: workout.totalVolume.round().toString(),
            unit: 'kg',
            unitSemantics: 'chilogrammi',
            caption: 'Peso × ripetizioni, riscaldamenti esclusi',
            icon: Icons.stacked_line_chart_rounded,
          ),
          StatRow(
            key: const Key('live_workout_kcal'),
            label: 'Calorie stimate',
            value: kcal.round().toString(),
            unit: 'kcal',
            unitSemantics: 'chilocalorie',
            caption: 'Su ${bodyKg.toStringAsFixed(1)} kg — $bodyKgSource',
            icon: Icons.local_fire_department_rounded,
            trailing: missingGroups.isEmpty
                ? null
                : const StatusChip(
                    level: AppStatusLevel.warning,
                    label: 'Stima grezza',
                    compact: true,
                  ),
          ),
          if (missingGroups.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '${missingGroups.length} '
              '${missingGroups.length == 1 ? 'esercizio non ha' : 'esercizi non hanno'} '
              'il gruppo muscolare: per quelli le calorie usano un valore '
              'medio e possono sbagliare parecchio.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: accents.warning,
                height: 1.35,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ResumePhaseCard extends StatelessWidget {
  const _ResumePhaseCard({required this.onOpen});

  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Blocco a tempo lasciato a metà',
      subtitle: 'Il circuito aspetta dove l\'hai interrotto.',
      icon: Icons.replay_rounded,
      actionLabel: onOpen == null ? null : 'Riprendi',
      onAction: onOpen,
      child: Text(
        onOpen == null
            ? 'La ripresa non è ancora collegata a questa schermata.'
            : 'Riprendi da lì: il progresso già fatto non si ripete.',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: AppAccents.of(context).mutedInk,
          height: 1.35,
        ),
      ),
    );
  }
}

/// La barra in fondo: il recupero quando c'è, e sotto l'azione principale.
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.rest,
    required this.guided,
    required this.onStopGuided,
    required this.focus,
    required this.workout,
    required this.busy,
    required this.onCompleteCurrent,
    required this.onFinish,
  });

  final RestTimerController rest;
  final bool guided;
  final VoidCallback onStopGuided;
  final LiveWorkoutFocus focus;
  final Workout workout;
  final bool busy;
  final void Function(WorkoutCursor cursor) onCompleteCurrent;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cursor = focus.current;

    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Divider(height: 1, color: theme.colorScheme.outline),
          RestTimerBanner(
            controller: rest,
            guided: guided,
            onStop: guided ? onStopGuided : null,
            nextLabel: cursor == null
                ? null
                : workout.exercises[cursor.exerciseIndex].exerciseName,
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: cursor == null
                  ? FilledButton.icon(
                      key: const Key('live_workout_finish'),
                      onPressed: busy ? null : onFinish,
                      icon: const Icon(Icons.flag_rounded),
                      label: const Text('Hai finito — chiudi e salva'),
                    )
                  : FilledButton.icon(
                      key: const Key('live_workout_complete_current'),
                      onPressed: busy ? null : () => onCompleteCurrent(cursor),
                      icon: const Icon(Icons.check_rounded),
                      label: Text(
                        _currentActionLabel(workout, cursor),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

String _currentActionLabel(Workout workout, WorkoutCursor cursor) {
  final exercise = workout.exercises[cursor.exerciseIndex];
  final set = exercise.sets[cursor.setIndex];
  final description = describeWorkoutSet(set, exercise.trackingMode);
  return 'Fatta: ${exercise.exerciseName} · $description';
}

/// Il foglio del recupero: valori pronti più la possibilità di toglierlo.
class _RestPickerSheet extends StatelessWidget {
  const _RestPickerSheet({required this.initialSeconds});

  final int initialSeconds;

  static const _presets = <int>[0, 30, 45, 60, 90, 120, 180];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                'Quanto recuperi?',
                style: theme.textTheme.headlineSmall,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Vale per tutto il blocco. Zero significa: nessun timer.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: accents.mutedInk,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final seconds in _presets)
                  ChoiceChip(
                    label: Text(
                      seconds == 0 ? 'Nessuno' : _formatRestPreset(seconds),
                    ),
                    selected: seconds == initialSeconds,
                    onSelected: (_) => Navigator.of(context).pop(seconds),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _formatRestPreset(int seconds) {
  if (seconds < 60) return '${seconds}s';
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  return rest == 0 ? '$minutes min' : '$minutes min ${rest}s';
}

/// mm:ss finché resta sotto l'ora, poi h:mm:ss. Chi si allena legge minuti.
String _formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}
