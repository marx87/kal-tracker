import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/data/diary_repository.dart';
import 'package:kal_tracker/features/foods/data/food_catalog_repository.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/targets/data/target_repository.dart';
import 'package:kal_tracker/features/targets/domain/nutrition_target.dart';
import 'package:kal_tracker/features/wellbeing/data/wellbeing_repository.dart';

void main() {
  setUpAll(AppTime.initialize);

  test('migra v1 a v2 conservando i profili e aggiungendo il seed', () async {
    final executor = NativeDatabase.memory(
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
          ..execute(
            'CREATE INDEX idx_meal_items_meal_id ON meal_items (meal_id)',
          )
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
          ..execute(
            "INSERT INTO app_profiles VALUES "
            "('marco-v1', 'Marco v1', 0, 0)",
          )
          ..execute(
            "INSERT INTO meals VALUES "
            "('meal-v1', 'marco-v1', 'breakfast', 0, 0, 0, NULL)",
          )
          ..execute(
            "INSERT INTO meal_items VALUES ("
            "'item-v1', 'meal-v1', 'Pane v1', 50, "
            "250, 9, 43, 4, 125, 4.5, 21.5, 2, "
            "'manual', 0, 0, NULL)",
          )
          ..execute('PRAGMA user_version = 1');
      },
    );
    final database = AppDatabase(executor);
    addTearDown(database.close);

    final profiles = await database.select(database.appProfiles).get();
    final foods = await database.select(database.foods).get();
    final version = await database
        .customSelect('PRAGMA user_version')
        .map((row) => row.read<int>('user_version'))
        .getSingle();
    final diary = await DiaryRepository(
      database,
    ).watchDay(profileId: 'marco-v1', day: DateTime(1970, 1, 1)).first;

    expect(profiles.single.displayName, 'Marco v1');
    expect(diary.entries.single.foodName, 'Pane v1');
    expect(diary.totals.calories, 125);
    expect(foods, hasLength(12));
    // Copre di fatto l'intera catena v1 → v7.
    expect(version, 10);

    await TargetRepository(database).upsertTarget(
      profileId: 'marco-v1',
      target: const NutritionTarget.standard(),
    );
    expect(await TargetRepository(database).getTarget('marco-v1'), isNotNull);
  });

  test('i dati v2 persistono dopo chiusura e riapertura', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final directory = await Directory.systemTemp.createTemp('kal_tracker_v2_');
    final file = File('${directory.path}/kal-tracker.sqlite');
    AppDatabase? database;
    addTearDown(() async {
      await database?.close();
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = false;
    });

    database = AppDatabase(NativeDatabase(file));
    final profile = await LocalProfileRepository(database).getOrCreateMarco();
    await TargetRepository(database).upsertTarget(
      profileId: profile.id,
      target: const NutritionTarget(
        calories: 2100,
        protein: 135,
        carbs: 225,
        fat: 68,
      ),
    );
    await WellbeingRepository(database).addWater(
      profileId: profile.id,
      milliliters: 330,
      loggedAt: DateTime(2026, 8, 2, 12),
    );
    await database.close();
    database = null;

    database = AppDatabase(NativeDatabase(file));
    final target = await TargetRepository(database).getTarget(profile.id);
    final water = await WellbeingRepository(
      database,
    ).watchWaterDay(profileId: profile.id, day: DateTime(2026, 8, 2)).first;
    final catalog = await FoodCatalogRepository(
      database,
    ).watchCatalog(profileId: profile.id).first;

    expect(target?.calories, 2100);
    expect(water.totalMilliliters, 330);
    expect(catalog, hasLength(12));
  });

  test('le foreign key v2 impediscono righe orfane', () async {
    final database = AppDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final now = AppTime.nowUtc();

    await expectLater(
      database
          .into(database.waterLogs)
          .insert(
            WaterLogsCompanion.insert(
              id: 'orphan-water',
              profileId: 'missing-profile',
              milliliters: 250,
              loggedAt: now,
              createdAt: now,
              updatedAt: now,
            ),
          ),
      throwsA(isA<Exception>()),
    );
  });
}
