import 'dart:async';
import 'dart:io';

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

  final List<RemoteOp> ops;

  /// Profilo locale citato dalla mutation: il gateway garantisce che la
  /// riga `profiles` remota esista prima di eseguire gli op.
  final String? profileLocalId;
}

/// Traduzione pura outbox locale -> contratto remoto (tabella `kal_tracker`).
/// Accetta sia i payload dei repository sia quelli del ripristino backup.
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
        return const MappedMutation();
      case 'fit_recipe':
        return _recipe(mutation);
      case 'meal_template':
        return _template(mutation);
      default:
        return const MappedMutation();
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
    return MappedMutation(
      ops: [
        RemoteUpsert('body_measurements', [
          {
            'id': id,
            'profile_id': SyncIds.remoteId(_string(p['profile_id']) ?? ''),
            'weight_kg': _double(p['weight_kg']).clamp(20, 500),
            'measured_at': _string(p['measured_at']) ?? updatedAt,
            'note': _text(p['note'], max: 240),
            'source': 'kal_tracker',
            'updated_at': updatedAt,
            'deleted_at': _string(p['deleted_at']),
            'last_mutation_id': mutation.mutationId,
          },
        ]),
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
        parentId: op.parentId,
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

  static const _mealTypes = {'breakfast', 'lunch', 'dinner', 'snack', 'other'};

  static String _mealType(String? value) =>
      _mealTypes.contains(value) ? value! : 'other';

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

  static String _localDate(String isoInstant) {
    final instant = DateTime.tryParse(isoInstant)?.toUtc() ?? AppTime.nowUtc();
    final rome = AppTime.inRome(instant);
    final month = rome.month.toString().padLeft(2, '0');
    final day = rome.day.toString().padLeft(2, '0');
    return '${rome.year}-$month-$day';
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
      const retryableCodes = {'408', '425', '429', '500', '502', '503', '504'};
      return SyncGatewayException(
        'Il server ha rifiutato la modifica (codice ${error.code ?? '?'}).',
        retryable: retryableCodes.contains(error.code),
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
