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
import 'package:kal_tracker/features/routines/domain/routine_models.dart';
import 'package:kal_tracker/features/routines/presentation/routine_editor_screen.dart';

import '../../workouts/history/workout_history_fixtures.dart' as fixtures;

/// L'editor si apre come nell'app, spinto sopra un'altra schermata: così il
/// salvataggio può tornare indietro invece di svuotare l'albero.
Widget _app(AppDatabase database, {String? routineId}) => ProviderScope(
  overrides: [databaseProvider.overrideWithValue(database)],
  child: MaterialApp(
    theme: AppTheme.light,
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            key: const Key('open_editor'),
            onPressed: () => openRoutineEditor(context, routineId: routineId),
            child: const Text('Apri'),
          ),
        ),
      ),
    ),
  ),
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

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await tester.runAsync(database.close);
  }

  Future<DraftExercise> seedExercise(
    String name, {
    MuscleGroup group = MuscleGroup.gambe,
    ExercisePrescription prescription = ExercisePrescription.empty,
  }) async {
    final exercise = await exercises.createExercise(
      profileId: profileId,
      draft: ExerciseDraft(name: name, muscleGroup: group),
    );
    return DraftExercise(
      key: exercise.id,
      exerciseRefId: exercise.id,
      name: exercise.name,
      muscleGroup: exercise.muscleGroup,
      trackingMode: exercise.trackingMode,
      prescription: prescription,
    );
  }

  Future<void> openEditor(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('open_editor')));
    await tester.pumpAndSettle();
  }

  /// Porta un elemento in vista: la lista dell'editor è più alta dello
  /// schermo e i figli fuori campo non esistono nell'albero.
  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    await tester.dragUntilVisible(
      target,
      find.byKey(const Key('routine_editor_list')),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
  }

  Future<List<LocalRoutineExercise>> mainRows() async {
    final rows = await (database.select(
      database.routineExercises,
    )..where((row) => row.block.equals('main'))).get();
    return rows..sort((a, b) => a.position.compareTo(b.position));
  }

  testWidgets(
    'unisce due esercizi in superserie e la salva sulla riga giusta',
    (tester) async {
      final squat = await seedExercise('Squat');
      final affondi = await seedExercise('Affondi');
      final stacchi = await seedExercise('Stacchi');
      final id = await routines.saveRoutine(
        profileId: profileId,
        draft: RoutineDraft(
          name: 'Gambe',
          warmup: const [],
          main: [squat, affondi, stacchi],
          finisher: const [],
          segments: const [],
        ),
      );

      await tester.pumpWidget(_app(database, routineId: id));
      await openEditor(tester);

      expect(find.text('Modifica scheda'), findsOneWidget);
      await scrollTo(tester, find.byKey(const Key('merge_block_0')));
      await tester.tap(find.byKey(const Key('merge_block_0')));
      await tester.pumpAndSettle();

      expect(find.text('Superserie A · 2 alternati'), findsOneWidget);
      expect(find.text('A1'), findsOneWidget);
      expect(find.text('A2'), findsOneWidget);

      await scrollTo(tester, find.byKey(const Key('save_routine_button')));
      await tester.tap(find.byKey(const Key('save_routine_button')));
      await tester.pumpAndSettle();

      final rows = await mainRows();
      expect(rows.map((row) => row.exerciseNameSnapshot), [
        'Squat',
        'Affondi',
        'Stacchi',
      ]);
      expect(rows[0].inSupersetWithPrevious, isFalse);
      expect(rows[1].inSupersetWithPrevious, isTrue);
      expect(rows[2].inSupersetWithPrevious, isFalse);

      await disposeApp(tester);
    },
  );

  testWidgets('la prescrizione si scrive dal foglio e finisce nel database', (
    tester,
  ) async {
    final squat = await seedExercise('Squat');
    final id = await routines.saveRoutine(
      profileId: profileId,
      draft: RoutineDraft(
        name: 'Gambe',
        warmup: const [],
        main: [squat],
        finisher: const [],
        segments: const [],
      ),
    );

    await tester.pumpWidget(_app(database, routineId: id));
    await openEditor(tester);

    // Le chiavi delle righe caricate sono «main-0», «main-1»…: stabili,
    // perché nascono dall'ordine con cui la scheda è stata letta.
    final chip = find.byKey(const Key('prescription_main-0'));
    await scrollTo(tester, chip);
    expect(
      find.textContaining('(predefinito)'),
      findsOneWidget,
      reason: 'senza prescrizione si vedono i valori proposti',
    );

    await tester.tap(chip);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('prescription_sets_field')),
      '5',
    );
    await tester.enterText(
      find.byKey(const Key('prescription_work_field')),
      '12',
    );
    await tester.enterText(
      find.byKey(const Key('prescription_rest_field')),
      '60',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('prescription_save_button')));
    await tester.pumpAndSettle();

    expect(find.text('5×12 · rec 60″'), findsOneWidget);

    await scrollTo(tester, find.byKey(const Key('save_routine_button')));
    await tester.tap(find.byKey(const Key('save_routine_button')));
    await tester.pumpAndSettle();

    final row = (await mainRows()).single;
    expect(row.prescSets, 5);
    expect(row.prescReps, 12);
    expect(row.prescRestSec, 60);
    expect(row.prescDurationSec, isNull);

    await disposeApp(tester);
  });

  testWidgets(
    'l\'intervallo si scrive dal foglio e finisce sulle due colonne',
    (tester) async {
      final squat = await seedExercise('Squat');
      final id = await routines.saveRoutine(
        profileId: profileId,
        draft: RoutineDraft(
          name: 'Gambe',
          warmup: const [],
          main: [squat],
          finisher: const [],
          segments: const [],
        ),
      );

      await tester.pumpWidget(_app(database, routineId: id));
      await openEditor(tester);

      final chip = find.byKey(const Key('prescription_main-0'));
      await scrollTo(tester, chip);
      await tester.tap(chip);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('prescription_work_field')),
        '8',
      );
      await tester.pumpAndSettle();
      // Il tetto non si scrive a mano: la progressione lo propone, e allarga
      // solo verso l'alto (8 diventa 8-10, mai 6-10).
      await tester.tap(
        find.byKey(const Key('prescription_suggest_range_button')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('prescription_reps_max_field')),
        '12',
      );
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('prescription_save_button')));
      await tester.pumpAndSettle();

      expect(find.text('3×8-12 · rec predefinito'), findsOneWidget);

      await scrollTo(tester, find.byKey(const Key('save_routine_button')));
      await tester.tap(find.byKey(const Key('save_routine_button')));
      await tester.pumpAndSettle();

      final row = (await mainRows()).single;
      expect(row.prescRepsMin, 8);
      expect(row.prescRepsMax, 12);
      expect(row.prescReps, 8, reason: 'la sessione riparte dal fondo');

      await disposeApp(tester);
    },
  );

  testWidgets('un tetto sotto il fondo non si applica e lo dice', (
    tester,
  ) async {
    final squat = await seedExercise('Squat');
    final id = await routines.saveRoutine(
      profileId: profileId,
      draft: RoutineDraft(
        name: 'Gambe',
        warmup: const [],
        main: [squat],
        finisher: const [],
        segments: const [],
      ),
    );

    await tester.pumpWidget(_app(database, routineId: id));
    await openEditor(tester);

    final chip = find.byKey(const Key('prescription_main-0'));
    await scrollTo(tester, chip);
    await tester.tap(chip);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('prescription_work_field')),
      '12',
    );
    await tester.enterText(
      find.byKey(const Key('prescription_reps_max_field')),
      '8',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('prescription_save_button')));
    await tester.pumpAndSettle();

    expect(find.textContaining('8-12, non 12-8'), findsOneWidget);
    expect(
      find.byKey(const Key('prescription_sheet')),
      findsOneWidget,
      reason: 'il foglio resta aperto invece di salvare mezza banda',
    );

    await disposeApp(tester);
  });

  testWidgets('con l\'intervallo pieno la scheda propone il gradino', (
    tester,
  ) async {
    final panca = await seedExercise(
      'Panca piana con manubri',
      group: MuscleGroup.petto,
      prescription: const ExercisePrescription(
        sets: 3,
        reps: 8,
        repsMin: 8,
        repsMax: 12,
      ),
    );
    final id = await routines.saveRoutine(
      profileId: profileId,
      draft: RoutineDraft(
        name: 'Push',
        warmup: const [],
        main: [panca],
        finisher: const [],
        segments: const [],
      ),
    );

    // Tre serie in cima all'intervallo, stesso carico: è il caso in cui la
    // doppia progressione dice di salire.
    await fixtures.seedWorkout(
      database,
      id: 'seduta',
      profileId: profileId,
      startedAt: DateTime.utc(2026, 8, 1, 18),
      endedAt: DateTime.utc(2026, 8, 1, 19),
    );
    await fixtures.seedWorkoutExercise(
      database,
      id: 'seduta-panca',
      workoutId: 'seduta',
      position: 0,
      name: 'Panca piana con manubri',
      exerciseRefId: panca.exerciseRefId,
      exerciseId: panca.exerciseRefId,
    );
    for (var index = 0; index < 3; index++) {
      await fixtures.seedSet(
        database,
        id: 'seduta-set-$index',
        workoutExerciseId: 'seduta-panca',
        position: index,
        weightKg: 18,
        reps: 12,
      );
    }

    await tester.pumpWidget(_app(database, routineId: id));
    await openEditor(tester);

    final proposal = find.byKey(Key('progression_main-0'));
    await scrollTo(tester, proposal);
    expect(find.textContaining('prova 20 kg'), findsOneWidget);
    expect(
      find.text('Ultima seduta a 18 kg, gradino +2 kg.'),
      findsOneWidget,
      reason:
          'da dove si parte e quanto vale il gradino, che la frase non '
          'dice',
    );
    // Nessuna scrittura: il carico non sta sulla scheda, sta nella seduta.
    expect((await mainRows()).single.prescReps, 8);

    await disposeApp(tester);
  });

  testWidgets('senza intervallo la scheda ne propone uno, e lo scrive solo '
      'se glielo si dice', (tester) async {
    final squat = await seedExercise(
      'Squat con bilanciere',
      prescription: const ExercisePrescription(sets: 4, reps: 10),
    );
    final id = await routines.saveRoutine(
      profileId: profileId,
      draft: RoutineDraft(
        name: 'Gambe',
        warmup: const [],
        main: [squat],
        finisher: const [],
        segments: const [],
      ),
    );

    await tester.pumpWidget(_app(database, routineId: id));
    await openEditor(tester);

    final accept = find.byKey(const Key('accept_range_main-0'));
    await scrollTo(tester, accept);
    expect(find.textContaining('numero fisso di ripetizioni'), findsOneWidget);
    expect(find.text('Passa a 10-12'), findsOneWidget);

    await tester.tap(accept);
    await tester.pumpAndSettle();

    expect(
      (await mainRows()).single.prescRepsMax,
      isNull,
      reason: 'la proposta accettata resta in bozza finché non si salva',
    );
    // La prescrizione sta più in alto nella lista: si risale a leggerla, come
    // farebbe Marco dopo aver accettato.
    await tester.drag(
      find.byKey(const Key('routine_editor_list')),
      const Offset(0, 800),
    );
    await tester.pumpAndSettle();
    expect(find.text('4×10-12 · rec predefinito'), findsOneWidget);

    // «Salva la scheda per confermarlo» galleggia sopra il pulsante Salva:
    // si aspetta che se ne vada, come farebbe una persona.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const Key('save_routine_button')));
    await tester.tap(find.byKey(const Key('save_routine_button')));
    await tester.pumpAndSettle();

    final row = (await mainRows()).single;
    expect(row.prescRepsMin, 10);
    expect(row.prescRepsMax, 12);

    await disposeApp(tester);
  });

  testWidgets('crea una scheda nuova scegliendo gli esercizi dal selettore', (
    tester,
  ) async {
    await seedExercise('Squat');
    await seedExercise('Affondi');

    await tester.pumpWidget(_app(database));
    await openEditor(tester);

    expect(find.text('Nuova scheda'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('routine_name_field')),
      'Gambe del lunedì',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();

    await scrollTo(tester, find.byKey(const Key('add_main_button')));
    await tester.tap(find.byKey(const Key('add_main_button')));
    await tester.pumpAndSettle();

    // Il pulsante di conferma resta spento finché non si sceglie qualcosa.
    final confirm = find.byKey(const Key('picker_confirm_button'));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.tap(find.textContaining('Squat'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Affondi'));
    await tester.pumpAndSettle();
    expect(find.text('Aggiungi 2'), findsOneWidget);
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(find.text('Squat'), findsOneWidget);
    expect(find.text('Affondi'), findsOneWidget);

    await scrollTo(tester, find.byKey(const Key('save_routine_button')));
    await tester.tap(find.byKey(const Key('save_routine_button')));
    await tester.pumpAndSettle();

    final saved = await routines.watchRoutines(profileId).first;
    expect(saved.single.name, 'Gambe del lunedì');
    expect(saved.single.exerciseCount, 2);
    expect((await mainRows()).map((row) => row.exerciseNameSnapshot), [
      'Squat',
      'Affondi',
    ]);

    await disposeApp(tester);
  });

  testWidgets('senza nome non salva e lo dice invece di non fare niente', (
    tester,
  ) async {
    await tester.pumpWidget(_app(database));
    await openEditor(tester);

    await scrollTo(tester, find.byKey(const Key('save_routine_button')));
    await tester.tap(find.byKey(const Key('save_routine_button')));
    await tester.pumpAndSettle();

    // L'errore sugli esercizi sta accanto al pulsante, quello sul nome è in
    // cima: si risale per verificarlo, come farebbe Marco.
    expect(find.textContaining('almeno uno'), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('routine_editor_list')),
      const Offset(0, 800),
    );
    await tester.pumpAndSettle();
    expect(find.text('Serve un nome.'), findsOneWidget);
    expect(await database.select(database.routines).get(), isEmpty);

    await disposeApp(tester);
  });

  testWidgets('un blocco a tempo copre esercizi consecutivi e si salva', (
    tester,
  ) async {
    final squat = await seedExercise('Squat');
    final affondi = await seedExercise('Affondi');
    final stacchi = await seedExercise('Stacchi');
    final id = await routines.saveRoutine(
      profileId: profileId,
      draft: RoutineDraft(
        name: 'Gambe',
        warmup: const [],
        main: [squat, affondi, stacchi],
        finisher: const [],
        segments: const [],
      ),
    );

    await tester.pumpWidget(_app(database, routineId: id));
    await openEditor(tester);

    await scrollTo(tester, find.byKey(const Key('add_segment_button')));
    await tester.tap(find.byKey(const Key('add_segment_button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('segment_end_field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2. Affondi').last);
    await tester.pumpAndSettle();
    expect(find.text('2 esercizi consecutivi a tempo.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('segment_work_field')), '45');
    await tester.enterText(find.byKey(const Key('segment_rounds_field')), '3');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('segment_save_button')));
    await tester.pumpAndSettle();

    expect(find.text('Da «Squat» a «Affondi»'), findsOneWidget);
    expect(find.textContaining('45″ lavoro'), findsWidgets);

    await scrollTo(tester, find.byKey(const Key('save_routine_button')));
    await tester.tap(find.byKey(const Key('save_routine_button')));
    await tester.pumpAndSettle();

    final segment = (await routines.getRoutine(id))!.segments.single;
    expect(segment.segmentIndex, 0);
    expect(segment.startIdx, 0);
    expect(segment.endIdx, 2);
    expect(segment.workSec, 45);
    expect(segment.rounds, 3);

    await disposeApp(tester);
  });

  testWidgets('un passo di riscaldamento nasce con la sua durata e la tiene', (
    tester,
  ) async {
    final cat = await seedExercise('Cat-Cow', group: MuscleGroup.mobilita);

    await tester.pumpWidget(_app(database));
    await openEditor(tester);

    await tester.enterText(
      find.byKey(const Key('routine_name_field')),
      'Mattina',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();

    await scrollTo(tester, find.byKey(const Key('add_warmup_button')));
    await tester.tap(find.byKey(const Key('add_warmup_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Cat-Cow'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('picker_confirm_button')));
    await tester.pumpAndSettle();

    // La scheda ha bisogno di almeno un esercizio principale per salvare.
    await scrollTo(tester, find.byKey(const Key('add_main_button')));
    await tester.tap(find.byKey(const Key('add_main_button')));
    await tester.pumpAndSettle();
    // Cercare un esercizio che non c'è offre di crearlo senza uscire dalla
    // scheda: il foglio arriva già col nome scritto.
    await tester.enterText(
      find.byKey(const Key('picker_search_field')),
      'Squat',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('picker_create_tile')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('exercise_name_field')))
          .controller!
          .text,
      'Squat',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    final saveExercise = find.byKey(const Key('save_exercise_button'));
    await tester.ensureVisible(saveExercise);
    await tester.pumpAndSettle();
    await tester.tap(saveExercise);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('picker_confirm_button')));
    await tester.pumpAndSettle();
    // La conferma di «esercizio creato» galleggia sopra il pulsante Salva:
    // si aspetta che se ne vada, come farebbe una persona.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // Il passo nasce con la durata proposta dalla scheda, non vuoto: il
    // database pretende una durata per ogni riga di riscaldamento.
    final durationField = find.byKey(
      Key('warmup_duration_${cat.exerciseRefId}'),
    );
    await scrollTo(tester, durationField);
    expect(tester.widget<TextField>(durationField).controller!.text, '30');

    await scrollTo(tester, find.byKey(const Key('save_routine_button')));
    await tester.tap(find.byKey(const Key('save_routine_button')));
    await tester.pumpAndSettle();

    final warmup = await (database.select(
      database.routineExercises,
    )..where((row) => row.block.equals('warmup'))).getSingle();
    expect(warmup.exerciseNameSnapshot, 'Cat-Cow');
    expect(warmup.warmupDurationSec, 30);
    expect(warmup.position, 0);
    final main = (await mainRows()).single;
    expect(main.exerciseNameSnapshot, 'Squat');

    await disposeApp(tester);
  });

  testWidgets(
    'un esercizio sparito dal catalogo resta segnalato, non sparisce',
    (tester) async {
      final squat = await seedExercise('Squat');
      final id = await routines.saveRoutine(
        profileId: profileId,
        draft: RoutineDraft(
          name: 'Gambe',
          warmup: const [],
          main: [squat],
          finisher: const [],
          segments: const [],
        ),
      );
      await exercises.deleteExercise(squat.exerciseRefId);

      await tester.pumpWidget(_app(database, routineId: id));
      await openEditor(tester);

      await scrollTo(tester, find.byKey(const Key('prescription_main-0')));
      // Il nome compare due volte: nella riga della scheda e nella proposta
      // di carico, che parla degli stessi esercizi.
      expect(find.text('Squat'), findsWidgets);
      expect(find.text('Non più in libreria'), findsOneWidget);

      await disposeApp(tester);
    },
  );
}
