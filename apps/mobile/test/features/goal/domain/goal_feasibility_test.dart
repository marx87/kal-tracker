import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/goal/domain/definition_level.dart';
import 'package:kal_tracker/features/goal/domain/goal_feasibility.dart';

import '../marco.dart';

FeasibilityVerdict verdictFor(double targetWeightKg, DefinitionLevel level) =>
    GoalFeasibility.assess(
      currentWeightKg: marcoWeight,
      currentFatFreeMassKg: marcoFatFreeMass,
      targetWeightKg: targetWeightKg,
      targetLevel: level,
    );

void main() {
  group('sulla curva', () {
    test('«definito» al peso giusto si raggiunge perdendo solo grasso', () {
      final onCurve = DefinitionCurve.weightFor(
        level: DefinitionLevel.defined,
        fatFreeMassKg: marcoFatFreeMass,
      );
      final verdict = verdictFor(onCurve, DefinitionLevel.defined);

      expect(verdict.kind, FeasibilityKind.achievable);
      expect(verdict.isAchievable, isTrue);
      expect(verdict.fatFreeMassDeltaKg, closeTo(0, 0.001));
      expect(verdict.fatToLoseKg, closeTo(marcoWeight - onCurve, 0.001));
      expect(verdict.counterProposal, isNull);
    });

    test('mezzo chilo di scarto resta «sulla curva»', () {
      // 300 g di massa magra sono dentro il rumore della bilancia: un
      // avviso lì sarebbe un falso allarme, non un'informazione.
      final onCurve = DefinitionCurve.weightFor(
        level: DefinitionLevel.defined,
        fatFreeMassKg: marcoFatFreeMass,
      );
      final verdict = verdictFor(onCurve - 0.3, DefinitionLevel.defined);

      expect(verdict.kind, FeasibilityKind.achievable);
    });
  });

  group('sotto la curva: costerebbe muscolo', () {
    test('i «75 kg definito» della roadmap costano 4,9 kg di massa magra', () {
      final verdict = verdictFor(75, DefinitionLevel.defined);

      expect(verdict.kind, FeasibilityKind.needsMuscleLoss);
      expect(verdict.fatFreeMassDeltaKg, closeTo(-4.91, 0.01));
      expect(verdict.headline, contains('4,9'));
      expect(verdict.explanation, contains('sconsiglio'));
    });

    test('la controproposta è il peso che quella parola ha oggi', () {
      final verdict = verdictFor(75, DefinitionLevel.defined);

      expect(verdict.onCurveWeightKg, closeTo(80.52, 0.01));
      expect(verdict.counterProposal, contains('80,5'));
    });
  });

  group('sopra la curva: servirebbe costruirne', () {
    test('90 kg «definito» chiedono 8,4 kg di muscolo in più', () {
      final verdict = verdictFor(90, DefinitionLevel.defined);

      expect(verdict.kind, FeasibilityKind.needsMuscleGain);
      expect(verdict.fatFreeMassDeltaKg, closeTo(8.44, 0.01));
      expect(verdict.headline, contains('8,4'));
    });

    test('la controproposta è una fase di massa, non un deficit', () {
      final verdict = verdictFor(90, DefinitionLevel.defined);

      expect(verdict.counterProposal, contains('fase di massa'));
      expect(verdict.explanation, contains('Non è un deficit'));
    });
  });

  test('un traguardo più morbido di dove si è non ha grasso da perdere', () {
    // Stessa massa magra, ma partendo da 90 kg: il traguardo «morbido» sta
    // sopra, quindi non c'è niente da perdere.
    final verdict = GoalFeasibility.assess(
      currentWeightKg: 90,
      currentFatFreeMassKg: marcoFatFreeMass,
      targetWeightKg: DefinitionCurve.weightFor(
        level: DefinitionLevel.soft,
        fatFreeMassKg: marcoFatFreeMass,
      ),
      targetLevel: DefinitionLevel.soft,
    );

    expect(verdict.kind, FeasibilityKind.achievable);
    expect(verdict.fatDeltaKg, lessThan(0));
    // Il numero che alimenta i tempi non va mai sotto zero, altrimenti la
    // data stimata tornerebbe indietro nel tempo.
    expect(verdict.fatToLoseKg, 0);
  });
}
