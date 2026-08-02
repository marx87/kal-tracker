import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/data/diary_repository.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

void main() {
  late AppDatabase database;
  late LocalProfileRepository profileRepository;
  late DiaryRepository diaryRepository;

  setUp(() {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileRepository = LocalProfileRepository(database);
    diaryRepository = DiaryRepository(database);
  });

  tearDown(() => database.close());

  test('crea Marco una sola volta', () async {
    final first = await profileRepository.getOrCreateMarco();
    final second = await profileRepository.getOrCreateMarco();
    final profiles = await database.select(database.appProfiles).get();

    expect(first.id, second.id);
    expect(first.displayName, 'Marco');
    expect(profiles, hasLength(1));
  });

  test('salva un alimento, calcola lo snapshot e crea la outbox', () async {
    final profile = await profileRepository.getOrCreateMarco();
    final day = AppTime.nowInRome();

    await diaryRepository.addManualFood(
      profileId: profile.id,
      input: ManualFoodInput(
        foodName: 'Riso basmati',
        grams: 150,
        per100g: const Nutrients(
          calories: 130,
          protein: 2.7,
          carbs: 28,
          fat: 0.3,
        ),
        mealType: MealType.lunch,
        eatenAt: day,
      ),
    );

    final diary = await diaryRepository
        .watchDay(profileId: profile.id, day: day)
        .first;
    final outbox = await database.select(database.syncOutbox).get();

    expect(diary.entries, hasLength(1));
    expect(diary.entries.single.foodName, 'Riso basmati');
    expect(diary.totals.calories, closeTo(195, 0.0001));
    expect(diary.totals.protein, closeTo(4.05, 0.0001));
    expect(outbox, hasLength(1));
    expect(outbox.single.operation, 'upsert');
  });

  test('non mostra voci appartenenti a un altro giorno', () async {
    final profile = await profileRepository.getOrCreateMarco();
    final day = AppTime.nowInRome();
    final tomorrow = day.add(const Duration(days: 1));

    await diaryRepository.addManualFood(
      profileId: profile.id,
      input: ManualFoodInput(
        foodName: 'Yogurt',
        grams: 125,
        per100g: const Nutrients(calories: 60, protein: 4, carbs: 5, fat: 2),
        mealType: MealType.breakfast,
        eatenAt: tomorrow,
      ),
    );

    final diary = await diaryRepository
        .watchDay(profileId: profile.id, day: day)
        .first;

    expect(diary.entries, isEmpty);
  });

  test('la cancellazione usa un tombstone e una nuova operazione', () async {
    final profile = await profileRepository.getOrCreateMarco();
    final day = AppTime.nowInRome();
    final id = await diaryRepository.addManualFood(
      profileId: profile.id,
      input: ManualFoodInput(
        foodName: 'Mela',
        grams: 100,
        per100g: const Nutrients(
          calories: 52,
          protein: 0.3,
          carbs: 14,
          fat: 0.2,
        ),
        mealType: MealType.snack,
        eatenAt: day,
      ),
    );

    await diaryRepository.deleteEntry(id);
    final diary = await diaryRepository
        .watchDay(profileId: profile.id, day: day)
        .first;
    final item = await (database.select(
      database.mealItems,
    )..where((row) => row.id.equals(id))).getSingle();
    final outbox = await database.select(database.syncOutbox).get();

    expect(diary.entries, isEmpty);
    expect(item.deletedAt, isNotNull);
    expect(outbox.map((row) => row.operation), ['upsert', 'delete']);
  });

  test('la cancellazione ripetuta non duplica la outbox', () async {
    final profile = await profileRepository.getOrCreateMarco();
    final id = await diaryRepository.addManualFood(
      profileId: profile.id,
      input: ManualFoodInput(
        foodName: 'Pera',
        grams: 100,
        per100g: const Nutrients(
          calories: 57,
          protein: 0.4,
          carbs: 15,
          fat: 0.1,
        ),
        mealType: MealType.snack,
        eatenAt: AppTime.nowInRome(),
      ),
    );

    await diaryRepository.deleteEntry(id);
    await diaryRepository.deleteEntry(id);

    final outbox = await database.select(database.syncOutbox).get();
    expect(outbox.map((row) => row.operation), ['upsert', 'delete']);
  });

  test('le foreign key SQLite rifiutano un alimento senza pasto', () async {
    final now = AppTime.nowUtc();

    await expectLater(
      database
          .into(database.mealItems)
          .insert(
            MealItemsCompanion.insert(
              id: 'orphan-item',
              mealId: 'missing-meal',
              foodName: 'Orfano',
              grams: 100,
              caloriesPer100g: 10,
              proteinPer100g: 1,
              carbsPer100g: 1,
              fatPer100g: 1,
              totalCalories: 10,
              totalProtein: 1,
              totalCarbs: 1,
              totalFat: 1,
              createdAt: now,
              updatedAt: now,
            ),
          ),
      throwsA(isA<Exception>()),
    );
  });

  test('profili e diario persistono dopo chiusura e riapertura', () async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final tempDirectory = await Directory.systemTemp.createTemp(
      'kal_tracker_persistence_',
    );
    final databaseFile = File('${tempDirectory.path}/kal-tracker.sqlite');
    AppDatabase? diskDatabase;
    addTearDown(() async {
      if (diskDatabase != null) {
        await diskDatabase.close();
      }
      if (await tempDirectory.exists()) {
        await tempDirectory.delete(recursive: true);
      }
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = false;
    });

    diskDatabase = AppDatabase(NativeDatabase(databaseFile));
    final diskProfileRepository = LocalProfileRepository(diskDatabase);
    final profile = await diskProfileRepository.getOrCreateMarco();
    final day = AppTime.nowInRome();
    await DiaryRepository(diskDatabase).addManualFood(
      profileId: profile.id,
      input: ManualFoodInput(
        foodName: 'Pane integrale',
        grams: 80,
        per100g: const Nutrients(calories: 250, protein: 9, carbs: 43, fat: 4),
        mealType: MealType.breakfast,
        eatenAt: day,
      ),
    );
    await diskDatabase.close();
    diskDatabase = null;

    diskDatabase = AppDatabase(NativeDatabase(databaseFile));
    final reopenedProfiles = await diskDatabase
        .select(diskDatabase.appProfiles)
        .get();
    final reopenedDiary = await DiaryRepository(
      diskDatabase,
    ).watchDay(profileId: profile.id, day: day).first;

    expect(reopenedProfiles.single.displayName, 'Marco');
    expect(reopenedDiary.entries.single.foodName, 'Pane integrale');
    expect(reopenedDiary.totals.calories, closeTo(200, 0.0001));
  });
}
