import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/sync/sync_auth.dart';
import 'package:kal_tracker/core/sync/sync_gateway.dart';
import 'package:kal_tracker/core/sync/sync_state_store.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

class SyncReport {
  const SyncReport({
    this.pushed = 0,
    this.pulled = 0,
    this.skipped = 0,
    this.error,
    this.signedOut = false,
    this.completedAt,
  });

  final int pushed;
  final int pulled;
  final int skipped;
  final String? error;
  final bool signedOut;
  final DateTime? completedAt;

  bool get succeeded => error == null && !signedOut;
}

/// Motore di sincronizzazione: push dell'outbox poi pull del change feed,
/// mai concorrenti (le chiamate sovrapposte condividono la stessa run).
class SyncEngine {
  SyncEngine({
    required this._database,
    required this._gateway,
    required this._stateStore,
    DateTime Function()? now,
    this.pageSize = 200,
  }) : _now = now ?? AppTime.nowUtc;

  static const backoffSteps = [
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 30),
    Duration(hours: 2),
    Duration(hours: 24),
  ];

  final AppDatabase _database;
  final SyncGateway _gateway;
  final SyncStateStore _stateStore;
  final DateTime Function() _now;
  final int pageSize;

  Future<SyncReport>? _inFlight;

  /// Con [ignoreBackoff] il push tenta subito anche la testa della coda
  /// in attesa di backoff: è il contratto di "Sincronizza ora".
  Future<SyncReport> sync({bool ignoreBackoff = false}) => _inFlight ??= _run(
    ignoreBackoff: ignoreBackoff,
  ).whenComplete(() => _inFlight = null);

  Future<int> pendingCount() async =>
      (await _database.select(_database.syncOutbox).get()).length;

  Stream<int> watchPendingCount() =>
      _database.select(_database.syncOutbox).watch().map((rows) => rows.length);

  Future<SyncReport> _run({required bool ignoreBackoff}) async {
    try {
      final account = await _gateway.currentAccount();
      if (account == null) {
        return const SyncReport(signedOut: true);
      }
      var state = await _stateStore.read();

      final push = await _push(state, ignoreBackoff: ignoreBackoff);
      state = push.state;
      if (push.signedOut) {
        return SyncReport(pushed: push.pushed, signedOut: true);
      }

      final pull = await _pull(state);
      state = pull.state;

      final error = push.error ?? pull.error;
      if (error == null) {
        state = state.copyWith(lastSyncAt: _now());
      }
      await _stateStore.write(state);
      return SyncReport(
        pushed: push.pushed,
        pulled: pull.pulled,
        skipped: pull.skipped,
        error: error,
        completedAt: state.lastSyncAt,
      );
    } on Object {
      return const SyncReport(
        error: 'Sincronizzazione non riuscita: riproverò più tardi.',
      );
    }
  }

  Future<({SyncState state, int pushed, String? error, bool signedOut})> _push(
    SyncState state, {
    required bool ignoreBackoff,
  }) async {
    final rows =
        await (_database.select(_database.syncOutbox)..orderBy([
              (t) => OrderingTerm.asc(t.createdAt),
              (t) => OrderingTerm(
                expression: const CustomExpression<int>('rowid'),
              ),
            ]))
            .get();

    var pushed = 0;
    var discarded = 0;
    var aliases = state.remoteToLocalIds;
    String? error;
    var signedOut = false;

    for (final row in rows) {
      final nextAttemptAt = row.nextAttemptAt;
      if (!ignoreBackoff &&
          nextAttemptAt != null &&
          nextAttemptAt.isAfter(_now())) {
        // La testa della coda non è ancora pronta: fermarsi preserva
        // l'ordine di applicazione per entità.
        break;
      }
      final mutation = SyncMutation(
        mutationId: row.id,
        entityType: row.entityType,
        entityId: row.entityId,
        operation: row.operation,
        payload: _decodePayload(row.payloadJson),
      );
      try {
        await _gateway.pushMutation(mutation);
      } on Object catch (pushError) {
        if (pushError is SyncGatewayException) {
          if (pushError.authRequired) {
            signedOut = true;
            break;
          }
          if (!pushError.retryable) {
            // Rifiuto permanente del server: ritentare per sempre
            // bloccherebbe tutta la coda dietro questa riga. Si scarta
            // e si prosegue con le mutation successive.
            await (_database.delete(
              _database.syncOutbox,
            )..where((t) => t.id.equals(row.id))).go();
            discarded++;
            continue;
          }
        }
        error = pushError is SyncGatewayException
            ? pushError.message
            : 'Invio non riuscito: riproverò più tardi.';
        final attempts = row.attemptCount + 1;
        final step =
            backoffSteps[math.min(row.attemptCount, backoffSteps.length - 1)];
        await (_database.update(
          _database.syncOutbox,
        )..where((t) => t.id.equals(row.id))).write(
          SyncOutboxCompanion(
            attemptCount: Value(attempts),
            nextAttemptAt: Value(_now().add(step)),
          ),
        );
        break;
      }
      // Solo dopo la conferma del server la riga di outbox sparisce.
      await (_database.delete(
        _database.syncOutbox,
      )..where((t) => t.id.equals(row.id))).go();
      pushed++;
      aliases = _recordAliases(aliases, mutation);
    }

    if (discarded > 0) {
      error ??= discarded == 1
          ? 'Il server ha rifiutato una modifica: l’ho scartata per '
                'non bloccare la coda.'
          : 'Il server ha rifiutato $discarded modifiche: le ho scartate '
                'per non bloccare la coda.';
    }

    return (
      state: state.copyWith(remoteToLocalIds: aliases),
      pushed: pushed,
      error: error,
      signedOut: signedOut,
    );
  }

  Map<String, String> _recordAliases(
    Map<String, String> aliases,
    SyncMutation mutation,
  ) {
    const idKeyed = {
      'meal_item',
      'water_log',
      'body_measurement',
      'food',
      'fit_recipe',
      'meal_template',
    };
    var updated = aliases;
    void record(String localId) {
      final remote = SyncIds.remoteId(localId);
      if (remote != localId && updated[remote] != localId) {
        updated = {...updated, remote: localId};
      }
    }

    if (idKeyed.contains(mutation.entityType)) {
      record(mutation.entityId);
    }
    final mealId = mutation.payload['meal_id'];
    if (mutation.entityType == 'meal_item' && mealId is String) {
      record(mealId);
    }
    return updated;
  }

  Future<({SyncState state, int pulled, int skipped, String? error})> _pull(
    SyncState state,
  ) async {
    var pulled = 0;
    var skipped = 0;
    String? error;
    final marcoId = (await LocalProfileRepository(
      _database,
    ).getOrCreateMarco()).id;

    while (true) {
      List<RemoteChange> changes;
      try {
        changes = await _gateway.fetchChanges(
          afterChangeId: state.lastChangeId,
          limit: pageSize,
        );
      } on Object catch (pullError) {
        error = pullError is SyncGatewayException
            ? pullError.message
            : 'Scaricamento non riuscito: riproverò più tardi.';
        break;
      }
      if (changes.isEmpty) {
        break;
      }
      for (final change in changes) {
        bool applied;
        try {
          applied = await _applyChange(change, marcoId, state);
        } on Object {
          // Errore locale (lock SQLite, disco, I/O): il cursore non
          // avanza, così la riga viene riscaricata al prossimo sync.
          // Le righe incompatibili non arrivano qui: _applyChange le
          // rifiuta ritornando false.
          error = 'Salvataggio locale non riuscito: riproverò più tardi.';
          break;
        }
        if (applied) {
          pulled++;
        } else {
          skipped++;
        }
        state = state.copyWith(lastChangeId: change.changeId);
      }
      await _stateStore.write(state);
      if (error != null || changes.length < pageSize) {
        break;
      }
    }
    return (state: state, pulled: pulled, skipped: skipped, error: error);
  }

  Future<bool> _applyChange(
    RemoteChange change,
    String marcoId,
    SyncState state,
  ) async {
    final p = change.payload;
    String localId(Object? value) {
      final id = value is String ? value : '';
      return state.remoteToLocalIds[id] ?? id;
    }

    switch (change.entityType) {
      case 'meals':
        return _applyMeal(p, marcoId, localId);
      case 'meal_items':
        return _applyMealItem(p, localId);
      case 'nutrition_targets':
        return _applyTarget(p, marcoId);
      case 'water_logs':
        return _applyWaterLog(p, marcoId, localId);
      case 'body_measurements':
        return _applyBodyMeasurement(p, marcoId, localId);
      case 'foods':
        return _applyFood(p, marcoId, localId);
      case 'recipes':
        return _applyRecipe(p, marcoId, localId);
      case 'recipe_items':
        return _applyRecipeItem(p, change.operation, localId);
      case 'meal_templates':
        return _applyTemplate(p, marcoId, localId);
      case 'meal_template_items':
        return _applyTemplateItem(p, change.operation, localId);
      default:
        // profiles, external_workouts, meal_analysis_jobs: niente da fare.
        return false;
    }
  }

  Future<bool> _applyMeal(
    Map<String, Object?> p,
    String marcoId,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    if (id.isEmpty) {
      return false;
    }
    final existing = await (_database.select(
      _database.meals,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    final remoteUpdated = _time(p['updated_at']) ?? _now();
    // Conflitti: vince l'updated_at più recente (stessa regola del backup).
    if (existing != null && existing.updatedAt.isAfter(remoteUpdated)) {
      return false;
    }
    await _database
        .into(_database.meals)
        .insertOnConflictUpdate(
          MealsCompanion(
            id: Value(id),
            profileId: Value(marcoId),
            mealType: Value(
              _string(p['meal_type']) ?? existing?.mealType ?? 'snack',
            ),
            eatenAt: Value(
              _time(p['eaten_at']) ?? existing?.eatenAt ?? remoteUpdated,
            ),
            createdAt: Value(
              existing?.createdAt ?? _time(p['created_at']) ?? remoteUpdated,
            ),
            updatedAt: Value(remoteUpdated),
            deletedAt: Value(_time(p['deleted_at'])),
          ),
        );
    return true;
  }

  Future<bool> _applyMealItem(
    Map<String, Object?> p,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final mealId = localId(p['meal_id']);
    if (id.isEmpty || mealId.isEmpty) {
      return false;
    }
    final meal = await (_database.select(
      _database.meals,
    )..where((t) => t.id.equals(mealId))).getSingleOrNull();
    if (meal == null) {
      return false;
    }
    final existing = await (_database.select(
      _database.mealItems,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    final remoteUpdated = _time(p['updated_at']) ?? _now();
    // Conflitti: vince l'updated_at più recente (stessa regola del backup).
    if (existing != null && existing.updatedAt.isAfter(remoteUpdated)) {
      return false;
    }
    final grams = _double(p['quantity_g']);
    final per100g = Nutrients(
      calories: _double(p['energy_kcal_per_100g']),
      protein: _double(p['protein_g_per_100g']),
      carbs: _double(p['carbohydrate_g_per_100g']),
      fat: _double(p['fat_g_per_100g']),
    );
    if (grams <= 0 || !per100g.isValid) {
      return false;
    }
    final totals = NutritionCalculator.scale(per100g: per100g, grams: grams);
    await _database
        .into(_database.mealItems)
        .insertOnConflictUpdate(
          MealItemsCompanion(
            id: Value(id),
            mealId: Value(mealId),
            foodName: Value(_string(p['food_name_snapshot']) ?? 'Alimento'),
            grams: Value(grams),
            caloriesPer100g: Value(per100g.calories),
            proteinPer100g: Value(per100g.protein),
            carbsPer100g: Value(per100g.carbs),
            fatPer100g: Value(per100g.fat),
            totalCalories: Value(totals.calories),
            totalProtein: Value(totals.protein),
            totalCarbs: Value(totals.carbs),
            totalFat: Value(totals.fat),
            source: Value(_string(p['food_source_snapshot']) ?? 'manual'),
            createdAt: Value(
              existing?.createdAt ?? _time(p['created_at']) ?? remoteUpdated,
            ),
            updatedAt: Value(remoteUpdated),
            deletedAt: Value(_time(p['deleted_at'])),
          ),
        );
    return true;
  }

  Future<bool> _applyTarget(Map<String, Object?> p, String marcoId) async {
    final calories = _double(p['energy_kcal']);
    if (calories <= 0) {
      return false;
    }
    final existing = await (_database.select(
      _database.nutritionTargets,
    )..where((t) => t.profileId.equals(marcoId))).getSingleOrNull();
    final remoteUpdated = _time(p['updated_at']) ?? _now();
    // Conflitti: vince l'updated_at più recente (stessa regola del backup).
    if (existing != null && existing.updatedAt.isAfter(remoteUpdated)) {
      return false;
    }
    await _database
        .into(_database.nutritionTargets)
        .insertOnConflictUpdate(
          NutritionTargetsCompanion(
            profileId: Value(marcoId),
            dailyCalories: Value(calories),
            dailyProtein: Value(_double(p['protein_g'])),
            dailyCarbs: Value(_double(p['carbohydrate_g'])),
            dailyFat: Value(_double(p['fat_g'])),
            createdAt: Value(
              existing?.createdAt ?? _time(p['created_at']) ?? remoteUpdated,
            ),
            updatedAt: Value(remoteUpdated),
            deletedAt: Value(_time(p['deleted_at'])),
          ),
        );
    return true;
  }

  Future<bool> _applyWaterLog(
    Map<String, Object?> p,
    String marcoId,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final milliliters = _int(p['milliliters']);
    if (id.isEmpty || milliliters <= 0 || milliliters > 10000) {
      return false;
    }
    final existing = await (_database.select(
      _database.waterLogs,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    final remoteUpdated = _time(p['updated_at']) ?? _now();
    // Conflitti: vince l'updated_at più recente (stessa regola del backup).
    if (existing != null && existing.updatedAt.isAfter(remoteUpdated)) {
      return false;
    }
    await _database
        .into(_database.waterLogs)
        .insertOnConflictUpdate(
          WaterLogsCompanion(
            id: Value(id),
            profileId: Value(marcoId),
            milliliters: Value(milliliters),
            loggedAt: Value(_time(p['logged_at']) ?? remoteUpdated),
            createdAt: Value(
              existing?.createdAt ?? _time(p['created_at']) ?? remoteUpdated,
            ),
            updatedAt: Value(remoteUpdated),
            deletedAt: Value(_time(p['deleted_at'])),
          ),
        );
    return true;
  }

  Future<bool> _applyBodyMeasurement(
    Map<String, Object?> p,
    String marcoId,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final weight = _double(p['weight_kg']);
    if (id.isEmpty || weight < 20 || weight > 500) {
      return false;
    }
    final existing = await (_database.select(
      _database.bodyMeasurements,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    final remoteUpdated = _time(p['updated_at']) ?? _now();
    // Conflitti: vince l'updated_at più recente (stessa regola del backup).
    if (existing != null && existing.updatedAt.isAfter(remoteUpdated)) {
      return false;
    }
    await _database
        .into(_database.bodyMeasurements)
        .insertOnConflictUpdate(
          BodyMeasurementsCompanion(
            id: Value(id),
            profileId: Value(marcoId),
            weightKg: Value(weight),
            measuredAt: Value(_time(p['measured_at']) ?? remoteUpdated),
            note: Value(_string(p['note'])),
            createdAt: Value(
              existing?.createdAt ?? _time(p['created_at']) ?? remoteUpdated,
            ),
            updatedAt: Value(remoteUpdated),
            deletedAt: Value(_time(p['deleted_at'])),
          ),
        );
    return true;
  }

  Future<bool> _applyFood(
    Map<String, Object?> p,
    String marcoId,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final name = _string(p['name']);
    if (id.isEmpty || name == null || name.isEmpty) {
      return false;
    }
    final existing = await (_database.select(
      _database.foods,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    final remoteUpdated = _time(p['updated_at']) ?? _now();
    // Conflitti: vince l'updated_at più recente (stessa regola del backup).
    if (existing != null && existing.updatedAt.isAfter(remoteUpdated)) {
      return false;
    }
    final serving = _double(p['serving_size_g']);
    await _database
        .into(_database.foods)
        .insertOnConflictUpdate(
          FoodsCompanion(
            id: Value(id),
            ownerProfileId: Value(existing?.ownerProfileId ?? marcoId),
            name: Value(name),
            brand: Value(_string(p['brand'])),
            barcode: Value(_string(p['barcode'])),
            caloriesPer100g: Value(_double(p['energy_kcal_per_100g'])),
            proteinPer100g: Value(_double(p['protein_g_per_100g'])),
            carbsPer100g: Value(_double(p['carbohydrate_g_per_100g'])),
            fatPer100g: Value(_double(p['fat_g_per_100g'])),
            defaultServingGrams: Value(serving > 0 ? serving : 100),
            source: Value(existing?.source ?? 'custom'),
            createdAt: Value(
              existing?.createdAt ?? _time(p['created_at']) ?? remoteUpdated,
            ),
            updatedAt: Value(remoteUpdated),
            deletedAt: Value(_time(p['deleted_at'])),
          ),
        );
    return true;
  }

  Future<bool> _applyRecipe(
    Map<String, Object?> p,
    String marcoId,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final name = _string(p['name']);
    if (id.isEmpty || name == null || name.isEmpty) {
      return false;
    }
    final existing = await (_database.select(
      _database.fitRecipes,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    final remoteUpdated = _time(p['updated_at']) ?? _now();
    // Conflitti: vince l'updated_at più recente (stessa regola del backup).
    if (existing != null && existing.updatedAt.isAfter(remoteUpdated)) {
      return false;
    }
    await _database
        .into(_database.fitRecipes)
        .insertOnConflictUpdate(
          FitRecipesCompanion(
            id: Value(id),
            profileId: Value(marcoId),
            name: Value(name),
            description: Value(_string(p['description'])),
            instructions: Value(_string(p['instructions'])),
            tags: Value(_string(p['tags'])),
            servings: Value(_int(p['servings']).clamp(1, 100)),
            prepMinutes: Value(_int(p['prep_minutes']).clamp(0, 10080)),
            totalCalories: Value(existing?.totalCalories ?? 0),
            totalProtein: Value(existing?.totalProtein ?? 0),
            totalCarbs: Value(existing?.totalCarbs ?? 0),
            totalFat: Value(existing?.totalFat ?? 0),
            isFavorite: Value(p['is_favorite'] == true),
            createdAt: Value(
              existing?.createdAt ?? _time(p['created_at']) ?? remoteUpdated,
            ),
            updatedAt: Value(remoteUpdated),
            deletedAt: Value(_time(p['deleted_at'])),
          ),
        );
    await _refreshRecipeTotals(id);
    return true;
  }

  Future<bool> _applyRecipeItem(
    Map<String, Object?> p,
    String operation,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final recipeId = localId(p['recipe_id']);
    if (id.isEmpty || recipeId.isEmpty) {
      return false;
    }
    if (operation == 'delete' || p['deleted_at'] != null) {
      // Localmente gli ingredienti non hanno tombstone: si eliminano.
      await (_database.delete(
        _database.recipeIngredients,
      )..where((t) => t.id.equals(id))).go();
      await _refreshRecipeTotals(recipeId);
      return true;
    }
    final recipe = await (_database.select(
      _database.fitRecipes,
    )..where((t) => t.id.equals(recipeId))).getSingleOrNull();
    if (recipe == null) {
      return false;
    }
    final grams = _double(p['quantity_g']);
    if (grams <= 0) {
      return false;
    }
    final position = _int(p['position']);
    await (_database.delete(_database.recipeIngredients)..where(
          (t) =>
              t.recipeId.equals(recipeId) &
              t.position.equals(position) &
              t.id.equals(id).not(),
        ))
        .go();
    await _database
        .into(_database.recipeIngredients)
        .insertOnConflictUpdate(
          RecipeIngredientsCompanion(
            id: Value(id),
            recipeId: Value(recipeId),
            foodId: const Value(null),
            position: Value(position),
            name: Value(_string(p['food_name_snapshot']) ?? 'Ingrediente'),
            grams: Value(grams),
            caloriesPer100g: Value(_double(p['energy_kcal_per_100g'])),
            proteinPer100g: Value(_double(p['protein_g_per_100g'])),
            carbsPer100g: Value(_double(p['carbohydrate_g_per_100g'])),
            fatPer100g: Value(_double(p['fat_g_per_100g'])),
          ),
        );
    await _refreshRecipeTotals(recipeId);
    return true;
  }

  Future<bool> _applyTemplate(
    Map<String, Object?> p,
    String marcoId,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final name = _string(p['name']);
    if (id.isEmpty || name == null || name.isEmpty) {
      return false;
    }
    final existing = await (_database.select(
      _database.mealTemplates,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    final remoteUpdated = _time(p['updated_at']) ?? _now();
    // Conflitti: vince l'updated_at più recente (stessa regola del backup).
    if (existing != null && existing.updatedAt.isAfter(remoteUpdated)) {
      return false;
    }
    await _database
        .into(_database.mealTemplates)
        .insertOnConflictUpdate(
          MealTemplatesCompanion(
            id: Value(id),
            profileId: Value(marcoId),
            name: Value(name),
            mealType: Value(_string(p['meal_type']) ?? 'snack'),
            createdAt: Value(
              existing?.createdAt ?? _time(p['created_at']) ?? remoteUpdated,
            ),
            updatedAt: Value(remoteUpdated),
            deletedAt: Value(_time(p['deleted_at'])),
          ),
        );
    return true;
  }

  Future<bool> _applyTemplateItem(
    Map<String, Object?> p,
    String operation,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final templateId = localId(p['template_id']);
    if (id.isEmpty || templateId.isEmpty) {
      return false;
    }
    if (operation == 'delete' || p['deleted_at'] != null) {
      await (_database.delete(
        _database.mealTemplateItems,
      )..where((t) => t.id.equals(id))).go();
      return true;
    }
    final template = await (_database.select(
      _database.mealTemplates,
    )..where((t) => t.id.equals(templateId))).getSingleOrNull();
    if (template == null) {
      return false;
    }
    final grams = _double(p['quantity_g']);
    if (grams <= 0) {
      return false;
    }
    final position = _int(p['position']);
    await (_database.delete(_database.mealTemplateItems)..where(
          (t) =>
              t.templateId.equals(templateId) &
              t.position.equals(position) &
              t.id.equals(id).not(),
        ))
        .go();
    await _database
        .into(_database.mealTemplateItems)
        .insertOnConflictUpdate(
          MealTemplateItemsCompanion(
            id: Value(id),
            templateId: Value(templateId),
            position: Value(position),
            foodName: Value(_string(p['food_name_snapshot']) ?? 'Voce'),
            grams: Value(grams),
            caloriesPer100g: Value(_double(p['energy_kcal_per_100g'])),
            proteinPer100g: Value(_double(p['protein_g_per_100g'])),
            carbsPer100g: Value(_double(p['carbohydrate_g_per_100g'])),
            fatPer100g: Value(_double(p['fat_g_per_100g'])),
          ),
        );
    return true;
  }

  /// Il server non conserva i totali delle ricette: si ricalcolano sempre
  /// dagli ingredienti con NutritionCalculator.scale.
  Future<void> _refreshRecipeTotals(String recipeId) async {
    final recipe = await (_database.select(
      _database.fitRecipes,
    )..where((t) => t.id.equals(recipeId))).getSingleOrNull();
    if (recipe == null) {
      return;
    }
    final ingredients = await (_database.select(
      _database.recipeIngredients,
    )..where((t) => t.recipeId.equals(recipeId))).get();
    var totals = const Nutrients.zero();
    for (final ingredient in ingredients) {
      totals =
          totals +
          NutritionCalculator.scale(
            per100g: Nutrients(
              calories: ingredient.caloriesPer100g,
              protein: ingredient.proteinPer100g,
              carbs: ingredient.carbsPer100g,
              fat: ingredient.fatPer100g,
            ),
            grams: ingredient.grams,
          );
    }
    await (_database.update(
      _database.fitRecipes,
    )..where((t) => t.id.equals(recipeId))).write(
      FitRecipesCompanion(
        totalCalories: Value(totals.calories),
        totalProtein: Value(totals.protein),
        totalCarbs: Value(totals.carbs),
        totalFat: Value(totals.fat),
      ),
    );
  }

  Map<String, Object?> _decodePayload(String json) {
    try {
      final decoded = jsonDecode(json);
      return decoded is Map<String, Object?> ? decoded : const {};
    } on Object {
      return const {};
    }
  }

  String? _string(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  double _double(Object? value) {
    final parsed = value is num ? value.toDouble() : 0.0;
    return parsed.isFinite ? parsed : 0.0;
  }

  int _int(Object? value) => value is num ? value.toInt() : 0;

  DateTime? _time(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toUtc() : null;
}

enum SyncPhase { disabled, signedOut, idle, syncing, error }

class SyncStatus {
  const SyncStatus({
    required this.phase,
    this.pendingCount = 0,
    this.lastSyncAt,
    this.error,
  });

  const SyncStatus.disabled()
    : phase = SyncPhase.disabled,
      pendingCount = 0,
      lastSyncAt = null,
      error = null;

  final SyncPhase phase;
  final int pendingCount;
  final DateTime? lastSyncAt;
  final String? error;

  SyncStatus copyWith({
    SyncPhase? phase,
    int? pendingCount,
    DateTime? lastSyncAt,
    String? error,
    bool clearError = false,
  }) => SyncStatus(
    phase: phase ?? this.phase,
    pendingCount: pendingCount ?? this.pendingCount,
    lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    error: clearError ? null : (error ?? this.error),
  );
}

final syncStateStoreProvider = Provider<SyncStateStore>(
  (ref) => SyncStateStore(),
);

/// Con AppConfig vuoto il motore non esiste proprio: l'app resta identica
/// alla versione solo-offline.
final syncEngineProvider = Provider<SyncEngine?>((ref) {
  final config = ref.watch(appConfigProvider);
  if (!config.hasSupabaseConfiguration) {
    return null;
  }
  return SyncEngine(
    database: ref.watch(databaseProvider),
    gateway: ref.watch(syncGatewayProvider),
    stateStore: ref.watch(syncStateStoreProvider),
  );
});

final syncDebounceProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 3),
);

class SyncController extends Notifier<SyncStatus> {
  Timer? _debounce;
  bool _disposed = false;

  @override
  SyncStatus build() {
    final engine = ref.watch(syncEngineProvider);
    if (engine == null) {
      return const SyncStatus.disabled();
    }
    _disposed = false;
    final subscription = engine.watchPendingCount().listen((count) {
      state = state.copyWith(pendingCount: count);
      if (count > 0) {
        _schedule();
      }
    });
    ref.onDispose(() {
      _disposed = true;
      subscription.cancel();
      _debounce?.cancel();
    });
    _loadInitial();
    // Sync silenziosa all'avvio, con lo stesso debounce delle scritture.
    _schedule();
    return const SyncStatus(phase: SyncPhase.idle);
  }

  Future<void> syncNow() {
    _debounce?.cancel();
    // Il comando manuale scavalca il backoff per-riga dell'outbox.
    return _runSync(ignoreBackoff: true);
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(ref.read(syncDebounceProvider), () {
      unawaited(_runSync());
    });
  }

  Future<void> _loadInitial() async {
    final stored = await ref.read(syncStateStoreProvider).read();
    if (_disposed || stored.lastSyncAt == null) {
      return;
    }
    state = state.copyWith(lastSyncAt: stored.lastSyncAt);
  }

  Future<void> _runSync({bool ignoreBackoff = false}) async {
    final engine = ref.read(syncEngineProvider);
    if (engine == null || _disposed) {
      return;
    }
    if (state.phase == SyncPhase.syncing) {
      return;
    }
    state = state.copyWith(phase: SyncPhase.syncing, clearError: true);
    final report = await engine.sync(ignoreBackoff: ignoreBackoff);
    if (_disposed) {
      return;
    }
    if (report.signedOut) {
      state = state.copyWith(phase: SyncPhase.signedOut, clearError: true);
      // La sessione non vale più: la schermata deve tornare all'accesso.
      ref.read(syncAuthProvider.notifier).sessionExpired();
    } else if (report.error != null) {
      state = state.copyWith(phase: SyncPhase.error, error: report.error);
    } else {
      state = state.copyWith(
        phase: SyncPhase.idle,
        lastSyncAt: report.completedAt,
        clearError: true,
      );
    }
  }
}

final syncControllerProvider = NotifierProvider<SyncController, SyncStatus>(
  SyncController.new,
);

/// Aggancio per l'avvio dell'app: istanzia il controller senza mai
/// notificare chi lo guarda (il notifier è stabile).
final syncBootstrapProvider = Provider<void>((ref) {
  ref.watch(syncControllerProvider.notifier);
});
