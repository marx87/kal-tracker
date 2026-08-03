import 'dart:convert';

import 'package:kal_tracker/features/diary/domain/nutrition.dart';

/// Asset del catalogo piatti (`assets/catalog/catalogo_piatti_v1.json`),
/// generato da `scripts/build_food_catalog.py`.
class CatalogAsset {
  const CatalogAsset({required this.version, required this.items});

  factory CatalogAsset.fromJson(Map<String, Object?> json) {
    final version = json['version'];
    final rawItems = json['items'];
    if (version is! int || rawItems is! List) {
      throw const FormatException('Il formato del catalogo non è valido.');
    }
    return CatalogAsset(
      version: version,
      items: [
        for (final raw in rawItems)
          CatalogAssetItem.fromJson((raw as Map).cast<String, Object?>()),
      ],
    );
  }

  factory CatalogAsset.fromJsonString(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Il formato del catalogo non è valido.');
    }
    return CatalogAsset.fromJson(decoded);
  }

  final int version;
  final List<CatalogAssetItem> items;
}

class CatalogAssetItem {
  const CatalogAssetItem({
    required this.id,
    required this.name,
    required this.category,
    required this.aliases,
    required this.per100g,
    required this.portionGrams,
    this.note,
  });

  factory CatalogAssetItem.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final name = json['name'];
    final category = json['category'];
    final aliases = json['aliases'];
    final note = json['note'];
    if (id is! String ||
        name is! String ||
        category is! String ||
        aliases is! List ||
        (note != null && note is! String)) {
      throw FormatException('Voce del catalogo non valida: $json');
    }
    return CatalogAssetItem(
      id: id,
      name: name,
      category: category,
      aliases: aliases.cast<String>(),
      per100g: Nutrients(
        calories: _toDouble(json['kcalPer100g']),
        protein: _toDouble(json['proteinPer100g']),
        carbs: _toDouble(json['carbsPer100g']),
        fat: _toDouble(json['fatPer100g']),
      ),
      portionGrams: _toDouble(json['portionGrams']),
      note: note as String?,
    );
  }

  final String id;
  final String name;
  final String category;
  final List<String> aliases;
  final Nutrients per100g;
  final double portionGrams;
  final String? note;

  static double _toDouble(Object? value) {
    if (value is! num) {
      throw FormatException('Valore numerico non valido: $value');
    }
    return value.toDouble();
  }
}

/// Indice in memoria costruito dall'asset: alias e categorie non stanno nella
/// tabella Foods (nessuna migrazione dello schema), quindi la ricerca per
/// alias e il filtro per categoria passano da qui tramite gli id stabili.
class CatalogSearchIndex {
  const CatalogSearchIndex._(
    this.categories,
    this._idsByCategory,
    this._foldedAliasesById,
  );

  factory CatalogSearchIndex.fromAsset(CatalogAsset asset) {
    final categories = <String>[];
    final idsByCategory = <String, Set<String>>{};
    final foldedAliasesById = <String, String>{};
    for (final item in asset.items) {
      idsByCategory
          .putIfAbsent(item.category, () {
            categories.add(item.category);
            return <String>{};
          })
          .add(item.id);
      if (item.aliases.isNotEmpty) {
        foldedAliasesById[item.id] = item.aliases.map(_fold).join('\n');
      }
    }
    return CatalogSearchIndex._(
      List.unmodifiable(categories),
      idsByCategory,
      foldedAliasesById,
    );
  }

  static const CatalogSearchIndex empty = CatalogSearchIndex._([], {}, {});

  /// Categorie nell'ordine dell'asset (già ordinato dallo script).
  final List<String> categories;
  final Map<String, Set<String>> _idsByCategory;
  final Map<String, String> _foldedAliasesById;

  Set<String> idsForCategory(String category) =>
      _idsByCategory[category] ?? const <String>{};

  /// Id dei piatti con almeno un alias che contiene la query
  /// (minuscole e senza accenti: «matriciana» trova «Pasta all'amatriciana»).
  List<String> aliasMatchIds(String query) {
    final folded = _fold(query.trim());
    if (folded.isEmpty || _foldedAliasesById.isEmpty) {
      return const [];
    }
    return [
      for (final entry in _foldedAliasesById.entries)
        if (entry.value.contains(folded)) entry.key,
    ];
  }

  bool aliasMatches(String foodId, String query) {
    final folded = _fold(query.trim());
    if (folded.isEmpty) {
      return false;
    }
    return _foldedAliasesById[foodId]?.contains(folded) ?? false;
  }

  /// Slug per chiavi stabili dei widget (es. «Primi piatti» -> primi-piatti).
  static String slugify(String value) => _fold(
    value,
  ).replaceAll(RegExp('[^a-z0-9]+'), '-').replaceAll(RegExp('^-+|-+\$'), '');

  static const Map<String, String> _accents = {
    'à': 'a',
    'á': 'a',
    'â': 'a',
    'ä': 'a',
    'ã': 'a',
    'è': 'e',
    'é': 'e',
    'ê': 'e',
    'ë': 'e',
    'ì': 'i',
    'í': 'i',
    'î': 'i',
    'ï': 'i',
    'ò': 'o',
    'ó': 'o',
    'ô': 'o',
    'ö': 'o',
    'õ': 'o',
    'ù': 'u',
    'ú': 'u',
    'û': 'u',
    'ü': 'u',
    'ç': 'c',
    'ñ': 'n',
  };

  static String _fold(String value) {
    final lower = value.toLowerCase();
    final buffer = StringBuffer();
    for (var i = 0; i < lower.length; i++) {
      final char = lower[i];
      buffer.write(_accents[char] ?? char);
    }
    return buffer.toString();
  }
}
