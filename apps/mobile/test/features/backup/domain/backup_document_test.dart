import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/backup/domain/backup_document.dart';

void main() {
  group('BackupDocument', () {
    test('conserva i dati in un giro completo di encode e decode', () {
      final document = _document();

      final restored = BackupDocument.decode(document.encode());

      expect(restored.formatVersion, BackupDocument.currentFormatVersion);
      expect(restored.appVersion, '0.2.0+2');
      expect(restored.exportedAt, DateTime.utc(2026, 8, 3, 9, 30));
      expect(restored.profile.displayName, 'Marco');
      expect(restored.mealItems, hasLength(1));
      expect(restored.mealItems.single.foodName, 'Riso basmati cotto');
      expect(restored.mealItems.single.grams, 150);
      expect(restored.mealItems.single.totalCalories, 195);
      expect(restored.meals.single.mealType, 'lunch');
      expect(restored.rowCount, 3);
      expect(restored.checksum, document.checksum);
    });

    test('rifiuta un file con il checksum manomesso', () {
      final document = _document();
      final tampered = jsonDecode(document.encode()) as Map<String, Object?>;
      final data = tampered['data']! as Map<String, Object?>;
      final items = data['meal_items']! as List<Object?>;
      (items.single! as Map<String, Object?>)['grams'] = 300.0;

      expect(
        () => BackupDocument.decode(jsonEncode(tampered)),
        throwsA(
          isA<BackupFormatException>().having(
            (error) => error.message,
            'message',
            contains('danneggiato'),
          ),
        ),
      );
    });

    test('rifiuta un formato di backup più recente', () {
      final document = _document();
      final future = jsonDecode(document.encode()) as Map<String, Object?>;
      future['format_version'] = BackupDocument.currentFormatVersion + 1;

      expect(
        () => BackupDocument.decode(jsonEncode(future)),
        throwsA(
          isA<BackupFormatException>().having(
            (error) => error.message,
            'message',
            contains('aggiorna Kal Tracker'),
          ),
        ),
      );
    });

    test('rifiuta grammi non positivi e nutrienti negativi', () {
      expect(
        () => BackupMealItem.fromJson(_mealItemJson(grams: 0)),
        throwsA(isA<BackupFormatException>()),
      );
      expect(
        () => BackupMealItem.fromJson(_mealItemJson(calories: -1)),
        throwsA(isA<BackupFormatException>()),
      );
      expect(
        () => BackupMealItem.fromJson(_mealItemJson(name: '  ')),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('rifiuta un file che non è JSON', () {
      expect(
        () => BackupDocument.decode('questo non è un backup'),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('conserva le sezioni degli allenamenti', () {
      final document = _document(withWorkouts: true);

      final restored = BackupDocument.decode(document.encode());

      expect(restored.formatVersion, 2);
      expect(restored.coversWorkouts, isTrue);
      expect(restored.exercises.single.isSynthetic, isTrue);
      expect(restored.workouts.single.finalDurationSeconds, 3900);
      expect(restored.workouts.single.durationSuspect, isTrue);
      expect(restored.workoutSets.single.weightKg, 62.5);
      expect(restored.workoutSets.single.reps, 8);
      expect(restored.workoutSets.single.durationSec, isNull);
      expect(restored.workoutProfileStats.single.totalXp, 11370);
      expect(restored.workoutAchievements.single.slug, 'pr_10');
      expect(restored.workoutAchievements.single.unlockedAt, isNull);
      expect(restored.bodyMeasurementValues.single.label, 'Vita');
      expect(restored.rowCount, 11);
      expect(restored.checksum, document.checksum);
    });

    test('accetta durate senza tetto sulle 24 ore', () {
      final document = _document(withWorkouts: true, finalDurationSeconds: 0);

      final restored = BackupDocument.decode(document.encode());

      expect(restored.workouts.single.finalDurationSeconds, 0);
      expect(
        BackupWorkout.fromJson({
          ..._workoutJson(),
          'final_duration_seconds': 1929600,
          'accumulated_pause_seconds': 200000,
        }).finalDurationSeconds,
        1929600,
      );
    });

    test('rifiuta valori fuori scala nelle sezioni nuove', () {
      expect(
        () => BackupWorkout.fromJson({..._workoutJson(), 'mood': 6}),
        throwsA(isA<BackupFormatException>()),
      );
      expect(
        () => BackupWorkout.fromJson({..._workoutJson(), 'rpe': 0}),
        throwsA(isA<BackupFormatException>()),
      );
      expect(
        () => BackupWorkout.fromJson({..._workoutJson(), 'total_kcal': -1.0}),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('legge un backup del formato 1 senza le sezioni nuove', () {
      final legacy = _document(formatVersion: 1);
      final raw = jsonDecode(legacy.encode()) as Map<String, Object?>;
      final data = raw['data']! as Map<String, Object?>;

      final restored = BackupDocument.decode(legacy.encode());

      expect(data.containsKey('workouts'), isFalse);
      expect(data.containsKey('body_measurement_values'), isFalse);
      expect(restored.formatVersion, 1);
      expect(restored.coversWorkouts, isFalse);
      expect(restored.workouts, isEmpty);
      expect(restored.exercises, isEmpty);
      expect(restored.mealItems, hasLength(1));
    });

    test('il checksum di un backup del formato 1 resta valido dopo la v2', () {
      // Il file è quello scritto dalla versione precedente dell'app, con la
      // sua firma: se il corpo si riscrivesse con le sezioni nuove (anche
      // vuote) ogni backup vecchio risulterebbe danneggiato.
      const legacy =
          '{"format_version":1,"app_version":"0.2.0+2","exported_at":'
          '"2026-08-03T09:30:00.000Z","data":{"profile":{"id":"profile-1",'
          '"display_name":"Marco","created_at":"2026-08-03T09:00:00.000Z",'
          '"updated_at":"2026-08-03T09:00:00.000Z"},"meals":[],'
          '"meal_items":[],"nutrition_targets":[],"water_logs":[],'
          '"body_measurements":[{"id":"weight-1","profile_id":"profile-1",'
          '"weight_kg":80.5,"measured_at":"2026-08-03T09:00:00.000Z",'
          '"note":null,"created_at":"2026-08-03T09:00:00.000Z",'
          '"updated_at":"2026-08-03T09:00:00.000Z","deleted_at":null}],'
          '"foods":[],"food_preferences":[],"fit_recipes":[],'
          '"recipe_ingredients":[],"meal_templates":[],'
          '"meal_template_items":[]},"checksum":'
          '"1b4d9d3e6c8f0a2d4b6e8c0a2d4f6b8e0c2a4d6f8b0e2c4a6d8f0b2e4c6a8d0f"}';
      final signed = _sign(legacy);

      final restored = BackupDocument.decode(signed);

      expect(restored.formatVersion, 1);
      expect(restored.bodyMeasurements.single.hasImpedance, isFalse);
      expect(restored.bodyMeasurements.single.source, 'manual');
      expect(restored.bodyMeasurements.single.weightKg, 80.5);
    });

    test('rifiuta un backup del formato 1 manomesso', () {
      final signed = jsonDecode(
        _sign(
          '{"format_version":1,"app_version":"0.2.0+2","exported_at":'
          '"2026-08-03T09:30:00.000Z","data":{"profile":{"id":"profile-1",'
          '"display_name":"Marco","created_at":"2026-08-03T09:00:00.000Z",'
          '"updated_at":"2026-08-03T09:00:00.000Z"},"meals":[],'
          '"meal_items":[],"nutrition_targets":[],"water_logs":[],'
          '"body_measurements":[],"foods":[],"food_preferences":[],'
          '"fit_recipes":[],"recipe_ingredients":[],"meal_templates":[],'
          '"meal_template_items":[]},"checksum":"da-ricalcolare"}',
        ),
      );
      (signed! as Map<String, Object?>)['app_version'] = '9.9.9';

      expect(
        () => BackupDocument.decode(jsonEncode(signed)),
        throwsA(isA<BackupFormatException>()),
      );
    });
  });
}

/// Rifirma un file scritto a mano: il checksum è sul corpo senza la chiave
/// «checksum», esattamente come lo calcola l'app.
String _sign(String raw) {
  final root = jsonDecode(raw)! as Map<String, Object?>;
  final body = {...root}..remove('checksum');
  return jsonEncode({
    ...body,
    'checksum': sha256.convert(utf8.encode(jsonEncode(body))).toString(),
  });
}

Map<String, Object?> _mealItemJson({
  double grams = 150,
  double calories = 130,
  String name = 'Riso basmati cotto',
}) => {
  'id': 'item-1',
  'meal_id': 'meal-1',
  'food_name': name,
  'grams': grams,
  'calories_per_100g': calories,
  'protein_per_100g': 2.7,
  'carbs_per_100g': 28.2,
  'fat_per_100g': 0.3,
  'total_calories': 195.0,
  'total_protein': 4.05,
  'total_carbs': 42.3,
  'total_fat': 0.45,
  'source': 'manual',
  'created_at': '2026-08-03T09:00:00.000Z',
  'updated_at': '2026-08-03T09:00:00.000Z',
  'deleted_at': null,
};

Map<String, Object?> _workoutJson() => {
  'id': 'workout-1',
  'profile_id': 'profile-1',
  'started_at': '2026-08-03T07:00:00.000Z',
  'ended_at': '2026-08-03T08:05:00.000Z',
  'paused_at': null,
  'accumulated_pause_seconds': 0,
  'final_duration_seconds': 3900,
  'duration_suspect': true,
  'routine_id': null,
  'routine_external_id': 'routine-sparita',
  'routine_name_snapshot': 'Giorno1 spalle petto tricipiti',
  'notes': null,
  'total_kcal': 477.78,
  'mood': 4,
  'rpe': 7,
  'satisfaction': 5,
  'feedback_notes': null,
  'xp_earned': 120,
  'resume_path': null,
  'circuit_checkpoint_json': null,
  'synced_to_health_connect': false,
  'health_sync_state': null,
  'health_sync_claim_id': null,
  'health_sync_attempted_at': null,
  'health_sync_completed_at': null,
  'source': 'gym_tracker',
  'external_id': 'gym-workout-1',
  'created_at': '2026-08-03T09:00:00.000Z',
  'updated_at': '2026-08-03T09:00:00.000Z',
  'deleted_at': null,
};

BackupDocument _document({
  bool withWorkouts = false,
  int formatVersion = BackupDocument.currentFormatVersion,
  int finalDurationSeconds = 3900,
}) {
  final moment = DateTime.utc(2026, 8, 3, 9);
  return BackupDocument(
    formatVersion: formatVersion,
    appVersion: '0.2.0+2',
    exportedAt: DateTime.utc(2026, 8, 3, 9, 30),
    profile: BackupProfile(
      id: 'profile-1',
      displayName: 'Marco',
      createdAt: moment,
      updatedAt: moment,
    ),
    meals: [
      BackupMeal(
        id: 'meal-1',
        profileId: 'profile-1',
        mealType: 'lunch',
        eatenAt: moment,
        createdAt: moment,
        updatedAt: moment,
      ),
    ],
    mealItems: [BackupMealItem.fromJson(_mealItemJson())],
    nutritionTargets: const [],
    waterLogs: const [],
    bodyMeasurements: withWorkouts
        ? [
            BackupBodyMeasurement(
              id: 'weight-1',
              profileId: 'profile-1',
              weightKg: 94.5,
              measuredAt: moment,
              hasImpedance: true,
              impedanceOhm: 512,
              bodyFatPct: 24.3,
              formulaVersion: 'renpho-1',
              source: 'renpho_ble',
              externalId: 'renpho-1',
              createdAt: moment,
              updatedAt: moment,
            ),
          ]
        : const [],
    foods: const [],
    foodPreferences: const [],
    fitRecipes: const [],
    recipeIngredients: const [],
    mealTemplates: const [],
    mealTemplateItems: const [],
    bodyMeasurementValues: withWorkouts
        ? const [
            BackupBodyMeasurementValue(
              id: 'girth-1',
              measurementId: 'weight-1',
              label: 'Vita',
              value: 96,
            ),
          ]
        : const [],
    exercises: withWorkouts
        ? [
            BackupExercise(
              id: 'cd-childpose',
              profileId: 'profile-1',
              name: 'Posizione del bambino',
              muscleGroup: 'mobilita',
              trackingMode: 'timed',
              defaultRestSec: 10,
              isPreset: true,
              isSynthetic: true,
              source: 'cooldown_preset',
              createdAt: moment,
              updatedAt: moment,
            ),
          ]
        : const [],
    workouts: withWorkouts
        ? [
            BackupWorkout.fromJson({
              ..._workoutJson(),
              'final_duration_seconds': finalDurationSeconds,
            }),
          ]
        : const [],
    workoutExercises: withWorkouts
        ? const [
            BackupWorkoutExercise(
              id: 'workout-exercise-1',
              workoutId: 'workout-1',
              position: 0,
              exerciseRefId: 'cd-childpose',
              exerciseId: 'cd-childpose',
              exerciseNameSnapshot: 'Posizione del bambino',
              trackingMode: 'weightReps',
              muscleGroupSnapshot: 'petto',
              isWarmup: false,
              isCooldown: false,
              isFinisher: false,
              isInSupersetWithPrevious: false,
            ),
          ]
        : const [],
    workoutSets: withWorkouts
        ? const [
            BackupWorkoutSet(
              id: 'set-1',
              workoutExerciseId: 'workout-exercise-1',
              position: 0,
              weightKg: 62.5,
              reps: 8,
              isWarmup: false,
              completed: true,
            ),
          ]
        : const [],
    workoutProfileStats: withWorkouts
        ? [
            BackupWorkoutProfileStats(
              id: 'stats-1',
              profileId: 'profile-1',
              totalXp: 11370,
              currentStreak: 2,
              longestStreak: 2,
              weeklyWorkoutGoal: 4,
              weeklyKcalGoal: 1500,
              reminderEnabled: true,
              reminderHour: 18,
              reminderMinute: 0,
              healthConnectEnabled: true,
              voiceEnabled: true,
              gymBodyWeightKg: 94.7,
              createdAt: moment,
              updatedAt: moment,
            ),
          ]
        : const [],
    workoutAchievements: withWorkouts
        ? const [
            BackupWorkoutAchievement(
              id: 'achievement-1',
              profileId: 'profile-1',
              slug: 'pr_10',
            ),
          ]
        : const [],
  );
}
