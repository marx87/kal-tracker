import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/foods/domain/catalog_asset.dart';

void main() {
  const rawAsset = '''
  {
    "version": 3,
    "items": [
      {
        "id": "cat-pasta-al-ragu",
        "name": "Pasta al ragù",
        "aliases": ["pasta alla bolognese", "tagliatelle al ragù"],
        "category": "Primi piatti",
        "kcalPer100g": 150,
        "proteinPer100g": 7,
        "carbsPer100g": 20,
        "fatPer100g": 4.5,
        "portionGrams": 350,
        "note": "valori da cotto e condito"
      },
      {
        "id": "cat-tiramisu",
        "name": "Tiramisù",
        "aliases": ["tiramisu della nonna"],
        "category": "Colazione, dolci e snack",
        "kcalPer100g": 290,
        "proteinPer100g": 5,
        "carbsPer100g": 32,
        "fatPer100g": 16,
        "portionGrams": 120
      }
    ]
  }
  ''';

  test('l’asset si legge con version, nutrienti per 100 g e note', () {
    final asset = CatalogAsset.fromJsonString(rawAsset);
    expect(asset.version, 3);
    expect(asset.items, hasLength(2));

    final ragu = asset.items.first;
    expect(ragu.id, 'cat-pasta-al-ragu');
    expect(ragu.category, 'Primi piatti');
    expect(ragu.per100g.calories, 150);
    expect(ragu.per100g.fat, 4.5);
    expect(ragu.portionGrams, 350);
    expect(ragu.note, 'valori da cotto e condito');
    expect(asset.items.last.note, isNull);
  });

  test('un asset malformato solleva FormatException', () {
    expect(
      () => CatalogAsset.fromJsonString('{"items": []}'),
      throwsFormatException,
    );
    expect(
      () => CatalogAsset.fromJsonString('{"version": 1, "items": [{}]}'),
      throwsFormatException,
    );
  });

  test('l’indice risolve alias (senza accenti) e categorie', () {
    final index = CatalogSearchIndex.fromAsset(
      CatalogAsset.fromJsonString(rawAsset),
    );

    expect(index.categories, ['Primi piatti', 'Colazione, dolci e snack']);
    expect(index.idsForCategory('Primi piatti'), {'cat-pasta-al-ragu'});
    expect(index.idsForCategory('Sconosciuta'), isEmpty);

    // «bolognese» non compare nel nome: arriva dall'alias.
    expect(index.aliasMatchIds('bolognese'), ['cat-pasta-al-ragu']);
    // Accenti ignorati in entrambe le direzioni.
    expect(index.aliasMatchIds('ragù'), ['cat-pasta-al-ragu']);
    expect(index.aliasMatchIds('TIRAMISU'), ['cat-tiramisu']);
    expect(index.aliasMatchIds(''), isEmpty);
    expect(index.aliasMatches('cat-tiramisu', 'nonna'), isTrue);
    expect(index.aliasMatches('cat-tiramisu', 'bolognese'), isFalse);

    expect(
      CatalogSearchIndex.slugify('Colazione, dolci e snack'),
      'colazione-dolci-e-snack',
    );
    expect(CatalogSearchIndex.empty.aliasMatchIds('bolognese'), isEmpty);
  });

  test('l’asset reale è coerente e la ricerca resta corretta su ~800 voci', () {
    final asset = CatalogAsset.fromJsonString(
      File('assets/catalog/catalogo_piatti_v1.json').readAsStringSync(),
    );

    // Version 2: audit "porzioni oneste" (solo portionGrams ritoccati).
    expect(asset.version, 2);
    expect(asset.items, hasLength(795));

    final ids = asset.items.map((item) => item.id).toSet();
    expect(ids, hasLength(asset.items.length), reason: 'id duplicati');
    expect(ids.every((id) => id.startsWith('cat-')), isTrue);
    expect(
      asset.items.every(
        (item) =>
            item.per100g.isValid &&
            item.portionGrams > 0 &&
            item.name.trim().isNotEmpty,
      ),
      isTrue,
    );

    final index = CatalogSearchIndex.fromAsset(asset);
    expect(index.categories, hasLength(10));

    // L'unione delle categorie copre tutto il catalogo, senza sovrapposizioni.
    final union = <String>{};
    for (final category in index.categories) {
      final categoryIds = index.idsForCategory(category);
      expect(categoryIds, isNotEmpty);
      expect(union.intersection(categoryIds), isEmpty);
      union.addAll(categoryIds);
    }
    expect(union, hasLength(asset.items.length));

    // Ricerca per alias su tutto il catalogo: conta la correttezza, non i ms.
    expect(index.aliasMatchIds('bolognese'), contains('cat-pasta-al-ragu'));
    expect(
      index.aliasMatchIds('spaghettata di mezzanotte'),
      contains('cat-pasta-aglio-olio-e-peperoncino'),
    );
    expect(
      index.aliasMatchIds('matriciana'),
      contains('cat-pasta-all-amatriciana'),
    );
    expect(index.aliasMatchIds('xyzzy-inesistente'), isEmpty);
  });
}
