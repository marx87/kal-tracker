import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/goal/domain/goal_pace.dart';

import '../marco.dart';

void main() {
  group('limite di sicurezza', () {
    test('per Marco lo 0,7 % del peso fa 0,67 kg a settimana', () {
      expect(
        GoalPace.safeMaximumKgPerWeek(marcoWeight),
        closeTo(0.6685, 0.0001),
      );
    });

    test('è una frazione del peso, non un numero fisso', () {
      // 0,5 kg a settimana è prudente a 95 kg e aggressivo a 60: un limite
      // in chili assoluti proteggerebbe solo le persone grandi.
      expect(
        GoalPace.safeMaximumKgPerWeek(60),
        lessThan(GoalPace.safeMaximumKgPerWeek(marcoWeight)),
      );
    });

    test('un ritmo dentro il limite passa senza commenti', () {
      final verdict = GoalPace.assess(
        currentWeightKg: marcoWeight,
        requestedKgPerWeek: 0.5,
      );

      expect(verdict.accepted, isTrue);
      expect(verdict.appliedKgPerWeek, 0.5);
      expect(verdict.refusal, isNull);
    });

    test('un chilo a settimana viene RIFIUTATO, spiegato e controproposto', () {
      final verdict = GoalPace.assess(
        currentWeightKg: marcoWeight,
        requestedKgPerWeek: 1,
      );

      expect(verdict.accepted, isFalse);
      // Il ritmo non viene applicato di nascosto al massimo: resta chiaro
      // che è stato chiesto altro.
      expect(verdict.requestedKgPerWeek, 1);
      expect(verdict.appliedKgPerWeek, closeTo(0.6685, 0.0001));
      expect(verdict.refusal, contains('oltre il limite'));
      expect(verdict.counterProposal, contains('0,67'));
      expect(verdict.counterProposal, contains('kcal'));
    });

    test('anche un ritmo troppo lento viene rifiutato', () {
      final verdict = GoalPace.assess(
        currentWeightKg: marcoWeight,
        requestedKgPerWeek: 0.01,
      );

      expect(verdict.accepted, isFalse);
      expect(verdict.refusal, contains('oscillazioni'));
    });
  });

  group('deficit', () {
    test('mezzo chilo a settimana sono 550 kcal al giorno', () {
      expect(GoalPace.dailyDeficitKcal(0.5), closeTo(550, 0.001));
    });

    test('il massimo sicuro di Marco sono circa 735 kcal', () {
      expect(
        GoalPace.dailyDeficitKcal(GoalPace.safeMaximumKgPerWeek(marcoWeight)),
        closeTo(735.35, 0.01),
      );
    });
  });

  group('dalla scadenza al ritmo', () {
    test('una data ragionevole produce un ritmo accettato', () {
      // 8 kg in sei mesi: circa 0,3 kg a settimana.
      final verdict = GoalPace.fromDeadline(
        currentWeightKg: marcoWeight,
        fatToLoseKg: 8,
        days: 180,
      );

      expect(verdict.accepted, isTrue);
      expect(verdict.appliedKgPerWeek, closeTo(0.311, 0.001));
    });

    test('una data troppo vicina viene rifiutata con la data onesta', () {
      // 8 kg in 28 giorni sarebbero 2 kg a settimana.
      final verdict = GoalPace.fromDeadline(
        currentWeightKg: marcoWeight,
        fatToLoseKg: 8,
        days: 28,
      );

      expect(verdict.accepted, isFalse);
      expect(verdict.requestedKgPerWeek, closeTo(2, 0.001));
      // La controproposta è espressa in giorni, non in chili: l'aderenza si
      // comunica come distanza dalla data.
      expect(verdict.counterProposal, contains('giorni'));
      expect(verdict.counterProposal, contains('in più'));
    });

    test('una data nel passato non produce un ritmo', () {
      final verdict = GoalPace.fromDeadline(
        currentWeightKg: marcoWeight,
        fatToLoseKg: 8,
        days: 0,
      );

      expect(verdict.accepted, isFalse);
      expect(verdict.refusal, contains('data futura'));
    });
  });

  group('giorni necessari', () {
    test('si arrotondano per eccesso', () {
      // 8 kg a 0,67 la settimana sono 83,6 giorni: 84, non 83.
      expect(GoalPace.daysToLose(fatToLoseKg: 8, kgPerWeek: 0.6685), 84);
    });

    test('senza grasso da perdere sono zero, non infinito', () {
      expect(GoalPace.daysToLose(fatToLoseKg: 0, kgPerWeek: 0.5), 0);
      expect(GoalPace.daysToLose(fatToLoseKg: -2, kgPerWeek: 0.5), 0);
    });

    test('un ritmo assurdo non produce una divisione per zero', () {
      expect(GoalPace.daysToLose(fatToLoseKg: 5, kgPerWeek: 0), greaterThan(0));
    });
  });

  group('i ritmi detti a parole', () {
    test('non mostrano mai una percentuale', () {
      for (final choice in PaceChoice.values) {
        expect(choice.label, isNot(contains('%')));
        expect(choice.description, isNot(contains('%')));
      }
    });

    test('«deciso» coincide con il massimo sicuro', () {
      expect(
        PaceChoice.firm.kgPerWeekFor(marcoWeight),
        closeTo(GoalPace.safeMaximumKgPerWeek(marcoWeight), 0.0001),
      );
    });

    test('un ritmo qualunque si ritrova nel nome più vicino', () {
      expect(
        PaceChoice.nearest(currentWeightKg: marcoWeight, kgPerWeek: 0.48),
        PaceChoice.steady,
      );
      expect(
        PaceChoice.nearest(currentWeightKg: marcoWeight, kgPerWeek: 0.30),
        PaceChoice.calm,
      );
      expect(
        PaceChoice.nearest(currentWeightKg: marcoWeight, kgPerWeek: 0.70),
        PaceChoice.firm,
      );
    });
  });
}
