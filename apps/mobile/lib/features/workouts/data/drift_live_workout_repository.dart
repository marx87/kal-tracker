/// La sessione dal vivo su Drift: l'implementazione che mancava.
///
/// La schermata esisteva già ed era completa; qui sotto c'è solo la
/// persistenza, con quattro decisioni che vale la pena spiegare una volta.
///
/// **1. Gli id dei figli sono derivati dalla posizione, non estratti a caso.**
/// Nel modello l'identità di una cella È la coppia (esercizio, serie): tutta la
/// logica portata da Gym ragiona per indici. Se ogni salvataggio inventasse
/// nuovi uuid, la stessa serie cambierebbe riga a ogni tocco e il server si
/// vedrebbe arrivare righe nuove al posto di aggiornamenti. Con
/// `SyncIds.derived` l'id è una funzione della posizione: stabile fra un
/// salvataggio e l'altro, stabile fra due dispositivi.
///
/// **2. Ogni salvataggio riscrive i figli in blocco, dentro una transazione.**
/// Sembra sprecato e non lo è: le liste sono di decine di righe, la scrittura è
/// una sola transazione, e in cambio non esiste nessuno stato intermedio in cui
/// una serie spuntata e la sua riga esercizio raccontano cose diverse. È la
/// stessa scelta del salvataggio di una scheda, per lo stesso motivo (la UNIQUE
/// sulle posizioni non perdona uno stato a metà).
///
/// **3. `saveWorkout` non tocca la rotta di ripresa né la chiusura.** Il
/// checkpoint del circuito viaggia su `updateResumeState` a ogni cambio di
/// fase, mentre la schermata dal vivo tiene in mano una copia della sessione
/// che può essere di un minuto fa: se il salvataggio riscrivesse anche quei due
/// campi, un `resumePath` vecchio cancellerebbe il checkpoint appena scritto e
/// la ripresa finirebbe sulla fase sbagliata. Allo stesso modo `ended_at`,
/// durata e calorie li scrive SOLO [finalizeWorkout], insieme e una volta sola.
///
/// **4. In coda di sincronizzazione ci va solo la sessione CHIUSA.** Sul
/// server esiste lo stesso indice unico parziale che c'è qui
/// (`workouts_one_active_idx`): spedire una sessione ancora aperta mentre
/// l'altro dispositivo ne ha una sua produrrebbe un 23505 ritentabile per
/// sempre, cioè una coda ferma in testa. Una sessione in corso è del telefono
/// che la sta registrando; quando finisce parte intera, con esercizi, serie,
/// punti dolenti e blocchi a tempo.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/sync/sync_gateway.dart' show SyncIds;
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/workouts/domain/exercise_kind.dart';
import 'package:kal_tracker/features/workouts/domain/kcal_estimator.dart';
import 'package:kal_tracker/features/workouts/domain/live_workout_repository.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';
import 'package:uuid/uuid.dart';

class DriftLiveWorkoutRepository implements LiveWorkoutRepository {
  DriftLiveWorkoutRepository(
    this._database, {
    required Future<String> Function() profileId,
    Uuid? uuid,
    DateTime Function()? now,
  }) : _readProfileId = profileId,
       _uuid = uuid ?? const Uuid(),
       _now = now ?? AppTime.nowUtc;

  /// Per chi l'id del profilo ce l'ha già in mano (i test, e chiunque legga
  /// prima il profilo per altri motivi).
  DriftLiveWorkoutRepository.forProfile(
    AppDatabase database,
    String profileId, {
    Uuid? uuid,
    DateTime Function()? now,
  }) : this(database, profileId: (() async => profileId), uuid: uuid, now: now);

  final AppDatabase _database;
  final Future<String> Function() _readProfileId;
  final Uuid _uuid;
  final DateTime Function() _now;

  /// Il profilo si risolve una volta sola: è l'unico profilo dell'app e
  /// rileggerlo a ogni serie spuntata sarebbe una query per niente.
  String? _profileId;

  /// Oltre questa soglia la durata di una sessione non è più un dato
  /// dell'orologio ma un dimenticanza: si marca, non si rettifica.
  static const int _suspectDurationSeconds = 24 * 60 * 60;

  Future<String> _profile() async => _profileId ??= await _readProfileId();

  // ── Lettura ──────────────────────────────────────────────────────────────

  @override
  Future<Workout?> activeWorkout() async {
    final row = await _activeRow(await _profile());
    return row == null ? null : _hydrate(row);
  }

  @override
  Future<Workout?> getById(String workoutId) async {
    final row = await _rowById(workoutId);
    return row == null ? null : _hydrate(row);
  }

  @override
  Future<List<Workout>> recentClosedWorkouts({int limit = 200}) async {
    final profileId = await _profile();
    final rows =
        await (_database.select(_database.workouts)
              ..where(
                (row) =>
                    row.profileId.equals(profileId) &
                    row.endedAt.isNotNull() &
                    row.deletedAt.isNull(),
              )
              ..orderBy([(row) => OrderingTerm.desc(row.startedAt)])
              ..limit(limit <= 0 ? 1 : limit))
            .get();
    if (rows.isEmpty) {
      return const [];
    }

    // Due query per tutto lo storico, non due per sessione: la baseline dei
    // record si carica all'apertura della schermata, con l'utente che aspetta.
    final ids = [for (final row in rows) row.id];
    final exerciseRows =
        await (_database.select(_database.workoutExercises)
              ..where((row) => row.workoutId.isIn(ids))
              ..orderBy([(row) => OrderingTerm.asc(row.position)]))
            .get();
    final setsByExercise = await _setsFor([
      for (final row in exerciseRows) row.id,
    ]);

    final byWorkout = <String, List<LocalWorkoutExercise>>{};
    for (final row in exerciseRows) {
      (byWorkout[row.workoutId] ??= <LocalWorkoutExercise>[]).add(row);
    }
    return [
      for (final row in rows)
        _workoutFrom(
          row,
          byWorkout[row.id] ?? const [],
          setsByExercise,
          const [],
          const [],
        ),
    ];
  }

  @override
  Future<List<BodyWeightSample>> recentBodyWeights({int limit = 10}) async {
    final profileId = await _profile();
    final rows =
        await (_database.select(_database.bodyMeasurements)
              ..where(
                (row) =>
                    row.profileId.equals(profileId) & row.deletedAt.isNull(),
              )
              ..orderBy([(row) => OrderingTerm.desc(row.measuredAt)])
              ..limit(limit <= 0 ? 1 : limit))
            .get();
    // Il peso per le calorie MET esce da qui e SOLO da qui: nessun valore
    // congelato nel profilo, altrimenti si calcolerebbe per sempre sul peso di
    // mesi fa (vedi `pickBodyKg`).
    return [
      for (final row in rows)
        BodyWeightSample(measuredAt: row.measuredAt, kg: row.weightKg),
    ];
  }

  // ── Avvio ────────────────────────────────────────────────────────────────

  @override
  Future<Workout> startWorkout({
    String? routineId,
    String? routineName,
    required List<WorkoutExercise> exercises,
  }) async {
    final profileId = await _profile();
    final now = _now();
    final workoutId = _uuid.v4();

    try {
      await _database.transaction(() async {
        final open = await _activeRow(profileId);
        if (open != null) {
          throw ActiveWorkoutAlreadyOpen(await _hydrate(open));
        }
        // La scheda si collega solo se la riga esiste ancora: la FK non
        // accetta un id fantasma. L'id però resta scritto comunque in
        // `routine_external_id`, che è il campo pensato per sopravvivere alla
        // cancellazione della scheda — e il CHECK pretende che i due valori,
        // quando ci sono entrambi, coincidano.
        final linked = await _existingRoutineId(routineId);
        await _database
            .into(_database.workouts)
            .insert(
              WorkoutsCompanion.insert(
                id: workoutId,
                profileId: profileId,
                startedAt: now,
                routineId: Value(linked),
                routineExternalId: Value(_text(routineId, 120)),
                routineNameSnapshot: Value(_text(routineName, 160)),
                createdAt: now,
                updatedAt: now,
              ),
            );
        await _writeChildren(workoutId, exercises);
      });
    } on ActiveWorkoutAlreadyOpen {
      rethrow;
    } catch (error) {
      // Fra il controllo e l'inserimento ci può stare un altro dispositivo (o
      // un doppio tocco): l'indice unico parziale scatta e SQLite parla di
      // vincoli. Chi chiama non deve conoscere quel messaggio, deve sapere che
      // c'è già una sessione da riprendere.
      final open = await _activeRow(profileId);
      if (open != null) {
        throw ActiveWorkoutAlreadyOpen(await _hydrate(open));
      }
      rethrow;
    }

    final started = await getById(workoutId);
    if (started == null) {
      throw StateError('La sessione appena creata non si rilegge.');
    }
    return started;
  }

  // ── Scrittura ────────────────────────────────────────────────────────────

  @override
  Future<void> saveWorkout(Workout workout) async {
    final now = _now();
    await _database.transaction(() async {
      final row = await _rowById(workout.id);
      if (row == null) {
        // Meglio un errore visibile che un salvataggio finto: la schermata
        // mostra «serie non salvata» e la copia in memoria torna indietro.
        throw StateError('Questa sessione non esiste più.');
      }
      await (_database.update(
        _database.workouts,
      )..where((table) => table.id.equals(workout.id))).write(
        WorkoutsCompanion(
          // La pausa vive qui perché la schermata la registra con un
          // salvataggio normale; su una sessione già chiusa non ha senso e il
          // CHECK la rifiuterebbe.
          pausedAt: Value(row.endedAt == null ? workout.pausedAt : null),
          accumulatedPauseSeconds: Value(
            _atLeastZero(workout.accumulatedPauseSeconds),
          ),
          notes: Value(_text(workout.notes, 1000)),
          mood: Value(_bounded(workout.mood, 1, 5)),
          rpe: Value(_bounded(workout.rpe, 1, 10)),
          satisfaction: Value(_bounded(workout.satisfaction, 1, 5)),
          feedbackNotes: Value(_text(workout.feedbackNotes, 1000)),
          xpEarned: Value(_atLeastZeroOrNull(workout.xpEarned)),
          syncedToHealthConnect: Value(workout.syncedToHealthConnect),
          updatedAt: Value(now),
        ),
      );
      await _writeChildren(workout.id, workout.exercises);
      await _writePainPoints(workout.id, workout.painPoints);
      await _writeIntervalSegments(workout);
    });
  }

  @override
  Future<void> finalizeWorkout(Workout snapshot) async {
    final now = _now();
    await _database.transaction(() async {
      final row = await _rowById(snapshot.id);
      if (row == null) {
        throw StateError('Questa sessione non esiste più.');
      }
      // L'orologio può tornare indietro fra l'inizio e la fine (fuso, ora
      // legale, rete): una fine prima dell'inizio è rifiutata dal CHECK, e una
      // sessione non chiusa sarebbe un danno peggiore di un secondo perso.
      final endedAt = _notBefore(snapshot.endedAt ?? now, row.startedAt);
      final duration =
          _atLeastZeroOrNull(snapshot.finalDurationSeconds) ??
          _atLeastZero(
            endedAt.difference(row.startedAt).inSeconds -
                _atLeastZero(snapshot.accumulatedPauseSeconds),
          );

      await (_database.update(
        _database.workouts,
      )..where((table) => table.id.equals(snapshot.id))).write(
        WorkoutsCompanion(
          endedAt: Value(endedAt),
          // Una sessione chiusa non è in pausa, e la card «riprendi» non deve
          // avere più niente a cui puntare.
          pausedAt: const Value(null),
          resumePath: const Value(null),
          circuitCheckpointJson: const Value(null),
          accumulatedPauseSeconds: Value(
            _atLeastZero(snapshot.accumulatedPauseSeconds),
          ),
          finalDurationSeconds: Value(duration),
          // Nessun troncamento: la sessione dimenticata aperta trenta ore si
          // salva com'è e si MARCA. Il tetto di 24 h è una regola di lettura.
          durationSuspect: Value(duration > _suspectDurationSeconds),
          totalKcal: Value(_atLeastZeroDouble(snapshot.totalKcal)),
          notes: Value(_text(snapshot.notes, 1000)),
          mood: Value(_bounded(snapshot.mood, 1, 5)),
          rpe: Value(_bounded(snapshot.rpe, 1, 10)),
          satisfaction: Value(_bounded(snapshot.satisfaction, 1, 5)),
          feedbackNotes: Value(_text(snapshot.feedbackNotes, 1000)),
          xpEarned: Value(_atLeastZeroOrNull(snapshot.xpEarned)),
          syncedToHealthConnect: Value(snapshot.syncedToHealthConnect),
          updatedAt: Value(now),
        ),
      );

      final exercises = await _writeChildren(snapshot.id, snapshot.exercises);
      final pains = await _writePainPoints(snapshot.id, snapshot.painPoints);
      final segments = await _writeIntervalSegments(snapshot);

      await _appendOutbox(
        workoutId: snapshot.id,
        payload: {
          'id': snapshot.id,
          'profile_id': row.profileId,
          'started_at': row.startedAt.toUtc().toIso8601String(),
          'ended_at': endedAt.toUtc().toIso8601String(),
          'paused_at': null,
          'accumulated_pause_seconds': _atLeastZero(
            snapshot.accumulatedPauseSeconds,
          ),
          'final_duration_seconds': duration,
          'duration_suspect': duration > _suspectDurationSeconds,
          'routine_id': row.routineId,
          'routine_external_id': row.routineExternalId,
          'routine_name_snapshot': row.routineNameSnapshot,
          'notes': _text(snapshot.notes, 1000),
          'total_kcal': _atLeastZeroDouble(snapshot.totalKcal),
          'mood': _bounded(snapshot.mood, 1, 5),
          'rpe': _bounded(snapshot.rpe, 1, 10),
          'satisfaction': _bounded(snapshot.satisfaction, 1, 5),
          'feedback_notes': _text(snapshot.feedbackNotes, 1000),
          'xp_earned': _atLeastZeroOrNull(snapshot.xpEarned),
          'resume_path': null,
          'circuit_checkpoint_json': null,
          'synced_to_health_connect': snapshot.syncedToHealthConnect,
          'source': row.source,
          'external_id': row.externalId,
          'created_at': row.createdAt.toUtc().toIso8601String(),
          'updated_at': now.toUtc().toIso8601String(),
          // Le tre liste dei figli ci sono SEMPRE: per il gateway una chiave
          // assente significa «questa scrittura non parla dei figli», e i figli
          // remoti resterebbero quelli di prima.
          'exercises': exercises,
          'pain_points': pains,
          'interval_segments': segments,
        },
        now: now,
      );
    });
  }

  @override
  Future<void> updatePauseState(
    String workoutId, {
    required DateTime? pausedAt,
    required int accumulatedPauseSeconds,
  }) async {
    await (_database.update(
      _database.workouts,
    )..where((row) => row.id.equals(workoutId) & row.deletedAt.isNull())).write(
      WorkoutsCompanion(
        pausedAt: Value(pausedAt),
        accumulatedPauseSeconds: Value(_atLeastZero(accumulatedPauseSeconds)),
        updatedAt: Value(_now()),
      ),
    );
  }

  @override
  Future<void> updateResumeState(
    String workoutId, {
    required String? resumePath,
    required Map<String, dynamic>? circuitCheckpoint,
  }) async {
    await (_database.update(
      _database.workouts,
    )..where((row) => row.id.equals(workoutId) & row.deletedAt.isNull())).write(
      WorkoutsCompanion(
        resumePath: Value(_text(resumePath, 200)),
        circuitCheckpointJson: Value(
          circuitCheckpoint == null ? null : jsonEncode(circuitCheckpoint),
        ),
        updatedAt: Value(_now()),
      ),
    );
  }

  // ── Figli ────────────────────────────────────────────────────────────────

  /// Riscrive esercizi e serie, e restituisce il payload di sincronizzazione
  /// delle stesse righe: le due cose vengono dallo stesso giro, così non
  /// possono raccontare storie diverse.
  Future<List<Map<String, Object?>>> _writeChildren(
    String workoutId,
    List<WorkoutExercise> exercises,
  ) async {
    final existing = await (_database.select(
      _database.workoutExercises,
    )..where((row) => row.workoutId.equals(workoutId))).get();
    if (existing.isNotEmpty) {
      // Le serie si cancellano a mano invece di affidarsi al cascade: così la
      // scrittura non dipende dallo stato di `PRAGMA foreign_keys`.
      final existingIds = [for (final exercise in existing) exercise.id];
      await (_database.delete(
        _database.workoutSets,
      )..where((row) => row.workoutExerciseId.isIn(existingIds))).go();
      await (_database.delete(
        _database.workoutExercises,
      )..where((row) => row.workoutId.equals(workoutId))).go();
    }
    if (exercises.isEmpty) {
      return const [];
    }

    final catalog = await _catalogFor(exercises);
    final exerciseRows = <WorkoutExercisesCompanion>[];
    final setRows = <WorkoutSetsCompanion>[];
    final payload = <Map<String, Object?>>[];

    for (final (position, exercise) in exercises.indexed) {
      final rowId = _exerciseRowId(workoutId, position);
      final refId = _refId(exercise.exerciseId);
      final known = catalog.containsKey(refId);
      // I quattro blocchi sono esclusivi e il database lo impone: se il
      // modello arrivasse con due bandiere, la sessione intera verrebbe
      // rifiutata. Precedenza: riscaldamento, defaticamento, finisher.
      final isWarmup = exercise.isWarmup;
      final isCooldown = !isWarmup && exercise.isCooldown;
      final isFinisher = !isWarmup && !isCooldown && exercise.isFinisher;
      // QUI si chiude il buco delle calorie: se la riga non porta il gruppo,
      // lo si prende dal catalogo invece di scrivere NULL e far ripiegare
      // `estimateKcal` su 5.0 MET (20-40% di errore su gambe e cardio).
      final group = exercise.muscleGroup?.name ?? catalog[refId];
      final name = _text(exercise.exerciseName, 160) ?? 'Esercizio';
      final rest = _bounded(exercise.restSeconds, 0, 3600);
      final chained = position > 0 && exercise.isInSupersetWithPrevious;
      final segmentIndex = _atLeastZeroOrNull(exercise.intervalSegmentIndex);

      exerciseRows.add(
        WorkoutExercisesCompanion.insert(
          id: rowId,
          workoutId: workoutId,
          position: position,
          exerciseRefId: refId,
          exerciseId: Value(known ? refId : null),
          exerciseNameSnapshot: name,
          trackingMode: exercise.trackingMode.name,
          muscleGroupSnapshot: Value(group),
          restSeconds: Value(rest),
          isWarmup: Value(isWarmup),
          isCooldown: Value(isCooldown),
          isFinisher: Value(isFinisher),
          isInSupersetWithPrevious: Value(chained),
          intervalSegmentIndex: Value(segmentIndex),
        ),
      );

      final sets = <Map<String, Object?>>[];
      for (final (setPosition, set) in exercise.sets.indexed) {
        final setId = _setRowId(rowId, setPosition);
        final weight = _boundedDouble(set.weightKg, 0, 1000);
        final reps = _bounded(set.reps, 0, 1000);
        final durationSec = _bounded(set.durationSec, 0, 86400);
        final distance = _boundedDouble(set.distanceM, 0, 200000);
        final rpe = _bounded(set.rpe, 1, 10);
        setRows.add(
          WorkoutSetsCompanion.insert(
            id: setId,
            workoutExerciseId: rowId,
            position: setPosition,
            weightKg: Value(weight),
            reps: Value(reps),
            durationSec: Value(durationSec),
            distanceM: Value(distance),
            rpe: Value(rpe),
            isWarmup: Value(set.isWarmup),
            completed: Value(set.completed),
          ),
        );
        sets.add({
          'id': setId,
          'workout_exercise_id': rowId,
          'position': setPosition,
          'weight_kg': weight,
          'reps': reps,
          'duration_sec': durationSec,
          'distance_m': distance,
          'rpe': rpe,
          'is_warmup': set.isWarmup,
          'completed': set.completed,
        });
      }

      payload.add({
        'id': rowId,
        'workout_id': workoutId,
        'position': position,
        'exercise_ref_id': refId,
        'exercise_id': known ? refId : null,
        'exercise_name_snapshot': name,
        'tracking_mode': exercise.trackingMode.name,
        'muscle_group_snapshot': group,
        'rest_seconds': rest,
        'is_warmup': isWarmup,
        'is_cooldown': isCooldown,
        'is_finisher': isFinisher,
        'is_in_superset_with_previous': chained,
        'interval_segment_index': segmentIndex,
        'sets': sets,
      });
    }

    await _database.batch((batch) {
      batch.insertAll(_database.workoutExercises, exerciseRows);
      batch.insertAll(_database.workoutSets, setRows);
    });
    return payload;
  }

  Future<List<Map<String, Object?>>> _writePainPoints(
    String workoutId,
    List<String> labels,
  ) async {
    await (_database.delete(
      _database.workoutPainPoints,
    )..where((row) => row.workoutId.equals(workoutId))).go();
    final payload = <Map<String, Object?>>[];
    // Le etichette sono un insieme: due volte «spalla destra» è una volta.
    final seen = <String>{};
    for (final raw in labels) {
      final label = _text(raw, 40);
      if (label == null || !seen.add(label)) {
        continue;
      }
      final id = SyncIds.derived('workout-pain-point', '$workoutId/$label');
      await _database
          .into(_database.workoutPainPoints)
          .insert(
            WorkoutPainPointsCompanion.insert(
              id: id,
              workoutId: workoutId,
              label: label,
            ),
          );
      payload.add({'id': id, 'workout_id': workoutId, 'label': label});
    }
    return payload;
  }

  /// I due marcatori dei blocchi a tempo NON sono esclusivi: lo stesso indice
  /// può stare fra i completati e fra i parziali, ed è la situazione che manda
  /// la ripresa sulla fase giusta. Perciò una riga per indice, con due
  /// booleani, e non una colonna sola con tre stati.
  Future<List<Map<String, Object?>>> _writeIntervalSegments(
    Workout workout,
  ) async {
    await (_database.delete(
      _database.workoutIntervalSegments,
    )..where((row) => row.workoutId.equals(workout.id))).go();

    final completed = workout.completedIntervalSegmentIndices.toSet();
    final partial = workout.partialIntervalSegmentIndices.toSet();
    final indices = <int>{...completed, ...partial}.toList()..sort();
    final payload = <Map<String, Object?>>[];
    for (final index in indices) {
      if (index < 0) {
        continue;
      }
      final isCompleted = completed.contains(index);
      final id = SyncIds.derived(
        'workout-interval-segment',
        '${workout.id}/$index',
      );
      // La firma appartiene SOLO al marcatore di completamento: senza quello
      // il CHECK la rifiuta.
      final signature = isCompleted
          ? workout.completedIntervalSegmentSignatures[index]
          : null;
      await _database
          .into(_database.workoutIntervalSegments)
          .insert(
            WorkoutIntervalSegmentsCompanion.insert(
              id: id,
              workoutId: workout.id,
              segmentIndex: index,
              completedMarker: Value(isCompleted),
              partialMarker: Value(partial.contains(index)),
              completionSignature: Value(signature),
            ),
          );
      payload.add({
        'id': id,
        'workout_id': workout.id,
        'segment_index': index,
        'completed_marker': isCompleted,
        'partial_marker': partial.contains(index),
        'completion_signature': signature,
      });
    }
    return payload;
  }

  Future<void> _appendOutbox({
    required String workoutId,
    required Map<String, Object?> payload,
    required DateTime now,
  }) => _database
      .into(_database.syncOutbox)
      .insert(
        SyncOutboxCompanion.insert(
          id: _uuid.v4(),
          entityType: 'workout',
          entityId: workoutId,
          operation: 'upsert',
          payloadJson: jsonEncode(payload),
          createdAt: now,
        ),
      );

  // ── Lettura di supporto ──────────────────────────────────────────────────

  Future<LocalWorkout?> _activeRow(String profileId) =>
      (_database.select(_database.workouts)
            ..where(
              (row) =>
                  row.profileId.equals(profileId) &
                  row.endedAt.isNull() &
                  row.deletedAt.isNull(),
            )
            // L'indice ne ammette una sola, ma se un database migrato senza
            // indice ne avesse due, la più recente è quella che si sta usando.
            ..orderBy([(row) => OrderingTerm.desc(row.startedAt)])
            ..limit(1))
          .getSingleOrNull();

  Future<LocalWorkout?> _rowById(String workoutId) =>
      (_database.select(_database.workouts)
            ..where((row) => row.id.equals(workoutId) & row.deletedAt.isNull()))
          .getSingleOrNull();

  Future<String?> _existingRoutineId(String? routineId) async {
    if (routineId == null || routineId.isEmpty) {
      return null;
    }
    final row = await (_database.select(
      _database.routines,
    )..where((table) => table.id.equals(routineId))).getSingleOrNull();
    return row?.id;
  }

  /// `exerciseRefId -> muscle_group` per gli esercizi citati, e insieme
  /// l'elenco di quelli che esistono ancora.
  ///
  /// Le righe cancellate in modo morbido restano dentro: la chiave esterna le
  /// accetta e il loro gruppo muscolare è comunque il gruppo giusto di quel
  /// movimento. Perdere il dato perché l'esercizio è uscito dal catalogo
  /// sarebbe una perdita di informazione, non una cautela.
  Future<Map<String, String>> _catalogFor(
    List<WorkoutExercise> exercises,
  ) async {
    final ids = {for (final exercise in exercises) _refId(exercise.exerciseId)};
    if (ids.isEmpty) {
      return const {};
    }
    final rows = await (_database.select(
      _database.exercises,
    )..where((row) => row.id.isIn(ids))).get();
    return {for (final row in rows) row.id: row.muscleGroup};
  }

  Future<Workout> _hydrate(LocalWorkout row) async {
    final exerciseRows =
        await (_database.select(_database.workoutExercises)
              ..where((table) => table.workoutId.equals(row.id))
              ..orderBy([(table) => OrderingTerm.asc(table.position)]))
            .get();
    final sets = await _setsFor([for (final row in exerciseRows) row.id]);
    final pains = await (_database.select(
      _database.workoutPainPoints,
    )..where((table) => table.workoutId.equals(row.id))).get();
    final segments =
        await (_database.select(_database.workoutIntervalSegments)
              ..where((table) => table.workoutId.equals(row.id))
              ..orderBy([(table) => OrderingTerm.asc(table.segmentIndex)]))
            .get();
    return _workoutFrom(row, exerciseRows, sets, pains, segments);
  }

  Future<Map<String, List<LocalWorkoutSet>>> _setsFor(
    List<String> exerciseIds,
  ) async {
    if (exerciseIds.isEmpty) {
      return const {};
    }
    final rows =
        await (_database.select(_database.workoutSets)
              ..where((row) => row.workoutExerciseId.isIn(exerciseIds))
              ..orderBy([(row) => OrderingTerm.asc(row.position)]))
            .get();
    final grouped = <String, List<LocalWorkoutSet>>{};
    for (final row in rows) {
      (grouped[row.workoutExerciseId] ??= <LocalWorkoutSet>[]).add(row);
    }
    return grouped;
  }

  Workout _workoutFrom(
    LocalWorkout row,
    List<LocalWorkoutExercise> exerciseRows,
    Map<String, List<LocalWorkoutSet>> setsByExercise,
    List<LocalWorkoutPainPoint> pains,
    List<LocalWorkoutIntervalSegment> segments,
  ) {
    return Workout(
      id: row.id,
      startedAt: row.startedAt,
      endedAt: row.endedAt,
      pausedAt: row.pausedAt,
      accumulatedPauseSeconds: row.accumulatedPauseSeconds,
      finalDurationSeconds: row.finalDurationSeconds,
      routineId: row.routineId,
      routineName: row.routineNameSnapshot,
      notes: row.notes,
      resumePath: row.resumePath,
      circuitCheckpoint: _decodeCheckpoint(row.circuitCheckpointJson),
      completedIntervalSegmentIndices: [
        for (final segment in segments)
          if (segment.completedMarker) segment.segmentIndex,
      ],
      completedIntervalSegmentSignatures: {
        for (final segment in segments)
          if (segment.completedMarker && segment.completionSignature != null)
            segment.segmentIndex: segment.completionSignature!,
      },
      partialIntervalSegmentIndices: [
        for (final segment in segments)
          if (segment.partialMarker) segment.segmentIndex,
      ],
      totalKcal: row.totalKcal,
      mood: row.mood,
      rpe: row.rpe,
      satisfaction: row.satisfaction,
      painPoints: [for (final pain in pains) pain.label],
      feedbackNotes: row.feedbackNotes,
      xpEarned: row.xpEarned,
      syncedToHealthConnect: row.syncedToHealthConnect,
      exercises: [
        for (final exercise in exerciseRows)
          WorkoutExercise(
            id: exercise.id,
            exerciseId: exercise.exerciseRefId,
            catalogExerciseId: exercise.exerciseId,
            exerciseName: exercise.exerciseNameSnapshot,
            // Un valore che il dominio non conosce NON diventa un ripiego
            // silenzioso: `trackingModeOrNull` e `muscleGroupOrNull` tornano
            // nulli, e il nullo del gruppo è un dato mancante da segnalare.
            trackingMode:
                trackingModeOrNull(exercise.trackingMode) ??
                ExerciseTrackingMode.weightReps,
            muscleGroup: muscleGroupOrNull(exercise.muscleGroupSnapshot),
            restSeconds: exercise.restSeconds,
            isWarmup: exercise.isWarmup,
            isCooldown: exercise.isCooldown,
            isFinisher: exercise.isFinisher,
            isInSupersetWithPrevious: exercise.isInSupersetWithPrevious,
            intervalSegmentIndex: exercise.intervalSegmentIndex,
            sets: [
              for (final set in setsByExercise[exercise.id] ?? const [])
                WorkoutSet(
                  id: set.id,
                  weightKg: set.weightKg,
                  reps: set.reps,
                  durationSec: set.durationSec,
                  distanceM: set.distanceM,
                  rpe: set.rpe,
                  isWarmup: set.isWarmup,
                  completed: set.completed,
                ),
            ],
          ),
      ],
    );
  }

  /// Un checkpoint illeggibile non deve impedire di allenarsi: si perde la
  /// ripresa della fase, non la sessione.
  static Map<String, dynamic>? _decodeCheckpoint(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  // ── Id derivati ──────────────────────────────────────────────────────────

  static String _exerciseRowId(String workoutId, int position) =>
      SyncIds.derived('workout-exercise', '$workoutId/$position');

  static String _setRowId(String exerciseRowId, int position) =>
      SyncIds.derived('workout-set', '$exerciseRowId/$position');

  // ── Limiti ───────────────────────────────────────────────────────────────
  //
  // Come nel salvataggio delle schede: un valore fuori scala si riporta dentro
  // i limiti invece di far fallire la scrittura. In palestra «3600» al posto di
  // «5000» è ancora l'allenamento di Marco, un salvataggio perso no.

  static String _refId(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return 'sconosciuto';
    }
    return trimmed.length <= 64 ? trimmed : trimmed.substring(0, 64);
  }

  static String? _text(String? value, int max) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed.length <= max ? trimmed : trimmed.substring(0, max);
  }

  static int? _bounded(int? value, int min, int max) => value?.clamp(min, max);

  static double? _boundedDouble(double? value, double min, double max) =>
      value?.clamp(min, max);

  static int _atLeastZero(int value) => value < 0 ? 0 : value;

  static int? _atLeastZeroOrNull(int? value) =>
      value == null ? null : _atLeastZero(value);

  static double? _atLeastZeroDouble(double? value) {
    if (value == null) {
      return null;
    }
    return value < 0 ? 0 : value;
  }

  static DateTime _notBefore(DateTime value, DateTime floor) =>
      value.isBefore(floor) ? floor : value;
}
