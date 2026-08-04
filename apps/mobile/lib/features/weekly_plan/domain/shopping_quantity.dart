/// Quantità «da spesa»: leggibili, non da bilancia analitica.
///
/// Al supermercato «487,5 g di pomodori» non serve a niente: serve «500 g».
/// Le regole sono tre e sono tutte pure e tabellabili:
///  * sotto i 100 g si arrotonda al multiplo di 10;
///  * sotto il chilo al multiplo di 50;
///  * dal chilo in su si passa ai kg con una cifra decimale.
/// In più, dove l'unità naturale è ovvia si mostra quella (uova a pezzi, olio
/// a cucchiai o ml) tenendo SEMPRE i grammi veri come nota: il conteggio
/// nutrizionale del piano non si tocca, qui si arrotonda solo quello che
/// finisce nel carrello.
library;

import 'package:kal_tracker/features/weekly_plan/domain/shopping_text.dart';

/// Quantità pronta da mostrare.
class ShoppingQuantity {
  const ShoppingQuantity({
    required this.grams,
    required this.display,
    this.note,
  });

  /// Grammi veri sommati dal piano (mai arrotondati).
  final double grams;

  /// Quantità da comprare, già arrotondata: «500 g», «1,2 kg», «3 uova».
  final String display;

  /// Dettaglio in grammi quando [display] usa un'unità naturale.
  final String? note;
}

abstract final class ShoppingQuantities {
  /// Peso medio di un uovo medio sgusciato: serve solo a contare i pezzi.
  static const double gramsPerEgg = 55;

  /// Un cucchiaio d'olio.
  static const double gramsPerSpoon = 10;

  /// Densità dell'olio di semi/oliva: per passare dai grammi ai ml.
  static const double oilDensity = 0.92;

  /// La soglia sotto la quale l'olio si misura a cucchiai.
  static const double spoonThresholdGrams = 60;

  /// Quantità da comprare per un ingrediente.
  static ShoppingQuantity format({
    required String name,
    required double grams,
  }) {
    final safeGrams = grams.isFinite && grams > 0 ? grams : 0.0;
    final words = ShoppingText.tokens(name);

    if (_isEggs(name)) {
      final pieces = _atLeastOne((safeGrams / gramsPerEgg).round());
      return ShoppingQuantity(
        grams: safeGrams,
        display: pieces == 1 ? '1 uovo' : '$pieces uova',
        note: _exactGrams(safeGrams),
      );
    }

    if (words.any((word) => word.startsWith('olio'))) {
      if (safeGrams < spoonThresholdGrams) {
        final spoons = _atLeastOne((safeGrams / gramsPerSpoon).round());
        return ShoppingQuantity(
          grams: safeGrams,
          display: spoons == 1 ? '1 cucchiaio' : '$spoons cucchiai',
          note: _exactGrams(safeGrams),
        );
      }
      final milliliters = _roundToStep(safeGrams / oilDensity, 10);
      return ShoppingQuantity(
        grams: safeGrams,
        display: '$milliliters ml',
        note: _exactGrams(safeGrams),
      );
    }

    return ShoppingQuantity(grams: safeGrams, display: formatGrams(safeGrams));
  }

  /// L'ingrediente sono le uova, non un alimento che le contiene.
  ///
  /// L'uovo vale a pezzi solo quando è la TESTA del nome («Uova», «Uovo
  /// intero»). Altrove è una qualità di un altro alimento — «Tagliatelle
  /// all'uovo secche», «Albume d'uovo», «Tuorlo d'uovo» — e quella roba al
  /// supermercato si compra a peso: chiedere «3 uova» al posto di 150 g di
  /// tagliatelle farebbe tornare a casa con la spesa sbagliata.
  static bool _isEggs(String name) {
    final words = ShoppingText.normalize(name).split(' ');
    return words.isNotEmpty && ShoppingText.singular(words.first) == 'uovo';
  }

  /// Il solo arrotondamento in grammi/kg, senza unità naturali.
  static String formatGrams(double grams) {
    if (!grams.isFinite || grams <= 0) {
      return '0 g';
    }
    final rounded = grams < 100
        ? _roundToStep(grams, 10)
        : (grams < 1000 ? _roundToStep(grams, 50) : grams.round());
    if (rounded < 1000) {
      return '$rounded g';
    }
    // Un decimale: 1240 g → «1,2 kg», 2000 g → «2 kg».
    final tenths = (rounded / 100).round();
    final units = tenths ~/ 10;
    final decimal = tenths % 10;
    return decimal == 0 ? '$units kg' : '$units,$decimal kg';
  }

  /// Arrotonda al multiplo di [step] più vicino, senza mai sparire: una
  /// spolverata di 4 g resta «10 g», non «0 g».
  static int _roundToStep(double value, int step) {
    final steps = (value / step).round();
    return (steps < 1 ? 1 : steps) * step;
  }

  static int _atLeastOne(int value) => value < 1 ? 1 : value;

  static String _exactGrams(double grams) => '≈ ${grams.round()} g';
}
