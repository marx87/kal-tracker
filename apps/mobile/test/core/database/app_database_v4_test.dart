import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/data/diary_repository.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

/// Fixture della v3 scritta a mano: le 13 tabelle già installate sul
/// telefono di Marco (v0.8.0), con i soli vincoli significativi.
QueryExecutor _schemaV3({required List<String> seed}) {
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
        ''');
      for (final statement in seed) {
        raw.execute(statement);
      }
      raw.execute('PRAGMA user_version = 3');
    },
  );
}

void main() {
  setUpAll(AppTime.initialize);

  test('migra v3 a v4 conservando diario, ricette e modelli di pasto', () async {
    final executor = _schemaV3(
      seed: [
        "INSERT INTO app_profiles VALUES ('marco-v3', 'Marco v3', 0, 0)",
        "INSERT INTO meals VALUES "
            "('meal-v3', 'marco-v3', 'lunch', 0, 0, 0, NULL)",
        "INSERT INTO meal_items VALUES ("
            "'item-v3', 'meal-v3', 'Riso v3', 150, "
            "130, 2.7, 28.2, 0.3, 195, 4.05, 42.3, 0.45, "
            "'manual', 0, 0, NULL)",
        "INSERT INTO fit_recipes (id, profile_id, name, tags, servings, "
            "total_calories, total_protein, total_carbs, total_fat, "
            "created_at, updated_at) VALUES "
            "('recipe-v3', 'marco-v3', 'Bowl v3', 'cena,proteico', 2, "
            "800, 60, 90, 20, 0, 0)",
        "INSERT INTO meal_templates (id, profile_id, name, meal_type, "
            "created_at, updated_at) VALUES "
            "('template-v3', 'marco-v3', 'Colazione tipo', 'breakfast', 0, 0)",
      ],
    );
    final database = AppDatabase(executor);
    addTearDown(database.close);

    final version = await database
        .customSelect('PRAGMA user_version')
        .map((row) => row.read<int>('user_version'))
        .getSingle();
    final diary = await DiaryRepository(
      database,
    ).watchDay(profileId: 'marco-v3', day: DateTime(1970, 1, 1)).first;
    final recipe = await database.select(database.fitRecipes).getSingle();
    final templates = await database.select(database.mealTemplates).get();
    final plans = await database.select(database.weeklyPlans).get();
    final slots = await database.select(database.weeklyPlanSlots).get();

    expect(version, 9);
    expect(diary.entries.single.foodName, 'Riso v3');
    expect(diary.totals.calories, closeTo(195, 0.0001));
    expect(recipe.name, 'Bowl v3');
    expect(recipe.tags, 'cena,proteico');
    expect(templates.single.name, 'Colazione tipo');
    expect(plans, isEmpty);
    expect(slots, isEmpty);
  });

  test('il piano v4 accetta slot ordinati e cancella a cascata', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final profile = await LocalProfileRepository(database).getOrCreateMarco();
    final now = AppTime.nowUtc();
    final startDate = DateTime.utc(2026, 8, 5);

    await database
        .into(database.weeklyPlans)
        .insert(
          WeeklyPlansCompanion.insert(
            id: 'plan-1',
            profileId: profile.id,
            startDate: startDate,
            days: 7,
            mealsCsv: 'pranzo,cena',
            status: 'ready',
            requestJson: '{"schema":1}',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await database.batch((batch) {
      batch.insertAll(database.weeklyPlanSlots, [
        WeeklyPlanSlotsCompanion.insert(
          id: 'slot-1',
          planId: 'plan-1',
          date: startDate,
          meal: 'pranzo',
          recipeNameSnapshot: 'Bowl pollo e riso',
          servings: 1,
        ),
        WeeklyPlanSlotsCompanion.insert(
          id: 'slot-2',
          planId: 'plan-1',
          date: startDate,
          meal: 'cena',
          recipeNameSnapshot: 'Salmone e broccoli',
          servings: 1.5,
          why: const Value('Proteine alte a fine giornata'),
        ),
      ]);
    });

    final slots = await database.select(database.weeklyPlanSlots).get();
    expect(slots.map((row) => row.meal), ['pranzo', 'cena']);
    expect(slots.last.servings, closeTo(1.5, 0.0001));
    expect(slots.first.doneAt, isNull);

    await (database.delete(
      database.weeklyPlans,
    )..where((row) => row.id.equals('plan-1'))).go();

    expect(await database.select(database.weeklyPlanSlots).get(), isEmpty);
  });

  test('i vincoli v4 rifiutano giorni fuori scala, stati ignoti, '
      'porzioni nulle e pasti doppi', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final profile = await LocalProfileRepository(database).getOrCreateMarco();
    final now = AppTime.nowUtc();
    final startDate = DateTime.utc(2026, 8, 5);

    WeeklyPlansCompanion plan({
      required String id,
      int days = 7,
      String status = 'ready',
      String profileId = '',
    }) => WeeklyPlansCompanion.insert(
      id: id,
      profileId: profileId.isEmpty ? profile.id : profileId,
      startDate: startDate,
      days: days,
      mealsCsv: 'pranzo,cena',
      status: status,
      requestJson: '{"schema":1}',
      createdAt: now,
      updatedAt: now,
    );

    await database.into(database.weeklyPlans).insert(plan(id: 'plan-1'));

    await expectLater(
      database.into(database.weeklyPlans).insert(plan(id: 'plan-15', days: 15)),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      database
          .into(database.weeklyPlans)
          .insert(plan(id: 'plan-bad-status', status: 'boh')),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      database
          .into(database.weeklyPlans)
          .insert(plan(id: 'plan-orphan', profileId: 'missing-profile')),
      throwsA(isA<Exception>()),
    );

    await database
        .into(database.weeklyPlanSlots)
        .insert(
          WeeklyPlanSlotsCompanion.insert(
            id: 'slot-1',
            planId: 'plan-1',
            date: startDate,
            meal: 'pranzo',
            recipeNameSnapshot: 'Bowl pollo e riso',
            servings: 1,
          ),
        );

    await expectLater(
      database
          .into(database.weeklyPlanSlots)
          .insert(
            WeeklyPlanSlotsCompanion.insert(
              id: 'slot-zero',
              planId: 'plan-1',
              date: startDate,
              meal: 'cena',
              recipeNameSnapshot: 'Salmone e broccoli',
              servings: 0,
            ),
          ),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      database
          .into(database.weeklyPlanSlots)
          .insert(
            WeeklyPlanSlotsCompanion.insert(
              id: 'slot-duplicate',
              planId: 'plan-1',
              date: startDate,
              meal: 'pranzo',
              recipeNameSnapshot: 'Pasta al pesto',
              servings: 1,
            ),
          ),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      database
          .into(database.weeklyPlanSlots)
          .insert(
            WeeklyPlanSlotsCompanion.insert(
              id: 'slot-orphan',
              planId: 'plan-mancante',
              date: startDate,
              meal: 'cena',
              recipeNameSnapshot: 'Salmone e broccoli',
              servings: 1,
            ),
          ),
      throwsA(isA<Exception>()),
    );

    expect(await database.select(database.weeklyPlanSlots).get(), hasLength(1));
  });

  test('cancellare una ricetta lascia lo slot senza recipeId', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final profile = await LocalProfileRepository(database).getOrCreateMarco();
    final now = AppTime.nowUtc();
    final startDate = DateTime.utc(2026, 8, 5);

    await database
        .into(database.fitRecipes)
        .insert(
          FitRecipesCompanion.insert(
            id: 'recipe-1',
            profileId: profile.id,
            name: 'Bowl pollo e riso',
            servings: 2,
            totalCalories: 800,
            totalProtein: 60,
            totalCarbs: 90,
            totalFat: 20,
            createdAt: now,
            updatedAt: now,
          ),
        );
    await database
        .into(database.weeklyPlans)
        .insert(
          WeeklyPlansCompanion.insert(
            id: 'plan-1',
            profileId: profile.id,
            startDate: startDate,
            days: 1,
            mealsCsv: 'cena',
            status: 'ready',
            requestJson: '{"schema":1}',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await database
        .into(database.weeklyPlanSlots)
        .insert(
          WeeklyPlanSlotsCompanion.insert(
            id: 'slot-1',
            planId: 'plan-1',
            date: startDate,
            meal: 'cena',
            recipeId: const Value('recipe-1'),
            recipeNameSnapshot: 'Bowl pollo e riso',
            servings: 1,
          ),
        );

    await (database.delete(
      database.fitRecipes,
    )..where((row) => row.id.equals('recipe-1'))).go();

    final slot = await database.select(database.weeklyPlanSlots).getSingle();
    expect(slot.recipeId, isNull);
    expect(slot.recipeNameSnapshot, 'Bowl pollo e riso');
  });
}
