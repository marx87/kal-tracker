import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

/// Utente Supabase autenticato.
class SyncAccount {
  const SyncAccount({required this.userId, required this.email});

  final String userId;
  final String email;
}

/// Una riga di SyncOutbox pronta per il server: l'id della riga di outbox
/// è il mutation id (i retry diventano no-op grazie al ledger remoto).
class SyncMutation {
  const SyncMutation({
    required this.mutationId,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.payload,
  });

  final String mutationId;
  final String entityType;
  final String entityId;
  final String operation;
  final Map<String, Object?> payload;
}

/// Una riga del change feed `sync_changes` (entity_type al plurale remoto).
class RemoteChange {
  const RemoteChange({
    required this.changeId,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.payload,
  });

  final int changeId;
  final String entityType;
  final String entityId;
  final String operation;
  final Map<String, Object?> payload;
}

class SyncGatewayException implements Exception {
  const SyncGatewayException(
    this.message, {
    this.retryable = false,
    this.authRequired = false,
  });

  final String message;
  final bool retryable;
  final bool authRequired;

  @override
  String toString() => message;
}

/// Derivazioni deterministiche di id e mutation id: a parità di input
/// l'output è identico, quindi ogni retry riusa gli stessi uuid.
abstract final class SyncIds {
  static final _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static bool isUuid(String value) => _uuidPattern.hasMatch(value);

  static String derived(String base, String salt) => const Uuid().v5(
    Namespace.url.value,
    'https://kal-tracker.local/sync/$base/$salt',
  );

  /// Id remoto per un id locale: gli uuid passano invariati, gli id non-uuid
  /// (es. alimenti seed) diventano uuid v5 stabili.
  static String remoteId(String localId) =>
      isUuid(localId) ? localId.toLowerCase() : derived('id', localId);

  static String nutritionTargetId(String remoteProfileId) =>
      derived('nutrition-target', remoteProfileId);
}

/// Decide se una mutation respinta resta in coda o viene scartata. È l'unico
/// punto dove si prende quella decisione, ed è asimmetrica: scartare è
/// irreversibile (la riga di outbox sparisce e nessuno la rigenera), aspettare
/// costa solo tempo.
abstract final class SyncRetryPolicy {
  /// Il server non ha nemmeno guardato la riga: sovraccarico o trasporto.
  static const transientCodes = {
    '408',
    '425',
    '429',
    '500',
    '502',
    '503',
    '504',
  };

  /// Violazioni di integrità, e NON sono rifiuti definitivi: 23503 dice che la
  /// riga a cui si collega non è ancora arrivata (i figli di un allenamento
  /// viaggiano dopo il catalogo esercizi), 23505 che la scrittura si è
  /// incrociata con un'altra. Scartarle farebbe sparire dal server un intero
  /// allenamento con i suoi figli, segnalato solo da un messaggio generico.
  static const integrityCodes = {'23503', '23505'};

  static bool isRetryable(String? postgresCode) =>
      transientCodes.contains(postgresCode) ||
      integrityCodes.contains(postgresCode);
}

sealed class RemoteOp {
  const RemoteOp();
}

/// Insert/upsert PostgREST (`Prefer: resolution=merge-duplicates` sul PK).
class RemoteUpsert extends RemoteOp {
  const RemoteUpsert(this.table, this.rows);

  final String table;
  final List<Map<String, Object?>> rows;
}

/// PATCH per id: 0 righe aggiornate non è un errore (riga mai arrivata
/// sul server, oppure retry già assorbito dal ledger delle mutation).
class RemotePatch extends RemoteOp {
  const RemotePatch(this.table, this.id, this.values);

  final String table;
  final String id;
  final Map<String, Object?> values;
}

/// Sostituzione completa delle righe figlie: prima si tombstonano le righe
/// vive (la UNIQUE parziale su (template_id, position) lo impone), poi si
/// inseriscono le nuove con `deleted_at` nullo.
class RemoteChildrenSwap extends RemoteOp {
  const RemoteChildrenSwap({
    required this.table,
    required this.parentColumn,
    required this.parentId,
    required this.rows,
    required this.tombstoneMutationIdFor,
    required this.tombstoneAt,
  });

  final String table;
  final String parentColumn;
  final String parentId;
  final List<Map<String, Object?>> rows;
  final String Function(String remoteRowId) tombstoneMutationIdFor;
  final String tombstoneAt;

  /// Righe vive da tombstonare: mai quelle della generazione corrente.
  /// Dopo una risposta persa il retry rivede come "vive" le righe appena
  /// inserite: tombstonarle le azzererebbe per sempre, perché la
  /// re-upsert successiva è assorbita dal ledger delle mutation.
  List<String> tombstoneTargets(Iterable<String> liveRowIds) {
    final currentIds = {for (final row in rows) row['id']};
    return [
      for (final id in liveRowIds)
        if (!currentIds.contains(id)) id,
    ];
  }
}

class MappedMutation {
  const MappedMutation({this.ops = const [], this.profileLocalId});

  /// Entità che sul server non esiste per scelta (i preferiti locali). È il
  /// solo caso in cui zero op sono un successo: un entityType SCONOSCIUTO
  /// deve invece far fallire il push, o il motore cancellerebbe la riga di
  /// outbox contandola come inviata.
  const MappedMutation.localOnly() : ops = const [], profileLocalId = null;

  final List<RemoteOp> ops;

  /// Profilo locale citato dalla mutation: il gateway garantisce che la
  /// riga `profiles` remota esista prima di eseguire gli op.
  final String? profileLocalId;
}

/// Traduzione pura outbox locale -> contratto remoto (tabella `kal_tracker`).
/// Accetta sia i payload dei repository sia quelli del ripristino backup.
///
/// I payload degli allenamenti usano i NOMI DELLE COLONNE REMOTE della
/// migrazione 0007, così la traduzione è una copia e non un dizionario da
/// tenere allineato a mano. I figli viaggiano annidati nel payload del padre,
/// come per `fit_recipe`:
/// • `routine` → `exercises[]` e `interval_segments[]`;
/// • `workout` → `exercises[]`, ognuno con i suoi `sets[]`, più
///   `pain_points[]` e `interval_segments[]`;
/// • `workout_profile_stats` → `achievements[]` e `weekly_plan[]`;
/// • `body_measurement` → `values[]` (le circonferenze).
///
/// La CHIAVE ASSENTE e la lista vuota vogliono dire cose diverse: assente è
/// «questa scrittura non parla dei figli» e li lascia stare, `[]` è «di figli
/// non ce ne sono più» e li tombstona. Chi accoda un aggiornamento parziale
/// (chiudere una sessione, salvare il feedback) deve quindi OMETTERE le
/// chiavi dei figli, non mandarle vuote.
abstract final class SyncPushMapper {
  static const timeZone = 'Europe/Rome';

  static MappedMutation map(SyncMutation mutation) {
    switch (mutation.entityType) {
      case 'meal_item':
        return _mealItem(mutation);
      case 'nutrition_target':
        return _nutritionTarget(mutation);
      case 'water_log':
        return _waterLog(mutation);
      case 'body_measurement':
        return _bodyMeasurement(mutation);
      case 'food':
        return _food(mutation);
      case 'food_preference':
        // Nessuna tabella remota: il preferito locale resta solo sul device.
        return const MappedMutation.localOnly();
      case 'fit_recipe':
        return _recipe(mutation);
      case 'meal_template':
        return _template(mutation);
      case 'exercise':
        return _exercise(mutation);
      case 'routine':
        return _routine(mutation);
      case 'workout':
        return _workout(mutation);
      case 'workout_profile_stats':
        return _workoutProfileStats(mutation);
      default:
        // Un tipo sconosciuto NON può diventare una mappatura vuota: senza op
        // da eseguire `pushMutation` riuscirebbe e il motore cancellerebbe la
        // riga di outbox contandola come inviata, perdendo il dato per sempre
        // (l'importer al secondo lancio è un no-op e non la rigenera).
        // Retryable perché il rimedio è un aggiornamento dell'app, non la
        // rinuncia alla riga.
        throw SyncGatewayException(
          'Questa versione dell’app non sa inviare '
          '«${mutation.entityType}»: aggiornala per completare la '
          'sincronizzazione.',
          retryable: true,
        );
    }
  }

  static MappedMutation _mealItem(SyncMutation mutation) {
    final p = mutation.payload;
    final itemId = SyncIds.remoteId(mutation.entityId);
    if (mutation.operation == 'delete') {
      return MappedMutation(
        ops: [
          RemotePatch('meal_items', itemId, {
            'deleted_at': _string(p['deleted_at']) ?? _nowIso(),
            'last_mutation_id': mutation.mutationId,
          }),
        ],
      );
    }
    final mealLocalId = _string(p['meal_id']);
    final updatedAt = _string(p['updated_at']) ?? _nowIso();
    final eatenAt = _string(p['eaten_at']) ?? updatedAt;
    final grams = _positive(_double(p['grams']), fallback: 1);
    final ops = <RemoteOp>[];
    if (mealLocalId != null) {
      final mealId = SyncIds.remoteId(mealLocalId);
      ops.add(
        RemoteUpsert('meals', [
          {
            'id': mealId,
            'profile_id': SyncIds.remoteId(_string(p['profile_id']) ?? ''),
            'eaten_at': eatenAt,
            'local_date': _localDate(eatenAt),
            'time_zone': timeZone,
            'meal_type': _mealType(_string(p['meal_type'])),
            'entry_source': 'manual',
            'status': 'confirmed',
            'updated_at': updatedAt,
            'deleted_at': null,
            'last_mutation_id': SyncIds.derived(mutation.mutationId, 'meal'),
          },
        ]),
      );
      ops.add(
        RemoteUpsert('meal_items', [
          {
            'id': itemId,
            'meal_id': mealId,
            'position': 0,
            'quantity_value': grams,
            'quantity_unit': 'g',
            'quantity_g': grams,
            'food_name_snapshot': _text(p['food_name'], max: 160) ?? 'Alimento',
            'food_source_snapshot': _string(p['source']) ?? 'manual',
            // I totali sono colonne GENERATED sul server: non si inviano.
            'energy_kcal_per_100g': _double(p['calories_per_100g']),
            'protein_g_per_100g': _double(p['protein_per_100g']),
            'carbohydrate_g_per_100g': _double(p['carbs_per_100g']),
            'fat_g_per_100g': _double(p['fat_per_100g']),
            'fiber_g_per_100g': 0,
            'updated_at': updatedAt,
            'deleted_at': _string(p['deleted_at']),
            'last_mutation_id': mutation.mutationId,
          },
        ]),
      );
    }
    return MappedMutation(ops: ops, profileLocalId: _string(p['profile_id']));
  }

  static MappedMutation _nutritionTarget(SyncMutation mutation) {
    final p = mutation.payload;
    final profileLocalId = _string(p['profile_id']) ?? mutation.entityId;
    final remoteProfileId = SyncIds.remoteId(profileLocalId);
    final targetId = SyncIds.nutritionTargetId(remoteProfileId);
    if (mutation.operation == 'delete') {
      return MappedMutation(
        ops: [
          RemotePatch('nutrition_targets', targetId, {
            'deleted_at': _string(p['deleted_at']) ?? _nowIso(),
            'last_mutation_id': mutation.mutationId,
          }),
        ],
        profileLocalId: profileLocalId,
      );
    }
    return MappedMutation(
      ops: [
        RemoteUpsert('nutrition_targets', [
          {
            'id': targetId,
            'profile_id': remoteProfileId,
            // La chiave locale è il profilo: lato server la storicizzazione
            // per data collassa su un'unica riga "da sempre".
            'effective_from': '1970-01-01',
            'goal_type': 'maintain',
            'energy_kcal': _positive(_double(p['daily_calories']), fallback: 1),
            'protein_g': _double(p['daily_protein']),
            'carbohydrate_g': _double(p['daily_carbs']),
            'fat_g': _double(p['daily_fat']),
            'fiber_g': 0,
            'updated_at': _string(p['updated_at']) ?? _nowIso(),
            'deleted_at': _string(p['deleted_at']),
            'last_mutation_id': mutation.mutationId,
          },
        ]),
      ],
      profileLocalId: profileLocalId,
    );
  }

  static MappedMutation _waterLog(SyncMutation mutation) {
    final p = mutation.payload;
    final id = SyncIds.remoteId(mutation.entityId);
    if (mutation.operation == 'delete') {
      return MappedMutation(
        ops: [
          RemotePatch('water_logs', id, {
            'deleted_at': _string(p['deleted_at']) ?? _nowIso(),
            'last_mutation_id': mutation.mutationId,
          }),
        ],
      );
    }
    final updatedAt = _string(p['updated_at']) ?? _nowIso();
    final loggedAt = _string(p['logged_at']) ?? updatedAt;
    return MappedMutation(
      ops: [
        RemoteUpsert('water_logs', [
          {
            'id': id,
            'profile_id': SyncIds.remoteId(_string(p['profile_id']) ?? ''),
            'milliliters': _int(p['milliliters']).clamp(1, 10000),
            'logged_at': loggedAt,
            'local_date': _localDate(loggedAt),
            'updated_at': updatedAt,
            'deleted_at': _string(p['deleted_at']),
            'last_mutation_id': mutation.mutationId,
          },
        ]),
      ],
      profileLocalId: _string(p['profile_id']),
    );
  }

  static MappedMutation _bodyMeasurement(SyncMutation mutation) {
    final p = mutation.payload;
    final id = SyncIds.remoteId(mutation.entityId);
    if (mutation.operation == 'delete') {
      return MappedMutation(
        ops: [
          RemotePatch('body_measurements', id, {
            'deleted_at': _string(p['deleted_at']) ?? _nowIso(),
            'last_mutation_id': mutation.mutationId,
          }),
        ],
      );
    }
    final updatedAt = _string(p['updated_at']) ?? _nowIso();
    final values = _children(p['values']);
    return MappedMutation(
      ops: [
        RemoteUpsert('body_measurements', [
          {
            'id': id,
            'profile_id': SyncIds.remoteId(_string(p['profile_id']) ?? ''),
            'weight_kg': _double(p['weight_kg']).clamp(20, 500),
            'measured_at': _string(p['measured_at']) ?? updatedAt,
            'note': _text(p['note'], max: 240),
            // La sorgente NON si forza: è metà della unique
            // (owner, source, external_id) che deduplica le importazioni.
            // Scrivere 'kal_tracker' su una pesata di Gym la renderebbe
            // reimportabile all'infinito.
            'source': _enum(p['source'], _measurementSources, 'kal_tracker'),
            'external_id': _text(p['external_id'], max: 120),
            'updated_at': updatedAt,
            'deleted_at': _string(p['deleted_at']),
            'last_mutation_id': mutation.mutationId,
          },
        ]),
        // Chiave assente = «questa scrittura non parla di circonferenze»:
        // uno swap incondizionato le tombstonerebbe a ogni pesata modificata.
        if (p.containsKey('values'))
          RemoteChildrenSwap(
            table: 'body_measurement_values',
            parentColumn: 'measurement_id',
            parentId: id,
            rows: [
              for (final (index, value) in values.indexed)
                {
                  'id': _childId(
                    value['id'],
                    mutation.mutationId,
                    'value',
                    index,
                  ),
                  'measurement_id': id,
                  'label': _text(value['label'], max: 40) ?? 'Misura',
                  'value': _double(value['value']),
                  'deleted_at': null,
                  'last_mutation_id': SyncIds.derived(
                    mutation.mutationId,
                    'measurement-value:$index',
                  ),
                },
            ],
            tombstoneMutationIdFor: (remoteRowId) => SyncIds.derived(
              mutation.mutationId,
              'measurement-value-tomb:$remoteRowId',
            ),
            tombstoneAt: updatedAt,
          ),
      ],
      profileLocalId: _string(p['profile_id']),
    );
  }

  static MappedMutation _food(SyncMutation mutation) {
    final p = mutation.payload;
    final id = SyncIds.remoteId(mutation.entityId);
    if (mutation.operation == 'delete') {
      return MappedMutation(
        ops: [
          RemotePatch('foods', id, {
            'deleted_at': _string(p['deleted_at']) ?? _nowIso(),
            'last_mutation_id': mutation.mutationId,
          }),
        ],
      );
    }
    return MappedMutation(
      ops: [
        RemoteUpsert('foods', [
          {
            'id': id,
            'name': _text(p['name'], max: 160) ?? 'Alimento',
            'brand': _text(p['brand'], max: 120),
            'barcode': _text(p['barcode'], max: 32),
            'source': 'personal',
            'energy_kcal_per_100g': _double(p['calories_per_100g']),
            'protein_g_per_100g': _double(p['protein_per_100g']),
            'carbohydrate_g_per_100g': _double(p['carbs_per_100g']),
            'fat_g_per_100g': _double(p['fat_per_100g']),
            'fiber_g_per_100g': 0,
            'serving_size_g': _positive(
              _double(p['default_serving_grams']),
              fallback: 100,
            ),
            'updated_at': _string(p['updated_at']) ?? _nowIso(),
            'deleted_at': _string(p['deleted_at']),
            'last_mutation_id': mutation.mutationId,
          },
        ]),
      ],
    );
  }

  static MappedMutation _recipe(SyncMutation mutation) {
    final p = mutation.payload;
    final recipeId = SyncIds.remoteId(mutation.entityId);
    if (mutation.operation == 'delete') {
      return MappedMutation(
        ops: [
          RemotePatch('recipes', recipeId, {
            'deleted_at': _string(p['deleted_at']) ?? _nowIso(),
            'last_mutation_id': mutation.mutationId,
          }),
        ],
      );
    }
    final updatedAt = _string(p['updated_at']) ?? _nowIso();
    if (!p.containsKey('name')) {
      // Upsert parziale di setFavorite: applicarlo come riga piena
      // azzererebbe i NOT NULL, quindi diventa una PATCH mirata.
      return MappedMutation(
        ops: [
          RemotePatch('recipes', recipeId, {
            'is_favorite': p['is_favorite'] == true,
            'updated_at': updatedAt,
            'last_mutation_id': mutation.mutationId,
          }),
        ],
      );
    }
    final ingredients = p['ingredients'] is List
        ? (p['ingredients'] as List).whereType<Map>().toList(growable: false)
        : const <Map>[];
    final rows = <Map<String, Object?>>[
      for (final (index, ingredient) in ingredients.indexed)
        {
          'id': _rowId(ingredient['id'], mutation.mutationId, index),
          'recipe_id': recipeId,
          // Gli alimenti locali possono non esistere sul server: il
          // collegamento food_id resta locale, sul cloud viaggia lo snapshot.
          'food_id': null,
          'position': _int(ingredient['position'], fallback: index),
          'quantity_g': _positive(_double(ingredient['grams']), fallback: 1),
          'food_name_snapshot':
              _text(ingredient['name'], max: 160) ?? 'Ingrediente',
          'energy_kcal_per_100g': _double(ingredient['calories_per_100g']),
          'protein_g_per_100g': _double(ingredient['protein_per_100g']),
          'carbohydrate_g_per_100g': _double(ingredient['carbs_per_100g']),
          'fat_g_per_100g': _double(ingredient['fat_per_100g']),
          'fiber_g_per_100g': 0,
          'deleted_at': null,
          'last_mutation_id': SyncIds.derived(
            mutation.mutationId,
            'recipe-item-mut:$index',
          ),
        },
    ];
    return MappedMutation(
      ops: [
        RemoteUpsert('recipes', [
          {
            'id': recipeId,
            'profile_id': SyncIds.remoteId(_string(p['profile_id']) ?? ''),
            'name': _text(p['name'], max: 160) ?? 'Ricetta',
            'description': _text(p['description'], max: 600),
            'instructions': _text(p['instructions'], max: 4000),
            'tags': _tags(p['tags']),
            'servings': _int(p['servings'], fallback: 1).clamp(1, 100),
            'prep_minutes': _int(p['prep_minutes']).clamp(0, 10080),
            'is_favorite': p['is_favorite'] == true,
            // Niente totali sul server: si ricalcolano dagli ingredienti.
            'updated_at': updatedAt,
            'deleted_at': _string(p['deleted_at']),
            'last_mutation_id': SyncIds.derived(mutation.mutationId, 'recipe'),
          },
        ]),
        RemoteChildrenSwap(
          table: 'recipe_items',
          parentColumn: 'recipe_id',
          parentId: recipeId,
          rows: rows,
          tombstoneMutationIdFor: (remoteRowId) =>
              SyncIds.derived(mutation.mutationId, 'recipe-tomb:$remoteRowId'),
          tombstoneAt: updatedAt,
        ),
      ],
      profileLocalId: _string(p['profile_id']),
    );
  }

  static MappedMutation _template(SyncMutation mutation) {
    final p = mutation.payload;
    final templateId = SyncIds.remoteId(mutation.entityId);
    if (mutation.operation == 'delete') {
      return MappedMutation(
        ops: [
          RemotePatch('meal_templates', templateId, {
            'deleted_at': _string(p['deleted_at']) ?? _nowIso(),
            'last_mutation_id': mutation.mutationId,
          }),
        ],
      );
    }
    final updatedAt = _string(p['updated_at']) ?? _nowIso();
    final items = p['items'] is List
        ? (p['items'] as List).whereType<Map>().toList(growable: false)
        : const <Map>[];
    final rows = <Map<String, Object?>>[
      for (final (index, item) in items.indexed)
        {
          // Le voci del payload non hanno id: si derivano uuid stabili
          // dall'evento di outbox, così il retry reinserisce le stesse righe.
          'id': _rowId(item['id'], mutation.mutationId, index),
          'template_id': templateId,
          'position': _int(item['position'], fallback: index),
          'quantity_g': _positive(_double(item['grams']), fallback: 1),
          'food_name_snapshot': _text(item['food_name'], max: 160) ?? 'Voce',
          'energy_kcal_per_100g': _double(item['calories_per_100g']),
          'protein_g_per_100g': _double(item['protein_per_100g']),
          'carbohydrate_g_per_100g': _double(item['carbs_per_100g']),
          'fat_g_per_100g': _double(item['fat_per_100g']),
          'fiber_g_per_100g': 0,
          'deleted_at': null,
          'last_mutation_id': SyncIds.derived(
            mutation.mutationId,
            'template-item-mut:$index',
          ),
        },
    ];
    return MappedMutation(
      ops: [
        RemoteUpsert('meal_templates', [
          {
            'id': templateId,
            'profile_id': SyncIds.remoteId(_string(p['profile_id']) ?? ''),
            'name': _text(p['name'], max: 80) ?? 'Modello',
            'meal_type': _mealType(_string(p['meal_type'])),
            'updated_at': updatedAt,
            'deleted_at': _string(p['deleted_at']),
            'last_mutation_id': SyncIds.derived(
              mutation.mutationId,
              'template',
            ),
          },
        ]),
        RemoteChildrenSwap(
          table: 'meal_template_items',
          parentColumn: 'template_id',
          parentId: templateId,
          rows: rows,
          tombstoneMutationIdFor: (remoteRowId) => SyncIds.derived(
            mutation.mutationId,
            'template-tomb:$remoteRowId',
          ),
          tombstoneAt: updatedAt,
        ),
      ],
      profileLocalId: _string(p['profile_id']),
    );
  }

  static MappedMutation _exercise(SyncMutation mutation) {
    final p = mutation.payload;
    final id = SyncIds.remoteId(mutation.entityId);
    if (mutation.operation == 'delete') {
      return MappedMutation(
        ops: [
          RemotePatch('exercises', id, {
            'deleted_at': _string(p['deleted_at']) ?? _nowIso(),
            'last_mutation_id': mutation.mutationId,
          }),
        ],
      );
    }
    final updatedAt = _string(p['updated_at']) ?? _nowIso();
    return MappedMutation(
      ops: [
        RemoteUpsert('exercises', [
          {
            'id': id,
            'profile_id': SyncIds.remoteId(_string(p['profile_id']) ?? ''),
            'name': _text(p['name'], max: 160) ?? 'Esercizio',
            'muscle_group': _enum(p['muscle_group'], _muscleGroups, 'altro'),
            'tracking_mode': _enum(
              p['tracking_mode'],
              _trackingModes,
              'weightReps',
            ),
            'notes': _text(p['notes'], max: 600),
            'image_url': _text(p['image_url'], max: 500),
            'default_rest_sec': _bounded(p['default_rest_sec'], 0, 3600),
            'is_preset': p['is_preset'] == true,
            'is_synthetic': p['is_synthetic'] == true,
            'source': _enum(p['source'], _exerciseSources, 'manual'),
            // Resta l'id di Gym in chiaro (anche gli slug `cd-*`): la colonna
            // è testo ed è metà della unique che deduplica le importazioni.
            'external_id': _text(p['external_id'], max: 120),
            'updated_at': updatedAt,
            'deleted_at': _string(p['deleted_at']),
            'last_mutation_id': mutation.mutationId,
          },
        ]),
      ],
      profileLocalId: _string(p['profile_id']),
    );
  }

  static MappedMutation _routine(SyncMutation mutation) {
    final p = mutation.payload;
    final routineId = SyncIds.remoteId(mutation.entityId);
    if (mutation.operation == 'delete') {
      return MappedMutation(
        ops: [
          RemotePatch('routines', routineId, {
            'deleted_at': _string(p['deleted_at']) ?? _nowIso(),
            'last_mutation_id': mutation.mutationId,
          }),
        ],
      );
    }
    final updatedAt = _string(p['updated_at']) ?? _nowIso();
    final exercises = _children(p['exercises']);
    final segments = _children(p['interval_segments']);
    return MappedMutation(
      ops: [
        RemoteUpsert('routines', [
          {
            'id': routineId,
            'profile_id': SyncIds.remoteId(_string(p['profile_id']) ?? ''),
            'name': _text(p['name'], max: 160) ?? 'Scheda',
            'notes': _text(p['notes'], max: 1000),
            'is_circuit': p['is_circuit'] == true,
            'work_sec': _bounded(p['work_sec'], 1, 3600) ?? 30,
            'short_rest_sec': _bounded(p['short_rest_sec'], 0, 3600) ?? 30,
            'long_rest_sec': _bounded(p['long_rest_sec'], 0, 3600) ?? 60,
            'rounds': _bounded(p['rounds'], 1, 50) ?? 3,
            'warmup_work_sec': _bounded(p['warmup_work_sec'], 1, 3600) ?? 30,
            'warmup_rest_sec': _bounded(p['warmup_rest_sec'], 0, 3600) ?? 15,
            'source': _enum(p['source'], _workoutSources, 'manual'),
            'external_id': _text(p['external_id'], max: 120),
            'updated_at': updatedAt,
            'deleted_at': _string(p['deleted_at']),
            'last_mutation_id': mutation.mutationId,
          },
        ]),
        // Chiave assente = «questa scrittura non parla dei figli»: uno swap
        // incondizionato li tombstonerebbe a ogni aggiornamento parziale.
        if (p.containsKey('exercises'))
          RemoteChildrenSwap(
            table: 'routine_exercises',
            parentColumn: 'routine_id',
            parentId: routineId,
            rows: [
              for (final (index, row) in exercises.indexed)
                _routineExerciseRow(mutation, routineId, row, index),
            ],
            tombstoneMutationIdFor: (remoteRowId) => SyncIds.derived(
              mutation.mutationId,
              'routine-exercise-tomb:$remoteRowId',
            ),
            tombstoneAt: updatedAt,
          ),
        if (p.containsKey('interval_segments'))
          RemoteChildrenSwap(
            table: 'routine_interval_segments',
            parentColumn: 'routine_id',
            parentId: routineId,
            rows: [
              for (final (index, row) in segments.indexed)
                {
                  'id': _childId(
                    row['id'],
                    mutation.mutationId,
                    'routine-segment',
                    index,
                  ),
                  'routine_id': routineId,
                  'segment_index': _int(row['segment_index'], fallback: index),
                  'start_idx': _int(row['start_idx']),
                  'end_idx': _int(row['end_idx'], fallback: 1),
                  'work_sec': _bounded(row['work_sec'], 1, 3600) ?? 40,
                  'rest_sec': _bounded(row['rest_sec'], 0, 3600) ?? 20,
                  'long_rest_sec': _bounded(row['long_rest_sec'], 0, 3600) ?? 0,
                  'rounds': _bounded(row['rounds'], 1, 50) ?? 1,
                  'deleted_at': null,
                  'last_mutation_id': SyncIds.derived(
                    mutation.mutationId,
                    'routine-segment:$index',
                  ),
                },
            ],
            tombstoneMutationIdFor: (remoteRowId) => SyncIds.derived(
              mutation.mutationId,
              'routine-segment-tomb:$remoteRowId',
            ),
            tombstoneAt: updatedAt,
          ),
      ],
      profileLocalId: _string(p['profile_id']),
    );
  }

  /// Il blocco decide due CHECK remoti: solo il riscaldamento ha una durata,
  /// e la catena di superserie esiste solo nel blocco principale. Un valore
  /// incoerente sarebbe un 23514, cioè la scheda intera scartata.
  static Map<String, Object?> _routineExerciseRow(
    SyncMutation mutation,
    String routineId,
    Map<Object?, Object?> row,
    int index,
  ) {
    final block = _enum(row['block'], _blocks, 'main');
    final position = _int(row['position'], fallback: index);
    return {
      'id': _childId(row['id'], mutation.mutationId, 'routine-exercise', index),
      'routine_id': routineId,
      'exercise_ref_id': SyncIds.remoteId(
        _string(row['exercise_ref_id']) ?? '',
      ),
      'exercise_id': _optionalId(row['exercise_id']),
      'block': block,
      'position': position,
      'exercise_name_snapshot':
          _text(row['exercise_name_snapshot'], max: 160) ?? 'Esercizio',
      'in_superset_with_previous':
          block == 'main' &&
          position > 0 &&
          row['in_superset_with_previous'] == true,
      'warmup_duration_sec': block == 'warmup'
          ? _bounded(row['warmup_duration_sec'], 1, 3600) ?? 30
          : null,
      'presc_sets': _bounded(row['presc_sets'], 1, 50),
      'presc_reps': _bounded(row['presc_reps'], 1, 500),
      'presc_duration_sec': _bounded(row['presc_duration_sec'], 1, 7200),
      'presc_rest_sec': _bounded(row['presc_rest_sec'], 0, 3600),
      'deleted_at': null,
      'last_mutation_id': SyncIds.derived(
        mutation.mutationId,
        'routine-exercise:$index',
      ),
    };
  }

  static MappedMutation _workout(SyncMutation mutation) {
    final p = mutation.payload;
    final workoutId = SyncIds.remoteId(mutation.entityId);
    if (mutation.operation == 'delete') {
      return MappedMutation(
        ops: [
          RemotePatch('workouts', workoutId, {
            'deleted_at': _string(p['deleted_at']) ?? _nowIso(),
            'last_mutation_id': mutation.mutationId,
          }),
        ],
      );
    }
    final updatedAt = _string(p['updated_at']) ?? _nowIso();
    final startedAt = _string(p['started_at']) ?? updatedAt;
    final routineId = _optionalId(p['routine_id']);
    final exercises = _children(p['exercises']);
    final exerciseRows = <Map<String, Object?>>[];
    final setRows = <Map<String, Object?>>[];
    for (final (index, row) in exercises.indexed) {
      final rowId = _childId(
        row['id'],
        mutation.mutationId,
        'workout-exercise',
        index,
      );
      final position = _int(row['position'], fallback: index);
      // I tre blocchi sono esclusivi (CHECK is_warmup + is_cooldown +
      // is_finisher <= 1): due flag insieme sarebbero un 23514, cioè la
      // sessione intera scartata. Precedenza: riscaldamento, defaticamento,
      // finisher.
      final isWarmup = row['is_warmup'] == true;
      final isCooldown = !isWarmup && row['is_cooldown'] == true;
      exerciseRows.add({
        'id': rowId,
        'workout_id': workoutId,
        'exercise_ref_id': SyncIds.remoteId(
          _string(row['exercise_ref_id']) ?? '',
        ),
        'exercise_id': _optionalId(row['exercise_id']),
        'position': position,
        'exercise_name_snapshot':
            _text(row['exercise_name_snapshot'], max: 160) ?? 'Esercizio',
        'tracking_mode': _enum(
          row['tracking_mode'],
          _trackingModes,
          'weightReps',
        ),
        'muscle_group_snapshot': _optionalEnum(
          row['muscle_group_snapshot'],
          _muscleGroups,
        ),
        'rest_seconds': _bounded(row['rest_seconds'], 0, 3600),
        'is_warmup': isWarmup,
        'is_cooldown': isCooldown,
        'is_finisher': !isWarmup && !isCooldown && row['is_finisher'] == true,
        'is_in_superset_with_previous':
            position > 0 && row['is_in_superset_with_previous'] == true,
        'interval_segment_index': _nonNegative(row['interval_segment_index']),
        'deleted_at': null,
        'last_mutation_id': SyncIds.derived(
          mutation.mutationId,
          'workout-exercise:$index',
        ),
      });
      for (final (setIndex, set) in _children(row['sets']).indexed) {
        setRows.add({
          'id': _childId(
            set['id'],
            mutation.mutationId,
            'workout-set:$index',
            setIndex,
          ),
          // `workout_id` è denormalizzato apposta: così la sostituzione in
          // blocco delle serie è un solo swap sul padre invece di uno per
          // esercizio.
          'workout_id': workoutId,
          'workout_exercise_id': rowId,
          'position': _int(set['position'], fallback: setIndex),
          'weight_kg': _boundedDouble(set['weight_kg'], 0, 1000),
          'reps': _bounded(set['reps'], 0, 1000),
          'duration_sec': _bounded(set['duration_sec'], 0, 86400),
          'distance_m': _boundedDouble(set['distance_m'], 0, 200000),
          'rpe': _bounded(set['rpe'], 1, 10),
          'is_warmup': set['is_warmup'] == true,
          'completed': set['completed'] == true,
          'deleted_at': null,
          'last_mutation_id': SyncIds.derived(
            mutation.mutationId,
            'workout-set:$index:$setIndex',
          ),
        });
      }
    }
    final painPoints = _children(p['pain_points']);
    final segments = _children(p['interval_segments']);
    return MappedMutation(
      ops: [
        RemoteUpsert('workouts', [
          {
            'id': workoutId,
            'profile_id': SyncIds.remoteId(_string(p['profile_id']) ?? ''),
            'started_at': startedAt,
            'ended_at': _string(p['ended_at']),
            'paused_at': _string(p['paused_at']),
            // Nessun tetto a 86400: il clamp a 24 h è una regola di lettura,
            // e una sessione dimenticata aperta 536 ore esiste davvero.
            'accumulated_pause_seconds':
                _nonNegative(p['accumulated_pause_seconds']) ?? 0,
            'final_duration_seconds': _nonNegative(p['final_duration_seconds']),
            'duration_suspect': p['duration_suspect'] == true,
            'routine_id': routineId,
            // L'id della scheda sopravvive alla sua cancellazione: nove
            // sessioni puntano a sei schede che non esistono più.
            'routine_external_id':
                _optionalId(p['routine_external_id']) ?? routineId,
            'routine_name_snapshot': _text(
              p['routine_name_snapshot'],
              max: 160,
            ),
            'notes': _text(p['notes'], max: 1000),
            'total_kcal': _nonNegativeDouble(p['total_kcal']),
            'mood': _bounded(p['mood'], 1, 5),
            'rpe': _bounded(p['rpe'], 1, 10),
            'satisfaction': _bounded(p['satisfaction'], 1, 5),
            'feedback_notes': _text(p['feedback_notes'], max: 1000),
            // NULL e 0 sono stati diversi: NULL è «mai premiato» ed è la
            // guardia di idempotenza dell'assegnazione XP.
            'xp_earned': _nonNegative(p['xp_earned']),
            'resume_path': _text(p['resume_path'], max: 200),
            // La colonna remota è jsonb con CHECK su jsonb_typeof = 'object':
            // la stringa JSON locale va decodificata, o arriverebbe come
            // scalare e il CHECK la rifiuterebbe. Si accetta anche il nome
            // della colonna LOCALE, che è testo e si chiama ..._json.
            'circuit_checkpoint': _jsonObject(
              p['circuit_checkpoint'] ?? p['circuit_checkpoint_json'],
            ),
            'synced_to_health_connect': p['synced_to_health_connect'] == true,
            'health_sync_state': _optionalEnum(
              p['health_sync_state'],
              _healthSyncStates,
            ),
            'health_sync_claim_id': _optionalId(p['health_sync_claim_id']),
            'health_sync_attempted_at': _string(p['health_sync_attempted_at']),
            'health_sync_completed_at': _string(p['health_sync_completed_at']),
            'source': _enum(p['source'], _workoutSources, 'manual'),
            'external_id': _text(p['external_id'], max: 120),
            'updated_at': updatedAt,
            'deleted_at': _string(p['deleted_at']),
            'last_mutation_id': mutation.mutationId,
          },
        ]),
        // Chiave assente = «questa scrittura non parla dei figli»: uno swap
        // incondizionato li tombstonerebbe a ogni aggiornamento parziale
        // (chiudere una sessione, salvare il feedback).
        if (p.containsKey('exercises')) ...[
          RemoteChildrenSwap(
            table: 'workout_exercises',
            parentColumn: 'workout_id',
            parentId: workoutId,
            rows: exerciseRows,
            tombstoneMutationIdFor: (remoteRowId) => SyncIds.derived(
              mutation.mutationId,
              'workout-exercise-tomb:$remoteRowId',
            ),
            tombstoneAt: updatedAt,
          ),
          // Le serie stanno nello stesso swap del padre proprio perché
          // `workout_sets` porta anche `workout_id`.
          RemoteChildrenSwap(
            table: 'workout_sets',
            parentColumn: 'workout_id',
            parentId: workoutId,
            rows: setRows,
            tombstoneMutationIdFor: (remoteRowId) => SyncIds.derived(
              mutation.mutationId,
              'workout-set-tomb:$remoteRowId',
            ),
            tombstoneAt: updatedAt,
          ),
        ],
        if (p.containsKey('pain_points'))
          RemoteChildrenSwap(
            table: 'workout_pain_points',
            parentColumn: 'workout_id',
            parentId: workoutId,
            rows: [
              for (final (index, row) in painPoints.indexed)
                {
                  'id': _childId(
                    row['id'],
                    mutation.mutationId,
                    'pain-point',
                    index,
                  ),
                  'workout_id': workoutId,
                  'label': _text(row['label'], max: 40) ?? 'Dolore',
                  'deleted_at': null,
                  'last_mutation_id': SyncIds.derived(
                    mutation.mutationId,
                    'pain-point:$index',
                  ),
                },
            ],
            tombstoneMutationIdFor: (remoteRowId) => SyncIds.derived(
              mutation.mutationId,
              'pain-point-tomb:$remoteRowId',
            ),
            tombstoneAt: updatedAt,
          ),
        if (p.containsKey('interval_segments'))
          RemoteChildrenSwap(
            table: 'workout_interval_segments',
            parentColumn: 'workout_id',
            parentId: workoutId,
            rows: [
              for (final (index, row) in segments.indexed)
                // Una riga senza nessun marker non è un dato: il CHECK la
                // rifiuterebbe e con lei l'intera sessione.
                if (row['completed_marker'] == true ||
                    row['partial_marker'] == true)
                  {
                    'id': _childId(
                      row['id'],
                      mutation.mutationId,
                      'workout-segment',
                      index,
                    ),
                    'workout_id': workoutId,
                    'segment_index': _int(
                      row['segment_index'],
                      fallback: index,
                    ),
                    // I due marker sono indipendenti e possono valere insieme:
                    // è lo stato che produce `appendPartialIntervalSegment`
                    // quando la firma non combacia più.
                    'completed_marker': row['completed_marker'] == true,
                    'partial_marker': row['partial_marker'] == true,
                    'completion_signature': row['completed_marker'] == true
                        ? _text(row['completion_signature'], max: 8192)
                        : null,
                    'deleted_at': null,
                    'last_mutation_id': SyncIds.derived(
                      mutation.mutationId,
                      'workout-segment:$index',
                    ),
                  },
            ],
            tombstoneMutationIdFor: (remoteRowId) => SyncIds.derived(
              mutation.mutationId,
              'workout-segment-tomb:$remoteRowId',
            ),
            tombstoneAt: updatedAt,
          ),
      ],
      profileLocalId: _string(p['profile_id']),
    );
  }

  static MappedMutation _workoutProfileStats(SyncMutation mutation) {
    final p = mutation.payload;
    final profileLocalId = _string(p['profile_id']) ?? mutation.entityId;
    final remoteProfileId = SyncIds.remoteId(profileLocalId);
    final statsId = SyncIds.remoteId(mutation.entityId);
    if (mutation.operation == 'delete') {
      return MappedMutation(
        ops: [
          RemotePatch('workout_profile_stats', statsId, {
            'deleted_at': _string(p['deleted_at']) ?? _nowIso(),
            'last_mutation_id': mutation.mutationId,
          }),
        ],
        profileLocalId: profileLocalId,
      );
    }
    final updatedAt = _string(p['updated_at']) ?? _nowIso();
    final currentStreak = _bounded(p['current_streak'], 0, 100000) ?? 0;
    final achievements = _children(p['achievements']);
    final weeklyPlan = _children(p['weekly_plan']);
    return MappedMutation(
      ops: [
        RemoteUpsert('workout_profile_stats', [
          {
            'id': statsId,
            'profile_id': remoteProfileId,
            'total_xp': _bounded(p['total_xp'], 0, 100000000) ?? 0,
            'current_streak': currentStreak,
            // Il CHECK remoto pretende longest >= current: un longest più
            // basso è un dato incoerente, non un motivo per perdere la riga.
            'longest_streak': math.max(
              _bounded(p['longest_streak'], 0, 100000) ?? 0,
              currentStreak,
            ),
            'last_workout_day': _calendarDate(p['last_workout_day']),
            'weekly_workout_goal':
                _bounded(p['weekly_workout_goal'], 1, 14) ?? 3,
            'weekly_kcal_goal':
                _bounded(p['weekly_kcal_goal'], 0, 100000) ?? 1500,
            'reminder_enabled': p['reminder_enabled'] == true,
            'reminder_hour': _bounded(p['reminder_hour'], 0, 23) ?? 18,
            'reminder_minute': _bounded(p['reminder_minute'], 0, 59) ?? 0,
            'health_connect_enabled': p['health_connect_enabled'] == true,
            'voice_enabled': p['voice_enabled'] != false,
            'gym_body_weight_kg': _boundedDouble(
              p['gym_body_weight_kg'],
              20,
              500,
            ),
            'gym_exported_at': _string(p['gym_exported_at']),
            'updated_at': updatedAt,
            'deleted_at': _string(p['deleted_at']),
            'last_mutation_id': mutation.mutationId,
          },
        ]),
        // Chiave assente = «questa scrittura non parla dei figli»: cambiare il
        // promemoria non deve azzerare 22 trofei e 5 giorni di piano.
        if (p.containsKey('achievements'))
          RemoteChildrenSwap(
            table: 'workout_achievements',
            parentColumn: 'profile_id',
            parentId: remoteProfileId,
            rows: [
              for (final (index, row) in achievements.indexed)
                {
                  'id': _childId(
                    row['id'],
                    mutation.mutationId,
                    'achievement',
                    index,
                  ),
                  'profile_id': remoteProfileId,
                  'slug': _text(row['slug'], max: 60) ?? 'sconosciuto',
                  // NULL per i trofei importati: l'export non dice quando, e
                  // metterci l'istante dell'import schiaccerebbe la timeline
                  // sul giorno della migrazione.
                  'unlocked_at': _string(row['unlocked_at']),
                  'deleted_at': null,
                  'last_mutation_id': SyncIds.derived(
                    mutation.mutationId,
                    'achievement:$index',
                  ),
                },
            ],
            tombstoneMutationIdFor: (remoteRowId) => SyncIds.derived(
              mutation.mutationId,
              'achievement-tomb:$remoteRowId',
            ),
            tombstoneAt: updatedAt,
          ),
        if (p.containsKey('weekly_plan'))
          RemoteChildrenSwap(
            table: 'routine_weekly_plan',
            parentColumn: 'profile_id',
            parentId: remoteProfileId,
            rows: [
              for (final (index, row) in weeklyPlan.indexed)
                {
                  'id': _childId(
                    row['id'],
                    mutation.mutationId,
                    'weekly-plan',
                    index,
                  ),
                  'profile_id': remoteProfileId,
                  'weekday': _bounded(row['weekday'], 1, 7) ?? 1,
                  'routine_id': _optionalId(row['routine_id']),
                  'routine_external_id': _optionalId(
                    row['routine_external_id'],
                  ),
                  'routine_name_snapshot': _text(
                    row['routine_name_snapshot'],
                    max: 160,
                  ),
                  'deleted_at': null,
                  'last_mutation_id': SyncIds.derived(
                    mutation.mutationId,
                    'weekly-plan:$index',
                  ),
                },
            ],
            tombstoneMutationIdFor: (remoteRowId) => SyncIds.derived(
              mutation.mutationId,
              'weekly-plan-tomb:$remoteRowId',
            ),
            tombstoneAt: updatedAt,
          ),
      ],
      profileLocalId: profileLocalId,
    );
  }

  /// La tabella remota `profiles` impone unique(owner_id): se sul server
  /// esiste già un profilo con un id diverso (reinstallazione, ripristino,
  /// secondo dispositivo) gli op vengono rimappati sul suo id, compreso
  /// l'id derivato del target nutrizionale.
  static RemoteOp adoptProfile(
    RemoteOp op, {
    required String from,
    required String to,
  }) {
    if (from == to) {
      return op;
    }
    final targetFrom = SyncIds.nutritionTargetId(from);
    final targetTo = SyncIds.nutritionTargetId(to);
    Object? swap(Object? value) => value == from
        ? to
        : value == targetFrom
        ? targetTo
        : value;
    Map<String, Object?> swapRow(Map<String, Object?> row) => {
      for (final entry in row.entries) entry.key: swap(entry.value),
    };
    return switch (op) {
      RemoteUpsert() => RemoteUpsert(op.table, [
        for (final row in op.rows) swapRow(row),
      ]),
      RemotePatch() => RemotePatch(
        op.table,
        swap(op.id)! as String,
        swapRow(op.values),
      ),
      RemoteChildrenSwap() => RemoteChildrenSwap(
        table: op.table,
        parentColumn: op.parentColumn,
        // Anche il padre segue l'adozione: i trofei e il piano settimanale
        // sono figli del PROFILO, e con il parentId vecchio lo swap
        // cercherebbe le righe vive sotto un profilo che non esiste più.
        parentId: swap(op.parentId)! as String,
        rows: [for (final row in op.rows) swapRow(row)],
        tombstoneMutationIdFor: op.tombstoneMutationIdFor,
        tombstoneAt: op.tombstoneAt,
      ),
    };
  }

  static String? _string(Object? value) => value is String ? value : null;

  static String? _text(Object? value, {required int max}) {
    final text = _string(value)?.trim();
    if (text == null || text.isEmpty) {
      return null;
    }
    return text.length > max ? text.substring(0, max) : text;
  }

  static double _double(Object? value) {
    final parsed = value is num ? value.toDouble() : 0.0;
    return parsed.isFinite && parsed >= 0 ? parsed : 0.0;
  }

  static double _positive(double value, {required double fallback}) =>
      value > 0 ? value : fallback;

  static int _int(Object? value, {int fallback = 0}) =>
      value is num ? value.toInt() : fallback;

  static int? _bounded(Object? value, int min, int max) {
    if (value is! num || !value.toDouble().isFinite) {
      return null;
    }
    return value.toInt().clamp(min, max).toInt();
  }

  static double? _boundedDouble(Object? value, double min, double max) {
    if (value is! num || !value.toDouble().isFinite) {
      return null;
    }
    return value.toDouble().clamp(min, max).toDouble();
  }

  static int? _nonNegative(Object? value) =>
      value is num && value >= 0 ? value.toInt() : null;

  static double? _nonNegativeDouble(Object? value) =>
      value is num && value.toDouble().isFinite && value >= 0
      ? value.toDouble()
      : null;

  static const _mealTypes = {'breakfast', 'lunch', 'dinner', 'snack', 'other'};

  static const _muscleGroups = {
    'petto',
    'schiena',
    'spalle',
    'bicipiti',
    'tricipiti',
    'gambe',
    'polpacci',
    'addome',
    'cardio',
    'fullbody',
    'mobilita',
    'altro',
  };

  static const _trackingModes = {
    'weightReps',
    'bodyweightReps',
    'timeOnly',
    'timed',
    'distanceTime',
  };

  static const _blocks = {'warmup', 'main', 'finisher'};

  static const _exerciseSources = {'manual', 'gym_tracker', 'cooldown_preset'};

  static const _workoutSources = {'manual', 'gym_tracker'};

  static const _measurementSources = {
    'kal_tracker',
    'manual',
    'renpho_ble',
    'renpho_csv',
    'gym_tracker',
    'health_connect',
  };

  static const _healthSyncStates = {'writing', 'synced', 'uncertain'};

  static String _mealType(String? value) =>
      _mealTypes.contains(value) ? value! : 'other';

  /// I CHECK remoti su questi campi sono chiusi: un valore fuori elenco è un
  /// 23514 permanente, e una mutation scartata è un dato perso.
  static String _enum(Object? value, Set<String> allowed, String fallback) {
    final text = _string(value);
    return allowed.contains(text) ? text! : fallback;
  }

  static String? _optionalEnum(Object? value, Set<String> allowed) {
    final text = _string(value);
    return allowed.contains(text) ? text : null;
  }

  static List<Map<Object?, Object?>> _children(Object? value) => value is List
      ? value.whereType<Map<Object?, Object?>>().toList(growable: false)
      : const [];

  /// Id remoto di una FK opzionale: null quando la chiave è assente o vuota,
  /// altrimenti la STESSA derivazione del padre (gli slug `cd-*` non sono
  /// uuid e diventano uuid v5: senza questo passaggio il server risponde
  /// 23503 e la mutation resta bloccata in coda).
  static String? _optionalId(Object? value) {
    final id = _string(value)?.trim();
    return id == null || id.isEmpty ? null : SyncIds.remoteId(id);
  }

  /// Id remoto di una riga figlia: si deriva dall'id LOCALE quando c'è, così
  /// resta lo stesso anche se la mutation viene riaccodata; il fallback per i
  /// payload senza id è deterministico sull'evento di outbox.
  static String _childId(
    Object? payloadId,
    String mutationId,
    String kind,
    int index,
  ) {
    final id = _string(payloadId)?.trim();
    return id == null || id.isEmpty
        ? SyncIds.derived(mutationId, '$kind:$index')
        : SyncIds.remoteId(id);
  }

  static Map<String, Object?>? _jsonObject(Object? value) {
    if (value is Map) {
      return Map<String, Object?>.from(value);
    }
    final raw = _string(value);
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, Object?>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }

  static String? _tags(Object? value) {
    final raw = _string(value);
    if (raw == null) {
      return null;
    }
    final segments = raw
        .toLowerCase()
        .split(',')
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.isEmpty) {
      return null;
    }
    final encoded = segments.join(',');
    return encoded.length > 240 ? null : encoded;
  }

  static String _rowId(Object? payloadId, String mutationId, int index) {
    final id = _string(payloadId);
    return id != null && SyncIds.isUuid(id)
        ? id.toLowerCase()
        : SyncIds.derived(mutationId, 'row-id:$index');
  }

  static String _localDate(String isoInstant) =>
      _romeDay(DateTime.tryParse(isoInstant)?.toUtc() ?? AppTime.nowUtc());

  static String _romeDay(DateTime instant) {
    final rome = AppTime.inRome(instant);
    final month = rome.month.toString().padLeft(2, '0');
    final day = rome.day.toString().padLeft(2, '0');
    return '${rome.year}-$month-$day';
  }

  static final _plainDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  /// Valore per una colonna Postgres `date`. Un istante UTC ci finisce
  /// troncato: la mezzanotte di Roma è le 22:00 del giorno prima, e
  /// `last_workout_day` slitterebbe indietro spezzando lo streak.
  static String? _calendarDate(Object? value) {
    final raw = _string(value)?.trim();
    if (raw == null || raw.isEmpty) {
      return null;
    }
    if (_plainDate.hasMatch(raw)) {
      return raw;
    }
    final instant = DateTime.tryParse(raw);
    return instant == null ? null : _romeDay(instant.toUtc());
  }

  static String _nowIso() => AppTime.nowUtc().toIso8601String();
}

/// Contratto del gateway: tutta la logica del motore dipende solo da qui.
abstract class SyncGateway {
  Future<SyncAccount?> currentAccount();

  Future<SyncAccount> signIn({required String email, required String password});

  Future<void> signOut();

  Future<void> pushMutation(SyncMutation mutation);

  Future<List<RemoteChange>> fetchChanges({
    required int afterChangeId,
    int limit = 200,
  });
}

/// Implementazione reale su Supabase (schema `kal_tracker`, PostgREST puro:
/// niente RPC, il contratto server è trigger + ledger `sync_changes`).
class SupabaseSyncGateway implements SyncGateway {
  SupabaseSyncGateway({SupabaseClient? client}) : _clientOverride = client;

  static const schemaName = 'kal_tracker';

  final SupabaseClient? _clientOverride;
  final Map<String, String> _ensuredProfiles = {};

  SupabaseClient get _client {
    final client = _clientOverride;
    if (client != null) {
      return client;
    }
    try {
      return Supabase.instance.client;
    } on Object {
      throw const SyncGatewayException(
        'Il cloud non è pronto: riapri l’app e riprova.',
        retryable: true,
      );
    }
  }

  SupabaseQuerySchema get _db => _client.schema(schemaName);

  @override
  Future<SyncAccount?> currentAccount() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      return null;
    }
    return SyncAccount(userId: user.id, email: user.email ?? '');
  }

  @override
  Future<SyncAccount> signIn({
    required String email,
    required String password,
  }) async {
    try {
      final response = await _client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      final user = response.user;
      if (user == null) {
        throw const SyncGatewayException(
          'Accesso non riuscito: controlla email e password.',
        );
      }
      return SyncAccount(userId: user.id, email: user.email ?? email);
    } on SyncGatewayException {
      rethrow;
    } on AuthException {
      throw const SyncGatewayException(
        'Accesso non riuscito: controlla email e password.',
        authRequired: true,
      );
    } on Object {
      throw const SyncGatewayException(
        'Non riesco a contattare il server: controlla la connessione.',
        retryable: true,
      );
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await _client.auth.signOut();
    } on Object {
      // Anche se il server non risponde la sessione locale viene rimossa.
      return;
    }
  }

  @override
  Future<void> pushMutation(SyncMutation mutation) async {
    _requireSession();
    final mapped = SyncPushMapper.map(mutation);
    try {
      var ops = mapped.ops;
      final profileLocalId = mapped.profileLocalId;
      if (profileLocalId != null && profileLocalId.isNotEmpty) {
        final expectedId = SyncIds.remoteId(profileLocalId);
        final actualId = await _ensureProfile(profileLocalId);
        if (actualId != expectedId) {
          ops = [
            for (final op in ops)
              SyncPushMapper.adoptProfile(op, from: expectedId, to: actualId),
          ];
        }
      }
      for (final op in ops) {
        await _execute(op);
      }
    } on SyncGatewayException {
      rethrow;
    } on Object catch (error) {
      throw _wrap(error);
    }
  }

  @override
  Future<List<RemoteChange>> fetchChanges({
    required int afterChangeId,
    int limit = 200,
  }) async {
    _requireSession();
    try {
      final rows = await _db
          .from('sync_changes')
          .select('change_id, entity_type, entity_id, operation, payload')
          .gt('change_id', afterChangeId)
          .order('change_id', ascending: true)
          .limit(limit);
      return [
        for (final row in rows)
          RemoteChange(
            changeId: (row['change_id'] as num).toInt(),
            entityType: row['entity_type'] as String,
            entityId: row['entity_id'] as String,
            operation: row['operation'] as String,
            payload: row['payload'] is Map
                ? Map<String, Object?>.from(row['payload'] as Map)
                : const {},
          ),
      ];
    } on SyncGatewayException {
      rethrow;
    } on Object catch (error) {
      throw _wrap(error);
    }
  }

  /// Garantisce la riga `profiles` remota e ritorna il suo id.
  /// La tabella impone unique(owner_id): se esiste già un profilo con un
  /// altro id (reinstallazione, ripristino backup, secondo dispositivo)
  /// si adotta quello, altrimenti ogni push morirebbe con 23505.
  Future<String> _ensureProfile(String profileLocalId) async {
    final remoteId = SyncIds.remoteId(profileLocalId);
    final known = _ensuredProfiles[remoteId];
    if (known != null) {
      return known;
    }
    final existing = await _db
        .from('profiles')
        .select('id')
        .isFilter('deleted_at', null)
        .limit(1);
    var actualId = existing.isNotEmpty ? existing.first['id'] as String? : null;
    if (actualId == null) {
      actualId = remoteId;
      await _db.from('profiles').upsert({
        'id': remoteId,
        'display_name': 'Marco',
        'time_zone': SyncPushMapper.timeZone,
        'locale': 'it_IT',
        'last_mutation_id': SyncIds.derived('profile', remoteId),
      });
    }
    _ensuredProfiles[remoteId] = actualId;
    return actualId;
  }

  Future<void> _execute(RemoteOp op) async {
    switch (op) {
      case RemoteUpsert():
        if (op.rows.isNotEmpty) {
          await _db.from(op.table).upsert(op.rows);
        }
      case RemotePatch():
        await _db.from(op.table).update(op.values).eq('id', op.id);
      case RemoteChildrenSwap():
        final live = await _db
            .from(op.table)
            .select('id')
            .eq(op.parentColumn, op.parentId)
            .isFilter('deleted_at', null);
        final liveIds = [for (final row in live) row['id'] as String];
        for (final rowId in op.tombstoneTargets(liveIds)) {
          await _db
              .from(op.table)
              .update({
                'deleted_at': op.tombstoneAt,
                'last_mutation_id': op.tombstoneMutationIdFor(rowId),
              })
              .eq('id', rowId);
        }
        if (op.rows.isNotEmpty) {
          await _db.from(op.table).upsert(op.rows);
        }
    }
  }

  void _requireSession() {
    if (_client.auth.currentSession == null) {
      throw const SyncGatewayException(
        'Serve l’accesso per sincronizzare.',
        authRequired: true,
      );
    }
  }

  SyncGatewayException _wrap(Object error) {
    if (error is AuthException) {
      return const SyncGatewayException(
        'La sessione è scaduta: accedi di nuovo.',
        authRequired: true,
      );
    }
    if (error is PostgrestException) {
      final code = error.code;
      if (SyncRetryPolicy.integrityCodes.contains(code)) {
        return SyncGatewayException(
          'Il server non ha ancora tutti i dati collegati '
          '(codice $code): riprovo più tardi.',
          retryable: true,
        );
      }
      return SyncGatewayException(
        'Il server ha rifiutato la modifica (codice ${code ?? '?'}).',
        retryable: SyncRetryPolicy.isRetryable(code),
      );
    }
    if (error is SocketException || error is TimeoutException) {
      return const SyncGatewayException(
        'Connessione assente: riproverò più tardi.',
        retryable: true,
      );
    }
    return const SyncGatewayException(
      'Errore di rete durante la sincronizzazione.',
      retryable: true,
    );
  }
}

final syncGatewayProvider = Provider<SyncGateway>(
  (ref) => SupabaseSyncGateway(),
);
