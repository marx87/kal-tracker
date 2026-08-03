/// Contratto `meal_analysis.schema.json`: il parser Dart è rigido come
/// `contract.py` del worker (set esatto di chiavi, 1..12 alimenti, fasce
/// grammi 0 < min <= sugg <= max <= 3000). Il jsonb sul server è vincolato
/// solo per tipo e dimensione: un risultato corrotto non deve mai mandare
/// in crash la revisione, quindi ogni violazione diventa [FormatException].
/// Niente calorie né macro per contratto: il calcolo resta all'app via
/// NutritionCalculator dopo la conferma di Marco.
library;

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
    if (!_hasExactKeys(value, expected)) {
      throw const FormatException('Campi alimento mancanti o inattesi.');
    }

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
}

bool _hasExactKeys(Map<Object?, Object?> value, Set<String> expected) {
  if (value.length != expected.length) {
    return false;
  }
  for (final key in value.keys) {
    if (key is! String || !expected.contains(key)) {
      return false;
    }
  }
  return true;
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
