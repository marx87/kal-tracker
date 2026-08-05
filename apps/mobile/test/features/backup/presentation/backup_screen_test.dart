import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/app.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/backup/data/backup_repository.dart';
import 'package:kal_tracker/features/backup/data/backup_storage.dart';
import 'package:kal_tracker/features/backup/domain/backup_document.dart';
import 'package:kal_tracker/features/backup/presentation/backup_providers.dart';
import 'package:kal_tracker/features/backup/presentation/backup_screen.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

void main() {
  testWidgets('esporta il diario e mostra la data dell’ultimo backup', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final profileId = (await LocalProfileRepository(
      database,
    ).getOrCreateMarco()).id;
    await _seedMeal(database, profileId, 'Riso basmati cotto');
    final storage = _FakeBackupStorage();

    await tester.pumpWidget(_app(database, storage));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('last_export_at'))).data,
      'Non hai ancora fatto nessun backup.',
    );

    await tester.tap(find.byKey(const Key('export_backup_button')));
    await tester.pumpAndSettle();

    expect(storage.saved, isNotNull);
    final document = BackupDocument.decode(storage.saved!);
    expect(document.mealItems.single.foodName, 'Riso basmati cotto');
    expect(document.profile.id, profileId);
    expect(
      tester.widget<Text>(find.byKey(const Key('last_export_at'))).data,
      startsWith('Ultimo backup:'),
    );

    await _disposeApp(tester, database);
  });

  testWidgets('dai Progressi si raggiunge backup e ripristino', (tester) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    final storage = _FakeBackupStorage();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          appConfigProvider.overrideWithValue(const AppConfig.offline()),
          backupStorageProvider.overrideWithValue(storage),
        ],
        child: const KalTrackerApp(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('nav_body')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('body_open_progress_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open_backup_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('backup_list')), findsOneWidget);
    expect(find.text('Una copia del diario, quando vuoi'), findsOneWidget);

    await _disposeApp(tester, database);
  });

  testWidgets('la sostituzione chiede due conferme e mostra il riepilogo', (
    tester,
  ) async {
    AppTime.initialize();
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    addTearDown(
      () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false,
    );

    final database = AppDatabase(NativeDatabase.memory());
    final profileId = (await LocalProfileRepository(
      database,
    ).getOrCreateMarco()).id;
    await _seedMeal(database, profileId, 'Voce da sostituire');

    final other = AppDatabase(NativeDatabase.memory());
    final otherProfileId = (await LocalProfileRepository(
      other,
    ).getOrCreateMarco()).id;
    await _seedMeal(other, otherProfileId, 'Petto di pollo');
    final backup = await BackupRepository(
      other,
    ).exportBackup(profileId: otherProfileId);
    await other.close();

    final storage = _FakeBackupStorage()..restoreSource = backup.encode();

    await tester.pumpWidget(_app(database, storage));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('restore_backup_button')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('restore_source_field')),
      '/tmp/kal-tracker-backup-2026-08-03.json',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('restore_mode_replace')));
    await tester.pumpAndSettle();

    final continueButton = find.byKey(const Key('restore_continue_button'));
    await tester.ensureVisible(continueButton);
    await tester.tap(continueButton);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('confirm_restore_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('restore_summary')), findsNothing);

    await tester.tap(find.byKey(const Key('confirm_replace_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('restore_summary')), findsOneWidget);
    final items = await database.select(database.mealItems).get();
    expect(items.map((row) => row.foodName), ['Petto di pollo']);
    expect(
      (await database.select(database.appProfiles).get()).map((row) => row.id),
      [otherProfileId],
    );

    await _disposeApp(tester, database);
  });
}

Widget _app(AppDatabase database, BackupStorage storage) => ProviderScope(
  overrides: [
    databaseProvider.overrideWithValue(database),
    backupStorageProvider.overrideWithValue(storage),
  ],
  child: MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('it'),
    supportedLocales: const [Locale('it')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: const BackupScreen(),
  ),
);

Future<void> _disposeApp(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(database.close);
}

Future<void> _seedMeal(
  AppDatabase database,
  String profileId,
  String foodName,
) async {
  final moment = DateTime.utc(2026, 8, 1, 12, 30);
  final mealId = 'meal-${foodName.hashCode}';
  await database
      .into(database.meals)
      .insert(
        MealsCompanion.insert(
          id: mealId,
          profileId: profileId,
          mealType: 'lunch',
          eatenAt: moment,
          createdAt: moment,
          updatedAt: moment,
        ),
      );
  await database
      .into(database.mealItems)
      .insert(
        MealItemsCompanion.insert(
          id: 'item-${foodName.hashCode}',
          mealId: mealId,
          foodName: foodName,
          grams: 150,
          caloriesPer100g: 130,
          proteinPer100g: 2.7,
          carbsPer100g: 28.2,
          fatPer100g: 0.3,
          totalCalories: 195,
          totalProtein: 4.05,
          totalCarbs: 42.3,
          totalFat: 0.45,
          createdAt: moment,
          updatedAt: moment,
        ),
      );
}

class _FakeBackupStorage implements BackupStorage {
  String? saved;
  DateTime? savedAt;
  String? restoreSource;

  @override
  Future<BackupExportResult> saveBackup({
    required String contents,
    required DateTime exportedAt,
  }) async {
    saved = contents;
    savedAt = exportedAt;
    return BackupExportResult(
      path: '/tmp/${FileBackupStorage.backupFileName(exportedAt)}',
      exportedAt: exportedAt,
      shared: true,
    );
  }

  @override
  Future<BackupState> readState() async => BackupState(
    lastExportAt: savedAt,
    lastExportPath: savedAt == null
        ? null
        : '/tmp/${FileBackupStorage.backupFileName(savedAt!)}',
  );

  @override
  Future<String> readRestoreSource(String rawInput) async =>
      restoreSource ?? rawInput;
}
