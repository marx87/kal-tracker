/// Il modello della sessione, portato da Gym Tracker senza Firestore.
///
/// Le tre liste di Firestore (`exercises` immutabile, `activeExercises` di
/// lavoro, `intervalSegmentExercises` append-only) qui sono UNA sola, come
/// prescrive `app_database.dart`: le transazioni di SQLite fanno il lavoro che
/// là facevano tre campi paralleli. [WorkoutExercise.intervalSegmentIndex]
/// distingue le righe appese da un blocco a tempo.
///
/// L'IDENTITÀ DI UNA CELLA RESTA POSIZIONALE: i cursori vivi sono coppie
/// `(exerciseIndex, setIndex)` e tutta la logica portata — flusso superserie,
/// fuoco, mutazioni — ragiona così. Gli [id] qui sotto sono solo la maniglia
/// con cui il repository ritrova la riga da aggiornare, non una seconda
/// identità: non usarli per confrontare due celle.
library;

import 'package:kal_tracker/features/workouts/domain/exercise_kind.dart';

class WorkoutSet {
  const WorkoutSet({
    this.id,
    this.weightKg,
    this.reps,
    this.durationSec,
    this.distanceM,
    this.rpe,
    this.isWarmup = false,
    this.completed = false,
  });

  /// Chiave della riga su `workout_sets`. Nulla finché la serie non è stata
  /// scritta nemmeno una volta.
  final String? id;

  /// I cinque campi metrici restano NULLABLE e senza valore di comodo: «non
  /// inserito» e «zero» sono due cose diverse, ed è il motivo per cui
  /// [copyWith] ha i flag `clear*`.
  final double? weightKg;
  final int? reps;
  final int? durationSec;
  final double? distanceM;

  /// Sforzo percepito, 1..10.
  final int? rpe;

  final bool isWarmup;
  final bool completed;

  WorkoutSet copyWith({
    String? id,
    double? weightKg,
    int? reps,
    int? durationSec,
    double? distanceM,
    int? rpe,
    bool? isWarmup,
    bool? completed,
    bool clearWeight = false,
    bool clearReps = false,
    bool clearDuration = false,
    bool clearDistance = false,
    bool clearRpe = false,
  }) {
    return WorkoutSet(
      id: id ?? this.id,
      weightKg: clearWeight ? null : (weightKg ?? this.weightKg),
      reps: clearReps ? null : (reps ?? this.reps),
      durationSec: clearDuration ? null : (durationSec ?? this.durationSec),
      distanceM: clearDistance ? null : (distanceM ?? this.distanceM),
      rpe: clearRpe ? null : (rpe ?? this.rpe),
      isWarmup: isWarmup ?? this.isWarmup,
      completed: completed ?? this.completed,
    );
  }

  /// Volume = kg × ripetizioni, zero se manca il peso o è riscaldamento.
  /// Per gli esercizi a tempo resta zero apposta: là il volume non significa
  /// niente e la UI mostra durata e distanza.
  double get volume {
    if (isWarmup) return 0;
    return (weightKg ?? 0) * (reps ?? 0);
  }
}

class WorkoutExercise {
  const WorkoutExercise({
    required this.exerciseId,
    required this.exerciseName,
    required this.sets,
    this.id,
    this.catalogExerciseId,
    this.trackingMode = ExerciseTrackingMode.weightReps,
    this.muscleGroup,
    this.restSeconds,
    this.isWarmup = false,
    this.isCooldown = false,
    this.isFinisher = false,
    this.isInSupersetWithPrevious = false,
    this.intervalSegmentIndex,
  });

  /// Chiave della riga su `workout_exercises`.
  final String? id;

  /// `exercise_ref_id`: l'id ORIGINALE dell'esercizio, mai nullo. È la chiave
  /// con cui `personal_records` e `kcal_estimator` RAGGRUPPANO. Non va
  /// ricostruita da [catalogExerciseId], che diventa nullo quando l'esercizio
  /// viene cancellato: esercizi diversi collasserebbero in una voce sola e i
  /// trofei PR già sbloccati cambierebbero numero.
  final String exerciseId;

  /// `exercise_id`: la chiave esterna viva verso il catalogo, nulla quando
  /// l'esercizio è stato cancellato.
  final String? catalogExerciseId;

  /// Congelato apposta: sopravvive alle rinomine.
  final String exerciseName;

  /// La modalità EFFETTIVA di questa sessione, non quella del catalogo di
  /// oggi: nello storico 72 righe su 250 divergono dal catalogo.
  final ExerciseTrackingMode trackingMode;

  /// Il gruppo muscolare congelato. NULLABLE perché il database lo consente,
  /// ma lasciarlo nullo ha un prezzo: `estimateKcal` ricade su 5.0 MET e le
  /// calorie di gambe e cardio sbagliano del 20-40%. Vedi
  /// `exercisesMissingMuscleGroupSnapshot` in `muscle_group_snapshot.dart`.
  final MuscleGroup? muscleGroup;

  final List<WorkoutSet> sets;
  final int? restSeconds;

  /// I quattro blocchi sono esclusivi — riscaldamento, principale, finisher,
  /// defaticamento — ed è un CHECK del database, non una convenzione.
  final bool isWarmup;
  final bool isCooldown;
  final bool isFinisher;

  /// Vero quando l'esercizio è in superserie con quello IMMEDIATAMENTE
  /// precedente: si salta lì senza recupero.
  final bool isInSupersetWithPrevious;

  /// Identifica le righe appese da un blocco a tempo.
  final int? intervalSegmentIndex;

  WorkoutExercise copyWith({
    String? id,
    String? catalogExerciseId,
    String? exerciseName,
    ExerciseTrackingMode? trackingMode,
    MuscleGroup? muscleGroup,
    List<WorkoutSet>? sets,
    int? restSeconds,
    bool? isWarmup,
    bool? isCooldown,
    bool? isFinisher,
    bool? isInSupersetWithPrevious,
    int? intervalSegmentIndex,
  }) {
    return WorkoutExercise(
      id: id ?? this.id,
      exerciseId: exerciseId,
      catalogExerciseId: catalogExerciseId ?? this.catalogExerciseId,
      exerciseName: exerciseName ?? this.exerciseName,
      trackingMode: trackingMode ?? this.trackingMode,
      muscleGroup: muscleGroup ?? this.muscleGroup,
      sets: sets ?? this.sets,
      restSeconds: restSeconds ?? this.restSeconds,
      isWarmup: isWarmup ?? this.isWarmup,
      isCooldown: isCooldown ?? this.isCooldown,
      isFinisher: isFinisher ?? this.isFinisher,
      isInSupersetWithPrevious:
          isInSupersetWithPrevious ?? this.isInSupersetWithPrevious,
      intervalSegmentIndex: intervalSegmentIndex ?? this.intervalSegmentIndex,
    );
  }

  double get totalVolume =>
      sets.fold<double>(0, (total, set) => total + set.volume);
}

class Workout {
  const Workout({
    required this.id,
    required this.startedAt,
    required this.exercises,
    this.endedAt,
    this.pausedAt,
    this.accumulatedPauseSeconds = 0,
    this.finalDurationSeconds,
    this.routineId,
    this.routineName,
    this.notes,
    this.resumePath,
    this.circuitCheckpoint,
    this.completedIntervalSegmentIndices = const [],
    this.completedIntervalSegmentSignatures = const {},
    this.partialIntervalSegmentIndices = const [],
    this.totalKcal,
    this.mood,
    this.rpe,
    this.satisfaction,
    this.painPoints = const [],
    this.feedbackNotes,
    this.xpEarned,
    this.syncedToHealthConnect = false,
  });

  final String id;
  final DateTime startedAt;

  /// `null` significa «in corso», ed è l'invariante che l'indice unico
  /// parziale `idx_workouts_one_active` protegge: un profilo non può avere
  /// due sessioni aperte.
  final DateTime? endedAt;

  /// Marcatore di pausa esplicito, scritto quando si esce da una sessione non
  /// finita. Insieme ad [accumulatedPauseSeconds] tiene fuori dal tempo (e
  /// quindi dalle calorie) i minuti passati lontano dall'allenamento.
  final DateTime? pausedAt;
  final int accumulatedPauseSeconds;
  final int? finalDurationSeconds;

  final String? routineId;
  final String? routineName;
  final List<WorkoutExercise> exercises;
  final String? notes;

  /// Rotta e checkpoint leggero usati dalla card «riprendi». Le sessioni
  /// vecchie hanno entrambi nulli.
  final String? resumePath;
  final Map<String, dynamic>? circuitCheckpoint;

  /// I due marcatori dei blocchi a tempo NON sono esclusivi e non si possono
  /// comprimere in un enum: sono liste indipendenti che possono contenere lo
  /// stesso indice, e la ripresa guarda PRIMA i parziali.
  final List<int> completedIntervalSegmentIndices;
  final Map<int, String> completedIntervalSegmentSignatures;
  final List<int> partialIntervalSegmentIndices;

  final double? totalKcal;

  /// Feedback di fine sessione.
  final int? mood;
  final int? rpe;
  final int? satisfaction;
  final List<String> painPoints;
  final String? feedbackNotes;

  final int? xpEarned;
  final bool syncedToHealthConnect;

  Workout copyWith({
    DateTime? endedAt,
    DateTime? pausedAt,
    int? accumulatedPauseSeconds,
    int? finalDurationSeconds,
    String? routineId,
    String? routineName,
    List<WorkoutExercise>? exercises,
    String? notes,
    String? resumePath,
    Map<String, dynamic>? circuitCheckpoint,
    List<int>? completedIntervalSegmentIndices,
    Map<int, String>? completedIntervalSegmentSignatures,
    List<int>? partialIntervalSegmentIndices,
    double? totalKcal,
    int? mood,
    int? rpe,
    int? satisfaction,
    List<String>? painPoints,
    String? feedbackNotes,
    int? xpEarned,
    bool? syncedToHealthConnect,
    bool clearPausedAt = false,
    bool clearResumeState = false,
  }) {
    return Workout(
      id: id,
      startedAt: startedAt,
      endedAt: endedAt ?? this.endedAt,
      pausedAt: clearPausedAt ? null : (pausedAt ?? this.pausedAt),
      accumulatedPauseSeconds:
          accumulatedPauseSeconds ?? this.accumulatedPauseSeconds,
      finalDurationSeconds: finalDurationSeconds ?? this.finalDurationSeconds,
      routineId: routineId ?? this.routineId,
      routineName: routineName ?? this.routineName,
      exercises: exercises ?? this.exercises,
      notes: notes ?? this.notes,
      resumePath: clearResumeState ? null : (resumePath ?? this.resumePath),
      circuitCheckpoint: clearResumeState
          ? null
          : (circuitCheckpoint ?? this.circuitCheckpoint),
      completedIntervalSegmentIndices:
          completedIntervalSegmentIndices ??
          this.completedIntervalSegmentIndices,
      completedIntervalSegmentSignatures:
          completedIntervalSegmentSignatures ??
          this.completedIntervalSegmentSignatures,
      partialIntervalSegmentIndices:
          partialIntervalSegmentIndices ?? this.partialIntervalSegmentIndices,
      totalKcal: totalKcal ?? this.totalKcal,
      mood: mood ?? this.mood,
      rpe: rpe ?? this.rpe,
      satisfaction: satisfaction ?? this.satisfaction,
      painPoints: painPoints ?? this.painPoints,
      feedbackNotes: feedbackNotes ?? this.feedbackNotes,
      xpEarned: xpEarned ?? this.xpEarned,
      syncedToHealthConnect:
          syncedToHealthConnect ?? this.syncedToHealthConnect,
    );
  }

  double get totalVolume =>
      exercises.fold<double>(0, (total, e) => total + e.totalVolume);

  /// La regola di lettura di Gym, invariata: [finalDurationSeconds] se c'è,
  /// altrimenti `endedAt - startedAt - accumulatedPauseSeconds`.
  ///
  /// Il tetto di 24 ore vive SOLO qui, in lettura. Chi scrive non lo applica:
  /// una sessione dimenticata aperta trenta ore va salvata com'è e mostrata
  /// come 24, non troncata nel database.
  Duration? get duration {
    if (endedAt == null) return null;
    final fixed = finalDurationSeconds;
    if (fixed != null) {
      return Duration(seconds: fixed.clamp(0, 24 * 60 * 60));
    }
    final raw = endedAt!.difference(startedAt);
    final active = raw - Duration(seconds: accumulatedPauseSeconds);
    return active.isNegative ? Duration.zero : active;
  }

  bool get isRunning => endedAt == null;
}
