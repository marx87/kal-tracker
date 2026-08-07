import 'dart:convert';

import 'package:drift/drift.dart';
// Le due righe generate da drift si chiamano `TrainingProfile` e
// `TrainingLimitation` esattamente come le entità di dominio (le tabelle non
// hanno un `@DataClassName`, e lo schema non si tocca). Nel corpo del file
// vince il dominio; la riga di drift, dove serve nominarla, arriva col
// prefisso `db`.
import 'package:kal_tracker/core/database/app_database.dart'
    hide TrainingLimitation, TrainingProfile;
import 'package:kal_tracker/core/database/app_database.dart'
    as db
    show TrainingLimitation;
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/training_profile/domain/training_profile.dart';
import 'package:uuid/uuid.dart';

/// Lettura e scrittura del profilo di allenamento e delle sue limitazioni.
///
/// Le due tabelle stanno insieme perché insieme rispondono a una sola
/// domanda — «cosa può fare Marco oggi» — e perché la riga di
/// `training_profiles` può mancare mentre le limitazioni ci sono già: quella
/// tabella pende da `app_profiles`, non dal profilo di allenamento. Chi legge
/// riceve comunque un [TrainingProfile], vuoto ma valido.
class TrainingProfileRepository {
  TrainingProfileRepository(this._database, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final AppDatabase _database;
  final Uuid _uuid;

  static const _profileEntity = 'training_profile';
  static const _limitationEntity = 'training_limitation';

  /// Il profilo con tutte le sue limitazioni, aperte e chiuse.
  Future<TrainingProfile> loadProfile(String profileId) async {
    final row = await (_database.select(
      _database.trainingProfiles,
    )..where((table) => table.profileId.equals(profileId))).getSingleOrNull();

    final limitationRows =
        await (_database.select(_database.trainingLimitations)
              ..where(
                (table) =>
                    table.profileId.equals(profileId) &
                    table.deletedAt.isNull(),
              )
              ..orderBy([(table) => OrderingTerm.desc(table.startedAt)]))
            .get();

    final limitations = <TrainingLimitation>[];
    var unreadable = 0;
    for (final limitation in limitationRows) {
      final bodyPart = BodyPart.fromStorage(limitation.bodyPart);
      final severity = LimitationSeverity.fromStorage(limitation.severity);
      if (bodyPart == null || severity == null) {
        // I CHECK del database rendono impossibile scriverla così: se arriva
        // è una zona (o una gravità) che questa versione dell'app non
        // conosce, portata dalla sincronizzazione. Non si indovina — si
        // conta, e chi mostra il profilo lo dichiara.
        unreadable++;
        continue;
      }
      limitations.add(
        TrainingLimitation(
          id: limitation.id,
          bodyPart: bodyPart,
          severity: severity,
          note: limitation.note,
          startedAt: limitation.startedAt,
          resolvedAt: limitation.resolvedAt,
        ),
      );
    }

    if (row == null) {
      return TrainingProfile(
        profileId: profileId,
        limitations: limitations,
        unreadableLimitations: unreadable,
      );
    }
    return TrainingProfile(
      profileId: profileId,
      equipment: Equipment.parse(row.equipment),
      sessionsPerWeek: row.sessionsPerWeek,
      minutesPerSession: row.minutesPerSession,
      preferredDays: TrainingDay.parse(row.preferredDays),
      deloadPreference: DeloadPreference.fromStorage(row.deloadPreference),
      limitations: limitations,
      unreadableLimitations: unreadable,
    );
  }

  /// Lo stesso profilo, che si aggiorna da solo.
  ///
  /// La query è costante di proposito: seguire una delle due tabelle
  /// lascerebbe fuori l'altra, e seguire la riga del profilo non funziona
  /// affatto finché quella riga non esiste. Quello che serve è la sorgente
  /// (`readsFrom`), non il risultato.
  Stream<TrainingProfile> watchProfile(String profileId) => _database
      .customSelect(
        'SELECT 1',
        readsFrom: {_database.trainingProfiles, _database.trainingLimitations},
      )
      .watch()
      .asyncMap((_) => loadProfile(profileId));

  /// Scrive attrezzatura e disponibilità. Le limitazioni non passano di qui:
  /// hanno una vita propria, con una data di inizio e una chiusura a mano.
  Future<void> saveProfile(TrainingProfile profile) async {
    _checkSessions(profile.sessionsPerWeek);
    _checkMinutes(profile.minutesPerSession);

    final equipment = Equipment.encode(profile.equipment);
    final days = TrainingDay.encode(profile.preferredDays);
    final now = AppTime.nowUtc();

    await _database.transaction(() async {
      final existing =
          await (_database.select(_database.trainingProfiles)
                ..where((table) => table.profileId.equals(profile.profileId)))
              .getSingleOrNull();
      // `created_at` è la data in cui Marco ha risposto la prima volta:
      // riscriverla a ogni salvataggio la cancellerebbe.
      final createdAt = existing?.createdAt ?? now;

      if (existing == null) {
        await _database
            .into(_database.trainingProfiles)
            .insert(
              TrainingProfilesCompanion.insert(
                profileId: profile.profileId,
                equipment: Value(equipment),
                sessionsPerWeek: Value(profile.sessionsPerWeek),
                minutesPerSession: Value(profile.minutesPerSession),
                preferredDays: Value(days),
                deloadPreference: Value(profile.deloadPreference.name),
                createdAt: createdAt,
                updatedAt: now,
              ),
            );
      } else {
        await (_database.update(
          _database.trainingProfiles,
        )..where((table) => table.profileId.equals(profile.profileId))).write(
          TrainingProfilesCompanion(
            equipment: Value(equipment),
            sessionsPerWeek: Value(profile.sessionsPerWeek),
            minutesPerSession: Value(profile.minutesPerSession),
            preferredDays: Value(days),
            deloadPreference: Value(profile.deloadPreference.name),
            updatedAt: Value(now),
          ),
        );
      }

      await _appendOutbox(
        entityType: _profileEntity,
        entityId: profile.profileId,
        operation: 'upsert',
        payload: {
          'profile_id': profile.profileId,
          'equipment': equipment,
          'sessions_per_week': profile.sessionsPerWeek,
          'minutes_per_session': profile.minutesPerSession,
          'preferred_days': days,
          'deload_preference': profile.deloadPreference.name,
          // `toUtc()` per lo stesso motivo delle limitazioni: quella che
          // torna da drift è ora locale.
          'created_at': createdAt.toUtc().toIso8601String(),
          'updated_at': now.toUtc().toIso8601String(),
        },
        now: now,
      );
    });
  }

  /// Apre una limitazione. Nasce senza [TrainingLimitation.resolvedAt], e ci
  /// resta finché non è Marco a chiuderla.
  Future<String> addLimitation({
    required String profileId,
    required BodyPart bodyPart,
    required LimitationSeverity severity,
    String? note,
    DateTime? startedAt,
  }) async {
    final cleanNote = _cleanNote(note);
    final id = _uuid.v4();
    final now = AppTime.nowUtc();
    final start = (startedAt ?? now).toUtc();

    await _database.transaction(() async {
      await _database
          .into(_database.trainingLimitations)
          .insert(
            TrainingLimitationsCompanion.insert(
              id: id,
              profileId: profileId,
              bodyPart: bodyPart.storage,
              severity: severity.name,
              note: Value(cleanNote),
              startedAt: start,
              createdAt: now,
              updatedAt: now,
            ),
          );
      await _appendOutbox(
        entityType: _limitationEntity,
        entityId: id,
        operation: 'upsert',
        payload: _limitationPayload(
          id: id,
          profileId: profileId,
          bodyPart: bodyPart,
          severity: severity,
          note: cleanNote,
          startedAt: start,
          resolvedAt: null,
          createdAt: now,
          updatedAt: now,
        ),
        now: now,
      );
    });
    return id;
  }

  /// Riscrive una limitazione aperta: la spalla che era un fastidio è
  /// diventata dolore, o la nota va precisata.
  ///
  /// [resolvedAt] non si tocca da qui — per chiuderla c'è
  /// [resolveLimitation], che è un gesto diverso e va chiesto per nome.
  Future<void> updateLimitation({
    required String id,
    required BodyPart bodyPart,
    required LimitationSeverity severity,
    String? note,
    DateTime? startedAt,
  }) async {
    final existing = await _limitationRow(id);
    if (existing == null) {
      throw StateError('Limitazione non trovata.');
    }
    final cleanNote = _cleanNote(note);
    final now = AppTime.nowUtc();
    final start = (startedAt ?? existing.startedAt).toUtc();

    await _database.transaction(() async {
      await (_database.update(
        _database.trainingLimitations,
      )..where((table) => table.id.equals(id))).write(
        TrainingLimitationsCompanion(
          bodyPart: Value(bodyPart.storage),
          severity: Value(severity.name),
          note: Value(cleanNote),
          startedAt: Value(start),
          updatedAt: Value(now),
        ),
      );
      await _appendOutbox(
        entityType: _limitationEntity,
        entityId: id,
        operation: 'upsert',
        payload: _limitationPayload(
          id: id,
          profileId: existing.profileId,
          bodyPart: bodyPart,
          severity: severity,
          note: cleanNote,
          startedAt: start,
          resolvedAt: existing.resolvedAt,
          createdAt: existing.createdAt,
          updatedAt: now,
        ),
        now: now,
      );
    });
  }

  /// La chiude. **Solo su richiesta**: nessun automatismo la fa scadere, e una
  /// limitazione chiusa smette di filtrare il catalogo ma resta nello storico
  /// a spiegare perché le schede di quel periodo erano quelle.
  Future<void> resolveLimitation(String id, {DateTime? resolvedAt}) async {
    final existing = await _limitationRow(id);
    if (existing == null) {
      throw StateError('Limitazione non trovata.');
    }
    if (existing.resolvedAt != null) {
      return;
    }
    final now = AppTime.nowUtc();
    final closedAt = (resolvedAt ?? now).toUtc();
    await _writeResolvedAt(existing, closedAt, now);
  }

  /// La riapre: la spalla è tornata a far male, ed è la stessa storia di
  /// prima, non una nuova.
  Future<void> reopenLimitation(String id) async {
    final existing = await _limitationRow(id);
    if (existing == null) {
      throw StateError('Limitazione non trovata.');
    }
    if (existing.resolvedAt == null) {
      return;
    }
    await _writeResolvedAt(existing, null, AppTime.nowUtc());
  }

  /// Cancellazione morbida, come nel resto dell'app: serve a togliere una
  /// riga sbagliata, non a dire che la limitazione è passata (per quello c'è
  /// [resolveLimitation]).
  Future<void> deleteLimitation(String id) async {
    final now = AppTime.nowUtc();
    await _database.transaction(() async {
      final changed =
          await (_database.update(_database.trainingLimitations)..where(
                (table) => table.id.equals(id) & table.deletedAt.isNull(),
              ))
              .write(
                TrainingLimitationsCompanion(
                  updatedAt: Value(now),
                  deletedAt: Value(now),
                ),
              );
      if (changed == 0) {
        return;
      }
      await _appendOutbox(
        entityType: _limitationEntity,
        entityId: id,
        operation: 'delete',
        payload: {'id': id, 'deleted_at': now.toIso8601String()},
        now: now,
      );
    });
  }

  Future<void> _writeResolvedAt(
    db.TrainingLimitation existing,
    DateTime? closedAt,
    DateTime now,
  ) async {
    final bodyPart = BodyPart.fromStorage(existing.bodyPart);
    final severity = LimitationSeverity.fromStorage(existing.severity);
    if (bodyPart == null || severity == null) {
      throw StateError('Limitazione scritta con valori sconosciuti.');
    }
    await _database.transaction(() async {
      await (_database.update(
        _database.trainingLimitations,
      )..where((table) => table.id.equals(existing.id))).write(
        TrainingLimitationsCompanion(
          resolvedAt: Value(closedAt),
          updatedAt: Value(now),
        ),
      );
      await _appendOutbox(
        entityType: _limitationEntity,
        entityId: existing.id,
        operation: 'upsert',
        payload: _limitationPayload(
          id: existing.id,
          profileId: existing.profileId,
          bodyPart: bodyPart,
          severity: severity,
          note: existing.note,
          startedAt: existing.startedAt,
          resolvedAt: closedAt,
          createdAt: existing.createdAt,
          updatedAt: now,
        ),
        now: now,
      );
    });
  }

  Future<db.TrainingLimitation?> _limitationRow(String id) =>
      (_database.select(_database.trainingLimitations)
            ..where((table) => table.id.equals(id) & table.deletedAt.isNull()))
          .getSingleOrNull();

  Map<String, Object?> _limitationPayload({
    required String id,
    required String profileId,
    required BodyPart bodyPart,
    required LimitationSeverity severity,
    required String? note,
    required DateTime startedAt,
    required DateTime? resolvedAt,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) => {
    'id': id,
    'profile_id': profileId,
    'body_part': bodyPart.storage,
    'severity': severity.name,
    'note': note,
    // Sempre `toUtc()` prima di scrivere: le date che tornano da drift sono
    // ora locale, e un ISO senza fuso in coda di sincronizzazione è un
    // istante che cambia significato a seconda di chi lo rilegge.
    'started_at': startedAt.toUtc().toIso8601String(),
    'resolved_at': resolvedAt?.toUtc().toIso8601String(),
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  Future<void> _appendOutbox({
    required String entityType,
    required String entityId,
    required String operation,
    required Map<String, Object?> payload,
    required DateTime now,
  }) => _database
      .into(_database.syncOutbox)
      .insert(
        SyncOutboxCompanion.insert(
          id: _uuid.v4(),
          entityType: entityType,
          entityId: entityId,
          operation: operation,
          payloadJson: jsonEncode(payload),
          createdAt: now,
        ),
      );

  /// Gli stessi limiti dei CHECK, ma con una frase leggibile: il CHECK
  /// protegge il database, questo protegge Marco dal messaggio di errore di
  /// SQLite.
  static void _checkSessions(int? value) {
    if (value == null) {
      return;
    }
    if (value < 1 || value > 14) {
      throw const FormatException(
        'Le sessioni a settimana devono stare fra 1 e 14.',
      );
    }
  }

  static void _checkMinutes(int? value) {
    if (value == null) {
      return;
    }
    if (value < 10 || value > 300) {
      throw const FormatException(
        'La durata di una sessione deve stare fra 10 e 300 minuti.',
      );
    }
  }

  static String? _cleanNote(String? note) {
    final clean = note?.trim();
    if (clean == null || clean.isEmpty) {
      return null;
    }
    if (clean.length > 300) {
      throw const FormatException('La nota è troppo lunga.');
    }
    return clean;
  }
}
