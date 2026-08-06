import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/wellbeing/presentation/progress_screen.dart';

void main() {
  testWidgets('probe foglio obiettivi su tablet', (tester) async {
    AppTime.initialize();
    tester.view.physicalSize = const Size(1706, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final database = AppDatabase(NativeDatabase.memory());
    await LocalProfileRepository(database).getOrCreateMarco();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(database)],
        child: MaterialApp(
          theme: AppTheme.light,
          locale: const Locale('it'),
          supportedLocales: const [Locale('it')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const ProgressScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('edit_targets_button')));
    await tester.pumpAndSettle();

    final field = find.byKey(const Key('target_calories_field'));
    // ignore: avoid_print
    print('CAMPO larghezza=${tester.getSize(field).width} top=${tester.getTopLeft(field).dy}');
    final sheet = find.byType(BottomSheet);
    // ignore: avoid_print
    print('FOGLIO size=${tester.getSize(sheet)} top=${tester.getTopLeft(sheet).dy}');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(database.close);
  });
}
