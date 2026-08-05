import 'package:drift/drift.dart' show Value;
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
import 'package:kal_tracker/features/exercises/presentation/exercises_screen.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

Widget _app(AppDatabase database) => ProviderScope(
  overrides: [databaseProvider.overrideWithValue(database)],
  child: MaterialApp(theme: AppTheme.light, home: const ExercisesScreen()),
);

void main() {
  late AppDatabase database;
  late ExerciseRepository repository;
  late String profileId;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
    repository = ExerciseRepository(database);
  });

  /// Smonta l'albero prima di chiudere il database: drift, quando lo stream
  /// viene annullato, lascia un timer a durata zero, e il test framework
  /// considera un timer pendente un errore.
  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(database.close);
  }

  Future<Exercise> seed(
    String name, {
    MuscleGroup group = MuscleGroup.petto,
    ExerciseTrackingMode mode = ExerciseTrackingMode.weightReps,
  }) => repository.createExercise(
    profileId: profileId,
    draft: ExerciseDraft(name: name, muscleGroup: group, trackingMode: mode),
  );

  testWidgets('la libreria vuota dice cosa fare, non «nessun dato»', (
    tester,
  ) async {
    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('exercises_empty_state')), findsOneWidget);
    expect(find.textContaining('Crea il primo esercizio'), findsOneWidget);
    expect(find.byKey(const Key('create_exercise_button')), findsOneWidget);
    await disposeApp(tester);
  });

  testWidgets('raggruppa per gruppo muscolare e la ricerca filtra', (
    tester,
  ) async {
    await seed('Panca piana');
    await seed('Squat', group: MuscleGroup.gambe);
    await seed('Affondi bulgari', group: MuscleGroup.gambe);

    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    // «Gambe» è anche l'etichetta di un filtro: qui interessa l'intestazione
    // di sezione, quindi si cerca dentro la lista.
    Finder inList(String text) => find.descendant(
      of: find.byKey(const Key('exercises_list')),
      matching: find.text(text),
    );
    expect(inList('Gambe'), findsOneWidget);
    expect(inList('Petto'), findsOneWidget);
    expect(
      inList('2 esercizi'),
      findsOneWidget,
      reason: 'il conteggio di Gambe',
    );
    expect(
      inList('1 esercizio'),
      findsOneWidget,
      reason: 'il conteggio di Petto',
    );
    expect(find.text('Affondi bulgari'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('exercise_search_field')),
      'squ',
    );
    await tester.pumpAndSettle();

    expect(find.text('Squat'), findsOneWidget);
    expect(find.text('Affondi bulgari'), findsNothing);
    expect(inList('Petto'), findsNothing, reason: 'la sezione vuota sparisce');

    await tester.enterText(
      find.byKey(const Key('exercise_search_field')),
      'panc',
    );
    await tester.pumpAndSettle();

    expect(find.text('Panca piana'), findsOneWidget);
    expect(find.text('Squat'), findsNothing);
    await disposeApp(tester);
  });

  testWidgets('il filtro per origine separa i miei dai base', (tester) async {
    await seed('Affondi bulgari', group: MuscleGroup.gambe);
    final now = AppTime.nowUtc();
    await database
        .into(database.exercises)
        .insert(
          ExercisesCompanion.insert(
            id: 'base-squat',
            profileId: profileId,
            name: 'Squat',
            muscleGroup: 'gambe',
            trackingMode: 'weightReps',
            isPreset: const Value(true),
            createdAt: now,
            updatedAt: now,
          ),
        );

    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();
    expect(find.text('BASE'), findsOneWidget);
    expect(find.text('MIO'), findsOneWidget);

    await tester.tap(find.byKey(const Key('exercise_origin_mine')));
    await tester.pumpAndSettle();

    expect(find.text('Affondi bulgari'), findsOneWidget);
    expect(find.text('Squat'), findsNothing);
    await disposeApp(tester);
  });

  testWidgets('crea un esercizio dal foglio e lo scrive in libreria', (
    tester,
  ) async {
    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('create_exercise_button')));
    await tester.pumpAndSettle();

    expect(find.text('Nuovo esercizio'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('exercise_name_field')),
      'Rematore con bilanciere',
    );
    await tester.tap(find.byKey(const Key('exercise_group_schiena')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('exercise_mode_bodyweightReps')));
    await tester.pumpAndSettle();

    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    final save = find.byKey(const Key('save_exercise_button'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    final rows = await database.select(database.exercises).get();
    expect(rows, hasLength(1));
    expect(rows.single.name, 'Rematore con bilanciere');
    expect(rows.single.muscleGroup, 'schiena');
    expect(rows.single.trackingMode, 'bodyweightReps');
    expect(find.text('Rematore con bilanciere'), findsWidgets);
    await disposeApp(tester);
  });

  testWidgets('senza nome il foglio non salva e lo dice', (tester) async {
    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('create_exercise_button')));
    await tester.pumpAndSettle();
    final save = find.byKey(const Key('save_exercise_button'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(find.text('Serve un nome.'), findsOneWidget);
    expect(await database.select(database.exercises).get(), isEmpty);
    await disposeApp(tester);
  });

  testWidgets('eliminare chiede conferma e poi lo toglie dalla lista', (
    tester,
  ) async {
    final panca = await seed('Panca piana');

    await tester.pumpWidget(_app(database));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('exercise_menu_${panca.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Elimina'));
    await tester.pumpAndSettle();

    expect(find.text('Eliminare questo esercizio?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm_delete_exercise')));
    await tester.pumpAndSettle();

    expect(find.text('Panca piana'), findsNothing);
    final row = await (database.select(
      database.exercises,
    )..where((table) => table.id.equals(panca.id))).getSingle();
    expect(row.deletedAt, isNotNull);
    await disposeApp(tester);
  });
}
