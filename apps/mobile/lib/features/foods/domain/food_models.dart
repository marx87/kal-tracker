import 'package:kal_tracker/features/diary/domain/nutrition.dart';

abstract final class FoodSource {
  static const String seed = 'seed';
  static const String custom = 'custom';
}

class FoodCatalogException implements Exception {
  const FoodCatalogException(this.message);

  final String message;

  @override
  String toString() => 'FoodCatalogException: $message';
}

class FoodDraft {
  const FoodDraft({
    required this.name,
    required this.per100g,
    this.brand,
    this.barcode,
    this.defaultServingGrams = 100,
  });

  final String name;
  final String? brand;
  final String? barcode;
  final Nutrients per100g;
  final double defaultServingGrams;

  void validate() {
    if (name.trim().isEmpty || name.trim().length > 160) {
      throw const FormatException('Il nome dell’alimento non è valido.');
    }
    if (brand != null && brand!.trim().length > 120) {
      throw const FormatException('La marca è troppo lunga.');
    }
    final cleanBarcode = barcode?.trim() ?? '';
    if (cleanBarcode.length > 32) {
      throw const FormatException('Il codice a barre è troppo lungo.');
    }
    if (cleanBarcode.isNotEmpty && !RegExp(r'^\d+$').hasMatch(cleanBarcode)) {
      throw const FormatException(
        'Il codice a barre può contenere solo cifre.',
      );
    }
    if (!per100g.isValid) {
      throw const FormatException('I nutrienti dell’alimento non sono validi.');
    }
    if (!defaultServingGrams.isFinite || defaultServingGrams <= 0) {
      throw const FormatException('La porzione predefinita non è valida.');
    }
  }
}

class FoodCatalogItem {
  const FoodCatalogItem({
    required this.id,
    required this.name,
    required this.per100g,
    required this.defaultServingGrams,
    required this.source,
    required this.isFavorite,
    required this.useCount,
    this.brand,
    this.barcode,
    this.lastUsedAt,
  });

  final String id;
  final String name;
  final String? brand;
  final String? barcode;
  final Nutrients per100g;
  final double defaultServingGrams;
  final String source;
  final bool isFavorite;
  final int useCount;
  final DateTime? lastUsedAt;

  bool get isSeed => source == FoodSource.seed;
}

class AtwaterCheck {
  const AtwaterCheck({
    required this.declaredCalories,
    required this.estimatedCalories,
  });

  static const double tolerance = 0.2;

  final double declaredCalories;
  final double estimatedCalories;

  double get deviation {
    if (estimatedCalories <= 0) {
      return declaredCalories <= 0 ? 0 : 1;
    }
    return (declaredCalories - estimatedCalories).abs() / estimatedCalories;
  }

  bool get isSuspicious => deviation > tolerance;

  String? get warning => isSuspicious
      ? 'Le calorie dichiarate (${declaredCalories.round()} kcal) non tornano '
            'con proteine, carboidrati e grassi '
            '(${estimatedCalories.round()} kcal). '
            'Ricontrolla l’etichetta: puoi salvare lo stesso.'
      : null;
}

abstract final class AtwaterCalculator {
  static const double caloriesPerProteinGram = 4;
  static const double caloriesPerCarbsGram = 4;
  static const double caloriesPerFatGram = 9;

  static AtwaterCheck check(Nutrients per100g) {
    if (!per100g.isValid) {
      throw const FormatException('I nutrienti dell’alimento non sono validi.');
    }
    return AtwaterCheck(
      declaredCalories: per100g.calories,
      estimatedCalories:
          per100g.protein * caloriesPerProteinGram +
          per100g.carbs * caloriesPerCarbsGram +
          per100g.fat * caloriesPerFatGram,
    );
  }
}
