import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/body/domain/bia_formula.dart';

void main() {
  const formula = Deurenberg1991Formula();

  BiaInput input({
    double impedanceOhm = 480,
    double weightKg = 75,
    double heightCm = 180,
    int ageYears = 25,
    BiaSex sex = BiaSex.male,
  }) => BiaInput(
    impedanceOhm: impedanceOhm,
    weightKg: weightKg,
    heightCm: heightCm,
    ageYears: ageYears,
    sex: sex,
  );

  group('Katch-McArdle', () {
    test(
      'riproduce il BMR dichiarato dalla bilancia sui dati reali di Marco',
      () {
        // 71,66 kg di massa magra il 5 agosto 2026: la bilancia mostrava 1918.
        // La formula dà 1917,856, cioè 0,14 kcal di scarto. È il motivo per cui
        // Katch-McArdle è stata scelta al posto di Mifflin-St Jeor, che sugli
        // stessi dati sbaglia di 7-10 kcal e non segue la massa magra.
        expect(katchMcArdleBmr(71.66), 1918);
        expect(370 + 21.6 * 71.66, closeTo(1917.86, 0.01));
      },
    );

    test('dipende dalla massa magra e non dal peso', () {
      expect(katchMcArdleBmr(75) - katchMcArdleBmr(70), 108);
    });
  });

  group('Deurenberg 1991', () {
    test('si dichiara con versione ed equazione', () {
      expect(formula.version, 'bia-v1');
      expect(formula.label, 'Deurenberg 1991');
      expect(formula.rationale, isNotEmpty);
    });

    test('uomo di riferimento: i termini dell’equazione tornano a mano', () {
      // 0,34·(180²/480) + 15,34·1,80 + 0,273·75 − 0,127·25 + 4,56 − 12,44
      // = 22,950 + 27,612 + 20,475 − 3,175 + 4,56 − 12,44 = 59,982
      final estimate = formula.estimate(input())!;
      expect(estimate.fatFreeMassKg, closeTo(59.982, 0.001));
      expect(estimate.fatMassKg, closeTo(15.018, 0.001));
      expect(estimate.bodyFatPct, closeTo(20.024, 0.01));
      expect(estimate.formulaVersion, 'bia-v1');
    });

    test('donna di riferimento: il termine del sesso vale 0', () {
      final estimate = formula.estimate(
        input(
          impedanceOhm: 600,
          weightKg: 60,
          heightCm: 165,
          ageYears: 30,
          sex: BiaSex.female,
        ),
      )!;
      expect(estimate.fatFreeMassKg, closeTo(40.869, 0.001));
      expect(estimate.bodyFatPct, closeTo(31.886, 0.01));
    });

    test(
      'a parità di tutto il resto, uomo e donna differiscono di 4,56 kg',
      () {
        final male = formula.estimate(input())!;
        final female = formula.estimate(input(sex: BiaSex.female))!;
        expect(
          male.fatFreeMassKg - female.fatFreeMassKg,
          closeTo(4.56, 0.0001),
        );
      },
    );

    test('più resistenza vuol dire meno massa magra', () {
      final low = formula.estimate(input(impedanceOhm: 400))!;
      final high = formula.estimate(input(impedanceOhm: 600))!;
      expect(high.fatFreeMassKg, lessThan(low.fatFreeMassKg));
      expect(high.bodyFatPct, greaterThan(low.bodyFatPct));
    });

    test('l’età conta: dieci anni valgono 1,27 kg di massa magra', () {
      final young = formula.estimate(input(ageYears: 25))!;
      final older = formula.estimate(input(ageYears: 35))!;
      expect(young.fatFreeMassKg - older.fatFreeMassKg, closeTo(1.27, 0.0001));
    });

    test('l’acqua deriva dalla massa magra con la costante di idratazione', () {
      final estimate = formula.estimate(input())!;
      expect(
        estimate.totalBodyWaterL,
        closeTo(estimate.fatFreeMassKg * 0.732, 0.0001),
      );
      expect(
        estimate.waterPct,
        closeTo(estimate.totalBodyWaterL / 75 * 100, 0.0001),
      );
    });

    test(
      'il BMR della stima è quello di Katch-McArdle sulla sua massa magra',
      () {
        final estimate = formula.estimate(input())!;
        expect(estimate.bmrKcal, katchMcArdleBmr(estimate.fatFreeMassKg));
      },
    );

    test('fuori dal dominio non stima: tace', () {
      // Impedenza impossibile per una bilancia piede-piede: contatto
      // parziale o trama malinterpretata. Un numero qui avrebbe l'aria di una
      // misura.
      expect(formula.estimate(input(impedanceOhm: 0)), isNull);
      expect(formula.estimate(input(impedanceOhm: 40)), isNull);
      expect(formula.estimate(input(impedanceOhm: 1800)), isNull);
      expect(formula.estimate(input(heightCm: 40)), isNull);
      expect(formula.estimate(input(ageYears: 4)), isNull);
      expect(formula.estimate(input(weightKg: 5)), isNull);
    });

    test(
      'una combinazione che darebbe un grasso non fisiologico non stima',
      () {
        // Impedenza bassissima su un peso alto: l'equazione produrrebbe una
        // massa magra maggiore del peso. Si tace invece di troncare a zero.
        expect(
          formula.estimate(
            input(impedanceOhm: 155, weightKg: 45, heightCm: 200, ageYears: 20),
          ),
          isNull,
        );
      },
    );
  });

  group('registro delle formule', () {
    test('la corrente è la bia-v1 ed è raggiungibile per versione', () {
      expect(BiaFormulas.currentVersion, 'bia-v1');
      expect(BiaFormulas.byVersion('bia-v1'), isA<Deurenberg1991Formula>());
      expect(BiaFormulas.byVersion('bia-v99'), isNull);
      expect(BiaFormulas.byVersion(null), isNull);
    });

    test('riconosce le versioni nostre da quelle altrui', () {
      // La distinzione decide chi si può riscrivere: le righe senza versione
      // portano numeri dichiarati da altri (display Renpho, CSV) e non sono
      // nostre da rifare.
      expect(BiaFormulas.isOurs('bia-v1'), isTrue);
      expect(BiaFormulas.isOurs('bia-v2'), isTrue);
      expect(BiaFormulas.isOurs(null), isFalse);
      expect(BiaFormulas.isOurs('renpho-app'), isFalse);
    });
  });

  group('età alla pesata', () {
    final birth = DateTime.utc(1987, 9, 13);

    test('il compleanno non ancora arrivato vale un anno in meno', () {
      expect(ageYearsAt(birth, DateTime.utc(2026, 8, 5)), 38);
      expect(ageYearsAt(birth, DateTime.utc(2026, 9, 12)), 38);
      expect(ageYearsAt(birth, DateTime.utc(2026, 9, 13)), 39);
    });
  });

  group('dati del profilo', () {
    test(
      'senza altezza, nascita o sesso non si costruisce nessun ingresso',
      () {
        expect(
          biaInputFrom(
            heightCm: null,
            birthDate: DateTime.utc(1987, 9, 13),
            sexCode: 'M',
            weightKg: 95.8,
            impedanceOhm: 442,
            measuredAt: DateTime.utc(2026, 8, 5),
          ),
          isNull,
        );
        expect(
          biaInputFrom(
            heightCm: 182,
            birthDate: null,
            sexCode: 'M',
            weightKg: 95.8,
            impedanceOhm: 442,
            measuredAt: DateTime.utc(2026, 8, 5),
          ),
          isNull,
        );
        expect(
          biaInputFrom(
            heightCm: 182,
            birthDate: DateTime.utc(1987, 9, 13),
            sexCode: null,
            weightKg: 95.8,
            impedanceOhm: 442,
            measuredAt: DateTime.utc(2026, 8, 5),
          ),
          isNull,
        );
      },
    );

    test('senza impedenza non si costruisce nessun ingresso', () {
      expect(
        biaInputFrom(
          heightCm: 182,
          birthDate: DateTime.utc(1987, 9, 13),
          sexCode: 'M',
          weightKg: 95.8,
          impedanceOhm: null,
          measuredAt: DateTime.utc(2026, 8, 5),
        ),
        isNull,
      );
    });

    test('col profilo di Marco l’età è quella del giorno della pesata', () {
      final built = biaInputFrom(
        heightCm: 182,
        birthDate: DateTime.utc(1987, 9, 13),
        sexCode: 'm',
        weightKg: 95.8,
        impedanceOhm: 442,
        measuredAt: DateTime.utc(2026, 8, 5, 6, 30),
      )!;
      expect(built.ageYears, 38);
      expect(built.sex, BiaSex.male);
      expect(built.impedanceIndex, closeTo(33124 / 442, 0.0001));
    });
  });
}
