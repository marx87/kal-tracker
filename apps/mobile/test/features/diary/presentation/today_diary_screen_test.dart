import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/app.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/data/diary_repository.dart';
import 'package:kal_tracker/features/diary/data/meal_template_repository.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

void main() {
  testWidgets('aggiunge un alimento e aggiorna il totale giornaliero', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());

    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    expect(find.text('Diario di Marco'), findsOneWidget);
    expect(
      find.text(
        'Il diario è vuoto. Inizia con un alimento: funziona già anche senza rete.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('add_food_button')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('food_name_field')),
      'Riso basmati',
    );
    await tester.enterText(find.byKey(const Key('grams_field')), '150');
    await tester.enterText(find.byKey(const Key('calories_field')), '130');
    await tester.enterText(find.byKey(const Key('protein_field')), '2,7');
    await tester.enterText(find.byKey(const Key('carbs_field')), '28');
    await tester.enterText(find.byKey(const Key('fat_field')), '0,3');

    final saveButton = find.byKey(const Key('save_food_button'));
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    expect(find.text('Riso basmati'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('daily_calories'))).data,
      '195 kcal',
    );

    await _disposeApp(tester, database);
  });

  testWidgets('naviga tra i giorni e mostra il diario del giorno scelto', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final profile = await LocalProfileRepository(database).getOrCreateMarco();
    final diaryRepository = DiaryRepository(database);
    final today = AppTime.nowInRome();

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
        eatenAt: today,
      ),
    );
    await diaryRepository.addManualFood(
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
        eatenAt: DiaryDay.shift(today, -1),
      ),
    );

    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    expect(_dayPill('Oggi'), findsOneWidget);
    expect(find.text('Riso basmati'), findsOneWidget);
    expect(find.byKey(const Key('back_to_today_button')), findsNothing);

    await tester.tap(find.byKey(const Key('previous_day_button')));
    await tester.pumpAndSettle();

    expect(_dayPill('Ieri'), findsOneWidget);
    expect(find.text('Mela'), findsOneWidget);
    expect(find.text('Riso basmati'), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const Key('daily_calories'))).data,
      '52 kcal',
    );

    await tester.tap(find.byKey(const Key('back_to_today_button')));
    await tester.pumpAndSettle();

    expect(_dayPill('Oggi'), findsOneWidget);
    expect(find.text('Riso basmati'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('daily_calories'))).data,
      '195 kcal',
    );

    await _disposeApp(tester, database);
  });

  testWidgets('modifica i grammi di una voce e aggiorna il totale', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final profile = await LocalProfileRepository(database).getOrCreateMarco();
    final entryId = await DiaryRepository(database).addManualFood(
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
        eatenAt: AppTime.nowInRome(),
      ),
    );

    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    final tile = find.byKey(Key('diary_entry_$entryId'));
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('entry_preview_calories'))).data,
      '195 kcal',
    );

    await tester.enterText(find.byKey(const Key('edit_grams_field')), '200');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('entry_preview_calories'))).data,
      '260 kcal',
    );

    final save = find.byKey(const Key('save_entry_button'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('daily_calories'))).data,
      '260 kcal',
    );
    expect(find.text('200 g · P 5.4 · C 56.0 · G 0.6'), findsOneWidget);

    await _disposeApp(tester, database);
  });

  testWidgets('eliminare una voce chiede conferma e avvisa', (tester) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final profile = await LocalProfileRepository(database).getOrCreateMarco();
    final entryId = await DiaryRepository(database).addManualFood(
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
        eatenAt: AppTime.nowInRome(),
      ),
    );

    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    await _openEntryMenu(tester, entryId);
    await tester.tap(find.byKey(Key('delete_entry_$entryId')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('delete_entry_dialog')), findsOneWidget);
    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle();
    expect(find.text('Riso basmati'), findsOneWidget);

    await _openEntryMenu(tester, entryId);
    await tester.tap(find.byKey(Key('delete_entry_$entryId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm_delete_entry')));
    await tester.pumpAndSettle();

    expect(find.text('Riso basmati eliminato dal diario.'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('daily_calories'))).data,
      '0 kcal',
    );

    await _disposeApp(tester, database);
  });

  testWidgets('annullare l’eliminazione riporta la voce nel diario', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final profile = await LocalProfileRepository(database).getOrCreateMarco();
    final entryId = await DiaryRepository(database).addManualFood(
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
        eatenAt: AppTime.nowInRome(),
      ),
    );

    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    await _openEntryMenu(tester, entryId);
    await tester.tap(find.byKey(Key('delete_entry_$entryId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm_delete_entry')));
    await tester.pumpAndSettle();

    expect(find.text('Riso basmati eliminato dal diario.'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('daily_calories'))).data,
      '0 kcal',
    );

    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle();

    expect(find.text('Riso basmati'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('daily_calories'))).data,
      '195 kcal',
    );

    final item = await (database.select(
      database.mealItems,
    )..where((row) => row.id.equals(entryId))).getSingle();
    expect(item.deletedAt, isNull);

    await _disposeApp(tester, database);
  });

  testWidgets('eliminare un modello chiede conferma e annulla non cancella', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final profile = await LocalProfileRepository(database).getOrCreateMarco();
    final diaryRepository = DiaryRepository(database);
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
        eatenAt: AppTime.nowInRome(),
      ),
    );
    final templateId =
        await MealTemplateRepository(
          database,
          diaryRepository: diaryRepository,
        ).saveTemplateFromMeal(
          profileId: profile.id,
          day: AppTime.nowInRome(),
          mealType: MealType.lunch,
          name: 'Pranzo veloce',
        );

    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    await _openMealMenu(tester);
    await tester.tap(find.text('Applica un modello'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('template_menu_$templateId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('delete_template_$templateId')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('delete_template_dialog')), findsOneWidget);
    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle();

    expect(find.byKey(Key('apply_template_$templateId')), findsOneWidget);
    final untouched = await (database.select(
      database.mealTemplates,
    )..where((row) => row.id.equals(templateId))).getSingle();
    expect(untouched.deletedAt, isNull);

    await tester.tap(find.byKey(Key('template_menu_$templateId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('delete_template_$templateId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm_delete_template')));
    await tester.pumpAndSettle();

    expect(find.text('Modello “Pranzo veloce” eliminato.'), findsOneWidget);
    final deleted = await (database.select(
      database.mealTemplates,
    )..where((row) => row.id.equals(templateId))).getSingle();
    expect(deleted.deletedAt, isNotNull);

    await _disposeApp(tester, database);
  });

  testWidgets('salva un pasto come modello e lo applica a un altro giorno', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final profile = await LocalProfileRepository(database).getOrCreateMarco();
    await DiaryRepository(database).addManualFood(
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
        eatenAt: AppTime.nowInRome(),
      ),
    );

    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    await _openMealMenu(tester);
    await tester.tap(find.text('Salva come modello'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('template_name_field')),
      'Pranzo veloce',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm_template_name_button')));
    await tester.pumpAndSettle();

    expect(find.text('Modello “Pranzo veloce” salvato.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    final previousDay = find.byKey(const Key('previous_day_button'));
    await tester.ensureVisible(previousDay);
    await tester.pumpAndSettle();
    await tester.tap(previousDay);
    await tester.pumpAndSettle();
    expect(_dayPill('Ieri'), findsOneWidget);
    expect(find.text('Riso basmati'), findsNothing);

    await _openMealMenu(tester);
    await tester.tap(find.text('Applica un modello'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pranzo veloce'));
    await tester.pumpAndSettle();

    expect(find.text('Riso basmati'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('daily_calories'))).data,
      '195 kcal',
    );

    await _disposeApp(tester, database);
  });
}

Future<void> _openEntryMenu(WidgetTester tester, String entryId) async {
  final menu = find.byKey(Key('entry_menu_$entryId'));
  await tester.ensureVisible(menu);
  await tester.pumpAndSettle();
  await tester.tap(menu);
  await tester.pumpAndSettle();
}

Future<void> _openMealMenu(WidgetTester tester) async {
  final menu = find.byKey(const Key('meal_menu_lunch'));
  await tester.ensureVisible(menu);
  await tester.pumpAndSettle();
  await tester.tap(menu);
  await tester.pumpAndSettle();
}

Finder _dayPill(String label) => find.descendant(
  of: find.byKey(const Key('day_picker_button')),
  matching: find.text(label),
);

Widget _app(AppDatabase database) => ProviderScope(
  overrides: [
    databaseProvider.overrideWithValue(database),
    appConfigProvider.overrideWithValue(const AppConfig.offline()),
  ],
  child: const KalTrackerApp(),
);

Future<void> _disposeApp(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(database.close);
}
