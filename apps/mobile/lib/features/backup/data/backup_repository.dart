import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/backup/domain/backup_document.dart';
import 'package:kal_tracker/features/backup/domain/backup_restore.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:uuid/uuid.dart';

class BackupRepository {
  BackupRepository(this._database, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  /// Alimenti forniti dall'app (seed essenziali e catalogo piatti):
  /// sopravvivono al restore «sostituisci tutto» e non generano tombstone.
  static const List<String> _builtInFoodSources = ['seed', 'catalog'];

  final AppDatabase _database;
  final Uuid _uuid;

  Future<BackupDocument> exportBackup({
    required String profileId,
    String appVersion = BackupDocument.unknownAppVersion,
    DateTime? exportedAt,
  }) async {
    final profile = await (_database.select(
      _database.appProfiles,
    )..where((row) => row.id.equals(profileId))).getSingleOrNull();
    if (profile == null) {
      throw StateError('Profilo non trovato.');
    }

    final meals =
        await (_database.select(_database.meals)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();
    final mealIds = meals.map((row) => row.id).toList(growable: false);
    final mealItems = mealIds.isEmpty
        ? const <MealItem>[]
        : await (_database.select(_database.mealItems)
                ..where((row) => row.mealId.isIn(mealIds))
                ..orderBy([(row) => OrderingTerm.asc(row.id)]))
              .get();

    final targets = await (_database.select(
      _database.nutritionTargets,
    )..where((row) => row.profileId.equals(profileId))).get();
    final waterLogs =
        await (_database.select(_database.waterLogs)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();
    final measurements =
        await (_database.select(_database.bodyMeasurements)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();

    final foods =
        await (_database.select(_database.foods)
              ..where((row) => row.ownerProfileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();
    final preferences =
        await (_database.select(_database.foodPreferences)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.foodId)]))
            .get();

    final recipes =
        await (_database.select(_database.fitRecipes)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();
    final recipeIds = recipes.map((row) => row.id).toList(growable: false);
    final ingredients = recipeIds.isEmpty
        ? const <LocalRecipeIngredient>[]
        : await (_database.select(_database.recipeIngredients)
                ..where((row) => row.recipeId.isIn(recipeIds))
                ..orderBy([(row) => OrderingTerm.asc(row.id)]))
              .get();

    final templates =
        await (_database.select(_database.mealTemplates)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();
    final templateIds = templates.map((row) => row.id).toList(growable: false);
    final templateItems = templateIds.isEmpty
        ? const <LocalMealTemplateItem>[]
        : await (_database.select(_database.mealTemplateItems)
                ..where((row) => row.templateId.isIn(templateIds))
                ..orderBy([(row) => OrderingTerm.asc(row.id)]))
              .get();

    final measurementIds = measurements
        .map((row) => row.id)
        .toList(growable: false);
    final measurementValues = measurementIds.isEmpty
        ? const <LocalBodyMeasurementValue>[]
        : await (_database.select(_database.bodyMeasurementValues)
                ..where((row) => row.measurementId.isIn(measurementIds))
                ..orderBy([(row) => OrderingTerm.asc(row.id)]))
              .get();
    final impedanceReadings = measurementIds.isEmpty
        ? const <LocalBodyImpedanceReading>[]
        : await (_database.select(_database.bodyImpedanceReadings)
                ..where((row) => row.measurementId.isIn(measurementIds))
                ..orderBy([(row) => OrderingTerm.asc(row.id)]))
              .get();

    final generatedPlans =
        await (_database.select(_database.weeklyPlans)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();
    final generatedPlanIds = generatedPlans
        .map((row) => row.id)
        .toList(growable: false);
    final generatedPlanSlots = generatedPlanIds.isEmpty
        ? const <LocalWeeklyPlanSlot>[]
        : await (_database.select(_database.weeklyPlanSlots)
                ..where((row) => row.planId.isIn(generatedPlanIds))
                ..orderBy([(row) => OrderingTerm.asc(row.id)]))
              .get();
    final checkIns =
        await (_database.select(_database.dailyCheckIns)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();
    final goals =
        await (_database.select(_database.goals)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();
    final trainingProfiles = await (_database.select(
      _database.trainingProfiles,
    )..where((row) => row.profileId.equals(profileId))).get();
    final trainingLimitations =
        await (_database.select(_database.trainingLimitations)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();
    final healthSummaries =
        await (_database.select(_database.dailyHealthSummaries)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();
    final coachFeed =
        await (_database.select(_database.coachFeedItems)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();

    // Gli esercizi si prendono TUTTI, compresi i sintetici del defaticamento:
    // lo storico li cita per id e un backup che li saltasse non sarebbe
    // ripristinabile (la riga di sessione resterebbe senza il suo esercizio).
    final exercises =
        await (_database.select(_database.exercises)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();
    final routines =
        await (_database.select(_database.routines)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();
    final routineIds = routines.map((row) => row.id).toList(growable: false);
    final routineExercises = routineIds.isEmpty
        ? const <LocalRoutineExercise>[]
        : await (_database.select(_database.routineExercises)
                ..where((row) => row.routineId.isIn(routineIds))
                ..orderBy([(row) => OrderingTerm.asc(row.id)]))
              .get();
    final routineSegments = routineIds.isEmpty
        ? const <LocalRoutineIntervalSegment>[]
        : await (_database.select(_database.routineIntervalSegments)
                ..where((row) => row.routineId.isIn(routineIds))
                ..orderBy([(row) => OrderingTerm.asc(row.id)]))
              .get();
    final weeklyPlan =
        await (_database.select(_database.routineWeeklyPlan)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();

    final workouts =
        await (_database.select(_database.workouts)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();
    final workoutIds = workouts.map((row) => row.id).toList(growable: false);
    final workoutExercises = workoutIds.isEmpty
        ? const <LocalWorkoutExercise>[]
        : await (_database.select(_database.workoutExercises)
                ..where((row) => row.workoutId.isIn(workoutIds))
                ..orderBy([(row) => OrderingTerm.asc(row.id)]))
              .get();
    final workoutExerciseIds = workoutExercises
        .map((row) => row.id)
        .toList(growable: false);
    final workoutSets = workoutExerciseIds.isEmpty
        ? const <LocalWorkoutSet>[]
        : await (_database.select(_database.workoutSets)
                ..where((row) => row.workoutExerciseId.isIn(workoutExerciseIds))
                ..orderBy([(row) => OrderingTerm.asc(row.id)]))
              .get();
    final painPoints = workoutIds.isEmpty
        ? const <LocalWorkoutPainPoint>[]
        : await (_database.select(_database.workoutPainPoints)
                ..where((row) => row.workoutId.isIn(workoutIds))
                ..orderBy([(row) => OrderingTerm.asc(row.id)]))
              .get();
    final workoutSegments = workoutIds.isEmpty
        ? const <LocalWorkoutIntervalSegment>[]
        : await (_database.select(_database.workoutIntervalSegments)
                ..where((row) => row.workoutId.isIn(workoutIds))
                ..orderBy([(row) => OrderingTerm.asc(row.id)]))
              .get();

    final stats =
        await (_database.select(_database.workoutProfileStats)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();
    final achievements =
        await (_database.select(_database.workoutAchievements)
              ..where((row) => row.profileId.equals(profileId))
              ..orderBy([(row) => OrderingTerm.asc(row.id)]))
            .get();

    return BackupDocument(
      formatVersion: BackupDocument.currentFormatVersion,
      appVersion: appVersion,
      exportedAt: (exportedAt ?? AppTime.nowUtc()).toUtc(),
      profile: BackupProfile(
        id: profile.id,
        displayName: profile.displayName,
        createdAt: profile.createdAt,
        updatedAt: profile.updatedAt,
        heightCm: profile.heightCm,
        birthDate: profile.birthDate,
        sex: profile.sex,
      ),
      meals: [
        for (final row in meals)
          BackupMeal(
            id: row.id,
            profileId: row.profileId,
            mealType: row.mealType,
            eatenAt: row.eatenAt,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      mealItems: [
        for (final row in mealItems)
          BackupMealItem(
            id: row.id,
            mealId: row.mealId,
            foodName: row.foodName,
            grams: row.grams,
            caloriesPer100g: row.caloriesPer100g,
            proteinPer100g: row.proteinPer100g,
            carbsPer100g: row.carbsPer100g,
            fatPer100g: row.fatPer100g,
            totalCalories: row.totalCalories,
            totalProtein: row.totalProtein,
            totalCarbs: row.totalCarbs,
            totalFat: row.totalFat,
            source: row.source,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      nutritionTargets: [
        for (final row in targets)
          BackupNutritionTarget(
            profileId: row.profileId,
            dailyCalories: row.dailyCalories,
            dailyProtein: row.dailyProtein,
            dailyCarbs: row.dailyCarbs,
            dailyFat: row.dailyFat,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      waterLogs: [
        for (final row in waterLogs)
          BackupWaterLog(
            id: row.id,
            profileId: row.profileId,
            milliliters: row.milliliters,
            loggedAt: row.loggedAt,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      bodyMeasurements: [
        for (final row in measurements)
          BackupBodyMeasurement(
            id: row.id,
            profileId: row.profileId,
            weightKg: row.weightKg,
            measuredAt: row.measuredAt,
            hasImpedance: row.hasImpedance,
            impedanceOhm: row.impedanceOhm,
            bodyFatPct: row.bodyFatPct,
            musclePct: row.musclePct,
            skeletalMusclePct: row.skeletalMusclePct,
            bonePct: row.bonePct,
            proteinPct: row.proteinPct,
            waterPct: row.waterPct,
            subcutaneousFatPct: row.subcutaneousFatPct,
            visceralFatIndex: row.visceralFatIndex,
            bmrKcal: row.bmrKcal,
            formulaVersion: row.formulaVersion,
            source: row.source,
            externalId: row.externalId,
            deviceModel: row.deviceModel,
            rawPayload: row.rawPayload,
            note: row.note,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      foods: [
        for (final row in foods)
          BackupFood(
            id: row.id,
            ownerProfileId: row.ownerProfileId,
            name: row.name,
            brand: row.brand,
            barcode: row.barcode,
            caloriesPer100g: row.caloriesPer100g,
            proteinPer100g: row.proteinPer100g,
            carbsPer100g: row.carbsPer100g,
            fatPer100g: row.fatPer100g,
            defaultServingGrams: row.defaultServingGrams,
            source: row.source,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      foodPreferences: [
        for (final row in preferences)
          BackupFoodPreference(
            profileId: row.profileId,
            foodId: row.foodId,
            isFavorite: row.isFavorite,
            useCount: row.useCount,
            lastUsedAt: row.lastUsedAt,
            updatedAt: row.updatedAt,
          ),
      ],
      fitRecipes: [
        for (final row in recipes)
          BackupRecipe(
            id: row.id,
            profileId: row.profileId,
            name: row.name,
            description: row.description,
            instructions: row.instructions,
            tags: row.tags,
            servings: row.servings,
            prepMinutes: row.prepMinutes,
            totalCalories: row.totalCalories,
            totalProtein: row.totalProtein,
            totalCarbs: row.totalCarbs,
            totalFat: row.totalFat,
            isFavorite: row.isFavorite,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      recipeIngredients: [
        for (final row in ingredients)
          BackupRecipeIngredient(
            id: row.id,
            recipeId: row.recipeId,
            foodId: row.foodId,
            position: row.position,
            name: row.name,
            grams: row.grams,
            caloriesPer100g: row.caloriesPer100g,
            proteinPer100g: row.proteinPer100g,
            carbsPer100g: row.carbsPer100g,
            fatPer100g: row.fatPer100g,
          ),
      ],
      mealTemplates: [
        for (final row in templates)
          BackupMealTemplate(
            id: row.id,
            profileId: row.profileId,
            name: row.name,
            mealType: row.mealType,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      mealTemplateItems: [
        for (final row in templateItems)
          BackupMealTemplateItem(
            id: row.id,
            templateId: row.templateId,
            position: row.position,
            foodName: row.foodName,
            grams: row.grams,
            caloriesPer100g: row.caloriesPer100g,
            proteinPer100g: row.proteinPer100g,
            carbsPer100g: row.carbsPer100g,
            fatPer100g: row.fatPer100g,
          ),
      ],
      bodyMeasurementValues: [
        for (final row in measurementValues)
          BackupBodyMeasurementValue(
            id: row.id,
            measurementId: row.measurementId,
            label: row.label,
            value: row.value,
          ),
      ],
      exercises: [
        for (final row in exercises)
          BackupExercise(
            id: row.id,
            profileId: row.profileId,
            name: row.name,
            muscleGroup: row.muscleGroup,
            trackingMode: row.trackingMode,
            notes: row.notes,
            imageUrl: row.imageUrl,
            defaultRestSec: row.defaultRestSec,
            isPreset: row.isPreset,
            isSynthetic: row.isSynthetic,
            source: row.source,
            externalId: row.externalId,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      routines: [
        for (final row in routines)
          BackupRoutine(
            id: row.id,
            profileId: row.profileId,
            name: row.name,
            notes: row.notes,
            isCircuit: row.isCircuit,
            workSec: row.workSec,
            shortRestSec: row.shortRestSec,
            longRestSec: row.longRestSec,
            rounds: row.rounds,
            warmupWorkSec: row.warmupWorkSec,
            warmupRestSec: row.warmupRestSec,
            source: row.source,
            externalId: row.externalId,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      routineExercises: [
        for (final row in routineExercises)
          BackupRoutineExercise(
            id: row.id,
            routineId: row.routineId,
            block: row.block,
            position: row.position,
            exerciseRefId: row.exerciseRefId,
            exerciseId: row.exerciseId,
            exerciseNameSnapshot: row.exerciseNameSnapshot,
            inSupersetWithPrevious: row.inSupersetWithPrevious,
            warmupDurationSec: row.warmupDurationSec,
            prescSets: row.prescSets,
            prescReps: row.prescReps,
            prescDurationSec: row.prescDurationSec,
            prescRestSec: row.prescRestSec,
          ),
      ],
      routineIntervalSegments: [
        for (final row in routineSegments)
          BackupRoutineIntervalSegment(
            id: row.id,
            routineId: row.routineId,
            segmentIndex: row.segmentIndex,
            startIdx: row.startIdx,
            endIdx: row.endIdx,
            workSec: row.workSec,
            restSec: row.restSec,
            longRestSec: row.longRestSec,
            rounds: row.rounds,
          ),
      ],
      routineWeeklyPlan: [
        for (final row in weeklyPlan)
          BackupRoutineWeeklyPlanDay(
            id: row.id,
            profileId: row.profileId,
            weekday: row.weekday,
            routineId: row.routineId,
            routineExternalId: row.routineExternalId,
            routineNameSnapshot: row.routineNameSnapshot,
            updatedAt: row.updatedAt,
          ),
      ],
      workouts: [
        for (final row in workouts)
          BackupWorkout(
            id: row.id,
            profileId: row.profileId,
            startedAt: row.startedAt,
            endedAt: row.endedAt,
            pausedAt: row.pausedAt,
            accumulatedPauseSeconds: row.accumulatedPauseSeconds,
            finalDurationSeconds: row.finalDurationSeconds,
            durationSuspect: row.durationSuspect,
            routineId: row.routineId,
            routineExternalId: row.routineExternalId,
            routineNameSnapshot: row.routineNameSnapshot,
            notes: row.notes,
            totalKcal: row.totalKcal,
            mood: row.mood,
            rpe: row.rpe,
            satisfaction: row.satisfaction,
            feedbackNotes: row.feedbackNotes,
            xpEarned: row.xpEarned,
            resumePath: row.resumePath,
            circuitCheckpointJson: row.circuitCheckpointJson,
            syncedToHealthConnect: row.syncedToHealthConnect,
            healthSyncState: row.healthSyncState,
            healthSyncClaimId: row.healthSyncClaimId,
            healthSyncAttemptedAt: row.healthSyncAttemptedAt,
            healthSyncCompletedAt: row.healthSyncCompletedAt,
            source: row.source,
            externalId: row.externalId,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      workoutExercises: [
        for (final row in workoutExercises)
          BackupWorkoutExercise(
            id: row.id,
            workoutId: row.workoutId,
            position: row.position,
            exerciseRefId: row.exerciseRefId,
            exerciseId: row.exerciseId,
            exerciseNameSnapshot: row.exerciseNameSnapshot,
            trackingMode: row.trackingMode,
            muscleGroupSnapshot: row.muscleGroupSnapshot,
            restSeconds: row.restSeconds,
            isWarmup: row.isWarmup,
            isCooldown: row.isCooldown,
            isFinisher: row.isFinisher,
            isInSupersetWithPrevious: row.isInSupersetWithPrevious,
            intervalSegmentIndex: row.intervalSegmentIndex,
          ),
      ],
      workoutSets: [
        for (final row in workoutSets)
          BackupWorkoutSet(
            id: row.id,
            workoutExerciseId: row.workoutExerciseId,
            position: row.position,
            weightKg: row.weightKg,
            reps: row.reps,
            durationSec: row.durationSec,
            distanceM: row.distanceM,
            rpe: row.rpe,
            isWarmup: row.isWarmup,
            completed: row.completed,
          ),
      ],
      workoutPainPoints: [
        for (final row in painPoints)
          BackupWorkoutPainPoint(
            id: row.id,
            workoutId: row.workoutId,
            label: row.label,
          ),
      ],
      workoutIntervalSegments: [
        for (final row in workoutSegments)
          BackupWorkoutIntervalSegment(
            id: row.id,
            workoutId: row.workoutId,
            segmentIndex: row.segmentIndex,
            completedMarker: row.completedMarker,
            partialMarker: row.partialMarker,
            completionSignature: row.completionSignature,
          ),
      ],
      workoutProfileStats: [
        for (final row in stats)
          BackupWorkoutProfileStats(
            id: row.id,
            profileId: row.profileId,
            totalXp: row.totalXp,
            currentStreak: row.currentStreak,
            longestStreak: row.longestStreak,
            lastWorkoutDay: row.lastWorkoutDay,
            weeklyWorkoutGoal: row.weeklyWorkoutGoal,
            weeklyKcalGoal: row.weeklyKcalGoal,
            reminderEnabled: row.reminderEnabled,
            reminderHour: row.reminderHour,
            reminderMinute: row.reminderMinute,
            healthConnectEnabled: row.healthConnectEnabled,
            voiceEnabled: row.voiceEnabled,
            gymBodyWeightKg: row.gymBodyWeightKg,
            gymExportedAt: row.gymExportedAt,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      workoutAchievements: [
        for (final row in achievements)
          BackupWorkoutAchievement(
            id: row.id,
            profileId: row.profileId,
            slug: row.slug,
            unlockedAt: row.unlockedAt,
          ),
      ],
      weeklyPlans: [
        for (final row in generatedPlans)
          BackupWeeklyPlan(
            id: row.id,
            profileId: row.profileId,
            startDate: row.startDate,
            days: row.days,
            mealsCsv: row.mealsCsv,
            status: row.status,
            remoteJobId: row.remoteJobId,
            notes: row.notes,
            requestJson: row.requestJson,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      weeklyPlanSlots: [
        for (final row in generatedPlanSlots)
          BackupWeeklyPlanSlot(
            id: row.id,
            planId: row.planId,
            date: row.date,
            meal: row.meal,
            recipeId: row.recipeId,
            recipeNameSnapshot: row.recipeNameSnapshot,
            servings: row.servings,
            why: row.why,
            doneAt: row.doneAt,
            diaryEntryIds: row.diaryEntryIds,
          ),
      ],
      dailyCheckIns: [
        for (final row in checkIns)
          BackupDailyCheckIn(
            id: row.id,
            profileId: row.profileId,
            day: row.day,
            sleepHours: row.sleepHours,
            energyScore: row.energyScore,
            steps: row.steps,
            walkMinutes: row.walkMinutes,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      goals: [
        for (final row in goals)
          BackupGoal(
            id: row.id,
            profileId: row.profileId,
            targetWeightKg: row.targetWeightKg,
            targetLevel: row.targetLevel,
            paceKgPerWeek: row.paceKgPerWeek,
            startedAt: row.startedAt,
            startWeightKg: row.startWeightKg,
            startFatFreeMassKg: row.startFatFreeMassKg,
            phase: row.phase,
            phaseStartedAt: row.phaseStartedAt,
            closedAt: row.closedAt,
            outcome: row.outcome,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      bodyImpedanceReadings: [
        for (final row in impedanceReadings)
          BackupBodyImpedanceReading(
            id: row.id,
            measurementId: row.measurementId,
            segment: row.segment,
            frequencyHz: row.frequencyHz,
            ohm: row.ohm,
          ),
      ],
      trainingProfiles: [
        for (final row in trainingProfiles)
          BackupTrainingProfile(
            profileId: row.profileId,
            equipment: row.equipment,
            sessionsPerWeek: row.sessionsPerWeek,
            minutesPerSession: row.minutesPerSession,
            preferredDays: row.preferredDays,
            deloadPreference: row.deloadPreference,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
          ),
      ],
      trainingLimitations: [
        for (final row in trainingLimitations)
          BackupTrainingLimitation(
            id: row.id,
            profileId: row.profileId,
            bodyPart: row.bodyPart,
            severity: row.severity,
            note: row.note,
            startedAt: row.startedAt,
            resolvedAt: row.resolvedAt,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      dailyHealthSummaries: [
        for (final row in healthSummaries)
          BackupDailyHealthSummary(
            id: row.id,
            profileId: row.profileId,
            day: row.day,
            source: row.source,
            externalId: row.externalId,
            steps: row.steps,
            sleepMinutes: row.sleepMinutes,
            restingHeartRate: row.restingHeartRate,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
      coachFeedItems: [
        for (final row in coachFeed)
          BackupCoachFeedItem(
            id: row.id,
            profileId: row.profileId,
            kind: row.kind,
            source: row.source,
            externalId: row.externalId,
            title: row.title,
            body: row.body,
            actionLabel: row.actionLabel,
            actionPath: row.actionPath,
            occurredAt: row.occurredAt,
            readAt: row.readAt,
            dismissedAt: row.dismissedAt,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt,
            deletedAt: row.deletedAt,
          ),
      ],
    );
  }

  Future<BackupRestoreSummary> importBackup(
    String json, {
    required BackupRestoreMode mode,
  }) async {
    final document = BackupDocument.decode(json);
    final now = AppTime.nowUtc();
    try {
      return await _database.transaction(
        () => _restore(document: document, mode: mode, now: now),
      );
    } on BackupFormatException {
      rethrow;
    } on Object {
      throw const BackupFormatException(
        'Ripristino non riuscito: i dati del backup non sono compatibili con '
        'questo diario. Non è stato modificato niente.',
      );
    }
  }

  Future<BackupRestoreSummary> _restore({
    required BackupDocument document,
    required BackupRestoreMode mode,
    required DateTime now,
  }) async {
    final counters = _RestoreCounters();
    final replacing = mode == BackupRestoreMode.replace;
    if (replacing && !document.coversWorkouts) {
      await _refuseLegacyReplace();
    }
    if (replacing && !document.coversDataContract) {
      await _refuseLegacyDataContractReplace();
    }
    final removable = replacing
        ? await _existingKeys()
        : const <String, Set<String>>{};
    if (replacing) {
      await _wipeUserTables();
    }

    final profileId = await _restoreProfile(
      profile: document.profile,
      replacing: replacing,
      counters: counters,
      now: now,
    );

    await _restoreFoods(document, profileId, replacing, counters, now);
    await _restoreFoodPreferences(
      document,
      profileId,
      replacing,
      counters,
      now,
    );
    await _restoreMeals(document, profileId, replacing, counters, now);
    await _restoreTargets(document, profileId, replacing, counters, now);
    await _restoreWaterLogs(document, profileId, replacing, counters, now);
    await _restoreMeasurements(document, profileId, replacing, counters, now);
    await _restoreRecipes(document, profileId, replacing, counters, now);
    await _restoreTemplates(document, profileId, replacing, counters, now);
    await _restoreGeneratedWeeklyPlans(
      document,
      profileId,
      replacing,
      counters,
    );
    await _restoreCheckIns(document, profileId, replacing, counters, now);
    await _restoreGoals(document, profileId, replacing, counters, now);
    await _restoreTrainingData(document, profileId, replacing, counters, now);
    await _restoreDailyHealthSummaries(
      document,
      profileId,
      replacing,
      counters,
      now,
    );
    await _restoreCoachFeed(document, profileId, replacing, counters, now);
    // L'ordine è quello delle chiavi esterne: catalogo, schede, sessioni. Le
    // righe figlie citano i genitori appena scritti, quindi non si possono
    // anticipare.
    await _restoreExercises(document, profileId, replacing, counters);
    await _restoreRoutines(document, profileId, replacing, counters);
    await _restoreWeeklyPlan(document, profileId, replacing, counters);
    await _restoreWorkouts(document, profileId, replacing, counters);
    await _restoreWorkoutStats(document, profileId, replacing, counters);

    if (replacing) {
      await _appendTombstones(
        removable: removable,
        restored: _restoredKeys(document, profileId),
        now: now,
      );
    }

    return BackupRestoreSummary(
      mode: mode,
      created: counters.created,
      updated: counters.updated,
      skipped: counters.skipped,
    );
  }

  Future<String> _restoreProfile({
    required BackupProfile profile,
    required bool replacing,
    required _RestoreCounters counters,
    required DateTime now,
  }) async {
    final existing = replacing
        ? null
        : await (_database.select(
            _database.appProfiles,
          )..limit(1)).getSingleOrNull();
    if (existing == null) {
      await _database
          .into(_database.appProfiles)
          .insert(
            AppProfilesCompanion.insert(
              id: profile.id,
              displayName: profile.displayName,
              heightCm: Value(profile.heightCm),
              birthDate: Value(profile.birthDate),
              sex: Value(profile.sex),
              createdAt: profile.createdAt,
              updatedAt: profile.updatedAt,
            ),
          );
      counters.created++;
      await _appendOutbox(
        entityType: 'profile',
        entityId: profile.id,
        payload: profile.toJson(),
        now: now,
      );
      return profile.id;
    }
    if (existing.id == profile.id &&
        profile.updatedAt.isAfter(existing.updatedAt)) {
      await (_database.update(
        _database.appProfiles,
      )..where((row) => row.id.equals(profile.id))).write(
        AppProfilesCompanion(
          displayName: Value(profile.displayName),
          heightCm: Value(profile.heightCm),
          birthDate: Value(profile.birthDate),
          sex: Value(profile.sex),
          updatedAt: Value(profile.updatedAt),
        ),
      );
      counters.updated++;
      await _appendOutbox(
        entityType: 'profile',
        entityId: existing.id,
        payload: {...profile.toJson(), 'id': existing.id},
        now: now,
      );
    } else {
      counters.skipped++;
    }
    return existing.id;
  }

  Future<void> _restoreFoods(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
    DateTime now,
  ) async {
    for (final food in document.foods) {
      final existing = replacing
          ? null
          : await (_database.select(
              _database.foods,
            )..where((row) => row.id.equals(food.id))).getSingleOrNull();
      if (existing != null && !food.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.foods)
          .insertOnConflictUpdate(
            FoodsCompanion(
              id: Value(food.id),
              ownerProfileId: Value(
                food.ownerProfileId == null ? null : profileId,
              ),
              name: Value(food.name),
              brand: Value(food.brand),
              barcode: Value(food.barcode),
              caloriesPer100g: Value(food.caloriesPer100g),
              proteinPer100g: Value(food.proteinPer100g),
              carbsPer100g: Value(food.carbsPer100g),
              fatPer100g: Value(food.fatPer100g),
              defaultServingGrams: Value(food.defaultServingGrams),
              source: Value(food.source),
              createdAt: Value(food.createdAt),
              updatedAt: Value(food.updatedAt),
              deletedAt: Value(food.deletedAt),
            ),
          );
      _count(counters, existing != null);
      await _appendOutbox(
        entityType: 'food',
        entityId: food.id,
        payload: {
          ...food.toJson(),
          'owner_profile_id': food.ownerProfileId == null ? null : profileId,
        },
        now: now,
      );
    }
  }

  Future<void> _restoreFoodPreferences(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
    DateTime now,
  ) async {
    for (final preference in document.foodPreferences) {
      final existing = replacing
          ? null
          : await (_database.select(_database.foodPreferences)..where(
                  (row) =>
                      row.profileId.equals(profileId) &
                      row.foodId.equals(preference.foodId),
                ))
                .getSingleOrNull();
      if (existing != null &&
          !preference.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.foodPreferences)
          .insertOnConflictUpdate(
            FoodPreferencesCompanion(
              profileId: Value(profileId),
              foodId: Value(preference.foodId),
              isFavorite: Value(preference.isFavorite),
              useCount: Value(preference.useCount),
              lastUsedAt: Value(preference.lastUsedAt),
              updatedAt: Value(preference.updatedAt),
            ),
          );
      _count(counters, existing != null);
      await _appendOutbox(
        entityType: 'food_preference',
        entityId: '$profileId:${preference.foodId}',
        payload: {...preference.toJson(), 'profile_id': profileId},
        now: now,
      );
    }
  }

  Future<void> _restoreMeals(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
    DateTime now,
  ) async {
    for (final meal in document.meals) {
      final existing = replacing
          ? null
          : await (_database.select(
              _database.meals,
            )..where((row) => row.id.equals(meal.id))).getSingleOrNull();
      if (existing != null && !meal.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.meals)
          .insertOnConflictUpdate(
            MealsCompanion(
              id: Value(meal.id),
              profileId: Value(profileId),
              mealType: Value(meal.mealType),
              eatenAt: Value(meal.eatenAt),
              createdAt: Value(meal.createdAt),
              updatedAt: Value(meal.updatedAt),
              deletedAt: Value(meal.deletedAt),
            ),
          );
      _count(counters, existing != null);
    }

    final mealsById = {for (final meal in document.meals) meal.id: meal};
    for (final item in document.mealItems) {
      final existing = replacing
          ? null
          : await (_database.select(
              _database.mealItems,
            )..where((row) => row.id.equals(item.id))).getSingleOrNull();
      if (existing != null && !item.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      final totals = _itemTotals(item);
      await _database
          .into(_database.mealItems)
          .insertOnConflictUpdate(
            MealItemsCompanion(
              id: Value(item.id),
              mealId: Value(item.mealId),
              foodName: Value(item.foodName),
              grams: Value(item.grams),
              caloriesPer100g: Value(item.caloriesPer100g),
              proteinPer100g: Value(item.proteinPer100g),
              carbsPer100g: Value(item.carbsPer100g),
              fatPer100g: Value(item.fatPer100g),
              totalCalories: Value(totals.calories),
              totalProtein: Value(totals.protein),
              totalCarbs: Value(totals.carbs),
              totalFat: Value(totals.fat),
              source: Value(item.source),
              createdAt: Value(item.createdAt),
              updatedAt: Value(item.updatedAt),
              deletedAt: Value(item.deletedAt),
            ),
          );
      _count(counters, existing != null);
      final meal = mealsById[item.mealId];
      await _appendOutbox(
        entityType: 'meal_item',
        entityId: item.id,
        payload: {
          ...item.toJson(),
          ..._totalsJson(totals),
          'profile_id': profileId,
          if (meal != null) 'meal_type': meal.mealType,
          if (meal != null) 'eaten_at': meal.eatenAt.toUtc().toIso8601String(),
        },
        now: now,
      );
    }
  }

  Future<void> _restoreTargets(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
    DateTime now,
  ) async {
    for (final target in document.nutritionTargets) {
      final existing = replacing
          ? null
          : await (_database.select(_database.nutritionTargets)
                  ..where((row) => row.profileId.equals(profileId)))
                .getSingleOrNull();
      if (existing != null && !target.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.nutritionTargets)
          .insertOnConflictUpdate(
            NutritionTargetsCompanion(
              profileId: Value(profileId),
              dailyCalories: Value(target.dailyCalories),
              dailyProtein: Value(target.dailyProtein),
              dailyCarbs: Value(target.dailyCarbs),
              dailyFat: Value(target.dailyFat),
              createdAt: Value(target.createdAt),
              updatedAt: Value(target.updatedAt),
              deletedAt: Value(target.deletedAt),
            ),
          );
      _count(counters, existing != null);
      await _appendOutbox(
        entityType: 'nutrition_target',
        entityId: profileId,
        payload: {...target.toJson(), 'profile_id': profileId},
        now: now,
      );
    }
  }

  Future<void> _restoreWaterLogs(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
    DateTime now,
  ) async {
    for (final log in document.waterLogs) {
      final existing = replacing
          ? null
          : await (_database.select(
              _database.waterLogs,
            )..where((row) => row.id.equals(log.id))).getSingleOrNull();
      if (existing != null && !log.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.waterLogs)
          .insertOnConflictUpdate(
            WaterLogsCompanion(
              id: Value(log.id),
              profileId: Value(profileId),
              milliliters: Value(log.milliliters),
              loggedAt: Value(log.loggedAt),
              createdAt: Value(log.createdAt),
              updatedAt: Value(log.updatedAt),
              deletedAt: Value(log.deletedAt),
            ),
          );
      _count(counters, existing != null);
      await _appendOutbox(
        entityType: 'water_log',
        entityId: log.id,
        payload: {...log.toJson(), 'profile_id': profileId},
        now: now,
      );
    }
  }

  Future<void> _restoreMeasurements(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
    DateTime now,
  ) async {
    final valuesByMeasurement = <String, List<BackupBodyMeasurementValue>>{};
    for (final value in document.bodyMeasurementValues) {
      valuesByMeasurement.putIfAbsent(value.measurementId, () => []).add(value);
    }
    final impedanceByMeasurement = <String, List<BackupBodyImpedanceReading>>{};
    for (final reading in document.bodyImpedanceReadings) {
      impedanceByMeasurement
          .putIfAbsent(reading.measurementId, () => [])
          .add(reading);
    }

    for (final measurement in document.bodyMeasurements) {
      final existing = replacing
          ? null
          : await (_database.select(
              _database.bodyMeasurements,
            )..where((row) => row.id.equals(measurement.id))).getSingleOrNull();
      if (existing != null &&
          !measurement.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.bodyMeasurements)
          .insertOnConflictUpdate(
            BodyMeasurementsCompanion(
              id: Value(measurement.id),
              profileId: Value(profileId),
              weightKg: Value(measurement.weightKg),
              measuredAt: Value(measurement.measuredAt),
              hasImpedance: Value(measurement.hasImpedance),
              impedanceOhm: Value(measurement.impedanceOhm),
              bodyFatPct: Value(measurement.bodyFatPct),
              musclePct: Value(measurement.musclePct),
              skeletalMusclePct: Value(measurement.skeletalMusclePct),
              bonePct: Value(measurement.bonePct),
              proteinPct: Value(measurement.proteinPct),
              waterPct: Value(measurement.waterPct),
              subcutaneousFatPct: Value(measurement.subcutaneousFatPct),
              visceralFatIndex: Value(measurement.visceralFatIndex),
              bmrKcal: Value(measurement.bmrKcal),
              formulaVersion: Value(measurement.formulaVersion),
              source: Value(measurement.source),
              externalId: Value(measurement.externalId),
              deviceModel: Value(measurement.deviceModel),
              rawPayload: Value(measurement.rawPayload),
              note: Value(measurement.note),
              createdAt: Value(measurement.createdAt),
              updatedAt: Value(measurement.updatedAt),
              deletedAt: Value(measurement.deletedAt),
            ),
          );
      if (existing != null) {
        await (_database.delete(
          _database.bodyMeasurementValues,
        )..where((row) => row.measurementId.equals(measurement.id))).go();
        await (_database.delete(
          _database.bodyImpedanceReadings,
        )..where((row) => row.measurementId.equals(measurement.id))).go();
      }
      for (final value
          in valuesByMeasurement[measurement.id] ??
              const <BackupBodyMeasurementValue>[]) {
        await _database
            .into(_database.bodyMeasurementValues)
            .insertOnConflictUpdate(
              BodyMeasurementValuesCompanion(
                id: Value(value.id),
                measurementId: Value(value.measurementId),
                label: Value(value.label),
                value: Value(value.value),
              ),
            );
      }
      for (final reading
          in impedanceByMeasurement[measurement.id] ??
              const <BackupBodyImpedanceReading>[]) {
        await _database
            .into(_database.bodyImpedanceReadings)
            .insertOnConflictUpdate(
              BodyImpedanceReadingsCompanion(
                id: Value(reading.id),
                measurementId: Value(measurement.id),
                segment: Value(reading.segment),
                frequencyHz: Value(reading.frequencyHz),
                ohm: Value(reading.ohm),
              ),
            );
      }
      _count(counters, existing != null);
      await _appendOutbox(
        entityType: 'body_measurement',
        entityId: measurement.id,
        payload: {
          ...measurement.toJson(),
          'profile_id': profileId,
          'values': [
            for (final value
                in valuesByMeasurement[measurement.id] ??
                    const <BackupBodyMeasurementValue>[])
              value.toJson(),
          ],
          'impedance_readings': [
            for (final reading
                in impedanceByMeasurement[measurement.id] ??
                    const <BackupBodyImpedanceReading>[])
              reading.toJson(),
          ],
        },
        now: now,
      );
    }
  }

  Future<void> _restoreRecipes(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
    DateTime now,
  ) async {
    final ingredientsByRecipe = <String, List<BackupRecipeIngredient>>{};
    for (final ingredient in document.recipeIngredients) {
      ingredientsByRecipe
          .putIfAbsent(ingredient.recipeId, () => [])
          .add(ingredient);
    }

    for (final recipe in document.fitRecipes) {
      final existing = replacing
          ? null
          : await (_database.select(
              _database.fitRecipes,
            )..where((row) => row.id.equals(recipe.id))).getSingleOrNull();
      if (existing != null && !recipe.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      final ingredients =
          ingredientsByRecipe[recipe.id] ?? const <BackupRecipeIngredient>[];
      final totals = _recipeTotals(ingredients);
      await _database
          .into(_database.fitRecipes)
          .insertOnConflictUpdate(
            FitRecipesCompanion(
              id: Value(recipe.id),
              profileId: Value(profileId),
              name: Value(recipe.name),
              description: Value(recipe.description),
              instructions: Value(recipe.instructions),
              tags: Value(recipe.tags),
              servings: Value(recipe.servings),
              prepMinutes: Value(recipe.prepMinutes),
              totalCalories: Value(totals.calories),
              totalProtein: Value(totals.protein),
              totalCarbs: Value(totals.carbs),
              totalFat: Value(totals.fat),
              isFavorite: Value(recipe.isFavorite),
              createdAt: Value(recipe.createdAt),
              updatedAt: Value(recipe.updatedAt),
              deletedAt: Value(recipe.deletedAt),
            ),
          );
      if (existing != null) {
        await (_database.delete(
          _database.recipeIngredients,
        )..where((row) => row.recipeId.equals(recipe.id))).go();
      }
      for (final ingredient in ingredients) {
        await _database
            .into(_database.recipeIngredients)
            .insertOnConflictUpdate(
              RecipeIngredientsCompanion(
                id: Value(ingredient.id),
                recipeId: Value(ingredient.recipeId),
                foodId: Value(ingredient.foodId),
                position: Value(ingredient.position),
                name: Value(ingredient.name),
                grams: Value(ingredient.grams),
                caloriesPer100g: Value(ingredient.caloriesPer100g),
                proteinPer100g: Value(ingredient.proteinPer100g),
                carbsPer100g: Value(ingredient.carbsPer100g),
                fatPer100g: Value(ingredient.fatPer100g),
              ),
            );
      }
      _count(counters, existing != null);
      await _appendOutbox(
        entityType: 'fit_recipe',
        entityId: recipe.id,
        payload: {
          ...recipe.toJson(),
          ..._totalsJson(totals),
          'profile_id': profileId,
          'ingredients': [
            for (final ingredient in ingredients) ingredient.toJson(),
          ],
        },
        now: now,
      );
    }
  }

  Future<void> _restoreTemplates(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
    DateTime now,
  ) async {
    final itemsByTemplate = <String, List<BackupMealTemplateItem>>{};
    for (final item in document.mealTemplateItems) {
      itemsByTemplate.putIfAbsent(item.templateId, () => []).add(item);
    }

    for (final template in document.mealTemplates) {
      final existing = replacing
          ? null
          : await (_database.select(
              _database.mealTemplates,
            )..where((row) => row.id.equals(template.id))).getSingleOrNull();
      if (existing != null && !template.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.mealTemplates)
          .insertOnConflictUpdate(
            MealTemplatesCompanion(
              id: Value(template.id),
              profileId: Value(profileId),
              name: Value(template.name),
              mealType: Value(template.mealType),
              createdAt: Value(template.createdAt),
              updatedAt: Value(template.updatedAt),
              deletedAt: Value(template.deletedAt),
            ),
          );
      if (existing != null) {
        await (_database.delete(
          _database.mealTemplateItems,
        )..where((row) => row.templateId.equals(template.id))).go();
      }
      final items =
          itemsByTemplate[template.id] ?? const <BackupMealTemplateItem>[];
      for (final item in items) {
        await _database
            .into(_database.mealTemplateItems)
            .insertOnConflictUpdate(
              MealTemplateItemsCompanion(
                id: Value(item.id),
                templateId: Value(item.templateId),
                position: Value(item.position),
                foodName: Value(item.foodName),
                grams: Value(item.grams),
                caloriesPer100g: Value(item.caloriesPer100g),
                proteinPer100g: Value(item.proteinPer100g),
                carbsPer100g: Value(item.carbsPer100g),
                fatPer100g: Value(item.fatPer100g),
              ),
            );
      }
      _count(counters, existing != null);
      await _appendOutbox(
        entityType: 'meal_template',
        entityId: template.id,
        payload: {
          ...template.toJson(),
          'profile_id': profileId,
          'items': [for (final item in items) item.toJson()],
        },
        now: now,
      );
    }
  }

  Future<void> _restoreGeneratedWeeklyPlans(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
  ) async {
    final slotsByPlan = <String, List<BackupWeeklyPlanSlot>>{};
    for (final slot in document.weeklyPlanSlots) {
      slotsByPlan.putIfAbsent(slot.planId, () => []).add(slot);
    }
    final liveRecipeIds = {
      for (final recipe in await _database.select(_database.fitRecipes).get())
        recipe.id,
    };

    for (final plan in document.weeklyPlans) {
      final existing = replacing
          ? null
          : await (_database.select(
              _database.weeklyPlans,
            )..where((row) => row.id.equals(plan.id))).getSingleOrNull();
      if (existing != null && !plan.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.weeklyPlans)
          .insertOnConflictUpdate(
            WeeklyPlansCompanion(
              id: Value(plan.id),
              profileId: Value(profileId),
              startDate: Value(plan.startDate),
              days: Value(plan.days),
              mealsCsv: Value(plan.mealsCsv),
              status: Value(plan.status),
              remoteJobId: Value(plan.remoteJobId),
              notes: Value(plan.notes),
              requestJson: Value(plan.requestJson),
              createdAt: Value(plan.createdAt),
              updatedAt: Value(plan.updatedAt),
              deletedAt: Value(plan.deletedAt),
            ),
          );
      if (existing != null) {
        await (_database.delete(
          _database.weeklyPlanSlots,
        )..where((row) => row.planId.equals(plan.id))).go();
      }
      for (final slot
          in slotsByPlan[plan.id] ?? const <BackupWeeklyPlanSlot>[]) {
        final recipeId = slot.recipeId;
        await _database
            .into(_database.weeklyPlanSlots)
            .insertOnConflictUpdate(
              WeeklyPlanSlotsCompanion(
                id: Value(slot.id),
                planId: Value(plan.id),
                date: Value(slot.date),
                meal: Value(slot.meal),
                recipeId: Value(
                  recipeId != null && liveRecipeIds.contains(recipeId)
                      ? recipeId
                      : null,
                ),
                recipeNameSnapshot: Value(slot.recipeNameSnapshot),
                servings: Value(slot.servings),
                why: Value(slot.why),
                doneAt: Value(slot.doneAt),
                diaryEntryIds: Value(slot.diaryEntryIds),
              ),
            );
      }
      _count(counters, existing != null);
    }
  }

  Future<void> _restoreCheckIns(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
    DateTime now,
  ) async {
    for (final checkIn in document.dailyCheckIns) {
      final existing = replacing
          ? null
          : await (_database.select(
              _database.dailyCheckIns,
            )..where((row) => row.id.equals(checkIn.id))).getSingleOrNull();
      if (existing != null && !checkIn.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.dailyCheckIns)
          .insertOnConflictUpdate(
            DailyCheckInsCompanion(
              id: Value(checkIn.id),
              profileId: Value(profileId),
              day: Value(checkIn.day),
              sleepHours: Value(checkIn.sleepHours),
              energyScore: Value(checkIn.energyScore),
              steps: Value(checkIn.steps),
              walkMinutes: Value(checkIn.walkMinutes),
              createdAt: Value(checkIn.createdAt),
              updatedAt: Value(checkIn.updatedAt),
              deletedAt: Value(checkIn.deletedAt),
            ),
          );
      _count(counters, existing != null);
      await _appendOutbox(
        entityType: 'daily_check_in',
        entityId: checkIn.id,
        payload: {...checkIn.toJson(), 'profile_id': profileId},
        now: now,
      );
    }
  }

  Future<void> _restoreGoals(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
    DateTime now,
  ) async {
    for (final goal in document.goals) {
      final existing = replacing
          ? null
          : await (_database.select(
              _database.goals,
            )..where((row) => row.id.equals(goal.id))).getSingleOrNull();
      if (existing != null && !goal.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.goals)
          .insertOnConflictUpdate(
            GoalsCompanion(
              id: Value(goal.id),
              profileId: Value(profileId),
              targetWeightKg: Value(goal.targetWeightKg),
              targetLevel: Value(goal.targetLevel),
              paceKgPerWeek: Value(goal.paceKgPerWeek),
              startedAt: Value(goal.startedAt),
              startWeightKg: Value(goal.startWeightKg),
              startFatFreeMassKg: Value(goal.startFatFreeMassKg),
              phase: Value(goal.phase),
              phaseStartedAt: Value(goal.phaseStartedAt),
              closedAt: Value(goal.closedAt),
              outcome: Value(goal.outcome),
              createdAt: Value(goal.createdAt),
              updatedAt: Value(goal.updatedAt),
              deletedAt: Value(goal.deletedAt),
            ),
          );
      _count(counters, existing != null);
      await _appendOutbox(
        entityType: 'goal',
        entityId: goal.id,
        payload: {...goal.toJson(), 'profile_id': profileId},
        now: now,
      );
    }
  }

  Future<void> _restoreTrainingData(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
    DateTime now,
  ) async {
    for (final profile in document.trainingProfiles) {
      final existing = replacing
          ? null
          : await (_database.select(_database.trainingProfiles)
                  ..where((row) => row.profileId.equals(profileId)))
                .getSingleOrNull();
      if (existing != null && !profile.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
      } else {
        await _database
            .into(_database.trainingProfiles)
            .insertOnConflictUpdate(
              TrainingProfilesCompanion(
                profileId: Value(profileId),
                equipment: Value(profile.equipment),
                sessionsPerWeek: Value(profile.sessionsPerWeek),
                minutesPerSession: Value(profile.minutesPerSession),
                preferredDays: Value(profile.preferredDays),
                deloadPreference: Value(profile.deloadPreference),
                createdAt: Value(profile.createdAt),
                updatedAt: Value(profile.updatedAt),
              ),
            );
        _count(counters, existing != null);
        await _appendOutbox(
          entityType: 'training_profile',
          entityId: profileId,
          payload: {...profile.toJson(), 'profile_id': profileId},
          now: now,
        );
      }
    }

    for (final limitation in document.trainingLimitations) {
      final existing = replacing
          ? null
          : await (_database.select(
              _database.trainingLimitations,
            )..where((row) => row.id.equals(limitation.id))).getSingleOrNull();
      if (existing != null &&
          !limitation.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.trainingLimitations)
          .insertOnConflictUpdate(
            TrainingLimitationsCompanion(
              id: Value(limitation.id),
              profileId: Value(profileId),
              bodyPart: Value(limitation.bodyPart),
              severity: Value(limitation.severity),
              note: Value(limitation.note),
              startedAt: Value(limitation.startedAt),
              resolvedAt: Value(limitation.resolvedAt),
              createdAt: Value(limitation.createdAt),
              updatedAt: Value(limitation.updatedAt),
              deletedAt: Value(limitation.deletedAt),
            ),
          );
      _count(counters, existing != null);
      await _appendOutbox(
        entityType: 'training_limitation',
        entityId: limitation.id,
        payload: {...limitation.toJson(), 'profile_id': profileId},
        now: now,
      );
    }
  }

  Future<void> _restoreDailyHealthSummaries(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
    DateTime now,
  ) async {
    for (final summary in document.dailyHealthSummaries) {
      final existing = replacing
          ? null
          : await (_database.select(
              _database.dailyHealthSummaries,
            )..where((row) => row.id.equals(summary.id))).getSingleOrNull();
      if (existing != null && !summary.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.dailyHealthSummaries)
          .insertOnConflictUpdate(
            DailyHealthSummariesCompanion(
              id: Value(summary.id),
              profileId: Value(profileId),
              day: Value(summary.day),
              source: Value(summary.source),
              externalId: Value(summary.externalId),
              steps: Value(summary.steps),
              sleepMinutes: Value(summary.sleepMinutes),
              restingHeartRate: Value(summary.restingHeartRate),
              createdAt: Value(summary.createdAt),
              updatedAt: Value(summary.updatedAt),
              deletedAt: Value(summary.deletedAt),
            ),
          );
      _count(counters, existing != null);
      await _appendOutbox(
        entityType: 'daily_health_summary',
        entityId: summary.id,
        payload: {...summary.toJson(), 'profile_id': profileId},
        now: now,
      );
    }
  }

  Future<void> _restoreCoachFeed(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
    DateTime now,
  ) async {
    for (final item in document.coachFeedItems) {
      final existing = replacing
          ? null
          : await (_database.select(
              _database.coachFeedItems,
            )..where((row) => row.id.equals(item.id))).getSingleOrNull();
      if (existing != null && !item.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.coachFeedItems)
          .insertOnConflictUpdate(
            CoachFeedItemsCompanion(
              id: Value(item.id),
              profileId: Value(profileId),
              kind: Value(item.kind),
              source: Value(item.source),
              externalId: Value(item.externalId),
              title: Value(item.title),
              body: Value(item.body),
              actionLabel: Value(item.actionLabel),
              actionPath: Value(item.actionPath),
              occurredAt: Value(item.occurredAt),
              readAt: Value(item.readAt),
              dismissedAt: Value(item.dismissedAt),
              createdAt: Value(item.createdAt),
              updatedAt: Value(item.updatedAt),
              deletedAt: Value(item.deletedAt),
            ),
          );
      _count(counters, existing != null);
      await _appendOutbox(
        entityType: 'coach_feed_item',
        entityId: item.id,
        payload: {...item.toJson(), 'profile_id': profileId},
        now: now,
      );
    }
  }

  // ---------------------------------------------------------------------
  // Allenamenti (formato 2).
  //
  // Nessuna di queste entità scrive in `sync_outbox`: `SyncPushMapper.map`
  // non conosce ancora i loro entityType e ogni mutation finirebbe nel
  // `default:`, cioè verrebbe cancellata dalla coda contandola come inviata.
  // Finché il gateway non le conosce, gli allenamenti vivono solo in locale e
  // il backup è la loro unica rete di sicurezza.
  // ---------------------------------------------------------------------

  Future<void> _restoreExercises(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
  ) async {
    for (final exercise in document.exercises) {
      final existing = replacing
          ? null
          : await (_database.select(
              _database.exercises,
            )..where((row) => row.id.equals(exercise.id))).getSingleOrNull();
      if (existing != null && !exercise.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.exercises)
          .insertOnConflictUpdate(
            ExercisesCompanion(
              id: Value(exercise.id),
              profileId: Value(profileId),
              name: Value(exercise.name),
              muscleGroup: Value(exercise.muscleGroup),
              trackingMode: Value(exercise.trackingMode),
              notes: Value(exercise.notes),
              imageUrl: Value(exercise.imageUrl),
              defaultRestSec: Value(exercise.defaultRestSec),
              isPreset: Value(exercise.isPreset),
              isSynthetic: Value(exercise.isSynthetic),
              source: Value(exercise.source),
              externalId: Value(exercise.externalId),
              createdAt: Value(exercise.createdAt),
              updatedAt: Value(exercise.updatedAt),
              deletedAt: Value(exercise.deletedAt),
            ),
          );
      _count(counters, existing != null);
    }
  }

  /// Le righe e i blocchi a tempo seguono la scheda: si riscrivono in blocco
  /// come gli ingredienti di una ricetta, perché la loro identità è la
  /// posizione dentro il blocco e non un id che valga da solo.
  Future<void> _restoreRoutines(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
  ) async {
    final exercisesByRoutine = <String, List<BackupRoutineExercise>>{};
    for (final row in document.routineExercises) {
      exercisesByRoutine.putIfAbsent(row.routineId, () => []).add(row);
    }
    final segmentsByRoutine = <String, List<BackupRoutineIntervalSegment>>{};
    for (final row in document.routineIntervalSegments) {
      segmentsByRoutine.putIfAbsent(row.routineId, () => []).add(row);
    }

    for (final routine in document.routines) {
      final existing = replacing
          ? null
          : await (_database.select(
              _database.routines,
            )..where((row) => row.id.equals(routine.id))).getSingleOrNull();
      if (existing != null && !routine.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.routines)
          .insertOnConflictUpdate(
            RoutinesCompanion(
              id: Value(routine.id),
              profileId: Value(profileId),
              name: Value(routine.name),
              notes: Value(routine.notes),
              isCircuit: Value(routine.isCircuit),
              workSec: Value(routine.workSec),
              shortRestSec: Value(routine.shortRestSec),
              longRestSec: Value(routine.longRestSec),
              rounds: Value(routine.rounds),
              warmupWorkSec: Value(routine.warmupWorkSec),
              warmupRestSec: Value(routine.warmupRestSec),
              source: Value(routine.source),
              externalId: Value(routine.externalId),
              createdAt: Value(routine.createdAt),
              updatedAt: Value(routine.updatedAt),
              deletedAt: Value(routine.deletedAt),
            ),
          );
      if (existing != null) {
        await (_database.delete(
          _database.routineExercises,
        )..where((row) => row.routineId.equals(routine.id))).go();
        await (_database.delete(
          _database.routineIntervalSegments,
        )..where((row) => row.routineId.equals(routine.id))).go();
      }
      for (final row
          in exercisesByRoutine[routine.id] ??
              const <BackupRoutineExercise>[]) {
        await _database
            .into(_database.routineExercises)
            .insertOnConflictUpdate(
              RoutineExercisesCompanion(
                id: Value(row.id),
                routineId: Value(row.routineId),
                block: Value(row.block),
                position: Value(row.position),
                exerciseRefId: Value(row.exerciseRefId),
                exerciseId: Value(row.exerciseId),
                exerciseNameSnapshot: Value(row.exerciseNameSnapshot),
                inSupersetWithPrevious: Value(row.inSupersetWithPrevious),
                warmupDurationSec: Value(row.warmupDurationSec),
                prescSets: Value(row.prescSets),
                prescReps: Value(row.prescReps),
                prescDurationSec: Value(row.prescDurationSec),
                prescRestSec: Value(row.prescRestSec),
              ),
            );
      }
      for (final row
          in segmentsByRoutine[routine.id] ??
              const <BackupRoutineIntervalSegment>[]) {
        await _database
            .into(_database.routineIntervalSegments)
            .insertOnConflictUpdate(
              RoutineIntervalSegmentsCompanion(
                id: Value(row.id),
                routineId: Value(row.routineId),
                segmentIndex: Value(row.segmentIndex),
                startIdx: Value(row.startIdx),
                endIdx: Value(row.endIdx),
                workSec: Value(row.workSec),
                restSec: Value(row.restSec),
                longRestSec: Value(row.longRestSec),
                rounds: Value(row.rounds),
              ),
            );
      }
      _count(counters, existing != null);
    }
  }

  /// Il giorno della settimana è la chiave vera (`UNIQUE (profile_id,
  /// weekday)`): se il telefono ha già una riga per quel giorno si riusa il suo
  /// id, altrimenti l'upsert per chiave primaria sbatterebbe contro la UNIQUE.
  Future<void> _restoreWeeklyPlan(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
  ) async {
    for (final day in document.routineWeeklyPlan) {
      final existing = replacing
          ? null
          : await (_database.select(_database.routineWeeklyPlan)..where(
                  (row) =>
                      row.profileId.equals(profileId) &
                      row.weekday.equals(day.weekday),
                ))
                .getSingleOrNull();
      if (existing != null && !day.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.routineWeeklyPlan)
          .insertOnConflictUpdate(
            RoutineWeeklyPlanCompanion(
              id: Value(existing?.id ?? day.id),
              profileId: Value(profileId),
              weekday: Value(day.weekday),
              routineId: Value(day.routineId),
              routineExternalId: Value(day.routineExternalId),
              routineNameSnapshot: Value(day.routineNameSnapshot),
              updatedAt: Value(day.updatedAt),
            ),
          );
      _count(counters, existing != null);
    }
  }

  /// Righe, serie, punti dolenti e blocchi a tempo seguono la sessione: la
  /// sessione è l'unità che ha senso ripristinare, e i figli si riscrivono
  /// tutti insieme perché la loro identità è la posizione.
  Future<void> _restoreWorkouts(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
  ) async {
    final exercisesByWorkout = <String, List<BackupWorkoutExercise>>{};
    for (final row in document.workoutExercises) {
      exercisesByWorkout.putIfAbsent(row.workoutId, () => []).add(row);
    }
    final setsByExercise = <String, List<BackupWorkoutSet>>{};
    for (final row in document.workoutSets) {
      setsByExercise.putIfAbsent(row.workoutExerciseId, () => []).add(row);
    }
    final painByWorkout = <String, List<BackupWorkoutPainPoint>>{};
    for (final row in document.workoutPainPoints) {
      painByWorkout.putIfAbsent(row.workoutId, () => []).add(row);
    }
    final segmentsByWorkout = <String, List<BackupWorkoutIntervalSegment>>{};
    for (final row in document.workoutIntervalSegments) {
      segmentsByWorkout.putIfAbsent(row.workoutId, () => []).add(row);
    }

    for (final workout in document.workouts) {
      final existing = replacing
          ? null
          : await (_database.select(
              _database.workouts,
            )..where((row) => row.id.equals(workout.id))).getSingleOrNull();
      if (existing != null && !workout.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.workouts)
          .insertOnConflictUpdate(
            WorkoutsCompanion(
              id: Value(workout.id),
              profileId: Value(profileId),
              startedAt: Value(workout.startedAt),
              endedAt: Value(workout.endedAt),
              pausedAt: Value(workout.pausedAt),
              accumulatedPauseSeconds: Value(workout.accumulatedPauseSeconds),
              finalDurationSeconds: Value(workout.finalDurationSeconds),
              durationSuspect: Value(workout.durationSuspect),
              routineId: Value(workout.routineId),
              routineExternalId: Value(workout.routineExternalId),
              routineNameSnapshot: Value(workout.routineNameSnapshot),
              notes: Value(workout.notes),
              totalKcal: Value(workout.totalKcal),
              mood: Value(workout.mood),
              rpe: Value(workout.rpe),
              satisfaction: Value(workout.satisfaction),
              feedbackNotes: Value(workout.feedbackNotes),
              xpEarned: Value(workout.xpEarned),
              resumePath: Value(workout.resumePath),
              circuitCheckpointJson: Value(workout.circuitCheckpointJson),
              syncedToHealthConnect: Value(workout.syncedToHealthConnect),
              healthSyncState: Value(workout.healthSyncState),
              healthSyncClaimId: Value(workout.healthSyncClaimId),
              healthSyncAttemptedAt: Value(workout.healthSyncAttemptedAt),
              healthSyncCompletedAt: Value(workout.healthSyncCompletedAt),
              source: Value(workout.source),
              externalId: Value(workout.externalId),
              createdAt: Value(workout.createdAt),
              updatedAt: Value(workout.updatedAt),
              deletedAt: Value(workout.deletedAt),
            ),
          );
      if (existing != null) {
        await _deleteWorkoutChildren(workout.id);
      }
      for (final row
          in exercisesByWorkout[workout.id] ??
              const <BackupWorkoutExercise>[]) {
        await _database
            .into(_database.workoutExercises)
            .insertOnConflictUpdate(
              WorkoutExercisesCompanion(
                id: Value(row.id),
                workoutId: Value(row.workoutId),
                position: Value(row.position),
                exerciseRefId: Value(row.exerciseRefId),
                exerciseId: Value(row.exerciseId),
                exerciseNameSnapshot: Value(row.exerciseNameSnapshot),
                trackingMode: Value(row.trackingMode),
                muscleGroupSnapshot: Value(row.muscleGroupSnapshot),
                restSeconds: Value(row.restSeconds),
                isWarmup: Value(row.isWarmup),
                isCooldown: Value(row.isCooldown),
                isFinisher: Value(row.isFinisher),
                isInSupersetWithPrevious: Value(row.isInSupersetWithPrevious),
                intervalSegmentIndex: Value(row.intervalSegmentIndex),
              ),
            );
        for (final set
            in setsByExercise[row.id] ?? const <BackupWorkoutSet>[]) {
          await _database
              .into(_database.workoutSets)
              .insertOnConflictUpdate(
                WorkoutSetsCompanion(
                  id: Value(set.id),
                  workoutExerciseId: Value(set.workoutExerciseId),
                  position: Value(set.position),
                  weightKg: Value(set.weightKg),
                  reps: Value(set.reps),
                  durationSec: Value(set.durationSec),
                  distanceM: Value(set.distanceM),
                  rpe: Value(set.rpe),
                  isWarmup: Value(set.isWarmup),
                  completed: Value(set.completed),
                ),
              );
        }
      }
      for (final row
          in painByWorkout[workout.id] ?? const <BackupWorkoutPainPoint>[]) {
        await _database
            .into(_database.workoutPainPoints)
            .insertOnConflictUpdate(
              WorkoutPainPointsCompanion(
                id: Value(row.id),
                workoutId: Value(row.workoutId),
                label: Value(row.label),
              ),
            );
      }
      for (final row
          in segmentsByWorkout[workout.id] ??
              const <BackupWorkoutIntervalSegment>[]) {
        await _database
            .into(_database.workoutIntervalSegments)
            .insertOnConflictUpdate(
              WorkoutIntervalSegmentsCompanion(
                id: Value(row.id),
                workoutId: Value(row.workoutId),
                segmentIndex: Value(row.segmentIndex),
                completedMarker: Value(row.completedMarker),
                partialMarker: Value(row.partialMarker),
                completionSignature: Value(row.completionSignature),
              ),
            );
      }
      _count(counters, existing != null);
    }
  }

  /// Le serie si cancellano prima delle righe invece di affidarsi al CASCADE:
  /// la pulizia deve valere anche se le foreign key sono spente.
  Future<void> _deleteWorkoutChildren(String workoutId) async {
    final exerciseIds =
        (await (_database.select(
              _database.workoutExercises,
            )..where((row) => row.workoutId.equals(workoutId))).get())
            .map((row) => row.id)
            .toList(growable: false);
    if (exerciseIds.isNotEmpty) {
      await (_database.delete(
        _database.workoutSets,
      )..where((row) => row.workoutExerciseId.isIn(exerciseIds))).go();
    }
    await (_database.delete(
      _database.workoutExercises,
    )..where((row) => row.workoutId.equals(workoutId))).go();
    await (_database.delete(
      _database.workoutPainPoints,
    )..where((row) => row.workoutId.equals(workoutId))).go();
    await (_database.delete(
      _database.workoutIntervalSegments,
    )..where((row) => row.workoutId.equals(workoutId))).go();
  }

  /// XP e trofei. Le statistiche sono una riga sola per profilo (`UNIQUE
  /// (profile_id)`), quindi si cerca per profilo e non per id.
  ///
  /// Un trofeo già sbloccato non si tocca: il suo `unlockedAt` locale è almeno
  /// altrettanto attendibile di quello del file, e riscriverlo sposterebbe la
  /// data di un traguardo vinto davvero.
  Future<void> _restoreWorkoutStats(
    BackupDocument document,
    String profileId,
    bool replacing,
    _RestoreCounters counters,
  ) async {
    for (final stats in document.workoutProfileStats) {
      final existing = replacing
          ? null
          : await (_database.select(_database.workoutProfileStats)
                  ..where((row) => row.profileId.equals(profileId)))
                .getSingleOrNull();
      if (existing != null && !stats.updatedAt.isAfter(existing.updatedAt)) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.workoutProfileStats)
          .insertOnConflictUpdate(
            WorkoutProfileStatsCompanion(
              id: Value(existing?.id ?? stats.id),
              profileId: Value(profileId),
              totalXp: Value(stats.totalXp),
              currentStreak: Value(stats.currentStreak),
              longestStreak: Value(stats.longestStreak),
              lastWorkoutDay: Value(stats.lastWorkoutDay),
              weeklyWorkoutGoal: Value(stats.weeklyWorkoutGoal),
              weeklyKcalGoal: Value(stats.weeklyKcalGoal),
              reminderEnabled: Value(stats.reminderEnabled),
              reminderHour: Value(stats.reminderHour),
              reminderMinute: Value(stats.reminderMinute),
              healthConnectEnabled: Value(stats.healthConnectEnabled),
              voiceEnabled: Value(stats.voiceEnabled),
              gymBodyWeightKg: Value(stats.gymBodyWeightKg),
              gymExportedAt: Value(stats.gymExportedAt),
              createdAt: Value(stats.createdAt),
              updatedAt: Value(stats.updatedAt),
              deletedAt: Value(stats.deletedAt),
            ),
          );
      _count(counters, existing != null);
    }

    for (final achievement in document.workoutAchievements) {
      final existing = replacing
          ? null
          : await (_database.select(_database.workoutAchievements)..where(
                  (row) =>
                      row.profileId.equals(profileId) &
                      row.slug.equals(achievement.slug),
                ))
                .getSingleOrNull();
      if (existing != null) {
        counters.skipped++;
        continue;
      }
      await _database
          .into(_database.workoutAchievements)
          .insertOnConflictUpdate(
            WorkoutAchievementsCompanion(
              id: Value(achievement.id),
              profileId: Value(profileId),
              slug: Value(achievement.slug),
              unlockedAt: Value(achievement.unlockedAt),
            ),
          );
      counters.created++;
    }
  }

  /// Un backup del formato 1 non contiene gli allenamenti: non sono vuoti,
  /// mancano proprio. Sostituire tutto li cancellerebbe (ogni tabella nuova ha
  /// `ON DELETE CASCADE` verso il profilo) senza avere niente da rimettere, e
  /// un ripristino che perde dati in silenzio è peggio di un ripristino che
  /// non parte.
  Future<void> _refuseLegacyReplace() async {
    final summary = await _workoutDataSummary();
    if (summary == null) {
      return;
    }
    throw BackupWouldLoseDataException(
      'Questo backup è stato fatto prima che l’app tenesse gli allenamenti e '
      'non ne contiene nessuno: sostituendo tutto perderesti $summary. '
      'Usa «Unisci», oppure fai prima un backup nuovo.',
    );
  }

  /// Il formato 2 conosce gli allenamenti ma non i dati introdotti dal
  /// contratto Coach360. In modalita' sostituzione quelle tabelle verrebbero
  /// eliminate insieme al profilo, quindi si applica la stessa protezione del
  /// formato 1 invece di perdere dati in silenzio.
  Future<void> _refuseLegacyDataContractReplace() async {
    final profiles = await _database.select(_database.appProfiles).get();
    final measurements = await _database
        .select(_database.bodyMeasurements)
        .get();
    final hasPersonalDetails = profiles.any(
      (row) => row.heightCm != null || row.birthDate != null || row.sex != null,
    );
    final hasScaleProvenance = measurements.any(
      (row) => row.deviceModel != null || row.rawPayload != null,
    );
    final rows =
        await _countRows(_database.weeklyPlans) +
        await _countRows(_database.dailyCheckIns) +
        await _countRows(_database.goals) +
        await _countRows(_database.bodyImpedanceReadings) +
        await _countRows(_database.trainingProfiles) +
        await _countRows(_database.trainingLimitations) +
        await _countRows(_database.dailyHealthSummaries) +
        await _countRows(_database.coachFeedItems);
    if (rows == 0 && !hasPersonalDetails && !hasScaleProvenance) {
      return;
    }
    throw const BackupWouldLoseDataException(
      'Questo backup è stato fatto prima che Coach360 salvasse check-in, '
      'obiettivi, profilo atleta, dati salute e provenienza della bilancia. '
      'Sostituendo tutto perderesti dati che il file non può ripristinare. '
      'Usa «Unisci», oppure fai prima un backup nuovo.',
    );
  }

  /// Descrive in italiano che cosa c'è da perdere, o null se non c'è niente.
  Future<String?> _workoutDataSummary() async {
    final sessions = await _countRows(_database.workouts);
    final routines = await _countRows(_database.routines);
    final exercises = await _countRows(_database.exercises);
    final achievements = await _countRows(_database.workoutAchievements);
    final pieces = [
      if (sessions > 0) _countLabel(sessions, 'sessione', 'sessioni'),
      if (routines > 0) _countLabel(routines, 'scheda', 'schede'),
      if (exercises > 0) _countLabel(exercises, 'esercizio', 'esercizi'),
      if (achievements > 0) _countLabel(achievements, 'trofeo', 'trofei'),
    ];
    if (pieces.isNotEmpty) {
      return pieces.length == 1
          ? pieces.single
          : '${pieces.take(pieces.length - 1).join(', ')} e ${pieces.last}';
    }
    // Restano il piano settimanale, le statistiche e le circonferenze: nessuno
    // dei quattro conteggi sopra le nomina, ma perderle sarebbe uguale.
    final others =
        await _countRows(_database.routineWeeklyPlan) +
        await _countRows(_database.workoutProfileStats) +
        await _countRows(_database.bodyMeasurementValues);
    return others > 0 ? 'i dati degli allenamenti' : null;
  }

  Future<int> _countRows(TableInfo<Table, Object?> table) async {
    final total = countAll();
    final row = await (_database.selectOnly(
      table,
    )..addColumns([total])).getSingle();
    return row.read(total) ?? 0;
  }

  String _countLabel(int value, String singular, String plural) =>
      value == 1 ? '1 $singular' : '$value $plural';

  Future<Map<String, Set<String>>> _existingKeys() async {
    final foods = await (_database.select(
      _database.foods,
    )..where((row) => row.source.isIn(_builtInFoodSources).not())).get();
    final preferences = await _database.select(_database.foodPreferences).get();
    final targets = await _database.select(_database.nutritionTargets).get();
    final checkIns = await _database.select(_database.dailyCheckIns).get();
    final goals = await _database.select(_database.goals).get();
    final trainingProfiles = await _database
        .select(_database.trainingProfiles)
        .get();
    final trainingLimitations = await _database
        .select(_database.trainingLimitations)
        .get();
    final healthSummaries = await _database
        .select(_database.dailyHealthSummaries)
        .get();
    final coachFeed = await _database.select(_database.coachFeedItems).get();
    return {
      'meal_item': {
        for (final row in await _database.select(_database.mealItems).get())
          row.id,
      },
      'water_log': {
        for (final row in await _database.select(_database.waterLogs).get())
          row.id,
      },
      'body_measurement': {
        for (final row
            in await _database.select(_database.bodyMeasurements).get())
          row.id,
      },
      'fit_recipe': {
        for (final row in await _database.select(_database.fitRecipes).get())
          row.id,
      },
      'meal_template': {
        for (final row in await _database.select(_database.mealTemplates).get())
          row.id,
      },
      'food': {for (final row in foods) row.id},
      'food_preference': {
        for (final row in preferences) '${row.profileId}:${row.foodId}',
      },
      'nutrition_target': {for (final row in targets) row.profileId},
      'daily_check_in': {for (final row in checkIns) row.id},
      'goal': {for (final row in goals) row.id},
      'training_profile': {for (final row in trainingProfiles) row.profileId},
      'training_limitation': {for (final row in trainingLimitations) row.id},
      'daily_health_summary': {for (final row in healthSummaries) row.id},
      'coach_feed_item': {for (final row in coachFeed) row.id},
    };
  }

  Map<String, Set<String>> _restoredKeys(
    BackupDocument document,
    String profileId,
  ) => {
    'meal_item': {for (final row in document.mealItems) row.id},
    'water_log': {for (final row in document.waterLogs) row.id},
    'body_measurement': {for (final row in document.bodyMeasurements) row.id},
    'fit_recipe': {for (final row in document.fitRecipes) row.id},
    'meal_template': {for (final row in document.mealTemplates) row.id},
    'food': {for (final row in document.foods) row.id},
    'food_preference': {
      for (final row in document.foodPreferences) '$profileId:${row.foodId}',
    },
    'nutrition_target': document.nutritionTargets.isEmpty
        ? const <String>{}
        : {profileId},
    'daily_check_in': {for (final row in document.dailyCheckIns) row.id},
    'goal': {for (final row in document.goals) row.id},
    'training_profile': document.trainingProfiles.isEmpty
        ? const <String>{}
        : {profileId},
    'training_limitation': {
      for (final row in document.trainingLimitations) row.id,
    },
    'daily_health_summary': {
      for (final row in document.dailyHealthSummaries) row.id,
    },
    'coach_feed_item': {for (final row in document.coachFeedItems) row.id},
  };

  /// L'ordine è figli prima dei genitori anche dove basterebbe il CASCADE: la
  /// cancellazione non deve dipendere dal PRAGMA delle foreign key.
  ///
  /// Le tabelle degli allenamenti non lasciano tombstone come le altre perché
  /// non hanno un tipo entità sul gateway: non sono mai state spinte, quindi
  /// non c'è niente da cancellare da remoto.
  Future<void> _wipeUserTables() async {
    await _database.delete(_database.coachFeedItems).go();
    await _database.delete(_database.dailyHealthSummaries).go();
    await _database.delete(_database.trainingLimitations).go();
    await _database.delete(_database.trainingProfiles).go();
    await _database.delete(_database.dailyCheckIns).go();
    await _database.delete(_database.goals).go();
    await _database.delete(_database.weeklyPlanSlots).go();
    await _database.delete(_database.weeklyPlans).go();
    await _database.delete(_database.workoutSets).go();
    await _database.delete(_database.workoutExercises).go();
    await _database.delete(_database.workoutPainPoints).go();
    await _database.delete(_database.workoutIntervalSegments).go();
    await _database.delete(_database.workouts).go();
    await _database.delete(_database.routineExercises).go();
    await _database.delete(_database.routineIntervalSegments).go();
    await _database.delete(_database.routineWeeklyPlan).go();
    await _database.delete(_database.routines).go();
    await _database.delete(_database.workoutAchievements).go();
    await _database.delete(_database.workoutProfileStats).go();
    await _database.delete(_database.exercises).go();
    await _database.delete(_database.bodyMeasurementValues).go();
    await _database.delete(_database.bodyImpedanceReadings).go();
    await _database.delete(_database.mealItems).go();
    await _database.delete(_database.meals).go();
    await _database.delete(_database.mealTemplateItems).go();
    await _database.delete(_database.mealTemplates).go();
    await _database.delete(_database.recipeIngredients).go();
    await _database.delete(_database.fitRecipes).go();
    await _database.delete(_database.foodPreferences).go();
    await (_database.delete(
      _database.foods,
    )..where((row) => row.source.isIn(_builtInFoodSources).not())).go();
    await _database.delete(_database.waterLogs).go();
    await _database.delete(_database.bodyMeasurements).go();
    await _database.delete(_database.nutritionTargets).go();
    await _database.delete(_database.appProfiles).go();
  }

  Future<void> _appendTombstones({
    required Map<String, Set<String>> removable,
    required Map<String, Set<String>> restored,
    required DateTime now,
  }) async {
    for (final entry in removable.entries) {
      final survivors = restored[entry.key] ?? const <String>{};
      for (final key in entry.value.difference(survivors)) {
        await _appendOutbox(
          entityType: entry.key,
          entityId: key,
          operation: 'delete',
          payload: {
            ..._identity(entry.key, key),
            'deleted_at': now.toIso8601String(),
          },
          now: now,
        );
      }
    }
  }

  /// Ripete la chiave con cui l’upsert identifica la riga: le tabelle senza
  /// colonna `id` non sarebbero cancellabili con `{'id': ...}`.
  Map<String, Object?> _identity(String entityType, String key) {
    if (entityType == 'food_preference') {
      final parts = key.split(':');
      return {'profile_id': parts.first, 'food_id': parts.last};
    }
    if (entityType == 'nutrition_target') {
      return {'profile_id': key};
    }
    if (entityType == 'training_profile') {
      return {'profile_id': key};
    }
    return {'id': key};
  }

  /// I totali non arrivano mai dal file: si ricalcolano da per 100 g × grammi.
  Nutrients _itemTotals(BackupMealItem item) => NutritionCalculator.scale(
    per100g: Nutrients(
      calories: item.caloriesPer100g,
      protein: item.proteinPer100g,
      carbs: item.carbsPer100g,
      fat: item.fatPer100g,
    ),
    grams: item.grams,
  );

  Nutrients _recipeTotals(List<BackupRecipeIngredient> ingredients) {
    var total = const Nutrients.zero();
    for (final ingredient in ingredients) {
      total =
          total +
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
    return total;
  }

  Map<String, Object?> _totalsJson(Nutrients totals) => {
    'total_calories': totals.calories,
    'total_protein': totals.protein,
    'total_carbs': totals.carbs,
    'total_fat': totals.fat,
  };

  void _count(_RestoreCounters counters, bool existed) {
    if (existed) {
      counters.updated++;
    } else {
      counters.created++;
    }
  }

  Future<void> _appendOutbox({
    required String entityType,
    required String entityId,
    required Map<String, Object?> payload,
    required DateTime now,
    String operation = 'upsert',
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
}

class _RestoreCounters {
  int created = 0;
  int updated = 0;
  int skipped = 0;
}
