import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/checkin/data/check_in_repository.dart';
import 'package:kal_tracker/features/checkin/data/check_in_store.dart';
import 'package:kal_tracker/features/checkin/domain/daily_check_in.dart';

/// Fixture della v9 scritta a mano: le 34 tabelle che il telefono di Marco ha
/// dopo il profilo atleta, con i soli vincoli significativi. Generarla dalla
/// definizione Dart di oggi non proverebbe niente — sarebbe la migrazione a
/// confrontarsi con se stessa, e la CHECK che la v10 deve allargare arriverebbe
/// già larga. Chi porterà lo schema a v11 dovrà scrivere la propria fixture v10
/// con lo stesso pattern.
///
/// Due dettagli sono qui apposta perché è così che sta il telefono vero, non
/// perché siano comodi:
///
/// - `daily_check_ins` porta `steps` e `walk_minutes` **in fondo**, dopo
///   `deleted_at`: la v9 le ha aggiunte con `addColumn`, che accoda. Una
///   copia posizionale le scambierebbe con le date; questa fixture è l'unico
///   posto dove quello sbaglio si vede.
/// - la CHECK di `daily_check_ins` è ancora quella stretta della v7, che
///   pretende sonno o energia. È esattamente il difetto che la v10 rimuove.
QueryExecutor _schemaV9({required List<String> seed}) {
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
        // Le due colonne della doppia progressione sono in fondo, come le
        // lascia l'`addColumn` della v9.
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
            presc_reps_min INTEGER NULL,
            presc_reps_max INTEGER NULL,
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
        // La tabella al centro di questa migrazione, com'è davvero alla v9:
        // colonne del movimento accodate e CHECK ancora stretta.
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
            steps INTEGER NULL,
            walk_minutes INTEGER NULL,
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
        ..execute(
          'CREATE UNIQUE INDEX idx_body_impedance_readings_undeclared '
          'ON body_impedance_readings (measurement_id, segment) '
          'WHERE frequency_hz IS NULL',
        )
        // v8: le impostazioni dell'apparecchio.
        ..execute('''
          CREATE TABLE local_settings (
            key TEXT NOT NULL PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at INTEGER NOT NULL
          )
        ''')
        // v9: chi è Marco come atleta.
        ..execute('''
          CREATE TABLE training_profiles (
            profile_id TEXT NOT NULL PRIMARY KEY
              REFERENCES app_profiles(id) ON DELETE CASCADE,
            equipment TEXT NOT NULL DEFAULT '',
            sessions_per_week INTEGER NULL,
            minutes_per_session INTEGER NULL,
            preferred_days TEXT NOT NULL DEFAULT '',
            deload_preference TEXT NOT NULL DEFAULT 'suggerito',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            CHECK (deload_preference IN ('automatico', 'suggerito'))
          )
        ''')
        ..execute('''
          CREATE TABLE training_limitations (
            id TEXT NOT NULL PRIMARY KEY,
            profile_id TEXT NOT NULL
              REFERENCES app_profiles(id) ON DELETE CASCADE,
            body_part TEXT NOT NULL,
            severity TEXT NOT NULL,
            note TEXT NULL,
            started_at INTEGER NOT NULL,
            resolved_at INTEGER NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            CHECK (severity IN ('fastidio', 'dolore', 'stop'))
          )
        ''');
      for (final statement in seed) {
        raw.execute(statement);
      }
      raw.execute('PRAGMA user_version = 9');
    },
  );
}

/// Il 6 agosto 2026 a mezzanotte UTC, in secondi: l'etichetta del giorno con
/// cui `daily_check_ins` scrive la colonna `day`.
const _seiAgosto = 1785974400;
const _cinqueAgosto = _seiAgosto - 86400;
const _quattroAgosto = _seiAgosto - 172800;

/// Il telefono di Marco alla v9: anagrafica, una pesata Bluetooth con la sua
/// impedenza, tre check-in di forma diversa, l'obiettivo in corso, una sessione
/// chiusa, il profilo atleta con la sua limitazione e la bilancia ricordata.
///
/// I tre check-in sono tre casi che la ricostruzione della tabella deve
/// attraversare intatti: uno completo di movimento, uno di solo sonno, e un
/// tombstone — che è l'unica riga a cui la CHECK stretta permetteva di essere
/// vuota, ed è quindi quella che una CHECK sbagliata butterebbe fuori.
List<String> get _seedV9 => [
  "INSERT INTO app_profiles VALUES "
      "('marco-v9', 'Marco', 182.0, -72576000, 'M', 0, 0)",
  "INSERT INTO body_measurements (id, profile_id, weight_kg, measured_at, "
      "has_impedance, impedance_ohm, body_fat_pct, formula_version, source, "
      "external_id, device_model, raw_payload, created_at, updated_at) VALUES "
      "('pesata-1', 'marco-v9', 94.5, 1000, 1, 512.5, 25.2, 'bia-v1', "
      "'renpho_ble', 'QN-Scale:2026-08-05T08:39:30', 'QN-Scale', "
      "'02:0f:1a:00:25:5e:03:c9', 0, 0)",
  "INSERT INTO body_impedance_readings (id, measurement_id, segment, ohm) "
      "VALUES ('imp-1', 'pesata-1', 'whole', 512.5)",
  "INSERT INTO body_measurement_values VALUES "
      "('giro-1', 'pesata-1', 'Vita', 106.0)",
  "INSERT INTO daily_check_ins (id, profile_id, day, sleep_hours, "
      "energy_score, created_at, updated_at, steps, walk_minutes) VALUES "
      "('chk-6', 'marco-v9', $_seiAgosto, 7.5, 4, 100, 200, 8000, 40)",
  "INSERT INTO daily_check_ins (id, profile_id, day, sleep_hours, "
      "created_at, updated_at) VALUES "
      "('chk-5', 'marco-v9', $_cinqueAgosto, 6.5, 100, 200)",
  "INSERT INTO daily_check_ins (id, profile_id, day, created_at, updated_at, "
      "deleted_at) VALUES "
      "('chk-4', 'marco-v9', $_quattroAgosto, 100, 200, 300)",
  "INSERT INTO goals (id, profile_id, target_weight_kg, target_level, "
      "pace_kg_per_week, started_at, start_weight_kg, start_fat_free_mass_kg, "
      "phase, created_at, updated_at) VALUES "
      "('goal-1', 'marco-v9', 80.5, 'defined', 0.5, 1000, 95.8, 71.66, "
      "'approach', 0, 0)",
  "INSERT INTO exercises (id, profile_id, name, muscle_group, tracking_mode, "
      "source, external_id, created_at, updated_at) VALUES "
      "('ex-1', 'marco-v9', 'Panca piana', 'petto', 'weightReps', "
      "'gym_tracker', 'ex-1', 0, 0)",
  "INSERT INTO workouts (id, profile_id, started_at, ended_at, source, "
      "external_id, total_kcal, xp_earned, created_at, updated_at) VALUES "
      "('wk-1', 'marco-v9', 1000, 4600, 'gym_tracker', 'wk-1', 412.5, 320, "
      "0, 0)",
  "INSERT INTO workout_profile_stats (id, profile_id, total_xp, "
      "current_streak, longest_streak, created_at, updated_at) VALUES "
      "('stats-1', 'marco-v9', 11370, 2, 5, 0, 0)",
  "INSERT INTO training_profiles (profile_id, equipment, sessions_per_week, "
      "minutes_per_session, preferred_days, deload_preference, created_at, "
      "updated_at) VALUES ('marco-v9', 'manubri,elastici_anello', 3, 45, "
      "'lun,mer,ven', 'suggerito', 0, 0)",
  "INSERT INTO training_limitations (id, profile_id, body_part, severity, "
      "started_at, created_at, updated_at) VALUES "
      "('lim-1', 'marco-v9', 'spalla_dx', 'dolore', 1000, 0, 0)",
  "INSERT INTO local_settings VALUES "
      "('scale.device.id', 'AA:BB:CC:DD:EE:FF', 0)",
  "INSERT INTO sync_outbox VALUES ('out-1', 'body_measurement', 'pesata-1', "
      "'upsert', '{}', 1000, 0, NULL)",
];

Future<Set<String>> _indexNames(AppDatabase database) async {
  final rows = await database
      .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
      .get();
  return {for (final row in rows) row.read<String>('name')};
}

Future<String?> _tableSql(AppDatabase database, String name) async {
  final rows = await database
      .customSelect(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
        variables: [Variable<String>(name)],
      )
      .get();
  return rows.single.readNullable<String>('sql');
}

/// Il check-in di un giorno, letto per id.
Future<LocalDailyCheckIn> _checkIn(AppDatabase database, String id) =>
    (database.select(
      database.dailyCheckIns,
    )..where((row) => row.id.equals(id))).getSingle();

void main() {
  setUpAll(AppTime.initialize);

  test('migra v9 a v10 senza perdere una riga di check-in', () async {
    final database = AppDatabase(_schemaV9(seed: _seedV9));
    addTearDown(database.close);

    final version = await database
        .customSelect('PRAGMA user_version')
        .map((row) => row.read<int>('user_version'))
        .getSingle();

    expect(version, 11);

    // La riga completa: il movimento sta in fondo alla tabella vecchia e in
    // mezzo a quella nuova. Se la copia fosse posizionale invece che per nome,
    // gli 8000 passi finirebbero in `created_at` e nessuno se ne accorgerebbe
    // finché il coach non legge una giornata nata nel 1970.
    final completo = await _checkIn(database, 'chk-6');
    expect(completo.day.toUtc(), DateTime.utc(2026, 8, 6));
    expect(completo.sleepHours, closeTo(7.5, 0.0001));
    expect(completo.energyScore, 4);
    expect(completo.steps, 8000);
    expect(completo.walkMinutes, 40);
    expect(completo.createdAt.toUtc(), DateTime.utc(1970, 1, 1, 0, 1, 40));
    expect(completo.updatedAt.toUtc(), DateTime.utc(1970, 1, 1, 0, 3, 20));
    expect(completo.deletedAt, isNull);

    final soloSonno = await _checkIn(database, 'chk-5');
    expect(soloSonno.sleepHours, closeTo(6.5, 0.0001));
    expect(soloSonno.steps, isNull);

    // Il tombstone è la riga più fragile della ricostruzione: è vuota per
    // definizione, e una CHECK scritta male la rifiuterebbe in copia facendo
    // fallire tutta la migrazione.
    final tombstone = await _checkIn(database, 'chk-4');
    expect(tombstone.deletedAt, isNotNull);
    expect(tombstone.sleepHours, isNull);

    expect(await database.select(database.dailyCheckIns).get(), hasLength(3));
  });

  test('la v10 non tocca niente che non sia il check-in', () async {
    final database = AppDatabase(_schemaV9(seed: _seedV9));
    addTearDown(database.close);

    final profile = await database.select(database.appProfiles).getSingle();
    final measurement = await database
        .select(database.bodyMeasurements)
        .getSingle();
    final impedenza = await database
        .select(database.bodyImpedanceReadings)
        .getSingle();
    final goal = await database.select(database.goals).getSingle();
    final workout = await database.select(database.workouts).getSingle();
    final stats = await database
        .select(database.workoutProfileStats)
        .getSingle();
    final atleta = await database.select(database.trainingProfiles).getSingle();
    final limite = await database
        .select(database.trainingLimitations)
        .getSingle();
    final impostazione = await database
        .select(database.localSettings)
        .getSingle();

    expect(profile.displayName, 'Marco');
    expect(measurement.deviceModel, 'QN-Scale');
    expect(impedenza.ohm, closeTo(512.5, 0.0001));
    expect(goal.targetLevel, 'defined');
    expect(workout.totalKcal, closeTo(412.5, 0.0001));
    expect(stats.totalXp, 11370);
    expect(atleta.equipment, 'manubri,elastici_anello');
    expect(atleta.deloadPreference, 'suggerito');
    expect(limite.bodyPart, 'spalla_dx');
    expect(impostazione.value, 'AA:BB:CC:DD:EE:FF');
    // La coda di sincronizzazione non deve aver visto niente: la v10 cambia un
    // vincolo, non i dati, e un tablet che si vedesse riproporre tre check-in
    // avrebbe ricevuto una notizia falsa.
    expect(await database.select(database.syncOutbox).get(), hasLength(1));
  });

  test('la giornata dei soli passi entra, su migrato e su nuovo', () async {
    for (final (label, database) in <(String, AppDatabase)>[
      ('migrato', AppDatabase(_schemaV9(seed: _seedV9))),
      ('nuovo', AppDatabase(NativeDatabase.memory())),
    ]) {
      addTearDown(database.close);
      final profileId = label == 'migrato' ? 'marco-v9' : 'marco-nuovo';
      if (label == 'nuovo') {
        await database
            .into(database.appProfiles)
            .insert(
              AppProfilesCompanion.insert(
                id: profileId,
                displayName: 'Marco',
                createdAt: DateTime.utc(2026, 8, 7),
                updatedAt: DateTime.utc(2026, 8, 7),
              ),
            );
      }

      // È il difetto che la v10 esiste per chiudere: fino alla v9 questa riga
      // veniva rifiutata dal database, e i passi di una giornata camminata
      // sparivano perché quel giorno Marco non aveva risposto sul sonno.
      await database
          .into(database.dailyCheckIns)
          .insert(
            DailyCheckInsCompanion.insert(
              id: 'solo-passi',
              profileId: profileId,
              day: DateTime.utc(2026, 8, 7),
              createdAt: DateTime.utc(2026, 8, 7),
              updatedAt: DateTime.utc(2026, 8, 7),
              steps: const Value(9200),
            ),
          );

      final riga = await _checkIn(database, 'solo-passi');
      expect(riga.steps, 9200, reason: 'passi persi su database $label');
      expect(riga.sleepHours, isNull, reason: 'sonno inventato su $label');
    }
  });

  test('una riga viva del tutto vuota resta rifiutata', () async {
    final database = AppDatabase(_schemaV9(seed: _seedV9));
    addTearDown(database.close);

    // La CHECK è stata allargata, non tolta: senza nemmeno un campo la riga
    // farebbe contare come «compilato» un giorno in cui non è stata data
    // nessuna risposta. Solo il tombstone può essere vuoto.
    await expectLater(
      database
          .into(database.dailyCheckIns)
          .insert(
            DailyCheckInsCompanion.insert(
              id: 'vuota',
              profileId: 'marco-v9',
              day: DateTime.utc(2026, 8, 7),
              createdAt: DateTime.utc(2026, 8, 7),
              updatedAt: DateTime.utc(2026, 8, 7),
            ),
          ),
      throwsA(isA<Exception>()),
    );
  });

  test('la tabella ricostruita è identica a quella nata da zero', () async {
    final migrato = AppDatabase(_schemaV9(seed: _seedV9));
    final nuovo = AppDatabase(NativeDatabase.memory());
    addTearDown(migrato.close);
    addTearDown(nuovo.close);

    // Basta aprirli: le migrazioni girano alla prima query.
    await migrato.select(migrato.appProfiles).get();
    await nuovo.select(nuovo.appProfiles).get();

    final sqlMigrato = await _tableSql(migrato, 'daily_check_ins');

    // Due telefoni che si comportano in modo diverso sullo stesso gesto sono
    // il difetto che questa migrazione poteva introdurre: il vincolo va
    // riscritto su entrambi, non solo su chi installa oggi.
    expect(sqlMigrato, await _tableSql(nuovo, 'daily_check_ins'));
    expect(sqlMigrato, contains('walk_minutes IS NOT NULL'));
    // E le colonne devono restare nell'ordine della definizione Dart: la
    // ricostruzione ha rimesso in fila quelle che l'`addColumn` della v9 aveva
    // accodato.
    expect(
      sqlMigrato!.indexOf('steps'),
      lessThan(sqlMigrato.indexOf('created_at')),
    );
  });

  test('indice e chiave esterna sopravvivono alla ricostruzione', () async {
    final database = AppDatabase(_schemaV9(seed: _seedV9));
    addTearDown(database.close);

    // `alterTable` fa DROP della tabella vecchia, e in SQLite un DROP si porta
    // via gli indici. Drift li rilegge da `sqlite_master` prima di buttarla;
    // se un giorno smettesse di farlo, il check-in tornerebbe a leggersi con
    // una scansione completa e nessun test se ne accorgerebbe.
    expect(
      await _indexNames(database),
      contains('idx_daily_check_ins_profile_day'),
    );

    // La chiave esterna è l'altra cosa che una ricostruzione può perdere in
    // silenzio, perché durante la migrazione le FK sono spente: qui sono
    // riaccese da `beforeOpen`, e cancellare il profilo deve portarsi via i
    // suoi check-in invece di lasciarli orfani.
    await (database.delete(
      database.appProfiles,
    )..where((row) => row.id.equals('marco-v9'))).go();

    expect(await database.select(database.dailyCheckIns).get(), isEmpty);
  });

  test(
    'togliere il sonno da un giorno camminato non porta via i passi',
    () async {
      final database = AppDatabase(_schemaV9(seed: _seedV9));
      addTearDown(database.close);
      DriftCheckInStore store() => DriftCheckInStore(
        database,
        legacy: FileCheckInStore(directory: Directory.systemTemp.createTemp),
        profileId: () async => 'marco-v9',
      );

      // Lo scenario vero, sul telefono vero: il 6 agosto ha sonno ed energia, e
      // Marco corregge la notte che non ha dormito lasciando i suoi 8000 passi.
      final giorno = DateTime.utc(2026, 8, 6);
      final repository = CheckInRepository(store());
      await repository.save(day: giorno, clearSleep: true, clearEnergy: true);

      final riga = await _checkIn(database, 'chk-6');
      expect(riga.deletedAt, isNull, reason: 'il giorno è stato spento');
      expect(riga.steps, 8000);
      expect(riga.walkMinutes, 40);
      expect(riga.sleepHours, isNull);

      // E alla riapertura i passi ci sono ancora, che è tutto il punto.
      final entry = (await store().read()).forDay(checkInDayOf(giorno))!;
      expect(entry.steps, 8000);
      expect(entry.hasNeat, isTrue);
      expect(entry.sleepHours, isNull);
    },
  );
}
