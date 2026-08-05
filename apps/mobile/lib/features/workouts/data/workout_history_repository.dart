import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/features/workouts/data/workout_history_models.dart';

/// Lettura dello storico allenamenti. Solo lettura: questa è la finestra sui
/// dati importati da Gym, e finché il travaso è l'unica sorgente non esiste
/// nessun motivo per cui una schermata di consultazione possa scriverli.
class WorkoutHistoryRepository {
  WorkoutHistoryRepository(this._database);

  final AppDatabase _database;

  /// Un mese di sessioni fitte sta in poche decine di righe: il tetto serve
  /// solo a impedire che una lista senza fine diventi il caso normale.
  static const int _maxRows = 2000;

  /// I totali di ogni sessione in una passata sola.
  ///
  /// È SQL scritto a mano e non l'API tipizzata perché il volume è
  /// l'espressione di Gym («riscaldamento vale zero, i campi mancanti valgono
  /// zero») e in drift diventerebbe una catena di cast illeggibile proprio
  /// nel punto in cui la regola deve restare riconoscibile.
  ///
  /// Le due JOIN aprono un ventaglio esercizi × serie: per questo gli
  /// esercizi si contano con COUNT(DISTINCT) e le serie con COUNT(s.id), che
  /// salta i NULL prodotti dalla LEFT JOIN di un esercizio senza serie.
  static const String _summarySelect = '''
SELECT
  w.id                          AS id,
  w.started_at                  AS started_at,
  w.ended_at                    AS ended_at,
  w.accumulated_pause_seconds   AS accumulated_pause_seconds,
  w.final_duration_seconds      AS final_duration_seconds,
  w.duration_suspect            AS duration_suspect,
  w.routine_id                  AS routine_id,
  w.routine_external_id         AS routine_external_id,
  w.routine_name_snapshot       AS routine_name_snapshot,
  w.notes                       AS notes,
  w.total_kcal                  AS total_kcal,
  w.mood                        AS mood,
  w.rpe                         AS rpe,
  w.satisfaction                AS satisfaction,
  w.feedback_notes              AS feedback_notes,
  w.xp_earned                   AS xp_earned,
  COUNT(DISTINCT we.id)         AS exercise_count,
  COUNT(s.id)                   AS set_count,
  CAST(COALESCE(SUM(
    CASE WHEN s.is_warmup = 1 THEN 0
         ELSE COALESCE(s.weight_kg, 0) * COALESCE(s.reps, 0) END
  ), 0) AS REAL)                AS total_volume,
  MAX(CASE WHEN we.is_warmup = 0 AND we.is_cooldown = 0
                AND s.duration_sec IS NOT NULL AND s.weight_kg IS NULL
           THEN 1 ELSE 0 END)   AS has_timed,
  MAX(CASE WHEN we.is_cooldown = 0 AND s.weight_kg > 0
           THEN 1 ELSE 0 END)   AS has_strength,
  MAX(CASE WHEN we.interval_segment_index IS NOT NULL
           THEN 1 ELSE 0 END)   AS has_circuit
FROM workouts w
LEFT JOIN workout_exercises we ON we.workout_id = w.id
LEFT JOIN workout_sets s ON s.workout_exercise_id = we.id''';

  static const String _summaryTail = 'GROUP BY w.id ORDER BY w.started_at DESC';

  /// La lista, filtrata per profilo.
  static const String _historySql =
      '$_summarySelect\n'
      'WHERE w.profile_id = ?1 AND w.deleted_at IS NULL\n'
      '$_summaryTail\n'
      'LIMIT ?2';

  /// La stessa aggregazione su una sessione sola: l'intestazione del
  /// dettaglio deve venire dalla stessa espressione della scheda in lista,
  /// altrimenti prima o poi i due numeri divergono.
  static const String _singleSql =
      '$_summarySelect\n'
      'WHERE w.id = ?1 AND w.deleted_at IS NULL\n'
      '$_summaryTail\n'
      'LIMIT 1';

  /// Lo storico, dalla sessione più recente. Si aggiorna da solo quando
  /// cambiano le sessioni, gli esercizi o le serie.
  Stream<List<WorkoutSummary>> watchHistory(
    String profileId, {
    int limit = _maxRows,
  }) {
    return _summaryQuery(profileId, limit).watch().map(_mapSummaries);
  }

  Future<List<WorkoutSummary>> loadHistory(
    String profileId, {
    int limit = _maxRows,
  }) async {
    return _mapSummaries(await _summaryQuery(profileId, limit).get());
  }

  Selectable<QueryRow> _summaryQuery(String profileId, int limit) {
    if (limit <= 0 || limit > _maxRows) {
      throw const FormatException('Il numero di sessioni non è valido.');
    }
    return _database.customSelect(
      _historySql,
      variables: [Variable<String>(profileId), Variable<int>(limit)],
      readsFrom: {
        _database.workouts,
        _database.workoutExercises,
        _database.workoutSets,
      },
    );
  }

  List<WorkoutSummary> _mapSummaries(List<QueryRow> rows) =>
      rows.map(_summaryFromRow).toList(growable: false);

  WorkoutSummary _summaryFromRow(QueryRow row) {
    final routineExternalId = row.readNullable<String>('routine_external_id');
    return WorkoutSummary(
      id: row.read<String>('id'),
      startedAt: row.read<DateTime>('started_at'),
      endedAt: row.readNullable<DateTime>('ended_at'),
      accumulatedPauseSeconds: row.read<int>('accumulated_pause_seconds'),
      finalDurationSeconds: row.readNullable<int>('final_duration_seconds'),
      durationSuspect: row.read<bool>('duration_suspect'),
      routineName: row.readNullable<String>('routine_name_snapshot'),
      // La scheda è citata ma la FK viva è NULL: cancellata. Il nome che
      // resta è quello storico, e va mostrato come tale.
      routineDeleted:
          routineExternalId != null &&
          row.readNullable<String>('routine_id') == null,
      exerciseCount: row.read<int>('exercise_count'),
      setCount: row.read<int>('set_count'),
      totalVolume: row.read<double>('total_volume'),
      totalKcal: row.readNullable<double>('total_kcal'),
      notes: row.readNullable<String>('notes'),
      mood: row.readNullable<int>('mood'),
      rpe: row.readNullable<int>('rpe'),
      satisfaction: row.readNullable<int>('satisfaction'),
      feedbackNotes: row.readNullable<String>('feedback_notes'),
      xpEarned: row.readNullable<int>('xp_earned'),
      hasTimedWork: row.read<bool>('has_timed'),
      hasStrengthWork: row.read<bool>('has_strength'),
      hasCircuitRows: row.read<bool>('has_circuit'),
    );
  }

  /// Una sessione aperta, con le sue righe.
  ///
  /// La sorgente di aggiornamento dichiara tutte e cinque le tabelle da cui
  /// il dettaglio è composto: seguire la sola riga della sessione lascerebbe
  /// lo schermo fermo se cambiasse una serie.
  Stream<WorkoutDetail?> watchDetail(String workoutId) {
    return _database
        .customSelect(
          'SELECT id FROM workouts '
          'WHERE id = ?1 AND deleted_at IS NULL',
          variables: [Variable<String>(workoutId)],
          readsFrom: {
            _database.workouts,
            _database.workoutExercises,
            _database.workoutSets,
            _database.workoutPainPoints,
            _database.workoutIntervalSegments,
          },
        )
        .watch()
        .asyncMap(
          (rows) async => rows.isEmpty ? null : await loadDetail(workoutId),
        );
  }

  /// Il dettaglio di una sessione, o null se non c'è (o è stata cancellata).
  Future<WorkoutDetail?> loadDetail(String workoutId) async {
    final summary = await _loadSummary(workoutId);
    if (summary == null) {
      return null;
    }

    final exerciseRows =
        await (_database.select(_database.workoutExercises)
              ..where((row) => row.workoutId.equals(workoutId))
              ..orderBy([(row) => OrderingTerm.asc(row.position)]))
            .get();

    // Le serie di tutta la sessione in una query sola, poi raggruppate in
    // memoria: una query per esercizio moltiplicherebbe i giri sul database
    // per una sessione che ne ha già venti.
    final setsByExercise = <String, List<WorkoutSetEntry>>{};
    if (exerciseRows.isNotEmpty) {
      final setRows =
          await (_database.select(_database.workoutSets)
                ..where(
                  (row) => row.workoutExerciseId.isIn(
                    exerciseRows.map((exercise) => exercise.id),
                  ),
                )
                ..orderBy([(row) => OrderingTerm.asc(row.position)]))
              .get();
      for (final set in setRows) {
        (setsByExercise[set.workoutExerciseId] ??= <WorkoutSetEntry>[]).add(
          WorkoutSetEntry(
            position: set.position,
            weightKg: set.weightKg,
            reps: set.reps,
            durationSec: set.durationSec,
            distanceM: set.distanceM,
            rpe: set.rpe,
            isWarmup: set.isWarmup,
            completed: set.completed,
          ),
        );
      }
    }

    final painRows = await (_database.select(
      _database.workoutPainPoints,
    )..where((row) => row.workoutId.equals(workoutId))).get();

    final segmentRows =
        await (_database.select(_database.workoutIntervalSegments)
              ..where((row) => row.workoutId.equals(workoutId))
              ..orderBy([(row) => OrderingTerm.asc(row.segmentIndex)]))
            .get();

    return WorkoutDetail(
      summary: summary,
      exercises: exerciseRows
          .map(
            (row) => WorkoutExerciseEntry(
              id: row.id,
              position: row.position,
              name: row.exerciseNameSnapshot,
              trackingMode: WorkoutTrackingMode.fromName(row.trackingMode),
              block: _blockOf(row),
              muscleGroup: row.muscleGroupSnapshot,
              restSeconds: row.restSeconds,
              // L'id originale resta, la FK viva no: l'esercizio è stato
              // cancellato dal catalogo dopo quella sessione.
              exerciseDeleted: row.exerciseId == null,
              inSupersetWithPrevious: row.isInSupersetWithPrevious,
              intervalSegmentIndex: row.intervalSegmentIndex,
              sets: setsByExercise[row.id] ?? const <WorkoutSetEntry>[],
            ),
          )
          .toList(growable: false),
      painPoints: painRows.map((row) => row.label).toList(growable: false),
      circuitMarkers: segmentRows
          .map(
            (row) => WorkoutCircuitMarker(
              segmentIndex: row.segmentIndex,
              completed: row.completedMarker,
              partial: row.partialMarker,
            ),
          )
          .toList(growable: false),
    );
  }

  Future<WorkoutSummary?> _loadSummary(String workoutId) async {
    final rows = await _database
        .customSelect(
          _singleSql,
          variables: [Variable<String>(workoutId)],
          readsFrom: {
            _database.workouts,
            _database.workoutExercises,
            _database.workoutSets,
          },
        )
        .get();
    return rows.isEmpty ? null : _summaryFromRow(rows.first);
  }

  /// I tre booleani della riga tornano a essere l'unico blocco che sono. Lo
  /// schema garantisce che al massimo uno sia vero.
  WorkoutBlock _blockOf(LocalWorkoutExercise row) {
    if (row.isWarmup) {
      return WorkoutBlock.warmup;
    }
    if (row.isFinisher) {
      return WorkoutBlock.finisher;
    }
    if (row.isCooldown) {
      return WorkoutBlock.cooldown;
    }
    return WorkoutBlock.main;
  }
}
