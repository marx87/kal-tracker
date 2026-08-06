import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/theme/app_breakpoints.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/wellbeing/presentation/progress_screen.dart';

void main() {
  testWidgets('sul telefono la lista occupa tutta la larghezza', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    await LocalProfileRepository(database).getOrCreateMarco();

    _window(tester, 400);
    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    expect(_listWidth(tester), 400);

    await _dispose(tester, database);
  });

  testWidgets('sul tablet di Marco (1706 dp) il contenuto si ferma alla '
      'colonna leggibile', (tester) async {
    // Il difetto vero: senza limite le righe di «Dati personali» e la barra
    // dell'acqua andrebbero da un bordo all'altro del tablet.
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    await LocalProfileRepository(database).getOrCreateMarco();

    _window(tester, 1706);
    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    final width = _listWidth(tester);
    expect(
      width,
      AppBreakpoints.contentMaxWidth(AppWindowSize.expanded),
      reason: 'la colonna deve fermarsi alla larghezza leggibile',
    );
    expect(width, lessThan(1706));

    await _dispose(tester, database);
  });
}

double _listWidth(WidgetTester tester) =>
    tester.getSize(find.byKey(const Key('progress_list'))).width;

/// Finestra larga quanto serve e alta abbastanza da costruire tutta la lista.
void _window(WidgetTester tester, double width) {
  tester.view.physicalSize = Size(width, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget _app(AppDatabase database) => ProviderScope(
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
);

Future<void> _dispose(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(database.close);
}
