import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/routines/presentation/weekly_schedule_providers.dart';
import 'package:kal_tracker/features/routines/presentation/weekly_schedule_screen.dart';

/// Il giorno di oggi è fissato: con l'orologio vero la riga «· oggi» si
/// sposterebbe da sola e il test fallirebbe un giorno su sette.
const _oggi = 3;

Widget _app(AppDatabase database) => ProviderScope(
  overrides: [
    databaseProvider.overrideWithValue(database),
    todayWeekdayProvider.overrideWithValue(_oggi),
  ],
  child: MaterialApp(theme: AppTheme.light, home: const WeeklyScheduleScreen()),
);

void main() {
  late AppDatabase database;
  late String profileId;

  setUpAll(() => initializeDateFormatting('it'));

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
  });

  /// Finestra alta quanto serve a tenere tutti e sette i giorni montati: la
  /// `ListView` costruisce solo ciò che si vede, e scorrere prima di ogni
  /// tocco renderebbe illeggibile ogni test senza provare niente di più.
  void tallWindow(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Smonta l'albero prima di chiudere il database: drift, annullando lo
  /// stream, lascia un timer a durata zero che il framework conta come errore.
  Future<void> disposeApp(WidgetTester tester) async {
    // Smaltisce anche il timer di chiusura forzata delle snackbar con azione
    // (showAutoClosingSnackBar), che su questo Flutter non si chiudono da sole.
    await tester.pump(const Duration(seconds: 9));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(database.close);
  }

  Future<void> seedRoutine(String id, String name) => database
      .into(database.routines)
      .insert(
        RoutinesCompanion.insert(
          id: id,
          profileId: profileId,
          name: name,
          createdAt: DateTime.utc(2026, 8, 1),
          updatedAt: DateTime.utc(2026, 8, 1),
        ),
      );

  Future<List<LocalRoutineWeeklyPlanDay>> week() =>
      database.select(database.routineWeeklyPlan).get();

  testWidgets('senza schede dice cosa manca invece di sette righe vuote', (
    tester,
  ) async {
    tallWindow(tester);
    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('weekly_schedule_empty_state')),
      findsOneWidget,
    );
    expect(find.text('Crea la prima scheda'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('la settimana mostra sette giorni e segna oggi', (tester) async {
    await seedRoutine('routine-gambe', 'Gambe');
    tallWindow(tester);
    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    for (var weekday = 1; weekday <= 7; weekday++) {
      expect(
        find.byKey(Key('weekly_schedule_day_$weekday')),
        findsOneWidget,
        reason: 'manca il giorno $weekday',
      );
    }
    expect(find.text('Riposo'), findsNWidgets(7));
    // «Oggi» sta anche nel testo: il colore da solo non arriva a tutti.
    expect(find.text('Mercoledì · oggi'), findsOneWidget);
    expect(find.text('Nessun allenamento previsto'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('scegliere una scheda scrive il giorno e lo dice', (
    tester,
  ) async {
    await seedRoutine('routine-gambe', 'Gambe');
    tallWindow(tester);
    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('weekly_schedule_day_2')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('weekly_schedule_pick_routine-gambe')),
    );
    await tester.pumpAndSettle();

    final rows = await week();
    expect(rows.single.weekday, 2);
    expect(rows.single.routineId, 'routine-gambe');
    expect(find.text('Martedì: Gambe'), findsOneWidget);
    expect(find.text('1 allenamento a settimana'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('«Annulla» rimette il giorno com\'era', (tester) async {
    await seedRoutine('routine-gambe', 'Gambe');
    tallWindow(tester);
    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('weekly_schedule_day_5')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('weekly_schedule_pick_routine-gambe')),
    );
    await tester.pumpAndSettle();
    expect(await week(), hasLength(1));

    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle();

    // Il venerdì torna riposo: cioè torna a non avere una riga.
    expect(await week(), isEmpty);

    await disposeApp(tester);
  });

  testWidgets('«Riposo» toglie la scheda e manda la settimana senza quel '
      'giorno', (tester) async {
    await seedRoutine('routine-gambe', 'Gambe');
    await database
        .into(database.routineWeeklyPlan)
        .insert(
          RoutineWeeklyPlanCompanion.insert(
            id: 'giorno-1',
            profileId: profileId,
            weekday: 1,
            routineId: const Value('routine-gambe'),
            routineExternalId: const Value('routine-gambe'),
            routineNameSnapshot: const Value('Gambe'),
            updatedAt: DateTime.utc(2026, 8, 1),
          ),
        );
    tallWindow(tester);
    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('weekly_schedule_day_1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('weekly_schedule_pick_rest')));
    await tester.pumpAndSettle();

    expect(await week(), isEmpty);
    expect(find.text('Lunedì: riposo'), findsOneWidget);

    // E la coda porta la settimana intera, vuota: è l'unico modo perché il
    // giorno tolto arrivi anche sull'altro dispositivo.
    final riga = await database.select(database.syncOutbox).getSingle();
    expect(riga.entityType, 'routine_weekly_plan');
    final payload = jsonDecode(riga.payloadJson) as Map<String, Object?>;
    expect(payload['days'], isEmpty);

    await disposeApp(tester);
  });

  testWidgets('riscegliere la stessa scheda non scrive niente', (tester) async {
    await seedRoutine('routine-gambe', 'Gambe');
    tallWindow(tester);
    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('weekly_schedule_day_4')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('weekly_schedule_pick_routine-gambe')),
    );
    await tester.pumpAndSettle();
    final primaCoda = (await database.select(database.syncOutbox).get()).length;

    await tester.tap(find.byKey(const Key('weekly_schedule_day_4')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('weekly_schedule_pick_routine-gambe')),
    );
    await tester.pumpAndSettle();

    // Toccare la scheda già assegnata non è una modifica: nessuna riga in più
    // da mandare, e nessun `updated_at` che vince un conflitto per sbaglio.
    expect(
      (await database.select(database.syncOutbox).get()).length,
      primaCoda,
    );

    await disposeApp(tester);
  });

  testWidgets('un giorno con la scheda cancellata lo dice e non offre '
      'l\'annulla', (tester) async {
    await database
        .into(database.routines)
        .insert(
          RoutinesCompanion.insert(
            id: 'routine-vecchia',
            profileId: profileId,
            name: 'Vecchia',
            createdAt: DateTime.utc(2026, 8, 1),
            updatedAt: DateTime.utc(2026, 8, 1),
            deletedAt: Value(DateTime.utc(2026, 8, 2)),
          ),
        );
    await seedRoutine('routine-gambe', 'Gambe');
    await database
        .into(database.routineWeeklyPlan)
        .insert(
          RoutineWeeklyPlanCompanion.insert(
            id: 'giorno-6',
            profileId: profileId,
            weekday: 6,
            routineExternalId: const Value('routine-vecchia'),
            routineNameSnapshot: const Value('Vecchia'),
            updatedAt: DateTime.utc(2026, 8, 1),
          ),
        );
    tallWindow(tester);
    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    expect(find.text('Questa scheda non c\'è più'), findsOneWidget);

    await tester.tap(find.byKey(const Key('weekly_schedule_day_6')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('weekly_schedule_pick_routine-gambe')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sabato: Gambe'), findsOneWidget);
    // Rimettere «com'era» vorrebbe dire far risorgere una scheda cancellata:
    // l'annulla non si offre invece di prometterlo e non mantenerlo.
    expect(find.text('Annulla'), findsNothing);

    await disposeApp(tester);
  });
}
