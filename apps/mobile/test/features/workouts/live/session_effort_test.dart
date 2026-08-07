import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/features/workouts/domain/session_effort.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';
import 'package:kal_tracker/features/workouts/domain/workout_finalization.dart';
import 'package:kal_tracker/features/workouts/presentation/widgets/session_effort_sheet.dart';

/// I tre bersagli di fine sessione: cosa valgono e come si toccano.

Workout _openWorkout() =>
    Workout(id: 'w1', startedAt: DateTime(2026, 8, 5, 18), exercises: const []);

Widget _host(void Function(SessionEffort?) onAnswer) => MaterialApp(
  theme: AppTheme.light,
  home: Scaffold(
    body: Builder(
      builder: (context) => Center(
        child: TextButton(
          key: const Key('apri'),
          onPressed: () async => onAnswer(await askSessionEffort(context)),
          child: const Text('Chiudi la sessione'),
        ),
      ),
    ),
  ),
);

void main() {
  group('i tre bersagli', () {
    test('parlano la scala che il database e lo storico già conoscono', () {
      // `workouts.rpe` è vincolata a 1..10 e lo storico importato da Gym è su
      // quella scala: i tre livelli ci stanno dentro, quindi vecchio e nuovo
      // si mediano insieme senza conversioni.
      for (final effort in SessionEffort.values) {
        expect(effort.rpe, inInclusiveRange(1, 10));
      }
      expect(SessionEffort.facile.rpe, 3);
      expect(SessionEffort.giusta.rpe, 6);
      expect(SessionEffort.dura.rpe, 9);
    });

    test('un gradino vale tre punti, molto più della soglia del semaforo', () {
      // Il segnale «sforzo in salita» scatta a 0,75 di differenza fra medie
      // settimanali: con gradini da tre punti, una settimana che si sposta
      // davvero lo supera anche se solo una sessione su quattro cambia
      // bersaglio.
      expect(SessionEffort.giusta.rpe - SessionEffort.facile.rpe, 3);
      expect(SessionEffort.dura.rpe - SessionEffort.giusta.rpe, 3);
    });

    test('ognuno si legge ad alta voce senza numeri', () {
      expect(SessionEffort.dura.spoken, contains('Dura'));
      expect(SessionEffort.dura.spoken, isNot(contains('9')));
    });
  });

  group('istantanea di chiusura', () {
    test('la risposta finisce nell\'RPE della sessione, non a fianco', () {
      final snapshot = finalizeWorkoutSnapshot(
        workout: _openWorkout(),
        endedAt: DateTime(2026, 8, 5, 19),
        bodyKg: 94.5,
        effort: SessionEffort.dura,
      );

      expect(snapshot.rpe, 9);
      expect(snapshot.endedAt, isNotNull);
    });

    test('senza risposta l\'RPE resta com\'era: non si inventa un livello', () {
      final snapshot = finalizeWorkoutSnapshot(
        workout: _openWorkout(),
        endedAt: DateTime(2026, 8, 5, 19),
        bodyKg: 94.5,
      );

      expect(snapshot.rpe, isNull);
    });
  });

  group('il foglio', () {
    testWidgets('mostra i tre bersagli con la parola, non con un numero', (
      tester,
    ) async {
      await tester.pumpWidget(_host((_) {}));
      await tester.tap(find.byKey(const Key('apri')));
      await tester.pumpAndSettle();

      expect(find.text('Com\'è andata?'), findsOneWidget);
      expect(find.text('Facile'), findsOneWidget);
      expect(find.text('Giusta'), findsOneWidget);
      expect(find.text('Dura'), findsOneWidget);
      // Nessuna scala 1..10 in vista: è il punto della sostituzione.
      expect(find.text('6'), findsNothing);
    });

    testWidgets('i bersagli sono grossi: nessuno sotto i 48', (tester) async {
      await tester.pumpWidget(_host((_) {}));
      await tester.tap(find.byKey(const Key('apri')));
      await tester.pumpAndSettle();

      for (final effort in SessionEffort.values) {
        final size = tester.getSize(
          find.byKey(Key('session_effort_${effort.name}')),
        );
        expect(size.height, greaterThanOrEqualTo(48));
      }
    });

    testWidgets('toccarne uno restituisce quel livello', (tester) async {
      SessionEffort? answer;
      await tester.pumpWidget(_host((value) => answer = value));
      await tester.tap(find.byKey(const Key('apri')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('session_effort_giusta')));
      await tester.pumpAndSettle();

      expect(answer, SessionEffort.giusta);
    });

    testWidgets('toccare fuori NON lo chiude: la domanda è obbligatoria', (
      tester,
    ) async {
      var answered = false;
      await tester.pumpWidget(_host((_) => answered = true));
      await tester.tap(find.byKey(const Key('apri')));
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.text('Com\'è andata?'), findsOneWidget);
      expect(answered, isFalse);

      await tester.tap(find.byKey(const Key('session_effort_facile')));
      await tester.pumpAndSettle();
    });

    testWidgets('nemmeno il gesto «indietro» lo chiude', (tester) async {
      await tester.pumpWidget(_host((_) {}));
      await tester.tap(find.byKey(const Key('apri')));
      await tester.pumpAndSettle();

      // È il gesto che in palestra parte da solo, col telefono in mano.
      final popped = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(popped, isTrue);
      expect(find.text('Com\'è andata?'), findsOneWidget);

      await tester.tap(find.byKey(const Key('session_effort_dura')));
      await tester.pumpAndSettle();
    });
  });
}
