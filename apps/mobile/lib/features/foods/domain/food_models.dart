import 'package:kal_tracker/features/diary/domain/nutrition.dart';

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
    if (barcode != null && barcode!.trim().length > 32) {
      throw const FormatException('Il codice a barre è troppo lungo.');
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
}
