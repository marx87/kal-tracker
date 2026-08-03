import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/foods/domain/catalog_asset.dart';
import 'package:kal_tracker/features/foods/domain/food_models.dart';
import 'package:path_provider/path_provider.dart';

enum CatalogImportStatus { imported, upToDate, failed }

class CatalogImportResult {
  const CatalogImportResult.imported({
    required int this.version,
    required this.itemCount,
  }) : status = CatalogImportStatus.imported;

  const CatalogImportResult.upToDate({required int this.version})
    : status = CatalogImportStatus.upToDate,
      itemCount = 0;

  const CatalogImportResult.failed()
    : status = CatalogImportStatus.failed,
      version = null,
      itemCount = 0;

  final CatalogImportStatus status;
  final int? version;
  final int itemCount;
}

/// Importa il catalogo piatti dall'asset nella tabella Foods.
///
/// I piatti diventano righe con `source: 'catalog'`, `ownerProfileId` NULL e
/// NESSUNA riga di outbox: come i seed sono visibili a tutti i profili, non
/// si eliminano, la modifica crea una copia personale e il push di sync non
/// li tocca (il push è interamente outbox-driven).
///
/// L'import è versionato: la version dell'asset viene confrontata con quella
/// già importata (file JSON locale, stesso pattern di BackupStorage) e il
/// batch parte solo se serve. `insertOrIgnore` sugli id stabili `cat-*` rende
/// l'operazione idempotente e non tocca mai le copie personali.
class CatalogSeedImporter {
  CatalogSeedImporter(
    this._database, {
    Future<String> Function()? loadAsset,
    Future<Directory> Function()? stateDirectory,
  }) : _loadAsset = loadAsset ?? _loadBundledAsset,
       _stateDirectory = stateDirectory ?? getApplicationSupportDirectory;

  static const String assetPath = 'assets/catalog/catalogo_piatti_v1.json';
  static const String stateFileName = 'kal-tracker-catalog-state.json';

  final AppDatabase _database;
  final Future<String> Function() _loadAsset;
  final Future<Directory> Function() _stateDirectory;

  static Future<String> _loadBundledAsset() => rootBundle.loadString(assetPath);

  /// Non lancia mai: se qualcosa va storto l'app parte lo stesso e
  /// l'import si ritenta al lancio successivo.
  Future<CatalogImportResult> importIfNeeded() async {
    try {
      final asset = CatalogAsset.fromJsonString(await _loadAsset());
      final importedVersion = await _readImportedVersion();
      if (importedVersion != null && importedVersion >= asset.version) {
        return CatalogImportResult.upToDate(version: importedVersion);
      }

      // Alcuni piatti dell'asset replicano i seed essenziali per nome
      // (es. Banana, Mandorle) con valori leggermente diversi: la riga seed
      // resta l'unica, così preferiti e recenti non si spalmano su doppioni.
      final seedNameKeys = await _seedNameKeys();
      final items = [
        for (final item in asset.items)
          if (!seedNameKeys.contains(CatalogSearchIndex.slugify(item.name)))
            item,
      ];

      final now = AppTime.nowUtc();
      await _database.batch((batch) {
        batch.insertAll(_database.foods, [
          for (final item in items)
            FoodsCompanion.insert(
              id: item.id,
              name: item.name,
              caloriesPer100g: item.per100g.calories,
              proteinPer100g: item.per100g.protein,
              carbsPer100g: item.per100g.carbs,
              fatPer100g: item.per100g.fat,
              defaultServingGrams: Value(item.portionGrams),
              source: const Value(FoodSource.catalog),
              createdAt: now,
              updatedAt: now,
            ),
        ], mode: InsertMode.insertOrIgnore);
      });
      await _writeImportedVersion(asset.version, now);
      return CatalogImportResult.imported(
        version: asset.version,
        itemCount: items.length,
      );
    } on Object {
      return const CatalogImportResult.failed();
    }
  }

  Future<Set<String>> _seedNameKeys() async {
    final rows = await (_database.select(
      _database.foods,
    )..where((row) => row.source.equals(FoodSource.seed))).get();
    return {for (final row in rows) CatalogSearchIndex.slugify(row.name)};
  }

  Future<int?> _readImportedVersion() async {
    try {
      final file = await _stateFile();
      if (!file.existsSync()) {
        return null;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        return null;
      }
      final version = decoded['imported_version'];
      return version is int ? version : null;
    } on Object {
      return null;
    }
  }

  Future<void> _writeImportedVersion(int version, DateTime now) async {
    final file = await _stateFile();
    await file.writeAsString(
      jsonEncode({
        'imported_version': version,
        'imported_at': now.toIso8601String(),
      }),
      flush: true,
    );
  }

  Future<File> _stateFile() async {
    final directory = await _stateDirectory();
    return File('${directory.path}/$stateFileName');
  }
}
