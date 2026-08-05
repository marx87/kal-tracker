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
import 'package:kal_tracker/features/routines/presentation/routines_screen.dart';

Widget _app(AppDatabase database) => ProviderScope(
  overrides: [databaseProvider.overrideWithValue(database)],
  child: MaterialApp(theme: AppTheme.light, home: const RoutinesScreen()),
);

void main() {
  late AppDatabase database;
  late RoutineRepository routines;
  late ExerciseRepository exercises;
  late String profileId;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
    routines = RoutineRepository(database);
    exercises = ExerciseRepository(database);
  });

  /// Smonta l'albero prima di chiudere il database: drift, annullando lo
  /// stream, lascia un timer a durata zero che il framework di test conta
  /// come errore.
  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(database.close);
  }

  Future<DraftExercise> seedExercise(String name) async {
    final exercise = await exercises.createExercise(
      profileId: profileId,
      draft: ExerciseDraft(name: name, muscleGroup: MuscleGroup.gambe),
    );
    return DraftExercise(
      key: exercise.id,
      exerciseRefId: exercise.id,
      name: exercise.name,
      muscleGroup: exercise.muscleGroup,
      trackingMode: exercise.trackingMode,
    );
  }

  testWidgets('senza schede spiega cos\'è una scheda e offre di crearne una', (
    tester,
  ) async {
    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('routines_empty_state')), findsOneWidget);
    expect(find.text('Crea la prima scheda'), findsOneWidget);
    expect(find.byKey(const Key('create_routine_button')), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('la riga di una scheda dice esercizi, durata e superserie', (
    tester,
  ) async {
    final squat = await seedExercise('Squat');
    final affondi = await seedExercise('Affondi');
    final id = await routines.saveRoutine(
      profileId: profileId,
      draft: RoutineDraft(
        name: 'Gambe pesanti',
        warmup: const [],
        main: [squat, affondi.copyWith(inSupersetWithPrevious: true)],
        finisher: const [],
        segments: const [],
      ),
    );

    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    expect(find.byKey(Key('routine_card_$id')), findsOneWidget);
    expect(find.text('Gambe pesanti'), findsOneWidget);
    expect(find.text('1 scheda pronta'), findsOneWidget);
    expect(find.textContaining('2 esercizi'), findsOneWidget);
    expect(find.text('1 superserie'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('un circuito si riconosce dalla pastiglia, non solo dal colore', (
    tester,
  ) async {
    final squat = await seedExercise('Squat');
    await routines.saveRoutine(
      profileId: profileId,
      draft: RoutineDraft(
        name: 'HIIT breve',
        isCircuit: true,
        rounds: 4,
        warmup: const [],
        main: [squat],
        finisher: const [],
        segments: const [],
      ),
    );

    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    expect(find.text('Circuito'), findsOneWidget);
    expect(find.textContaining('4 round'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('eliminare chiede conferma e la scheda sparisce dall\'elenco', (
    tester,
  ) async {
    final squat = await seedExercise('Squat');
    final id = await routines.saveRoutine(
      profileId: profileId,
      draft: RoutineDraft(
        name: 'Gambe pesanti',
        warmup: const [],
        main: [squat],
        finisher: const [],
        segments: const [],
      ),
    );

    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('routine_menu_$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Elimina'));
    await tester.pumpAndSettle();

    expect(find.text('Eliminare questa scheda?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm_delete_routine')));
    await tester.pumpAndSettle();

    expect(find.text('Gambe pesanti'), findsNothing);
    expect(find.byKey(const Key('routines_empty_state')), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets(
    'la ricerca restringe l\'elenco e lo dice quando non trova nulla',
    (tester) async {
      final squat = await seedExercise('Squat');
      for (final name in ['Push pesante', 'Pull leggero']) {
        await routines.saveRoutine(
          profileId: profileId,
          draft: RoutineDraft(
            name: name,
            warmup: const [],
            main: [squat],
            finisher: const [],
            segments: const [],
          ),
        );
      }

      await tester.pumpWidget(_app(database));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('routine_search_field')),
        'pull',
      );
      await tester.pumpAndSettle();
      expect(find.text('Pull leggero'), findsOneWidget);
      expect(find.text('Push pesante'), findsNothing);

      await tester.enterText(
        find.byKey(const Key('routine_search_field')),
        'zzz',
      );
      await tester.pumpAndSettle();
      expect(find.text('Nessuna scheda con questo nome'), findsOneWidget);

      await disposeApp(tester);
    },
  );
}
