import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/features/workouts/domain/exercise_kind.dart';
import 'package:kal_tracker/features/workouts/domain/kcal_estimator.dart';
import 'package:kal_tracker/features/workouts/domain/live_workout_repository.dart';
import 'package:kal_tracker/features/workouts/domain/session_effort.dart';
import 'package:kal_tracker/features/workouts/domain/start_workout.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';
import 'package:kal_tracker/features/workouts/presentation/live/live_workout_providers.dart';
import 'package:kal_tracker/features/workouts/presentation/live/live_workout_screen.dart';

import 'fake_live_workout_repository.dart';

/// La schermata dal vivo, montata davvero.
///
/// NOTA SUI PUMP: la sessione ha un cronometro che si aggiorna ogni secondo,
/// quindi `pumpAndSettle` non tornerebbe mai — l'albero non smette di
/// ridisegnarsi finché la sessione è aperta. Si pompa a mano, come si fa con
/// ogni schermata che ha un orologio dentro.

Future<void> _settle(WidgetTester tester, [int frames = 6]) async {
  for (var index = 0; index < frames; index++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// Aspetta che `showAutoClosingSnackBar` chiuda la sua fascia.
///
/// Serve perché quell'helper esiste apposta: su questo Flutter una snackbar
/// CON azione non si chiude da sola, e il timer di chiusura resterebbe appeso
/// oltre la fine del test.
Future<void> _closeAutoSnackBar(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 6));
  await _settle(tester);
}

/// Risponde alla domanda obbligatoria di fine sessione.
///
/// Ogni chiusura passa di qui: senza risposta la sessione non si chiude, ed è
/// il motivo per cui non esiste una scorciatoia nemmeno nei test.
Future<void> _answerEffort(
  WidgetTester tester, [
  SessionEffort effort = SessionEffort.giusta,
]) async {
  await tester.tap(find.byKey(Key('session_effort_${effort.name}')));
  await _settle(tester);
}

WorkoutExercise _bench({
  int sets = 3,
  bool superset = false,
  String id = 'bench',
}) => WorkoutExercise(
  exerciseId: id,
  exerciseName: id == 'bench' ? 'Panca piana' : 'Rematore',
  muscleGroup: MuscleGroup.petto,
  restSeconds: 90,
  isInSupersetWithPrevious: superset,
  sets: [
    for (var index = 0; index < sets; index++)
      const WorkoutSet(weightKg: 80, reps: 8),
  ],
);

Workout _openWorkout({
  List<WorkoutExercise>? exercises,
  DateTime? pausedAt,
  int accumulatedPause = 0,
  String? resumePath,
}) => Workout(
  id: 'w1',
  startedAt: DateTime.now().subtract(const Duration(minutes: 12)),
  routineName: 'Giorno 1 · spinta',
  pausedAt: pausedAt,
  accumulatedPauseSeconds: accumulatedPause,
  resumePath: resumePath,
  exercises: exercises ?? [_bench()],
);

Widget _app(FakeLiveWorkoutRepository repository, {Widget? child}) =>
    ProviderScope(
      overrides: [liveWorkoutRepositoryProvider.overrideWithValue(repository)],
      child: MaterialApp(
        theme: AppTheme.light,
        home: child ?? const LiveWorkoutScreen(workoutId: 'w1'),
      ),
    );

void main() {
  group('sessione dal vivo', () {
    testWidgets('mostra la scheda, le serie e quale tocca adesso', (
      tester,
    ) async {
      final repository = FakeLiveWorkoutRepository(initial: _openWorkout());

      await tester.pumpWidget(_app(repository));
      await _settle(tester);

      expect(find.text('Giorno 1 · spinta'), findsOneWidget);
      expect(find.text('Panca piana'), findsWidgets);
      expect(find.text('0 serie su 3'), findsOneWidget);
      // L'azione principale nomina la serie che tocca, non «avanti».
      expect(find.textContaining('Fatta: Panca piana'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('spuntare una serie la salva e fa partire il recupero', (
      tester,
    ) async {
      final repository = FakeLiveWorkoutRepository(initial: _openWorkout());

      await tester.pumpWidget(_app(repository));
      await _settle(tester);

      await tester.tap(find.byKey(const Key('live_workout_complete_current')));
      await _settle(tester);

      expect(repository.saved, isNotEmpty);
      expect(
        repository.saved.last.exercises.first.sets.first.completed,
        isTrue,
      );
      expect(find.text('1 serie su 3'), findsOneWidget);
      // Novanta secondi di recupero: il banner li mostra.
      expect(find.byKey(const Key('rest_timer_seconds')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('rest_timer_seconds'))).data,
        '90',
      );
      // Durante il recupero c'è una sola azione primaria: il timer non lotta
      // più con «serie fatta» nello stesso spazio in fondo.
      expect(
        find.byKey(const Key('live_workout_complete_current')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('rest_timer_skip')));
      await _settle(tester);
      expect(
        find.byKey(const Key('live_workout_complete_current')),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('dentro una superserie il recupero NON parte a metà round', (
      tester,
    ) async {
      final repository = FakeLiveWorkoutRepository(
        initial: _openWorkout(
          exercises: [
            _bench(sets: 2),
            _bench(sets: 2, superset: true, id: 'row'),
          ],
        ),
      );

      await tester.pumpWidget(_app(repository));
      await _settle(tester);

      // Prima cella: A1. Dopo, si va su B1 senza timer.
      await tester.tap(find.byKey(const Key('live_workout_complete_current')));
      await _settle(tester);

      expect(find.byKey(const Key('rest_timer_seconds')), findsNothing);
      expect(find.textContaining('Fatta: Rematore'), findsOneWidget);

      // Seconda cella: chiude il round, e ADESSO si riposa.
      await tester.tap(find.byKey(const Key('live_workout_complete_current')));
      await _settle(tester);

      expect(find.byKey(const Key('rest_timer_seconds')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      'se la scrittura fallisce la serie torna aperta invece di sembrare '
      'registrata',
      (tester) async {
        final repository = FakeLiveWorkoutRepository(initial: _openWorkout())
          ..failNextSave = true;

        await tester.pumpWidget(_app(repository));
        await _settle(tester);

        await tester.tap(
          find.byKey(const Key('live_workout_complete_current')),
        );
        await _settle(tester);

        expect(find.text('0 serie su 3'), findsOneWidget);
        expect(find.text('Serie non salvata. Riprova.'), findsOneWidget);

        // La snackbar CON azione si chiude solo grazie all'helper: lo si
        // lascia scattare, altrimenti resta un timer appeso — che è
        // esattamente il difetto che l'helper esiste per evitare.
        await _closeAutoSnackBar(tester);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('la stima delle calorie dichiara su che peso è fatta', (
      tester,
    ) async {
      final repository = FakeLiveWorkoutRepository(
        initial: _openWorkout(),
        bodyWeights: [
          BodyWeightSample(measuredAt: DateTime(2026, 6, 19), kg: 94.5),
          BodyWeightSample(measuredAt: DateTime(2026, 5), kg: 97),
        ],
      );

      await tester.pumpWidget(_app(repository));
      await _settle(tester);

      expect(find.textContaining('Su 94.5 kg — ultima pesata'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      'un esercizio senza gruppo muscolare è dichiarato, non nascosto',
      (tester) async {
        final repository = FakeLiveWorkoutRepository(
          initial: _openWorkout(
            exercises: const [
              WorkoutExercise(
                exerciseId: 'squat',
                exerciseName: 'Squat',
                sets: [WorkoutSet(weightKg: 100, reps: 5)],
              ),
            ],
          ),
        );

        await tester.pumpWidget(_app(repository));
        await _settle(tester);

        expect(find.text('Gruppo muscolare assente'), findsOneWidget);
        expect(find.text('Stima grezza'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });

  group('ripresa', () {
    testWidgets(
      'riaprendo una sessione in pausa il tempo lontano finisce nelle pause, '
      'non nella durata',
      (tester) async {
        final repository = FakeLiveWorkoutRepository(
          initial: _openWorkout(
            pausedAt: DateTime.now().subtract(const Duration(minutes: 5)),
          ),
        );

        await tester.pumpWidget(_app(repository));
        await _settle(tester);

        final saved = repository.saved.last;
        expect(saved.pausedAt, isNull);
        // Cinque minuti di assenza, con un margine per il tempo di prova.
        expect(saved.accumulatedPauseSeconds, greaterThanOrEqualTo(299));
        // Dodici minuti dall'avvio meno cinque di pausa: sette.
        expect(find.textContaining('In corso da 07:'), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('un blocco a tempo lasciato a metà si può riprendere', (
      tester,
    ) async {
      final repository = FakeLiveWorkoutRepository(
        initial: _openWorkout(resumePath: '/workout/w1/phase/segment?seg=0'),
      );
      String? opened;

      await tester.pumpWidget(
        _app(
          repository,
          child: LiveWorkoutScreen(
            workoutId: 'w1',
            onOpenPhase: (path) => opened = path,
          ),
        ),
      );
      await _settle(tester);

      expect(find.text('Blocco a tempo lasciato a metà'), findsOneWidget);
      await tester.tap(find.byKey(const Key('section_card_action')).first);
      await _settle(tester);

      expect(opened, '/workout/w1/phase/segment?seg=0');

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('uscita protetta', () {
    testWidgets('il gesto indietro chiede cosa fare invece di uscire', (
      tester,
    ) async {
      final repository = FakeLiveWorkoutRepository(initial: _openWorkout());

      await tester.pumpWidget(_app(repository));
      await _settle(tester);

      await tester.tap(find.byKey(const Key('live_workout_back')));
      await _settle(tester);

      expect(find.text('Allenamento in corso'), findsOneWidget);
      expect(find.byKey(const Key('workout_exit_continue')), findsOneWidget);
      expect(find.byKey(const Key('workout_exit_pause')), findsOneWidget);
      expect(find.byKey(const Key('workout_exit_finish')), findsOneWidget);

      // «Continua» non deve fare nulla se non chiudere il dialogo.
      await tester.tap(find.byKey(const Key('workout_exit_continue')));
      await _settle(tester);

      expect(find.text('Allenamento in corso'), findsNothing);
      expect(repository.finalized, isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('«metti in pausa» scrive la pausa e NON chiude la sessione', (
      tester,
    ) async {
      final repository = FakeLiveWorkoutRepository(initial: _openWorkout());

      await tester.pumpWidget(_app(repository));
      await _settle(tester);

      await tester.tap(find.byKey(const Key('live_workout_back')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('workout_exit_pause')));
      await _settle(tester);

      expect(repository.saved.last.pausedAt, isNotNull);
      expect(repository.saved.last.endedAt, isNull);
      expect(repository.finalized, isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      '«chiudi e salva» propone il defaticamento e poi chiude con le calorie',
      (tester) async {
        final repository = FakeLiveWorkoutRepository(
          initial: _openWorkout(),
          bodyWeights: [
            BodyWeightSample(measuredAt: DateTime(2026, 6, 19), kg: 94.5),
          ],
        );
        String? openedPhase;
        bool? rowsWereIncomplete;

        await tester.pumpWidget(
          _app(
            repository,
            child: LiveWorkoutScreen(
              workoutId: 'w1',
              onOpenPhase: (path) async {
                openedPhase = path;
                final current = repository.current!;
                final exercises = [
                  for (final exercise in current.exercises)
                    if (exercise.isCooldown)
                      exercise.copyWith(
                        sets: [
                          for (final set in exercise.sets)
                            set.copyWith(completed: true),
                        ],
                      )
                    else
                      exercise,
                ];
                rowsWereIncomplete = current.exercises
                    .where((exercise) => exercise.isCooldown)
                    .expand((exercise) => exercise.sets)
                    .every((set) => !set.completed);
                await repository.commitCircuitPhase(
                  current.copyWith(exercises: exercises),
                );
              },
            ),
          ),
        );
        await _settle(tester);

        await tester.tap(find.byKey(const Key('live_workout_back')));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('workout_exit_finish')));
        await _settle(tester);

        expect(find.text('Defaticamento?'), findsOneWidget);
        await tester.tap(find.byKey(const Key('cooldown_accept')));
        await _settle(tester);
        await _answerEffort(tester);

        final closed = repository.finalized;
        expect(closed, isNotNull);
        expect(closed!.endedAt, isNotNull);
        expect(closed.totalKcal, greaterThan(0));
        expect(closed.exercises.where((e) => e.isCooldown), isNotEmpty);
        expect(openedPhase, '/workout/w1/phase/cooldown');
        expect(rowsWereIncomplete, isTrue);
        expect(
          closed.exercises
              .where((exercise) => exercise.isCooldown)
              .expand((exercise) => exercise.sets)
              .every((set) => set.completed),
          isTrue,
        );

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets('rifiutando il defaticamento si chiude e basta', (
      tester,
    ) async {
      final repository = FakeLiveWorkoutRepository(initial: _openWorkout());

      await tester.pumpWidget(_app(repository));
      await _settle(tester);

      await tester.tap(find.byKey(const Key('live_workout_back')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('workout_exit_finish')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('cooldown_skip')));
      await _settle(tester);
      await _answerEffort(tester);

      expect(repository.finalized, isNotNull);
      expect(
        repository.finalized!.exercises.where((e) => e.isCooldown),
        isEmpty,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      'se la chiusura fallisce l\'allenamento resta aperto e lo si dice',
      (tester) async {
        final repository = FakeLiveWorkoutRepository(initial: _openWorkout())
          ..failFinalize = true;

        await tester.pumpWidget(_app(repository));
        await _settle(tester);

        await tester.tap(find.byKey(const Key('live_workout_back')));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('workout_exit_finish')));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('cooldown_skip')));
        await _settle(tester);
        await _answerEffort(tester);

        expect(repository.finalized, isNull);
        expect(
          find.text('Chiusura non riuscita: l\'allenamento è ancora aperto.'),
          findsOneWidget,
        );

        await _closeAutoSnackBar(tester);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });

  group('com\'è andata', () {
    testWidgets('la sessione non si chiude finché non si risponde', (
      tester,
    ) async {
      final repository = FakeLiveWorkoutRepository(initial: _openWorkout());

      await tester.pumpWidget(_app(repository));
      await _settle(tester);

      await tester.tap(find.byKey(const Key('live_workout_back')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('workout_exit_finish')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('cooldown_skip')));
      await _settle(tester);

      expect(find.text('Com\'è andata?'), findsOneWidget);
      // Toccare fuori è il gesto con cui si scappava dalla domanda
      // facoltativa: qui non porta da nessuna parte.
      await tester.tapAt(const Offset(10, 10));
      await _settle(tester);

      expect(find.text('Com\'è andata?'), findsOneWidget);
      expect(repository.finalized, isNull);

      await _answerEffort(tester, SessionEffort.dura);

      expect(repository.finalized, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('il bersaglio scelto finisce nell\'RPE della sessione', (
      tester,
    ) async {
      final repository = FakeLiveWorkoutRepository(initial: _openWorkout());

      await tester.pumpWidget(_app(repository));
      await _settle(tester);

      await tester.tap(find.byKey(const Key('live_workout_back')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('workout_exit_finish')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('cooldown_skip')));
      await _settle(tester);
      await _answerEffort(tester, SessionEffort.dura);

      // Nove: la colonna è quella di sempre, così le sessioni importate da Gym
      // e queste si mediano insieme.
      expect(repository.finalized!.rpe, 9);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      'dopo una chiusura fallita il ritentativo non ripete la domanda',
      (tester) async {
        final repository = FakeLiveWorkoutRepository(initial: _openWorkout())
          ..failFinalize = true;

        await tester.pumpWidget(_app(repository));
        await _settle(tester);

        await tester.tap(find.byKey(const Key('live_workout_back')));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('workout_exit_finish')));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('cooldown_skip')));
        await _settle(tester);
        await _answerEffort(tester, SessionEffort.facile);

        expect(repository.finalized, isNull);

        // Il database si riprende e si ritenta dalla snackbar.
        repository.failFinalize = false;
        await tester.tap(find.text('Riprova'));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('cooldown_skip')));
        await _settle(tester);

        // La risposta è già stata data: pagare l'errore di scrittura con una
        // seconda domanda sarebbe il modo più veloce per farla odiare.
        expect(find.text('Com\'è andata?'), findsNothing);
        expect(repository.finalized, isNotNull);
        expect(repository.finalized!.rpe, 3);

        await _closeAutoSnackBar(tester);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });

  group('record personali', () {
    Workout closedSession({required double kg, required int reps}) => Workout(
      id: 'vecchia',
      startedAt: DateTime(2026, 7, 1, 18),
      endedAt: DateTime(2026, 7, 1, 19),
      exercises: [
        WorkoutExercise(
          exerciseId: 'bench',
          exerciseName: 'Panca piana',
          muscleGroup: MuscleGroup.petto,
          sets: [WorkoutSet(weightKg: kg, reps: reps, completed: true)],
        ),
      ],
    );

    testWidgets('battere il carico di prima si festeggia sul momento', (
      tester,
    ) async {
      final repository = FakeLiveWorkoutRepository(
        // Oggi si spingono 80 kg: il massimo precedente era 75.
        initial: _openWorkout(),
        closedHistory: [closedSession(kg: 75, reps: 8)],
      );

      await tester.pumpWidget(_app(repository));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('live_workout_complete_current')));
      await _settle(tester);

      expect(
        find.textContaining('Record: 80 kg su Panca piana'),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 6));
      await _settle(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('restare sotto il record NON produce nessun annuncio', (
      tester,
    ) async {
      final repository = FakeLiveWorkoutRepository(
        initial: _openWorkout(),
        closedHistory: [closedSession(kg: 100, reps: 8)],
      );

      await tester.pumpWidget(_app(repository));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('live_workout_complete_current')));
      await _settle(tester);

      expect(find.textContaining('Record:'), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      'la PRIMA volta che si fa un esercizio non è un record: è la base',
      (tester) async {
        final repository = FakeLiveWorkoutRepository(
          initial: _openWorkout(),
          closedHistory: const [],
        );

        await tester.pumpWidget(_app(repository));
        await _settle(tester);
        await tester.tap(
          find.byKey(const Key('live_workout_complete_current')),
        );
        await _settle(tester);

        expect(find.textContaining('Record:'), findsNothing);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });

  group('una sola sessione aperta per profilo', () {
    test('il secondo avvio propone di riprendere, non lancia', () async {
      final repository = FakeLiveWorkoutRepository(initial: _openWorkout());

      final result = await startLiveWorkout(repository, exercises: [_bench()]);

      expect(result, isA<WorkoutAlreadyRunning>());
      final running = result as WorkoutAlreadyRunning;
      expect(running.existing.id, 'w1');
      expect(
        running.message(DateTime.now()),
        'Hai già un allenamento aperto da 12 minuti.',
      );
    });

    test(
      'se il vincolo scatta comunque (due dispositivi) l\'esito è lo stesso',
      () async {
        // `activeWorkout` dice «libero», ma l'inserimento trova la corsa.
        final repository = _RacingRepository(_openWorkout());

        final result = await startLiveWorkout(
          repository,
          exercises: [_bench()],
        );

        expect(result, isA<WorkoutAlreadyRunning>());
      },
    );

    test('senza sessioni aperte si parte', () async {
      final repository = FakeLiveWorkoutRepository();

      final result = await startLiveWorkout(
        repository,
        routineName: 'Giorno 1',
        exercises: [_bench()],
      );

      expect(result, isA<WorkoutStarted>());
      expect((result as WorkoutStarted).workout.routineName, 'Giorno 1');
    });

    test('un guasto vero resta un guasto, non «ne hai già una»', () async {
      final result = await startLiveWorkout(
        _BrokenRepository(),
        exercises: [_bench()],
      );

      expect(result, isA<WorkoutStartFailed>());
    });
  });
}

/// Simula la corsa fra due dispositivi: la lettura non vede niente, la
/// scrittura sbatte contro l'indice unico.
class _RacingRepository extends FakeLiveWorkoutRepository {
  _RacingRepository(this.hidden);

  final Workout hidden;

  @override
  Future<Workout?> activeWorkout() async => null;

  @override
  Future<Workout> startWorkout({
    String? routineId,
    String? routineName,
    required List<WorkoutExercise> exercises,
  }) async => throw ActiveWorkoutAlreadyOpen(hidden);
}

class _BrokenRepository extends FakeLiveWorkoutRepository {
  @override
  Future<Workout?> activeWorkout() async => throw StateError('database chiuso');
}
