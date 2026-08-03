import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/data/diary_repository.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

QueryExecutor _schemaV2({required List<String> seed}) {
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
        ''');
      for (final statement in seed) {
        raw.execute(statement);
      }
      raw.execute('PRAGMA user_version = 2');
    },
  );
}

void main() {
  setUpAll(AppTime.initialize);

  test('migra v2 a v3 conservando diario, ricette e alimenti', () async {
    final executor = _schemaV2(
      seed: [
        "INSERT INTO app_profiles VALUES ('marco-v2', 'Marco v2', 0, 0)",
        "INSERT INTO meals VALUES "
            "('meal-v2', 'marco-v2', 'lunch', 0, 0, 0, NULL)",
        "INSERT INTO meal_items VALUES ("
            "'item-v2', 'meal-v2', 'Riso v2', 150, "
            "130, 2.7, 28.2, 0.3, 195, 4.05, 42.3, 0.45, "
            "'manual', 0, 0, NULL)",
        "INSERT INTO foods (id, name, calories_per100g, protein_per100g, "
            "carbs_per100g, fat_per100g, created_at, updated_at) VALUES "
            "('seed-oats', 'Fiocchi d''avena', 389, 16.9, 66.3, 6.9, 0, 0)",
        "INSERT INTO fit_recipes (id, profile_id, name, servings, "
            "total_calories, total_protein, total_carbs, total_fat, "
            "created_at, updated_at) VALUES "
            "('recipe-v2', 'marco-v2', 'Bowl v2', 2, 800, 60, 90, 20, 0, 0)",
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
    ).watchDay(profileId: 'marco-v2', day: DateTime(1970, 1, 1)).first;
    final recipe = await database.select(database.fitRecipes).getSingle();
    final foods = await database.select(database.foods).get();
    final templates = await database.select(database.mealTemplates).get();

    expect(version, 3);
    expect(diary.entries.single.foodName, 'Riso v2');
    expect(diary.totals.calories, closeTo(195, 0.0001));
    expect(recipe.name, 'Bowl v2');
    expect(recipe.tags, isNull);
    expect(foods, hasLength(1));
    expect(templates, isEmpty);

    await (database.update(database.fitRecipes)
          ..where((row) => row.id.equals('recipe-v2')))
        .write(const FitRecipesCompanion(tags: Value('pranzo,proteico')));
    final tagged = await database.select(database.fitRecipes).getSingle();

    expect(tagged.tags, 'pranzo,proteico');
  });

  test('i modelli di pasto v3 accettano voci ordinate e cancellano '
      'a cascata', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final profile = await LocalProfileRepository(database).getOrCreateMarco();
    final now = AppTime.nowUtc();

    await database
        .into(database.mealTemplates)
        .insert(
          MealTemplatesCompanion.insert(
            id: 'template-1',
            profileId: profile.id,
            name: 'Colazione tipo',
            mealType: 'breakfast',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await database.batch((batch) {
      batch.insertAll(database.mealTemplateItems, [
        MealTemplateItemsCompanion.insert(
          id: 'template-item-1',
          templateId: 'template-1',
          position: 0,
          foodName: 'Fiocchi d’avena',
          grams: 60,
          caloriesPer100g: 389,
          proteinPer100g: 16.9,
          carbsPer100g: 66.3,
          fatPer100g: 6.9,
        ),
        MealTemplateItemsCompanion.insert(
          id: 'template-item-2',
          templateId: 'template-1',
          position: 1,
          foodName: 'Banana',
          grams: 120,
          caloriesPer100g: 89,
          proteinPer100g: 1.1,
          carbsPer100g: 22.8,
          fatPer100g: 0.3,
        ),
      ]);
    });

    final items = await database.select(database.mealTemplateItems).get();
    expect(items.map((row) => row.position), [0, 1]);

    await (database.delete(
      database.mealTemplates,
    )..where((row) => row.id.equals('template-1'))).go();

    expect(await database.select(database.mealTemplateItems).get(), isEmpty);
  });

  test('i vincoli v3 rifiutano grammi nulli, posizioni duplicate '
      'e modelli orfani', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final profile = await LocalProfileRepository(database).getOrCreateMarco();
    final now = AppTime.nowUtc();

    await database
        .into(database.mealTemplates)
        .insert(
          MealTemplatesCompanion.insert(
            id: 'template-1',
            profileId: profile.id,
            name: 'Pranzo tipo',
            mealType: 'lunch',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await database
        .into(database.mealTemplateItems)
        .insert(
          MealTemplateItemsCompanion.insert(
            id: 'template-item-1',
            templateId: 'template-1',
            position: 0,
            foodName: 'Petto di pollo',
            grams: 150,
            caloriesPer100g: 165,
            proteinPer100g: 31,
            carbsPer100g: 0,
            fatPer100g: 3.6,
          ),
        );

    await expectLater(
      database
          .into(database.mealTemplateItems)
          .insert(
            MealTemplateItemsCompanion.insert(
              id: 'template-item-zero',
              templateId: 'template-1',
              position: 1,
              foodName: 'Broccoli',
              grams: 0,
              caloriesPer100g: 34,
              proteinPer100g: 2.8,
              carbsPer100g: 6.6,
              fatPer100g: 0.4,
            ),
          ),
      throwsA(isA<Exception>()),
    );

    await expectLater(
      database
          .into(database.mealTemplateItems)
          .insert(
            MealTemplateItemsCompanion.insert(
              id: 'template-item-duplicate',
              templateId: 'template-1',
              position: 0,
              foodName: 'Riso basmati cotto',
              grams: 150,
              caloriesPer100g: 130,
              proteinPer100g: 2.7,
              carbsPer100g: 28.2,
              fatPer100g: 0.3,
            ),
          ),
      throwsA(isA<Exception>()),
    );

    await expectLater(
      database
          .into(database.mealTemplates)
          .insert(
            MealTemplatesCompanion.insert(
              id: 'template-orphan',
              profileId: 'missing-profile',
              name: 'Cena tipo',
              mealType: 'dinner',
              createdAt: now,
              updatedAt: now,
            ),
          ),
      throwsA(isA<Exception>()),
    );

    expect(
      await database.select(database.mealTemplateItems).get(),
      hasLength(1),
    );
  });
}
