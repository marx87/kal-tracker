import 'dart:convert';

import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/gym_import/data/gym_json.dart';

/// Ciò che il dump grezzo di Firestore sa e il file di export no.
///
/// L'esportatore dell'app scriveva solo quello che serviva a rileggere lo
/// storico a schermo: le prescrizioni delle schede, i blocchi a tempo, le
/// pause accumulate e i marcatori di completamento dei circuiti non ci sono.
/// Sono però colonne dello schema v6, quindi il dump non è un di più: è
/// l'unica occasione di riempirle, perché Firebase viene spento (M5.8).
///
/// Tutto qui dentro è FACOLTATIVO per costruzione: senza dump l'import gira
/// uguale e questi campi restano nulli, segnalati nel rendiconto.
class GymFirestoreDump {
  GymFirestoreDump._({
    required this.userId,
    required this.exerciseExtras,
    required this.routineExtras,
    required this.workoutExtras,
    required this.measurementCreatedAt,
    required this.warnings,
    required this.unmapped,
  });

  /// Nessun dump: ogni ricerca risponde «non lo so».
  GymFirestoreDump.absent()
    : userId = null,
      exerciseExtras = const {},
      routineExtras = const {},
      workoutExtras = const {},
      measurementCreatedAt = const {},
      warnings = const [],
      unmapped = const {};

  final String? userId;
  final Map<String, GymExerciseExtras> exerciseExtras;
  final Map<String, GymRoutineExtras> routineExtras;
  final Map<String, GymWorkoutExtras> workoutExtras;

  /// L'istante di creazione del documento Firestore: è più preciso della data
  /// della pesata quando la riga viene ricostruita.
  final Map<String, DateTime> measurementCreatedAt;

  final List<String> warnings;

  /// Chiavi lette e non mappate su nessuna colonna, con quanti documenti le
  /// avevano valorizzate.
  final Map<String, int> unmapped;

  bool get isPresent => userId != null;

  /// Legge il dump scegliendo l'utente da importare.
  ///
  /// Con [userId] nullo vince l'unico utente che ha dei `workouts`: gli altri
  /// due UID del dump contengono solo le schede di esempio create dall'app al
  /// primo avvio, e importarle mescolerebbe dati di prova allo storico vero.
  factory GymFirestoreDump.read(Map<String, Object?> raw, {String? userId}) {
    final warnings = <String>[];
    final unmapped = <String, int>{};
    void account(String kind, Map<String, Object?> map, Set<String> consumed) {
      for (final entry in map.entries) {
        if (consumed.contains(entry.key) || _isEmpty(entry.value)) {
          continue;
        }
        final key = 'dump.$kind.${entry.key}';
        unmapped[key] = (unmapped[key] ?? 0) + 1;
      }
    }

    final data = asMap(
      require(raw, 'dati', 'dump Firestore'),
      'dump Firestore: dati',
    );
    final users = asList(
      require(data, 'users', 'dump Firestore: dati'),
      'dump Firestore: dati.users',
    ).map((user) => asMap(user, 'dump Firestore: utente')).toList();

    final chosen = _pickUser(users, userId);
    if (users.length > 1) {
      final others = users
          .map((user) => requireString(user, '__id__', 'dump: utente'))
          .where((id) => id != chosen.$1)
          .join(', ');
      warnings.add(
        'Il dump Firestore contiene ${users.length} utenti: importato solo '
        '${chosen.$1}, ignorati $others.',
      );
    }

    final subs = chosen.$2;
    final exercises = <String, GymExerciseExtras>{};
    for (final raw in subs['exercises'] ?? const []) {
      final map = asMap(raw, 'dump: esercizio');
      final id = requireString(map, '__id__', 'dump: esercizio');
      exercises[id] = GymExerciseExtras(
        isPreset: optionalBool(map['isPreset']) ?? false,
        imageUrl: optionalString(map['imageUrl']),
      );
      account('esercizio', map, const {
        ..._documentKeys,
        'isPreset',
        'imageUrl',
        // Già presenti nell'export, che resta la sorgente della riga.
        'name',
        'muscleGroup',
        'trackingMode',
        'notes',
        'createdAt',
      });
    }

    final routines = <String, GymRoutineExtras>{};
    for (final raw in subs['routines'] ?? const []) {
      final map = asMap(raw, 'dump: scheda');
      final id = requireString(map, '__id__', 'dump: scheda');
      routines[id] = GymRoutineExtras(
        prescriptions: _prescriptions(map['prescriptions'], id),
        segments: _segments(map['intervalSegments'], id, warnings),
      );
      account('scheda', map, const {
        ..._documentKeys,
        'prescriptions',
        'intervalSegments',
        'name',
        'notes',
        'createdAt',
        'exerciseIds',
        'warmupSteps',
        'finisherExerciseIds',
        'supersetIndices',
        'isCircuit',
        'workSec',
        'shortRestSec',
        'longRestSec',
        'rounds',
        'warmupWorkSec',
        'warmupRestSec',
      });
    }

    final workouts = <String, GymWorkoutExtras>{};
    for (final raw in subs['workouts'] ?? const []) {
      final map = asMap(raw, 'dump: sessione');
      final id = requireString(map, '__id__', 'dump: sessione');
      workouts[id] = _workoutExtras(map, id, warnings);
      account('sessione', map, const {
        ..._documentKeys,
        'pausedAt',
        'accumulatedPauseSeconds',
        'finalDurationSeconds',
        'resumePath',
        'circuitCheckpoint',
        'syncedToHealthConnect',
        'healthSyncState',
        'healthSyncAttemptedAt',
        'healthSyncCompletedAt',
        'completedIntervalSegmentIndices',
        'partialIntervalSegmentIndices',
        'completedIntervalSegmentSignatures',
        'exercises',
        // `activeExercises` è la copia di lavoro della stessa lista e
        // `intervalSegmentExercises` la coda append-only: in Firestore erano
        // tre liste parallele perché il documento non aveva transazioni. La
        // riga importata è una sola, e la sorgente è `exercises`.
        'activeExercises',
        'intervalSegmentExercises',
        'startedAt',
        'endedAt',
        'routineId',
        'routineName',
        'notes',
        'totalKcal',
        'mood',
        'rpe',
        'satisfaction',
        'painPoints',
        'feedbackNotes',
        'xpEarned',
      });
      final active = map['activeExercises'];
      final base = map['exercises'];
      if (active is List && base is List && active.length != base.length) {
        warnings.add(
          'Sessione $id: la lista di lavoro ha ${active.length} righe contro '
          'le ${base.length} definitive. Importate le definitive.',
        );
      }
      final appended = map['intervalSegmentExercises'];
      if (appended is List && appended.isNotEmpty) {
        warnings.add(
          'Sessione $id: ${appended.length} righe appese da un blocco a tempo '
          'non sono nell\'export e non vengono importate.',
        );
      }
    }

    final measurementCreatedAt = <String, DateTime>{};
    for (final raw in subs['measurements'] ?? const []) {
      final map = asMap(raw, 'dump: pesata');
      final id = requireString(map, '__id__', 'dump: pesata');
      final created = optionalString(map['__creato__']);
      if (created != null) {
        measurementCreatedAt[id] = AppTime.parseInstant(created);
      }
      account('pesata', map, const {
        ..._documentKeys,
        'weightKg',
        'date',
        'custom',
        'notes',
      });
    }

    return GymFirestoreDump._(
      userId: chosen.$1,
      exerciseExtras: exercises,
      routineExtras: routines,
      workoutExtras: workouts,
      measurementCreatedAt: measurementCreatedAt,
      warnings: warnings,
      unmapped: unmapped,
    );
  }

  static (String, Map<String, List<Object?>>) _pickUser(
    List<Map<String, Object?>> users,
    String? wanted,
  ) {
    if (users.isEmpty) {
      throw const FormatException('Il dump Firestore non contiene utenti.');
    }
    final candidates = <String, Map<String, List<Object?>>>{};
    for (final user in users) {
      final id = requireString(user, '__id__', 'dump: utente');
      final subs = asMap(
        user['__sottocollezioni__'] ?? const <String, Object?>{},
        'dump: sottocollezioni di $id',
      );
      candidates[id] = {
        for (final entry in subs.entries)
          entry.key: asList(entry.value, 'dump: $id/${entry.key}'),
      };
    }
    if (wanted != null) {
      final subs = candidates[wanted];
      if (subs == null) {
        throw FormatException(
          'Il dump Firestore non contiene l\'utente $wanted.',
        );
      }
      return (wanted, subs);
    }
    final withHistory = candidates.entries
        .where((entry) => (entry.value['workouts'] ?? const []).isNotEmpty)
        .toList();
    if (withHistory.length != 1) {
      throw FormatException(
        'Nel dump Firestore ci sono ${withHistory.length} utenti con uno '
        'storico di allenamenti: indica quale importare.',
      );
    }
    return (withHistory.single.key, withHistory.single.value);
  }

  static Map<String, GymPrescription> _prescriptions(
    Object? raw,
    String routineId,
  ) {
    if (raw == null) {
      return const {};
    }
    final map = asMap(raw, 'dump: prescrizioni di $routineId');
    final result = <String, GymPrescription>{};
    for (final entry in map.entries) {
      final value = asMap(
        entry.value,
        'dump: prescrizione ${entry.key} di $routineId',
      );
      final prescription = GymPrescription(
        sets: optionalInt(value['sets']),
        reps: optionalInt(value['reps']),
        durationSec: optionalInt(value['durationSec']),
        restSec: optionalInt(value['restSec']),
      );
      if (prescription.isEmpty) {
        continue;
      }
      result[entry.key] = prescription;
    }
    return result;
  }

  static List<GymRoutineSegment> _segments(
    Object? raw,
    String routineId,
    List<String> warnings,
  ) {
    if (raw == null) {
      return const [];
    }
    final list = asList(raw, 'dump: blocchi a tempo di $routineId');
    final result = <GymRoutineSegment>[];
    for (var index = 0; index < list.length; index++) {
      final map = asMap(list[index], 'dump: blocco $index di $routineId');
      final start = optionalInt(map['start']);
      final end = optionalInt(map['end']);
      if (start == null || end == null || end <= start || start < 0) {
        warnings.add(
          'Scheda $routineId: il blocco a tempo $index copre un intervallo '
          'non valido ($start-$end) e non viene importato.',
        );
        continue;
      }
      result.add(
        GymRoutineSegment(
          segmentIndex: result.length,
          startIdx: start,
          endIdx: end,
          workSec: optionalInt(map['workSec']) ?? 40,
          restSec: optionalInt(map['restSec']) ?? 20,
          longRestSec: optionalInt(map['longRestSec']) ?? 0,
          rounds: optionalInt(map['rounds']) ?? 1,
        ),
      );
    }
    return result;
  }

  static GymWorkoutExtras _workoutExtras(
    Map<String, Object?> map,
    String id,
    List<String> warnings,
  ) {
    final created = optionalString(map['__creato__']);
    final checkpoint = map['circuitCheckpoint'];
    final signatures = map['completedIntervalSegmentSignatures'];
    final state = optionalString(map['healthSyncState']);
    if (state != null && !_healthStates.contains(state)) {
      warnings.add(
        'Sessione $id: stato di sincronizzazione salute "$state" sconosciuto, '
        'non importato.',
      );
    }
    final rows = map['exercises'];
    return GymWorkoutExtras(
      createdAt: created == null ? null : AppTime.parseInstant(created),
      pausedAt: optionalString(map['pausedAt']) == null
          ? null
          : AppTime.parseInstant(map['pausedAt']! as String),
      accumulatedPauseSeconds: optionalInt(map['accumulatedPauseSeconds']),
      finalDurationSeconds: optionalInt(map['finalDurationSeconds']),
      resumePath: optionalString(map['resumePath']),
      circuitCheckpointJson: checkpoint == null ? null : jsonEncode(checkpoint),
      syncedToHealthConnect: optionalBool(map['syncedToHealthConnect']),
      healthSyncState: state != null && _healthStates.contains(state)
          ? state
          : null,
      healthSyncAttemptedAt:
          optionalString(map['healthSyncAttemptedAt']) == null
          ? null
          : AppTime.parseInstant(map['healthSyncAttemptedAt']! as String),
      healthSyncCompletedAt:
          optionalString(map['healthSyncCompletedAt']) == null
          ? null
          : AppTime.parseInstant(map['healthSyncCompletedAt']! as String),
      completedSegments: _indices(map['completedIntervalSegmentIndices']),
      partialSegments: _indices(map['partialIntervalSegmentIndices']),
      completionSignatures: signatures == null
          ? const {}
          : {
              for (final entry in asMap(
                signatures,
                'dump: firme di $id',
              ).entries)
                if (int.tryParse(entry.key) != null &&
                    optionalString(entry.value) != null)
                  int.parse(entry.key): entry.value! as String,
            },
      rowSegmentIndexes: rows is! List
          ? const []
          : [
              for (final row in rows)
                optionalInt(
                  asMap(row, 'dump: riga di $id')['intervalSegmentIndex'],
                ),
            ],
      rowExerciseIds: rows is! List
          ? const []
          : [
              for (final row in rows)
                optionalString(asMap(row, 'dump: riga di $id')['exerciseId']),
            ],
    );
  }

  static Set<int> _indices(Object? raw) {
    if (raw is! List) {
      return const {};
    }
    return {
      for (final value in raw)
        if (optionalInt(value) case final int index when index >= 0) index,
    };
  }

  static bool _isEmpty(Object? value) =>
      value == null ||
      (value is Iterable && value.isEmpty) ||
      (value is Map && value.isEmpty) ||
      (value is String && value.isEmpty);

  /// Metadati che lo strumento di dump aggiunge a ogni documento.
  static const Set<String> _documentKeys = {
    '__id__',
    '__percorso__',
    '__creato__',
    '__aggiornato__',
  };

  static const Set<String> _healthStates = {'writing', 'synced', 'uncertain'};
}

class GymExerciseExtras {
  const GymExerciseExtras({required this.isPreset, required this.imageUrl});

  final bool isPreset;
  final String? imageUrl;
}

class GymRoutineExtras {
  const GymRoutineExtras({required this.prescriptions, required this.segments});

  /// Per id di esercizio, come in Gym: la stessa prescrizione vale per tutte
  /// le righe della scheda che citano quell'esercizio, comprese le ripetute.
  final Map<String, GymPrescription> prescriptions;
  final List<GymRoutineSegment> segments;
}

class GymPrescription {
  const GymPrescription({
    required this.sets,
    required this.reps,
    required this.durationSec,
    required this.restSec,
  });

  final int? sets;
  final int? reps;
  final int? durationSec;
  final int? restSec;

  bool get isEmpty =>
      sets == null && reps == null && durationSec == null && restSec == null;
}

class GymRoutineSegment {
  const GymRoutineSegment({
    required this.segmentIndex,
    required this.startIdx,
    required this.endIdx,
    required this.workSec,
    required this.restSec,
    required this.longRestSec,
    required this.rounds,
  });

  final int segmentIndex;
  final int startIdx;
  final int endIdx;
  final int workSec;
  final int restSec;
  final int longRestSec;
  final int rounds;
}

class GymWorkoutExtras {
  const GymWorkoutExtras({
    required this.createdAt,
    required this.pausedAt,
    required this.accumulatedPauseSeconds,
    required this.finalDurationSeconds,
    required this.resumePath,
    required this.circuitCheckpointJson,
    required this.syncedToHealthConnect,
    required this.healthSyncState,
    required this.healthSyncAttemptedAt,
    required this.healthSyncCompletedAt,
    required this.completedSegments,
    required this.partialSegments,
    required this.completionSignatures,
    required this.rowSegmentIndexes,
    required this.rowExerciseIds,
  });

  final DateTime? createdAt;
  final DateTime? pausedAt;
  final int? accumulatedPauseSeconds;
  final int? finalDurationSeconds;
  final String? resumePath;
  final String? circuitCheckpointJson;
  final bool? syncedToHealthConnect;
  final String? healthSyncState;
  final DateTime? healthSyncAttemptedAt;
  final DateTime? healthSyncCompletedAt;
  final Set<int> completedSegments;
  final Set<int> partialSegments;
  final Map<int, String> completionSignatures;

  /// `intervalSegmentIndex` riga per riga, nello stesso ordine dell'export.
  final List<int?> rowSegmentIndexes;

  /// Gli id degli esercizi riga per riga: servono solo a verificare che
  /// l'ordine del dump sia lo stesso dell'export prima di fidarsene.
  final List<String?> rowExerciseIds;

  Iterable<int> get markedSegments => {
    ...completedSegments,
    ...partialSegments,
  };
}
