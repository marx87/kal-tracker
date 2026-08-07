import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

/// Fixture della v6 scritta a mano: le 28 tabelle che il telefono di Marco ha
/// dopo l'assorbimento di Gym Tracker, con i soli vincoli significativi.
/// Generarla dalla definizione Dart di oggi non proverebbe niente — sarebbe la
/// migrazione a confrontarsi con se stessa. La fixture v7 è già stata scritta
/// con lo stesso pattern in `app_database_v8_test.dart`: chi porterà lo schema
/// a v9 continui da lì.
QueryExecutor _schemaV6({required List<String> seed}) {
  return NativeDatabase.memory(
    setup: (raw) {
      raw
        ..execute('''
          CREATE TABLE app_profiles (
            id TEXT NOT NULL PRIMARY KEY,
            display_name TEXT NOT NULL,
            height_cm REAL NULL,
            birth_date INTEGER NULL,
            sex TEXT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''')
        ..execute('''
          CREATE TABLE meals (
            id TEXT NOT NULL PRIMARY KEY,
            profile_id TEXT NOT NULL REFERENCES app_profiles(id),
            meal_type TEXT NOT NULL,
            eaten_at INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL
          )
        ''')
        // Un indice che il database ha già: `_createMissingIndexes` deve
        // saltarlo, perché il CREATE INDEX generato non ha IF NOT EXISTS.
        ..execute(
          'CREATE INDEX idx_meals_profile_eaten_at '
          'ON meals (profile_id, eaten_at)',
        )
        ..execute('''
          CREATE TABLE meal_items (
            id TEXT NOT NULL PRIMARY KEY,
            meal_id TEXT NOT NULL REFERENCES meals(id) ON DELETE CASCADE,
            food_name TEXT NOT NULL,
            grams REAL NOT NULL,
            calories_per100g REAL NOT NULL,
            protein_per100g REAL NOT NULL,
            carbs_per100g REAL NOT NULL,
            fat_per100g REAL NOT NULL,
            total_calories REAL NOT NULL,
            total_protein REAL NOT NULL,
            total_carbs REAL NOT NULL,
            total_fat REAL NOT NULL,
            source TEXT NOT NULL DEFAULT 'manual',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL
          )
        ''')
        ..execute('''
          CREATE TABLE sync_outbox (
            id TEXT NOT NULL PRIMARY KEY,
            entity_type TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            operation TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            next_attempt_at INTEGER NULL
          )
        ''')
        ..execute('''
          CREATE TABLE nutrition_targets (
            profile_id TEXT NOT NULL PRIMARY KEY
              REFERENCES app_profiles(id) ON DELETE CASCADE,
            daily_calories REAL NOT NULL,
            daily_protein REAL NOT NULL,
            daily_carbs REAL NOT NULL,
            daily_fat REAL NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            CHECK (daily_calories > 0)
          )
        ''')
        ..execute('''
          CREATE TABLE water_logs (
            id TEXT NOT NULL PRIMARY KEY,
            profile_id TEXT NOT NULL
              REFERENCES app_profiles(id) ON DELETE CASCADE,
            milliliters INTEGER NOT NULL,
            logged_at INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            CHECK (milliliters > 0 AND milliliters <= 10000)
          )
        ''')
        // La v5 ha già portato impedenza, percentuali, formula e sorgente: la
        // v7 aggiunge SOLO device_model e raw_payload, che qui non ci sono.
        ..execute('''
          CREATE TABLE body_measurements (
            id TEXT NOT NULL PRIMARY KEY,
            profile_id TEXT NOT NULL
              REFERENCES app_profiles(id) ON DELETE CASCADE,
            weight_kg REAL NOT NULL,
            measured_at INTEGER NOT NULL,
            has_impedance INTEGER NOT NULL DEFAULT 0,
            impedance_ohm REAL NULL,
            body_fat_pct REAL NULL,
            muscle_pct REAL NULL,
            skeletal_muscle_pct REAL NULL,
            bone_pct REAL NULL,
            protein_pct REAL NULL,
            water_pct REAL NULL,
            subcutaneous_fat_pct REAL NULL,
            visceral_fat_index INTEGER NULL,
            bmr_kcal INTEGER NULL,
            formula_version TEXT NULL,
            source TEXT NOT NULL DEFAULT 'manual',
            external_id TEXT NULL,
            note TEXT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            CHECK (weight_kg >= 20 AND weight_kg <= 500),
            CHECK (impedance_ohm IS NULL OR
                   (impedance_ohm > 0 AND impedance_ohm <= 2000)),
            CHECK (source IN ('manual', 'renpho_ble', 'renpho_csv',
                              'gym_tracker', 'health_connect')),
            UNIQUE (profile_id, source, external_id)
          )
        ''')
        ..execute('''
          CREATE TABLE foods (
            id TEXT NOT NULL PRIMARY KEY,
            owner_profile_id TEXT NULL
              REFERENCES app_profiles(id) ON DELETE SET NULL,
            name TEXT NOT NULL,
            brand TEXT NULL,
            barcode TEXT NULL UNIQUE,
            calories_per100g REAL NOT NULL,
            protein_per100g REAL NOT NULL,
            carbs_per100g REAL NOT NULL,
            fat_per100g REAL NOT NULL,
            default_serving_grams REAL NOT NULL DEFAULT 100.0,
            source TEXT NOT NULL DEFAULT 'custom',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            CHECK (calories_per100g >= 0)
          )
        ''')
        ..execute('''
          CREATE TABLE food_preferences (
            profile_id TEXT NOT NULL
              REFERENCES app_profiles(id) ON DELETE CASCADE,
            food_id TEXT NOT NULL REFERENCES foods(id) ON DELETE CASCADE,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            use_count INTEGER NOT NULL DEFAULT 0,
            last_used_at INTEGER NULL,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY (profile_id, food_id)
          )
        ''')
        ..execute('''
          CREATE TABLE fit_recipes (
            id TEXT NOT NULL PRIMARY KEY,
            profile_id TEXT NOT NULL
              REFERENCES app_profiles(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            description TEXT NULL,
            instructions TEXT NULL,
            tags TEXT NULL,
            servings INTEGER NOT NULL,
            prep_minutes INTEGER NOT NULL DEFAULT 0,
            total_calories REAL NOT NULL,
            total_protein REAL NOT NULL,
            total_carbs REAL NOT NULL,
            total_fat REAL NOT NULL,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            CHECK (servings > 0 AND servings <= 100)
          )
        ''')
        ..execute('''
          CREATE TABLE recipe_ingredients (
            id TEXT NOT NULL PRIMARY KEY,
            recipe_id TEXT NOT NULL
              REFERENCES fit_recipes(id) ON DELETE CASCADE,
            food_id TEXT NULL REFERENCES foods(id) ON DELETE SET NULL,
            position INTEGER NOT NULL,
            name TEXT NOT NULL,
            grams REAL NOT NULL,
            calories_per100g REAL NOT NULL,
            protein_per100g REAL NOT NULL,
            carbs_per100g REAL NOT NULL,
            fat_per100g REAL NOT NULL,
            CHECK (grams > 0),
            UNIQUE (recipe_id, position)
          )
        ''')
        ..execute('''
          CREATE TABLE meal_templates (
            id TEXT NOT NULL PRIMARY KEY,
            profile_id TEXT NOT NULL
              REFERENCES app_profiles(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            meal_type TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL
          )
        ''')
        ..execute('''
          CREATE TABLE meal_template_items (
            id TEXT NOT NULL PRIMARY KEY,
            template_id TEXT NOT NULL
              REFERENCES meal_templates(id) ON DELETE CASCADE,
            position INTEGER NOT NULL,
            food_name TEXT NOT NULL,
            grams REAL NOT NULL,
            calories_per100g REAL NOT NULL,
            protein_per100g REAL NOT NULL,
            carbs_per100g REAL NOT NULL,
            fat_per100g REAL NOT NULL,
            CHECK (grams > 0),
            UNIQUE (template_id, position)
          )
        ''')
        ..execute('''
          CREATE TABLE weekly_plans (
            id TEXT NOT NULL PRIMARY KEY,
            profile_id TEXT NOT NULL
              REFERENCES app_profiles(id) ON DELETE CASCADE,
            start_date INTEGER NOT NULL,
            days INTEGER NOT NULL,
            meals_csv TEXT NOT NULL,
            status TEXT NOT NULL,
            remote_job_id TEXT NULL,
            notes TEXT NULL,
            request_json TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            CHECK (days >= 1 AND days <= 14),
            CHECK (status IN ('generating', 'ready', 'failed'))
          )
        ''')
        ..execute('''
          CREATE TABLE weekly_plan_slots (
            id TEXT NOT NULL PRIMARY KEY,
            plan_id TEXT NOT NULL
              REFERENCES weekly_plans(id) ON DELETE CASCADE,
            date INTEGER NOT NULL,
            meal TEXT NOT NULL,
            recipe_id TEXT NULL
              REFERENCES fit_recipes(id) ON DELETE SET NULL,
            recipe_name_snapshot TEXT NOT NULL,
            servings REAL NOT NULL,
            why TEXT NULL,
            done_at INTEGER NULL,
            diary_entry_ids TEXT NULL,
            CHECK (servings > 0),
            UNIQUE (plan_id, date, meal)
          )
        ''')
        ..execute('''
          CREATE TABLE exercises (
            id TEXT NOT NULL PRIMARY KEY,
            profile_id TEXT NOT NULL
              REFERENCES app_profiles(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            muscle_group TEXT NOT NULL,
            tracking_mode TEXT NOT NULL,
            notes TEXT NULL,
            image_url TEXT NULL,
            default_rest_sec INTEGER NULL,
            is_preset INTEGER NOT NULL DEFAULT 0,
            is_synthetic INTEGER NOT NULL DEFAULT 0,
            source TEXT NOT NULL DEFAULT 'manual',
            external_id TEXT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            CHECK (source IN ('manual', 'gym_tracker', 'cooldown_preset')),
            UNIQUE (profile_id, source, external_id)
          )
        ''')
        ..execute('''
          CREATE TABLE routines (
            id TEXT NOT NULL PRIMARY KEY,
            profile_id TEXT NOT NULL
              REFERENCES app_profiles(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            notes TEXT NULL,
            is_circuit INTEGER NOT NULL DEFAULT 0,
            work_sec INTEGER NOT NULL DEFAULT 30,
            short_rest_sec INTEGER NOT NULL DEFAULT 30,
            long_rest_sec INTEGER NOT NULL DEFAULT 60,
            rounds INTEGER NOT NULL DEFAULT 3,
            warmup_work_sec INTEGER NOT NULL DEFAULT 30,
            warmup_rest_sec INTEGER NOT NULL DEFAULT 15,
            source TEXT NOT NULL DEFAULT 'manual',
            external_id TEXT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            CHECK (source IN ('manual', 'gym_tracker')),
            UNIQUE (profile_id, source, external_id)
          )
        ''')
        ..execute('''
          CREATE TABLE routine_exercises (
            id TEXT NOT NULL PRIMARY KEY,
            routine_id TEXT NOT NULL
              REFERENCES routines(id) ON DELETE CASCADE,
            block TEXT NOT NULL,
            position INTEGER NOT NULL,
            exercise_ref_id TEXT NOT NULL,
            exercise_id TEXT NULL
              REFERENCES exercises(id) ON DELETE SET NULL,
            exercise_name_snapshot TEXT NOT NULL,
            in_superset_with_previous INTEGER NOT NULL DEFAULT 0,
            warmup_duration_sec INTEGER NULL,
            presc_sets INTEGER NULL,
            presc_reps INTEGER NULL,
            presc_duration_sec INTEGER NULL,
            presc_rest_sec INTEGER NULL,
            CHECK (block IN ('warmup', 'main', 'finisher')),
            CHECK ((block = 'warmup') = (warmup_duration_sec IS NOT NULL)),
            UNIQUE (routine_id, block, position)
          )
        ''')
        ..execute('''
          CREATE TABLE routine_interval_segments (
            id TEXT NOT NULL PRIMARY KEY,
            routine_id TEXT NOT NULL
              REFERENCES routines(id) ON DELETE CASCADE,
            segment_index INTEGER NOT NULL,
            start_idx INTEGER NOT NULL,
            end_idx INTEGER NOT NULL,
            work_sec INTEGER NOT NULL DEFAULT 40,
            rest_sec INTEGER NOT NULL DEFAULT 20,
            long_rest_sec INTEGER NOT NULL DEFAULT 0,
            rounds INTEGER NOT NULL DEFAULT 1,
            CHECK (end_idx > start_idx),
            UNIQUE (routine_id, segment_index)
          )
        ''')
        ..execute('''
          CREATE TABLE routine_weekly_plan (
            id TEXT NOT NULL PRIMARY KEY,
            profile_id TEXT NOT NULL
              REFERENCES app_profiles(id) ON DELETE CASCADE,
            weekday INTEGER NOT NULL,
            routine_id TEXT NULL REFERENCES routines(id) ON DELETE SET NULL,
            routine_external_id TEXT NULL,
            routine_name_snapshot TEXT NULL,
            updated_at INTEGER NOT NULL,
            CHECK (weekday BETWEEN 1 AND 7),
            UNIQUE (profile_id, weekday)
          )
        ''')
        ..execute('''
          CREATE TABLE workouts (
            id TEXT NOT NULL PRIMARY KEY,
            profile_id TEXT NOT NULL
              REFERENCES app_profiles(id) ON DELETE CASCADE,
            started_at INTEGER NOT NULL,
            ended_at INTEGER NULL,
            paused_at INTEGER NULL,
            accumulated_pause_seconds INTEGER NOT NULL DEFAULT 0,
            final_duration_seconds INTEGER NULL,
            duration_suspect INTEGER NOT NULL DEFAULT 0,
            routine_id TEXT NULL REFERENCES routines(id) ON DELETE SET NULL,
            routine_external_id TEXT NULL,
            routine_name_snapshot TEXT NULL,
            notes TEXT NULL,
            total_kcal REAL NULL,
            mood INTEGER NULL,
            rpe INTEGER NULL,
            satisfaction INTEGER NULL,
            feedback_notes TEXT NULL,
            xp_earned INTEGER NULL,
            resume_path TEXT NULL,
            circuit_checkpoint_json TEXT NULL,
            synced_to_health_connect INTEGER NOT NULL DEFAULT 0,
            health_sync_state TEXT NULL,
            health_sync_claim_id TEXT NULL,
            health_sync_attempted_at INTEGER NULL,
            health_sync_completed_at INTEGER NULL,
            source TEXT NOT NULL DEFAULT 'manual',
            external_id TEXT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            CHECK (ended_at IS NULL OR ended_at >= started_at),
            CHECK (source IN ('manual', 'gym_tracker')),
            UNIQUE (profile_id, source, external_id)
          )
        ''')
        // Anche l'indice parziale c'è già: `_createPartialIndexes` lo ricrea a
        // ogni apertura e senza IF NOT EXISTS fallirebbe.
        ..execute(
          'CREATE UNIQUE INDEX idx_workouts_one_active ON workouts '
          '(profile_id) WHERE ended_at IS NULL AND deleted_at IS NULL',
        )
        ..execute('''
          CREATE TABLE workout_exercises (
            id TEXT NOT NULL PRIMARY KEY,
            workout_id TEXT NOT NULL
              REFERENCES workouts(id) ON DELETE CASCADE,
            position INTEGER NOT NULL,
            exercise_ref_id TEXT NOT NULL,
            exercise_id TEXT NULL
              REFERENCES exercises(id) ON DELETE SET NULL,
            exercise_name_snapshot TEXT NOT NULL,
            tracking_mode TEXT NOT NULL,
            muscle_group_snapshot TEXT NULL,
            rest_seconds INTEGER NULL,
            is_warmup INTEGER NOT NULL DEFAULT 0,
            is_cooldown INTEGER NOT NULL DEFAULT 0,
            is_finisher INTEGER NOT NULL DEFAULT 0,
            is_in_superset_with_previous INTEGER NOT NULL DEFAULT 0,
            interval_segment_index INTEGER NULL,
            CHECK (is_warmup + is_cooldown + is_finisher <= 1),
            UNIQUE (workout_id, position)
          )
        ''')
        ..execute('''
          CREATE TABLE workout_sets (
            id TEXT NOT NULL PRIMARY KEY,
            workout_exercise_id TEXT NOT NULL
              REFERENCES workout_exercises(id) ON DELETE CASCADE,
            position INTEGER NOT NULL,
            weight_kg REAL NULL,
            reps INTEGER NULL,
            duration_sec INTEGER NULL,
            distance_m REAL NULL,
            rpe INTEGER NULL,
            is_warmup INTEGER NOT NULL DEFAULT 0,
            completed INTEGER NOT NULL DEFAULT 0,
            CHECK (rpe IS NULL OR (rpe >= 1 AND rpe <= 10)),
            UNIQUE (workout_exercise_id, position)
          )
        ''')
        ..execute('''
          CREATE TABLE workout_pain_points (
            id TEXT NOT NULL PRIMARY KEY,
            workout_id TEXT NOT NULL
              REFERENCES workouts(id) ON DELETE CASCADE,
            label TEXT NOT NULL,
            UNIQUE (workout_id, label)
          )
        ''')
        ..execute('''
          CREATE TABLE workout_interval_segments (
            id TEXT NOT NULL PRIMARY KEY,
            workout_id TEXT NOT NULL
              REFERENCES workouts(id) ON DELETE CASCADE,
            segment_index INTEGER NOT NULL,
            completed_marker INTEGER NOT NULL DEFAULT 0,
            partial_marker INTEGER NOT NULL DEFAULT 0,
            completion_signature TEXT NULL,
            CHECK (completed_marker = 1 OR partial_marker = 1),
            UNIQUE (workout_id, segment_index)
          )
        ''')
        ..execute('''
          CREATE TABLE workout_profile_stats (
            id TEXT NOT NULL PRIMARY KEY,
            profile_id TEXT NOT NULL
              REFERENCES app_profiles(id) ON DELETE CASCADE,
            total_xp INTEGER NOT NULL DEFAULT 0,
            current_streak INTEGER NOT NULL DEFAULT 0,
            longest_streak INTEGER NOT NULL DEFAULT 0,
            last_workout_day INTEGER NULL,
            weekly_workout_goal INTEGER NOT NULL DEFAULT 3,
            weekly_kcal_goal INTEGER NOT NULL DEFAULT 1500,
            reminder_enabled INTEGER NOT NULL DEFAULT 0,
            reminder_hour INTEGER NOT NULL DEFAULT 18,
            reminder_minute INTEGER NOT NULL DEFAULT 0,
            health_connect_enabled INTEGER NOT NULL DEFAULT 0,
            voice_enabled INTEGER NOT NULL DEFAULT 1,
            gym_body_weight_kg REAL NULL,
            gym_exported_at INTEGER NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            CHECK (longest_streak >= current_streak),
            UNIQUE (profile_id)
          )
        ''')
        ..execute('''
          CREATE TABLE workout_achievements (
            id TEXT NOT NULL PRIMARY KEY,
            profile_id TEXT NOT NULL
              REFERENCES app_profiles(id) ON DELETE CASCADE,
            slug TEXT NOT NULL,
            unlocked_at INTEGER NULL,
            UNIQUE (profile_id, slug)
          )
        ''')
        ..execute('''
          CREATE TABLE body_measurement_values (
            id TEXT NOT NULL PRIMARY KEY,
            measurement_id TEXT NOT NULL
              REFERENCES body_measurements(id) ON DELETE CASCADE,
            label TEXT NOT NULL,
            value REAL NOT NULL,
            CHECK (value > 0 AND value <= 1000),
            UNIQUE (measurement_id, label)
          )
        ''');
      for (final statement in seed) {
        raw.execute(statement);
      }
      raw.execute('PRAGMA user_version = 6');
    },
  );
}

/// Il profilo di Marco dopo l'import di Gym: anagrafica compilata, una pesata
/// con impedenza importata dal CSV Renpho, una circonferenza, una sessione
/// chiusa e i suoi XP.
List<String> get _seedV6 => [
  "INSERT INTO app_profiles VALUES "
      "('marco-v6', 'Marco', 182.0, -72576000, 'M', 0, 0)",
  "INSERT INTO body_measurements (id, profile_id, weight_kg, measured_at, "
      "has_impedance, impedance_ohm, body_fat_pct, formula_version, source, "
      "external_id, created_at, updated_at) VALUES "
      "('pesata-1', 'marco-v6', 95.8, 1000, 1, 512.5, 25.2, 'renpho-app', "
      "'renpho_csv', '2026-08-05T08:39:30', 0, 0)",
  "INSERT INTO body_measurement_values VALUES "
      "('giro-1', 'pesata-1', 'Vita', 106.0)",
  "INSERT INTO exercises (id, profile_id, name, muscle_group, tracking_mode, "
      "source, external_id, created_at, updated_at) VALUES "
      "('ex-1', 'marco-v6', 'Panca piana', 'petto', 'weightReps', "
      "'gym_tracker', 'ex-1', 0, 0)",
  "INSERT INTO workouts (id, profile_id, started_at, ended_at, source, "
      "external_id, total_kcal, xp_earned, created_at, updated_at) VALUES "
      "('wk-1', 'marco-v6', 1000, 4600, 'gym_tracker', 'wk-1', 412.5, 320, "
      "0, 0)",
  "INSERT INTO workout_exercises (id, workout_id, position, exercise_ref_id, "
      "exercise_id, exercise_name_snapshot, tracking_mode) VALUES "
      "('wkex-1', 'wk-1', 0, 'ex-1', 'ex-1', 'Panca piana', 'weightReps')",
  "INSERT INTO workout_sets (id, workout_exercise_id, position, weight_kg, "
      "reps, completed) VALUES ('set-1', 'wkex-1', 0, 80.0, 8, 1)",
  "INSERT INTO workout_profile_stats (id, profile_id, total_xp, "
      "current_streak, longest_streak, created_at, updated_at) VALUES "
      "('stats-1', 'marco-v6', 11370, 2, 5, 0, 0)",
];

/// Fixture della v1: quattro tabelle sole. Serve a provare la catena intera,
/// perché il ramo della v5 ricrea `body_measurements` dalla definizione Dart
/// di oggi — comprese le colonne della v7.
QueryExecutor _schemaV1() {
  return NativeDatabase.memory(
    setup: (raw) {
      raw
        ..execute('''
          CREATE TABLE app_profiles (
            id TEXT NOT NULL PRIMARY KEY,
            display_name TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''')
        ..execute('''
          CREATE TABLE meals (
            id TEXT NOT NULL PRIMARY KEY,
            profile_id TEXT NOT NULL REFERENCES app_profiles(id),
            meal_type TEXT NOT NULL,
            eaten_at INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL
          )
        ''')
        ..execute('''
          CREATE TABLE meal_items (
            id TEXT NOT NULL PRIMARY KEY,
            meal_id TEXT NOT NULL REFERENCES meals(id) ON DELETE CASCADE,
            food_name TEXT NOT NULL,
            grams REAL NOT NULL,
            calories_per100g REAL NOT NULL,
            protein_per100g REAL NOT NULL,
            carbs_per100g REAL NOT NULL,
            fat_per100g REAL NOT NULL,
            total_calories REAL NOT NULL,
            total_protein REAL NOT NULL,
            total_carbs REAL NOT NULL,
            total_fat REAL NOT NULL,
            source TEXT NOT NULL DEFAULT 'manual',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL
          )
        ''')
        ..execute('''
          CREATE TABLE sync_outbox (
            id TEXT NOT NULL PRIMARY KEY,
            entity_type TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            operation TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            next_attempt_at INTEGER NULL
          )
        ''')
        ..execute(
          "INSERT INTO app_profiles VALUES ('marco-v1', 'Marco v1', 0, 0)",
        )
        ..execute('PRAGMA user_version = 1');
    },
  );
}

Future<Set<String>> _indexNames(AppDatabase database) async {
  final rows = await database
      .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
      .get();
  return {for (final row in rows) row.read<String>('name')};
}

void main() {
  setUpAll(AppTime.initialize);

  test('migra v6 a v7 conservando profilo, pesate e allenamenti', () async {
    final database = AppDatabase(_schemaV6(seed: _seedV6));
    addTearDown(database.close);

    final version = await database
        .customSelect('PRAGMA user_version')
        .map((row) => row.read<int>('user_version'))
        .getSingle();
    final profile = await database.select(database.appProfiles).getSingle();
    final measurement = await database
        .select(database.bodyMeasurements)
        .getSingle();
    final circonferenza = await database
        .select(database.bodyMeasurementValues)
        .getSingle();
    final workout = await database.select(database.workouts).getSingle();
    final stats = await database
        .select(database.workoutProfileStats)
        .getSingle();

    expect(version, 9);
    expect(profile.displayName, 'Marco');
    expect(profile.heightCm, closeTo(182, 0.0001));
    expect(profile.sex, 'M');
    expect(measurement.weightKg, closeTo(95.8, 0.0001));
    expect(measurement.impedanceOhm, closeTo(512.5, 0.0001));
    expect(measurement.formulaVersion, 'renpho-app');
    expect(circonferenza.label, 'Vita');
    expect(workout.totalKcal, closeTo(412.5, 0.0001));
    expect(stats.totalXp, 11370);
  });

  test('le pesate migrate arrivano senza bilancia dichiarata', () async {
    final database = AppDatabase(_schemaV6(seed: _seedV6));
    addTearDown(database.close);

    final measurement = await database
        .select(database.bodyMeasurements)
        .getSingle();
    final letture = await database.select(database.bodyImpedanceReadings).get();

    // Le righe importate dal CSV non hanno una trama grezza da conservare:
    // NULL è la risposta onesta, non una stringa vuota.
    expect(measurement.deviceModel, isNull);
    expect(measurement.rawPayload, isNull);
    expect(letture, isEmpty);
  });

  test('una lettura Bluetooth completa entra tutta', () async {
    final database = AppDatabase(_schemaV6(seed: _seedV6));
    addTearDown(database.close);
    final now = AppTime.nowUtc();

    await database
        .into(database.bodyMeasurements)
        .insert(
          BodyMeasurementsCompanion.insert(
            id: 'ble-1',
            profileId: 'marco-v6',
            weightKg: 95.8,
            measuredAt: now,
            createdAt: now,
            updatedAt: now,
            hasImpedance: const Value(true),
            impedanceOhm: const Value(512.5),
            bodyFatPct: const Value(25.2),
            musclePct: const Value(71.1),
            skeletalMusclePct: const Value(43.0),
            bonePct: const Value(3.7),
            proteinPct: const Value(15.4),
            waterPct: const Value(52.1),
            subcutaneousFatPct: const Value(21.9),
            visceralFatIndex: const Value(12),
            bmrKcal: const Value(1918),
            formulaVersion: const Value('bia-v1'),
            source: const Value('renpho_ble'),
            externalId: const Value('QN-Scale:2026-08-06T07:12:03'),
            deviceModel: const Value('QN-Scale'),
            rawPayload: const Value('02:0f:1a:00:25:5e:03:c9'),
          ),
        );

    // Quattro segmenti e due frequenze: è la lettura che una bilancia a otto
    // elettrodi produce, e deve entrare senza una v8.
    await database.batch((batch) {
      batch.insertAll(database.bodyImpedanceReadings, [
        BodyImpedanceReadingsCompanion.insert(
          id: 'imp-1',
          measurementId: 'ble-1',
          segment: 'whole',
          ohm: 512.5,
          frequencyHz: const Value(50000),
        ),
        BodyImpedanceReadingsCompanion.insert(
          id: 'imp-2',
          measurementId: 'ble-1',
          segment: 'whole',
          ohm: 640.0,
          frequencyHz: const Value(5000),
        ),
        BodyImpedanceReadingsCompanion.insert(
          id: 'imp-3',
          measurementId: 'ble-1',
          segment: 'leftArm',
          ohm: 320.4,
          frequencyHz: const Value(50000),
        ),
        // Il protocollo della QN-Scale non dichiara la frequenza: si lascia
        // vuota invece di scriverci dentro il valore tipico.
        BodyImpedanceReadingsCompanion.insert(
          id: 'imp-4',
          measurementId: 'ble-1',
          segment: 'trunk',
          ohm: 24.8,
        ),
      ]);
    });

    final saved = await (database.select(
      database.bodyMeasurements,
    )..where((row) => row.id.equals('ble-1'))).getSingle();
    final letture = await database.select(database.bodyImpedanceReadings).get();

    expect(saved.source, 'renpho_ble');
    expect(saved.deviceModel, 'QN-Scale');
    expect(saved.rawPayload, '02:0f:1a:00:25:5e:03:c9');
    expect(saved.formulaVersion, 'bia-v1');
    expect(letture, hasLength(4));
    expect(
      letture.where((row) => row.frequencyHz == null).single.segment,
      'trunk',
    );
  });

  test(
    'cancellare la pesata porta via le sue impedenze, non il contrario',
    () async {
      final database = AppDatabase(_schemaV6(seed: _seedV6));
      addTearDown(database.close);

      await database
          .into(database.bodyImpedanceReadings)
          .insert(
            BodyImpedanceReadingsCompanion.insert(
              id: 'imp-1',
              measurementId: 'pesata-1',
              segment: 'whole',
              ohm: 512.5,
            ),
          );

      await (database.delete(
        database.bodyMeasurements,
      )..where((row) => row.id.equals('pesata-1'))).go();

      expect(await database.select(database.bodyImpedanceReadings).get(), []);
    },
  );

  test(
    'un database migrato applica i vincoli della v7 quanto uno nuovo',
    () async {
      for (final (label, database) in <(String, AppDatabase)>[
        ('migrato', AppDatabase(_schemaV6(seed: _seedV6))),
        ('nuovo', AppDatabase(NativeDatabase.memory())),
      ]) {
        addTearDown(database.close);
        final profileId = label == 'migrato'
            ? 'marco-v6'
            : (await LocalProfileRepository(database).getOrCreateMarco()).id;
        final now = AppTime.nowUtc();
        final day = DateTime.utc(2026, 8, 6);

        DailyCheckInsCompanion checkIn({
          required String id,
          Value<double?> sleepHours = const Value(7.5),
          Value<int?> energyScore = const Value(4),
          DateTime? on,
        }) => DailyCheckInsCompanion.insert(
          id: id,
          profileId: profileId,
          day: on ?? day,
          createdAt: now,
          updatedAt: now,
          sleepHours: sleepHours,
          energyScore: energyScore,
        );

        // Energia fuori scala.
        await expectLater(
          database
              .into(database.dailyCheckIns)
              .insert(
                checkIn(id: '$label-energia', energyScore: const Value(9)),
              ),
          throwsA(isA<Exception>()),
          reason: 'energy_score oltre 5 su database $label',
        );
        // Una notte di 30 ore è un errore di digitazione.
        await expectLater(
          database
              .into(database.dailyCheckIns)
              .insert(checkIn(id: '$label-sonno', sleepHours: const Value(30))),
          throwsA(isA<Exception>()),
          reason: 'sleep_hours oltre 16 su database $label',
        );
        // Una riga viva senza nessuno dei due campi conterebbe come giorno
        // compilato pur non contenendo niente.
        await expectLater(
          database
              .into(database.dailyCheckIns)
              .insert(
                checkIn(
                  id: '$label-vuoto',
                  sleepHours: const Value(null),
                  energyScore: const Value(null),
                ),
              ),
          throwsA(isA<Exception>()),
          reason: 'check-in senza sonno né energia su database $label',
        );

        GoalsCompanion goal({
          required String id,
          String targetLevel = 'defined',
          String phase = 'approach',
          double targetWeightKg = 80.5,
          double paceKgPerWeek = 0.5,
          Value<String?> outcome = const Value.absent(),
          Value<DateTime?> closedAt = const Value.absent(),
        }) => GoalsCompanion.insert(
          id: id,
          profileId: profileId,
          targetWeightKg: targetWeightKg,
          targetLevel: targetLevel,
          paceKgPerWeek: paceKgPerWeek,
          startedAt: now,
          startWeightKg: 95.8,
          startFatFreeMassKg: 71.66,
          createdAt: now,
          updatedAt: now,
          phase: Value(phase),
          outcome: outcome,
          closedAt: closedAt,
        );

        // Un livello che non esiste nella scala.
        await expectLater(
          database
              .into(database.goals)
              .insert(goal(id: '$label-livello', targetLevel: 'scolpito')),
          throwsA(isA<Exception>()),
          reason: 'target_level ignoto su database $label',
        );
        // Una fase inventata.
        await expectLater(
          database
              .into(database.goals)
              .insert(goal(id: '$label-fase', phase: 'definizione')),
          throwsA(isA<Exception>()),
          reason: 'phase ignota su database $label',
        );
        // Un esito senza data di chiusura è un obiettivo chiuso a metà.
        await expectLater(
          database
              .into(database.goals)
              .insert(
                goal(id: '$label-esito', outcome: const Value('reached')),
              ),
          throwsA(isA<Exception>()),
          reason: 'outcome senza closed_at su database $label',
        );
        // Un peso traguardo che non è un peso.
        await expectLater(
          database
              .into(database.goals)
              .insert(goal(id: '$label-peso', targetWeightKg: 8)),
          throwsA(isA<Exception>()),
          reason: 'target_weight_kg sotto il minimo su database $label',
        );

        // L'impedenza è la misura grezza: zero significa non letta.
        await expectLater(
          database
              .into(database.bodyImpedanceReadings)
              .insert(
                BodyImpedanceReadingsCompanion.insert(
                  id: '$label-ohm',
                  measurementId: label == 'migrato' ? 'pesata-1' : 'assente',
                  segment: 'whole',
                  ohm: 0,
                ),
              ),
          throwsA(isA<Exception>()),
          reason: 'ohm nullo su database $label',
        );
      }
    },
  );

  test('lo stesso giorno ha un check-in solo', () async {
    final database = AppDatabase(_schemaV6(seed: _seedV6));
    addTearDown(database.close);
    final now = AppTime.nowUtc();
    final day = DateTime.utc(2026, 8, 6);

    await database
        .into(database.dailyCheckIns)
        .insert(
          DailyCheckInsCompanion.insert(
            id: 'chk-1',
            profileId: 'marco-v6',
            day: day,
            createdAt: now,
            updatedAt: now,
            sleepHours: const Value(7.5),
          ),
        );

    await expectLater(
      database
          .into(database.dailyCheckIns)
          .insert(
            DailyCheckInsCompanion.insert(
              id: 'chk-2',
              profileId: 'marco-v6',
              day: day,
              createdAt: now,
              updatedAt: now,
              energyScore: const Value(4),
            ),
          ),
      throwsA(isA<Exception>()),
    );

    // Il giorno cancellato resta come tombstone: è così che la
    // sincronizzazione impara che è stato svuotato.
    await (database.update(
      database.dailyCheckIns,
    )..where((row) => row.id.equals('chk-1'))).write(
      DailyCheckInsCompanion(
        sleepHours: const Value(null),
        energyScore: const Value(null),
        deletedAt: Value(now),
      ),
    );
    final tombstone = await database.select(database.dailyCheckIns).getSingle();
    expect(tombstone.deletedAt, isNotNull);
    expect(tombstone.sleepHours, isNull);
  });

  test(
    'due letture di corpo intero senza frequenza sono la stessa lettura',
    () async {
      final database = AppDatabase(_schemaV6(seed: _seedV6));
      addTearDown(database.close);

      BodyImpedanceReadingsCompanion lettura(String id) =>
          BodyImpedanceReadingsCompanion.insert(
            id: id,
            measurementId: 'pesata-1',
            segment: 'whole',
            ohm: 512.5,
          );

      await database.into(database.bodyImpedanceReadings).insert(lettura('a'));

      // In SQLite due NULL non collidono mai: senza l'indice parziale la
      // UNIQUE della tabella lascerebbe passare il doppione.
      await expectLater(
        database.into(database.bodyImpedanceReadings).insert(lettura('b')),
        throwsA(isA<Exception>()),
      );
    },
  );

  test('gli indici della v7 esistono anche su un database migrato', () async {
    final migrato = AppDatabase(_schemaV6(seed: _seedV6));
    final nuovo = AppDatabase(NativeDatabase.memory());
    addTearDown(migrato.close);
    addTearDown(nuovo.close);

    // Basta aprirli: le migrazioni girano alla prima query.
    await migrato.select(migrato.appProfiles).get();
    await nuovo.select(nuovo.appProfiles).get();

    final indiciMigrato = await _indexNames(migrato);
    final indiciNuovo = await _indexNames(nuovo);

    for (final index in [
      'idx_daily_check_ins_profile_day',
      'idx_goals_profile_started',
      'idx_body_impedance_readings_measurement',
      'idx_body_impedance_readings_undeclared',
      'idx_workouts_one_active',
    ]) {
      expect(indiciMigrato, contains(index), reason: 'manca $index');
      expect(indiciNuovo, contains(index), reason: 'manca $index');
    }
  });

  test('chi arriva dalla v1 riceve le colonne della v7 una volta sola', () async {
    final database = AppDatabase(_schemaV1());
    addTearDown(database.close);
    final now = AppTime.nowUtc();

    // Il ramo della v5 ricostruisce `body_measurements` dalla definizione Dart
    // di oggi, che contiene già device_model e raw_payload: se il ramo della v7
    // provasse ad aggiungerle di nuovo, la migrazione da v1 morirebbe con
    // «duplicate column name».
    final version = await database
        .customSelect('PRAGMA user_version')
        .map((row) => row.read<int>('user_version'))
        .getSingle();
    expect(version, 9);
    expect(
      (await database.select(database.appProfiles).getSingle()).displayName,
      'Marco v1',
    );

    await database
        .into(database.bodyMeasurements)
        .insert(
          BodyMeasurementsCompanion.insert(
            id: 'ble-v1',
            profileId: 'marco-v1',
            weightKg: 95.8,
            measuredAt: now,
            createdAt: now,
            updatedAt: now,
            deviceModel: const Value('QN-Scale'),
            rawPayload: const Value('02:0f'),
          ),
        );
    final saved = await database.select(database.bodyMeasurements).getSingle();
    expect(saved.deviceModel, 'QN-Scale');
    expect(saved.rawPayload, '02:0f');
  });
}
