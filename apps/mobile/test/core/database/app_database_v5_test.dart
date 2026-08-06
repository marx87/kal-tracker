import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

/// Fixture della v4 scritta a mano: le 15 tabelle installate sul telefono di
/// Marco (v0.9.x), con i soli vincoli significativi. Chi porterà lo schema a
/// v7 ha scritto la propria fixture v6 con lo stesso pattern.
QueryExecutor _schemaV4({required List<String> seed}) {
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
        ..execute('''
          CREATE TABLE body_measurements (
            id TEXT NOT NULL PRIMARY KEY,
            profile_id TEXT NOT NULL
              REFERENCES app_profiles(id) ON DELETE CASCADE,
            weight_kg REAL NOT NULL,
            measured_at INTEGER NOT NULL,
            note TEXT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER NULL,
            CHECK (weight_kg >= 20 AND weight_kg <= 500)
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
        ''');
      for (final statement in seed) {
        raw.execute(statement);
      }
      raw.execute('PRAGMA user_version = 4');
    },
  );
}

/// Le tre pesate che Marco aveva già in Gym Tracker, più il profilo.
List<String> get _seedV4 => [
  "INSERT INTO app_profiles VALUES ('marco-v4', 'Marco v4', 0, 0)",
  "INSERT INTO body_measurements (id, profile_id, weight_kg, measured_at, "
      "created_at, updated_at) VALUES "
      "('m-1', 'marco-v4', 96.2, 1000, 0, 0)",
  "INSERT INTO body_measurements (id, profile_id, weight_kg, measured_at, "
      "note, created_at, updated_at) VALUES "
      "('m-2', 'marco-v4', 94.5, 2000, 'dopo le ferie', 0, 0)",
  "INSERT INTO weekly_plans (id, profile_id, start_date, days, meals_csv, "
      "status, request_json, created_at, updated_at) VALUES "
      "('plan-v4', 'marco-v4', 3000, 7, 'pranzo,cena', 'ready', "
      "'{\"schema\":1}', 0, 0)",
];

void main() {
  setUpAll(AppTime.initialize);

  test('migra v4 a v5 conservando profilo, pesate e piani', () async {
    final database = AppDatabase(_schemaV4(seed: _seedV4));
    addTearDown(database.close);

    final version = await database
        .customSelect('PRAGMA user_version')
        .map((row) => row.read<int>('user_version'))
        .getSingle();
    final profile = await database.select(database.appProfiles).getSingle();
    final measurements = await (database.select(
      database.bodyMeasurements,
    )..orderBy([(row) => OrderingTerm(expression: row.measuredAt)])).get();
    final plans = await database.select(database.weeklyPlans).get();

    expect(version, 8);
    expect(profile.displayName, 'Marco v4');
    expect(measurements.map((row) => row.weightKg), [96.2, 94.5]);
    expect(measurements.last.note, 'dopo le ferie');
    expect(plans.single.id, 'plan-v4');
  });

  test(
    'il profilo migrato arriva senza anagrafica e la accetta dopo',
    () async {
      final database = AppDatabase(_schemaV4(seed: _seedV4));
      addTearDown(database.close);

      final before = await database.select(database.appProfiles).getSingle();
      expect(before.heightCm, isNull);
      expect(before.birthDate, isNull);
      expect(before.sex, isNull);

      await (database.update(
        database.appProfiles,
      )..where((row) => row.id.equals('marco-v4'))).write(
        AppProfilesCompanion(
          heightCm: const Value(182),
          birthDate: Value(DateTime.utc(1987, 9, 13)),
          sex: const Value('M'),
        ),
      );

      final after = await database.select(database.appProfiles).getSingle();
      expect(after.heightCm, closeTo(182, 0.0001));
      // Drift salva i DateTime come istante unix e li rilegge nel fuso locale:
      // la data di nascita si scrive e si confronta sempre in UTC a mezzanotte,
      // stessa convenzione di `WeeklyPlans.startDate`. Senza `toUtc()` qui
      // tornerebbero le 02:00 dell'ora legale del 1987.
      expect(after.birthDate!.toUtc(), DateTime.utc(1987, 9, 13));
      expect(after.sex, 'M');
    },
  );

  test(
    'le pesate migrate valgono come misure manuali senza impedenza',
    () async {
      final database = AppDatabase(_schemaV4(seed: _seedV4));
      addTearDown(database.close);

      final measurements = await database
          .select(database.bodyMeasurements)
          .get();

      for (final row in measurements) {
        expect(row.hasImpedance, isFalse);
        expect(row.source, 'manual');
        expect(row.impedanceOhm, isNull);
        expect(row.bodyFatPct, isNull);
        expect(row.formulaVersion, isNull);
        expect(row.externalId, isNull);
      }
    },
  );

  test(
    'un database migrato applica i vincoli nuovi quanto uno appena creato',
    () async {
      for (final (label, database) in <(String, AppDatabase)>[
        ('migrato', AppDatabase(_schemaV4(seed: _seedV4))),
        ('nuovo', AppDatabase(NativeDatabase.memory())),
      ]) {
        addTearDown(database.close);
        final profileId = label == 'migrato'
            ? 'marco-v4'
            : (await LocalProfileRepository(database).getOrCreateMarco()).id;
        final now = AppTime.nowUtc();

        BodyMeasurementsCompanion pesata({
          required String id,
          double weightKg = 95.8,
          Value<double?> bodyFatPct = const Value.absent(),
          Value<int?> visceralFatIndex = const Value.absent(),
          Value<double?> impedanceOhm = const Value.absent(),
          Value<String> source = const Value('manual'),
        }) => BodyMeasurementsCompanion.insert(
          id: id,
          profileId: profileId,
          weightKg: weightKg,
          measuredAt: now,
          createdAt: now,
          updatedAt: now,
          bodyFatPct: bodyFatPct,
          visceralFatIndex: visceralFatIndex,
          impedanceOhm: impedanceOhm,
          source: source,
        );

        // Percentuale fuori scala.
        await expectLater(
          database
              .into(database.bodyMeasurements)
              .insert(pesata(id: '$label-fat', bodyFatPct: const Value(150))),
          throwsA(isA<Exception>()),
          reason: 'body_fat_pct oltre 100 su database $label',
        );
        // Indice viscerale fuori scala.
        await expectLater(
          database
              .into(database.bodyMeasurements)
              .insert(
                pesata(id: '$label-visc', visceralFatIndex: const Value(0)),
              ),
          throwsA(isA<Exception>()),
          reason: 'visceral_fat_index sotto 1 su database $label',
        );
        // Impedenza non positiva: è la misura grezza, zero significa non letta.
        await expectLater(
          database
              .into(database.bodyMeasurements)
              .insert(pesata(id: '$label-ohm', impedanceOhm: const Value(0))),
          throwsA(isA<Exception>()),
          reason: 'impedance_ohm nulla su database $label',
        );
        // Sorgente sconosciuta.
        await expectLater(
          database
              .into(database.bodyMeasurements)
              .insert(
                pesata(
                  id: '$label-src',
                  source: const Value('bilancia-del-bar'),
                ),
              ),
          throwsA(isA<Exception>()),
          reason: 'source ignota su database $label',
        );
        // Il peso resta nei limiti di sempre.
        await expectLater(
          database
              .into(database.bodyMeasurements)
              .insert(pesata(id: '$label-peso', weightKg: 12)),
          throwsA(isA<Exception>()),
          reason: 'weight_kg sotto il minimo su database $label',
        );
      }
    },
  );

  test('la stessa pesata importata due volte non si duplica', () async {
    final database = AppDatabase(_schemaV4(seed: _seedV4));
    addTearDown(database.close);
    final now = AppTime.nowUtc();

    BodyMeasurementsCompanion importata(String id) =>
        BodyMeasurementsCompanion.insert(
          id: id,
          profileId: 'marco-v4',
          weightKg: 95.8,
          measuredAt: now,
          createdAt: now,
          updatedAt: now,
          hasImpedance: const Value(true),
          impedanceOhm: const Value(512.5),
          bodyFatPct: const Value(25.2),
          formulaVersion: const Value('bia-v1'),
          source: const Value('renpho_csv'),
          externalId: const Value('2026-08-05T08:39:30'),
        );

    await database.into(database.bodyMeasurements).insert(importata('imp-1'));

    await expectLater(
      database.into(database.bodyMeasurements).insert(importata('imp-2')),
      throwsA(isA<Exception>()),
    );

    final saved = await (database.select(
      database.bodyMeasurements,
    )..where((row) => row.source.equals('renpho_csv'))).getSingle();
    expect(saved.id, 'imp-1');
    expect(saved.hasImpedance, isTrue);
    expect(saved.impedanceOhm, closeTo(512.5, 0.0001));
    expect(saved.formulaVersion, 'bia-v1');
  });

  test('due pesate manuali senza chiave esterna convivono', () async {
    final database = AppDatabase(_schemaV4(seed: _seedV4));
    addTearDown(database.close);
    final now = AppTime.nowUtc();

    for (final id in ['man-1', 'man-2']) {
      await database
          .into(database.bodyMeasurements)
          .insert(
            BodyMeasurementsCompanion.insert(
              id: id,
              profileId: 'marco-v4',
              weightKg: 95.8,
              measuredAt: now,
              createdAt: now,
              updatedAt: now,
            ),
          );
    }

    final manuali = await (database.select(
      database.bodyMeasurements,
    )..where((row) => row.id.like('man-%'))).get();
    expect(manuali, hasLength(2));
  });
}
