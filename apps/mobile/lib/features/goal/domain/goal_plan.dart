import 'dart:math' as math;

import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/goal/domain/body_composition.dart';
import 'package:kal_tracker/features/goal/domain/goal.dart';
import 'package:kal_tracker/features/goal/domain/goal_feasibility.dart';
import 'package:kal_tracker/features/goal/domain/goal_pace.dart';
import 'package:kal_tracker/features/goal/domain/tdee.dart';

/// I numeri di oggi: quante calorie e quante proteine, adesso.
class GoalDailyTargets {
  const GoalDailyTargets({
    required this.calories,
    required this.protein,
    required this.carbs,
    required this.fat,
    required this.clampedToBasal,
  });

  final double calories;
  final double protein;
  final double carbs;
  final double fat;

  /// Il deficit avrebbe portato le calorie sotto il metabolismo basale e
  /// sono state rialzate. Va detto: significa che il ritmo chiesto non sta
  /// in piedi solo con il cibo.
  final bool clampedToBasal;
}

/// Il piano derivato da obiettivo + fase + TDEE. Tutto ricalcolabile, niente
/// da salvare: cambiando il traguardo cambia questo, non lo storico.
class GoalPlan {
  const GoalPlan({
    required this.goal,
    required this.currentWeightKg,
    required this.fatFreeMassKg,
    required this.tdee,
    required this.targets,
    required this.feasibility,
    required this.dailyDeficitKcal,
    required this.fatToLoseKg,
    required this.remainingDays,
    required this.progress,
    required this.estimatedDate,
    required this.band,
  });

  final Goal goal;
  final double currentWeightKg;
  final double fatFreeMassKg;
  final TdeeEstimate tdee;
  final GoalDailyTargets targets;
  final FeasibilityVerdict feasibility;

  /// Il deficit di oggi. In consolidamento scende di settimana in settimana,
  /// in mantenimento è zero.
  final double dailyDeficitKcal;

  final double fatToLoseKg;
  final int remainingDays;

  /// Da 0 a 1 sul percorso di *questo* obiettivo.
  final double progress;

  /// Il giorno stimato d'arrivo. Nullo in mantenimento: non c'è un arrivo.
  final DateTime? estimatedDate;

  /// La banda: solo in mantenimento.
  final MaintenanceBand? band;

  bool get isMaintenance => goal.phase == GoalPhase.maintenance;
}

/// Costruisce il piano. Funzione pura: stessi ingressi, stesse uscite,
/// nessuna lettura di orologio o di database qui dentro.
abstract final class GoalPlanner {
  /// Grammi di proteine per kg di **massa magra** (non di peso): con i
  /// 71,66 kg di Marco fanno 143 g al giorno.
  static const double proteinGramsPerKgFatFreeMass = 2;

  /// Quota di calorie che va ai grassi. Il resto sono carboidrati: sono
  /// loro a fare da cuscinetto quando il deficit cambia.
  static const double fatShareOfCalories = 0.25;

  /// Di quanto risale il consolidamento ogni settimana.
  static const double consolidationStepKcal = 100;

  static GoalPlan build({
    required Goal goal,
    required double currentWeightKg,
    required double fatFreeMassKg,
    required TdeeEstimate tdee,
    required DateTime today,
  }) {
    final feasibility = GoalFeasibility.assess(
      currentWeightKg: currentWeightKg,
      currentFatFreeMassKg: fatFreeMassKg,
      targetWeightKg: goal.targetWeightKg,
      targetLevel: goal.targetLevel,
    );

    final fatToLose = feasibility.fatToLoseKg;
    final deficit = _deficitFor(goal: goal, today: today);
    final targets = _targetsFor(
      tdee: tdee.kcal,
      fatFreeMassKg: fatFreeMassKg,
      dailyDeficitKcal: deficit,
    );

    final remainingDays = goal.phase == GoalPhase.approach
        ? GoalPace.daysToLose(
            fatToLoseKg: fatToLose,
            kgPerWeek: goal.paceKgPerWeek,
          )
        : 0;

    return GoalPlan(
      goal: goal,
      currentWeightKg: currentWeightKg,
      fatFreeMassKg: fatFreeMassKg,
      tdee: tdee,
      targets: targets,
      feasibility: feasibility,
      dailyDeficitKcal: deficit,
      fatToLoseKg: fatToLose,
      remainingDays: remainingDays,
      progress: progressOf(goal: goal, currentWeightKg: currentWeightKg),
      estimatedDate: goal.phase == GoalPhase.approach && remainingDays > 0
          ? shiftDays(today, remainingDays)
          : null,
      band: goal.phase == GoalPhase.maintenance
          ? MaintenanceBand.around(goal.targetWeightKg)
          : null,
    );
  }

  /// Il deficit della fase corrente.
  static double _deficitFor({required Goal goal, required DateTime today}) =>
      switch (goal.phase) {
        GoalPhase.approach => GoalPace.dailyDeficitKcal(goal.paceKgPerWeek),
        GoalPhase.consolidation => consolidationDeficit(
          startingDeficitKcal: GoalPace.dailyDeficitKcal(goal.paceKgPerWeek),
          weeksIntoPhase: weeksBetween(
            goal.phaseStartedAt ?? goal.startedAt,
            today,
          ),
        ),
        GoalPhase.maintenance => 0,
      };

  /// Il consolidamento non spegne il deficit di colpo: risale di
  /// [consolidationStepKcal] al giorno ogni settimana fino a zero.
  static double consolidationDeficit({
    required double startingDeficitKcal,
    required int weeksIntoPhase,
  }) {
    final reduced =
        startingDeficitKcal -
        consolidationStepKcal * math.max(0, weeksIntoPhase);
    return reduced > 0 ? reduced : 0;
  }

  /// Quante settimane servono per chiudere il consolidamento.
  static int consolidationWeeks(double startingDeficitKcal) =>
      startingDeficitKcal <= 0
      ? 0
      : (startingDeficitKcal / consolidationStepKcal).ceil();

  static GoalDailyTargets _targetsFor({
    required double tdee,
    required double fatFreeMassKg,
    required double dailyDeficitKcal,
  }) {
    final basal = BodyComposition.basalMetabolicRate(fatFreeMassKg);
    final wanted = tdee - dailyDeficitKcal;
    // Sotto il basale non si scende mai: il corpo non spegne il cuore per
    // rispettare una data.
    final clamped = wanted < basal;
    final calories = clamped ? basal : wanted;

    final protein = BodyComposition.proteinGrams(
      fatFreeMassKg: fatFreeMassKg,
      gramsPerKg: proteinGramsPerKgFatFreeMass,
    );
    final fat = calories * fatShareOfCalories / 9;
    final carbs = math.max(0.0, (calories - protein * 4 - fat * 9) / 4);

    return GoalDailyTargets(
      calories: calories,
      protein: protein,
      carbs: carbs,
      fat: fat,
      clampedToBasal: clamped,
    );
  }

  static double progressOf({
    required Goal goal,
    required double currentWeightKg,
  }) {
    final span = goal.startWeightKg - goal.targetWeightKg;
    if (span.abs() < 0.05) {
      return 1;
    }
    final done = (goal.startWeightKg - currentWeightKg) / span;
    return done.clamp(0.0, 1.0);
  }

  /// Settimane intere trascorse tra due istanti.
  static int weeksBetween(DateTime from, DateTime to) {
    final days = to.toUtc().difference(from.toUtc()).inDays;
    return days <= 0 ? 0 : days ~/ 7;
  }

  /// Somma giorni restando sul calendario di Roma: `Duration(days:)` da solo
  /// sbaglia di un'ora al cambio dell'ora legale, e su una stima a due mesi
  /// quell'ora diventa un giorno intero.
  static DateTime shiftDays(DateTime day, int days) => AppTime.inRome(
    AppTime.startOfDayUtc(day).add(Duration(days: days, hours: 12)),
  );
}

/// Il passaggio automatico da una fase all'altra: l'avvicinamento finisce
/// quando il traguardo è raggiunto, il consolidamento quando il deficit è
/// stato riassorbito. Il piano non si spegne mai da solo.
abstract final class GoalPhasePolicy {
  /// Tolleranza sull'arrivo: la bilancia oscilla, e aspettare il decimale
  /// esatto vorrebbe dire non arrivare mai.
  static const double arrivalToleranceKg = 0.3;

  static GoalPhase nextPhase({
    required Goal goal,
    required double currentWeightKg,
    required DateTime today,
  }) => switch (goal.phase) {
    GoalPhase.approach =>
      currentWeightKg <= goal.targetWeightKg + arrivalToleranceKg
          ? GoalPhase.consolidation
          : GoalPhase.approach,
    GoalPhase.consolidation =>
      GoalPlanner.weeksBetween(goal.phaseStartedAt ?? goal.startedAt, today) >=
              GoalPlanner.consolidationWeeks(
                GoalPace.dailyDeficitKcal(goal.paceKgPerWeek),
              )
          ? GoalPhase.maintenance
          : GoalPhase.consolidation,
    GoalPhase.maintenance => GoalPhase.maintenance,
  };
}
