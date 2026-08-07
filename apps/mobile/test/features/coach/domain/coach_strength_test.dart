import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/coach/domain/coach_strength.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';

/// Una serie alle 18 di Roma, con le ripetizioni fisse.
///
/// Con le ripetizioni uguali fra le due letture l'e1RM è proporzionale al
/// carico, e i conti attesi si leggono direttamente dai chili: se serve
/// verificare la formula di Epley c'è il suo test, qui si verifica il
/// confronto.
CoachStrengthSet lift(
  DateTime day, {
  required String exercise,
  required double weightKg,
  int reps = 5,
  String? name,
}) => CoachStrengthSet(
  at: DateTime.utc(day.year, day.month, day.day, 16),
  exerciseId: exercise,
  exerciseName: name ?? exercise,
  weightKg: weightKg,
  reps: reps,
);

/// Lo stesso esercizio in due giorni della finestra di adesso e in due della
/// finestra di tre settimane fa.
List<CoachStrengthSet> lifted(
  String exercise, {
  required double before,
  required double now,
}) => [
  lift(DateTime.utc(2026, 7, 1), exercise: exercise, weightKg: before),
  lift(DateTime.utc(2026, 7, 8), exercise: exercise, weightKg: before),
  lift(DateTime.utc(2026, 7, 22), exercise: exercise, weightKg: now),
  lift(DateTime.utc(2026, 7, 29), exercise: exercise, weightKg: now),
];

void main() {
  setUp(AppTime.initialize);

  // La domenica del rapporto. Le due finestre che ne discendono sono
  // 20 luglio → 2 agosto e 29 giugno → 12 luglio.
  final sunday = DateTime.utc(2026, 8, 2);

  group('il confronto a tre settimane', () {
    test('tre fondamentali che calano del 10 % danno −10 %', () {
      final trend = CoachStrength.measure(
        sets: [
          ...lifted('panca', before: 100, now: 90),
          ...lifted('squat', before: 100, now: 90),
          ...lifted('stacco', before: 100, now: 90),
        ],
        referenceDay: sunday,
      );

      expect(trend.isKnown, isTrue);
      expect(trend.change, closeTo(-0.1, 0.0001));
      expect(trend.exercises, hasLength(3));
    });

    test('una forza che tiene non produce un calo', () {
      final trend = CoachStrength.measure(
        sets: [
          ...lifted('panca', before: 80, now: 82.5),
          ...lifted('squat', before: 120, now: 120),
          ...lifted('stacco', before: 140, now: 142.5),
        ],
        referenceDay: sunday,
      );

      expect(trend.change, greaterThan(0));
    });

    test('si mediano le variazioni, non i chili', () {
      // Lo squat cala del 10 %, i due esercizi leggeri non si muovono: la
      // media giusta è −3,3 %. Mediando i chili sarebbe −8,3 %, perché lo
      // squat pesa dieci volte gli altri e si mangerebbe la media da solo.
      final trend = CoachStrength.measure(
        sets: [
          ...lifted('squat', before: 200, now: 180),
          ...lifted('curl', before: 20, now: 20),
          ...lifted('alzate', before: 20, now: 20),
        ],
        referenceDay: sunday,
      );

      expect(trend.change, closeTo(-1 / 30, 0.0001));
    });

    test('dentro la seduta conta la serie di punta', () {
      // Quattro serie in scarico dopo quella pesante non devono far sembrare
      // che la forza sia crollata: la seduta vale il suo carico migliore.
      final trend = CoachStrength.measure(
        sets: [
          for (final exercise in ['panca', 'squat', 'stacco']) ...[
            lift(DateTime.utc(2026, 7, 1), exercise: exercise, weightKg: 100),
            lift(DateTime.utc(2026, 7, 8), exercise: exercise, weightKg: 100),
            lift(DateTime.utc(2026, 7, 22), exercise: exercise, weightKg: 90),
            lift(DateTime.utc(2026, 7, 22), exercise: exercise, weightKg: 60),
            lift(DateTime.utc(2026, 7, 22), exercise: exercise, weightKg: 60),
            lift(DateTime.utc(2026, 7, 29), exercise: exercise, weightKg: 90),
            lift(DateTime.utc(2026, 7, 29), exercise: exercise, weightKg: 60),
          ],
        ],
        referenceDay: sunday,
      );

      expect(trend.change, closeTo(-0.1, 0.0001));
    });

    test('i giorni fra le due finestre non entrano nel conto', () {
      // Il 15 luglio sta nel buco fra le due letture: è lì apposta perché tre
      // settimane vuol dire tre settimane, non «tutto quello che c'è».
      final trend = CoachStrength.measure(
        sets: [
          for (final exercise in ['panca', 'squat', 'stacco']) ...[
            ...lifted(exercise, before: 100, now: 90),
            lift(DateTime.utc(2026, 7, 15), exercise: exercise, weightKg: 10),
          ],
        ],
        referenceDay: sunday,
      );

      expect(trend.change, closeTo(-0.1, 0.0001));
    });

    test('la finestra si ancora al rapporto, non a «adesso»', () {
      // Rileggendo il rapporto una settimana dopo, la stessa domenica deve
      // dare lo stesso numero: è la ragione per cui `referenceDay` esiste.
      final sets = [
        ...lifted('panca', before: 100, now: 90),
        ...lifted('squat', before: 100, now: 90),
        ...lifted('stacco', before: 100, now: 90),
      ];

      expect(
        CoachStrength.measure(sets: sets, referenceDay: sunday).change,
        CoachStrength.measure(sets: sets, referenceDay: sunday).change,
      );
      expect(
        CoachStrength.measure(
          sets: sets,
          referenceDay: sunday.add(const Duration(days: 21)),
        ).isKnown,
        isFalse,
      );
    });
  });

  group('quali esercizi sono «fondamentali»', () {
    test('oltre i primi cinque per frequenza non si guarda', () {
      // Cinque esercizi fatti in quattro giornate e uno solo in due: il
      // sesto è un accessorio, e il suo crollo non deve tirare giù la media.
      final trend = CoachStrength.measure(
        sets: [
          for (final exercise in [
            'panca',
            'squat',
            'stacco',
            'lento',
            'rematore',
          ])
            ...lifted(exercise, before: 100, now: 100),
          lift(DateTime.utc(2026, 7, 1), exercise: 'pullover', weightKg: 100),
          lift(DateTime.utc(2026, 7, 22), exercise: 'pullover', weightKg: 50),
        ],
        referenceDay: sunday,
      );

      expect(trend.exercises, isNot(contains('pullover')));
      expect(trend.change, closeTo(0, 0.0001));
    });

    test('un esercizio senza un «prima» non si può confrontare', () {
      // Comparso solo adesso: non dice niente sulla forza, dice che la scheda
      // è cambiata.
      final trend = CoachStrength.measure(
        sets: [
          ...lifted('panca', before: 100, now: 90),
          ...lifted('squat', before: 100, now: 90),
          ...lifted('stacco', before: 100, now: 90),
          lift(DateTime.utc(2026, 7, 22), exercise: 'hip thrust', weightKg: 60),
          lift(DateTime.utc(2026, 7, 29), exercise: 'hip thrust', weightKg: 60),
        ],
        referenceDay: sunday,
      );

      expect(trend.exercises, isNot(contains('hip thrust')));
      expect(trend.change, closeTo(-0.1, 0.0001));
    });

    test('sotto i tre confrontabili il verdetto è «non lo so»', () {
      final trend = CoachStrength.measure(
        sets: [
          ...lifted('panca', before: 100, now: 80),
          ...lifted('squat', before: 100, now: 80),
        ],
        referenceDay: sunday,
      );

      expect(trend.isKnown, isFalse);
      expect(trend.exercises, isEmpty);
    });

    test('senza storico non si inventa una lettura tranquilla', () {
      final trend = CoachStrength.measure(sets: const [], referenceDay: sunday);

      expect(trend.isKnown, isFalse);
      expect(trend.change, isNull);
    });

    test('l\'esercizio si chiama come si chiama oggi', () {
      final trend = CoachStrength.measure(
        sets: [
          lift(
            DateTime.utc(2026, 7, 1),
            exercise: 'panca',
            weightKg: 100,
            name: 'Panca',
          ),
          lift(
            DateTime.utc(2026, 7, 22),
            exercise: 'panca',
            weightKg: 100,
            name: 'Panca piana',
          ),
          ...lifted('squat', before: 100, now: 100),
          ...lifted('stacco', before: 100, now: 100),
        ],
        referenceDay: sunday,
      );

      expect(trend.exercises, contains('Panca piana'));
      expect(trend.exercises, isNot(contains('Panca')));
    });
  });

  group('la proiezione dallo storico', () {
    test('riscaldamenti, serie non completate e cardio restano fuori', () {
      final sets = CoachStrengthSet.fromWorkouts([
        Workout(
          id: 'w1',
          startedAt: DateTime.utc(2026, 7, 22, 16),
          exercises: const [
            WorkoutExercise(
              exerciseId: 'panca',
              exerciseName: 'Panca piana',
              sets: [
                WorkoutSet(
                  weightKg: 40,
                  reps: 10,
                  isWarmup: true,
                  completed: true,
                ),
                WorkoutSet(weightKg: 90, reps: 5),
                WorkoutSet(weightKg: 90, reps: 5, completed: true),
              ],
            ),
            WorkoutExercise(
              exerciseId: 'corsa',
              exerciseName: 'Corsa',
              sets: [WorkoutSet(durationSec: 1200, completed: true)],
            ),
          ],
        ),
      ]);

      expect(sets, hasLength(1));
      expect(sets.single.exerciseId, 'panca');
      expect(sets.single.weightKg, 90);
      // La data è quella della sessione: le serie non ne hanno una propria.
      expect(sets.single.at, DateTime.utc(2026, 7, 22, 16));
    });

    test('l\'e1RM è quello dei record, non una seconda formula', () {
      final set = lift(
        DateTime.utc(2026, 7, 22),
        exercise: 'panca',
        weightKg: 90,
        reps: 5,
      );

      expect(set.e1rm, closeTo(90 * (1 + 5 / 30), 0.0001));
    });
  });
}
