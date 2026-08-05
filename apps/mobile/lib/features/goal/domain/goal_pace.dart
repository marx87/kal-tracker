import 'dart:math' as math;

import 'package:kal_tracker/features/goal/domain/body_composition.dart';

/// I tre ritmi, detti a parole. La percentuale non compare mai in UI.
///
/// Sono frazioni del peso corporeo a settimana, non chili fissi: 0,5 kg a
/// settimana è prudente a 95 kg e aggressivo a 60.
enum PaceChoice {
  calm(fractionOfBodyWeight: 0.003, label: 'Con calma'),
  steady(fractionOfBodyWeight: 0.005, label: 'Costante'),
  firm(fractionOfBodyWeight: 0.007, label: 'Deciso');

  const PaceChoice({required this.fractionOfBodyWeight, required this.label});

  final double fractionOfBodyWeight;
  final String label;

  String get description => switch (this) {
    PaceChoice.calm =>
      'Il deficit si sente poco. Ci vuole più tempo, si molla meno.',
    PaceChoice.steady => 'Il compromesso: si vede sulla bilancia, si regge.',
    PaceChoice.firm =>
      'Il massimo che l\'app accetta. Oltre, si perde anche muscolo.',
  };

  double kgPerWeekFor(double currentWeightKg) =>
      currentWeightKg * fractionOfBodyWeight;

  /// Il ritmo scelto più vicino a un valore in chili: serve a ridisegnare la
  /// scelta quando il ritmo salvato arriva da una data e non da un pulsante.
  static PaceChoice nearest({
    required double currentWeightKg,
    required double kgPerWeek,
  }) {
    var best = PaceChoice.steady;
    var distance = double.infinity;
    for (final choice in PaceChoice.values) {
      final candidate = (choice.kgPerWeekFor(currentWeightKg) - kgPerWeek)
          .abs();
      if (candidate < distance) {
        best = choice;
        distance = candidate;
      }
    }
    return best;
  }
}

/// L'esito della richiesta di un ritmo.
class PaceVerdict {
  const PaceVerdict({
    required this.accepted,
    required this.requestedKgPerWeek,
    required this.appliedKgPerWeek,
    required this.safeMaximumKgPerWeek,
    this.refusal,
    this.counterProposal,
  });

  final bool accepted;

  /// Quello che è stato chiesto.
  final double requestedKgPerWeek;

  /// Quello che si applica: uguale al richiesto se accettato, il massimo
  /// sicuro se rifiutato.
  final double appliedKgPerWeek;

  final double safeMaximumKgPerWeek;

  /// Perché è stato rifiutato. Nullo quando è accettato.
  final String? refusal;

  /// Cosa si può fare invece: sempre presente quando c'è un rifiuto.
  final String? counterProposal;

  double get dailyDeficitKcal => GoalPace.dailyDeficitKcal(appliedKgPerWeek);
}

/// **Il limite di sicurezza, non negoziabile.**
///
/// Massimo 0,7 % del peso corporeo a settimana. Non è prudenza generica: più
/// veloce di così il corpo copre la differenza anche con la massa magra, e un
/// traguardo di peso raggiunto perdendo muscolo è un fallimento travestito da
/// successo.
abstract final class GoalPace {
  static const double maxWeeklyFractionOfBodyWeight = 0.007;

  /// Sotto questo ritmo la stima dei tempi diventa fantascienza e il rumore
  /// della bilancia supera il segnale.
  static const double minimumKgPerWeek = 0.05;

  static double safeMaximumKgPerWeek(double currentWeightKg) =>
      currentWeightKg * maxWeeklyFractionOfBodyWeight;

  /// Il deficit giornaliero che produce quel ritmo: `kg × 7700 / 7`.
  static double dailyDeficitKcal(double kgPerWeek) =>
      kgPerWeek * BodyComposition.kcalPerKgOfFat / 7;

  /// Giudica un ritmo richiesto. Oltre il limite **rifiuta**, spiega e
  /// propone il massimo sicuro: non lo applica di nascosto.
  static PaceVerdict assess({
    required double currentWeightKg,
    required double requestedKgPerWeek,
  }) {
    final maximum = safeMaximumKgPerWeek(currentWeightKg);

    if (!requestedKgPerWeek.isFinite || requestedKgPerWeek < minimumKgPerWeek) {
      return PaceVerdict(
        accepted: false,
        requestedKgPerWeek: requestedKgPerWeek.isFinite
            ? requestedKgPerWeek
            : 0,
        appliedKgPerWeek: minimumKgPerWeek,
        safeMaximumKgPerWeek: maximum,
        refusal:
            'Un ritmo così lento non si distingue dalle oscillazioni '
            'normali della bilancia.',
        counterProposal:
            'Il minimo utile è ${_kg(minimumKgPerWeek)} kg a settimana.',
      );
    }

    if (requestedKgPerWeek > maximum + 0.005) {
      return PaceVerdict(
        accepted: false,
        requestedKgPerWeek: requestedKgPerWeek,
        appliedKgPerWeek: maximum,
        safeMaximumKgPerWeek: maximum,
        refusal:
            'Non ci arrivo così in fretta: ${_kg(requestedKgPerWeek)} kg a '
            'settimana sono oltre il limite che questa app accetta. Più '
            'veloce di ${_kg(maximum)} kg il corpo prende la differenza '
            'anche dal muscolo.',
        counterProposal:
            'Posso andare al massimo a ${_kg(maximum)} kg a settimana, '
            'cioè ${dailyDeficitKcal(maximum).round()} kcal al giorno in '
            'meno.',
      );
    }

    return PaceVerdict(
      accepted: true,
      requestedKgPerWeek: requestedKgPerWeek,
      appliedKgPerWeek: requestedKgPerWeek,
      safeMaximumKgPerWeek: maximum,
    );
  }

  /// Il ritmo implicito in una scadenza: «voglio arrivarci entro il…».
  ///
  /// È qui che il rifiuto serve davvero — una data scelta col dito produce
  /// facilmente 1,5 kg a settimana — e la controproposta è una data, non un
  /// numero: l'aderenza si comunica come distanza dalla data.
  static PaceVerdict fromDeadline({
    required double currentWeightKg,
    required double fatToLoseKg,
    required int days,
  }) {
    if (days <= 0 || fatToLoseKg <= 0) {
      return PaceVerdict(
        accepted: false,
        requestedKgPerWeek: 0,
        appliedKgPerWeek: minimumKgPerWeek,
        safeMaximumKgPerWeek: safeMaximumKgPerWeek(currentWeightKg),
        refusal: 'Serve una data futura per calcolare un ritmo.',
        counterProposal: 'Scegli un giorno da domani in poi.',
      );
    }
    final requested = fatToLoseKg / (days / 7);
    final verdict = assess(
      currentWeightKg: currentWeightKg,
      requestedKgPerWeek: requested,
    );
    if (verdict.accepted) {
      return verdict;
    }
    final honestDays = daysToLose(
      fatToLoseKg: fatToLoseKg,
      kgPerWeek: verdict.appliedKgPerWeek,
    );
    return PaceVerdict(
      accepted: false,
      requestedKgPerWeek: verdict.requestedKgPerWeek,
      appliedKgPerWeek: verdict.appliedKgPerWeek,
      safeMaximumKgPerWeek: verdict.safeMaximumKgPerWeek,
      refusal: verdict.refusal,
      counterProposal:
          'Al ritmo massimo sicuro ci vogliono $honestDays giorni: '
          '${honestDays - days} in più di quelli che hai chiesto.',
    );
  }

  /// Quanti giorni servono, al ritmo dato. Arrotondati per eccesso: mezza
  /// giornata di margine è più onesta di mezza giornata di ottimismo.
  static int daysToLose({
    required double fatToLoseKg,
    required double kgPerWeek,
  }) {
    if (fatToLoseKg <= 0) {
      return 0;
    }
    final safePace = math.max(kgPerWeek, minimumKgPerWeek);
    return (fatToLoseKg / safePace * 7).ceil();
  }
}

String _kg(double value) => value.toStringAsFixed(2).replaceAll('.', ',');
