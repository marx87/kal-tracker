import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/features/workouts/domain/exercise_kind.dart';
import 'package:kal_tracker/features/workouts/domain/plate_calculator.dart';
import 'package:kal_tracker/features/workouts/domain/rest_timer_controller.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';
import 'package:kal_tracker/features/workouts/presentation/widgets/exercise_block_card.dart';
import 'package:kal_tracker/features/workouts/presentation/widgets/plate_calculator_sheet.dart';
import 'package:kal_tracker/features/workouts/presentation/widgets/rest_timer_banner.dart';
import 'package:kal_tracker/features/workouts/presentation/widgets/workout_set_row.dart';

/// I mattoni della sessione, uno per uno.

Widget _host(Widget child, {double textScale = 1, Brightness? brightness}) =>
    MaterialApp(
      theme: brightness == Brightness.dark ? AppTheme.dark : AppTheme.light,
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

void main() {
  group('calcolo dischi', () {
    test('cento chili su un bilanciere da venti sono 25+15 per lato', () {
      final breakdown = computePlateBreakdown(targetKg: 100, barKg: 20);

      expect(breakdown.perSide, [25.0, 15.0]);
      expect(breakdown.residual, closeTo(0, 0.001));
    });

    test('un peso non componibile lascia un residuo dichiarato', () {
      // 47,5 - 20 = 27,5 → 13,75 per lato: 10 + 2,5 + 1,25 fa 13,75. Serve un
      // caso davvero scomodo.
      final breakdown = computePlateBreakdown(targetKg: 42, barKg: 20);

      expect(breakdown.residual, greaterThan(0));
      expect(
        achievablePlateTotal(perSide: breakdown.perSide, barKg: 20),
        lessThan(42),
      );
    });

    test('sotto il peso del bilanciere non si carica niente', () {
      final breakdown = computePlateBreakdown(targetKg: 15, barKg: 20);

      expect(breakdown.perSide, isEmpty);
      expect(breakdown.residual, 0);
    });

    testWidgets('il foglio mostra i dischi e il totale reale', (tester) async {
      await tester.pumpWidget(
        _host(const PlateCalculatorSheet(initialWeight: 100)),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('plate_total')), findsOneWidget);
      // Un disco per numero, col numero scritto sopra: il colore non è
      // l'unica cosa che li distingue.
      expect(find.text('25'), findsOneWidget);
      expect(find.text('15'), findsOneWidget);
    });

    testWidgets('un peso irraggiungibile è dichiarato, non arrotondato', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const PlateCalculatorSheet(initialWeight: 42)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Non esatto'), findsOneWidget);
      expect(find.textContaining('Il carico più vicino'), findsOneWidget);
    });

    testWidgets('sotto il bilanciere si spiega cosa fare', (tester) async {
      await tester.pumpWidget(
        _host(const PlateCalculatorSheet(initialWeight: 12)),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('meno del bilanciere'), findsOneWidget);
    });
  });

  group('riga della serie', () {
    testWidgets('peso × ripetizioni mostra i due campi', (tester) async {
      await tester.pumpWidget(
        _host(
          WorkoutSetRow(
            set: const WorkoutSet(weightKg: 80, reps: 8),
            setNumber: 1,
            trackingMode: ExerciseTrackingMode.weightReps,
            onChanged: (_) {},
            onComplete: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('80'), findsOneWidget);
      expect(find.text('8'), findsOneWidget);
      expect(find.byKey(const Key('set_open_plates')), findsOneWidget);
    });

    testWidgets('a solo tempo non compaiono peso né dischi', (tester) async {
      await tester.pumpWidget(
        _host(
          WorkoutSetRow(
            set: const WorkoutSet(durationSec: 90),
            setNumber: 1,
            trackingMode: ExerciseTrackingMode.timeOnly,
            onChanged: (_) {},
            onComplete: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('01:30'), findsOneWidget);
      expect(find.byKey(const Key('set_weight_value')), findsNothing);
      expect(find.byKey(const Key('set_open_plates')), findsNothing);
    });

    testWidgets('i pulsanti − e + cambiano il valore di 2,5 kg', (
      tester,
    ) async {
      WorkoutSet? changed;
      await tester.pumpWidget(
        _host(
          WorkoutSetRow(
            set: const WorkoutSet(weightKg: 80, reps: 8),
            setNumber: 1,
            trackingMode: ExerciseTrackingMode.weightReps,
            onChanged: (set) => changed = set,
            onComplete: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Aumenta peso in chilogrammi'));
      await tester.pumpAndSettle();

      expect(changed?.weightKg, 82.5);
    });

    testWidgets('la riga si legge come un blocco solo, con il suo stato', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          WorkoutSetRow(
            set: const WorkoutSet(weightKg: 80, reps: 8, completed: true),
            setNumber: 2,
            trackingMode: ExerciseTrackingMode.weightReps,
            onChanged: (_) {},
            onComplete: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Serie 2'), findsOneWidget);
      // Il pulsante dice che si può RIAPRIRE: senza, «fatta» sembrerebbe
      // definitivo.
      expect(
        find.bySemanticsLabel('Serie 2 fatta. Tocca per riaprirla.'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('al 150% di testo la riga non trabocca', (tester) async {
      await tester.pumpWidget(
        _host(
          WorkoutSetRow(
            set: const WorkoutSet(weightKg: 122.5, reps: 12),
            setNumber: 3,
            trackingMode: ExerciseTrackingMode.weightReps,
            onChanged: (_) {},
            onComplete: () {},
          ),
          textScale: 1.5,
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('il bersaglio «fatta» rispetta i 48', (tester) async {
      await tester.pumpWidget(
        _host(
          WorkoutSetRow(
            set: const WorkoutSet(weightKg: 80, reps: 8),
            setNumber: 1,
            trackingMode: ExerciseTrackingMode.weightReps,
            onChanged: (_) {},
            onComplete: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final size = tester.getSize(
        find.bySemanticsLabel('Segna la serie 1 come fatta'),
      );
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    });

    testWidgets('RIR rapido salva sulla scala RPE compatibile', (tester) async {
      WorkoutSet? changed;
      await tester.pumpWidget(
        _host(
          WorkoutSetRow(
            set: const WorkoutSet(weightKg: 20, reps: 10),
            setNumber: 1,
            trackingMode: ExerciseTrackingMode.weightReps,
            onChanged: (value) => changed = value,
            onComplete: () {},
          ),
        ),
      );

      await tester.tap(find.text('RIR'));
      await tester.pumpAndSettle();
      expect(find.text('Quante ne avevi ancora?'), findsOneWidget);

      await tester.tap(
        find.bySemanticsLabel('2 ripetizioni in riserva, equivalente a RPE 8'),
      );
      await tester.pumpAndSettle();

      expect(changed?.rpe, 8);
    });
  });

  group('fascia del recupero', () {
    testWidgets('mostra i secondi e li aggiusta di quindici', (tester) async {
      final controller = RestTimerController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_host(RestTimerBanner(controller: controller)));
      controller.start(const Duration(seconds: 90));
      await tester.pump();

      expect(
        tester.widget<Text>(find.byKey(const Key('rest_timer_seconds'))).data,
        '90',
      );

      await tester.tap(
        find.bySemanticsLabel('Aggiungi 15 secondi al recupero'),
      );
      await tester.pump();

      expect(
        tester.widget<Text>(find.byKey(const Key('rest_timer_seconds'))).data,
        '105',
      );

      controller.cancel();
      await tester.pump();
    });

    testWidgets('«riparti ora» chiude il recupero e chiama la callback', (
      tester,
    ) async {
      final controller = RestTimerController();
      addTearDown(controller.dispose);
      var completed = 0;

      await tester.pumpWidget(_host(RestTimerBanner(controller: controller)));
      controller.start(
        const Duration(seconds: 60),
        onComplete: () => completed++,
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('rest_timer_skip')));
      await tester.pump();

      expect(completed, 1);
      // Nel flusso manuale la fascia sparisce: il pulsante della serie
      // successiva deve tornare raggiungibile subito.
      expect(find.byKey(const Key('rest_timer_seconds')), findsNothing);
    });

    testWidgets('a recupero finito la fascia si tocca per intero', (
      tester,
    ) async {
      final controller = RestTimerController(
        now: () => DateTime(2026, 8, 5, 18),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(_host(RestTimerBanner(controller: controller)));
      controller.start(const Duration(seconds: 30));
      // L'orologio è fermo su un istante oltre la scadenza: il recupero è
      // scaduto, come al ritorno da un giro in secondo piano.
      controller.synchronize(now: DateTime(2026, 8, 5, 18, 1));
      await tester.pump();

      expect(find.text('Recupero finito — tocca e riparti'), findsOneWidget);

      await tester.tap(find.byType(InkWell).first);
      await tester.pump();

      expect(find.text('Recupero finito — tocca e riparti'), findsNothing);
    });

    testWidgets('nella superserie guidata si può fermare tutta la sequenza', (
      tester,
    ) async {
      final controller = RestTimerController();
      addTearDown(controller.dispose);
      var stopped = 0;

      await tester.pumpWidget(
        _host(
          RestTimerBanner(
            controller: controller,
            guided: true,
            onStop: () => stopped++,
            nextLabel: 'Rematore',
          ),
        ),
      );
      controller.start(const Duration(seconds: 45));
      await tester.pump();

      expect(find.text('Poi: Rematore'), findsOneWidget);
      await tester.tap(find.byKey(const Key('rest_timer_close')));
      await tester.pump();

      // Chiudere durante una superserie guidata ferma la SEQUENZA, non solo
      // il cronometro: il timer da solo non significa niente.
      expect(stopped, 1);

      controller.cancel();
      await tester.pump();
    });

    testWidgets('al buio la fascia resta leggibile', (tester) async {
      final controller = RestTimerController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _host(
          RestTimerBanner(controller: controller),
          brightness: Brightness.dark,
        ),
      );
      controller.start(const Duration(seconds: 30));
      await tester.pump();

      final text = tester.widget<Text>(
        find.byKey(const Key('rest_timer_seconds')),
      );
      // Il colore arriva dal tema scuro, non da un blu scritto a mano.
      expect(text.style?.color, AppTheme.dark.colorScheme.onPrimaryContainer);

      controller.cancel();
      await tester.pump();
    });
  });

  group('cronometro del recupero', () {
    test('scendere sotto zero con −15 chiude il recupero una volta sola', () {
      var completed = 0;
      final controller = RestTimerController(
        now: () => DateTime(2026, 8, 5, 18),
      )..start(const Duration(seconds: 10), onComplete: () => completed++);

      controller.addSeconds(-15);
      controller.addSeconds(-15);

      expect(controller.isCompleted, isTrue);
      expect(completed, 1);
      controller.dispose();
    });

    test('«salta» consegna il completamento esattamente una volta', () {
      var completed = 0;
      final controller = RestTimerController(
        now: () => DateTime(2026, 8, 5, 18),
      )..start(const Duration(seconds: 60), onComplete: () => completed++);

      controller
        ..skip()
        ..skip();

      expect(completed, 1);
      controller.dispose();
    });
  });

  group('card della superserie', () {
    Workout supersetWorkout() => Workout(
      id: 'w1',
      startedAt: DateTime(2026, 8, 5, 18),
      exercises: [
        WorkoutExercise(
          exerciseId: 'bench',
          exerciseName: 'Panca piana',
          muscleGroup: MuscleGroup.petto,
          restSeconds: 90,
          sets: const [
            WorkoutSet(weightKg: 80, reps: 8, completed: true),
            WorkoutSet(weightKg: 80, reps: 8),
          ],
        ),
        WorkoutExercise(
          exerciseId: 'row',
          exerciseName: 'Rematore',
          muscleGroup: MuscleGroup.schiena,
          restSeconds: 90,
          isInSupersetWithPrevious: true,
          sets: const [
            WorkoutSet(weightKg: 60, reps: 10),
            WorkoutSet(weightKg: 60, reps: 10),
          ],
        ),
      ],
    );

    WorkoutBlockActions noActions() => WorkoutBlockActions(
      onSetChanged: (_, _, _) {},
      onSetComplete: (_, _) {},
      onAddRound: (_) {},
    );

    testWidgets('si legge PER ROUND, non come due elenchi affiancati', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SupersetGroupCard(
            workout: supersetWorkout(),
            memberIndices: const [0, 1],
            actions: noActions(),
            current: (exerciseIndex: 1, setIndex: 0),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Round 1 di 2'), findsOneWidget);
      expect(find.text('Round 2 di 2'), findsOneWidget);
      // Le stazioni si chiamano A e B, come nella scheda.
      expect(find.text('A'), findsNWidgets(2));
      expect(find.text('B'), findsNWidgets(2));
      expect(find.text('Panca piana + Rematore'), findsOneWidget);
      expect(find.text('1 celle su 4'), findsOneWidget);
    });

    testWidgets('un esercizio senza gruppo muscolare lo dichiara', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          ExerciseBlockCard(
            exercise: const WorkoutExercise(
              exerciseId: 'squat',
              exerciseName: 'Squat',
              sets: [WorkoutSet(weightKg: 100, reps: 5)],
            ),
            exerciseIndex: 0,
            actions: noActions(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Gruppo muscolare assente'), findsOneWidget);
    });
  });
}
