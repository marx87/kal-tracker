import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/app.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';

void main() {
  testWidgets('aggiunge un alimento e aggiorna il totale giornaliero', (
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

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(database.close);
  });
}
