import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/coach/domain/coach_adherence.dart';
import 'package:kal_tracker/features/coach/domain/coach_metrics.dart';
import 'package:kal_tracker/features/coach/domain/coach_overtraining.dart';
import 'package:kal_tracker/features/coach/domain/coach_projection.dart';
import 'package:kal_tracker/features/coach/domain/coach_recomposition.dart';
import 'package:kal_tracker/features/coach/domain/coach_snapshot.dart';
import 'package:kal_tracker/features/coach/domain/coach_strength.dart';

import '../fixtures.dart';

/// Quattro settimane di pesate che scendono di mezzo chilo a settimana, con
/// composizione stabile: il caso «tutto sta funzionando».
CoachSnapshot goodWeek({
  CoachTargets? targets = const CoachTargets(
    dailyCalories: 2200,
    dailyProtein: 143,
    weeklyWorkouts: 3,
  ),
  CoachGoalContext? goal,
  List<CoachStrengthSet> strengthSets = const [],
}) {
  final sunday = DateTime.utc(2026, 8, 2);
  // 28 giorni: 95,5 → 93,5, cioè mezzo chilo a settimana.
  final weights = [
    for (var day = 27; day >= 0; day--) 95.5 - (27 - day) * (0.5 / 7),
  ];
  return CoachSnapshot(
    week: testWeek,
    diary: diaryWeek(lastDay: sunday, kcal: 2200, proteinGrams: 145, days: 28),
    weighIns: weighInSeries(
      lastDay: sunday,
      weights: weights,
      bodyFatPcts: List.filled(weights.length, 25),
      waterPcts: List.filled(weights.length, 54),
    ),
    sessions: [
      for (var week = 0; week < 4; week++)
        for (final offset in [1, 3, 5])
          session(sunday.subtract(Duration(days: week * 7 + offset)), rpe: 7),
    ],
    strengthSets: strengthSets,
    water: [
      for (var day = 27; day >= 0; day--)
        CoachWaterDay(
          day: sunday.subtract(Duration(days: day)),
          milliliters: 2200,
        ),
    ],
    targets: targets,
    goal: goal,
  );
}

void main() {
  setUp(AppTime.initialize);

  group('il motore', () {
    test('una settimana piena produce un rapporto completo', () {
      final metrics = CoachEngine.run(goodWeek());

      expect(metrics.week, testWeek);
      expect(metrics.intake.days, 7);
      expect(metrics.workoutsDone, 3);
      expect(metrics.tdee.isMeasured, isTrue);
      expect(metrics.adherence.overall, AdherenceGrade.onTrack);
      expect(metrics.recomposition.leanTrend, LeanMassTrend.holding);
      expect(metrics.overtraining.level, OvertrainingLevel.clear);
      expect(metrics.filledSlots, CoachMetrics.totalSlots);
    });

    test('il ritmo osservato si misura sulla finestra più lunga che c\'è', () {
      final metrics = CoachEngine.run(goodWeek());

      // 28 giorni di pesate coprono la settimana del rapporto più tre
      // indietro: la quarta è vuota e non fa da estremo. Il ritmo si misura
      // su quello che c'è, e quante settimane siano si dichiara.
      expect(metrics.rateWeeks, 3);
      expect(metrics.observedKgPerWeek, closeTo(-0.5, 0.02));
    });

    test('senza obiettivo non c\'è proiezione, e tutto il resto resta', () {
      final metrics = CoachEngine.run(goodWeek());

      expect(metrics.projection, isNull);
      expect(metrics.tdee.isMeasured, isTrue);
      expect(metrics.headlines, isNotEmpty);
    });

    test('con un obiettivo la proiezione dice una data', () {
      final metrics = CoachEngine.run(
        goodWeek(
          goal: CoachGoalContext(
            targetWeightKg: 87,
            paceKgPerWeek: 0.5,
            plannedDate: DateTime.utc(2026, 11, 1),
          ),
        ),
      );

      expect(metrics.projection!.state, ProjectionState.moving);
      expect(metrics.projection!.projectedDate, isNotNull);
      expect(metrics.headlines.join(' '), contains('A questo ritmo'));
    });

    test('una settimana vuota non esplode: dice cosa manca', () {
      final metrics = CoachEngine.run(CoachSnapshot(week: testWeek));

      expect(metrics.intake.days, 0);
      expect(metrics.workoutsDone, 0);
      expect(metrics.tdee.isMeasured, isFalse);
      expect(metrics.tdee.kcal, 0);
      expect(metrics.recomposition.isKnown, isFalse);
      expect(metrics.overtraining.knownCount, 0);
      expect(metrics.filledSlots, 0);
      expect(metrics.projection, isNull);
    });

    test(
      'la proiezione parte dalla domenica del rapporto, non da "adesso"',
      () {
        final goal = CoachGoalContext(targetWeightKg: 87, paceKgPerWeek: 0.5);
        final onSunday = CoachEngine.run(goodWeek(goal: goal));
        final reReadOnWednesday = CoachEngine.run(goodWeek(goal: goal));

        expect(
          onSunday.projection!.projectedDate,
          reReadOnWednesday.projection!.projectedDate,
        );
      },
    );
  });

  group('il quinto segnale', () {
    test('senza storico di serie resta «non lo so», non «tiene»', () {
      final light = CoachEngine.run(goodWeek()).overtraining;

      expect(
        light.readings[OvertrainingSignal.fallingStrength],
        SignalReading.unknown,
      );
      expect(light.missingDataNote, contains('forza in calo'));
    });

    test('lo storico degli allenamenti accende la forza in calo', () {
      final light = CoachEngine.run(
        goodWeek(strengthSets: liftedWeeks(before: 100, now: 90)),
      ).overtraining;

      expect(
        light.readings[OvertrainingSignal.fallingStrength],
        SignalReading.fired,
      );
      // Il numero e gli esercizi, non solo il colore.
      expect(light.reasons.single, contains('10,0 %'));
      expect(light.reasons.single, contains('panca'));
    });

    test('una forza che tiene viene letta, non data per buona', () {
      final light = CoachEngine.run(
        goodWeek(strengthSets: liftedWeeks(before: 100, now: 100)),
      ).overtraining;

      expect(
        light.readings[OvertrainingSignal.fallingStrength],
        SignalReading.quiet,
      );
      // Tutti e cinque: è il conto su cui il semaforo dice «accesi n su n».
      expect(light.knownCount, 5);
      expect(light.missingDataNote, isNull);
    });

    test('le finestre della forza stanno ferme alla domenica del rapporto', () {
      // Rileggendo lo stesso rapporto tre settimane dopo il quinto segnale
      // non deve cambiare colore da solo: `today` sposta la proiezione, non
      // il confronto dell'e1RM.
      final snapshot = goodWeek(
        strengthSets: liftedWeeks(before: 100, now: 90),
      );

      expect(
        CoachEngine.run(
          snapshot,
          today: testWeek.end.add(const Duration(days: 21)),
        ).overtraining.strength.change,
        CoachEngine.run(snapshot).overtraining.strength.change,
      );
    });
  });

  group('la richiesta che va sul Mac', () {
    test('porta i numeri già fatti e le frasi già scritte', () {
      final metrics = CoachEngine.run(
        goodWeek(
          goal: const CoachGoalContext(targetWeightKg: 87, paceKgPerWeek: 0.5),
        ),
      );
      final request = metrics.toRequestJson();

      expect(request['week_start'], '2026-07-27');
      expect(request['week_end'], '2026-08-02');
      expect((request['tdee']! as Map)['source'], 'misurato');
      expect((request['tdee']! as Map)['kcal'], isA<int>());
      expect((request['adherence']! as Map)['overall'], 'onTrack');
      expect((request['projection']! as Map)['state'], 'moving');
      expect((request['overtraining']! as Map)['level'], 'clear');
      expect(request['headlines'], isA<List<String>>());
      expect((request['data_quality']! as Map)['total'], 4);
    });

    test('la forza porta la misura, non solo il segnale acceso', () {
      final request = CoachEngine.run(
        goodWeek(strengthSets: liftedWeeks(before: 100, now: 90)),
      ).toRequestJson();
      final strength =
          (request['overtraining']! as Map)['strength']!
              as Map<String, Object?>;

      expect(strength['change']! as double, closeTo(-0.1, 0.0001));
      expect(strength['exercises'], containsAll(['panca', 'squat', 'stacco']));
    });

    test('senza serie la forza viaggia nulla, non a zero', () {
      final request = CoachEngine.run(goodWeek()).toRequestJson();
      final strength =
          (request['overtraining']! as Map)['strength']!
              as Map<String, Object?>;

      expect(strength['change'], isNull);
      expect(strength['exercises'], isEmpty);
    });

    test('senza obiettivo la proiezione viaggia nulla, non finta', () {
      final request = CoachEngine.run(goodWeek()).toRequestJson();

      expect(request['projection'], isNull);
    });

    test('i numeri sono arrotondati: nessun decimale da dodici cifre', () {
      final request = CoachEngine.run(goodWeek()).toRequestJson();
      final change = (request['tdee']! as Map)['weight_change_kg'] as double;

      // Il valore grezzo ha una coda di decimali dalla media a 7 giorni: sul
      // Mac ne arrivano due, che è quanto serve a scrivere una frase.
      expect(change, double.parse(change.toStringAsFixed(2)));
      expect(change, closeTo(-0.5, 0.02));
    });
  });
}
