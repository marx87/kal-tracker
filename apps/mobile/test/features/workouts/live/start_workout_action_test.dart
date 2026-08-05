import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/exercises/data/exercise_repository.dart';
import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/routines/data/routine_repository.dart';
import 'package:kal_tracker/features/routines/domain/routine_draft.dart';
import 'package:kal_tracker/features/workouts/data/drift_live_workout_repository.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';
import 'package:kal_tracker/features/workouts/presentation/live/start_workout_action.dart';

/// Il pulsante «Inizia» con il database vero sotto: è l'unico modo di
/// verificare che il secondo avvio diventi un messaggio con dentro
/// un'offerta, e non un'eccezione di vincolo.
void main() {
  late AppDatabase database;
  late String profileId;
  late RoutineRepository routines;
  late ExerciseRepository exercises;
  final opened = <String>[];

  setUp(() async {
    AppTime.initialize();
    opened.clear();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
    routines = RoutineRepository(database);
    exercises = ExerciseRepository(database);
  });

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(database.close);
  }

  Future<String> seedRoutine(String name) async {
    final squat = await exercises.createExercise(
      profileId: profileId,
      draft: const ExerciseDraft(name: 'Squat', muscleGroup: MuscleGroup.gambe),
    );
    return routines.saveRoutine(
      profileId: profileId,
      draft: RoutineDraft(
        name: name,
        warmup: const [],
        finisher: const [],
        segments: const [],
        main: [
          DraftExercise(
            key: 'k1',
            exerciseRefId: squat.id,
            name: squat.name,
            muscleGroup: squat.muscleGroup,
            trackingMode: squat.trackingMode,
          ),
        ],
      ),
    );
  }

  Widget app(String routineId, String name) => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(database)],
    child: MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(
        body: Center(
          child: StartRoutineButton(
            routineId: routineId,
            routineName: name,
            onOpenSession: opened.add,
          ),
        ),
      ),
    ),
  );

  testWidgets('il pulsante apre davvero una sessione e ci porta dentro', (
    tester,
  ) async {
    final routineId = await seedRoutine('Gambe pesanti');
    await tester.pumpWidget(app(routineId, 'Gambe pesanti'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('start_routine_$routineId')));
    await tester.pumpAndSettle();

    final open = await (database.select(
      database.workouts,
    )..where((row) => row.endedAt.isNull())).get();
    expect(open, hasLength(1));
    expect(open.single.routineNameSnapshot, 'Gambe pesanti');
    expect(opened, [open.single.id]);
    // Gli esercizi ci sono davvero: una sessione vuota sarebbe una schermata
    // aperta su niente.
    expect(
      await database.select(database.workoutExercises).get(),
      hasLength(1),
    );

    await disposeApp(tester);
  });

  testWidgets('con una sessione già aperta lo dice e offre di riprenderla', (
    tester,
  ) async {
    final routineId = await seedRoutine('Gambe pesanti');
    final repository = DriftLiveWorkoutRepository.forProfile(
      database,
      profileId,
    );
    final already = await repository.startWorkout(
      routineName: 'Di ieri sera',
      exercises: const [
        WorkoutExercise(
          exerciseId: 'libero',
          exerciseName: 'Sessione libera',
          sets: [WorkoutSet()],
        ),
      ],
    );

    await tester.pumpWidget(app(routineId, 'Gambe pesanti'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('start_routine_$routineId')));
    await tester.pumpAndSettle();

    // Nessuna seconda sessione, e nessuna eccezione a schermo.
    final open = await (database.select(
      database.workouts,
    )..where((row) => row.endedAt.isNull())).get();
    expect(open, hasLength(1));
    expect(open.single.id, already.id);
    expect(
      find.textContaining('Hai già un allenamento aperto'),
      findsOneWidget,
    );
    expect(opened, isEmpty);

    // «Riprendi» porta in quella che c'è, che è la cosa utile da fare.
    await tester.tap(find.text('Riprendi'));
    await tester.pumpAndSettle();
    expect(opened, [already.id]);

    await disposeApp(tester);
  });

  testWidgets('una scheda cancellata non apre una sessione vuota', (
    tester,
  ) async {
    final routineId = await seedRoutine('Gambe pesanti');
    await routines.deleteRoutine(routineId);

    await tester.pumpWidget(app(routineId, 'Gambe pesanti'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('start_routine_$routineId')));
    await tester.pumpAndSettle();

    expect(find.text('Questa scheda non esiste più.'), findsOneWidget);
    expect(await database.select(database.workouts).get(), isEmpty);
    expect(opened, isEmpty);

    await disposeApp(tester);
  });
}
