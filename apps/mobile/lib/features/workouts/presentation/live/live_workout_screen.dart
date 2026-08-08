import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';
import 'package:kal_tracker/features/exercises/presentation/exercise_providers.dart';
import 'package:kal_tracker/features/health/domain/health_data_gateway.dart';
import 'package:kal_tracker/features/health/presentation/health_providers.dart';
import 'package:kal_tracker/features/routines/domain/routine_models.dart';
import 'package:kal_tracker/features/routines/presentation/routine_providers.dart';
import 'package:kal_tracker/features/training_profile/domain/exercise_screening.dart';
import 'package:kal_tracker/features/training_profile/domain/training_profile.dart';
import 'package:kal_tracker/features/training_profile/presentation/training_profile_providers.dart';
import 'package:kal_tracker/features/workouts/cues/application/live_workout_cue_coordinator.dart';
import 'package:kal_tracker/features/workouts/cues/workout_cue_providers.dart';
import 'package:kal_tracker/features/workouts/domain/circuit_flow.dart';
import 'package:kal_tracker/features/workouts/domain/cool_down_sequence.dart';
import 'package:kal_tracker/features/workouts/domain/kcal_estimator.dart';
import 'package:kal_tracker/features/workouts/domain/live_load_guidance.dart';
import 'package:kal_tracker/features/workouts/domain/live_workout_focus.dart';
import 'package:kal_tracker/features/workouts/domain/live_workout_repository.dart';
import 'package:kal_tracker/features/workouts/domain/load_progression.dart';
import 'package:kal_tracker/features/workouts/domain/muscle_group_snapshot.dart';
import 'package:kal_tracker/features/workouts/domain/personal_records.dart';
import 'package:kal_tracker/features/workouts/domain/rest_timer_controller.dart';
import 'package:kal_tracker/features/workouts/domain/session_effort.dart';
import 'package:kal_tracker/features/workouts/domain/set_completion_guard.dart';
import 'package:kal_tracker/features/workouts/domain/superset_flow.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';
import 'package:kal_tracker/features/workouts/domain/workout_finalization.dart';
import 'package:kal_tracker/features/workouts/domain/workout_set_mutation.dart';
import 'package:kal_tracker/features/workouts/presentation/live/circuit_workout_plan.dart';
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
  final FutureOr<void> Function(String resumePath)? onOpenPhase;

  /// Chiamata dopo una chiusura andata a buon fine, con la sessione conclusa.
  final void Function(Workout closed)? onClosed;

  @override
  ConsumerState<LiveWorkoutScreen> createState() => _LiveWorkoutScreenState();
}

class _LiveWorkoutScreenState extends ConsumerState<LiveWorkoutScreen>
    with WidgetsBindingObserver {
  Workout? _workout;
  RoutineDetails? _routine;
  Object? _loadError;
  bool _loading = true;

  /// Vero da quando parte una chiusura o una pausa: da lì in poi la schermata
  /// non accetta più modifiche, altrimenti l'istantanea finale cambierebbe
  /// sotto ai piedi della scrittura.
  bool _isFinishing = false;
  bool _allowPop = false;
  bool _exitPromptOpen = false;
  bool _openingPhase = false;

  /// La risposta sui tre bersagli, tenuta da parte appena arriva.
  ///
  /// Una chiusura fallita riparte da capo dalla snackbar «Riprova»: chiedere
  /// di nuovo com'è andata farebbe pagare a chi si allena un errore di
  /// scrittura, e la seconda risposta sarebbe pure meno sincera della prima.
  SessionEffort? _effort;

  Duration _elapsed = Duration.zero;
  Timer? _elapsedTicker;

  final RestTimerController _rest = RestTimerController();
  String? _restContextLabel;
  String? _restNextLabel;

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

  /// I valori precedenti a «Applica» restano disponibili finché non si
  /// modifica o completa una serie di quell'esercizio.
  final Map<int, WorkoutExercise> _loadGuidanceUndo = {};

  /// Preso UNA volta e tenuto: `ref` non è più leggibile dentro `dispose`,
  /// e proprio lì serve — è dove sta la rete di sicurezza del salvataggio.
  late final LiveWorkoutRepository _repository;
  late final LiveWorkoutCueCoordinator _cues;
  late final HealthDataGateway _health;

  @override
  void initState() {
    super.initState();
    _repository = ref.read(liveWorkoutRepositoryProvider);
    _health = ref.read(healthDataGatewayProvider);
    _cues = LiveWorkoutCueCoordinator(
      engine: ref.read(workoutCueEngineProvider),
      workoutId: widget.workoutId,
    );
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _elapsedTicker?.cancel();
    _saveDebounce?.cancel();
    _rest.dispose();
    unawaited(_ignoreCueFailure(() => _cues.deactivate()));
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
    if (state == AppLifecycleState.resumed) {
      // Al ritorno in primo piano i timer periodici sono stati sospesi ma le
      // scadenze assolute no: si riallinea tutto invece di riprendere a
      // contare da dove si era rimasti.
      _rest.synchronize();
      _refreshElapsed();
      unawaited(_synchronizeCueRest());
      return;
    }

    // Il debounce è giusto mentre si digitano i chili, non quando il sistema
    // sta per sospendere il processo. In quel momento l'ultima copia parte
    // immediatamente verso SQLite.
    final workout = _workout;
    if (workout != null && !_isFinishing) {
      _saveDebounce?.cancel();
      unawaited(_enqueueSave(workout).catchError((_) {}));
    }
  }

  bool _synchronizingCueRest = false;

  Future<void> _synchronizeCueRest() => _restoreCueRest();

  Future<void> _restoreCueRest() async {
    if (_synchronizingCueRest) return;
    _synchronizingCueRest = true;
    try {
      final deadline = await _cues.restoreRestDeadline();
      if (!mounted || deadline == null) return;
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return;
      final localDeadline = _rest.deadline;
      if (localDeadline != null &&
          (localDeadline.difference(deadline).inMilliseconds).abs() < 1500) {
        return;
      }
      _rest.start(remaining);
      setState(() {
        _restContextLabel ??= 'Recupero in corso';
        _restNextLabel = _cues.pendingRestNextExerciseName;
      });
    } catch (_) {
      // La sessione e il suo salvataggio non dipendono mai da voce/notifiche.
    } finally {
      _synchronizingCueRest = false;
    }
  }

  Future<void> _ignoreCueFailure(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // Audio, vibrazione e notifica sono aiuti: SQLite resta la fonte vera.
    }
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

      final wasExplicitlyPaused = workout.pausedAt != null;
      final resumed = _resumeFromPause(workout);
      final weights = await _repository.recentBodyWeights();
      final history = await _repository.recentClosedWorkouts();
      final routine = await _loadRoutine(workout);

      if (!mounted) return;
      final body = pickBodyKg(measurements: weights);
      setState(() {
        _workout = resumed;
        _routine = routine;
        _bodyKg = body.kg;
        _bodyKgSource = body.source;
        _recordBaseline = recordsFromHistory(
          history,
          excludeWorkoutId: workout.id,
        );
        _loadGuidanceUndo.clear();
        _loading = false;
      });
      if (resumed.pausedAt == null && workout.pausedAt != null) {
        // La ripresa è una scrittura vera: se l'app muore adesso, il tempo di
        // pausa deve restare contato.
        await _enqueueSave(resumed);
      }
      _startElapsedTicker();
      final alreadyInProgress =
          DateTime.now().difference(workout.startedAt) >
          const Duration(seconds: 30);
      unawaited(
        _ignoreCueFailure(
          () => _cues.activate(
            workoutName: workout.routineName,
            resumed: wasExplicitlyPaused || alreadyInProgress,
          ),
        ),
      );
      await _restoreCueRest();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error;
      });
    }
  }

  Future<RoutineDetails?> _loadRoutine(Workout workout) async {
    final routineId = workout.routineId;
    if (routineId == null) return null;
    try {
      return await ref.read(routineRepositoryProvider).getRoutine(routineId);
    } catch (_) {
      // La sessione rimane utilizzabile anche se la scheda è stata rimossa.
      // Una fase già aperta porta il proprio piano nel checkpoint.
      return null;
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

  Future<bool> _openTimedPhase(String path) async {
    final workout = _workout;
    final open = widget.onOpenPhase;
    if (workout == null || open == null || _openingPhase || _isFinishing) {
      return false;
    }
    setState(() => _openingPhase = true);
    try {
      _dismissRest();
      // Prima si consegna al database l'ultima modifica della schermata
      // madre; al ritorno si rilegge il commit della fase. Così nessuna copia
      // vecchia può riscrivere sopra le serie appena concluse.
      await _flushSave(workout);
      await Future<void>.sync(() => open(path));
      final refreshed = await _repository.getById(widget.workoutId);
      if (refreshed == null) {
        throw StateError('La sessione non esiste più.');
      }
      final routine = await _loadRoutine(refreshed);
      if (!mounted) return true;
      setState(() {
        _workout = refreshed;
        _routine = routine;
        _loadGuidanceUndo.clear();
      });
      return true;
    } catch (_) {
      if (!mounted) return false;
      showAutoClosingSnackBar(
        ScaffoldMessenger.of(context),
        const SnackBar(
          content: Text(
            'Non riesco ad aprire o ricaricare il timer. La sessione è salva.',
          ),
        ),
      );
      return false;
    } finally {
      if (mounted) setState(() => _openingPhase = false);
    }
  }

  Future<bool> _openPlan(CircuitWorkoutPlan plan) =>
      _openTimedPhase(plan.resumePath(widget.workoutId));

  // ── Gesti sulle serie ────────────────────────────────────────────────────

  void _onSetChanged(int exerciseIndex, int setIndex, WorkoutSet set) {
    final workout = _workout;
    if (workout == null || _isFinishing) return;
    _loadGuidanceUndo.remove(exerciseIndex);
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
      _loadGuidanceUndo.remove(exerciseIndex);
      setState(() => _workout = next);
      await _flushSave(next);
      if (!mounted) return;

      if (toggled.completed) {
        _celebratePersonalRecord(exerciseIndex, toggled);
        _startRestAfter(before, exerciseIndex, setIndex);
      } else {
        // Riaprire una serie ferma il recupero che quella serie aveva
        // avviato: continuare a contare non avrebbe più un riferimento.
        _dismissRest();
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
    final current = _workout ?? before;
    final target = _cueTarget(current);

    Future<void> announce({Duration? rest}) => _ignoreCueFailure(() async {
      await _cues.setCompleted(
        exerciseName: exercise.exerciseName,
        setNumber: setIndex + 1,
        totalSets: exercise.sets.length,
      );
      if (rest != null) {
        await _cues.startRest(
          duration: rest,
          deadline: DateTime.now().add(rest),
          nextExerciseName: target?.exerciseName,
        );
      } else if (target != null) {
        await _cues.nextSet(
          exerciseName: target.exerciseName,
          setNumber: target.setNumber,
          totalSets: target.totalSets,
        );
      }
    });

    final group = supersetGroupContaining(before, exerciseIndex);
    if (group != null) {
      final transition = calculateSupersetCompletionTransition(before, group, (
        exerciseIndex: exerciseIndex,
        setIndex: setIndex,
      ));
      if (!transition.shouldRest) {
        // Prossima stazione subito: è il senso della superserie.
        if (mounted) setState(() => _guidedGroup = group);
        final next = transition.next;
        if (next != null && mounted) {
          _announce(
            'Vai su ${before.exercises[next.exerciseIndex].exerciseName}',
          );
        }
        unawaited(announce());
        return;
      }
      if (mounted) setState(() => _guidedGroup = group);
    } else {
      if (mounted) setState(() => _guidedGroup = null);
    }

    final seconds = exercise.restSeconds ?? 0;
    if (seconds <= 0) {
      unawaited(announce());
      return;
    }
    final duration = Duration(seconds: seconds);
    final deadline = DateTime.now().add(duration);
    _rest.start(duration);
    if (mounted) {
      setState(() {
        _restContextLabel = '${exercise.exerciseName} · serie ${setIndex + 1}';
        _restNextLabel = target == null ? null : _cueTargetLabel(target);
      });
    }
    // La scadenza usata dal banner e quella persistita differiscono solo dei
    // pochi microsecondi necessari a costruire il messaggio.
    unawaited(
      _ignoreCueFailure(() async {
        await _cues.setCompleted(
          exerciseName: exercise.exerciseName,
          setNumber: setIndex + 1,
          totalSets: exercise.sets.length,
        );
        await _cues.startRest(
          duration: duration,
          deadline: deadline,
          nextExerciseName: target?.exerciseName,
        );
      }),
    );
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
    unawaited(
      _ignoreCueFailure(
        () => _cues.personalRecord(
          exerciseName: exercise.exerciseName,
          summary: heavier
              ? '${formatKg(kg)} chilogrammi.'
              : 'Nuovo massimale stimato.',
        ),
      ),
    );
  }

  ({String exerciseName, int setNumber, int totalSets})? _cueTarget(
    Workout workout,
  ) {
    final cursor = calculateLiveWorkoutFocus(workout).current;
    if (cursor == null) return null;
    final exercise = workout.exercises[cursor.exerciseIndex];
    return (
      exerciseName: exercise.exerciseName,
      setNumber: cursor.setIndex + 1,
      totalSets: exercise.sets.length,
    );
  }

  String _cueTargetLabel(
    ({String exerciseName, int setNumber, int totalSets}) target,
  ) =>
      '${target.exerciseName} · serie ${target.setNumber} di ${target.totalSets}';

  void _dismissRest() {
    _rest.cancel();
    unawaited(_ignoreCueFailure(_cues.cancelRest));
    if (mounted) {
      setState(() {
        _guidedGroup = null;
        _restContextLabel = null;
        _restNextLabel = null;
      });
    }
  }

  void _skipRest() {
    final target = _workout == null ? null : _cueTarget(_workout!);
    _rest.skip();
    _rest.cancel();
    unawaited(
      _ignoreCueFailure(
        () => _cues.finishRestNow(nextExerciseName: target?.exerciseName),
      ),
    );
    if (mounted) {
      setState(() {
        _guidedGroup = null;
        _restContextLabel = null;
        _restNextLabel = null;
      });
    }
  }

  void _adjustRest(Duration remaining) {
    if (remaining <= Duration.zero) {
      _skipRest();
      return;
    }
    final deadline = _rest.deadline ?? DateTime.now().add(remaining);
    final target = _workout == null ? null : _cueTarget(_workout!);
    unawaited(
      _ignoreCueFailure(
        () => _cues.rescheduleRest(
          deadline: deadline,
          nextExerciseName: target?.exerciseName,
        ),
      ),
    );
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
    for (final index in exerciseIndices) {
      _loadGuidanceUndo.remove(index);
    }
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
      _loadGuidanceUndo.remove(index);
      exercises[index] = exercises[index].copyWith(restSeconds: picked);
    }
    final next = workout.copyWith(exercises: exercises);
    setState(() => _workout = next);
    unawaited(_flushSave(next));
  }

  void _applyLoadGuidance(int exerciseIndex, LiveLoadGuidance guidance) {
    final workout = _workout;
    if (workout == null ||
        _isFinishing ||
        exerciseIndex < 0 ||
        exerciseIndex >= workout.exercises.length ||
        !guidance.canApply) {
      return;
    }
    final original = workout.exercises[exerciseIndex];
    final exercises = List<WorkoutExercise>.of(workout.exercises);
    exercises[exerciseIndex] = guidance.applyToRemaining(original);
    final next = workout.copyWith(exercises: exercises);
    _loadGuidanceUndo[exerciseIndex] = original;
    setState(() => _workout = next);
    unawaited(_flushSave(next));
  }

  void _undoLoadGuidance(int exerciseIndex) {
    final workout = _workout;
    final original = _loadGuidanceUndo.remove(exerciseIndex);
    if (workout == null ||
        original == null ||
        exerciseIndex < 0 ||
        exerciseIndex >= workout.exercises.length ||
        _isFinishing) {
      return;
    }
    final exercises = List<WorkoutExercise>.of(workout.exercises);
    exercises[exerciseIndex] = original;
    final next = workout.copyWith(exercises: exercises);
    setState(() => _workout = next);
    unawaited(_flushSave(next));
  }

  Map<int, LiveLoadGuidance> _loadGuidanceFor(
    Workout workout,
    LiveWorkoutFocus focus,
  ) {
    final cursor = focus.current;
    if (cursor == null) return const {};
    final exercise = workout.exercises[cursor.exerciseIndex];
    if (exercise.isWarmup ||
        exercise.isCooldown ||
        exercise.trackingMode.isTimed) {
      return const {};
    }
    // La proposta deve poter spiegare la prescrizione che sta applicando.
    // In una sessione libera non c'è una riga di scheda né un intervallo:
    // copiare un vecchio peso lì sembrerebbe un consiglio senza contesto.
    final routine = _routine;
    if (routine == null) return const {};

    final history = ref
        .watch(lastWorkSetsProvider(lastWorkSetsKey([exercise.exerciseId])))
        .valueOrNull;
    final profile = ref.watch(trainingProfileProvider).valueOrNull;
    final catalog = ref.watch(exerciseCatalogProvider).valueOrNull;
    if (history == null || profile == null || catalog == null) return const {};

    RoutineExerciseRef? routineRow;
    for (final row in [...routine.main, ...routine.finisher]) {
      if (row.exerciseRefId == exercise.exerciseId) {
        routineRow = row;
        break;
      }
    }
    Exercise? catalogExercise;
    for (final item in catalog) {
      if (item.id == exercise.exerciseId) {
        catalogExercise = item;
        break;
      }
    }
    final tools = catalogExercise == null
        ? const <Equipment>{}
        : {
            for (final requirement in ExerciseScreener.requirementsOf(
              catalogExercise,
            ))
              ...requirement.options,
          };
    final advice = LoadProgression.advise(
      sets: history[exercise.exerciseId] ?? const <WorkoutSet>[],
      range: routineRow?.prescription.range,
      tools: tools,
      owned: profile.equipment,
      prescribedSets: routineRow?.prescription.sets ?? exercise.sets.length,
    );
    final guidance = LiveLoadGuidance.from(
      lastSets: history[exercise.exerciseId] ?? const <WorkoutSet>[],
      plannedSets: exercise.sets,
      advice: advice,
    );
    return guidance.hasHistory
        ? {cursor.exerciseIndex: guidance}
        : const <int, LiveLoadGuidance>{};
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
    _dismissRest();
    _elapsedTicker?.cancel();
    try {
      final paused = workout.copyWith(pausedAt: DateTime.now());
      await _flushSave(paused);
      if (!mounted) return;
      setState(() {
        _workout = paused;
        _allowPop = true;
      });
      await _ignoreCueFailure(() async {
        await _cues.paused();
        await _cues.deactivate(stopVoice: false);
      });
      if (!mounted) return;
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
    final initial = _workout;
    if (initial == null || _isFinishing || _openingPhase) return;
    var current = initial;

    // Il tasto finale è anche il proseguimento naturale della scheda: prima
    // completa, nell'ordine, riscaldamento/circuiti/blocchi a tempo; solo dopo
    // propone di chiudere la sessione.
    while (true) {
      final pending = circuitPlansForWorkout(
        current,
        routine: _routine,
      ).where((plan) => plan.kind != CircuitKind.cooldown).toList();
      if (pending.isEmpty) break;
      final plan = pending.first;
      final opened = await _openPlan(plan);
      if (!mounted || !opened) return;
      final refreshed = _workout;
      if (refreshed == null) return;
      current = refreshed;
      final currentId = current.id;
      final stillPending = circuitPlansForWorkout(current, routine: _routine)
          .any(
            (candidate) =>
                candidate.resumePath(currentId) == plan.resumePath(currentId),
          );
      // È uscito prima della fine: niente catena automatica e, soprattutto,
      // niente chiusura che fingerebbe completato il resto.
      if (stillPending) return;
    }

    var withCoolDown = await _offerCoolDown(current);
    if (!mounted) return;
    setState(() => _workout = withCoolDown);

    final cooldown = circuitPlansForWorkout(
      withCoolDown,
      routine: _routine,
    ).where((plan) => plan.kind == CircuitKind.cooldown).firstOrNull;
    if (cooldown != null) {
      final opened = await _openPlan(cooldown);
      if (!mounted || !opened) return;
      withCoolDown = _workout ?? withCoolDown;
      final cooldownStillPending = circuitPlansForWorkout(
        withCoolDown,
        routine: _routine,
      ).any((plan) => plan.kind == CircuitKind.cooldown);
      if (cooldownStillPending) return;
    }

    final effort = _effort ?? await askSessionEffort(context);
    if (!mounted) return;
    // Nessuna risposta vuol dire che il foglio è stato smontato dal sistema,
    // non che la domanda si possa saltare: la sessione resta aperta, che è
    // dove il lavoro registrato è comunque al sicuro.
    if (effort == null) return;
    _effort = effort;

    setState(() => _isFinishing = true);
    _dismissRest();
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
      await _ignoreCueFailure(
        () => _cues.completed(workoutName: snapshot.routineName),
      );
      if (!mounted) return;
      // Health Connect/HealthKit è un'uscita secondaria: la sessione locale è
      // già conclusa e si chiude subito. Se manca il consenso, la schermata
      // Salute permetterà di esportarla in seguito.
      unawaited(_syncFinalizedWorkoutToHealth(snapshot));
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

  Future<void> _syncFinalizedWorkoutToHealth(Workout workout) async {
    final endedAt = workout.endedAt;
    if (endedAt == null || workout.syncedToHealthConnect) return;
    try {
      final status = await _health.status();
      if (!status.supports(HealthCapability.writeWorkout) ||
          !status.isGranted(HealthCapability.writeWorkout)) {
        return;
      }
      final result = await _health.writeWorkout(
        HealthWorkoutRecord(
          id: workout.id,
          title: workout.routineName ?? 'Allenamento Coach360',
          startedAt: workout.startedAt,
          endedAt: endedAt,
          totalKcal: workout.totalKcal,
        ),
      );
      if (result.state != HealthWorkoutWriteState.written &&
          result.state != HealthWorkoutWriteState.alreadyPresent) {
        return;
      }
      await _repository.saveWorkout(
        workout.copyWith(syncedToHealthConnect: true),
      );
    } catch (_) {
      // L'esportazione si può ritentare dalla schermata Salute. Non rende mai
      // incompleta una sessione che SQLite ha già finalizzato.
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
      exercises: [
        ...workout.exercises,
        ...coolDownAsWorkoutExercises(completed: false),
      ],
    );
  }

  // ── Costruzione ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final workout = _workout;
    final focus = workout == null ? null : calculateLiveWorkoutFocus(workout);
    CircuitWorkoutPlan? primaryGuidedPlan;
    if (workout != null) {
      final pending = circuitPlansForWorkout(
        workout,
        routine: _routine,
      ).where((plan) => plan.kind != CircuitKind.cooldown).toList();
      if (pending.isNotEmpty &&
          (focus?.current == null ||
              pending.first.kind == CircuitKind.warmup)) {
        primaryGuidedPlan = pending.first;
      }
    }

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
                  _dismissRest();
                },
                onSkipRest: _skipRest,
                onDismissRest: _dismissRest,
                onAdjustedRest: _adjustRest,
                restContextLabel: _restContextLabel,
                restNextLabel: _restNextLabel,
                focus: focus!,
                workout: workout,
                busy: _busyCursor != null || _isFinishing || _openingPhase,
                guidedPlan: primaryGuidedPlan,
                onOpenGuided: primaryGuidedPlan == null
                    ? null
                    : () => unawaited(_openPlan(primaryGuidedPlan!)),
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
    final loadGuidance = _loadGuidanceFor(workout, focus);
    final resumePath = workout.resumePath;
    final guidedPlans = circuitPlansForWorkout(workout, routine: _routine)
        .where(
          (plan) =>
              plan.kind != CircuitKind.cooldown &&
              plan.resumePath(workout.id) != resumePath,
        )
        .toList(growable: false);
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
          if (resumePath case final path?)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _ResumePhaseCard(
                onOpen: widget.onOpenPhase == null
                    ? null
                    : () => unawaited(_openTimedPhase(path)),
              ),
            ),
          if (guidedPlans.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _GuidedPhasesCard(
                plans: guidedPlans,
                busy: _openingPhase || _isFinishing,
                onOpen: (plan) => unawaited(_openPlan(plan)),
              ),
            ),
          const SizedBox(height: 12),
          ..._buildBlocks(workout, focus, actions, loadGuidance),
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
    Map<int, LiveLoadGuidance> loadGuidance,
  ) {
    final blocks = <Widget>[];
    var index = 0;
    while (index < workout.exercises.length) {
      final exercise = workout.exercises[index];
      if (exercise.trackingMode.isTimed) {
        index++;
        continue;
      }
      final candidateGroup = supersetGroupContaining(workout, index);
      final group =
          candidateGroup != null &&
              candidateGroup.every(
                (member) => !workout.exercises[member].trackingMode.isTimed,
              )
          ? candidateGroup
          : null;
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
              guidanceByExercise: {
                for (final member in group) member: ?loadGuidance[member],
              },
              guidanceUndoIndices: _loadGuidanceUndo.keys.toSet(),
              onApplyGuidance: (exerciseIndex) {
                final guidance = loadGuidance[exerciseIndex];
                if (guidance != null) {
                  _applyLoadGuidance(exerciseIndex, guidance);
                }
              },
              onUndoGuidance: _undoLoadGuidance,
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
            exercise: exercise,
            exerciseIndex: index,
            actions: actions,
            current: focus.current,
            busyCursor: _busyCursor,
            guidance: loadGuidance[index],
            onApplyGuidance: loadGuidance[index] == null
                ? null
                : () => _applyLoadGuidance(index, loadGuidance[index]!),
            onUndoGuidance: _loadGuidanceUndo.containsKey(index)
                ? () => _undoLoadGuidance(index)
                : null,
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

class _GuidedPhasesCard extends StatelessWidget {
  const _GuidedPhasesCard({
    required this.plans,
    required this.busy,
    required this.onOpen,
  });

  final List<CircuitWorkoutPlan> plans;
  final bool busy;
  final void Function(CircuitWorkoutPlan plan) onOpen;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Fasi guidate',
      subtitle: 'Timer e recuperi avanzano insieme alla sessione.',
      icon: Icons.timer_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final plan in plans) ...[
            FilledButton.tonalIcon(
              key: ValueKey(
                'open-${plan.kind.name}-${plan.segmentIndex}-${plan.rowIndex}',
              ),
              onPressed: busy ? null : () => onOpen(plan),
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(plan.actionLabel),
            ),
            if (plan != plans.last) const SizedBox(height: 8),
          ],
        ],
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
    required this.onSkipRest,
    required this.onDismissRest,
    required this.onAdjustedRest,
    required this.restContextLabel,
    required this.restNextLabel,
    required this.focus,
    required this.workout,
    required this.busy,
    required this.guidedPlan,
    required this.onOpenGuided,
    required this.onCompleteCurrent,
    required this.onFinish,
  });

  final RestTimerController rest;
  final bool guided;
  final VoidCallback onStopGuided;
  final VoidCallback onSkipRest;
  final VoidCallback onDismissRest;
  final ValueChanged<Duration> onAdjustedRest;
  final String? restContextLabel;
  final String? restNextLabel;
  final LiveWorkoutFocus focus;
  final Workout workout;
  final bool busy;
  final CircuitWorkoutPlan? guidedPlan;
  final VoidCallback? onOpenGuided;
  final void Function(WorkoutCursor cursor) onCompleteCurrent;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cursor = focus.current;

    return Material(
      color: theme.colorScheme.surface,
      child: AnimatedBuilder(
        animation: rest,
        builder: (context, _) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Divider(height: 1, color: theme.colorScheme.outline),
            if (rest.isVisible)
              RestTimerBanner(
                controller: rest,
                guided: guided,
                onStop: guided ? onStopGuided : onDismissRest,
                onSkip: onSkipRest,
                onDismiss: onDismissRest,
                onAdjusted: onAdjustedRest,
                contextLabel: restContextLabel,
                nextLabel: restNextLabel,
              )
            else
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: guidedPlan != null
                      ? FilledButton.icon(
                          key: const Key('live_workout_open_guided'),
                          onPressed: busy ? null : onOpenGuided,
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: Text(guidedPlan!.actionLabel),
                        )
                      : cursor == null
                      ? FilledButton.icon(
                          key: const Key('live_workout_finish'),
                          onPressed: busy ? null : onFinish,
                          icon: const Icon(Icons.flag_rounded),
                          label: const Text('Hai finito — chiudi e salva'),
                        )
                      : FilledButton.icon(
                          key: const Key('live_workout_complete_current'),
                          onPressed: busy
                              ? null
                              : () => onCompleteCurrent(cursor),
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
      ),
    );
  }
}

String _currentActionLabel(Workout workout, WorkoutCursor cursor) {
  final exercise = workout.exercises[cursor.exerciseIndex];
  final set = exercise.sets[cursor.setIndex];
  final description = describeWorkoutSet(set, exercise.trackingMode);
  return 'Fatta: ${exercise.exerciseName} · serie ${cursor.setIndex + 1} '
      'di ${exercise.sets.length} · $description';
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
