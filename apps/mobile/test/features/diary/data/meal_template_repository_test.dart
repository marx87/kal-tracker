import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/data/diary_repository.dart';
import 'package:kal_tracker/features/diary/data/meal_template_repository.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

void main() {
  late AppDatabase database;
  late DiaryRepository diaryRepository;
  late MealTemplateRepository templateRepository;
  late String profileId;
  late DateTime day;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
    diaryRepository = DiaryRepository(database);
    templateRepository = MealTemplateRepository(
      database,
      diaryRepository: diaryRepository,
    );
    day = AppTime.nowInRome();
  });

  tearDown(() => database.close());

  Future<void> seedBreakfast() async {
    await diaryRepository.addManualFood(
      profileId: profileId,
      input: ManualFoodInput(
        foodName: 'Fiocchi d’avena',
        grams: 60,
        per100g: const Nutrients(calories: 370, protein: 13, carbs: 60, fat: 7),
        mealType: MealType.breakfast,
        eatenAt: day,
      ),
    );
    await diaryRepository.addManualFood(
      profileId: profileId,
      input: ManualFoodInput(
        foodName: 'Latte',
        grams: 200,
        per100g: const Nutrients(
          calories: 46,
          protein: 3.3,
          carbs: 5,
          fat: 1.5,
        ),
        mealType: MealType.breakfast,
        eatenAt: day,
      ),
    );
  }

  Future<List<String>> templateOperations() async {
    final outbox = await database.select(database.syncOutbox).get();
    return outbox
        .where((row) => row.entityType == 'meal_template')
        .map((row) => row.operation)
        .toList(growable: false);
  }

  test('salva un modello dal pasto con i suoi alimenti', () async {
    await seedBreakfast();

    final templateId = await templateRepository.saveTemplateFromMeal(
      profileId: profileId,
      day: day,
      mealType: MealType.breakfast,
      name: '  Colazione forte  ',
    );
    final templates = await templateRepository.watchTemplates(profileId).first;

    expect(templates, hasLength(1));
    expect(templates.single.id, templateId);
    expect(templates.single.name, 'Colazione forte');
    expect(templates.single.mealType, MealType.breakfast);
    expect(templates.single.items, hasLength(2));
    expect(templates.single.totals.calories, closeTo(314, 0.0001));
    expect(await templateOperations(), ['upsert']);
  });

  test('non salva un modello da un pasto vuoto', () async {
    await expectLater(
      templateRepository.saveTemplateFromMeal(
        profileId: profileId,
        day: day,
        mealType: MealType.dinner,
        name: 'Cena tipo',
      ),
      throwsStateError,
    );

    expect(await templateRepository.watchTemplates(profileId).first, isEmpty);
    expect(await templateOperations(), isEmpty);
  });

  test('applica il modello e aumenta i totali del giorno', () async {
    await seedBreakfast();
    final templateId = await templateRepository.saveTemplateFromMeal(
      profileId: profileId,
      day: day,
      mealType: MealType.breakfast,
      name: 'Colazione forte',
    );
    final otherDay = DiaryDay.shift(day, -2);

    final createdIds = await templateRepository.applyTemplate(
      templateId: templateId,
      profileId: profileId,
      day: otherDay,
    );
    final diary = await diaryRepository
        .watchDay(profileId: profileId, day: otherDay)
        .first;

    expect(createdIds, hasLength(2));
    expect(diary.entriesFor(MealType.breakfast), hasLength(2));
    expect(diary.totals.calories, closeTo(314, 0.0001));
    expect(diary.totals.protein, closeTo(14.4, 0.0001));
  });

  test('rinomina il modello e rifiuta un nome vuoto', () async {
    await seedBreakfast();
    final templateId = await templateRepository.saveTemplateFromMeal(
      profileId: profileId,
      day: day,
      mealType: MealType.breakfast,
      name: 'Colazione forte',
    );

    await templateRepository.renameTemplate(
      templateId: templateId,
      name: 'Colazione veloce',
    );
    await expectLater(
      templateRepository.renameTemplate(templateId: templateId, name: '   '),
      throwsFormatException,
    );

    final templates = await templateRepository.watchTemplates(profileId).first;
    expect(templates.single.name, 'Colazione veloce');
    expect(templates.single.items, hasLength(2));
    expect(await templateOperations(), ['upsert', 'upsert']);
  });

  test('la cancellazione del modello è soft e idempotente', () async {
    await seedBreakfast();
    final templateId = await templateRepository.saveTemplateFromMeal(
      profileId: profileId,
      day: day,
      mealType: MealType.breakfast,
      name: 'Colazione forte',
    );

    await templateRepository.deleteTemplate(templateId);
    await templateRepository.deleteTemplate(templateId);

    final stored = await (database.select(
      database.mealTemplates,
    )..where((row) => row.id.equals(templateId))).getSingle();
    final storedItems = await database.select(database.mealTemplateItems).get();

    expect(stored.deletedAt, isNotNull);
    expect(storedItems, hasLength(2));
    expect(await templateRepository.watchTemplates(profileId).first, isEmpty);
    expect(await templateRepository.getTemplate(templateId), isNull);
    expect(await templateOperations(), ['upsert', 'delete']);
  });
}
