/// Contratto `meal_analysis.schema.json`: il parser Dart è rigido come
/// `contract.py` del worker (set esatto di chiavi, 1..12 alimenti, fasce
/// grammi 0 < min <= sugg <= max <= 3000). Il jsonb sul server è vincolato
/// solo per tipo e dimensione: un risultato corrotto non deve mai mandare
/// in crash la revisione, quindi ogni violazione diventa [FormatException].
/// Il modello può proporre i valori PER 100 G (`per100g`, come leggesse
/// un'etichetta) ma MAI le calorie totali: ogni totale mostrato è sempre
/// NutritionCalculator.scale(per100g, grammi) calcolato dall'app.
/// COMPATIBILITÀ: `per100g` è OPZIONALE perché nel database esistono già
/// risultati del worker vecchio senza il campo; un alimento senza
/// `per100g` resta valido e in revisione si comporta come oggi
/// (valori per 100 g da compilare a mano).
library;

import 'package:kal_tracker/features/diary/domain/nutrition.dart';

const _preparations = {
  'raw',
  'cooked',
  'grilled',
  'baked',
  'fried',
  'boiled',
  'mixed',
  'unknown',
};

/// Stime nutrizionali per 100 g proposte dal modello, come lette da
/// un'etichetta. Range da contratto: 0..900 kcal (il grasso puro arriva
/// a ~900) e 0..100 g per ciascun macronutriente. Sono stime da
/// verificare: in revisione restano modificabili come tutto il resto.
class MealAnalysisPer100g {
  const MealAnalysisPer100g({
    required this.energyKcal,
    required this.proteinG,
    required this.carbsG,
    required this.fatG,
  });

  factory MealAnalysisPer100g.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('per100g deve essere un oggetto.');
    }
    const expected = {'energyKcal', 'proteinG', 'carbsG', 'fatG'};
    if (!_hasExactKeys(value, expected)) {
      throw const FormatException('Campi per100g mancanti o inattesi.');
    }
    final energyKcal = _number(value['energyKcal'], 'energyKcal');
    if (energyKcal < 0 || energyKcal > 900) {
      throw const FormatException('energyKcal deve essere tra 0 e 900.');
    }
    return MealAnalysisPer100g(
      energyKcal: energyKcal,
      proteinG: _gramsPer100(value['proteinG'], 'proteinG'),
      carbsG: _gramsPer100(value['carbsG'], 'carbsG'),
      fatG: _gramsPer100(value['fatG'], 'fatG'),
    );
  }

  final double energyKcal;
  final double proteinG;
  final double carbsG;
  final double fatG;

  /// Vista [Nutrients] da passare a [NutritionCalculator.scale]:
  /// mai da usare direttamente come totale del piatto.
  Nutrients toNutrients() => Nutrients(
    calories: energyKcal,
    protein: proteinG,
    carbs: carbsG,
    fat: fatG,
  );
}

class MealAnalysisFood {
  const MealAnalysisFood({
    required this.name,
    required this.alternatives,
    required this.minimumGrams,
    required this.suggestedGrams,
    required this.maximumGrams,
    required this.confidence,
    required this.preparation,
    required this.hiddenIngredients,
    required this.uncertainty,
    this.per100g,
  });

  factory MealAnalysisFood.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('Ogni alimento deve essere un oggetto.');
    }
    const expected = {
      'name',
      'alternatives',
      'minimumGrams',
      'suggestedGrams',
      'maximumGrams',
      'confidence',
      'preparation',
      'hiddenIngredients',
      'uncertainty',
    };
    if (!_hasExactKeys(value, expected, optional: const {'per100g'})) {
      throw const FormatException('Campi alimento mancanti o inattesi.');
    }

    // `per100g` è opzionale per compatibilità: i risultati del worker
    // vecchio (già nel database) non ce l'hanno e restano validi.
    // Un eventuale null esplicito vale come assente.
    final rawPer100g = value['per100g'];
    final per100g = rawPer100g == null
        ? null
        : MealAnalysisPer100g.fromJson(rawPer100g);

    final minimum = _number(value['minimumGrams'], 'minimumGrams');
    final suggested = _number(value['suggestedGrams'], 'suggestedGrams');
    final maximum = _number(value['maximumGrams'], 'maximumGrams');
    final rangeValid =
        0 < minimum &&
        minimum <= suggested &&
        suggested <= maximum &&
        maximum <= 3000;
    if (!rangeValid) {
      throw const FormatException('La fascia dei grammi non è valida.');
    }

    final confidence = _number(value['confidence'], 'confidence');
    if (confidence < 0 || confidence > 1) {
      throw const FormatException('confidence deve essere tra 0 e 1.');
    }

    final preparation = _requiredString(
      value['preparation'],
      'preparation',
      maxLength: 20,
    );
    if (!_preparations.contains(preparation)) {
      throw const FormatException('preparation non riconosciuta.');
    }

    final uncertainty = value['uncertainty'];
    if (uncertainty is! String || uncertainty.length > 300) {
      throw const FormatException('uncertainty non valida.');
    }

    return MealAnalysisFood(
      name: _requiredString(value['name'], 'name', maxLength: 120),
      alternatives: _stringList(value['alternatives'], 'alternatives', 3),
      minimumGrams: minimum,
      suggestedGrams: suggested,
      maximumGrams: maximum,
      confidence: confidence,
      preparation: preparation,
      hiddenIngredients: _stringList(
        value['hiddenIngredients'],
        'hiddenIngredients',
        6,
      ),
      uncertainty: uncertainty.trim(),
      per100g: per100g,
    );
  }

  final String name;
  final List<String> alternatives;
  final double minimumGrams;
  final double suggestedGrams;
  final double maximumGrams;
  final double confidence;
  final String preparation;
  final List<String> hiddenIngredients;
  final String uncertainty;

  /// Stime per 100 g del modello; null per i risultati vecchi senza il
  /// campo (compatibilità: si compilano a mano come oggi).
  final MealAnalysisPer100g? per100g;

  String get preparationLabel => switch (preparation) {
    'raw' => 'Crudo',
    'cooked' => 'Cotto',
    'grilled' => 'Alla griglia',
    'baked' => 'Al forno',
    'fried' => 'Fritto',
    'boiled' => 'Bollito',
    'mixed' => 'Misto',
    _ => 'Preparazione ignota',
  };
}

class MealAnalysisResult {
  const MealAnalysisResult({
    required this.foods,
    required this.questions,
    required this.overallConfidence,
    required this.notes,
  });

  factory MealAnalysisResult.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException(
        'Il risultato dell’analisi deve essere un oggetto.',
      );
    }
    const expected = {'foods', 'questions', 'overallConfidence', 'notes'};
    if (!_hasExactKeys(value, expected)) {
      throw const FormatException('Campi del risultato mancanti o inattesi.');
    }

    final rawFoods = value['foods'];
    if (rawFoods is! List || rawFoods.isEmpty || rawFoods.length > 12) {
      throw const FormatException('foods deve contenere da 1 a 12 alimenti.');
    }

    final overallConfidence = _number(
      value['overallConfidence'],
      'overallConfidence',
    );
    if (overallConfidence < 0 || overallConfidence > 1) {
      throw const FormatException('overallConfidence deve essere tra 0 e 1.');
    }

    final notes = value['notes'];
    if (notes is! String || notes.length > 500) {
      throw const FormatException('notes non valide.');
    }

    return MealAnalysisResult(
      foods: List.unmodifiable(rawFoods.map(MealAnalysisFood.fromJson)),
      questions: _stringList(
        value['questions'],
        'questions',
        5,
        maxLength: 240,
      ),
      overallConfidence: overallConfidence,
      notes: notes.trim(),
    );
  }

  final List<MealAnalysisFood> foods;
  final List<String> questions;
  final double overallConfidence;
  final String notes;

  /// Totale kcal stimato con i grammi SUGGERITI dal modello, sempre
  /// calcolato dall'app via [NutritionCalculator.scale] (mai dal modello).
  /// Null se anche un solo alimento è senza `per100g` (risultato vecchio:
  /// un totale parziale sarebbe fuorviante) o se la scala fallisce.
  double? get estimatedCalories {
    var total = 0.0;
    for (final food in foods) {
      final per100g = food.per100g;
      if (per100g == null) {
        return null;
      }
      try {
        total += NutritionCalculator.scale(
          per100g: per100g.toNutrients(),
          grams: food.suggestedGrams,
        ).calories;
      } on FormatException {
        return null;
      }
    }
    return total;
  }
}

/// Totale kcal stimato da un `analysis_result` grezzo (la copia salvata
/// nel registro locale del diario). Null se il payload non è conforme al
/// contratto o senza stime per 100 g complete: la riga di stato del
/// diario non deve mai cadere per un risultato vecchio o corrotto.
double? estimatedCaloriesFromRaw(Object? rawResult) {
  try {
    return MealAnalysisResult.fromJson(rawResult).estimatedCalories;
  } on FormatException {
    return null;
  }
}

/// Set esatto di chiavi, più eventuali [optional] ammesse ma non dovute:
/// `per100g` è l'unica, per leggere sia i risultati del worker nuovo sia
/// quelli vecchi già nel database.
bool _hasExactKeys(
  Map<Object?, Object?> value,
  Set<String> expected, {
  Set<String> optional = const {},
}) {
  var found = 0;
  for (final key in value.keys) {
    if (key is! String) {
      return false;
    }
    if (expected.contains(key)) {
      found++;
    } else if (!optional.contains(key)) {
      return false;
    }
  }
  return found == expected.length;
}

double _number(Object? value, String field) {
  if (value is! num) {
    throw FormatException('$field deve essere numerico.');
  }
  final result = value.toDouble();
  if (!result.isFinite) {
    throw FormatException('$field deve essere finito.');
  }
  return result;
}

/// Un macronutriente per 100 g non può superare i 100 g.
double _gramsPer100(Object? value, String field) {
  final result = _number(value, field);
  if (result < 0 || result > 100) {
    throw FormatException('$field deve essere tra 0 e 100.');
  }
  return result;
}

String _requiredString(Object? value, String field, {required int maxLength}) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$field deve essere una stringa non vuota.');
  }
  final normalized = value.trim();
  if (normalized.length > maxLength) {
    throw FormatException('$field supera $maxLength caratteri.');
  }
  return normalized;
}

List<String> _stringList(
  Object? value,
  String field,
  int maxItems, {
  int maxLength = 120,
}) {
  if (value is! List || value.length > maxItems) {
    throw FormatException('$field deve contenere al massimo $maxItems voci.');
  }
  return List.unmodifiable([
    for (final (index, item) in value.indexed)
      _requiredString(item, '$field[$index]', maxLength: maxLength),
  ]);
}
