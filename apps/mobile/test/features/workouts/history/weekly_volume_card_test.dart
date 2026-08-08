import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/workouts/presentation/history/widgets/weekly_volume_card.dart';
import 'package:kal_tracker/features/workouts/presentation/history/workout_history_screen.dart';

import 'workout_history_fixtures.dart';

/// La banda del volume settimanale in schermata.
///
/// I test guardano il database vero e non un valore finto: il difetto che
/// questa card doveva sanare non era un conteggio sbagliato — quello il
/// dominio lo sapeva già fare — ma un conteggio che nessuno chiamava.

/// Venerdì 7 agosto 2026: la settimana in corso è lunedì 3 – domenica 9.
final _today = DateTime.utc(2026, 8, 7, 12);

DateTime _dayOfWeek(int isoWeekday, {int weeksAgo = 0}) => DateTime.utc(
  2026,
  8,
  3,
  10,
).add(Duration(days: isoWeekday - 1 - 7 * weeksAgo));

void main() {
  late AppDatabase database;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    await seedProfile(database);
  });

  tearDown(() async {
    await database.close();
  });

  Widget host({ThemeData? theme, Widget? child}) => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(database),
      todayProvider.overrideWithValue(_today),
    ],
    child: MaterialApp(
      theme: theme ?? AppTheme.light,
      locale: const Locale('it'),
      supportedLocales: const [Locale('it')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: child ?? const WeeklyVolumeCard(),
        ),
      ),
    ),
  );

  /// Smonta l'albero e lascia scattare il timer con cui drift chiude le
  /// query rimaste in ascolto.
  Future<void> disposeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  void useTallWindow(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> seedSession({
    required String id,
    required DateTime startedAt,
    required String exerciseName,
    String? muscleGroup,
    int sets = 3,
    bool warmupBlock = false,
  }) async {
    await seedWorkout(
      database,
      id: id,
      profileId: 'marco',
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(minutes: 50)),
      finalDurationSeconds: 3000,
    );
    await seedWorkoutExercise(
      database,
      id: '$id-ex',
      workoutId: id,
      position: 0,
      name: exerciseName,
      muscleGroup: muscleGroup,
      isWarmup: warmupBlock,
    );
    for (var index = 0; index < sets; index++) {
      await seedSet(
        database,
        id: '$id-set-$index',
        workoutExerciseId: '$id-ex',
        position: index,
        weightKg: 20,
        reps: 12,
      );
    }
  }

  /// La settimana di Marco come la racconta il compito: quattro sedute,
  /// braccia e spalle allenate, addome e tricipiti rimasti fuori, più le due
  /// serie che il conteggio non guarda.
  Future<void> seedTheWeek() async {
    await seedSession(
      id: 'w-lun',
      startedAt: _dayOfWeek(DateTime.monday),
      exerciseName: 'Alzate laterali',
      muscleGroup: 'spalle',
      sets: 4,
    );
    await seedSession(
      id: 'w-mar',
      startedAt: _dayOfWeek(DateTime.tuesday),
      exerciseName: 'Curl manubri',
      muscleGroup: 'bicipiti',
      sets: 5,
    );
    await seedSession(
      id: 'w-gio',
      startedAt: _dayOfWeek(DateTime.thursday),
      exerciseName: 'Curl bilanciere',
      muscleGroup: 'bicipiti',
      sets: 3,
    );
    await seedSession(
      id: 'w-ven',
      startedAt: _dayOfWeek(DateTime.friday),
      exerciseName: 'Corsa',
      muscleGroup: 'cardio',
      sets: 2,
    );
    // Le due esclusioni da dichiarare: il riscaldamento e una riga a cui
    // manca lo scatto del catalogo.
    await seedWorkoutExercise(
      database,
      id: 'w-lun-risc',
      workoutId: 'w-lun',
      position: 1,
      name: 'Mobilità spalle',
      muscleGroup: 'spalle',
      isWarmup: true,
    );
    await seedSet(
      database,
      id: 'w-lun-risc-set',
      workoutExerciseId: 'w-lun-risc',
      position: 0,
      reps: 15,
    );
    await seedWorkoutExercise(
      database,
      id: 'w-mar-orfano',
      workoutId: 'w-mar',
      position: 1,
      name: 'Esercizio senza gruppo',
    );
    await seedSet(
      database,
      id: 'w-mar-orfano-set',
      workoutExerciseId: 'w-mar-orfano',
      position: 0,
      weightKg: 10,
      reps: 10,
    );
  }

  testWidgets('la settimana si legge gruppo per gruppo, con la banda accanto', (
    tester,
  ) async {
    useTallWindow(tester);
    await seedTheWeek();

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('weekly_volume_card')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('weekly_volume_range'))).data,
      '3 – 9 agosto',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('weekly_volume_totals'))).data,
      '4 sessioni · 14 serie contate',
    );

    // I gruppi con banda ci sono tutti, anche quelli a zero: è il caso che
    // conta di più.
    for (final group in const [
      'petto',
      'schiena',
      'spalle',
      'bicipiti',
      'tricipiti',
      'gambe',
      'polpacci',
      'addome',
    ]) {
      expect(
        find.byKey(Key('weekly_volume_group_$group')),
        findsOneWidget,
        reason: 'il gruppo $group deve comparire anche a zero',
      );
    }
    // Il cardio si conta ma non si giudica: compare senza banda.
    expect(find.byKey(const Key('weekly_volume_group_cardio')), findsOneWidget);
    expect(find.text('senza banda'), findsOneWidget);

    await disposeTree(tester);
  });

  testWidgets('i gruppi dell\'obiettivo rimasti a zero hanno una frase loro', (
    tester,
  ) async {
    useTallWindow(tester);
    await seedTheWeek();

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    final onTarget = tester
        .widget<Text>(find.byKey(const Key('weekly_volume_empty_focus')))
        .data!;
    expect(onTarget, contains('Tricipiti e Addome'));
    expect(onTarget, contains('esercizio saltato o escluso'));

    // Petto e gambe a zero in una settimana di braccia non sono un allarme:
    // stanno in una frase più quieta, e in un'altra.
    final offTarget = tester
        .widget<Text>(find.byKey(const Key('weekly_volume_empty_others')))
        .data!;
    expect(offTarget, contains('Petto'));
    expect(offTarget, contains('Gambe'));
    expect(onTarget, isNot(contains('Petto')));

    // Le spalle non sono vuote ma sono poche: lo dice la frase del
    // mantenimento, che descrive invece di rimproverare.
    final below = tester
        .widget<Text>(find.byKey(const Key('weekly_volume_below_groups')))
        .data!;
    expect(below, startsWith('Spalle:'));
    expect(below, contains('perde terreno'));

    await disposeTree(tester);
  });

  testWidgets('quello che resta fuori dal conteggio è scritto', (tester) async {
    useTallWindow(tester);
    await seedTheWeek();

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    final note = tester
        .widget<Text>(find.byKey(const Key('weekly_volume_exclusions')))
        .data!;
    expect(note, contains('1 serie fra riscaldamento e defaticamento'));
    expect(note, contains('1 serie su righe senza gruppo muscolare'));

    await disposeTree(tester);
  });

  testWidgets('cambiare lente cambia la banda, non i numeri', (tester) async {
    useTallWindow(tester);
    await seedTheWeek();

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    // Senza obiettivo attivo l'app propone il mantenimento: otto serie di
    // bicipiti sono dentro la sua banda.
    expect(
      tester
          .widget<Text>(find.byKey(const Key('weekly_volume_lens_note')))
          .data,
      startsWith('Lente di partenza, non una tua scelta'),
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('weekly_volume_below_groups')))
          .data,
      isNot(contains('Bicipiti')),
    );

    await tester.tap(find.byKey(const Key('weekly_volume_intent_growth')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(find.byKey(const Key('weekly_volume_lens_note')))
          .data,
      startsWith('Lente scelta da te.'),
    );
    // Le serie sono le stesse, è il riferimento a essersi alzato.
    expect(
      tester.widget<Text>(find.byKey(const Key('weekly_volume_totals'))).data,
      '4 sessioni · 14 serie contate',
    );
    expect(
      tester
          .widget<Text>(find.byKey(const Key('weekly_volume_below_groups')))
          .data,
      contains('Bicipiti'),
    );

    await disposeTree(tester);
  });

  testWidgets('la freccia porta alla settimana prima e poi torna', (
    tester,
  ) async {
    useTallWindow(tester);
    await seedTheWeek();
    await seedSession(
      id: 'w-scorsa',
      startedAt: _dayOfWeek(DateTime.wednesday, weeksAgo: 1),
      exerciseName: 'Squat',
      muscleGroup: 'gambe',
      sets: 7,
    );

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    // Avanti è spento: la settimana prossima non ha serie da contare.
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('weekly_volume_next_week')))
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const Key('weekly_volume_previous_week')));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('weekly_volume_range'))).data,
      '27 luglio – 2 agosto',
    );
    expect(find.text('Settimana scorsa'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('weekly_volume_totals'))).data,
      '1 sessione · 7 serie contate',
    );

    await tester.tap(find.byKey(const Key('weekly_volume_next_week')));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('weekly_volume_range'))).data,
      '3 – 9 agosto',
    );

    await disposeTree(tester);
  });

  testWidgets('una settimana senza serie lo dice invece di mostrare zeri', (
    tester,
  ) async {
    useTallWindow(tester);
    await seedTheWeek();

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('weekly_volume_previous_week')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('weekly_volume_empty_week')), findsOneWidget);
    expect(find.byKey(const Key('weekly_volume_group_spalle')), findsNothing);

    await disposeTree(tester);
  });

  testWidgets('la banda è nello storico allenamenti, non in un file a parte', (
    tester,
  ) async {
    useTallWindow(tester);
    await seedTheWeek();

    await tester.pumpWidget(host(child: const _HistoryHost()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('weekly_volume_card')), findsOneWidget);

    await disposeTree(tester);
  });

  testWidgets('a caratteri ingranditi del 50% la card non si rompe', (
    tester,
  ) async {
    useTallWindow(tester);
    await seedTheWeek();

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
        child: host(),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('weekly_volume_card')), findsOneWidget);

    await disposeTree(tester);
  });

  testWidgets('al buio i grigi arrivano dal tema', (tester) async {
    useTallWindow(tester);
    await seedTheWeek();

    await tester.pumpWidget(host(theme: AppTheme.dark));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final note = tester.widget<Text>(
      find.byKey(const Key('weekly_volume_exclusions')),
    );
    expect(note.style?.color, AppAccents.dark.mutedInk);

    await disposeTree(tester);
  });
}

/// Lo storico intero, per verificare che la card sia davvero appesa lì.
class _HistoryHost extends StatelessWidget {
  const _HistoryHost();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(height: 2600, child: WorkoutHistoryScreen());
}
