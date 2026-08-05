import 'package:flutter/foundation.dart';
import 'package:kal_tracker/features/coach/domain/coach_dates.dart';

/// Come sta andando il viaggio verso il traguardo.
enum ProjectionState {
  /// Si sta scendendo e c'è una data.
  moving,

  /// Il ritmo osservato è fermo o va nel verso sbagliato: nessuna data.
  stalled,

  /// Già arrivati (o dentro la tolleranza).
  arrived,

  /// Manca il ritmo osservato o la media a 7 giorni.
  unknown,
}

/// **La proiezione del traguardo.**
///
/// Si comunica come **distanza dalla data**, mai come colpa: «a questo ritmo
/// arrivi il 2 dicembre, due settimane dopo il previsto» dice esattamente
/// quanto costa il ritmo attuale e lascia a Marco la scelta, mentre «hai
/// sgarrato» non dice niente e basta.
@immutable
class GoalProjection {
  const GoalProjection({
    required this.state,
    required this.targetWeightKg,
    this.currentAverageKg,
    this.observedKgPerWeek,
    this.plannedKgPerWeek,
    this.weeksObserved = 0,
    this.plannedDate,
    this.projectedDate,
  });

  const GoalProjection.unknown()
    : state = ProjectionState.unknown,
      targetWeightKg = 0,
      currentAverageKg = null,
      observedKgPerWeek = null,
      plannedKgPerWeek = null,
      weeksObserved = 0,
      plannedDate = null,
      projectedDate = null;

  final ProjectionState state;
  final double targetWeightKg;

  /// La media a 7 giorni di adesso: è da qui che parte la proiezione, non
  /// dalla pesata di stamattina.
  final double? currentAverageKg;

  /// Il ritmo che si sta davvero tenendo, in kg a settimana. Negativo se si
  /// sta scendendo.
  final double? observedKgPerWeek;

  /// Il ritmo che l'obiettivo aveva promesso, sempre come numero positivo.
  final double? plannedKgPerWeek;

  /// Su quante settimane è stato misurato il ritmo osservato.
  final int weeksObserved;

  final DateTime? plannedDate;
  final DateTime? projectedDate;

  double? get remainingKg {
    final current = currentAverageKg;
    return current == null ? null : current - targetWeightKg;
  }

  /// Settimane di ritardo rispetto alla data promessa. Negativo = in
  /// anticipo. Nullo se una delle due date manca.
  int? get weeksLate {
    final planned = plannedDate;
    final projected = projectedDate;
    if (planned == null || projected == null) {
      return null;
    }
    return (projected.difference(planned).inDays / 7).round();
  }

  /// La frase del rapporto. Deterministica: il modello non la riscrive.
  String get headline => switch (state) {
    ProjectionState.unknown =>
      'Non ho abbastanza pesate per dire a che ritmo stai andando.',
    ProjectionState.arrived => 'Ci sei: la media a 7 giorni è al traguardo.',
    ProjectionState.stalled =>
      'A questo ritmo non ci arrivi: nelle ultime '
          '${coachWeeksLabel(weeksObserved)} la media a 7 giorni non è '
          'scesa.',
    ProjectionState.moving => _movingHeadline(),
  };

  String _movingHeadline() {
    final date = projectedDate;
    if (date == null) {
      return 'Stai scendendo.';
    }
    final base =
        'A questo ritmo arrivi a ${coachNumber(targetWeightKg)} kg il '
        '${coachDayLabel(date)}';
    final late = weeksLate;
    if (late == null) {
      return '$base.';
    }
    if (late == 0) {
      return '$base, in linea con il previsto.';
    }
    return late > 0
        ? '$base, ${coachWeeksLabel(late)} dopo il previsto.'
        : '$base, ${coachWeeksLabel(late)} prima del previsto.';
  }
}

/// Il calcolo della proiezione. Funzione pura: la data di oggi entra come
/// parametro, non si legge un orologio qui dentro.
abstract final class CoachProjection {
  /// Sotto questo ritmo settimanale non si sta scendendo, si sta oscillando:
  /// proiettare una data su un movimento così sarebbe fantascienza.
  static const double minimumKgPerWeek = 0.05;

  /// Quando la media a 7 giorni è entro questa distanza dal traguardo si
  /// considera arrivati: aspettare il decimale esatto vuol dire non arrivare
  /// mai.
  static const double arrivalToleranceKg = 0.3;

  /// Tetto alla proiezione. Oltre due anni la data non è un'informazione, è
  /// una presa in giro.
  static const int maximumWeeks = 104;

  static GoalProjection project({
    required double targetWeightKg,
    required double? currentAverageKg,
    required double? observedKgPerWeek,
    required int weeksObserved,
    required DateTime today,
    double? plannedKgPerWeek,
    DateTime? plannedDate,
  }) {
    if (currentAverageKg == null || observedKgPerWeek == null) {
      return GoalProjection(
        state: ProjectionState.unknown,
        targetWeightKg: targetWeightKg,
        currentAverageKg: currentAverageKg,
        observedKgPerWeek: observedKgPerWeek,
        plannedKgPerWeek: plannedKgPerWeek,
        weeksObserved: weeksObserved,
        plannedDate: plannedDate,
      );
    }

    final remaining = currentAverageKg - targetWeightKg;
    if (remaining.abs() <= arrivalToleranceKg) {
      return GoalProjection(
        state: ProjectionState.arrived,
        targetWeightKg: targetWeightKg,
        currentAverageKg: currentAverageKg,
        observedKgPerWeek: observedKgPerWeek,
        plannedKgPerWeek: plannedKgPerWeek,
        weeksObserved: weeksObserved,
        plannedDate: plannedDate,
        projectedDate: today,
      );
    }

    // Il verso conta: per scendere serve un ritmo negativo, per salire uno
    // positivo. Un ritmo del verso sbagliato non allunga la data, la toglie.
    final needsToDrop = remaining > 0;
    final speed = needsToDrop ? -observedKgPerWeek : observedKgPerWeek;
    if (speed < minimumKgPerWeek) {
      return GoalProjection(
        state: ProjectionState.stalled,
        targetWeightKg: targetWeightKg,
        currentAverageKg: currentAverageKg,
        observedKgPerWeek: observedKgPerWeek,
        plannedKgPerWeek: plannedKgPerWeek,
        weeksObserved: weeksObserved,
        plannedDate: plannedDate,
      );
    }

    final weeks = (remaining.abs() / speed).ceil();
    if (weeks > maximumWeeks) {
      return GoalProjection(
        state: ProjectionState.stalled,
        targetWeightKg: targetWeightKg,
        currentAverageKg: currentAverageKg,
        observedKgPerWeek: observedKgPerWeek,
        plannedKgPerWeek: plannedKgPerWeek,
        weeksObserved: weeksObserved,
        plannedDate: plannedDate,
      );
    }

    return GoalProjection(
      state: ProjectionState.moving,
      targetWeightKg: targetWeightKg,
      currentAverageKg: currentAverageKg,
      observedKgPerWeek: observedKgPerWeek,
      plannedKgPerWeek: plannedKgPerWeek,
      weeksObserved: weeksObserved,
      plannedDate: plannedDate,
      projectedDate: today.add(Duration(days: weeks * 7)),
    );
  }

  /// Il ritmo osservato fra due medie a 7 giorni distanti [weeks] settimane.
  ///
  /// Negativo se si sta scendendo. Più settimane ci stanno in mezzo, meno la
  /// singola oscillazione conta: il chiamante passa la finestra più lunga di
  /// cui dispone.
  static double? rateKgPerWeek({
    required double? currentAverageKg,
    required double? olderAverageKg,
    required int weeks,
  }) {
    if (currentAverageKg == null || olderAverageKg == null || weeks <= 0) {
      return null;
    }
    return (currentAverageKg - olderAverageKg) / weeks;
  }
}
