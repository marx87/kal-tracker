import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/goal/domain/definition_level.dart';
import 'package:kal_tracker/features/goal/domain/goal.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Persistenza dell'Obiettivo.
///
/// L'interfaccia è rimasta quella di sempre — leggi tutto, scrivi tutto — e a
/// cambiare è stata solo l'implementazione: dalla v7 l'obiettivo e il suo
/// storico vivono nella tabella `goals`, non più in un file JSON.
///
/// Il patto con chi chiama non cambia: letture indulgenti, scritture best
/// effort, mai un crash. Un obiettivo perso è un fastidio, un'app che non si
/// apre è un disastro.
abstract class GoalStore {
  Future<GoalHistory> read();
  Future<void> write(GoalHistory history);
}

/// L'Obiettivo su Drift.
///
/// **L'elezione dell'obiettivo corrente avviene in lettura**, non con un
/// vincolo del database. Due dispositivi offline che fissano un traguardo
/// ciascuno producono due righe aperte, e un indice unico bloccherebbe la
/// sincronizzazione invece di risolvere: qui vince il più recente per
/// `startedAt` e gli altri si leggono come archiviati, con l'esito «cambiato
/// in corsa». La prima scrittura successiva mette per iscritto quella stessa
/// decisione.
class DriftGoalStore implements GoalStore {
  DriftGoalStore(
    this._database, {
    FileGoalStore? legacy,
    Future<String> Function()? profileId,
  }) : _legacy = legacy ?? FileGoalStore() {
    _resolveProfileId = profileId ?? _marcoProfileId;
  }

  /// Quanti obiettivi chiusi si mostrano. È lo stesso numero di
  /// `GoalRepository.maxHistoryEntries`, ripetuto qui per non far dipendere la
  /// persistenza dal repository che la usa. È la finestra della VISTA, non un
  /// limite dell'archivio: le righe più vecchie restano nella tabella e
  /// nessuna scrittura le tocca, altrimenti la potatura dello storico
  /// diventerebbe una cancellazione vera.
  static const int historyWindow = 20;

  final AppDatabase _database;
  final FileGoalStore _legacy;
  late final Future<String> Function() _resolveProfileId;

  Future<void>? _legacyImport;

  @override
  Future<GoalHistory> read() async {
    final profileId = await _resolveProfileId();
    await _importLegacyOnce(profileId);
    return (await _readWindow(profileId)).history;
  }

  @override
  Future<void> write(GoalHistory history) async {
    final profileId = await _resolveProfileId();
    await _importLegacyOnce(profileId);

    final goals = <Goal>[
      ?history.current,
      ...history.past,
    ].where(_isPersistable).toList(growable: false);
    if (goals.isEmpty && history.current == null && history.past.isEmpty) {
      // Niente da scrivere e niente da archiviare: uno storico vuoto non
      // autorizza a svuotare la tabella.
      return;
    }

    try {
      await _database.transaction(() async {
        final window = await _readWindow(profileId);
        final keep = {for (final goal in goals) goal.id};
        // Il pavimento: le righe più vecchie del traguardo più vecchio ancora
        // in elenco sono quelle che la potatura ha dimenticato, non quelle che
        // qualcuno ha tolto. Non si toccano.
        final floor = goals.isEmpty
            ? null
            : goals
                  .map((goal) => goal.startedAt.toUtc())
                  .reduce((a, b) => a.isBefore(b) ? a : b);

        for (final row in window.rows) {
          if (keep.contains(row.id) || floor == null) {
            continue;
          }
          if (row.startedAt.toUtc().isBefore(floor)) {
            continue;
          }
          final deletedAt = _now();
          await (_database.update(
            _database.goals,
          )..where((table) => table.id.equals(row.id))).write(
            GoalsCompanion(
              updatedAt: Value(deletedAt),
              deletedAt: Value(deletedAt),
            ),
          );
          await _appendOutbox(
            entityId: row.id,
            operation: 'delete',
            payload: {
              'id': row.id,
              'profile_id': profileId,
              'deleted_at': deletedAt.toIso8601String(),
              'updated_at': deletedAt.toIso8601String(),
            },
            now: deletedAt,
          );
        }

        for (final goal in goals) {
          await _upsert(profileId: profileId, goal: goal);
        }
      });
    } on Object {
      // Stesso patto del file: lo stato in memoria resta coerente per la
      // sessione e la schermata non muore in mano a Marco.
      return;
    }
  }

  Future<({GoalHistory history, List<LocalGoal> rows})> _readWindow(
    String profileId,
  ) async {
    final rows =
        await (_database.select(_database.goals)..where(
              (row) => row.profileId.equals(profileId) & row.deletedAt.isNull(),
            ))
            .get();

    final open = rows.where((row) => row.closedAt == null).toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    final closed = rows.where((row) => row.closedAt != null).toList()
      ..sort((a, b) => b.closedAt!.compareTo(a.closedAt!));

    final current = open.isEmpty ? null : _toDomain(open.first);
    // Gli altri aperti sono il residuo di due dispositivi che hanno deciso
    // insieme: si leggono come archiviati alla nascita di quello che ha vinto.
    final contested = [
      for (final row in open.skip(1))
        _toDomain(row).copyWith(
          closedAt: current?.startedAt ?? row.startedAt.toUtc(),
          outcome: GoalOutcome.replaced,
        ),
    ];
    final past =
        [
            ...contested,
            ...closed.map(_toDomain),
          ].where((goal) => goal.closedAt != null).toList()
          ..sort((a, b) => b.closedAt!.compareTo(a.closedAt!));

    final visible = past.take(historyWindow).toList(growable: false);
    final visibleIds = {
      if (current != null) current.id,
      for (final goal in visible) goal.id,
    };

    return (
      history: GoalHistory(current: current, past: visible),
      // Solo le righe che il log può nominare: le altre sono fuori finestra e
      // nessuna scrittura deve poterle tombstonare.
      rows: rows
          .where((row) => visibleIds.contains(row.id))
          .toList(growable: false),
    );
  }

  Future<void> _upsert({required String profileId, required Goal goal}) async {
    final now = _now();
    await _database
        .into(_database.goals)
        .insert(
          GoalsCompanion.insert(
            id: goal.id,
            profileId: profileId,
            targetWeightKg: goal.targetWeightKg,
            targetLevel: goal.targetLevel.name,
            paceKgPerWeek: goal.paceKgPerWeek,
            startedAt: goal.startedAt.toUtc(),
            startWeightKg: goal.startWeightKg,
            startFatFreeMassKg: goal.startFatFreeMassKg,
            createdAt: now,
            updatedAt: now,
            phase: Value(goal.phase.name),
            phaseStartedAt: Value(goal.phaseStartedAt?.toUtc()),
            closedAt: Value(goal.closedAt?.toUtc()),
            outcome: Value(goal.outcome?.name),
          ),
          onConflict: DoUpdate(
            (_) => GoalsCompanion(
              targetWeightKg: Value(goal.targetWeightKg),
              targetLevel: Value(goal.targetLevel.name),
              paceKgPerWeek: Value(goal.paceKgPerWeek),
              startedAt: Value(goal.startedAt.toUtc()),
              startWeightKg: Value(goal.startWeightKg),
              startFatFreeMassKg: Value(goal.startFatFreeMassKg),
              phase: Value(goal.phase.name),
              phaseStartedAt: Value(goal.phaseStartedAt?.toUtc()),
              closedAt: Value(goal.closedAt?.toUtc()),
              outcome: Value(goal.outcome?.name),
              updatedAt: Value(now),
              // Rimettere in corsa un obiettivo archiviato è l'«Annulla»
              // della schermata: la riga torna viva.
              deletedAt: const Value(null),
            ),
          ),
        );
    await _appendOutbox(
      entityId: goal.id,
      operation: 'upsert',
      payload: {
        'id': goal.id,
        'profile_id': profileId,
        'target_weight_kg': goal.targetWeightKg,
        'target_level': goal.targetLevel.name,
        'pace_kg_per_week': goal.paceKgPerWeek,
        'started_at': goal.startedAt.toUtc().toIso8601String(),
        'start_weight_kg': goal.startWeightKg,
        'start_fat_free_mass_kg': goal.startFatFreeMassKg,
        'phase': goal.phase.name,
        'phase_started_at': goal.phaseStartedAt?.toUtc().toIso8601String(),
        'closed_at': goal.closedAt?.toUtc().toIso8601String(),
        'outcome': goal.outcome?.name,
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
        'deleted_at': null,
      },
      now: now,
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
          id: const Uuid().v4(),
          entityType: 'goal',
          entityId: entityId,
          operation: operation,
          payloadJson: jsonEncode(payload),
          createdAt: now,
        ),
      );

  /// Porta dentro il file JSON delle versioni precedenti e poi lo archivia.
  ///
  /// L'import è additivo: quello che c'è già nella tabella vince. Un obiettivo
  /// che non soddisfa i vincoli — pesi a zero di un file troncato — viene
  /// saltato invece di far fallire tutta la migrazione; il file resta lì,
  /// rinominato, e nessun dato sparisce davvero.
  Future<void> _importLegacyOnce(String profileId) =>
      _legacyImport ??= _importLegacy(profileId);

  Future<void> _importLegacy(String profileId) async {
    try {
      if (!await _legacy.exists()) {
        return;
      }
      final history = await _legacy.read();
      final goals = <Goal>[
        ?history.current,
        ...history.past,
      ].where(_isPersistable).toList(growable: false);
      if (goals.isNotEmpty) {
        await _database.transaction(() async {
          for (final goal in goals) {
            final existing = await (_database.select(
              _database.goals,
            )..where((row) => row.id.equals(goal.id))).getSingleOrNull();
            if (existing != null) {
              continue;
            }
            // Il JSON legacy entra in Drift una volta sola, ma da qui deve
            // viaggiare come ogni obiettivo creato nella UI.
            await _upsert(profileId: profileId, goal: goal);
          }
        });
      }
      await _legacy.archive();
    } on Object {
      return;
    }
  }

  /// I vincoli della tabella, ripetuti in Dart per poterli far rispettare
  /// scartando invece di esplodere. Un file JSON troncato produce obiettivi
  /// con pesi a zero: non sono traguardi, sono rumore.
  bool _isPersistable(Goal goal) {
    final started = goal.startedAt.toUtc();
    final closed = goal.closedAt?.toUtc();
    final phaseStarted = goal.phaseStartedAt?.toUtc();
    return goal.id.isNotEmpty &&
        goal.targetWeightKg >= 20 &&
        goal.targetWeightKg <= 500 &&
        goal.startWeightKg >= 20 &&
        goal.startWeightKg <= 500 &&
        goal.startFatFreeMassKg > 0 &&
        goal.startFatFreeMassKg <= 500 &&
        goal.paceKgPerWeek > 0 &&
        goal.paceKgPerWeek <= 5 &&
        (goal.outcome == null || closed != null) &&
        (closed == null || !closed.isBefore(started)) &&
        (phaseStarted == null || !phaseStarted.isBefore(started));
  }

  Goal _toDomain(LocalGoal row) => Goal(
    id: row.id,
    targetWeightKg: row.targetWeightKg,
    targetLevel:
        DefinitionLevel.fromStorage(row.targetLevel) ?? DefinitionLevel.normal,
    paceKgPerWeek: row.paceKgPerWeek,
    startedAt: row.startedAt.toUtc(),
    startWeightKg: row.startWeightKg,
    startFatFreeMassKg: row.startFatFreeMassKg,
    phase: GoalPhase.fromStorage(row.phase),
    phaseStartedAt: row.phaseStartedAt?.toUtc(),
    closedAt: row.closedAt?.toUtc(),
    outcome: GoalOutcome.fromStorage(row.outcome),
  );

  DateTime _now() => AppTime.nowUtc();

  Future<String> _marcoProfileId() async =>
      (await LocalProfileRepository(_database).getOrCreateMarco()).id;
}

/// Il file JSON delle versioni fino alla v6.
///
/// Non è più la persistenza dell'Obiettivo: resta come sorgente della
/// migrazione una-tantum e come store di riserva per un ambiente senza
/// database.
class FileGoalStore implements GoalStore {
  FileGoalStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  static const String fileName = 'kal-tracker-goal.json';

  /// Il nome che il file prende dopo essere entrato in Drift: rinominare è
  /// reversibile, cancellare no.
  static const String archivedFileName = 'kal-tracker-goal.json.migrated';

  final Future<Directory> Function() _directory;

  @override
  Future<GoalHistory> read() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return const GoalHistory.empty();
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        return const GoalHistory.empty();
      }
      return GoalHistory.fromJson(decoded);
    } on Object {
      return const GoalHistory.empty();
    }
  }

  @override
  Future<void> write(GoalHistory history) async {
    try {
      final file = await _file();
      await file.writeAsString(jsonEncode(history.toJson()), flush: true);
    } on Object {
      // Lo stato in memoria resta coerente per la sessione.
      return;
    }
  }

  Future<bool> exists() async {
    try {
      return (await _file()).existsSync();
    } on Object {
      return false;
    }
  }

  Future<void> archive() async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        return;
      }
      final directory = await _directory();
      await file.rename('${directory.path}/$archivedFileName');
    } on Object {
      return;
    }
  }

  Future<File> _file() async {
    final directory = await _directory();
    return File('${directory.path}/$fileName');
  }
}

/// Store in memoria: serve ai test e alla prima esecuzione in un ambiente
/// senza filesystem (i widget test non hanno `path_provider`).
class InMemoryGoalStore implements GoalStore {
  InMemoryGoalStore([this._history = const GoalHistory.empty()]);

  GoalHistory _history;

  @override
  Future<GoalHistory> read() async => _history;

  @override
  Future<void> write(GoalHistory history) async => _history = history;
}
