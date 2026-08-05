import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/workouts/presentation/history/workout_detail_screen.dart';

import 'workout_history_fixtures.dart';

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

  Widget host(String workoutId) => ProviderScope(
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
      home: WorkoutDetailScreen(workoutId: workoutId),
    ),
  );

  /// Smonta l'albero e lascia scattare il timer con cui drift chiude le
  /// query rimaste in ascolto. Senza, il test finisce con «A Timer is still
  /// pending»: non è un difetto della schermata, è la pulizia del database.
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

  testWidgets('il dettaglio mostra blocchi, superserie, circuito e serie '
      'come li registrava Gym', (tester) async {
    useTallWindow(tester);
    final started = DateTime.utc(2026, 7, 25, 16);
    await seedWorkout(
      database,
      id: 'w-misto',
      profileId: 'marco',
      startedAt: started,
      endedAt: started.add(const Duration(minutes: 70)),
      finalDurationSeconds: 4200,
      routineExternalId: 'r-cancellata',
      routineName: 'Full body circuito',
      totalKcal: 380,
      mood: 4,
      rpe: 8,
      satisfaction: 4,
      feedbackNotes: 'Ultimo giro durissimo.',
      xpEarned: 120,
    );
    await seedWorkoutExercise(
      database,
      id: 'we-corsa',
      workoutId: 'w-misto',
      position: 0,
      name: 'Corsa sul posto',
      trackingMode: 'timeOnly',
      isWarmup: true,
    );
    await seedSet(
      database,
      id: 's-corsa',
      workoutExerciseId: 'we-corsa',
      position: 0,
      durationSec: 180,
    );
    await seedWorkoutExercise(
      database,
      id: 'we-panca',
      workoutId: 'w-misto',
      position: 1,
      name: 'Panca piana',
      restSeconds: 90,
    );
    await seedSet(
      database,
      id: 's-panca-0',
      workoutExerciseId: 'we-panca',
      position: 0,
      weightKg: 40,
      reps: 10,
      isWarmup: true,
    );
    await seedSet(
      database,
      id: 's-panca-1',
      workoutExerciseId: 'we-panca',
      position: 1,
      weightKg: 60,
      reps: 8,
      rpe: 8,
    );
    await seedSet(
      database,
      id: 's-panca-2',
      workoutExerciseId: 'we-panca',
      position: 2,
      weightKg: 60,
      reps: 6,
      completed: false,
    );
    await seedWorkoutExercise(
      database,
      id: 'we-croci',
      workoutId: 'w-misto',
      position: 2,
      name: 'Croci ai cavi',
      inSupersetWithPrevious: true,
    );
    await seedSet(
      database,
      id: 's-croci',
      workoutExerciseId: 'we-croci',
      position: 0,
      weightKg: 20,
      reps: 12,
    );
    await seedWorkoutExercise(
      database,
      id: 'we-burpees',
      workoutId: 'w-misto',
      position: 3,
      name: 'Burpees',
      trackingMode: 'timed',
      intervalSegmentIndex: 0,
    );
    await seedSet(
      database,
      id: 's-burpees',
      workoutExerciseId: 'we-burpees',
      position: 0,
      durationSec: 40,
    );
    await seedCircuitMarker(
      database,
      id: 'seg-0',
      workoutId: 'w-misto',
      segmentIndex: 0,
      completed: true,
    );
    await seedWorkoutExercise(
      database,
      id: 'we-stretch',
      workoutId: 'w-misto',
      position: 4,
      name: 'Stretch pettorali',
      trackingMode: 'timeOnly',
      isCooldown: true,
    );
    await seedSet(
      database,
      id: 's-stretch',
      workoutExerciseId: 'we-stretch',
      position: 0,
      durationSec: 60,
    );
    await seedPainPoint(
      database,
      id: 'pain-0',
      workoutId: 'w-misto',
      label: 'Spalla destra',
    );

    await tester.pumpWidget(host('w-misto'));
    await tester.pumpAndSettle();

    // Intestazione: nome storico della scheda cancellata e numeri.
    expect(find.byKey(const Key('workout_detail_header')), findsOneWidget);
    expect(find.text('Full body circuito'), findsOneWidget);
    expect(find.textContaining('Scheda non più in archivio'), findsOneWidget);
    expect(find.text('1h 10min'), findsOneWidget);

    // I blocchi, nell'ordine in cui Gym li registrava.
    expect(find.textContaining('Riscaldamento · 1 esercizio'), findsOneWidget);
    expect(find.textContaining('Allenamento · 2 esercizi'), findsOneWidget);
    expect(find.textContaining('Circuito · blocco 1'), findsOneWidget);
    expect(find.textContaining('Defaticamento · 1 esercizio'), findsOneWidget);

    // La superserie sta in una card sola e lo dice.
    expect(find.text('Superserie · 2 esercizi'), findsOneWidget);
    expect(find.text('Panca piana'), findsOneWidget);
    expect(find.text('Croci ai cavi'), findsOneWidget);

    // Il blocco a tempo porta il suo marcatore di completamento.
    expect(find.byKey(const Key('workout_segment_done_0')), findsOneWidget);

    // Le serie, con il formato di Gym.
    expect(find.text('60 kg × 8'), findsOneWidget);
    expect(find.text('20 kg × 12'), findsOneWidget);
    expect(find.text('3:00'), findsOneWidget);
    expect(find.text('RPE 8'), findsWidgets);

    // Il feedback di fine sessione.
    expect(find.byKey(const Key('workout_detail_feedback')), findsOneWidget);
    expect(find.byKey(const Key('workout_pain_Spalla destra')), findsOneWidget);
    expect(find.text('Ultimo giro durissimo.'), findsOneWidget);

    await disposeTree(tester);
  });

  testWidgets('la sessione registrata a posteriori spiega perché è vuota', (
    tester,
  ) async {
    useTallWindow(tester);
    final started = DateTime.utc(2026, 6, 10, 17);
    await seedWorkout(
      database,
      id: 'w-esterna',
      profileId: 'marco',
      startedAt: started,
      endedAt: started.add(const Duration(minutes: 45)),
      finalDurationSeconds: 45 * 60,
      routineName: 'Sessione esterna',
      notes: 'Corsa al parco con l’orologio.',
      totalKcal: 300,
    );

    await tester.pumpWidget(host('w-esterna'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('workout_detail_no_exercises')),
      findsOneWidget,
    );
    expect(find.textContaining('Non manca niente'), findsOneWidget);
    // Quello che Gym aveva salvato resta in evidenza.
    expect(find.text('45min'), findsOneWidget);
    expect(find.text('300'), findsOneWidget);
    expect(find.text('Corsa al parco con l’orologio.'), findsOneWidget);

    await disposeTree(tester);
  });

  testWidgets('la durata non attendibile è marcata anche nel dettaglio', (
    tester,
  ) async {
    useTallWindow(tester);
    final started = DateTime.utc(2026, 5, 1, 9);
    await seedWorkout(
      database,
      id: 'w-aperta',
      profileId: 'marco',
      startedAt: started,
      endedAt: started.add(const Duration(hours: 536)),
      durationSuspect: true,
      routineName: 'Giorno 2 schiena',
    );

    await tester.pumpWidget(host('w-aperta'));
    await tester.pumpAndSettle();

    // Il numero grezzo resta a schermo: 536 ore, non 24.
    expect(find.text('536h'), findsOneWidget);
    final note = tester
        .widget<Text>(find.byKey(const Key('workout_detail_suspect_note')))
        .data!;
    expect(note, contains('l\'app è rimasta aperta'));
    expect(note, contains('536 ore'));

    await disposeTree(tester);
  });

  testWidgets('una sessione che non esiste non è una schermata rotta', (
    tester,
  ) async {
    await tester.pumpWidget(host('non-esiste'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('workout_detail_missing')), findsOneWidget);

    await disposeTree(tester);
  });
}
