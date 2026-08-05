import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/features/workouts/data/drift_live_workout_repository.dart';
import 'package:kal_tracker/features/workouts/domain/exercise_kind.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';
import 'package:kal_tracker/features/workouts/presentation/live/live_workout_providers.dart';
import 'package:kal_tracker/features/workouts/presentation/live/live_workout_screen.dart';

import '../history/workout_history_fixtures.dart';

/// Il giro completo con SOTTO il database vero, non il finto.
///
/// Le suite della schermata e quella del repository, prese da sole, resterebbero
/// verdi anche se i due lati non si parlassero: la prima usa un repository
/// scritto a mano, la seconda non monta niente. Questo test è il punto in cui
/// «si può iniziare un allenamento» smette di essere una promessa.
///
/// NOTA SUI PUMP: la sessione ha un cronometro che batte ogni secondo, quindi
/// `pumpAndSettle` non tornerebbe mai. Si pompa a mano.
Future<void> _settle(WidgetTester tester, [int frames = 8]) async {
  for (var index = 0; index < frames; index++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

void main() {
  late AppDatabase database;
  late DriftLiveWorkoutRepository repository;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    await seedProfile(database);
    await seedExercise(
      database,
      id: 'squat',
      profileId: 'marco',
      name: 'Squat',
      muscleGroup: 'gambe',
    );
    repository = DriftLiveWorkoutRepository.forProfile(database, 'marco');
  });

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(database.close);
  }

  testWidgets('si spunta una serie e finisce nel database', (tester) async {
    final started = await repository.startWorkout(
      routineName: 'Gambe pesanti',
      exercises: const [
        WorkoutExercise(
          exerciseId: 'squat',
          exerciseName: 'Squat',
          muscleGroup: MuscleGroup.gambe,
          restSeconds: 90,
          sets: [WorkoutSet(weightKg: 100, reps: 5)],
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          liveWorkoutRepositoryProvider.overrideWithValue(repository),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: LiveWorkoutScreen(workoutId: started.id),
        ),
      ),
    );
    await _settle(tester);

    expect(find.text('Gambe pesanti'), findsOneWidget);
    await tester.tap(find.byKey(const Key('live_workout_complete_current')));
    await _settle(tester);

    final saved = await database.select(database.workoutSets).getSingle();
    expect(saved.completed, isTrue);
    expect(saved.weightKg, 100);

    await disposeApp(tester);
  });

  testWidgets('l\'app chiusa a metà allenamento si riapre dov\'era', (
    tester,
  ) async {
    final unOraFa = DriftLiveWorkoutRepository.forProfile(
      database,
      'marco',
      now: () => DateTime.now().subtract(const Duration(hours: 1)),
    );
    final started = await unOraFa.startWorkout(
      routineName: 'Gambe pesanti',
      exercises: const [
        WorkoutExercise(
          exerciseId: 'squat',
          exerciseName: 'Squat',
          muscleGroup: MuscleGroup.gambe,
          restSeconds: 90,
          sets: [
            WorkoutSet(weightKg: 100, reps: 5, completed: true),
            WorkoutSet(weightKg: 100, reps: 5),
          ],
        ),
      ],
    );
    // Uscita con «pausa» dieci minuti fa, e un blocco a tempo lasciato a metà.
    await unOraFa.saveWorkout(
      started.copyWith(
        pausedAt: DateTime.now().subtract(const Duration(minutes: 10)),
        accumulatedPauseSeconds: 120,
      ),
    );
    await unOraFa.updateResumeState(
      started.id,
      resumePath: '/workout/${started.id}/phase/segment?seg=0',
      circuitCheckpoint: {'round': 2},
    );

    // È il gesto vero: l'app riparte e chiede se c'è una sessione aperta.
    final open = await repository.activeWorkout();
    expect(open, isNotNull);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          liveWorkoutRepositoryProvider.overrideWithValue(repository),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: LiveWorkoutScreen(workoutId: open!.id),
        ),
      ),
    );
    await _settle(tester);

    expect(find.text('Gambe pesanti'), findsOneWidget);
    expect(find.text('1 serie su 2'), findsOneWidget);
    expect(find.text('Blocco a tempo lasciato a metà'), findsOneWidget);

    // La pausa si chiude sommandola: senza, una sessione ripresa il giorno
    // dopo risulterebbe durata quindici ore, e le calorie con lei.
    final row = await database.select(database.workouts).getSingle();
    expect(row.pausedAt, isNull);
    expect(row.accumulatedPauseSeconds, closeTo(120 + 600, 30));
    // Il checkpoint del circuito è ancora lì: il salvataggio della ripresa non
    // lo ha cancellato.
    expect(row.circuitCheckpointJson, contains('round'));

    await disposeApp(tester);
  });

  testWidgets('chiudendo, la sessione esce dalle aperte con le sue calorie', (
    tester,
  ) async {
    await database
        .into(database.bodyMeasurements)
        .insert(
          BodyMeasurementsCompanion.insert(
            id: 'm1',
            profileId: 'marco',
            weightKg: 95.8,
            measuredAt: DateTime.utc(2026, 8, 5),
            createdAt: DateTime.utc(2026, 8, 5),
            updatedAt: DateTime.utc(2026, 8, 5),
          ),
        );
    // La sessione è cominciata quaranta minuti fa: le calorie si calcolano sul
    // tempo, e una sessione lunga zero minuti ne vale onestamente zero.
    final quarantaMinutiFa = DriftLiveWorkoutRepository.forProfile(
      database,
      'marco',
      now: () => DateTime.now().subtract(const Duration(minutes: 40)),
    );
    final started = await quarantaMinutiFa.startWorkout(
      routineName: 'Gambe pesanti',
      exercises: const [
        WorkoutExercise(
          exerciseId: 'squat',
          exerciseName: 'Squat',
          muscleGroup: MuscleGroup.gambe,
          sets: [WorkoutSet(weightKg: 100, reps: 5, completed: true)],
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          liveWorkoutRepositoryProvider.overrideWithValue(repository),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: LiveWorkoutScreen(workoutId: started.id),
        ),
      ),
    );
    await _settle(tester);

    // Il peso delle calorie è quello della pesata vera, e la schermata lo dice.
    expect(find.textContaining('95.8 kg'), findsOneWidget);

    await tester.tap(find.byKey(const Key('live_workout_finish')));
    await _settle(tester);
    // Il defaticamento è una proposta, non un obbligo.
    await tester.tap(find.byKey(const Key('cooldown_skip')));
    await _settle(tester);

    expect(await repository.activeWorkout(), isNull);
    final row = await database.select(database.workouts).getSingle();
    expect(row.endedAt, isNotNull);
    expect(row.finalDurationSeconds, closeTo(40 * 60, 60));
    // 6.0 MET (gambe) × 95,8 kg × 40/60 h ≈ 383 kcal: il peso è quello della
    // pesata vera, non un valore congelato nel profilo.
    expect(row.totalKcal, closeTo(383, 25));

    await disposeApp(tester);
  });
}
