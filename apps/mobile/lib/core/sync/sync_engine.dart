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
      'profile',
      'meal_item',
      'water_log',
      'body_measurement',
      'food',
      'fit_recipe',
      'meal_template',
      // Gli slug `cd-*` dei preset di defaticamento non sono uuid: senza
      // l'alias il pull non ritroverebbe l'esercizio locale che i workout
      // citano come exercise_ref_id.
      'exercise',
      'routine',
      'workout',
      'workout_profile_stats',
      'daily_check_in',
      'goal',
      'training_profile',
      'training_limitation',
      'daily_health_summary',
      'coach_feed_item',
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
      case 'profiles':
        return _applyProfile(p, marcoId);
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
      case 'daily_check_ins':
        return _applyDailyCheckIn(p, marcoId, localId);
      case 'goals':
        return _applyGoal(p, marcoId, localId);
      case 'training_profiles':
        return _applyTrainingProfile(p, marcoId);
      case 'training_limitations':
        return _applyTrainingLimitation(p, marcoId, localId);
      case 'daily_health_summaries':
        return _applyDailyHealthSummary(p, marcoId, localId);
      case 'coach_feed_items':
        return _applyCoachFeedItem(p, marcoId, localId);
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
      case 'exercises':
        return _applyExercise(p, marcoId, localId);
      case 'routines':
        return _applyRoutine(p, marcoId, localId);
      case 'routine_exercises':
        return _applyRoutineExercise(p, change.operation, localId);
      case 'routine_interval_segments':
        return _applyRoutineSegment(p, change.operation, localId);
      case 'routine_weekly_plan':
        return _applyWeeklyPlanDay(p, change.operation, marcoId, localId);
      case 'workouts':
        return _applyWorkout(p, marcoId, localId);
      case 'workout_exercises':
        return _applyWorkoutExercise(p, change.operation, localId);
      case 'workout_sets':
        return _applyWorkoutSet(p, change.operation, localId);
      case 'workout_pain_points':
        return _applyPainPoint(p, change.operation, localId);
      case 'workout_interval_segments':
        return _applyWorkoutSegment(p, change.operation, localId);
      case 'workout_profile_stats':
        return _applyWorkoutStats(p, marcoId);
      case 'workout_achievements':
        return _applyAchievement(p, change.operation, marcoId, localId);
      case 'body_measurement_values':
        return _applyMeasurementValue(p, change.operation, localId);
      case 'body_impedance_readings':
        return _applyImpedanceReading(p, change.operation, localId);
      default:
        // external_workouts, meal_analysis_jobs: niente da fare.
        return false;
    }
  }

  Future<bool> _applyProfile(Map<String, Object?> p, String marcoId) async {
    if (p['deleted_at'] != null) {
      // Il profilo locale e' il padre di tutto il diario: un tombstone remoto
      // non puo' cancellare a cascata un'installazione ancora utilizzata.
      return false;
    }
    final existing = await (_database.select(
      _database.appProfiles,
    )..where((row) => row.id.equals(marcoId))).getSingleOrNull();
    if (existing == null) {
      return false;
    }
    final remoteUpdated = _time(p['updated_at']) ?? _now();
    if (existing.updatedAt.isAfter(remoteUpdated)) {
      return false;
    }
    final height = _nullableDouble(p['height_cm']);
    final sex = _oneOf(p['sex'], const {'M', 'F'});
    await (_database.update(
      _database.appProfiles,
    )..where((row) => row.id.equals(marcoId))).write(
      AppProfilesCompanion(
        displayName: Value(_string(p['display_name']) ?? existing.displayName),
        heightCm: Value(
          height != null && height >= 50 && height <= 260 ? height : null,
        ),
        birthDate: Value(_calendarDay(p['birth_date'])),
        sex: Value(sex),
        updatedAt: Value(remoteUpdated),
      ),
    );
    return true;
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
            hasImpedance: Value(p['has_impedance'] == true),
            impedanceOhm: Value(_boundedDouble(p['impedance_ohm'], 0.01, 2000)),
            bodyFatPct: Value(_boundedDouble(p['body_fat_pct'], 0, 100)),
            musclePct: Value(_boundedDouble(p['muscle_pct'], 0, 100)),
            skeletalMusclePct: Value(
              _boundedDouble(p['skeletal_muscle_pct'], 0, 100),
            ),
            bonePct: Value(_boundedDouble(p['bone_pct'], 0, 100)),
            proteinPct: Value(_boundedDouble(p['protein_pct'], 0, 100)),
            waterPct: Value(_boundedDouble(p['water_pct'], 0, 100)),
            subcutaneousFatPct: Value(
              _boundedDouble(p['subcutaneous_fat_pct'], 0, 100),
            ),
            visceralFatIndex: Value(
              _boundedInt(p['visceral_fat_index'], 1, 60),
            ),
            bmrKcal: Value(_boundedInt(p['bmr_kcal'], 1, 9999)),
            formulaVersion: Value(_string(p['formula_version'])),
            source: Value(_oneOf(p['source'], _measurementSources) ?? 'manual'),
            externalId: Value(_string(p['external_id'])),
            deviceModel: Value(_string(p['device_model'])),
            rawPayload: Value(_string(p['raw_payload'])),
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

  Future<bool> _applyDailyCheckIn(
    Map<String, Object?> p,
    String marcoId,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final day = _calendarDay(p['day']);
    if (id.isEmpty || day == null) {
      return false;
    }
    final existing = await (_database.select(
      _database.dailyCheckIns,
    )..where((row) => row.id.equals(id))).getSingleOrNull();
    final remoteUpdated = _time(p['updated_at']) ?? _now();
    if (existing != null && existing.updatedAt.isAfter(remoteUpdated)) {
      return false;
    }
    final deletedAt = _time(p['deleted_at']);
    final sleep = _boundedDouble(p['sleep_hours'], 0, 16);
    final energy = _boundedInt(p['energy_score'], 1, 5);
    final steps = _boundedInt(p['steps'], 0, 200000);
    final walkMinutes = _boundedInt(p['walk_minutes'], 0, 1440);
    if (deletedAt == null &&
        sleep == null &&
        energy == null &&
        steps == null &&
        walkMinutes == null) {
      return false;
    }
    await _database
        .into(_database.dailyCheckIns)
        .insertOnConflictUpdate(
          DailyCheckInsCompanion(
            id: Value(id),
            profileId: Value(marcoId),
            day: Value(day),
            sleepHours: Value(sleep),
            energyScore: Value(energy),
            steps: Value(steps),
            walkMinutes: Value(walkMinutes),
            createdAt: Value(
              existing?.createdAt ?? _time(p['created_at']) ?? remoteUpdated,
            ),
            updatedAt: Value(remoteUpdated),
            deletedAt: Value(deletedAt),
          ),
        );
    return true;
  }

  Future<bool> _applyGoal(
    Map<String, Object?> p,
    String marcoId,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final targetWeight = _boundedDouble(p['target_weight_kg'], 20, 500);
    final startWeight = _boundedDouble(p['start_weight_kg'], 20, 500);
    final startFfm = _boundedDouble(p['start_fat_free_mass_kg'], 0.01, 500);
    final pace = _boundedDouble(p['pace_kg_per_week'], 0.01, 5);
    final startedAt = _time(p['started_at']);
    final level = _oneOf(p['target_level'], _goalLevels);
    if (id.isEmpty ||
        targetWeight == null ||
        startWeight == null ||
        startFfm == null ||
        pace == null ||
        startedAt == null ||
        level == null) {
      return false;
    }
    final existing = await (_database.select(
      _database.goals,
    )..where((row) => row.id.equals(id))).getSingleOrNull();
    final remoteUpdated = _time(p['updated_at']) ?? _now();
    if (existing != null && existing.updatedAt.isAfter(remoteUpdated)) {
      return false;
    }
    final phase = _oneOf(p['phase'], _goalPhases) ?? 'approach';
    final outcome = _oneOf(p['outcome'], _goalOutcomes);
    final closedAt = _time(p['closed_at']);
    if (outcome != null && closedAt == null) {
      return false;
    }
    await _database
        .into(_database.goals)
        .insertOnConflictUpdate(
          GoalsCompanion(
            id: Value(id),
            profileId: Value(marcoId),
            targetWeightKg: Value(targetWeight),
            targetLevel: Value(level),
            paceKgPerWeek: Value(pace),
            startedAt: Value(startedAt),
            startWeightKg: Value(startWeight),
            startFatFreeMassKg: Value(startFfm),
            phase: Value(phase),
            phaseStartedAt: Value(_time(p['phase_started_at'])),
            closedAt: Value(closedAt),
            outcome: Value(outcome),
            createdAt: Value(
              existing?.createdAt ?? _time(p['created_at']) ?? remoteUpdated,
            ),
            updatedAt: Value(remoteUpdated),
            deletedAt: Value(_time(p['deleted_at'])),
          ),
        );
    return true;
  }

  Future<bool> _applyTrainingProfile(
    Map<String, Object?> p,
    String marcoId,
  ) async {
    if (p['deleted_at'] != null) {
      await (_database.delete(
        _database.trainingProfiles,
      )..where((row) => row.profileId.equals(marcoId))).go();
      return true;
    }
    final existing = await (_database.select(
      _database.trainingProfiles,
    )..where((row) => row.profileId.equals(marcoId))).getSingleOrNull();
    final remoteUpdated = _time(p['updated_at']) ?? _now();
    if (existing != null && existing.updatedAt.isAfter(remoteUpdated)) {
      return false;
    }
    await _database
        .into(_database.trainingProfiles)
        .insertOnConflictUpdate(
          TrainingProfilesCompanion(
            profileId: Value(marcoId),
            equipment: Value(_string(p['equipment']) ?? ''),
            sessionsPerWeek: Value(_boundedInt(p['sessions_per_week'], 1, 14)),
            minutesPerSession: Value(
              _boundedInt(p['minutes_per_session'], 10, 300),
            ),
            preferredDays: Value(_string(p['preferred_days']) ?? ''),
            deloadPreference: Value(
              _oneOf(p['deload_preference'], const {
                    'automatico',
                    'suggerito',
                  }) ??
                  'suggerito',
            ),
            createdAt: Value(
              existing?.createdAt ?? _time(p['created_at']) ?? remoteUpdated,
            ),
            updatedAt: Value(remoteUpdated),
          ),
        );
    return true;
  }

  Future<bool> _applyTrainingLimitation(
    Map<String, Object?> p,
    String marcoId,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    if (id.isEmpty) {
      return false;
    }
    final existing = await (_database.select(
      _database.trainingLimitations,
    )..where((row) => row.id.equals(id))).getSingleOrNull();
    final remoteUpdated = _time(p['updated_at']) ?? _now();
    if (existing != null && existing.updatedAt.isAfter(remoteUpdated)) {
      return false;
    }
    final bodyPart = _oneOf(p['body_part'], _limitationBodyParts);
    final severity = _oneOf(p['severity'], const {
      'fastidio',
      'dolore',
      'stop',
    });
    final startedAt = _time(p['started_at']);
    if (bodyPart == null || severity == null || startedAt == null) {
      return false;
    }
    await _database
        .into(_database.trainingLimitations)
        .insertOnConflictUpdate(
          TrainingLimitationsCompanion(
            id: Value(id),
            profileId: Value(marcoId),
            bodyPart: Value(bodyPart),
            severity: Value(severity),
            note: Value(_string(p['note'])),
            startedAt: Value(startedAt),
            resolvedAt: Value(_time(p['resolved_at'])),
            createdAt: Value(
              existing?.createdAt ?? _time(p['created_at']) ?? remoteUpdated,
            ),
            updatedAt: Value(remoteUpdated),
            deletedAt: Value(_time(p['deleted_at'])),
          ),
        );
    return true;
  }

  Future<bool> _applyDailyHealthSummary(
    Map<String, Object?> p,
    String marcoId,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final day = _calendarDay(p['day']);
    final source = _string(p['source']);
    if (id.isEmpty || day == null || source == null || source.length > 40) {
      return false;
    }
    final existing = await (_database.select(
      _database.dailyHealthSummaries,
    )..where((row) => row.id.equals(id))).getSingleOrNull();
    final remoteUpdated = _time(p['updated_at']) ?? _now();
    if (existing != null && existing.updatedAt.isAfter(remoteUpdated)) {
      return false;
    }
    final deletedAt = _time(p['deleted_at']);
    final steps = _boundedInt(p['steps'], 0, 200000);
    final sleepMinutes = _boundedInt(p['sleep_minutes'], 0, 1440);
    final restingHeartRate = _boundedInt(p['resting_heart_rate'], 20, 250);
    if (deletedAt == null &&
        steps == null &&
        sleepMinutes == null &&
        restingHeartRate == null) {
      return false;
    }
    await _database
        .into(_database.dailyHealthSummaries)
        .insertOnConflictUpdate(
          DailyHealthSummariesCompanion(
            id: Value(id),
            profileId: Value(marcoId),
            day: Value(day),
            source: Value(source),
            externalId: Value(_string(p['external_id'])),
            steps: Value(steps),
            sleepMinutes: Value(sleepMinutes),
            restingHeartRate: Value(restingHeartRate),
            createdAt: Value(
              existing?.createdAt ?? _time(p['created_at']) ?? remoteUpdated,
            ),
            updatedAt: Value(remoteUpdated),
            deletedAt: Value(deletedAt),
          ),
        );
    return true;
  }

  Future<bool> _applyCoachFeedItem(
    Map<String, Object?> p,
    String marcoId,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final kind = _string(p['kind']);
    final source = _oneOf(p['source'], const {'deterministic', 'ai'});
    final title = _string(p['title']);
    final body = _string(p['body']);
    final occurredAt = _time(p['occurred_at']);
    if (id.isEmpty ||
        kind == null ||
        source == null ||
        title == null ||
        body == null ||
        occurredAt == null) {
      return false;
    }
    final existing = await (_database.select(
      _database.coachFeedItems,
    )..where((row) => row.id.equals(id))).getSingleOrNull();
    final remoteUpdated = _time(p['updated_at']) ?? _now();
    if (existing != null && existing.updatedAt.isAfter(remoteUpdated)) {
      return false;
    }
    await _database
        .into(_database.coachFeedItems)
        .insertOnConflictUpdate(
          CoachFeedItemsCompanion(
            id: Value(id),
            profileId: Value(marcoId),
            kind: Value(kind),
            source: Value(source),
            externalId: Value(_string(p['external_id'])),
            title: Value(title),
            body: Value(body),
            actionLabel: Value(_string(p['action_label'])),
            actionPath: Value(_string(p['action_path'])),
            occurredAt: Value(occurredAt),
            readAt: Value(_time(p['read_at'])),
            dismissedAt: Value(_time(p['dismissed_at'])),
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

  Future<bool> _applyExercise(
    Map<String, Object?> p,
    String marcoId,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final name = _string(p['name']);
    final muscleGroup = _oneOf(p['muscle_group'], _muscleGroups);
    final trackingMode = _oneOf(p['tracking_mode'], _trackingModes);
    if (id.isEmpty ||
        name == null ||
        muscleGroup == null ||
        trackingMode == null) {
      return false;
    }
    final existing = await (_database.select(
      _database.exercises,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    final remoteUpdated = _time(p['updated_at']) ?? _now();
    // Conflitti: vince l'updated_at più recente (stessa regola del backup).
    if (existing != null && existing.updatedAt.isAfter(remoteUpdated)) {
      return false;
    }
    final source = _oneOf(p['source'], _exerciseSources) ?? 'manual';
    final externalId = _string(p['external_id']);
    if (await _sourceKeyTaken(id: id, source: source, externalId: externalId)) {
      return false;
    }
    await _database
        .into(_database.exercises)
        .insertOnConflictUpdate(
          ExercisesCompanion(
            id: Value(id),
            profileId: Value(marcoId),
            name: Value(name),
            muscleGroup: Value(muscleGroup),
            trackingMode: Value(trackingMode),
            notes: Value(_string(p['notes'])),
            imageUrl: Value(_string(p['image_url'])),
            defaultRestSec: Value(_nullableInt(p['default_rest_sec'])),
            isPreset: Value(p['is_preset'] == true),
            isSynthetic: Value(p['is_synthetic'] == true),
            source: Value(source),
            externalId: Value(externalId),
            createdAt: Value(
              existing?.createdAt ?? _time(p['created_at']) ?? remoteUpdated,
            ),
            updatedAt: Value(remoteUpdated),
            deletedAt: Value(_time(p['deleted_at'])),
          ),
        );
    return true;
  }

  /// La UNIQUE (profile_id, source, external_id) deduplica le importazioni:
  /// una riga remota che la violerebbe si salta invece di far esplodere la
  /// scrittura locale, che bloccherebbe il pull su quel cursore per sempre.
  Future<bool> _sourceKeyTaken({
    required String id,
    required String source,
    required String? externalId,
  }) async {
    if (externalId == null) {
      return false;
    }
    final clash =
        await (_database.select(_database.exercises)..where(
              (t) =>
                  t.source.equals(source) &
                  t.externalId.equals(externalId) &
                  t.id.equals(id).not(),
            ))
            .getSingleOrNull();
    return clash != null;
  }

  Future<bool> _applyRoutine(
    Map<String, Object?> p,
    String marcoId,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final name = _string(p['name']);
    if (id.isEmpty || name == null) {
      return false;
    }
    final existing = await (_database.select(
      _database.routines,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    final remoteUpdated = _time(p['updated_at']) ?? _now();
    // Conflitti: vince l'updated_at più recente (stessa regola del backup).
    if (existing != null && existing.updatedAt.isAfter(remoteUpdated)) {
      return false;
    }
    await _database
        .into(_database.routines)
        .insertOnConflictUpdate(
          RoutinesCompanion(
            id: Value(id),
            profileId: Value(marcoId),
            name: Value(name),
            notes: Value(_string(p['notes'])),
            isCircuit: Value(p['is_circuit'] == true),
            workSec: Value(_intOr(p['work_sec'], 30)),
            shortRestSec: Value(_intOr(p['short_rest_sec'], 30)),
            longRestSec: Value(_intOr(p['long_rest_sec'], 60)),
            rounds: Value(_intOr(p['rounds'], 3)),
            warmupWorkSec: Value(_intOr(p['warmup_work_sec'], 30)),
            warmupRestSec: Value(_intOr(p['warmup_rest_sec'], 15)),
            source: Value(_oneOf(p['source'], _workoutSources) ?? 'manual'),
            externalId: Value(_string(p['external_id'])),
            createdAt: Value(
              existing?.createdAt ?? _time(p['created_at']) ?? remoteUpdated,
            ),
            updatedAt: Value(remoteUpdated),
            deletedAt: Value(_time(p['deleted_at'])),
          ),
        );
    return true;
  }

  Future<bool> _applyRoutineExercise(
    Map<String, Object?> p,
    String operation,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final routineId = localId(p['routine_id']);
    if (id.isEmpty || routineId.isEmpty) {
      return false;
    }
    if (_isTombstone(operation, p)) {
      // I figli localmente non hanno tombstone: si eliminano.
      await (_database.delete(
        _database.routineExercises,
      )..where((t) => t.id.equals(id))).go();
      return true;
    }
    final routine = await (_database.select(
      _database.routines,
    )..where((t) => t.id.equals(routineId))).getSingleOrNull();
    final block = _oneOf(p['block'], _blocks);
    final refId = localId(p['exercise_ref_id']);
    final name = _string(p['exercise_name_snapshot']);
    if (routine == null || block == null || refId.isEmpty || name == null) {
      return false;
    }
    final position = _int(p['position']);
    await (_database.delete(_database.routineExercises)..where(
          (t) =>
              t.routineId.equals(routineId) &
              t.block.equals(block) &
              t.position.equals(position) &
              t.id.equals(id).not(),
        ))
        .go();
    await _database
        .into(_database.routineExercises)
        .insertOnConflictUpdate(
          RoutineExercisesCompanion(
            id: Value(id),
            routineId: Value(routineId),
            block: Value(block),
            position: Value(position),
            exerciseRefId: Value(refId),
            exerciseId: Value(await _liveExerciseId(p['exercise_id'], localId)),
            exerciseNameSnapshot: Value(name),
            inSupersetWithPrevious: Value(
              position > 0 &&
                  block == 'main' &&
                  p['in_superset_with_previous'] == true,
            ),
            // Il CHECK lega la durata al blocco: un passo di riscaldamento la
            // ha sempre, gli altri blocchi mai.
            warmupDurationSec: Value(
              block == 'warmup' ? _intOr(p['warmup_duration_sec'], 30) : null,
            ),
            prescSets: Value(_nullableInt(p['presc_sets'])),
            prescReps: Value(_nullableInt(p['presc_reps'])),
            prescDurationSec: Value(_nullableInt(p['presc_duration_sec'])),
            prescRestSec: Value(_nullableInt(p['presc_rest_sec'])),
          ),
        );
    return true;
  }

  Future<bool> _applyRoutineSegment(
    Map<String, Object?> p,
    String operation,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final routineId = localId(p['routine_id']);
    if (id.isEmpty || routineId.isEmpty) {
      return false;
    }
    if (_isTombstone(operation, p)) {
      await (_database.delete(
        _database.routineIntervalSegments,
      )..where((t) => t.id.equals(id))).go();
      return true;
    }
    final routine = await (_database.select(
      _database.routines,
    )..where((t) => t.id.equals(routineId))).getSingleOrNull();
    final startIdx = _int(p['start_idx']);
    final endIdx = _int(p['end_idx']);
    if (routine == null || startIdx < 0 || endIdx <= startIdx) {
      return false;
    }
    final segmentIndex = _int(p['segment_index']);
    await (_database.delete(_database.routineIntervalSegments)..where(
          (t) =>
              t.routineId.equals(routineId) &
              t.segmentIndex.equals(segmentIndex) &
              t.id.equals(id).not(),
        ))
        .go();
    await _database
        .into(_database.routineIntervalSegments)
        .insertOnConflictUpdate(
          RoutineIntervalSegmentsCompanion(
            id: Value(id),
            routineId: Value(routineId),
            segmentIndex: Value(segmentIndex),
            startIdx: Value(startIdx),
            endIdx: Value(endIdx),
            workSec: Value(_intOr(p['work_sec'], 40)),
            restSec: Value(_intOr(p['rest_sec'], 20)),
            longRestSec: Value(_intOr(p['long_rest_sec'], 0)),
            rounds: Value(_intOr(p['rounds'], 1)),
          ),
        );
    return true;
  }

  Future<bool> _applyWeeklyPlanDay(
    Map<String, Object?> p,
    String operation,
    String marcoId,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final weekday = _int(p['weekday']);
    if (id.isEmpty || weekday < 1 || weekday > 7) {
      return false;
    }
    if (_isTombstone(operation, p)) {
      // Il giorno assente È l'informazione: riposo.
      await (_database.delete(
        _database.routineWeeklyPlan,
      )..where((t) => t.id.equals(id))).go();
      return true;
    }
    final existing = await (_database.select(
      _database.routineWeeklyPlan,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    final remoteUpdated = _time(p['updated_at']) ?? _now();
    // Conflitti: vince l'updated_at più recente (stessa regola del backup).
    if (existing != null && existing.updatedAt.isAfter(remoteUpdated)) {
      return false;
    }
    final externalId = _string(p['routine_external_id']);
    await (_database.delete(_database.routineWeeklyPlan)..where(
          (t) =>
              t.profileId.equals(marcoId) &
              t.weekday.equals(weekday) &
              t.id.equals(id).not(),
        ))
        .go();
    await _database
        .into(_database.routineWeeklyPlan)
        .insertOnConflictUpdate(
          RoutineWeeklyPlanCompanion(
            id: Value(id),
            profileId: Value(marcoId),
            weekday: Value(weekday),
            routineId: Value(await _liveRoutineId(p['routine_id'], localId)),
            routineExternalId: Value(
              externalId == null ? null : localId(externalId),
            ),
            routineNameSnapshot: Value(_string(p['routine_name_snapshot'])),
            updatedAt: Value(remoteUpdated),
          ),
        );
    return true;
  }

  Future<bool> _applyWorkout(
    Map<String, Object?> p,
    String marcoId,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final startedAt = _time(p['started_at']);
    if (id.isEmpty || startedAt == null) {
      return false;
    }
    final existing = await (_database.select(
      _database.workouts,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    final remoteUpdated = _time(p['updated_at']) ?? _now();
    // Conflitti: vince l'updated_at più recente (stessa regola del backup).
    if (existing != null && existing.updatedAt.isAfter(remoteUpdated)) {
      return false;
    }
    final endedAt = _time(p['ended_at']);
    final deletedAt = _time(p['deleted_at']);
    if (endedAt == null &&
        deletedAt == null &&
        await _hasOtherOpenWorkout(marcoId, id)) {
      // Una sola sessione aperta per profilo: è un indice unico parziale, e
      // insistere farebbe fallire ogni pull successivo sullo stesso cursore.
      return false;
    }
    final checkpoint = p['circuit_checkpoint'];
    await _database
        .into(_database.workouts)
        .insertOnConflictUpdate(
          WorkoutsCompanion(
            id: Value(id),
            profileId: Value(marcoId),
            startedAt: Value(startedAt),
            endedAt: Value(
              endedAt != null && endedAt.isBefore(startedAt) ? null : endedAt,
            ),
            pausedAt: Value(endedAt == null ? _time(p['paused_at']) : null),
            accumulatedPauseSeconds: Value(
              _intOr(p['accumulated_pause_seconds'], 0),
            ),
            finalDurationSeconds: Value(
              _nullableInt(p['final_duration_seconds']),
            ),
            durationSuspect: Value(p['duration_suspect'] == true),
            routineId: Value(await _liveRoutineId(p['routine_id'], localId)),
            routineExternalId: Value(
              _string(p['routine_external_id']) == null
                  ? null
                  : localId(p['routine_external_id']),
            ),
            routineNameSnapshot: Value(_string(p['routine_name_snapshot'])),
            notes: Value(_string(p['notes'])),
            totalKcal: Value(_nullableDouble(p['total_kcal'])),
            mood: Value(_nullableInt(p['mood'])),
            rpe: Value(_nullableInt(p['rpe'])),
            satisfaction: Value(_nullableInt(p['satisfaction'])),
            feedbackNotes: Value(_string(p['feedback_notes'])),
            xpEarned: Value(_nullableInt(p['xp_earned'])),
            resumePath: Value(_string(p['resume_path'])),
            // Locale la colonna è testo: il jsonb remoto torna serializzato,
            // non appiattito in una stringa di `toString()`.
            circuitCheckpointJson: Value(
              checkpoint is Map ? jsonEncode(checkpoint) : null,
            ),
            syncedToHealthConnect: Value(p['synced_to_health_connect'] == true),
            healthSyncState: Value(
              _oneOf(p['health_sync_state'], _healthSyncStates),
            ),
            healthSyncClaimId: Value(_string(p['health_sync_claim_id'])),
            healthSyncAttemptedAt: Value(_time(p['health_sync_attempted_at'])),
            healthSyncCompletedAt: Value(_time(p['health_sync_completed_at'])),
            source: Value(_oneOf(p['source'], _workoutSources) ?? 'manual'),
            externalId: Value(_string(p['external_id'])),
            createdAt: Value(
              existing?.createdAt ?? _time(p['created_at']) ?? remoteUpdated,
            ),
            updatedAt: Value(remoteUpdated),
            deletedAt: Value(deletedAt),
          ),
        );
    return true;
  }

  Future<bool> _hasOtherOpenWorkout(String profileId, String id) async {
    final open =
        await (_database.select(_database.workouts)..where(
              (t) =>
                  t.profileId.equals(profileId) &
                  t.endedAt.isNull() &
                  t.deletedAt.isNull() &
                  t.id.equals(id).not(),
            ))
            .get();
    return open.isNotEmpty;
  }

  Future<bool> _applyWorkoutExercise(
    Map<String, Object?> p,
    String operation,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final workoutId = localId(p['workout_id']);
    if (id.isEmpty || workoutId.isEmpty) {
      return false;
    }
    if (_isTombstone(operation, p)) {
      await (_database.delete(
        _database.workoutExercises,
      )..where((t) => t.id.equals(id))).go();
      return true;
    }
    final workout = await (_database.select(
      _database.workouts,
    )..where((t) => t.id.equals(workoutId))).getSingleOrNull();
    final refId = localId(p['exercise_ref_id']);
    final name = _string(p['exercise_name_snapshot']);
    final trackingMode = _oneOf(p['tracking_mode'], _trackingModes);
    if (workout == null ||
        refId.isEmpty ||
        name == null ||
        trackingMode == null) {
      return false;
    }
    final position = _int(p['position']);
    final isWarmup = p['is_warmup'] == true;
    final isCooldown = !isWarmup && p['is_cooldown'] == true;
    await (_database.delete(_database.workoutExercises)..where(
          (t) =>
              t.workoutId.equals(workoutId) &
              t.position.equals(position) &
              t.id.equals(id).not(),
        ))
        .go();
    await _database
        .into(_database.workoutExercises)
        .insertOnConflictUpdate(
          WorkoutExercisesCompanion(
            id: Value(id),
            workoutId: Value(workoutId),
            position: Value(position),
            exerciseRefId: Value(refId),
            exerciseId: Value(await _liveExerciseId(p['exercise_id'], localId)),
            exerciseNameSnapshot: Value(name),
            trackingMode: Value(trackingMode),
            muscleGroupSnapshot: Value(
              _oneOf(p['muscle_group_snapshot'], _muscleGroups),
            ),
            restSeconds: Value(_nullableInt(p['rest_seconds'])),
            // I tre blocchi sono esclusivi: il CHECK locale li conta.
            isWarmup: Value(isWarmup),
            isCooldown: Value(isCooldown),
            isFinisher: Value(
              !isWarmup && !isCooldown && p['is_finisher'] == true,
            ),
            isInSupersetWithPrevious: Value(
              position > 0 && p['is_in_superset_with_previous'] == true,
            ),
            intervalSegmentIndex: Value(
              _nullableInt(p['interval_segment_index']),
            ),
          ),
        );
    return true;
  }

  Future<bool> _applyWorkoutSet(
    Map<String, Object?> p,
    String operation,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final exerciseRowId = localId(p['workout_exercise_id']);
    if (id.isEmpty || exerciseRowId.isEmpty) {
      return false;
    }
    if (_isTombstone(operation, p)) {
      await (_database.delete(
        _database.workoutSets,
      )..where((t) => t.id.equals(id))).go();
      return true;
    }
    final parent = await (_database.select(
      _database.workoutExercises,
    )..where((t) => t.id.equals(exerciseRowId))).getSingleOrNull();
    if (parent == null) {
      return false;
    }
    final position = _int(p['position']);
    await (_database.delete(_database.workoutSets)..where(
          (t) =>
              t.workoutExerciseId.equals(exerciseRowId) &
              t.position.equals(position) &
              t.id.equals(id).not(),
        ))
        .go();
    await _database
        .into(_database.workoutSets)
        .insertOnConflictUpdate(
          WorkoutSetsCompanion(
            id: Value(id),
            workoutExerciseId: Value(exerciseRowId),
            position: Value(position),
            // Metrica GREZZA: «non inserito» e «zero» restano valori diversi.
            weightKg: Value(_nullableDouble(p['weight_kg'])),
            reps: Value(_nullableInt(p['reps'])),
            durationSec: Value(_nullableInt(p['duration_sec'])),
            distanceM: Value(_nullableDouble(p['distance_m'])),
            rpe: Value(_nullableInt(p['rpe'])),
            isWarmup: Value(p['is_warmup'] == true),
            completed: Value(p['completed'] == true),
          ),
        );
    return true;
  }

  Future<bool> _applyPainPoint(
    Map<String, Object?> p,
    String operation,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final workoutId = localId(p['workout_id']);
    if (id.isEmpty || workoutId.isEmpty) {
      return false;
    }
    if (_isTombstone(operation, p)) {
      await (_database.delete(
        _database.workoutPainPoints,
      )..where((t) => t.id.equals(id))).go();
      return true;
    }
    final workout = await (_database.select(
      _database.workouts,
    )..where((t) => t.id.equals(workoutId))).getSingleOrNull();
    final label = _string(p['label']);
    if (workout == null || label == null) {
      return false;
    }
    await (_database.delete(_database.workoutPainPoints)..where(
          (t) =>
              t.workoutId.equals(workoutId) &
              t.label.equals(label) &
              t.id.equals(id).not(),
        ))
        .go();
    await _database
        .into(_database.workoutPainPoints)
        .insertOnConflictUpdate(
          WorkoutPainPointsCompanion(
            id: Value(id),
            workoutId: Value(workoutId),
            label: Value(label),
          ),
        );
    return true;
  }

  Future<bool> _applyWorkoutSegment(
    Map<String, Object?> p,
    String operation,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final workoutId = localId(p['workout_id']);
    if (id.isEmpty || workoutId.isEmpty) {
      return false;
    }
    if (_isTombstone(operation, p)) {
      await (_database.delete(
        _database.workoutIntervalSegments,
      )..where((t) => t.id.equals(id))).go();
      return true;
    }
    final workout = await (_database.select(
      _database.workouts,
    )..where((t) => t.id.equals(workoutId))).getSingleOrNull();
    final completed = p['completed_marker'] == true;
    final partial = p['partial_marker'] == true;
    // I due marker sono indipendenti, ma una riga senza nessuno dei due non è
    // un dato: il CHECK locale la rifiuterebbe.
    if (workout == null || (!completed && !partial)) {
      return false;
    }
    final segmentIndex = _int(p['segment_index']);
    await (_database.delete(_database.workoutIntervalSegments)..where(
          (t) =>
              t.workoutId.equals(workoutId) &
              t.segmentIndex.equals(segmentIndex) &
              t.id.equals(id).not(),
        ))
        .go();
    await _database
        .into(_database.workoutIntervalSegments)
        .insertOnConflictUpdate(
          WorkoutIntervalSegmentsCompanion(
            id: Value(id),
            workoutId: Value(workoutId),
            segmentIndex: Value(segmentIndex),
            completedMarker: Value(completed),
            partialMarker: Value(partial),
            completionSignature: Value(
              completed ? _string(p['completion_signature']) : null,
            ),
          ),
        );
    return true;
  }

  Future<bool> _applyWorkoutStats(
    Map<String, Object?> p,
    String marcoId,
  ) async {
    // La riga è un singleton per profilo: l'id locale già presente vince su
    // quello remoto, o la UNIQUE (profile_id) farebbe fallire l'insert.
    final existing = await (_database.select(
      _database.workoutProfileStats,
    )..where((t) => t.profileId.equals(marcoId))).getSingleOrNull();
    final id = existing?.id ?? _string(p['id']);
    if (id == null || id.isEmpty) {
      return false;
    }
    final remoteUpdated = _time(p['updated_at']) ?? _now();
    // Conflitti: vince l'updated_at più recente (stessa regola del backup).
    if (existing != null && existing.updatedAt.isAfter(remoteUpdated)) {
      return false;
    }
    final currentStreak = _intOr(p['current_streak'], 0);
    await _database
        .into(_database.workoutProfileStats)
        .insertOnConflictUpdate(
          WorkoutProfileStatsCompanion(
            id: Value(id),
            profileId: Value(marcoId),
            totalXp: Value(_intOr(p['total_xp'], 0)),
            currentStreak: Value(currentStreak),
            longestStreak: Value(
              math.max(_intOr(p['longest_streak'], 0), currentStreak),
            ),
            // Colonna remota `date`: si rilegge come mezzanotte di Roma, o il
            // giorno tornerebbe indietro di due ore a ogni giro.
            lastWorkoutDay: Value(_calendarDay(p['last_workout_day'])),
            weeklyWorkoutGoal: Value(_intOr(p['weekly_workout_goal'], 3)),
            weeklyKcalGoal: Value(_intOr(p['weekly_kcal_goal'], 1500)),
            reminderEnabled: Value(p['reminder_enabled'] == true),
            reminderHour: Value(_intOr(p['reminder_hour'], 18)),
            reminderMinute: Value(_intOr(p['reminder_minute'], 0)),
            healthConnectEnabled: Value(p['health_connect_enabled'] == true),
            voiceEnabled: Value(p['voice_enabled'] != false),
            gymBodyWeightKg: Value(_nullableDouble(p['gym_body_weight_kg'])),
            gymExportedAt: Value(_time(p['gym_exported_at'])),
            createdAt: Value(
              existing?.createdAt ?? _time(p['created_at']) ?? remoteUpdated,
            ),
            updatedAt: Value(remoteUpdated),
            deletedAt: Value(_time(p['deleted_at'])),
          ),
        );
    return true;
  }

  Future<bool> _applyAchievement(
    Map<String, Object?> p,
    String operation,
    String marcoId,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final slug = _string(p['slug']);
    if (id.isEmpty || slug == null) {
      return false;
    }
    if (_isTombstone(operation, p)) {
      await (_database.delete(
        _database.workoutAchievements,
      )..where((t) => t.id.equals(id))).go();
      return true;
    }
    await (_database.delete(_database.workoutAchievements)..where(
          (t) =>
              t.profileId.equals(marcoId) &
              t.slug.equals(slug) &
              t.id.equals(id).not(),
        ))
        .go();
    await _database
        .into(_database.workoutAchievements)
        .insertOnConflictUpdate(
          WorkoutAchievementsCompanion(
            id: Value(id),
            profileId: Value(marcoId),
            slug: Value(slug),
            unlockedAt: Value(_time(p['unlocked_at'])),
          ),
        );
    return true;
  }

  Future<bool> _applyMeasurementValue(
    Map<String, Object?> p,
    String operation,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final measurementId = localId(p['measurement_id']);
    if (id.isEmpty || measurementId.isEmpty) {
      return false;
    }
    if (_isTombstone(operation, p)) {
      await (_database.delete(
        _database.bodyMeasurementValues,
      )..where((t) => t.id.equals(id))).go();
      return true;
    }
    final measurement = await (_database.select(
      _database.bodyMeasurements,
    )..where((t) => t.id.equals(measurementId))).getSingleOrNull();
    final label = _string(p['label']);
    final value = _double(p['value']);
    if (measurement == null || label == null || value <= 0 || value > 1000) {
      return false;
    }
    await (_database.delete(_database.bodyMeasurementValues)..where(
          (t) =>
              t.measurementId.equals(measurementId) &
              t.label.equals(label) &
              t.id.equals(id).not(),
        ))
        .go();
    await _database
        .into(_database.bodyMeasurementValues)
        .insertOnConflictUpdate(
          BodyMeasurementValuesCompanion(
            id: Value(id),
            measurementId: Value(measurementId),
            label: Value(label),
            value: Value(value),
          ),
        );
    return true;
  }

  Future<bool> _applyImpedanceReading(
    Map<String, Object?> p,
    String operation,
    String Function(Object?) localId,
  ) async {
    final id = localId(p['id']);
    final measurementId = localId(p['measurement_id']);
    if (id.isEmpty || measurementId.isEmpty) {
      return false;
    }
    if (_isTombstone(operation, p)) {
      await (_database.delete(
        _database.bodyImpedanceReadings,
      )..where((row) => row.id.equals(id))).go();
      return true;
    }
    final measurement = await (_database.select(
      _database.bodyMeasurements,
    )..where((row) => row.id.equals(measurementId))).getSingleOrNull();
    final segment = _oneOf(p['segment'], _impedanceSegments);
    final frequency = _boundedInt(p['frequency_hz'], 1, 10000000);
    final ohm = _boundedDouble(p['ohm'], 0.01, 5000);
    if (measurement == null || segment == null || ohm == null) {
      return false;
    }
    // La chiave naturale e' piu forte dell'id remoto: uno swap dopo un retry
    // non deve lasciare due letture dello stesso segmento/frequenza.
    await (_database.delete(_database.bodyImpedanceReadings)..where(
          (row) =>
              row.measurementId.equals(measurementId) &
              row.segment.equals(segment) &
              (frequency == null
                  ? row.frequencyHz.isNull()
                  : row.frequencyHz.equals(frequency)) &
              row.id.equals(id).not(),
        ))
        .go();
    await _database
        .into(_database.bodyImpedanceReadings)
        .insertOnConflictUpdate(
          BodyImpedanceReadingsCompanion(
            id: Value(id),
            measurementId: Value(measurementId),
            segment: Value(segment),
            frequencyHz: Value(frequency),
            ohm: Value(ohm),
          ),
        );
    return true;
  }

  /// La FK viva vale solo se l'esercizio esiste già qui: `exercise_ref_id`
  /// conserva comunque l'id originale, che è la chiave di raggruppamento.
  Future<String?> _liveExerciseId(
    Object? remoteValue,
    String Function(Object?) localId,
  ) async {
    if (_string(remoteValue) == null) {
      return null;
    }
    final id = localId(remoteValue);
    final row = await (_database.select(
      _database.exercises,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : id;
  }

  Future<String?> _liveRoutineId(
    Object? remoteValue,
    String Function(Object?) localId,
  ) async {
    if (_string(remoteValue) == null) {
      return null;
    }
    final id = localId(remoteValue);
    final row = await (_database.select(
      _database.routines,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : id;
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

  int _intOr(Object? value, int fallback) =>
      value is num && value.toDouble().isFinite ? value.toInt() : fallback;

  int? _nullableInt(Object? value) =>
      value is num && value.toDouble().isFinite ? value.toInt() : null;

  double? _nullableDouble(Object? value) =>
      value is num && value.toDouble().isFinite ? value.toDouble() : null;

  int? _boundedInt(Object? value, int minimum, int maximum) {
    final parsed = _nullableInt(value);
    return parsed != null && parsed >= minimum && parsed <= maximum
        ? parsed
        : null;
  }

  double? _boundedDouble(Object? value, double minimum, double maximum) {
    final parsed = _nullableDouble(value);
    return parsed != null && parsed >= minimum && parsed <= maximum
        ? parsed
        : null;
  }

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

  static const _healthSyncStates = {'writing', 'synced', 'uncertain'};

  static const _measurementSources = {
    'manual',
    'renpho_ble',
    'renpho_csv',
    'gym_tracker',
    'health_connect',
  };

  static const _impedanceSegments = {
    'whole',
    'leftArm',
    'rightArm',
    'leftLeg',
    'rightLeg',
    'trunk',
  };

  static const _goalLevels = {
    'soft',
    'normal',
    'lean',
    'athletic',
    'defined',
    'veryDefined',
  };

  static const _goalPhases = {'approach', 'consolidation', 'maintenance'};

  static const _goalOutcomes = {'reached', 'replaced', 'abandoned'};

  static const _limitationBodyParts = {
    'spalla_dx',
    'spalla_sx',
    'gomito_dx',
    'gomito_sx',
    'polso_dx',
    'polso_sx',
    'collo',
    'costole',
    'lombari',
    'anca_dx',
    'anca_sx',
    'ginocchio_dx',
    'ginocchio_sx',
    'caviglia_dx',
    'caviglia_sx',
  };

  /// I CHECK locali sono chiusi quanto quelli remoti: un valore fuori elenco
  /// farebbe fallire la scrittura e il pull resterebbe fermo su quel cursore.
  String? _oneOf(Object? value, Set<String> allowed) {
    final text = _string(value);
    return allowed.contains(text) ? text : null;
  }

  /// Le righe figlie non hanno tombstone locale: un `deleted_at` remoto è una
  /// cancellazione vera.
  bool _isTombstone(String operation, Map<String, Object?> payload) =>
      operation == 'delete' || payload['deleted_at'] != null;

  /// Una colonna Postgres `date` torna come '2026-08-04': va riletta come
  /// mezzanotte di Roma, non come mezzanotte UTC, o il giorno slitta indietro.
  DateTime? _calendarDay(Object? value) {
    final raw = _string(value);
    if (raw == null) {
      return null;
    }
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) {
      return null;
    }
    return raw.length == 10 ? AppTime.startOfDayUtc(parsed) : parsed.toUtc();
  }

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
