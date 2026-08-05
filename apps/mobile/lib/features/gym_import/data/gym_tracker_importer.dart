import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/sync/sync_gateway.dart' show SyncIds;
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/gym_import/data/gym_firestore_dump.dart';
import 'package:kal_tracker/features/gym_import/data/gym_json.dart';
import 'package:kal_tracker/features/gym_import/domain/cool_down_sequence.dart';
import 'package:kal_tracker/features/gym_import/domain/gym_import_report.dart';
import 'package:uuid/uuid.dart';

/// Travaso una tantum dello storico di Gym Tracker (M5.3).
///
/// Legge due sorgenti e le fonde: il file di export dell'app dà la struttura,
/// il dump grezzo di Firestore riempie ciò che l'esportatore non scriveva
/// (prescrizioni, blocchi a tempo, pause accumulate, marcatori di circuito).
/// Il dump è facoltativo: senza, l'import gira uguale e il rendiconto dice
/// cosa è rimasto fuori.
///
/// Idempotente sugli id ORIGINALI: sono la chiave primaria di ogni entità
/// padre, il confronto avviene su tutte le righe — tombstone compresi, così
/// una sessione cancellata non risorge — e un padre già presente non viene
/// riscritto né riletto nei figli. Rilanciarlo è un `isNoop`.
///
/// Tutto avviene in una sola transazione: un file rotto a metà non lascia
/// mezzo storico dentro.
class GymTrackerImporter {
  GymTrackerImporter(this._database, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final AppDatabase _database;
  final Uuid _uuid;

  /// [enqueueSync] è ora VERO di serie. Restava falso perché il gateway non
  /// sapeva mappare `exercise`, `routine`, `workout` e
  /// `workout_profile_stats`: quelle mutation cadevano nel `default:` dello
  /// switch, `pushMutation` riusciva senza fare niente e `SyncEngine._push`
  /// cancellava la riga di outbox contandola come inviata — la coda si
  /// svuotava senza che il server ricevesse nulla, e non c'era modo di
  /// rigenerarla perché al secondo lancio l'importer è un no-op.
  ///
  /// Oggi i quattro tipi sono mappati, un entityType sconosciuto ferma la
  /// testa della coda invece di essere ingoiato, e le migrazioni `0007` e
  /// `0008` sono applicate sul progetto reale: lo storico di Gym può quindi
  /// uscire dal telefono. Resta un parametro perché i test lo spengono per
  /// osservare il solo travaso.
  ///
  /// È `async` anche per i controlli di testa: un metodo che a volte lancia
  /// prima di restituire il Future e a volte dopo obbligherebbe ogni
  /// chiamante a due try diversi.
  Future<GymImportReport> importExport({
    required String profileId,
    required Map<String, Object?> export,
    Map<String, Object?>? firestoreDump,
    String? firestoreUserId,
    bool enqueueSync = true,
  }) async {
    const what = 'export Gym Tracker';
    final app = optionalString(require(export, 'app', what));
    if (app != 'gym-tracker') {
      throw FormatException(
        'Questo file non è un export di Gym Tracker (app: "$app").',
      );
    }
    final schemaVersion = optionalInt(require(export, 'schemaVersion', what));
    if (schemaVersion != 1) {
      throw FormatException(
        'Export di Gym Tracker in versione $schemaVersion: so leggere solo '
        'la 1.',
      );
    }

    final dump = firestoreDump == null
        ? GymFirestoreDump.absent()
        : GymFirestoreDump.read(firestoreDump, userId: firestoreUserId);

    final session = _ImportSession(
      database: _database,
      uuid: _uuid,
      profileId: profileId,
      export: export,
      dump: dump,
      enqueueSync: enqueueSync,
    );
    return _database.transaction(session.run);
  }
}

class _ImportSession {
  _ImportSession({
    required this.database,
    required this.uuid,
    required this.profileId,
    required this.export,
    required this.dump,
    required this.enqueueSync,
  }) : _now = AppTime.nowUtc();

  /// Oltre le 24 ore non è più un allenamento ma una sessione dimenticata
  /// aperta. È l'unico caso che il solo orologio sa riconoscere.
  static const int _suspectWallSeconds = 24 * 3600;

  /// Un minuto di scarto fra orologio e durata registrata è già visibile in
  /// un allenamento da mezz'ora: sotto è arrotondamento.
  static const int _suspectPauseSeconds = 60;

  final AppDatabase database;
  final Uuid uuid;
  final String profileId;
  final Map<String, Object?> export;
  final GymFirestoreDump dump;
  final bool enqueueSync;
  final DateTime _now;

  final List<String> _warnings = [];
  final Map<String, int> _unmapped = {};
  final Map<String, String> _catalogNames = {};
  final Map<String, String> _catalogGroups = {};
  final Map<String, String> _routineNames = {};
  final Set<String> _liveRoutineIds = {};
  List<Map<String, Object?>> _weeklyPlanPayload = const [];
  bool _lostSubSecond = false;

  int _cooldownPresets = 0;
  int _exercises = 0;
  int _routines = 0;
  int _routineExercises = 0;
  int _routineIntervalSegments = 0;
  int _weeklyPlanDays = 0;
  int _profileStats = 0;
  int _achievements = 0;
  int _workouts = 0;
  int _workoutExercises = 0;
  int _workoutSets = 0;
  int _painPoints = 0;
  int _workoutIntervalSegments = 0;
  int _bodyMeasurements = 0;
  int _bodyMeasurementValues = 0;
  int _syncMutations = 0;

  List<Object?> get _rawExercises =>
      asList(require(export, 'exercises', 'export'), 'export.exercises');

  List<Object?> get _rawRoutines =>
      asList(require(export, 'routines', 'export'), 'export.routines');

  List<Object?> get _rawWorkouts =>
      asList(require(export, 'workouts', 'export'), 'export.workouts');

  List<Object?> get _rawMeasurements =>
      asList(require(export, 'measurements', 'export'), 'export.measurements');

  Map<String, Object?> get _rawProfile =>
      asMap(require(export, 'profile', 'export'), 'export.profile');

  Future<GymImportReport> run() async {
    _warnings.addAll(dump.warnings);
    _unmapped.addAll(dump.unmapped);
    _account('export', export, _rootKeys);
    _buildRoutineNames();

    // L'ordine è dettato dalle FK: i preset di defaticamento PRIMA delle righe
    // di allenamento che li citano, il catalogo prima delle schede.
    await _installCooldownPresets();
    await _installExercises();
    await _loadCatalog();
    await _installRoutines();
    await _installWeeklyPlan();
    await _installStats();
    await _installWorkouts();
    await _installMeasurements();

    return GymImportReport(
      cooldownPresets: _cooldownPresets,
      exercises: _exercises,
      routines: _routines,
      routineExercises: _routineExercises,
      routineIntervalSegments: _routineIntervalSegments,
      weeklyPlanDays: _weeklyPlanDays,
      profileStats: _profileStats,
      achievements: _achievements,
      workouts: _workouts,
      workoutExercises: _workoutExercises,
      workoutSets: _workoutSets,
      painPoints: _painPoints,
      workoutIntervalSegments: _workoutIntervalSegments,
      bodyMeasurements: _bodyMeasurements,
      bodyMeasurementValues: _bodyMeasurementValues,
      syncMutations: _syncMutations,
      warnings: List.unmodifiable(_warnings),
      notImported: List.unmodifiable(_buildNotImported()),
      usedFirestoreDump: dump.isPresent,
    );
  }

  /// I nomi delle schede vengono da DUE fonti: le schede vive e i nomi che
  /// solo lo storico conosce. Sei routineId cancellati compaiono in nove
  /// sessioni con il loro `routineName`, e uno di quei sei è anche il giorno 3
  /// del piano settimanale. Senza questa unione la colonna
  /// `routine_name_snapshot`, creata apposta per questo caso, resterebbe vuota
  /// proprio lì.
  void _buildRoutineNames() {
    for (final raw in _rawRoutines) {
      final map = asMap(raw, 'export: scheda');
      final id = requireString(map, 'id', 'export: scheda');
      _routineNames[id] = requireString(map, 'name', 'export: scheda $id');
      _liveRoutineIds.add(id);
    }
    for (final raw in _rawWorkouts) {
      final map = asMap(raw, 'export: sessione');
      final id = optionalString(map['routineId']);
      final name = optionalString(map['routineName']);
      if (id != null && name != null && !_routineNames.containsKey(id)) {
        _routineNames[id] = name;
      }
    }
  }

  // -------------------------------------------------------------------
  // Catalogo
  // -------------------------------------------------------------------

  Future<void> _installCooldownPresets() async {
    for (final item in kCoolDownSequence) {
      final row = await database
          .into(database.exercises)
          .insertReturningOrNull(
            ExercisesCompanion.insert(
              id: item.slug,
              profileId: profileId,
              name: item.name,
              muscleGroup: 'mobilita',
              trackingMode: 'timed',
              notes: Value(item.hint),
              defaultRestSec: const Value(CoolDownItem.restSec),
              isSynthetic: const Value(true),
              source: const Value('cooldown_preset'),
              externalId: Value(item.slug),
              createdAt: _now,
              updatedAt: _now,
            ),
            mode: InsertMode.insertOrIgnore,
          );
      if (row == null) {
        continue;
      }
      _cooldownPresets++;
      // I preset DEVONO andare in coda quanto gli altri esercizi: dodici
      // righe di allenamento in due sessioni li citano e la FK remota
      // `workout_exercises_exercise_fk` rifiuterebbe l'insert. Un 23503 non è
      // fra i codici ritentabili del gateway, quindi la mutation verrebbe
      // scartata e un intero workout sparirebbe in silenzio.
      await _outbox(
        entityType: 'exercise',
        entityId: item.slug,
        payload: {
          'id': item.slug,
          'profile_id': profileId,
          'name': item.name,
          'muscle_group': 'mobilita',
          'tracking_mode': 'timed',
          'notes': item.hint,
          'image_url': null,
          'default_rest_sec': CoolDownItem.restSec,
          'is_preset': false,
          'is_synthetic': true,
          'source': 'cooldown_preset',
          'external_id': item.slug,
          'created_at': _now.toIso8601String(),
          'updated_at': _now.toIso8601String(),
        },
      );
    }
  }

  Future<void> _installExercises() async {
    final existing = await _existingExerciseIds();
    for (final raw in _rawExercises) {
      final map = asMap(raw, 'export: esercizio');
      final id = requireString(map, 'id', 'export: esercizio');
      const what = 'export: esercizio';
      _account('esercizio', map, _exerciseKeys);
      if (existing.contains(id)) {
        continue;
      }
      final extras = dump.exerciseExtras[id];
      final name = requireString(map, 'name', '$what $id');
      final muscleGroup = enumOr(
        require(map, 'muscleGroup', '$what $id'),
        kMuscleGroups,
        'altro',
      );
      final trackingMode = enumOr(
        require(map, 'trackingMode', '$what $id'),
        kTrackingModes,
        'weightReps',
      );
      final notes = optionalString(require(map, 'notes', '$what $id'));
      final createdAt = _instant(requireString(map, 'createdAt', '$what $id'));
      await database
          .into(database.exercises)
          .insert(
            ExercisesCompanion.insert(
              id: id,
              profileId: profileId,
              name: name,
              muscleGroup: muscleGroup,
              trackingMode: trackingMode,
              notes: Value(notes),
              imageUrl: Value(extras?.imageUrl),
              isPreset: Value(extras?.isPreset ?? false),
              source: const Value('gym_tracker'),
              externalId: Value(id),
              createdAt: createdAt,
              updatedAt: _now,
            ),
          );
      _exercises++;
      await _outbox(
        entityType: 'exercise',
        entityId: id,
        payload: {
          'id': id,
          'profile_id': profileId,
          'name': name,
          'muscle_group': muscleGroup,
          'tracking_mode': trackingMode,
          'notes': notes,
          'image_url': extras?.imageUrl,
          'default_rest_sec': null,
          'is_preset': extras?.isPreset ?? false,
          'is_synthetic': false,
          'source': 'gym_tracker',
          'external_id': id,
          'created_at': createdAt.toIso8601String(),
          'updated_at': _now.toIso8601String(),
        },
      );
    }
  }

  Future<void> _loadCatalog() async {
    final table = database.exercises;
    final query = database.selectOnly(table)
      ..addColumns([table.id, table.name, table.muscleGroup]);
    for (final row in await query.get()) {
      final id = row.read(table.id)!;
      _catalogNames[id] = row.read(table.name)!;
      _catalogGroups[id] = row.read(table.muscleGroup)!;
    }
  }

  // -------------------------------------------------------------------
  // Schede
  // -------------------------------------------------------------------

  Future<void> _installRoutines() async {
    final existing = await _existingRoutineIds();
    for (final raw in _rawRoutines) {
      final map = asMap(raw, 'export: scheda');
      final id = requireString(map, 'id', 'export: scheda');
      final what = 'export: scheda $id';
      _account('scheda', map, _routineKeys);
      if (existing.contains(id)) {
        continue;
      }
      final name = requireString(map, 'name', what);
      final notes = optionalString(require(map, 'notes', what));
      final createdAt = _instant(requireString(map, 'createdAt', what));
      await database
          .into(database.routines)
          .insert(
            RoutinesCompanion.insert(
              id: id,
              profileId: profileId,
              name: name,
              notes: Value(notes),
              isCircuit: Value(optionalBool(map['isCircuit']) ?? false),
              workSec: Value(optionalInt(map['workSec']) ?? 30),
              shortRestSec: Value(optionalInt(map['shortRestSec']) ?? 30),
              longRestSec: Value(optionalInt(map['longRestSec']) ?? 60),
              rounds: Value(optionalInt(map['rounds']) ?? 3),
              warmupWorkSec: Value(optionalInt(map['warmupWorkSec']) ?? 30),
              warmupRestSec: Value(optionalInt(map['warmupRestSec']) ?? 15),
              source: const Value('gym_tracker'),
              externalId: Value(id),
              createdAt: createdAt,
              updatedAt: _now,
            ),
          );
      _routines++;

      final extras = dump.routineExtras[id];
      final rows = await _installRoutineExercises(map, id, extras);
      final segments = await _installRoutineSegments(id, extras);

      await _outbox(
        entityType: 'routine',
        entityId: id,
        payload: {
          'id': id,
          'profile_id': profileId,
          'name': name,
          'notes': notes,
          'is_circuit': optionalBool(map['isCircuit']) ?? false,
          'work_sec': optionalInt(map['workSec']) ?? 30,
          'short_rest_sec': optionalInt(map['shortRestSec']) ?? 30,
          'long_rest_sec': optionalInt(map['longRestSec']) ?? 60,
          'rounds': optionalInt(map['rounds']) ?? 3,
          'warmup_work_sec': optionalInt(map['warmupWorkSec']) ?? 30,
          'warmup_rest_sec': optionalInt(map['warmupRestSec']) ?? 15,
          'source': 'gym_tracker',
          'external_id': id,
          'created_at': createdAt.toIso8601String(),
          'updated_at': _now.toIso8601String(),
          'exercises': rows,
          'interval_segments': segments,
        },
      );
    }
  }

  Future<List<Map<String, Object?>>> _installRoutineExercises(
    Map<String, Object?> map,
    String routineId,
    GymRoutineExtras? extras,
  ) async {
    final what = 'export: scheda $routineId';
    final payload = <Map<String, Object?>>[];

    // `supersetIndices` elencava le posizioni del blocco principale incatenate
    // alla precedente: in SQL è il booleano sulla riga.
    final superset = {
      for (final value in asList(
        require(map, 'supersetIndices', what),
        '$what: supersetIndices',
      ))
        if (optionalInt(value) case final int index) index,
    };

    final warmup = asList(
      require(map, 'warmupSteps', what),
      '$what: warmupSteps',
    );
    for (var i = 0; i < warmup.length; i++) {
      final step = asMap(warmup[i], '$what: riscaldamento $i');
      _account('passo di riscaldamento', step, _warmupStepKeys);
      final exerciseId = requireString(
        step,
        'exerciseId',
        '$what: riscaldamento $i',
      );
      final duration = optionalInt(
        require(step, 'durationSec', '$what: riscaldamento $i'),
      );
      if (duration == null || duration <= 0) {
        throw FormatException(
          '$what: il passo di riscaldamento $i non ha una durata.',
        );
      }
      payload.add(
        await _insertRoutineExercise(
          routineId: routineId,
          block: 'warmup',
          position: i,
          exerciseRefId: exerciseId,
          inSuperset: false,
          warmupDurationSec: duration,
          prescription: extras?.prescriptions[exerciseId],
        ),
      );
    }

    final main = asList(
      require(map, 'exerciseIds', what),
      '$what: exerciseIds',
    );
    for (var i = 0; i < main.length; i++) {
      final exerciseId = optionalString(main[i]);
      if (exerciseId == null) {
        throw FormatException('$what: la posizione $i non ha un esercizio.');
      }
      payload.add(
        await _insertRoutineExercise(
          routineId: routineId,
          block: 'main',
          position: i,
          exerciseRefId: exerciseId,
          inSuperset: i > 0 && superset.contains(i),
          warmupDurationSec: null,
          prescription: extras?.prescriptions[exerciseId],
        ),
      );
    }

    final finisher = asList(
      require(map, 'finisherExerciseIds', what),
      '$what: finisherExerciseIds',
    );
    for (var i = 0; i < finisher.length; i++) {
      final exerciseId = optionalString(finisher[i]);
      if (exerciseId == null) {
        throw FormatException('$what: il finisher $i non ha un esercizio.');
      }
      payload.add(
        await _insertRoutineExercise(
          routineId: routineId,
          block: 'finisher',
          position: i,
          exerciseRefId: exerciseId,
          inSuperset: false,
          warmupDurationSec: null,
          prescription: extras?.prescriptions[exerciseId],
        ),
      );
    }
    return payload;
  }

  Future<Map<String, Object?>> _insertRoutineExercise({
    required String routineId,
    required String block,
    required int position,
    required String exerciseRefId,
    required bool inSuperset,
    required int? warmupDurationSec,
    required GymPrescription? prescription,
  }) async {
    final id = SyncIds.derived(
      'gym-routine-exercise',
      '$routineId/$block/$position',
    );
    final known = _catalogNames.containsKey(exerciseRefId);
    if (!known) {
      _warnings.add(
        'Scheda ${_routineNames[routineId] ?? routineId}: la posizione '
        '$position del blocco $block cita l\'esercizio $exerciseRefId, che non '
        'è nel catalogo. Importata senza collegamento.',
      );
    }
    await database
        .into(database.routineExercises)
        .insert(
          RoutineExercisesCompanion.insert(
            id: id,
            routineId: routineId,
            block: block,
            position: position,
            exerciseRefId: exerciseRefId,
            exerciseId: Value(known ? exerciseRefId : null),
            exerciseNameSnapshot: _catalogNames[exerciseRefId] ?? exerciseRefId,
            inSupersetWithPrevious: Value(inSuperset),
            warmupDurationSec: Value(warmupDurationSec),
            prescSets: Value(prescription?.sets),
            prescReps: Value(prescription?.reps),
            prescDurationSec: Value(prescription?.durationSec),
            prescRestSec: Value(prescription?.restSec),
          ),
        );
    _routineExercises++;
    return {
      'id': id,
      'routine_id': routineId,
      'block': block,
      'position': position,
      'exercise_ref_id': exerciseRefId,
      'exercise_id': known ? exerciseRefId : null,
      'exercise_name_snapshot': _catalogNames[exerciseRefId] ?? exerciseRefId,
      'in_superset_with_previous': inSuperset,
      'warmup_duration_sec': warmupDurationSec,
      'presc_sets': prescription?.sets,
      'presc_reps': prescription?.reps,
      'presc_duration_sec': prescription?.durationSec,
      'presc_rest_sec': prescription?.restSec,
    };
  }

  Future<List<Map<String, Object?>>> _installRoutineSegments(
    String routineId,
    GymRoutineExtras? extras,
  ) async {
    final payload = <Map<String, Object?>>[];
    for (final segment in extras?.segments ?? const <GymRoutineSegment>[]) {
      final id = SyncIds.derived(
        'gym-routine-segment',
        '$routineId/${segment.segmentIndex}',
      );
      await database
          .into(database.routineIntervalSegments)
          .insert(
            RoutineIntervalSegmentsCompanion.insert(
              id: id,
              routineId: routineId,
              segmentIndex: segment.segmentIndex,
              startIdx: segment.startIdx,
              endIdx: segment.endIdx,
              workSec: Value(segment.workSec),
              restSec: Value(segment.restSec),
              longRestSec: Value(segment.longRestSec),
              rounds: Value(segment.rounds),
            ),
          );
      _routineIntervalSegments++;
      payload.add({
        'id': id,
        'routine_id': routineId,
        'segment_index': segment.segmentIndex,
        'start_idx': segment.startIdx,
        'end_idx': segment.endIdx,
        'work_sec': segment.workSec,
        'rest_sec': segment.restSec,
        'long_rest_sec': segment.longRestSec,
        'rounds': segment.rounds,
      });
    }
    return payload;
  }

  // -------------------------------------------------------------------
  // Profilo: piano settimanale, XP, trofei
  // -------------------------------------------------------------------

  Future<void> _installWeeklyPlan() async {
    final profile = _rawProfile;
    final raw = asMap(
      require(profile, 'weeklyPlan', 'export: profilo'),
      'export: piano settimanale',
    );
    final payload = <Map<String, Object?>>[];
    final weekdays = raw.keys.toList()..sort();
    for (final key in weekdays) {
      final weekday = int.tryParse(key);
      if (weekday == null || weekday < 1 || weekday > 7) {
        _warnings.add(
          'Piano settimanale: il giorno "$key" non è un giorno ISO 1-7 e non '
          'viene importato.',
        );
        continue;
      }
      final routineId = optionalString(raw[key]);
      if (routineId == null) {
        continue;
      }
      final live = _liveRoutineIds.contains(routineId);
      final name = _routineNames[routineId];
      if (!live) {
        _warnings.add(
          'Piano settimanale, giorno $weekday: la scheda $routineId '
          '${name == null ? '' : '(«$name») '}non esiste più. Il giorno resta '
          'con id e nome conservati, senza collegamento.',
        );
      }
      final id = SyncIds.derived('gym-weekly-plan', '$profileId/$weekday');
      final row = await database
          .into(database.routineWeeklyPlan)
          .insertReturningOrNull(
            RoutineWeeklyPlanCompanion.insert(
              id: id,
              profileId: profileId,
              weekday: weekday,
              routineId: Value(live ? routineId : null),
              routineExternalId: Value(routineId),
              routineNameSnapshot: Value(name),
              updatedAt: _now,
            ),
            mode: InsertMode.insertOrIgnore,
          );
      payload.add({
        'id': id,
        'profile_id': profileId,
        'weekday': weekday,
        'routine_id': live ? routineId : null,
        'routine_external_id': routineId,
        'routine_name_snapshot': name,
        'updated_at': _now.toIso8601String(),
      });
      if (row != null) {
        _weeklyPlanDays++;
      }
    }
    _weeklyPlanPayload = payload;
  }

  Future<void> _installStats() async {
    final profile = _rawProfile;
    const what = 'export: profilo';
    _account('profilo', profile, _profileKeys);

    final slugs = [
      for (final value in asList(
        require(profile, 'unlockedAchievements', what),
        '$what: unlockedAchievements',
      ))
        if (optionalString(value) case final String slug) slug,
    ];
    final achievementPayload = <Map<String, Object?>>[];
    for (final slug in slugs) {
      final id = SyncIds.derived('workout-achievement', '$profileId/$slug');
      final row = await database
          .into(database.workoutAchievements)
          .insertReturningOrNull(
            WorkoutAchievementsCompanion.insert(
              id: id,
              profileId: profileId,
              slug: slug,
            ),
            mode: InsertMode.insertOrIgnore,
          );
      achievementPayload.add({'id': id, 'slug': slug});
      if (row != null) {
        _achievements++;
      }
    }

    final existing = await (database.select(
      database.workoutProfileStats,
    )..where((row) => row.profileId.equals(profileId))).getSingleOrNull();
    if (existing != null) {
      return;
    }

    final totalXp = optionalInt(require(profile, 'totalXp', what)) ?? 0;
    final current = optionalInt(require(profile, 'currentStreak', what)) ?? 0;
    final longestRaw =
        optionalInt(require(profile, 'longestStreak', what)) ?? 0;
    final longest = longestRaw > current ? longestRaw : current;
    final lastDayRaw = optionalString(require(profile, 'lastWorkoutDay', what));
    // Il giorno di calendario romano, non l'istante: è la chiave con cui lo
    // streak si confronta con «oggi».
    final lastDay = lastDayRaw == null
        ? null
        : AppTime.startOfDayUtc(AppTime.inRome(_instant(lastDayRaw)));
    final weeklyWorkoutGoal =
        optionalInt(require(profile, 'weeklyWorkoutGoal', what)) ?? 3;
    final weeklyKcalGoal =
        optionalInt(require(profile, 'weeklyKcalGoal', what)) ?? 1500;
    final reminderEnabled =
        optionalBool(require(profile, 'reminderEnabled', what)) ?? false;
    final reminderHour =
        optionalInt(require(profile, 'reminderHour', what)) ?? 18;
    final reminderMinute =
        optionalInt(require(profile, 'reminderMinute', what)) ?? 0;
    final healthConnectEnabled =
        optionalBool(require(profile, 'healthConnectEnabled', what)) ?? false;
    final voiceEnabled =
        optionalBool(require(profile, 'voiceEnabled', what)) ?? true;
    // Si conserva ma non si usa: `pickBodyKg` ha `UserProfile.bodyWeightKg`
    // come priorità 1 e restituirebbe 94,7 invece dell'ultima pesata reale.
    final gymBodyWeightKg = optionalDouble(
      require(profile, 'bodyWeightKg', what),
    );
    final exportedAtRaw = optionalString(
      require(export, 'exportedAt', 'export'),
    );
    final exportedAt = exportedAtRaw == null ? null : _instant(exportedAtRaw);

    final statsId = SyncIds.derived('workout-profile-stats', profileId);
    await database
        .into(database.workoutProfileStats)
        .insert(
          WorkoutProfileStatsCompanion.insert(
            id: statsId,
            profileId: profileId,
            totalXp: Value(totalXp),
            currentStreak: Value(current),
            longestStreak: Value(longest),
            lastWorkoutDay: Value(lastDay),
            weeklyWorkoutGoal: Value(weeklyWorkoutGoal),
            weeklyKcalGoal: Value(weeklyKcalGoal),
            reminderEnabled: Value(reminderEnabled),
            reminderHour: Value(reminderHour),
            reminderMinute: Value(reminderMinute),
            healthConnectEnabled: Value(healthConnectEnabled),
            voiceEnabled: Value(voiceEnabled),
            gymBodyWeightKg: Value(gymBodyWeightKg),
            gymExportedAt: Value(exportedAt),
            createdAt: _now,
            updatedAt: _now,
          ),
        );
    _profileStats++;

    await _outbox(
      entityType: 'workout_profile_stats',
      entityId: statsId,
      payload: {
        'id': statsId,
        'profile_id': profileId,
        'total_xp': totalXp,
        'current_streak': current,
        'longest_streak': longest,
        // Colonna remota `date`: va la data di calendario romana, non
        // l'istante. Postgres troncherebbe al giorno UTC e lo streak si
        // spezzerebbe di un giorno al primo pull.
        'last_workout_day': lastDay == null
            ? null
            : AppTime.romeDateString(lastDay),
        'weekly_workout_goal': weeklyWorkoutGoal,
        'weekly_kcal_goal': weeklyKcalGoal,
        'reminder_enabled': reminderEnabled,
        'reminder_hour': reminderHour,
        'reminder_minute': reminderMinute,
        'health_connect_enabled': healthConnectEnabled,
        'voice_enabled': voiceEnabled,
        'gym_body_weight_kg': gymBodyWeightKg,
        'gym_exported_at': exportedAt?.toIso8601String(),
        'achievements': achievementPayload,
        'weekly_plan': _weeklyPlanPayload,
        'created_at': _now.toIso8601String(),
        'updated_at': _now.toIso8601String(),
      },
    );
  }

  // -------------------------------------------------------------------
  // Sessioni
  // -------------------------------------------------------------------

  Future<void> _installWorkouts() async {
    final existing = await _existingWorkoutIds();
    final raw = _rawWorkouts;
    if (raw.length >= 100) {
      _warnings.add(
        'L\'export contiene ${raw.length} sessioni: Gym ne esportava solo '
        'quelle già caricate a schermo, quindi lo storico più vecchio '
        'potrebbe non esserci.',
      );
    }
    final orphanRoutines = <String, int>{};

    for (final item in raw) {
      final map = asMap(item, 'export: sessione');
      final id = requireString(map, 'id', 'export: sessione');
      final what = 'export: sessione $id';
      _account('sessione', map, _workoutKeys);

      final routineExternalId = optionalString(require(map, 'routineId', what));
      if (routineExternalId != null &&
          !_liveRoutineIds.contains(routineExternalId)) {
        orphanRoutines[routineExternalId] =
            (orphanRoutines[routineExternalId] ?? 0) + 1;
      }
      if (existing.contains(id)) {
        continue;
      }

      final startedAt = _instant(requireString(map, 'startedAt', what));
      final endedRaw = optionalString(require(map, 'endedAt', what));
      final endedAt = endedRaw == null ? null : _instant(endedRaw);
      if (endedAt != null && endedAt.isBefore(startedAt)) {
        throw FormatException('$what: finisce prima di iniziare.');
      }
      final extras = dump.workoutExtras[id];
      final live =
          routineExternalId != null &&
          _liveRoutineIds.contains(routineExternalId);
      final routineName =
          optionalString(require(map, 'routineName', what)) ??
          (routineExternalId == null ? null : _routineNames[routineExternalId]);

      // `paused_at` esiste solo su una sessione ancora aperta: lo schema lo
      // impone e i dati veri non lo violano mai.
      final pausedAt = endedAt == null ? extras?.pausedAt : null;
      final pauseSeconds = extras?.accumulatedPauseSeconds ?? 0;
      final finalSeconds = extras?.finalDurationSeconds;
      final suspect = _isDurationSuspect(
        startedAt: startedAt,
        endedAt: endedAt,
        pauseSeconds: pauseSeconds,
        finalSeconds: finalSeconds,
      );

      final notes = optionalString(require(map, 'notes', what));
      final totalKcal = optionalDouble(require(map, 'totalKcal', what));
      final mood = optionalInt(require(map, 'mood', what));
      final rpe = optionalInt(require(map, 'rpe', what));
      final satisfaction = optionalInt(require(map, 'satisfaction', what));
      final feedbackNotes = optionalString(require(map, 'feedbackNotes', what));
      final xpEarned = optionalInt(require(map, 'xpEarned', what));

      await database
          .into(database.workouts)
          .insert(
            WorkoutsCompanion.insert(
              id: id,
              profileId: profileId,
              startedAt: startedAt,
              endedAt: Value(endedAt),
              pausedAt: Value(pausedAt),
              accumulatedPauseSeconds: Value(pauseSeconds),
              finalDurationSeconds: Value(finalSeconds),
              durationSuspect: Value(suspect),
              routineId: Value(live ? routineExternalId : null),
              routineExternalId: Value(routineExternalId),
              routineNameSnapshot: Value(routineName),
              notes: Value(notes),
              totalKcal: Value(totalKcal),
              mood: Value(mood),
              rpe: Value(rpe),
              satisfaction: Value(satisfaction),
              feedbackNotes: Value(feedbackNotes),
              xpEarned: Value(xpEarned),
              resumePath: Value(extras?.resumePath),
              circuitCheckpointJson: Value(extras?.circuitCheckpointJson),
              syncedToHealthConnect: Value(
                extras?.syncedToHealthConnect ?? false,
              ),
              healthSyncState: Value(extras?.healthSyncState),
              healthSyncAttemptedAt: Value(extras?.healthSyncAttemptedAt),
              healthSyncCompletedAt: Value(extras?.healthSyncCompletedAt),
              source: const Value('gym_tracker'),
              externalId: Value(id),
              createdAt: extras?.createdAt ?? startedAt,
              updatedAt: _now,
            ),
          );
      _workouts++;

      final rows = await _installWorkoutExercises(map, id, extras);
      final pains = await _installPainPoints(map, id);
      final segments = await _installWorkoutSegments(id, extras);

      await _outbox(
        entityType: 'workout',
        entityId: id,
        payload: {
          'id': id,
          'profile_id': profileId,
          'started_at': startedAt.toIso8601String(),
          'ended_at': endedAt?.toIso8601String(),
          'paused_at': pausedAt?.toIso8601String(),
          'accumulated_pause_seconds': pauseSeconds,
          'final_duration_seconds': finalSeconds,
          'duration_suspect': suspect,
          'routine_id': live ? routineExternalId : null,
          'routine_external_id': routineExternalId,
          'routine_name_snapshot': routineName,
          'notes': notes,
          'total_kcal': totalKcal,
          'mood': mood,
          'rpe': rpe,
          'satisfaction': satisfaction,
          'feedback_notes': feedbackNotes,
          'xp_earned': xpEarned,
          'resume_path': extras?.resumePath,
          'circuit_checkpoint_json': extras?.circuitCheckpointJson,
          'synced_to_health_connect': extras?.syncedToHealthConnect ?? false,
          'health_sync_state': extras?.healthSyncState,
          'health_sync_attempted_at': extras?.healthSyncAttemptedAt
              ?.toIso8601String(),
          'health_sync_completed_at': extras?.healthSyncCompletedAt
              ?.toIso8601String(),
          'source': 'gym_tracker',
          'external_id': id,
          'created_at': (extras?.createdAt ?? startedAt).toIso8601String(),
          'updated_at': _now.toIso8601String(),
          'exercises': rows,
          'pain_points': pains,
          'interval_segments': segments,
        },
      );
    }

    // Il nome NON è una chiave: si segnala il caso in cui una scheda viva si
    // chiama come quella cancellata, perché è la trappola in cui verrebbe
    // voglia di cadere.
    final liveNames = {
      for (final id in _liveRoutineIds)
        if (_routineNames[id] case final String name) name,
    };
    for (final entry in orphanRoutines.entries) {
      final name = _routineNames[entry.key];
      final omonima = name != null && liveNames.contains(name);
      _warnings.add(
        'La scheda ${entry.key}${name == null ? '' : ' («$name»)'} non esiste '
        'più ma ${entry.value} '
        '${entry.value == 1 ? 'sessione la cita' : 'sessioni la citano'}: id e '
        'nome restano sulla sessione, il collegamento no.'
        '${omonima ? ' Attenzione: esiste una scheda viva con lo stesso nome '
                  'e id diverso, ricollegarle per nome creerebbe una storia '
                  'falsa.' : ''}',
      );
    }
  }

  /// Marca le sessioni in cui l'orologio da solo mente. Non rettifica niente:
  /// i valori grezzi (orologio, pause, durata registrata) entrano tutti come
  /// stanno, e il flag dice soltanto di non fidarsi della sottrazione.
  bool _isDurationSuspect({
    required DateTime startedAt,
    required DateTime? endedAt,
    required int pauseSeconds,
    required int? finalSeconds,
  }) {
    final wallSeconds = endedAt?.difference(startedAt).inSeconds;
    final effective =
        finalSeconds ??
        (wallSeconds == null ? null : wallSeconds - pauseSeconds);
    if (effective != null && effective > _suspectWallSeconds) {
      _warnings.add(
        'Sessione del ${_day(startedAt)}: rimasta aperta '
        '${(effective / 3600).round()} ore. Importata grezza e marcata come '
        'durata sospetta: senza una tua decisione non la rettifico.',
      );
      return true;
    }
    if (wallSeconds != null &&
        finalSeconds != null &&
        wallSeconds - finalSeconds > _suspectPauseSeconds) {
      _warnings.add(
        'Sessione del ${_day(startedAt)}: l\'orologio segna '
        '${(wallSeconds / 60).round()} minuti ma Gym ne aveva registrati '
        '${(finalSeconds / 60).round()} ($pauseSeconds secondi di pausa). '
        'Importati entrambi i valori grezzi, la durata da orologio è marcata '
        'come sospetta.',
      );
      return true;
    }
    return false;
  }

  Future<List<Map<String, Object?>>> _installWorkoutExercises(
    Map<String, Object?> map,
    String workoutId,
    GymWorkoutExtras? extras,
  ) async {
    final what = 'export: sessione $workoutId';
    final rows = asList(require(map, 'exercises', what), '$what: exercises');
    final payload = <Map<String, Object?>>[];
    for (var i = 0; i < rows.length; i++) {
      final row = asMap(rows[i], '$what: riga $i');
      _account('riga di sessione', row, _workoutRowKeys);
      final rowId = SyncIds.derived('gym-workout-exercise', '$workoutId/$i');
      final exerciseId = requireString(row, 'exerciseId', '$what: riga $i');
      final known = _catalogNames.containsKey(exerciseId);
      if (!known) {
        _warnings.add(
          'Sessione $workoutId, riga $i: l\'esercizio $exerciseId non è nel '
          'catalogo. La riga entra con id e nome conservati, senza '
          'collegamento.',
        );
      }
      final trackingMode = enumOr(
        require(row, 'trackingMode', '$what: riga $i'),
        kTrackingModes,
        'weightReps',
      );
      final nameSnapshot = requireString(row, 'exerciseName', '$what: riga $i');
      final restSeconds = optionalInt(row['restSeconds']);
      final isWarmup = optionalBool(row['isWarmup']) ?? false;
      final isCooldown = optionalBool(row['isCooldown']) ?? false;
      final isFinisher = optionalBool(row['isFinisher']) ?? false;
      // La catena di superserie non può cominciare dalla prima riga.
      final inSuperset =
          i > 0 && (optionalBool(row['isInSupersetWithPrevious']) ?? false);
      final segmentIndex = _rowSegmentIndex(extras, i, exerciseId);

      await database
          .into(database.workoutExercises)
          .insert(
            WorkoutExercisesCompanion.insert(
              id: rowId,
              workoutId: workoutId,
              position: i,
              // L'id originale non si perde MAI: è la chiave con cui
              // personal_records e kcal_estimator raggruppano. La FK può
              // diventare NULL, questa no.
              exerciseRefId: exerciseId,
              exerciseId: Value(known ? exerciseId : null),
              exerciseNameSnapshot: nameSnapshot,
              trackingMode: trackingMode,
              muscleGroupSnapshot: Value(_catalogGroups[exerciseId]),
              restSeconds: Value(restSeconds),
              isWarmup: Value(isWarmup),
              isCooldown: Value(isCooldown),
              isFinisher: Value(isFinisher),
              isInSupersetWithPrevious: Value(inSuperset),
              intervalSegmentIndex: Value(segmentIndex),
            ),
          );
      _workoutExercises++;

      final sets = await _installWorkoutSets(row, rowId, '$what: riga $i');
      payload.add({
        'id': rowId,
        'workout_id': workoutId,
        'position': i,
        'exercise_ref_id': exerciseId,
        'exercise_id': known ? exerciseId : null,
        'exercise_name_snapshot': nameSnapshot,
        'tracking_mode': trackingMode,
        'muscle_group_snapshot': _catalogGroups[exerciseId],
        'rest_seconds': restSeconds,
        'is_warmup': isWarmup,
        'is_cooldown': isCooldown,
        'is_finisher': isFinisher,
        'is_in_superset_with_previous': inSuperset,
        'interval_segment_index': segmentIndex,
        'sets': sets,
      });
    }
    return payload;
  }

  /// Il dump elenca le righe nello stesso ordine dell'export: prima di
  /// prendergli `intervalSegmentIndex` si verifica che la riga sia la stessa,
  /// altrimenti si preferisce non saperlo a saperlo storto.
  int? _rowSegmentIndex(GymWorkoutExtras? extras, int position, String id) {
    if (extras == null || position >= extras.rowExerciseIds.length) {
      return null;
    }
    if (extras.rowExerciseIds[position] != id) {
      return null;
    }
    return extras.rowSegmentIndexes[position];
  }

  Future<List<Map<String, Object?>>> _installWorkoutSets(
    Map<String, Object?> row,
    String rowId,
    String what,
  ) async {
    final sets = asList(require(row, 'sets', what), '$what: sets');
    final payload = <Map<String, Object?>>[];
    for (var i = 0; i < sets.length; i++) {
      final set = asMap(sets[i], '$what: serie $i');
      _account('serie', set, _setKeys);
      final id = SyncIds.derived('gym-workout-set', '$rowId/$i');
      final weightKg = optionalDouble(set['weightKg']);
      final reps = optionalInt(set['reps']);
      final durationSec = optionalInt(set['durationSec']);
      final distanceM = optionalDouble(set['distanceM']);
      final rpe = optionalInt(set['rpe']);
      final isWarmup = optionalBool(set['isWarmup']) ?? false;
      final completed = optionalBool(set['completed']) ?? false;
      await database
          .into(database.workoutSets)
          .insert(
            WorkoutSetsCompanion.insert(
              id: id,
              workoutExerciseId: rowId,
              position: i,
              weightKg: Value(weightKg),
              reps: Value(reps),
              durationSec: Value(durationSec),
              distanceM: Value(distanceM),
              rpe: Value(rpe),
              isWarmup: Value(isWarmup),
              completed: Value(completed),
            ),
          );
      _workoutSets++;
      payload.add({
        'id': id,
        'workout_exercise_id': rowId,
        'position': i,
        'weight_kg': weightKg,
        'reps': reps,
        'duration_sec': durationSec,
        'distance_m': distanceM,
        'rpe': rpe,
        'is_warmup': isWarmup,
        'completed': completed,
      });
    }
    return payload;
  }

  Future<List<Map<String, Object?>>> _installPainPoints(
    Map<String, Object?> map,
    String workoutId,
  ) async {
    final what = 'export: sessione $workoutId';
    final labels = asList(
      require(map, 'painPoints', what),
      '$what: painPoints',
    );
    final payload = <Map<String, Object?>>[];
    for (final raw in labels) {
      final label = optionalString(raw);
      if (label == null) {
        continue;
      }
      final id = SyncIds.derived('gym-pain-point', '$workoutId/$label');
      final row = await database
          .into(database.workoutPainPoints)
          .insertReturningOrNull(
            WorkoutPainPointsCompanion.insert(
              id: id,
              workoutId: workoutId,
              label: label,
            ),
            mode: InsertMode.insertOrIgnore,
          );
      payload.add({'id': id, 'workout_id': workoutId, 'label': label});
      if (row != null) {
        _painPoints++;
      }
    }
    return payload;
  }

  Future<List<Map<String, Object?>>> _installWorkoutSegments(
    String workoutId,
    GymWorkoutExtras? extras,
  ) async {
    if (extras == null) {
      return const [];
    }
    final payload = <Map<String, Object?>>[];
    final indices = extras.markedSegments.toList()..sort();
    for (final index in indices) {
      final completed = extras.completedSegments.contains(index);
      final partial = extras.partialSegments.contains(index);
      final id = SyncIds.derived('gym-workout-segment', '$workoutId/$index');
      // La firma appartiene SOLO al marcatore di completamento: senza quello
      // non esiste, e lo schema lo impone.
      final signature = completed ? extras.completionSignatures[index] : null;
      await database
          .into(database.workoutIntervalSegments)
          .insert(
            WorkoutIntervalSegmentsCompanion.insert(
              id: id,
              workoutId: workoutId,
              segmentIndex: index,
              completedMarker: Value(completed),
              partialMarker: Value(partial),
              completionSignature: Value(signature),
            ),
          );
      _workoutIntervalSegments++;
      payload.add({
        'id': id,
        'workout_id': workoutId,
        'segment_index': index,
        'completed_marker': completed,
        'partial_marker': partial,
        'completion_signature': signature,
      });
    }
    return payload;
  }

  // -------------------------------------------------------------------
  // Pesate
  // -------------------------------------------------------------------

  Future<void> _installMeasurements() async {
    final existing = await _existingMeasurementIds();
    for (final raw in _rawMeasurements) {
      final map = asMap(raw, 'export: pesata');
      final id = requireString(map, 'id', 'export: pesata');
      final what = 'export: pesata $id';
      _account('pesata', map, _measurementKeys);
      if (existing.contains(id)) {
        continue;
      }
      final measuredAt = _instant(requireString(map, 'date', what));
      final weightKg = optionalDouble(require(map, 'weightKg', what));
      if (weightKg == null) {
        throw FormatException('$what: manca il peso.');
      }
      final note = optionalString(require(map, 'notes', what));
      // `external_id` più la UNIQUE (profile_id, source, external_id) sono la
      // deduplica vera: se la stessa pesata fosse già entrata con un altro id
      // l'insert viene ignorato invece di fallire.
      final inserted = await database
          .into(database.bodyMeasurements)
          .insertReturningOrNull(
            BodyMeasurementsCompanion.insert(
              id: id,
              profileId: profileId,
              weightKg: weightKg,
              measuredAt: measuredAt,
              source: const Value('gym_tracker'),
              externalId: Value(id),
              note: Value(note),
              createdAt: dump.measurementCreatedAt[id] ?? measuredAt,
              updatedAt: _now,
            ),
            mode: InsertMode.insertOrIgnore,
          );
      if (inserted == null) {
        _warnings.add(
          'Pesata del ${_day(measuredAt)}: già presente con un altro id, non '
          'duplicata.',
        );
        continue;
      }
      _bodyMeasurements++;

      final custom = asMap(
        require(map, 'custom', what) ?? const <String, Object?>{},
        '$what: custom',
      );
      final values = <Map<String, Object?>>[];
      final labels = custom.keys.toList()..sort();
      for (final label in labels) {
        final value = optionalDouble(custom[label]);
        if (value == null || value <= 0) {
          continue;
        }
        final valueId = SyncIds.derived('body-measurement-value', '$id/$label');
        await database
            .into(database.bodyMeasurementValues)
            .insert(
              BodyMeasurementValuesCompanion.insert(
                id: valueId,
                measurementId: id,
                label: label,
                value: value,
              ),
            );
        _bodyMeasurementValues++;
        values.add({
          'id': valueId,
          'measurement_id': id,
          'label': label,
          'value': value,
        });
      }

      await _outbox(
        entityType: 'body_measurement',
        entityId: id,
        payload: {
          'id': id,
          'profile_id': profileId,
          'weight_kg': weightKg,
          'measured_at': measuredAt.toIso8601String(),
          'source': 'gym_tracker',
          'external_id': id,
          'note': note,
          'created_at': (dump.measurementCreatedAt[id] ?? measuredAt)
              .toIso8601String(),
          'updated_at': _now.toIso8601String(),
          'values': values,
        },
      );
    }
  }

  // -------------------------------------------------------------------
  // Utilità
  // -------------------------------------------------------------------

  Future<Set<String>> _existingExerciseIds() async {
    final table = database.exercises;
    final query = database.selectOnly(table)..addColumns([table.id]);
    return (await query.get()).map((row) => row.read(table.id)!).toSet();
  }

  Future<Set<String>> _existingRoutineIds() async {
    final table = database.routines;
    final query = database.selectOnly(table)..addColumns([table.id]);
    return (await query.get()).map((row) => row.read(table.id)!).toSet();
  }

  Future<Set<String>> _existingWorkoutIds() async {
    final table = database.workouts;
    final query = database.selectOnly(table)..addColumns([table.id]);
    return (await query.get()).map((row) => row.read(table.id)!).toSet();
  }

  Future<Set<String>> _existingMeasurementIds() async {
    final table = database.bodyMeasurements;
    final query = database.selectOnly(table)..addColumns([table.id]);
    return (await query.get()).map((row) => row.read(table.id)!).toSet();
  }

  Future<void> _outbox({
    required String entityType,
    required String entityId,
    required Map<String, Object?> payload,
  }) async {
    if (!enqueueSync) {
      return;
    }
    await database
        .into(database.syncOutbox)
        .insert(
          SyncOutboxCompanion.insert(
            id: uuid.v4(),
            entityType: entityType,
            entityId: entityId,
            operation: 'upsert',
            payloadJson: jsonEncode(payload),
            createdAt: _now,
          ),
        );
    _syncMutations++;
  }

  DateTime _instant(String raw) {
    final value = AppTime.parseInstant(raw);
    if (value.millisecond != 0 || value.microsecond != 0) {
      _lostSubSecond = true;
    }
    return value;
  }

  String _day(DateTime instant) {
    final local = AppTime.inRome(instant);
    final day = local.day.toString().padLeft(2, '0');
    final month = local.month.toString().padLeft(2, '0');
    return '$day/$month/${local.year}';
  }

  /// Conta le chiavi lette da un documento e mai mappate su una colonna.
  /// Si calcola dai dati veri invece che da un elenco scritto a mano, così un
  /// campo nuovo nella sorgente non passa inosservato.
  void _account(String kind, Map<String, Object?> map, Set<String> consumed) {
    for (final entry in map.entries) {
      if (consumed.contains(entry.key) || _isEmpty(entry.value)) {
        continue;
      }
      final key = '$kind.${entry.key}';
      _unmapped[key] = (_unmapped[key] ?? 0) + 1;
    }
  }

  List<String> _buildNotImported() {
    final lines = <String>[
      for (final entry in _unmapped.entries)
        '${entry.key}: ${entry.value} '
            '${entry.value == 1 ? 'documento lo ha' : 'documenti lo hanno'} '
            'valorizzato ma nessuna colonna lo accoglie',
    ]..sort();
    if (!dump.isPresent) {
      lines.add(
        'Prescrizioni per esercizio e blocchi a tempo delle schede: '
        'l\'esportatore di Gym non li scriveva, servono dal dump Firestore.',
      );
    }
    if (_lostSubSecond) {
      lines.add(
        'I decimi di secondo delle date: Drift salva i DateTime al secondo, '
        'quindi la firma temporale delle sessioni tracciate si arrotonda.',
      );
    }
    return lines;
  }

  static bool _isEmpty(Object? value) =>
      value == null ||
      (value is Iterable && value.isEmpty) ||
      (value is Map && value.isEmpty) ||
      (value is String && value.isEmpty);

  static const Set<String> _rootKeys = {
    'exportedAt',
    'app',
    'schemaVersion',
    'profile',
    'exercises',
    'routines',
    'workouts',
    'measurements',
  };

  static const Set<String> _exerciseKeys = {
    'id',
    'name',
    'muscleGroup',
    'trackingMode',
    'notes',
    'createdAt',
  };

  static const Set<String> _routineKeys = {
    'id',
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
  };

  static const Set<String> _warmupStepKeys = {'exerciseId', 'durationSec'};

  static const Set<String> _workoutKeys = {
    'id',
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
    'exercises',
  };

  static const Set<String> _workoutRowKeys = {
    'exerciseId',
    'exerciseName',
    'trackingMode',
    'restSeconds',
    'isWarmup',
    'isCooldown',
    'isFinisher',
    'isInSupersetWithPrevious',
    'sets',
  };

  static const Set<String> _setKeys = {
    'weightKg',
    'reps',
    'durationSec',
    'distanceM',
    'rpe',
    'isWarmup',
    'completed',
  };

  static const Set<String> _profileKeys = {
    'totalXp',
    'currentStreak',
    'longestStreak',
    'lastWorkoutDay',
    'unlockedAchievements',
    'bodyWeightKg',
    'weeklyWorkoutGoal',
    'weeklyKcalGoal',
    'reminderEnabled',
    'reminderHour',
    'reminderMinute',
    'healthConnectEnabled',
    'voiceEnabled',
    'weeklyPlan',
  };

  static const Set<String> _measurementKeys = {
    'id',
    'date',
    'weightKg',
    'custom',
    'notes',
  };
}
