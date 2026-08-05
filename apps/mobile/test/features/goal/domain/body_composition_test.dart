import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/goal/domain/body_composition.dart';

import '../marco.dart';

void main() {
  group('Katch-McArdle', () {
    test('riproduce il BMR dichiarato dalla bilancia', () {
      final bmr = BodyComposition.basalMetabolicRate(marcoFatFreeMass);

      // Renpho dichiara 1918 kcal sugli stessi dati: la formula non è una
      // stima nostra, è la stessa che usa la bilancia.
      expect(bmr, closeTo(1917.9, 0.1));
      expect((bmr - renphoDeclaredBmr).abs(), lessThan(0.2));
    });

    test('dipende dalla massa magra e non dal peso', () {
      // Due corpi da 88 kg con muscolo diverso: la formula li distingue,
      // ed è il motivo per cui Mifflin-St Jeor è stata scartata.
      final muscular = BodyComposition.basalMetabolicRate(
        BodyComposition.fatFreeMassKg(weightKg: 88, bodyFatPct: 15),
      );
      final soft = BodyComposition.basalMetabolicRate(
        BodyComposition.fatFreeMassKg(weightKg: 88, bodyFatPct: 28),
      );

      expect(muscular - soft, closeTo(21.6 * 88 * 0.13, 0.01));
    });

    test('rifiuta una massa magra fuori scala invece di dare un numero', () {
      expect(
        () => BodyComposition.basalMetabolicRate(double.nan),
        throwsArgumentError,
      );
      expect(() => BodyComposition.basalMetabolicRate(2), throwsArgumentError);
    });
  });

  group('masse', () {
    test('grasso e massa magra sommano al peso', () {
      const weight = 95.5;
      const pct = 25.0;
      final fat = BodyComposition.fatMassKg(weightKg: weight, bodyFatPct: pct);
      final lean = BodyComposition.fatFreeMassKg(
        weightKg: weight,
        bodyFatPct: pct,
      );

      expect(fat, closeTo(23.875, 0.0001));
      expect(fat + lean, closeTo(weight, 0.0001));
    });

    test('percentuale e peso sono l\'uno l\'inverso dell\'altro', () {
      final weight = BodyComposition.weightAtBodyFat(
        fatFreeMassKg: marcoFatFreeMass,
        bodyFatPct: 11,
      );
      final backToPct = BodyComposition.bodyFatPct(
        weightKg: weight,
        fatFreeMassKg: marcoFatFreeMass,
      );

      expect(weight, closeTo(80.52, 0.01));
      expect(backToPct, closeTo(11, 0.0001));
    });

    test('oltre il 75 % di grasso il peso calcolato non ha più senso', () {
      expect(
        () => BodyComposition.weightAtBodyFat(
          fatFreeMassKg: marcoFatFreeMass,
          bodyFatPct: 80,
        ),
        throwsArgumentError,
      );
    });
  });

  group('proteine', () {
    test('2 g per kg di massa magra fanno i 143 g al giorno di Marco', () {
      final grams = BodyComposition.proteinGrams(
        fatFreeMassKg: marcoFatFreeMass,
        gramsPerKg: 2,
      );

      expect(grams, closeTo(143.32, 0.01));
      expect(grams.round(), 143);
    });

    test('si calcolano sulla massa magra, non sul peso', () {
      // A 95,5 kg di peso 2 g/kg farebbero 191 g: quaranta grammi di
      // differenza al giorno, tutti chiesti al grasso, che non li usa.
      final onFatFreeMass = BodyComposition.proteinGrams(
        fatFreeMassKg: marcoFatFreeMass,
        gramsPerKg: 2,
      );

      expect(onFatFreeMass, lessThan(95.5 * 2));
    });
  });

  test('il BMI resta un calcolo, non una colonna', () {
    expect(
      BodyComposition.bodyMassIndex(weightKg: 95.5, heightCm: 182),
      closeTo(28.83, 0.01),
    );
    expect(
      () => BodyComposition.bodyMassIndex(weightKg: 95.5, heightCm: 10),
      throwsArgumentError,
    );
  });
}
