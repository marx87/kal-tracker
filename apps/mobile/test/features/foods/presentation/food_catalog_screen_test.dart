import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/app.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';

void main() {
  testWidgets('l’aggiunta rapida dice in quale giorno finisce l’alimento', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          appConfigProvider.overrideWithValue(const AppConfig.offline()),
        ],
        child: const KalTrackerApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('previous_day_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav_foods')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('quick_add_seed-banana')));
    await tester.pumpAndSettle();
    final save = find.byKey(const Key('save_food_button'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(find.text('Banana aggiunto al diario di ieri.'), findsOneWidget);

    final meal = await database.select(database.meals).getSingle();
    final item = await database.select(database.mealItems).getSingle();
    expect(item.foodName, 'Banana');
    expect(
      DiaryDay.isSameDay(
        AppTime.inRome(meal.eatenAt),
        DiaryDay.shift(AppTime.nowInRome(), -1),
      ),
      isTrue,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(database.close);
  });
}
