import 'package:kal_tracker/features/goal/domain/body_composition.dart';

/// Quanto ci si muove, finché non ci sono abbastanza dati per misurarlo.
enum ActivityLevel {
  sedentary(multiplier: 1.2, label: 'Sedentario'),
  light(multiplier: 1.375, label: 'Poco attivo'),
  moderate(multiplier: 1.55, label: 'Attivo'),
  high(multiplier: 1.725, label: 'Molto attivo'),
  veryHigh(multiplier: 1.9, label: 'Atleta');

  const ActivityLevel({required this.multiplier, required this.label});

  final double multiplier;
  final String label;

  static ActivityLevel fromStorage(String? value) {
    for (final level in ActivityLevel.values) {
      if (level.name == value) {
        return level;
      }
    }
    return ActivityLevel.moderate;
  }
}

/// Da dove arriva il numero.
enum TdeeSource {
  /// Metabolismo basale × attività: una tabella, non una misura. Vale finché
  /// i dati reali non bastano.
  estimated(label: 'Stimato'),

  /// Calcolato sui dati veri di Marco: calorie mangiate meno la variazione
  /// di peso. Appena c'è, sostituisce la stima.
  measured(label: 'Misurato');

  const TdeeSource({required this.label});

  final String label;
}

/// Una finestra di dati reali su cui misurare il consumo.
class TdeeSample {
  const TdeeSample({
    required this.averageDailyKcal,
    required this.weightChangeKg,
    required this.days,
  });

  /// Media delle calorie ingerite nella finestra.
  final double averageDailyKcal;

  /// Variazione di peso nella finestra: negativa se è sceso.
  final double weightChangeKg;

  final int days;

  bool get isUsable =>
      days >= AdaptiveTdee.minimumDays &&
      averageDailyKcal.isFinite &&
      averageDailyKcal > 0 &&
      weightChangeKg.isFinite;
}

/// Il consumo giornaliero, con la sua provenienza dichiarata.
class TdeeEstimate {
  const TdeeEstimate({
    required this.kcal,
    required this.source,
    required this.days,
    this.fellBackBecauseImplausible = false,
  });

  final double kcal;
  final TdeeSource source;

  /// Giorni di dati che ci stanno dietro. Zero quando è una stima.
  final int days;

  /// La misura c'era ma era assurda, quindi si è tornati alla stima. È un
  /// caso reale: una settimana con tre chili di acqua in meno darebbe un
  /// consumo da maratoneta.
  final bool fellBackBecauseImplausible;

  bool get isMeasured => source == TdeeSource.measured;

  String get explanation => switch (source) {
    TdeeSource.measured =>
      'Misurato sui tuoi ultimi $days giorni: calorie mangiate meno il peso '
          'che se n\'è andato.',
    TdeeSource.estimated when fellBackBecauseImplausible =>
      'I dati delle ultime settimane danno un numero fuori scala — succede '
          'quando il peso si muove per acqua — quindi per ora vale la stima.',
    TdeeSource.estimated =>
      'Stima da metabolismo basale e attività: diventa una misura vera dopo '
          '${AdaptiveTdee.minimumDays} giorni di dati.',
  };
}

/// **Il TDEE adattivo.**
///
/// Le prime settimane vale la stima da metabolismo basale × attività; appena
/// ci sono abbastanza dati reali si passa alla misura e non si torna
/// indietro. È il numero da cui dipende tutto il resto: il deficit è una
/// sottrazione da qui.
abstract final class AdaptiveTdee {
  /// Due settimane: sotto, l'oscillazione dell'acqua corporea pesa più del
  /// grasso perso e la «misura» misurerebbe soprattutto il sale.
  static const int minimumDays = 14;

  /// Il consumo non può essere meno del basale né più di due volte e mezza:
  /// fuori da qui non è un metabolismo, è un dato sbagliato.
  static const double minMultiplierOfBmr = 1;
  static const double maxMultiplierOfBmr = 2.5;

  static double fromBasalMetabolicRate({
    required double basalMetabolicRate,
    required ActivityLevel activity,
  }) => basalMetabolicRate * activity.multiplier;

  /// `kcal medie ingerite − (Δ peso × 7700 / giorni)`.
  ///
  /// Se il peso è sceso il termine è negativo e il consumo risulta più alto
  /// di quanto si è mangiato: è esattamente il deficit che si stava tenendo.
  static double fromRealData(TdeeSample sample) =>
      sample.averageDailyKcal -
      (sample.weightChangeKg * BodyComposition.kcalPerKgOfFat / sample.days);

  static TdeeEstimate resolve({
    required double fatFreeMassKg,
    required ActivityLevel activity,
    TdeeSample? sample,
  }) {
    final basal = BodyComposition.basalMetabolicRate(fatFreeMassKg);
    final estimate = fromBasalMetabolicRate(
      basalMetabolicRate: basal,
      activity: activity,
    );

    if (sample == null || !sample.isUsable) {
      return TdeeEstimate(
        kcal: estimate,
        source: TdeeSource.estimated,
        days: sample?.days ?? 0,
      );
    }

    final measured = fromRealData(sample);
    final plausible =
        measured.isFinite &&
        measured >= basal * minMultiplierOfBmr &&
        measured <= basal * maxMultiplierOfBmr;
    if (!plausible) {
      return TdeeEstimate(
        kcal: estimate,
        source: TdeeSource.estimated,
        days: sample.days,
        fellBackBecauseImplausible: true,
      );
    }

    return TdeeEstimate(
      kcal: measured,
      source: TdeeSource.measured,
      days: sample.days,
    );
  }
}
