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
import 'package:kal_tracker/features/exercises/presentation/exercise_detail_screen.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/routines/data/routine_repository.dart';
import 'package:kal_tracker/features/routines/domain/routine_draft.dart';

Widget _app(AppDatabase database, String exerciseId) => ProviderScope(
  overrides: [databaseProvider.overrideWithValue(database)],
  child: MaterialApp(
    theme: AppTheme.light,
    home: ExerciseDetailScreen(exerciseId: exerciseId),
  ),
);

void main() {
  late AppDatabase database;
  late ExerciseRepository exercises;
  late RoutineRepository routines;
  late String profileId;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
    exercises = ExerciseRepository(database);
    routines = RoutineRepository(database);
  });

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(database.close);
  }

  testWidgets('la scheda dice com\'è fatto l\'esercizio e dove lo usi', (
    tester,
  ) async {
    final squat = await exercises.createExercise(
      profileId: profileId,
      draft: const ExerciseDraft(
        name: 'Squat con bilanciere',
        muscleGroup: MuscleGroup.gambe,
        notes: 'Ginocchia in linea con le punte',
        defaultRestSec: 120,
      ),
    );
    await routines.saveRoutine(
      profileId: profileId,
      draft: RoutineDraft(
        name: 'Gambe del lunedì',
        warmup: const [],
        main: [
          DraftExercise(
            key: squat.id,
            exerciseRefId: squat.id,
            name: squat.name,
            muscleGroup: squat.muscleGroup,
            trackingMode: squat.trackingMode,
          ),
        ],
        finisher: const [],
        segments: const [],
      ),
    );

    await tester.pumpWidget(_app(database, squat.id));
    await tester.pumpAndSettle();

    expect(find.text('Squat con bilanciere'), findsWidgets);
    expect(find.text('Gambe'), findsOneWidget);
    expect(find.text('Recupero predefinito'), findsOneWidget);
    expect(find.text('120'), findsOneWidget);
    expect(find.text('Ginocchia in linea con le punte'), findsOneWidget);
    expect(find.text('Gambe del lunedì'), findsOneWidget);
    expect(find.text('Blocco esercizi'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('un esercizio senza schede lo dice e suggerisce cosa fare', (
    tester,
  ) async {
    final squat = await exercises.createExercise(
      profileId: profileId,
      draft: const ExerciseDraft(name: 'Squat', muscleGroup: MuscleGroup.gambe),
    );

    await tester.pumpWidget(_app(database, squat.id));
    await tester.pumpAndSettle();

    expect(find.textContaining('Nessuna scheda lo usa ancora'), findsOneWidget);
    // Senza recupero predefinito il valore è un trattino, non uno zero:
    // «0 secondi» sarebbe una prescrizione, non un'assenza.
    expect(find.text('—'), findsOneWidget);
    expect(find.text('Lo decide la scheda'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('un esercizio cancellato non lascia una schermata vuota', (
    tester,
  ) async {
    await tester.pumpWidget(_app(database, 'non-esiste'));
    await tester.pumpAndSettle();

    expect(find.text('Esercizio non trovato'), findsOneWidget);

    await disposeApp(tester);
  });
}
