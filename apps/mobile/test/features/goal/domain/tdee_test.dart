import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/goal/domain/body_composition.dart';
import 'package:kal_tracker/features/goal/domain/tdee.dart';

import '../marco.dart';

void main() {
  group('la misura sui dati reali', () {
    test('mangiare 2200 e perdere un chilo in 14 giorni fa 2750 kcal', () {
      const sample = TdeeSample(
        averageDailyKcal: 2200,
        weightChangeKg: -1,
        days: 14,
      );

      expect(AdaptiveTdee.fromRealData(sample), closeTo(2750, 0.01));
    });

    test('se il peso sale, il consumo è meno di quanto si è mangiato', () {
      const sample = TdeeSample(
        averageDailyKcal: 3000,
        weightChangeKg: 1,
        days: 14,
      );

      expect(AdaptiveTdee.fromRealData(sample), closeTo(2450, 0.01));
    });
  });

  group('quale dei due vale', () {
    test('senza dati vale la stima da basale × attività', () {
      final estimate = AdaptiveTdee.resolve(
        fatFreeMassKg: marcoFatFreeMass,
        activity: ActivityLevel.moderate,
      );

      expect(estimate.source, TdeeSource.estimated);
      expect(estimate.days, 0);
      expect(
        estimate.kcal,
        closeTo(
          BodyComposition.basalMetabolicRate(marcoFatFreeMass) * 1.55,
          0.01,
        ),
      );
      expect(estimate.explanation, contains('Stima'));
    });

    test('le prime due settimane la misura non basta ancora', () {
      const sample = TdeeSample(
        averageDailyKcal: 2200,
        weightChangeKg: -1,
        days: 10,
      );

      final estimate = AdaptiveTdee.resolve(
        fatFreeMassKg: marcoFatFreeMass,
        activity: ActivityLevel.moderate,
        sample: sample,
      );

      expect(estimate.source, TdeeSource.estimated);
      expect(sample.isUsable, isFalse);
    });

    test('da 14 giorni in poi la misura sostituisce la stima', () {
      final estimate = AdaptiveTdee.resolve(
        fatFreeMassKg: marcoFatFreeMass,
        activity: ActivityLevel.moderate,
        sample: const TdeeSample(
          averageDailyKcal: 2200,
          weightChangeKg: -1,
          days: 14,
        ),
      );

      expect(estimate.source, TdeeSource.measured);
      expect(estimate.kcal, closeTo(2750, 0.01));
      expect(estimate.days, 14);
      expect(estimate.explanation, contains('14 giorni'));
    });
  });

  group('difese contro i dati sbagliati', () {
    test(
      'una settimana con tre chili d\'acqua in meno non fa un maratoneta',
      () {
        // −5 kg in 14 giorni mangiando 2200: darebbe 4950 kcal di consumo,
        // oltre due volte e mezzo il basale. È acqua, non metabolismo.
        final estimate = AdaptiveTdee.resolve(
          fatFreeMassKg: marcoFatFreeMass,
          activity: ActivityLevel.moderate,
          sample: const TdeeSample(
            averageDailyKcal: 2200,
            weightChangeKg: -5,
            days: 14,
          ),
        );

        expect(estimate.source, TdeeSource.estimated);
        expect(estimate.fellBackBecauseImplausible, isTrue);
        expect(estimate.explanation, contains('acqua'));
      },
    );

    test('un consumo sotto il basale viene scartato allo stesso modo', () {
      final estimate = AdaptiveTdee.resolve(
        fatFreeMassKg: marcoFatFreeMass,
        activity: ActivityLevel.moderate,
        sample: const TdeeSample(
          averageDailyKcal: 1200,
          weightChangeKg: 0,
          days: 21,
        ),
      );

      expect(estimate.source, TdeeSource.estimated);
      expect(estimate.fellBackBecauseImplausible, isTrue);
    });

    test('un campione con calorie assurde non è utilizzabile', () {
      expect(
        const TdeeSample(
          averageDailyKcal: 0,
          weightChangeKg: -1,
          days: 30,
        ).isUsable,
        isFalse,
      );
      expect(
        const TdeeSample(
          averageDailyKcal: double.nan,
          weightChangeKg: -1,
          days: 30,
        ).isUsable,
        isFalse,
      );
    });
  });
}
