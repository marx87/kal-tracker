import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/workouts/presentation/history/workout_history_screen.dart';

import 'workout_history_fixtures.dart';

void main() {
  late AppDatabase database;
  late DateTime now;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    now = AppTime.nowUtc();
    await seedProfile(database);
  });

  tearDown(() async {
    await database.close();
  });

  /// La schermata non è ancora nel router: si monta da sola, con lo stesso
  /// tema e le stesse localizzazioni dell'app (i nomi dei mesi italiani
  /// arrivano da lì, non da un'inizializzazione a parte).
  Widget host({ThemeData? theme}) => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(database)],
    child: MaterialApp(
      theme: theme ?? AppTheme.light,
      locale: const Locale('it'),
      supportedLocales: const [Locale('it')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const WorkoutHistoryScreen(),
    ),
  );

  /// Smonta l'albero e lascia scattare il timer con cui drift chiude le
  /// query rimaste in ascolto. Senza, il test finisce con «A Timer is still
  /// pending»: non è un difetto della schermata, è la pulizia del database.
  Future<void> disposeTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  /// Una finestra alta: la lista costruisce solo i figli visibili, e senza
  /// spazio metà delle asserzioni cercherebbero widget mai nati.
  void useTallWindow(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> seedThreeSessions() async {
    await seedRoutine(database, id: 'r-live', profileId: 'marco');

    // Sessione normale, due giorni fa.
    final recent = now.subtract(const Duration(days: 2));
    await seedWorkout(
      database,
      id: 'w-recente',
      profileId: 'marco',
      startedAt: recent,
      endedAt: recent.add(const Duration(minutes: 62)),
      finalDurationSeconds: 3600,
      routineId: 'r-live',
      routineName: 'Giorno 1 petto',
      totalKcal: 420,
      mood: 4,
      rpe: 7,
      satisfaction: 5,
    );
    await seedWorkoutExercise(
      database,
      id: 'we-panca',
      workoutId: 'w-recente',
      position: 0,
      name: 'Panca piana',
    );
    await seedSet(
      database,
      id: 's-panca',
      workoutExerciseId: 'we-panca',
      position: 0,
      weightKg: 60,
      reps: 8,
    );

    // Sessione dimenticata aperta, venti giorni fa.
    final forgotten = now.subtract(const Duration(days: 20));
    await seedWorkout(
      database,
      id: 'w-aperta',
      profileId: 'marco',
      startedAt: forgotten,
      endedAt: forgotten.add(const Duration(hours: 300)),
      durationSuspect: true,
      routineName: 'Giorno 2 schiena',
    );
    await seedWorkoutExercise(
      database,
      id: 'we-rematore',
      workoutId: 'w-aperta',
      position: 0,
      name: 'Rematore',
    );
    await seedSet(
      database,
      id: 's-rematore',
      workoutExerciseId: 'we-rematore',
      position: 0,
      weightKg: 50,
      reps: 10,
    );

    // Sessione registrata a posteriori, con la scheda ormai cancellata.
    final manual = now.subtract(const Duration(days: 5));
    await seedWorkout(
      database,
      id: 'w-esterna',
      profileId: 'marco',
      startedAt: manual,
      endedAt: manual.add(const Duration(minutes: 45)),
      finalDurationSeconds: 45 * 60,
      routineExternalId: 'r-cancellata',
      routineName: 'Giorno 3 spalle (vecchia)',
      notes: 'Sessione manuale (registrata a posteriori)',
      totalKcal: 300,
    );
  }

  testWidgets('la lista mostra le sessioni con i loro numeri e non nasconde '
      'i tre casi storti', (tester) async {
    useTallWindow(tester);
    await seedThreeSessions();

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('workout_card_w-recente')), findsOneWidget);
    expect(find.byKey(const Key('workout_card_w-aperta')), findsOneWidget);
    expect(find.byKey(const Key('workout_card_w-esterna')), findsOneWidget);

    // La sessione normale porta i suoi numeri.
    expect(find.text('Giorno 1 petto'), findsOneWidget);
    expect(find.text('1h'), findsWidgets);
    expect(find.text('420 kcal'), findsOneWidget);
    expect(find.text('480 kg'), findsOneWidget);

    // La durata non attendibile è marcata e spiegata, non corretta.
    expect(
      find.byKey(const Key('workout_suspect_chip_w-aperta')),
      findsOneWidget,
    );
    final note = tester
        .widget<Text>(find.byKey(const Key('workout_suspect_note_w-aperta')))
        .data!;
    expect(note, startsWith('Durata non attendibile: l\'app è rimasta aperta'));
    expect(note, contains('300 ore'));

    // La scheda cancellata lascia il nome storico, non un errore.
    expect(find.text('Giorno 3 spalle (vecchia)'), findsOneWidget);
    expect(find.textContaining('Scheda non più in archivio'), findsOneWidget);

    // La sessione senza esercizi ha una forma sua, non una lista vuota.
    expect(find.textContaining('Registrata a posteriori'), findsOneWidget);

    // Il totale del tempo dichiara che cosa ha lasciato fuori.
    expect(find.byKey(const Key('workout_total_time_note')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('workout_total_time_note')))
          .data,
      contains('Una sessione è fuori dal totale'),
    );

    await disposeTree(tester);
  });

  testWidgets('cambiare periodo restringe la lista', (tester) async {
    useTallWindow(tester);
    await seedThreeSessions();

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('workout_card_w-aperta')), findsOneWidget);

    await tester.tap(find.byKey(const Key('workout_period_week')));
    await tester.pumpAndSettle();

    // Due e cinque giorni fa restano dentro la settimana.
    expect(find.byKey(const Key('workout_card_w-recente')), findsOneWidget);
    expect(find.byKey(const Key('workout_card_w-esterna')), findsOneWidget);
    // Venti giorni fa no, e con lei sparisce la nota sul tempo parziale:
    // era l'unica sessione con la durata non attendibile.
    expect(find.byKey(const Key('workout_card_w-aperta')), findsNothing);
    expect(find.byKey(const Key('workout_total_time_note')), findsNothing);

    await disposeTree(tester);
  });

  testWidgets('toccare una sessione apre il dettaglio', (tester) async {
    useTallWindow(tester);
    await seedThreeSessions();

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('workout_card_w-recente')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('workout_detail_header')), findsOneWidget);
    expect(find.text('Panca piana'), findsOneWidget);

    await disposeTree(tester);
  });

  testWidgets('a caratteri ingranditi del 50% la lista non si rompe', (
    tester,
  ) async {
    useTallWindow(tester);
    await seedThreeSessions();

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
        child: host(),
      ),
    );
    await tester.pumpAndSettle();

    // Un overflow di layout in un test è un'eccezione: se resta nulla, il
    // testo grande ci sta davvero.
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('workout_card_w-recente')), findsOneWidget);
    expect(find.byKey(const Key('workout_totals_card')), findsOneWidget);

    await disposeTree(tester);
  });

  testWidgets('la stessa lista si veste di notte senza toccare il codice', (
    tester,
  ) async {
    useTallWindow(tester);
    await seedThreeSessions();

    await tester.pumpWidget(host(theme: AppTheme.dark));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('workout_card_w-recente')), findsOneWidget);

    // Il grigio dei testi secondari arriva dal tema, non da una costante
    // chiara scritta a mano: al buio cambia da solo.
    final note = tester.widget<Text>(
      find.byKey(const Key('workout_suspect_note_w-aperta')),
    );
    expect(note.style?.color, AppAccents.dark.mutedInk);

    await disposeTree(tester);
  });

  testWidgets('senza sessioni la schermata spiega che cosa arriverà qui', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('workout_history_empty')), findsOneWidget);
    expect(find.byKey(const Key('workout_history_list')), findsNothing);

    await disposeTree(tester);
  });
}
