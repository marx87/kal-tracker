import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';
import 'package:kal_tracker/features/routines/domain/routine_draft.dart';
import 'package:kal_tracker/features/routines/domain/routine_models.dart';
import 'package:kal_tracker/features/workouts/domain/load_progression.dart';
import 'package:uuid/uuid.dart';

/// Lettura e scrittura delle schede.
///
/// Una scheda è quattro tabelle (`routines`, `routine_exercises`,
/// `routine_interval_segments` e il catalogo a cui punta): il salvataggio
/// riscrive i figli in blocco dentro una transazione, perché le posizioni
/// devono restare dense e la UNIQUE (routine, blocco, posizione) non
/// perdona uno stato intermedio.
class RoutineRepository {
  RoutineRepository(this._database, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final AppDatabase _database;
  final Uuid _uuid;

  /// Le schede del profilo, già contate. Lo stream si aggiorna quando cambia
  /// una scheda, una sua riga o il nome di un esercizio citato: sono le tre
  /// tabelle unite qui sotto.
  Stream<List<RoutineSummary>> watchRoutines(
    String profileId, {
    String search = '',
  }) {
    final routines = _database.routines;
    final routineExercises = _database.routineExercises;
    final exercises = _database.exercises;

    final query =
        _database.select(routines).join([
          leftOuterJoin(
            routineExercises,
            routineExercises.routineId.equalsExp(routines.id),
          ),
          leftOuterJoin(
            exercises,
            exercises.id.equalsExp(routineExercises.exerciseId),
          ),
        ])..where(
          routines.profileId.equals(profileId) & routines.deletedAt.isNull(),
        );

    final needle = search.trim().toLowerCase();
    return query.watch().asyncMap((rows) async {
      final byRoutine = <String, LocalRoutine>{};
      final children =
          <
            String,
            List<({LocalRoutineExercise row, LocalExercise? exercise})>
          >{};
      for (final row in rows) {
        final routine = row.readTable(routines);
        byRoutine[routine.id] = routine;
        final child = row.readTableOrNull(routineExercises);
        if (child != null) {
          children.putIfAbsent(routine.id, () => []).add((
            row: child,
            exercise: row.readTableOrNull(exercises),
          ));
        }
      }
      final segments = await _segmentsByRoutine(byRoutine.keys);
      final summaries = [
        for (final routine in byRoutine.values)
          _detailsFrom(
            routine,
            children[routine.id] ?? const [],
            segments[routine.id] ?? const [],
          ).toSummary(),
      ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (needle.isEmpty) {
        return summaries;
      }
      return [
        for (final summary in summaries)
          if (summary.name.toLowerCase().contains(needle)) summary,
      ];
    });
  }

  Future<RoutineDetails?> getRoutine(String id) async {
    final routine =
        await (_database.select(_database.routines)
              ..where((row) => row.id.equals(id) & row.deletedAt.isNull()))
            .getSingleOrNull();
    if (routine == null) {
      return null;
    }

    final rows = await (_database.select(_database.routineExercises).join([
      leftOuterJoin(
        _database.exercises,
        _database.exercises.id.equalsExp(_database.routineExercises.exerciseId),
      ),
    ])..where(_database.routineExercises.routineId.equals(id))).get();
    final children = [
      for (final row in rows)
        (
          row: row.readTable(_database.routineExercises),
          exercise: row.readTableOrNull(_database.exercises),
        ),
    ];
    final segments = await _segmentsByRoutine([id]);
    return _detailsFrom(routine, children, segments[id] ?? const []);
  }

  /// Le schede che citano un esercizio. Serve prima di cancellarlo: una
  /// scheda che perde un esercizio resta eseguibile, ma Marco deve saperlo.
  Stream<List<RoutineUsage>> watchRoutinesUsingExercise(String exerciseId) {
    final routines = _database.routines;
    final routineExercises = _database.routineExercises;
    final query =
        _database.select(routineExercises).join([
          innerJoin(
            routines,
            routines.id.equalsExp(routineExercises.routineId),
          ),
        ])..where(
          routineExercises.exerciseRefId.equals(exerciseId) &
              routines.deletedAt.isNull(),
        );
    return query.watch().map((rows) {
      final usages = <RoutineUsage>[];
      final seen = <String>{};
      for (final row in rows) {
        final child = row.readTable(routineExercises);
        final routine = row.readTable(routines);
        // Un esercizio può comparire in più blocchi della stessa scheda: la
        // lista dice una volta sola «è qui», col blocco in cui sta.
        if (!seen.add('${routine.id}/${child.block}')) {
          continue;
        }
        usages.add(
          RoutineUsage(
            routineId: routine.id,
            routineName: routine.name,
            block: RoutineBlock.fromStorage(child.block),
          ),
        );
      }
      usages.sort((a, b) => a.routineName.compareTo(b.routineName));
      return usages;
    });
  }

  /// Crea o aggiorna una scheda. Restituisce l'id, che per una scheda nuova
  /// è quello appena generato.
  Future<String> saveRoutine({
    required String profileId,
    required RoutineDraft draft,
  }) async {
    final now = AppTime.nowUtc();
    final routineId = draft.id ?? _uuid.v4();
    final details = draft.preview();
    final name = _text(details.name, 160) ?? 'Scheda';
    final notes = _text(details.notes, 1000);
    final workSec = _bounded(details.workSec, 1, 3600);
    final shortRestSec = _bounded(details.shortRestSec, 0, 3600);
    final longRestSec = _bounded(details.longRestSec, 0, 3600);
    final rounds = _bounded(details.rounds, 1, 50);
    final warmupWorkSec = _bounded(details.warmupWorkSec, 1, 3600);
    final warmupRestSec = _bounded(details.warmupRestSec, 0, 3600);

    // Solo gli esercizi che esistono ancora possono reggere la chiave
    // esterna: per gli altri resta l'id originale in `exercise_ref_id`, che
    // è quello con cui il dominio ragiona.
    final referenced = {
      for (final list in [details.warmup, details.main, details.finisher])
        for (final row in list) row.exerciseRefId,
    };
    final known = referenced.isEmpty
        ? const <String>{}
        : (await (_database.select(
                _database.exercises,
              )..where((row) => row.id.isIn(referenced))).get())
              .map((row) => row.id)
              .toSet();

    final exercisePayload = <Map<String, Object?>>[];
    final segmentPayload = <Map<String, Object?>>[];

    await _database.transaction(() async {
      final existing = await (_database.select(
        _database.routines,
      )..where((row) => row.id.equals(routineId))).getSingleOrNull();

      if (existing == null) {
        await _database
            .into(_database.routines)
            .insert(
              RoutinesCompanion.insert(
                id: routineId,
                profileId: profileId,
                name: name,
                notes: Value(notes),
                isCircuit: Value(details.isCircuit),
                workSec: Value(workSec),
                shortRestSec: Value(shortRestSec),
                longRestSec: Value(longRestSec),
                rounds: Value(rounds),
                warmupWorkSec: Value(warmupWorkSec),
                warmupRestSec: Value(warmupRestSec),
                createdAt: now,
                updatedAt: now,
              ),
            );
      } else {
        // `source` ed `external_id` non si toccano: dicono che la scheda
        // arriva dall'export di Gym, e una modifica non la rende «manuale».
        await (_database.update(
          _database.routines,
        )..where((row) => row.id.equals(routineId))).write(
          RoutinesCompanion(
            name: Value(name),
            notes: Value(notes),
            isCircuit: Value(details.isCircuit),
            workSec: Value(workSec),
            shortRestSec: Value(shortRestSec),
            longRestSec: Value(longRestSec),
            rounds: Value(rounds),
            warmupWorkSec: Value(warmupWorkSec),
            warmupRestSec: Value(warmupRestSec),
            deletedAt: const Value(null),
            updatedAt: Value(now),
          ),
        );
      }

      // I figli si riscrivono interi. Un aggiornamento riga per riga
      // dovrebbe attraversare stati in cui due righe condividono la stessa
      // posizione, e la UNIQUE li rifiuterebbe a metà scrittura.
      await (_database.delete(
        _database.routineExercises,
      )..where((row) => row.routineId.equals(routineId))).go();
      await (_database.delete(
        _database.routineIntervalSegments,
      )..where((row) => row.routineId.equals(routineId))).go();

      for (final block in RoutineBlock.values) {
        final rows = switch (block) {
          RoutineBlock.warmup => details.warmup,
          RoutineBlock.main => details.main,
          RoutineBlock.finisher => details.finisher,
        };
        for (final (position, row) in rows.indexed) {
          final isWarmup = block == RoutineBlock.warmup;
          final duration = isWarmup
              ? _bounded(row.warmupDurationSec ?? warmupWorkSec, 1, 3600)
              : null;
          final inSuperset =
              block == RoutineBlock.main &&
              position > 0 &&
              row.inSupersetWithPrevious;
          final rowId = _uuid.v4();
          final snapshot = _text(row.name, 160) ?? 'Esercizio';
          final prescription = row.prescription;
          final sets = _optionalBounded(prescription.sets, 1, 50);
          final reps = _optionalBounded(prescription.reps, 1, 500);
          final durationSec = _optionalBounded(
            prescription.durationSec,
            1,
            7200,
          );
          final restSec = _optionalBounded(prescription.restSec, 0, 3600);
          final range = _rangeOf(prescription);
          final linked = known.contains(row.exerciseRefId)
              ? row.exerciseRefId
              : null;

          await _database
              .into(_database.routineExercises)
              .insert(
                RoutineExercisesCompanion.insert(
                  id: rowId,
                  routineId: routineId,
                  block: block.name,
                  position: position,
                  exerciseRefId: row.exerciseRefId,
                  exerciseId: Value(linked),
                  exerciseNameSnapshot: snapshot,
                  inSupersetWithPrevious: Value(inSuperset),
                  warmupDurationSec: Value(duration),
                  prescSets: Value(sets),
                  prescReps: Value(reps),
                  prescRepsMin: Value(range?.min),
                  prescRepsMax: Value(range?.max),
                  prescDurationSec: Value(durationSec),
                  prescRestSec: Value(restSec),
                ),
              );
          exercisePayload.add({
            'id': rowId,
            'routine_id': routineId,
            'block': block.name,
            'position': position,
            'exercise_ref_id': row.exerciseRefId,
            'exercise_id': linked,
            'exercise_name_snapshot': snapshot,
            'in_superset_with_previous': inSuperset,
            'warmup_duration_sec': duration,
            'presc_sets': sets,
            'presc_reps': reps,
            'presc_reps_min': range?.min,
            'presc_reps_max': range?.max,
            'presc_duration_sec': durationSec,
            'presc_rest_sec': restSec,
          });
        }
      }

      for (final segment in details.segments) {
        final segmentId = _uuid.v4();
        await _database
            .into(_database.routineIntervalSegments)
            .insert(
              RoutineIntervalSegmentsCompanion.insert(
                id: segmentId,
                routineId: routineId,
                segmentIndex: segment.segmentIndex,
                startIdx: segment.startIdx,
                endIdx: segment.endIdx,
                workSec: Value(_bounded(segment.workSec, 1, 3600)),
                restSec: Value(_bounded(segment.restSec, 0, 3600)),
                longRestSec: Value(_bounded(segment.longRestSec, 0, 3600)),
                rounds: Value(_bounded(segment.rounds, 1, 50)),
              ),
            );
        segmentPayload.add({
          'id': segmentId,
          'routine_id': routineId,
          'segment_index': segment.segmentIndex,
          'start_idx': segment.startIdx,
          'end_idx': segment.endIdx,
          'work_sec': _bounded(segment.workSec, 1, 3600),
          'rest_sec': _bounded(segment.restSec, 0, 3600),
          'long_rest_sec': _bounded(segment.longRestSec, 0, 3600),
          'rounds': _bounded(segment.rounds, 1, 50),
        });
      }

      await _appendOutbox(
        entityId: routineId,
        operation: 'upsert',
        payload: {
          'id': routineId,
          'profile_id': profileId,
          'name': name,
          'notes': notes,
          'is_circuit': details.isCircuit,
          'work_sec': workSec,
          'short_rest_sec': shortRestSec,
          'long_rest_sec': longRestSec,
          'rounds': rounds,
          'warmup_work_sec': warmupWorkSec,
          'warmup_rest_sec': warmupRestSec,
          'source': existing?.source ?? 'manual',
          'external_id': existing?.externalId,
          'created_at': (existing?.createdAt ?? now).toIso8601String(),
          'updated_at': now.toIso8601String(),
          // Le due liste ci sono SEMPRE: la loro assenza, per il gateway,
          // significherebbe «questa scrittura non parla dei figli» e i figli
          // remoti resterebbero quelli vecchi.
          'exercises': exercisePayload,
          'interval_segments': segmentPayload,
        },
        now: now,
      );
    });

    return routineId;
  }

  /// Cancellazione morbida, come per gli esercizi: lo storico degli
  /// allenamenti punta ancora alla scheda e ne conserva il nome.
  Future<void> deleteRoutine(String id) async {
    final now = AppTime.nowUtc();
    await _database.transaction(() async {
      await (_database.update(
        _database.routines,
      )..where((row) => row.id.equals(id) & row.deletedAt.isNull())).write(
        RoutinesCompanion(deletedAt: Value(now), updatedAt: Value(now)),
      );
      await _appendOutbox(
        entityId: id,
        operation: 'delete',
        payload: {'id': id, 'deleted_at': now.toIso8601String()},
        now: now,
      );
    });
  }

  Future<Map<String, List<LocalRoutineIntervalSegment>>> _segmentsByRoutine(
    Iterable<String> routineIds,
  ) async {
    final ids = routineIds.toSet();
    if (ids.isEmpty) {
      return const {};
    }
    final rows = await (_database.select(
      _database.routineIntervalSegments,
    )..where((row) => row.routineId.isIn(ids))).get();
    final grouped = <String, List<LocalRoutineIntervalSegment>>{};
    for (final row in rows) {
      grouped.putIfAbsent(row.routineId, () => []).add(row);
    }
    for (final list in grouped.values) {
      list.sort((a, b) => a.segmentIndex.compareTo(b.segmentIndex));
    }
    return grouped;
  }

  RoutineDetails _detailsFrom(
    LocalRoutine routine,
    List<({LocalRoutineExercise row, LocalExercise? exercise})> children,
    List<LocalRoutineIntervalSegment> segments,
  ) {
    final byBlock =
        <
          RoutineBlock,
          List<({LocalRoutineExercise row, LocalExercise? exercise})>
        >{};
    for (final child in children) {
      byBlock
          .putIfAbsent(RoutineBlock.fromStorage(child.row.block), () => [])
          .add(child);
    }
    for (final list in byBlock.values) {
      list.sort((a, b) => a.row.position.compareTo(b.row.position));
    }

    List<RoutineExerciseRef> refs(RoutineBlock block) => [
      for (final child in byBlock[block] ?? const []) _refFrom(child),
    ];

    return RoutineDetails(
      id: routine.id,
      name: routine.name,
      notes: routine.notes,
      isCircuit: routine.isCircuit,
      workSec: routine.workSec,
      shortRestSec: routine.shortRestSec,
      longRestSec: routine.longRestSec,
      rounds: routine.rounds,
      warmupWorkSec: routine.warmupWorkSec,
      warmupRestSec: routine.warmupRestSec,
      warmup: refs(RoutineBlock.warmup),
      main: refs(RoutineBlock.main),
      finisher: refs(RoutineBlock.finisher),
      segments: [
        for (final segment in segments)
          RoutineIntervalSegment(
            segmentIndex: segment.segmentIndex,
            startIdx: segment.startIdx,
            endIdx: segment.endIdx,
            workSec: segment.workSec,
            restSec: segment.restSec,
            longRestSec: segment.longRestSec,
            rounds: segment.rounds,
          ),
      ],
    );
  }

  RoutineExerciseRef _refFrom(
    ({LocalRoutineExercise row, LocalExercise? exercise}) child,
  ) {
    final exercise = child.exercise;
    // Cancellato o mai arrivato è la stessa cosa per chi legge la scheda:
    // l'esercizio non è più scegliibile, e la riga va marcata.
    final missing = exercise == null || exercise.deletedAt != null;
    return RoutineExerciseRef(
      exerciseRefId: child.row.exerciseRefId,
      name: exercise?.name ?? child.row.exerciseNameSnapshot,
      muscleGroup: MuscleGroup.fromStorage(exercise?.muscleGroup),
      trackingMode: ExerciseTrackingMode.fromStorage(exercise?.trackingMode),
      isMissing: missing,
      inSupersetWithPrevious: child.row.inSupersetWithPrevious,
      warmupDurationSec: child.row.warmupDurationSec,
      prescription: ExercisePrescription(
        sets: child.row.prescSets,
        reps: child.row.prescReps,
        // I due estremi si leggono come stanno su disco, anche quando non
        // fanno un intervallo: le colonne sono nullable e senza CHECK, e a
        // dire se quella coppia è una banda è `ExercisePrescription.range`.
        // Correggerli qui vorrebbe dire avere una seconda regola.
        repsMin: child.row.prescRepsMin,
        repsMax: child.row.prescRepsMax,
        durationSec: child.row.prescDurationSec,
        restSec: child.row.prescRestSec,
      ),
    );
  }

  Future<void> _appendOutbox({
    required String entityId,
    required String operation,
    required Map<String, Object?> payload,
    required DateTime now,
  }) => _database
      .into(_database.syncOutbox)
      .insert(
        SyncOutboxCompanion.insert(
          id: _uuid.v4(),
          entityType: 'routine',
          entityId: entityId,
          operation: operation,
          payloadJson: jsonEncode(payload),
          createdAt: now,
        ),
      );

  static String? _text(String? value, int max) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed.length <= max ? trimmed : trimmed.substring(0, max);
  }

  /// Riporta un valore dentro i limiti del database invece di rifiutarlo:
  /// «3600» al posto di «5000» è ancora la scheda di Marco, un errore di
  /// salvataggio no.
  static int _bounded(int value, int min, int max) => value.clamp(min, max);

  static int? _optionalBounded(int? value, int min, int max) =>
      value?.clamp(min, max);

  /// L'intervallo da scrivere sulle due colonne della v9, **o niente**.
  ///
  /// Si salva solo una banda vera: mezzo intervallo (`8` senza tetto) o uno
  /// al contrario (`12-8`) sono due colonne piene che nessun lettore può
  /// usare, cioè un'impostazione che promette una progressione che non
  /// scatterà mai. Meglio il numero fisso, che almeno dice la verità.
  ///
  /// Il giudizio è quello di [RepRange.resolve] e non una copia locale; i
  /// limiti sono quelli di `presc_reps`, perché è la stessa grandezza.
  static RepRange? _rangeOf(ExercisePrescription prescription) =>
      RepRange.resolve(
        min: _optionalBounded(prescription.repsMin, 1, 500),
        max: _optionalBounded(prescription.repsMax, 1, 500),
      );
}
