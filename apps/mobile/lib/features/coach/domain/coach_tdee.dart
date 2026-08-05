import 'package:flutter/foundation.dart';
import 'package:kal_tracker/features/goal/domain/body_composition.dart';
import 'package:kal_tracker/features/goal/domain/tdee.dart';

/// Il consumo della settimana, con dichiarato quanto ci sta dietro.
@immutable
class WeeklyTdee {
  const WeeklyTdee({
    required this.estimate,
    this.averageDailyKcal,
    this.weightChangeKg,
    this.diaryDays = 0,
    this.weighInDays = 0,
  });

  /// Il numero e la sua provenienza. È il tipo dell'area Obiettivo: il TDEE
  /// è uno solo in tutta l'app, il coach lo ricalcola, non ne inventa un
  /// secondo.
  final TdeeEstimate estimate;

  /// Media delle calorie ingerite nei giorni registrati della settimana.
  final double? averageDailyKcal;

  /// Δ fra la media a 7 giorni di questa settimana e quella della scorsa.
  /// Negativo se il peso è sceso.
  final double? weightChangeKg;

  /// Giorni di diario nella settimana (su 7).
  final int diaryDays;

  /// Giorni con almeno una pesata nella settimana (su 7).
  final int weighInDays;

  double get kcal => estimate.kcal;

  bool get isMeasured => estimate.isMeasured;

  /// Perché mancano i requisiti per la misura. Nullo quando la misura c'è.
  String? get missingDataReason {
    if (isMeasured) {
      return null;
    }
    if (estimate.fellBackBecauseImplausible) {
      return null;
    }
    if (diaryDays < CoachTdee.minimumDiaryDays) {
      return 'Servono almeno ${CoachTdee.minimumDiaryDays} giorni di diario '
          'nella settimana: ne ho $diaryDays.';
    }
    if (weighInDays < CoachTdee.minimumWeighInDays) {
      return 'Servono almeno ${CoachTdee.minimumWeighInDays} pesate a '
          'settimana perché la media a 7 giorni sia una media: ne ho '
          '$weighInDays.';
    }
    return 'Non ho ancora due settimane confrontabili.';
  }
}

/// **Il TDEE misurato, ricalcolato ogni settimana sui dati veri.**
///
/// `kcal medie ingerite − (Δ peso medio 7 gg × 7700 / 7)`.
///
/// La differenza rispetto alla versione dell'Obiettivo — che guarda una
/// finestra lunga di pesate grezze — è che qui i due estremi sono già **medie
/// a 7 giorni**: il rumore dell'acqua corporea è stato tolto prima della
/// sottrazione, non dopo. Per questo bastano due settimane di dati anche se
/// l'intervallo fra le due medie è di soli 7 giorni: dietro ci sono comunque
/// quattordici giorni di misure.
///
/// Le prime due o tre settimane vale la stima da metabolismo basale
/// (Katch-McArdle × attività). Poi vale solo il misurato — tranne quando il
/// misurato è assurdo, e allora si torna alla stima dicendolo.
abstract final class CoachTdee {
  /// Sotto questi giorni di diario la media delle calorie è la media di
  /// qualcos'altro: due giorni registrati su sette dicono cosa si è scritto,
  /// non cosa si è mangiato.
  static const int minimumDiaryDays = 5;

  /// Pesate per settimana. Con due sole, la «media a 7 giorni» è la media di
  /// due mattine e porta dentro tutta l'oscillazione dell'acqua.
  static const int minimumWeighInDays = 3;

  /// I giorni di dati reali dietro un confronto fra due medie a 7 giorni.
  /// Non 7: la settimana precedente è misurata anche lei.
  static const int daysBehindComparison = 14;

  static WeeklyTdee measure({
    required double? fatFreeMassKg,
    required ActivityLevel activity,
    required double? averageDailyKcal,
    required double? currentWeekAverageKg,
    required double? previousWeekAverageKg,
    required int diaryDays,
    required int weighInDays,
  }) {
    // Senza massa magra non c'è nemmeno il basale: non si può né misurare né
    // stimare, e il rapporto dirà che manca una pesata completa.
    if (fatFreeMassKg == null) {
      return WeeklyTdee(
        estimate: const TdeeEstimate(
          kcal: 0,
          source: TdeeSource.estimated,
          days: 0,
        ),
        averageDailyKcal: averageDailyKcal,
        diaryDays: diaryDays,
        weighInDays: weighInDays,
      );
    }

    final basal = BodyComposition.basalMetabolicRate(fatFreeMassKg);
    final estimated = AdaptiveTdee.fromBasalMetabolicRate(
      basalMetabolicRate: basal,
      activity: activity,
    );
    final fallback = WeeklyTdee(
      estimate: TdeeEstimate(
        kcal: estimated,
        source: TdeeSource.estimated,
        days: 0,
      ),
      averageDailyKcal: averageDailyKcal,
      weightChangeKg: _changeOf(currentWeekAverageKg, previousWeekAverageKg),
      diaryDays: diaryDays,
      weighInDays: weighInDays,
    );

    if (averageDailyKcal == null ||
        !averageDailyKcal.isFinite ||
        averageDailyKcal <= 0 ||
        diaryDays < minimumDiaryDays ||
        weighInDays < minimumWeighInDays) {
      return fallback;
    }
    final change = _changeOf(currentWeekAverageKg, previousWeekAverageKg);
    if (change == null) {
      return fallback;
    }

    final measured =
        averageDailyKcal - (change * BodyComposition.kcalPerKgOfFat / 7);
    final plausible =
        measured.isFinite &&
        measured >= basal * AdaptiveTdee.minMultiplierOfBmr &&
        measured <= basal * AdaptiveTdee.maxMultiplierOfBmr;
    if (!plausible) {
      // Succede davvero: una settimana con tre chili di acqua in meno darebbe
      // un consumo da maratoneta. Meglio una stima onesta di una misura
      // impossibile.
      return WeeklyTdee(
        estimate: TdeeEstimate(
          kcal: estimated,
          source: TdeeSource.estimated,
          days: daysBehindComparison,
          fellBackBecauseImplausible: true,
        ),
        averageDailyKcal: averageDailyKcal,
        weightChangeKg: change,
        diaryDays: diaryDays,
        weighInDays: weighInDays,
      );
    }

    return WeeklyTdee(
      estimate: TdeeEstimate(
        kcal: measured,
        source: TdeeSource.measured,
        days: daysBehindComparison,
      ),
      averageDailyKcal: averageDailyKcal,
      weightChangeKg: change,
      diaryDays: diaryDays,
      weighInDays: weighInDays,
    );
  }

  static double? _changeOf(double? current, double? previous) {
    if (current == null || previous == null) {
      return null;
    }
    final change = current - previous;
    return change.isFinite ? change : null;
  }
}
