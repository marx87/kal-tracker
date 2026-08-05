import 'package:flutter/foundation.dart';
import 'package:kal_tracker/features/body/domain/body_analysis.dart';
import 'package:kal_tracker/features/coach/domain/coach_snapshot.dart';

/// Cosa sta facendo la massa magra. **È la domanda del deficit**: un
/// traguardo di peso raggiunto perdendo muscolo è un fallimento travestito
/// da successo.
enum LeanMassTrend {
  /// Dentro il rumore della BIA: è l'esito che si cerca durante un deficit.
  holding(label: 'Massa magra tenuta'),

  falling(label: 'Massa magra in calo'),
  rising(label: 'Massa magra in crescita'),

  /// Manca la composizione in una delle due settimane.
  unknown(label: 'Composizione non misurata');

  const LeanMassTrend({required this.label});

  final String label;
}

/// La lettura della ricomposizione fra due settimane, a medie di 7 giorni.
@immutable
class Recomposition {
  const Recomposition({
    required this.leanTrend,
    this.leanMassNowKg,
    this.leanMassBeforeKg,
    this.fatMassNowKg,
    this.fatMassBeforeKg,
    this.compositionDaysNow = 0,
    this.compositionDaysBefore = 0,
  });

  const Recomposition.unknown()
    : leanTrend = LeanMassTrend.unknown,
      leanMassNowKg = null,
      leanMassBeforeKg = null,
      fatMassNowKg = null,
      fatMassBeforeKg = null,
      compositionDaysNow = 0,
      compositionDaysBefore = 0;

  final LeanMassTrend leanTrend;

  final double? leanMassNowKg;
  final double? leanMassBeforeKg;
  final double? fatMassNowKg;
  final double? fatMassBeforeKg;

  /// Giorni con composizione dietro ciascuna media.
  final int compositionDaysNow;
  final int compositionDaysBefore;

  double? get leanChangeKg =>
      (leanMassNowKg == null || leanMassBeforeKg == null)
      ? null
      : leanMassNowKg! - leanMassBeforeKg!;

  double? get fatChangeKg => (fatMassNowKg == null || fatMassBeforeKg == null)
      ? null
      : fatMassNowKg! - fatMassBeforeKg!;

  bool get isKnown => leanTrend != LeanMassTrend.unknown;

  /// Grasso giù e magra tenuta o in crescita: la combinazione che si cerca.
  bool get isRecomposition {
    final fat = fatChangeKg;
    if (fat == null || !isKnown) {
      return false;
    }
    return fat < -CoachRecomposition.noiseKg &&
        leanTrend != LeanMassTrend.falling;
  }

  /// La frase deterministica, quella che il modello NON deve riscrivere.
  String get headline => switch (leanTrend) {
    LeanMassTrend.unknown =>
      'Non ho due settimane di pesate con impedenza da confrontare.',
    LeanMassTrend.holding when isRecomposition =>
      'Grasso in calo e massa magra tenuta: è la combinazione che si cerca.',
    LeanMassTrend.rising when isRecomposition =>
      'Grasso in calo e massa magra in crescita.',
    LeanMassTrend.holding => 'Massa magra ferma.',
    LeanMassTrend.rising => 'Massa magra in crescita.',
    LeanMassTrend.falling =>
      'La massa magra sta scendendo: non è solo grasso quello che se ne va.',
  };
}

/// Il calcolo della ricomposizione. Confronta due **medie a 7 giorni**, mai
/// due pesate: nei dati veri di Marco il grasso è variato di 0,1 punti in
/// cinque minuti a peso identico.
abstract final class CoachRecomposition {
  /// Sotto questa variazione non è successo niente: è la BIA che respira.
  /// Stesso valore della schermata Corpo, per non dare due verdetti diversi
  /// sullo stesso movimento.
  static const double noiseKg = BodyAnalysis.stableToleranceKg;

  /// Giorni con composizione che servono per settimana perché la media conti.
  static const int minimumCompositionDays = 2;

  static Recomposition assess({
    required CoachAverages current,
    required CoachAverages previous,
  }) {
    if (!current.hasComposition ||
        !previous.hasComposition ||
        current.compositionDays < minimumCompositionDays ||
        previous.compositionDays < minimumCompositionDays) {
      return Recomposition(
        leanTrend: LeanMassTrend.unknown,
        leanMassNowKg: current.leanMassKg,
        leanMassBeforeKg: previous.leanMassKg,
        fatMassNowKg: current.fatMassKg,
        fatMassBeforeKg: previous.fatMassKg,
        compositionDaysNow: current.compositionDays,
        compositionDaysBefore: previous.compositionDays,
      );
    }

    final leanChange = current.leanMassKg! - previous.leanMassKg!;
    return Recomposition(
      leanTrend: leanChange.abs() <= noiseKg
          ? LeanMassTrend.holding
          : leanChange < 0
          ? LeanMassTrend.falling
          : LeanMassTrend.rising,
      leanMassNowKg: current.leanMassKg,
      leanMassBeforeKg: previous.leanMassKg,
      fatMassNowKg: current.fatMassKg,
      fatMassBeforeKg: previous.fatMassKg,
      compositionDaysNow: current.compositionDays,
      compositionDaysBefore: previous.compositionDays,
    );
  }
}
