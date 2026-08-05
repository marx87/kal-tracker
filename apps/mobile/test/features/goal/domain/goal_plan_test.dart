import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/goal/domain/body_composition.dart';
import 'package:kal_tracker/features/goal/domain/definition_level.dart';
import 'package:kal_tracker/features/goal/domain/goal.dart';
import 'package:kal_tracker/features/goal/domain/goal_plan.dart';
import 'package:kal_tracker/features/goal/domain/tdee.dart';

import '../marco.dart';

final DateTime _today = DateTime.utc(2026, 8, 5, 10);

const TdeeEstimate _measured = TdeeEstimate(
  kcal: 2750,
  source: TdeeSource.measured,
  days: 14,
);

Goal goalWith({
  GoalPhase phase = GoalPhase.approach,
  double paceKgPerWeek = 0.5,
  DateTime? phaseStartedAt,
  double targetWeightKg = 80.5,
}) => Goal(
  id: 'goal-1',
  targetWeightKg: targetWeightKg,
  targetLevel: DefinitionLevel.defined,
  paceKgPerWeek: paceKgPerWeek,
  startedAt: DateTime.utc(2026, 8, 5),
  startWeightKg: marcoWeight,
  startFatFreeMassKg: marcoFatFreeMass,
  phase: phase,
  phaseStartedAt: phaseStartedAt ?? DateTime.utc(2026, 8, 5),
);

GoalPlan planWith({
  GoalPhase phase = GoalPhase.approach,
  double currentWeightKg = marcoWeight,
  double paceKgPerWeek = 0.5,
  DateTime? phaseStartedAt,
  TdeeEstimate tdee = _measured,
}) => GoalPlanner.build(
  goal: goalWith(
    phase: phase,
    paceKgPerWeek: paceKgPerWeek,
    phaseStartedAt: phaseStartedAt,
  ),
  currentWeightKg: currentWeightKg,
  fatFreeMassKg: marcoFatFreeMass,
  tdee: tdee,
  today: _today,
);

void main() {
  setUp(AppTime.initialize);

  group('avvicinamento', () {
    test('deficit, grasso da perdere e data stimata stanno insieme', () {
      final plan = planWith();

      expect(plan.dailyDeficitKcal, closeTo(550, 0.01));
      expect(plan.fatToLoseKg, closeTo(15, 0.01));
      // 15 kg a mezzo chilo la settimana: trenta settimane.
      expect(plan.remainingDays, 210);
      expect(plan.estimatedDate, isNotNull);
      expect(plan.estimatedDate!.difference(_today).inDays, closeTo(210, 1));
    });

    test('le calorie sono il consumo meno il deficit', () {
      final plan = planWith();

      expect(plan.targets.calories, closeTo(2200, 0.01));
      expect(plan.targets.clampedToBasal, isFalse);
    });

    test('le proteine sono i 143 g di Marco, sulla massa magra', () {
      final plan = planWith();

      expect(plan.targets.protein.round(), 143);
    });

    test('cambiare ritmo ricalcola deficit e data, non il traguardo', () {
      final slow = planWith(paceKgPerWeek: 0.3);
      final fast = planWith(paceKgPerWeek: 0.65);

      expect(slow.goal.targetWeightKg, fast.goal.targetWeightKg);
      expect(slow.fatToLoseKg, closeTo(fast.fatToLoseKg, 0.001));
      expect(fast.dailyDeficitKcal, greaterThan(slow.dailyDeficitKcal));
      expect(fast.remainingDays, lessThan(slow.remainingDays));
    });

    test('il progresso si misura sul percorso di questo obiettivo', () {
      expect(planWith().progress, 0);
      expect(planWith(currentWeightKg: 88).progress, closeTo(0.5, 0.01));
      expect(planWith(currentWeightKg: 79).progress, 1);
    });

    test('sotto il metabolismo basale non si scende', () {
      // Consumo basso e ritmo alto: la sottrazione darebbe 1250 kcal.
      final plan = planWith(
        paceKgPerWeek: 0.65,
        tdee: const TdeeEstimate(
          kcal: 2000,
          source: TdeeSource.estimated,
          days: 0,
        ),
      );

      expect(plan.targets.clampedToBasal, isTrue);
      expect(
        plan.targets.calories,
        closeTo(BodyComposition.basalMetabolicRate(marcoFatFreeMass), 0.01),
      );
    });
  });

  group('consolidamento', () {
    test('il deficit risale di 100 kcal a settimana', () {
      expect(
        GoalPlanner.consolidationDeficit(
          startingDeficitKcal: 550,
          weeksIntoPhase: 0,
        ),
        550,
      );
      expect(
        GoalPlanner.consolidationDeficit(
          startingDeficitKcal: 550,
          weeksIntoPhase: 3,
        ),
        250,
      );
      expect(
        GoalPlanner.consolidationDeficit(
          startingDeficitKcal: 550,
          weeksIntoPhase: 9,
        ),
        0,
      );
    });

    test(
      'dopo tre settimane si mangia 300 kcal in più di quando è iniziato',
      () {
        final plan = planWith(
          phase: GoalPhase.consolidation,
          phaseStartedAt: _today.subtract(const Duration(days: 21)),
        );

        expect(plan.dailyDeficitKcal, closeTo(250, 0.01));
        expect(plan.targets.calories, closeTo(2500, 0.01));
        // In consolidamento non c'è una data d'arrivo: si è già arrivati.
        expect(plan.estimatedDate, isNull);
      },
    );

    test('la fase dura quanto serve a riassorbire il deficit', () {
      expect(GoalPlanner.consolidationWeeks(550), 6);
      expect(GoalPlanner.consolidationWeeks(0), 0);
    });
  });

  group('mantenimento', () {
    test('nessun deficit, e una banda al posto di un numero', () {
      final plan = planWith(
        phase: GoalPhase.maintenance,
        currentWeightKg: 80.4,
      );

      expect(plan.dailyDeficitKcal, 0);
      expect(plan.targets.calories, closeTo(2750, 0.01));
      expect(plan.band, isNotNull);
      expect(plan.band!.label, '79,5 – 81,5 kg');
      expect(plan.isMaintenance, isTrue);
    });
  });

  group('il passaggio di fase è automatico', () {
    test('l\'avvicinamento finisce quando si arriva', () {
      final goal = goalWith();

      expect(
        GoalPhasePolicy.nextPhase(
          goal: goal,
          currentWeightKg: 95.5,
          today: _today,
        ),
        GoalPhase.approach,
      );
      expect(
        GoalPhasePolicy.nextPhase(
          goal: goal,
          currentWeightKg: 80.6,
          today: _today,
        ),
        GoalPhase.consolidation,
      );
    });

    test('il consolidamento finisce quando il deficit è riassorbito', () {
      final goal = goalWith(
        phase: GoalPhase.consolidation,
        phaseStartedAt: _today.subtract(const Duration(days: 14)),
      );
      final finished = goalWith(
        phase: GoalPhase.consolidation,
        phaseStartedAt: _today.subtract(const Duration(days: 45)),
      );

      expect(
        GoalPhasePolicy.nextPhase(
          goal: goal,
          currentWeightKg: 80.5,
          today: _today,
        ),
        GoalPhase.consolidation,
      );
      expect(
        GoalPhasePolicy.nextPhase(
          goal: finished,
          currentWeightKg: 80.5,
          today: _today,
        ),
        GoalPhase.maintenance,
      );
    });

    test('dal mantenimento non si esce da soli', () {
      expect(
        GoalPhasePolicy.nextPhase(
          goal: goalWith(phase: GoalPhase.maintenance),
          currentWeightKg: 95,
          today: _today,
        ),
        GoalPhase.maintenance,
      );
    });
  });

  test('un traguardo fuori curva porta il suo verdetto dentro il piano', () {
    final plan = GoalPlanner.build(
      goal: goalWith(targetWeightKg: 75),
      currentWeightKg: marcoWeight,
      fatFreeMassKg: marcoFatFreeMass,
      tdee: _measured,
      today: _today,
    );

    expect(plan.feasibility.isAchievable, isFalse);
    expect(plan.feasibility.fatFreeMassDeltaKg, lessThan(-4));
  });
}
