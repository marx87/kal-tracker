import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/database/local_settings_store.dart';
import 'package:kal_tracker/core/time/app_time.dart';

/// Fixture della v7 scritta a mano: le 31 tabelle che il telefono di Marco ha
/// dopo check-in, obiettivo e impedenze multiple, con i soli vincoli
/// significativi. Generarla dalla definizione Dart di oggi non proverebbe
/// niente — sarebbe la migrazione a confrontarsi con se stessa. Chi porterà lo
/// schema a v9 dovrà scrivere la propria fixture v8 con lo stesso pattern.
///
/// Gli indici ci sono TUTTI, a differenza della fixture v6: alla v7 non ci si
/// arriva se non per creazione o per migrazione, e sia `onCreate` sia
/// `_createMissingIndexes` li lasciano tutti sul posto. Riprodurne solo due
/// racconterebbe un telefono che non esiste, e soprattutto non metterebbe alla
/// prova il passo che rischia davvero: il `CREATE INDEX` generato non ha
/// `IF NOT EXISTS`, quindi la v8 deve saltare uno per uno i ventisette indici
/// che trova già lì.
QueryExecutor _schemaV7({required List<String> seed}) {
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
        ..execute('CREATE INDEX idx_meal_items_meal_id ON meal_items (meal_id)')
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
          'CREATE INDEX idx_sync_outbox_created_at '
          'ON sync_outbox (created_at)',
        )
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
        ..execute(
          'CREATE INDEX idx_water_logs_profile_logged_at '
          'ON water_logs (profile_id, logged_at)',
        )
        // Qui la v7 ha già messo device_model e raw_payload: sono le due
        // colonne che distinguono questa fixture da quella della v6.
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
            device_model TEXT NULL,
            raw_payload TEXT NULL,
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
        ..execute(
          'CREATE INDEX idx_body_measurements_profile_measured_at '
          'ON body_measurements (profile_id, measured_at)',
        )
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
        ..execute('CREATE INDEX idx_foods_name ON foods (name)')
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
        ..execute(
          'CREATE INDEX idx_food_preferences_profile_recent '
          'ON food_preferences (profile_id, last_used_at)',
        )
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
        ..execute(
          'CREATE INDEX idx_fit_recipes_profile_updated_at '
          'ON fit_recipes (profile_id, updated_at)',
        )
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
        ..execute(
          'CREATE INDEX idx_recipe_ingredients_recipe_position '
          'ON recipe_ingredients (recipe_id, position)',
        )
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
        ..execute(
          'CREATE INDEX idx_meal_templates_profile_updated_at '
          'ON meal_templates (profile_id, updated_at)',
        )
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
        ..execute(
          'CREATE INDEX idx_meal_template_items_template_position '
          'ON meal_template_items (template_id, position)',
        )
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
        ..execute(
          'CREATE INDEX idx_weekly_plans_profile_start '
          'ON weekly_plans (profile_id, start_date)',
        )
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
        ..execute(
          'CREATE INDEX idx_weekly_plan_slots_plan_date '
          'ON weekly_plan_slots (plan_id, date)',
        )
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
        ..execute(
          'CREATE INDEX idx_exercises_profile_name '
          'ON exercises (profile_id, name)',
        )
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
        ..execute(
          'CREATE INDEX idx_routines_profile_name '
          'ON routines (profile_id, name)',
        )
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
        ..execute(
          'CREATE INDEX idx_routine_exercises_routine_block_position '
          'ON routine_exercises (routine_id, block, position)',
        )
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
        ..execute(
          'CREATE INDEX idx_routine_interval_segments_routine '
          'ON routine_interval_segments (routine_id, segment_index)',
        )
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
        ..execute(
          'CREATE INDEX idx_workouts_profile_started '
          'ON workouts (profile_id, started_at)',
        )
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
        ..execute(
          'CREATE INDEX idx_workout_exercises_workout_position '
          'ON workout_exercises (workout_id, position)',
        )
        ..execute(
          'CREATE INDEX idx_workout_exercises_exercise_ref '
          'ON workout_exercises (exercise_ref_id)',
        )
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
        ..execute(
          'CREATE INDEX idx_workout_sets_exercise_position '
          'ON workout_sets (workout_exercise_id, position)',
        )
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
        ''')
        ..execute(
          'CREATE INDEX idx_body_measurement_values_label '
          'ON body_measurement_values (measurement_id, label)',
        )
        ..execute('''
          CREATE TABLE daily_check_ins (
            id TEXT NOT NULL PRIMARY KEY,
            profile_id TEXT NOT NULL
              REFERENCES app_profiles(id) ON DELETE CASCADE,
            day INTEGER NOT NULL,
            sleep_hours REAL NULL,
            energy_score INTEGER NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            CHECK (sleep_hours IS NULL OR
                   (sleep_hours >= 0 AND sleep_hours <= 16)),
            CHECK (energy_score IS NULL OR
                   (energy_score >= 1 AND energy_score <= 5)),
            CHECK (deleted_at IS NOT NULL OR
                   sleep_hours IS NOT NULL OR energy_score IS NOT NULL),
            UNIQUE (profile_id, day)
          )
        ''')
        ..execute(
          'CREATE INDEX idx_daily_check_ins_profile_day '
          'ON daily_check_ins (profile_id, day)',
        )
        ..execute('''
          CREATE TABLE goals (
            id TEXT NOT NULL PRIMARY KEY,
            profile_id TEXT NOT NULL
              REFERENCES app_profiles(id) ON DELETE CASCADE,
            target_weight_kg REAL NOT NULL,
            target_level TEXT NOT NULL,
            pace_kg_per_week REAL NOT NULL,
            started_at INTEGER NOT NULL,
            start_weight_kg REAL NOT NULL,
            start_fat_free_mass_kg REAL NOT NULL,
            phase TEXT NOT NULL DEFAULT 'approach',
            phase_started_at INTEGER NULL,
            closed_at INTEGER NULL,
            outcome TEXT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            CHECK (pace_kg_per_week > 0 AND pace_kg_per_week <= 5),
            CHECK (target_level IN ('soft', 'normal', 'lean', 'athletic',
                                    'defined', 'veryDefined')),
            CHECK (phase IN ('approach', 'consolidation', 'maintenance')),
            CHECK (outcome IS NULL OR closed_at IS NOT NULL)
          )
        ''')
        ..execute(
          'CREATE INDEX idx_goals_profile_started '
          'ON goals (profile_id, started_at)',
        )
        ..execute('''
          CREATE TABLE body_impedance_readings (
            id TEXT NOT NULL PRIMARY KEY,
            measurement_id TEXT NOT NULL
              REFERENCES body_measurements(id) ON DELETE CASCADE,
            segment TEXT NOT NULL,
            frequency_hz INTEGER NULL,
            ohm REAL NOT NULL,
            CHECK (segment IN ('whole', 'leftArm', 'rightArm', 'leftLeg',
                               'rightLeg', 'trunk')),
            CHECK (ohm > 0 AND ohm <= 5000),
            UNIQUE (measurement_id, segment, frequency_hz)
          )
        ''')
        ..execute(
          'CREATE INDEX idx_body_impedance_readings_measurement '
          'ON body_impedance_readings (measurement_id)',
        )
        // Il secondo indice parziale della v7. Come quello dei workout,
        // `_createPartialIndexes` lo riemette a ogni apertura: senza
        // IF NOT EXISTS la v8 morirebbe qui.
        ..execute(
          'CREATE UNIQUE INDEX idx_body_impedance_readings_undeclared '
          'ON body_impedance_readings (measurement_id, segment) '
          'WHERE frequency_hz IS NULL',
        );
      for (final statement in seed) {
        raw.execute(statement);
      }
      raw.execute('PRAGMA user_version = 7');
    },
  );
}

/// Il giorno del check-in seminato, in secondi dall'epoca: è l'etichetta del
/// 6 agosto 2026, mezzanotte UTC, la stessa convenzione con cui
/// `daily_check_ins` scrive il giorno civile.
const _giornoCheckIn = 1785974400;

/// Il telefono di Marco alla v7: anagrafica, una pesata Bluetooth completa con
/// la sua impedenza e una circonferenza, il check-in del mattino, l'obiettivo
/// in corso, una sessione chiusa coi suoi XP — e due righe già in coda per la
/// sincronizzazione, che servono a rendere non banale il confronto sull'outbox.
List<String> get _seedV7 => [
  "INSERT INTO app_profiles VALUES "
      "('marco-v7', 'Marco', 182.0, -72576000, 'M', 0, 0)",
  // La pesata è arrivata dalla bilancia, non dal CSV: alla v7 device_model e
  // raw_payload esistono già e devono attraversare la migrazione intatti.
  "INSERT INTO body_measurements (id, profile_id, weight_kg, measured_at, "
      "has_impedance, impedance_ohm, body_fat_pct, formula_version, source, "
      "external_id, device_model, raw_payload, created_at, updated_at) VALUES "
      "('pesata-1', 'marco-v7', 94.5, 1000, 1, 512.5, 25.2, 'bia-v1', "
      "'renpho_ble', 'QN-Scale:2026-08-05T08:39:30', 'QN-Scale', "
      "'02:0f:1a:00:25:5e:03:c9', 0, 0)",
  "INSERT INTO body_impedance_readings (id, measurement_id, segment, ohm) "
      "VALUES ('imp-1', 'pesata-1', 'whole', 512.5)",
  "INSERT INTO body_measurement_values VALUES "
      "('giro-1', 'pesata-1', 'Vita', 106.0)",
  "INSERT INTO daily_check_ins (id, profile_id, day, sleep_hours, "
      "energy_score, created_at, updated_at) VALUES "
      "('chk-1', 'marco-v7', $_giornoCheckIn, 7.5, 4, 0, 0)",
  "INSERT INTO goals (id, profile_id, target_weight_kg, target_level, "
      "pace_kg_per_week, started_at, start_weight_kg, start_fat_free_mass_kg, "
      "phase, created_at, updated_at) VALUES "
      "('goal-1', 'marco-v7', 80.5, 'defined', 0.5, 1000, 95.8, 71.66, "
      "'approach', 0, 0)",
  "INSERT INTO exercises (id, profile_id, name, muscle_group, tracking_mode, "
      "source, external_id, created_at, updated_at) VALUES "
      "('ex-1', 'marco-v7', 'Panca piana', 'petto', 'weightReps', "
      "'gym_tracker', 'ex-1', 0, 0)",
  "INSERT INTO workouts (id, profile_id, started_at, ended_at, source, "
      "external_id, total_kcal, xp_earned, created_at, updated_at) VALUES "
      "('wk-1', 'marco-v7', 1000, 4600, 'gym_tracker', 'wk-1', 412.5, 320, "
      "0, 0)",
  "INSERT INTO workout_exercises (id, workout_id, position, exercise_ref_id, "
      "exercise_id, exercise_name_snapshot, tracking_mode) VALUES "
      "('wkex-1', 'wk-1', 0, 'ex-1', 'ex-1', 'Panca piana', 'weightReps')",
  "INSERT INTO workout_sets (id, workout_exercise_id, position, weight_kg, "
      "reps, completed) VALUES ('set-1', 'wkex-1', 0, 80.0, 8, 1)",
  "INSERT INTO workout_profile_stats (id, profile_id, total_xp, "
      "current_streak, longest_streak, created_at, updated_at) VALUES "
      "('stats-1', 'marco-v7', 11370, 2, 5, 0, 0)",
  "INSERT INTO sync_outbox VALUES ('out-1', 'body_measurement', 'pesata-1', "
      "'upsert', '{}', 1000, 0, NULL)",
  "INSERT INTO sync_outbox VALUES ('out-2', 'goal', 'goal-1', 'upsert', "
      "'{}', 1001, 0, NULL)",
];

Future<Set<String>> _indexNames(AppDatabase database) async {
  final rows = await database
      .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
      .get();
  return {for (final row in rows) row.read<String>('name')};
}

Future<List<String>> _outboxIds(AppDatabase database) async {
  final rows = await (database.select(
    database.syncOutbox,
  )..orderBy([(row) => OrderingTerm.asc(row.id)])).get();
  return [for (final row in rows) row.id];
}

void main() {
  setUpAll(AppTime.initialize);

  test('migra v7 a v8 conservando profilo, pesate, obiettivo e '
      'allenamenti', () async {
    final database = AppDatabase(_schemaV7(seed: _seedV7));
    addTearDown(database.close);

    final version = await database
        .customSelect('PRAGMA user_version')
        .map((row) => row.read<int>('user_version'))
        .getSingle();
    final profile = await database.select(database.appProfiles).getSingle();
    final measurement = await database
        .select(database.bodyMeasurements)
        .getSingle();
    final impedenza = await database
        .select(database.bodyImpedanceReadings)
        .getSingle();
    final circonferenza = await database
        .select(database.bodyMeasurementValues)
        .getSingle();
    final checkIn = await database.select(database.dailyCheckIns).getSingle();
    final goal = await database.select(database.goals).getSingle();
    final workout = await database.select(database.workouts).getSingle();
    final serie = await database.select(database.workoutSets).getSingle();
    final stats = await database
        .select(database.workoutProfileStats)
        .getSingle();
    // Interrogarla è l'unico modo di dire che è nata: se il ramo `from < 8`
    // non fosse girato, qui uscirebbe «no such table».
    final impostazioni = await database.select(database.localSettings).get();

    expect(version, 11);
    expect(impostazioni, isEmpty);
    expect(profile.displayName, 'Marco');
    expect(profile.heightCm, closeTo(182, 0.0001));
    expect(profile.sex, 'M');
    expect(measurement.weightKg, closeTo(94.5, 0.0001));
    expect(measurement.impedanceOhm, closeTo(512.5, 0.0001));
    expect(measurement.deviceModel, 'QN-Scale');
    expect(measurement.rawPayload, '02:0f:1a:00:25:5e:03:c9');
    expect(impedenza.segment, 'whole');
    expect(impedenza.frequencyHz, isNull);
    expect(circonferenza.label, 'Vita');
    expect(checkIn.sleepHours, closeTo(7.5, 0.0001));
    expect(checkIn.energyScore, 4);
    // Drift rilegge gli istanti in ora locale: quel che deve tornare è
    // l'etichetta del giorno, cioè la mezzanotte UTC del 6 agosto.
    expect(checkIn.day.toUtc(), DateTime.utc(2026, 8, 6));
    expect(goal.targetLevel, 'defined');
    expect(goal.targetWeightKg, closeTo(80.5, 0.0001));
    expect(goal.closedAt, isNull);
    expect(workout.totalKcal, closeTo(412.5, 0.0001));
    expect(serie.weightKg, closeTo(80, 0.0001));
    expect(stats.totalXp, 11370);
  });

  test('la tabella nasce e nasce vuota: nessuna bilancia inventata', () async {
    final database = AppDatabase(_schemaV7(seed: _seedV7));
    addTearDown(database.close);
    final store = LocalSettingsStore(database);

    // La v8 crea la tabella, non ci scrive dentro: finché Marco non sceglie
    // una bilancia a mano non c'è nessun indirizzo da ricordare, e «assente»
    // deve leggersi come null, non come stringa vuota.
    expect(await database.select(database.localSettings).get(), isEmpty);
    expect(await store.read(LocalSettingsStore.scaleDeviceId), isNull);
    expect(await store.read('chiave.mai.scritta'), isNull);
  });

  test(
    'lo store ricorda la bilancia e la dimentica, su migrato e su nuovo',
    () async {
      for (final (label, database) in <(String, AppDatabase)>[
        ('migrato', AppDatabase(_schemaV7(seed: _seedV7))),
        ('nuovo', AppDatabase(NativeDatabase.memory())),
      ]) {
        addTearDown(database.close);
        final store = LocalSettingsStore(database);

        await store.write(
          LocalSettingsStore.scaleDeviceId,
          'AA:BB:CC:DD:EE:FF',
        );
        await store.write(LocalSettingsStore.scaleDeviceName, 'QN-Scale');

        expect(
          await store.read(LocalSettingsStore.scaleDeviceId),
          'AA:BB:CC:DD:EE:FF',
          reason: 'indirizzo non riletto su database $label',
        );
        expect(
          await store.read(LocalSettingsStore.scaleDeviceName),
          'QN-Scale',
          reason: 'nome non riletto su database $label',
        );

        // Marco cambia bilancia: la chiave è la stessa, e
        // `insertOnConflictUpdate` deve sovrascrivere la riga, non affiancarne
        // una seconda — due indirizzi ricordati insieme sono un indirizzo
        // scelto a caso alla prossima pesata.
        // L'orario si spinge indietro di un giorno prima di riscrivere. Senza,
        // il confronto sarebbe vuoto: `updated_at` viaggia in secondi, due
        // scritture di fila cadono nello stesso secondo, e l'asserzione
        // passerebbe identica anche se `write` non toccasse mai quel campo.
        final ieri = DateTime.utc(2026, 8, 5, 7, 12);
        await (database.update(
              database.localSettings,
            )..where((row) => row.key.equals(LocalSettingsStore.scaleDeviceId)))
            .write(LocalSettingsCompanion(updatedAt: Value(ieri)));
        final prima =
            await (database.select(database.localSettings)..where(
                  (row) => row.key.equals(LocalSettingsStore.scaleDeviceId),
                ))
                .getSingle();
        expect(prima.updatedAt.toUtc(), ieri);
        await store.write(
          LocalSettingsStore.scaleDeviceId,
          '11:22:33:44:55:66',
        );
        final dopo =
            await (database.select(database.localSettings)..where(
                  (row) => row.key.equals(LocalSettingsStore.scaleDeviceId),
                ))
                .getSingle();

        expect(
          dopo.value,
          '11:22:33:44:55:66',
          reason: 'sovrascrittura non applicata su database $label',
        );
        expect(
          dopo.updatedAt.isAfter(prima.updatedAt),
          isTrue,
          reason: 'updated_at non aggiornato dalla riscrittura su $label',
        );
        expect(
          await database.select(database.localSettings).get(),
          hasLength(2),
          reason: 'la chiave si è duplicata su database $label',
        );

        // «Dimentica questa bilancia» toglie l'indirizzo e lascia stare il
        // resto: le chiavi qui dentro sono indipendenti.
        await store.remove(LocalSettingsStore.scaleDeviceId);

        expect(
          await store.read(LocalSettingsStore.scaleDeviceId),
          isNull,
          reason: 'indirizzo ancora presente su database $label',
        );
        expect(
          await store.read(LocalSettingsStore.scaleDeviceName),
          'QN-Scale',
          reason: 'remove ha portato via anche il nome su database $label',
        );

        // Dimenticare due volte non è un errore: il pulsante resta lì anche
        // quando non c'è più niente da dimenticare.
        await store.remove(LocalSettingsStore.scaleDeviceId);
        expect(
          await database.select(database.localSettings).get(),
          hasLength(1),
        );
      }
    },
  );

  test(
    'l’indirizzo della bilancia non parte per la sincronizzazione',
    () async {
      final database = AppDatabase(_schemaV7(seed: _seedV7));
      addTearDown(database.close);
      final store = LocalSettingsStore(database);

      final codaPrima = await _outboxIds(database);

      await store.write(LocalSettingsStore.scaleDeviceId, 'AA:BB:CC:DD:EE:FF');
      await store.write(LocalSettingsStore.scaleDeviceName, 'QN-Scale');
      await store.remove(LocalSettingsStore.scaleDeviceName);

      // È il punto della tabella: il MAC è quello che vede QUESTO telefono, e
      // spedirlo al tablet significherebbe dirgli di collegarsi a un indirizzo
      // che lì non esiste. Le due righe in coda sono quelle di prima, nessuna
      // in più.
      expect(await _outboxIds(database), codaPrima);
      expect(codaPrima, ['out-1', 'out-2']);
      // Senza questo la prova sarebbe vuota: la coda non cambia perché la
      // scrittura è avvenuta, non perché non è successo niente.
      expect(await database.select(database.localSettings).get(), hasLength(1));
    },
  );

  test('gli indici della v7 sopravvivono alla v8', () async {
    final migrato = AppDatabase(_schemaV7(seed: _seedV7));
    final nuovo = AppDatabase(NativeDatabase.memory());
    addTearDown(migrato.close);
    addTearDown(nuovo.close);

    // Basta aprirli: le migrazioni girano alla prima query.
    await migrato.select(migrato.appProfiles).get();
    await nuovo.select(nuovo.appProfiles).get();

    final indiciMigrato = await _indexNames(migrato);
    final indiciNuovo = await _indexNames(nuovo);

    for (final index in [
      'idx_meals_profile_eaten_at',
      'idx_body_measurements_profile_measured_at',
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

  test(
    'un database migrato e uno nuovo hanno la stessa local_settings',
    () async {
      final migrato = AppDatabase(_schemaV7(seed: _seedV7));
      final nuovo = AppDatabase(NativeDatabase.memory());
      addTearDown(migrato.close);
      addTearDown(nuovo.close);

      Future<String?> sql(AppDatabase database) async {
        final rows = await database
            .customSelect(
              "SELECT sql FROM sqlite_master WHERE type = 'table' "
              "AND name = 'local_settings'",
            )
            .get();
        return rows.single.readNullable<String>('sql');
      }

      // La tabella creata dalla migrazione e quella creata da zero escono dalla
      // stessa definizione Dart: se un domani divergessero, la chiave finirebbe
      // per essere PRIMARY KEY solo su uno dei due telefoni.
      expect(await sql(migrato), await sql(nuovo));
      expect(await sql(nuovo), contains('PRIMARY KEY'));
    },
  );
}
