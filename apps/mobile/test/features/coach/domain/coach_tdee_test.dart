import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/coach/domain/coach_tdee.dart';
import 'package:kal_tracker/features/goal/domain/body_composition.dart';
import 'package:kal_tracker/features/goal/domain/tdee.dart';

import '../../goal/marco.dart';

WeeklyTdee measure({
  double? fatFreeMassKg = marcoFatFreeMass,
  double? averageDailyKcal = 2200,
  double? currentWeekAverageKg = 95,
  double? previousWeekAverageKg = 95.5,
  int diaryDays = 7,
  int weighInDays = 5,
}) => CoachTdee.measure(
  fatFreeMassKg: fatFreeMassKg,
  activity: ActivityLevel.moderate,
  averageDailyKcal: averageDailyKcal,
  currentWeekAverageKg: currentWeekAverageKg,
  previousWeekAverageKg: previousWeekAverageKg,
  diaryDays: diaryDays,
  weighInDays: weighInDays,
);

void main() {
  group('la formula', () {
    test('mezzo chilo perso in una settimana mangiando 2200 fa 2750 kcal', () {
      final tdee = measure();

      // 2200 − (−0,5 × 7700 / 7) = 2200 + 550
      expect(tdee.isMeasured, isTrue);
      expect(tdee.kcal, closeTo(2750, 0.01));
      expect(tdee.weightChangeKg, closeTo(-0.5, 0.001));
    });

    test('se il peso sale, il consumo è meno di quanto si è mangiato', () {
      final tdee = measure(
        currentWeekAverageKg: 95.5,
        previousWeekAverageKg: 95,
        averageDailyKcal: 3000,
      );

      // 3000 − (0,5 × 7700 / 7) = 3000 − 550
      expect(tdee.kcal, closeTo(2450, 0.01));
    });

    test('dietro il confronto ci sono quattordici giorni, non sette', () {
      final tdee = measure();

      expect(tdee.estimate.days, CoachTdee.daysBehindComparison);
      expect(tdee.estimate.explanation, contains('14'));
    });
  });

  group('quando la misura non vale', () {
    test('con poco diario resta la stima da basale × attività', () {
      final tdee = measure(diaryDays: 4);

      expect(tdee.isMeasured, isFalse);
      expect(
        tdee.kcal,
        closeTo(
          BodyComposition.basalMetabolicRate(marcoFatFreeMass) * 1.55,
          0.01,
        ),
      );
      expect(tdee.missingDataReason, contains('giorni di diario'));
    });

    test('con due sole pesate la media a 7 giorni non è una media', () {
      final tdee = measure(weighInDays: 2);

      expect(tdee.isMeasured, isFalse);
      expect(tdee.missingDataReason, contains('pesate'));
    });

    test('senza la settimana di confronto non c\'è nulla da sottrarre', () {
      final tdee = measure(previousWeekAverageKg: null);

      expect(tdee.isMeasured, isFalse);
      expect(tdee.weightChangeKg, isNull);
      expect(tdee.missingDataReason, contains('due settimane'));
    });

    test('tre chili di acqua in meno darebbero un consumo da maratoneta', () {
      // 2200 + 3 × 7700 / 7 = 5500 kcal: fuori scala, si torna alla stima.
      final tdee = measure(currentWeekAverageKg: 92.5);

      expect(tdee.isMeasured, isFalse);
      expect(tdee.estimate.fellBackBecauseImplausible, isTrue);
      expect(tdee.estimate.explanation, contains('fuori scala'));
      // La variazione resta visibile: il dato non si nasconde, si declassa.
      expect(tdee.weightChangeKg, closeTo(-3, 0.001));
      expect(tdee.missingDataReason, isNull);
    });

    test('senza massa magra non si può né misurare né stimare', () {
      final tdee = measure(fatFreeMassKg: null);

      expect(tdee.isMeasured, isFalse);
      expect(tdee.kcal, 0);
    });

    test('un digiuno totale non produce un consumo negativo', () {
      final tdee = measure(averageDailyKcal: 0);

      expect(tdee.isMeasured, isFalse);
      expect(tdee.kcal, greaterThan(0));
    });
  });
}
