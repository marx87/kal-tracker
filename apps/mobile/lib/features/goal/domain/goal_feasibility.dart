import 'package:kal_tracker/features/goal/domain/body_composition.dart';
import 'package:kal_tracker/features/goal/domain/definition_level.dart';

/// Cosa comporta davvero la combinazione scelta.
enum FeasibilityKind {
  /// Ci si arriva perdendo solo grasso: è la curva.
  achievable,

  /// Servirebbe costruire muscolo prima: è una fase di massa, non un deficit.
  needsMuscleGain,

  /// Ci si arriverebbe solo smontando massa magra. L'app lo sconsiglia.
  needsMuscleLoss,
}

/// Il verdetto su una combinazione peso + definizione.
///
/// È il pezzo del «coach che sa dire di no»: non impedisce niente, ma dice
/// per intero quanto costa, e propone l'alternativa che costa il giusto.
class FeasibilityVerdict {
  const FeasibilityVerdict({
    required this.kind,
    required this.fatFreeMassDeltaKg,
    required this.fatDeltaKg,
    required this.onCurveWeightKg,
    required this.headline,
    required this.explanation,
    this.counterProposal,
  });

  final FeasibilityKind kind;

  /// Chili di massa magra che il traguardo richiede: positivo da costruire,
  /// negativo da perdere.
  final double fatFreeMassDeltaKg;

  /// Chili di grasso da perdere per arrivarci (negativo se ne servirebbe di
  /// più, cioè se il traguardo è più morbido di com'è oggi).
  final double fatDeltaKg;

  /// Il peso che quella definizione ha **oggi**, a massa magra invariata.
  /// È sempre la controproposta onesta.
  final double onCurveWeightKg;

  final String headline;
  final String explanation;

  /// Cosa fare invece, quando c'è un invece.
  final String? counterProposal;

  bool get isAchievable => kind == FeasibilityKind.achievable;

  /// Chili di grasso da perdere, mai negativi: è il numero che alimenta la
  /// stima dei tempi.
  double get fatToLoseKg => fatDeltaKg > 0 ? fatDeltaKg : 0;
}

/// Il verdetto di fattibilità su ogni combinazione fuori curva.
abstract final class GoalFeasibility {
  /// Sotto il mezzo chilo di scarto la combinazione è sulla curva: la
  /// bilancia stessa non distingue meglio, e un avviso per 300 g di massa
  /// magra sarebbe rumore.
  static const double toleranceKg = 0.5;

  static FeasibilityVerdict assess({
    required double currentWeightKg,
    required double currentFatFreeMassKg,
    required double targetWeightKg,
    required DefinitionLevel targetLevel,
  }) {
    final neededFatFreeMass = BodyComposition.fatFreeMassNeeded(
      weightKg: targetWeightKg,
      bodyFatPct: targetLevel.bodyFatPct,
    );
    final delta = neededFatFreeMass - currentFatFreeMassKg;
    final onCurveWeight = DefinitionCurve.weightFor(
      level: targetLevel,
      fatFreeMassKg: currentFatFreeMassKg,
    );
    // A massa magra invariata tutta la differenza di peso è grasso: è
    // esattamente ciò che rende leggibile il traguardo.
    final fatDelta = currentWeightKg - targetWeightKg;

    if (delta.abs() <= toleranceKg) {
      return FeasibilityVerdict(
        kind: FeasibilityKind.achievable,
        fatFreeMassDeltaKg: delta,
        fatDeltaKg: fatDelta,
        onCurveWeightKg: onCurveWeight,
        headline: fatDelta > 0
            ? 'Raggiungibile perdendo solo grasso'
            : 'Raggiungibile: sei già lì',
        explanation: fatDelta > 0
            ? 'Da qui a ${_kg(targetWeightKg)} kg te ne mancano '
                  '${_kg(fatDelta)} di grasso, e il muscolo resta dov\'è.'
            : 'Questo traguardo non chiede di perdere grasso: è dove sei '
                  'già, o poco più su.',
      );
    }

    if (delta > 0) {
      return FeasibilityVerdict(
        kind: FeasibilityKind.needsMuscleGain,
        fatFreeMassDeltaKg: delta,
        fatDeltaKg: fatDelta,
        onCurveWeightKg: onCurveWeight,
        headline: 'Servono ${_kg(delta)} kg di muscolo',
        explanation:
            'Essere ${targetLevel.inlineLabel} a ${_kg(targetWeightKg)} kg '
            'vuol dire portare la massa magra a '
            '${_kg(neededFatFreeMass)} kg: ${_kg(delta)} kg più di adesso. '
            'Non è un deficit, è una fase di massa.',
        counterProposal:
            'Prima una fase di massa, poi il deficit. Con il muscolo di oggi '
            '${targetLevel.inlineLabel} per te sono ${_kg(onCurveWeight)} kg.',
      );
    }

    final loss = -delta;
    return FeasibilityVerdict(
      kind: FeasibilityKind.needsMuscleLoss,
      fatFreeMassDeltaKg: delta,
      fatDeltaKg: fatDelta,
      onCurveWeightKg: onCurveWeight,
      headline: 'Costerebbe ${_kg(loss)} kg di massa magra',
      explanation:
          'Per stare a ${_kg(targetWeightKg)} kg ed essere ancora '
          '${targetLevel.inlineLabel} dovresti smontare ${_kg(loss)} kg di '
          'muscolo. Te lo sconsiglio: è un traguardo di peso raggiunto '
          'perdendo la parte che ti serve.',
      counterProposal:
          'Con il muscolo che hai, ${targetLevel.inlineLabel} sono '
          '${_kg(onCurveWeight)} kg. Stesso aspetto, senza smontare niente.',
    );
  }
}

String _kg(double value) => value.abs().toStringAsFixed(1).replaceAll('.', ',');
