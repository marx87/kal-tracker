import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';
import 'package:uuid/uuid.dart';

/// Lettura e scrittura del catalogo esercizi.
///
/// Due regole valgono per ogni query di catalogo, e stanno qui una volta sola:
/// le righe cancellate (`deleted_at`) non esistono, e le otto righe sintetiche
/// del defaticamento (`is_synthetic`) non sono esercizi di Marco — sono la
/// sequenza che l'app genera da sé, citata solo dallo storico.
class ExerciseRepository {
  ExerciseRepository(this._database, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final AppDatabase _database;
  final Uuid _uuid;

  /// Il catalogo, filtrato. Il testo cercato viene confrontato anche con
  /// l'etichetta del gruppo muscolare («Full body» non è mai scritto nella
  /// colonna, che contiene `fullbody`), quindi il filtro finale è in Dart.
  Stream<List<Exercise>> watchExercises(
    String profileId, {
    String search = '',
    MuscleGroup? muscleGroup,
    ExerciseOrigin origin = ExerciseOrigin.all,
  }) {
    final query = _database.select(_database.exercises)
      ..where((row) {
        var filter =
            row.profileId.equals(profileId) &
            row.deletedAt.isNull() &
            row.isSynthetic.equals(false);
        if (muscleGroup != null) {
          filter = filter & row.muscleGroup.equals(muscleGroup.name);
        }
        if (origin == ExerciseOrigin.base) {
          filter = filter & row.isPreset.equals(true);
        } else if (origin == ExerciseOrigin.mine) {
          filter = filter & row.isPreset.equals(false);
        }
        return filter;
      })
      ..orderBy([(row) => OrderingTerm.asc(row.name)]);

    final needle = search.trim().toLowerCase();
    return query.watch().map(
      (rows) => rows
          .map(_fromRow)
          .where((exercise) => _matches(exercise, needle))
          .toList(growable: false),
    );
  }

  bool _matches(Exercise exercise, String needle) {
    if (needle.isEmpty) {
      return true;
    }
    return exercise.name.toLowerCase().contains(needle) ||
        exercise.muscleGroup.label.toLowerCase().contains(needle) ||
        exercise.trackingMode.label.toLowerCase().contains(needle);
  }

  Future<Exercise?> getExercise(String id) async {
    final row =
        await (_database.select(
              _database.exercises,
            )..where((table) => table.id.equals(id) & table.deletedAt.isNull()))
            .getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  /// Gli esercizi citati da una scheda, in un colpo solo: serve all'editor,
  /// che deve mostrare nome, gruppo e modalità di ogni riga senza una query
  /// per riga.
  Future<Map<String, Exercise>> exercisesByIds(Iterable<String> ids) async {
    final wanted = ids.toSet();
    if (wanted.isEmpty) {
      return const {};
    }
    final rows =
        await (_database.select(_database.exercises)..where(
              (table) => table.id.isIn(wanted) & table.deletedAt.isNull(),
            ))
            .get();
    return {for (final row in rows) row.id: _fromRow(row)};
  }

  Future<Exercise> createExercise({
    required String profileId,
    required ExerciseDraft draft,
  }) async {
    final now = AppTime.nowUtc();
    final id = _uuid.v4();
    final name = draft.name.trim();
    final notes = _trimmedOrNull(draft.notes);
    final imageUrl = _trimmedOrNull(draft.imageUrl);

    await _database.transaction(() async {
      await _database
          .into(_database.exercises)
          .insert(
            ExercisesCompanion.insert(
              id: id,
              profileId: profileId,
              name: name,
              muscleGroup: draft.muscleGroup.name,
              trackingMode: draft.trackingMode.name,
              notes: Value(notes),
              imageUrl: Value(imageUrl),
              defaultRestSec: Value(draft.defaultRestSec),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await _appendOutbox(
        entityId: id,
        operation: 'upsert',
        payload: _payload(
          id: id,
          profileId: profileId,
          draft: draft.copyWith(name: name),
          isPreset: false,
          source: 'manual',
          externalId: null,
          createdAt: now,
          updatedAt: now,
        ),
        now: now,
      );
    });

    return Exercise(
      id: id,
      name: name,
      muscleGroup: draft.muscleGroup,
      trackingMode: draft.trackingMode,
      notes: notes,
      imageUrl: imageUrl,
      defaultRestSec: draft.defaultRestSec,
      isPreset: false,
      source: 'manual',
      createdAt: now,
    );
  }

  /// Aggiorna solo i campi che l'editor possiede. `source`, `external_id` e
  /// `is_preset` restano quelli della riga: dicono da dove arriva, e una
  /// modifica di Marco non trasforma un esercizio importato in uno suo.
  Future<void> updateExercise(String id, ExerciseDraft draft) async {
    final existing = await (_database.select(
      _database.exercises,
    )..where((row) => row.id.equals(id))).getSingleOrNull();
    if (existing == null) {
      return;
    }
    final now = AppTime.nowUtc();
    final name = draft.name.trim();
    final notes = _trimmedOrNull(draft.notes);
    final imageUrl = _trimmedOrNull(draft.imageUrl);

    await _database.transaction(() async {
      await (_database.update(
        _database.exercises,
      )..where((row) => row.id.equals(id))).write(
        ExercisesCompanion(
          name: Value(name),
          muscleGroup: Value(draft.muscleGroup.name),
          trackingMode: Value(draft.trackingMode.name),
          notes: Value(notes),
          imageUrl: Value(imageUrl),
          defaultRestSec: Value(draft.defaultRestSec),
          updatedAt: Value(now),
        ),
      );
      await _appendOutbox(
        entityId: id,
        operation: 'upsert',
        payload: _payload(
          id: id,
          profileId: existing.profileId,
          draft: draft.copyWith(name: name),
          isPreset: existing.isPreset,
          source: existing.source,
          externalId: existing.externalId,
          createdAt: existing.createdAt,
          updatedAt: now,
        ),
        now: now,
      );
    });
  }

  /// Cancellazione morbida: la riga resta perché le schede e lo storico la
  /// citano per id. Sparisce dal catalogo, non dal passato.
  Future<void> deleteExercise(String id) async {
    final now = AppTime.nowUtc();
    await _database.transaction(() async {
      await (_database.update(
        _database.exercises,
      )..where((row) => row.id.equals(id) & row.deletedAt.isNull())).write(
        ExercisesCompanion(deletedAt: Value(now), updatedAt: Value(now)),
      );
      await _appendOutbox(
        entityId: id,
        operation: 'delete',
        payload: {'id': id, 'deleted_at': now.toIso8601String()},
        now: now,
      );
    });
  }

  Exercise _fromRow(LocalExercise row) => Exercise(
    id: row.id,
    name: row.name,
    muscleGroup: MuscleGroup.fromStorage(row.muscleGroup),
    trackingMode: ExerciseTrackingMode.fromStorage(row.trackingMode),
    notes: row.notes,
    imageUrl: row.imageUrl,
    defaultRestSec: row.defaultRestSec,
    isPreset: row.isPreset,
    source: row.source,
    createdAt: row.createdAt,
  );

  Map<String, Object?> _payload({
    required String id,
    required String profileId,
    required ExerciseDraft draft,
    required bool isPreset,
    required String source,
    required String? externalId,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) => {
    'id': id,
    'profile_id': profileId,
    'name': draft.name,
    'muscle_group': draft.muscleGroup.name,
    'tracking_mode': draft.trackingMode.name,
    'notes': _trimmedOrNull(draft.notes),
    'image_url': _trimmedOrNull(draft.imageUrl),
    'default_rest_sec': draft.defaultRestSec,
    'is_preset': isPreset,
    // Un esercizio scritto da questa schermata non è mai una riga di
    // defaticamento: quelle le genera l'importatore e nessuno le modifica.
    'is_synthetic': false,
    'source': source,
    'external_id': externalId,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

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
          entityType: 'exercise',
          entityId: entityId,
          operation: operation,
          payloadJson: jsonEncode(payload),
          createdAt: now,
        ),
      );

  static String? _trimmedOrNull(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }
}
