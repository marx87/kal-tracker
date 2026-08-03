import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/calorie_progress_card.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/wellness_meal_card.dart';

void main() {
  testWidgets('il riepilogo giocoso resta leggibile su un telefono stretto', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 700);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('it'),
        theme: AppTheme.light,
        home: Scaffold(
          body: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: const SingleChildScrollView(
                padding: EdgeInsets.all(12),
                child: CalorieProgressCard(
                  targetCalories: 2200,
                  nutrients: Nutrients(
                    calories: 195,
                    protein: 4.1,
                    carbs: 42,
                    fat: 0.5,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('daily_calories'))).data,
      '195 kcal',
    );
    expect(find.text('su 2.200'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('la card pasto gestisce nomi lunghi senza overflow', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 700);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final entry = DiaryEntry(
      id: 'entry-1',
      mealId: 'meal-1',
      foodName: 'Insalata mediterranea con ceci e verdure croccanti',
      grams: 180,
      mealType: MealType.lunch,
      eatenAt: DateTime(2026, 8, 2, 13),
      per100g: const Nutrients(
        calories: 157.8,
        protein: 6.2,
        carbs: 21.3,
        fat: 4.5,
      ),
      nutrients: const Nutrients(
        calories: 284,
        protein: 11.2,
        carbs: 38.4,
        fat: 8.1,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: WellnessMealCard(
              title: 'Pranzo',
              icon: Icons.light_mode_outlined,
              accent: AppPalette.coral,
              softColor: AppPalette.coralSoft,
              entries: [entry],
              onDelete: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Pranzo'), findsOneWidget);
    expect(find.byTooltip('Azioni per ${entry.foodName}'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('la card pasto offre modifica, duplica ed elimina', (
    tester,
  ) async {
    final entry = DiaryEntry(
      id: 'entry-1',
      mealId: 'meal-1',
      foodName: 'Riso basmati',
      grams: 150,
      mealType: MealType.lunch,
      eatenAt: DateTime(2026, 8, 2, 13),
      per100g: const Nutrients(
        calories: 130,
        protein: 2.7,
        carbs: 28,
        fat: 0.3,
      ),
      nutrients: const Nutrients(
        calories: 195,
        protein: 4.05,
        carbs: 42,
        fat: 0.45,
      ),
    );
    final actions = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('it'),
        theme: AppTheme.light,
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: WellnessMealCard(
              title: 'Pranzo',
              icon: Icons.light_mode_outlined,
              accent: AppPalette.coral,
              softColor: AppPalette.coralSoft,
              menuKey: const Key('meal_menu_lunch'),
              entries: [entry],
              onDelete: (_) => actions.add('delete'),
              onEdit: (_) => actions.add('edit'),
              onDuplicate: (_) => actions.add('duplicate'),
              onCopyFromAnotherDay: () => actions.add('copy'),
              onSaveAsTemplate: () => actions.add('template'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('diary_entry_entry-1')));
    await tester.pumpAndSettle();
    expect(actions, ['edit']);

    await tester.tap(find.byKey(const Key('entry_menu_entry-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('duplicate_entry_entry-1')));
    await tester.pumpAndSettle();
    expect(actions, ['edit', 'duplicate']);

    await tester.tap(find.byKey(const Key('meal_menu_lunch')));
    await tester.pumpAndSettle();
    expect(find.text('Applica un modello'), findsNothing);
    await tester.tap(find.text('Copia da un altro giorno…'));
    await tester.pumpAndSettle();

    expect(actions, ['edit', 'duplicate', 'copy']);
    expect(tester.takeException(), isNull);
  });
}
