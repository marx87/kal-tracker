import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/recipes/data/recipe_repository.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_catalog_asset.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

enum RecipeCatalogImportStatus { imported, upToDate, failed }

class RecipeCatalogImportResult {
  const RecipeCatalogImportResult.imported({
    required int this.version,
    required this.installedCount,
  }) : status = RecipeCatalogImportStatus.imported;

  const RecipeCatalogImportResult.upToDate({required int this.version})
    : status = RecipeCatalogImportStatus.upToDate,
      installedCount = 0;

  const RecipeCatalogImportResult.failed()
    : status = RecipeCatalogImportStatus.failed,
      version = null,
      installedCount = 0;

  final RecipeCatalogImportStatus status;
  final int? version;
  final int installedCount;
}

/// Installa il ricettario fit dall'asset nel ricettario del profilo.
///
/// È il meccanismo starter esteso all'asset: le ricette diventano FitRecipes
/// normali dell'utente (modificabili, cancellabili, con la loro riga di
/// outbox) e l'id deterministico uuid v5 sullo slug fa rispettare i
/// tombstone a ogni re-import. Diverso dal CatalogSeedImporter dei piatti,
/// che scrive righe condivise senza profilo e senza outbox.
///
/// L'import è versionato (file JSON locale, stesso pattern del catalogo
/// piatti): a parità di version non si tocca nemmeno il database. Un version
/// bump futuro installa SOLO le ricette nuove: quelle esistenti o cancellate
/// non vengono mai toccate, per questo gli slug dell'asset sono API
/// permanenti e non vanno mai rinominati.
class RecipeCatalogImporter {
  RecipeCatalogImporter(
    this._repository, {
    Future<String> Function()? loadAsset,
    Future<Directory> Function()? stateDirectory,
  }) : _loadAsset = loadAsset ?? _loadBundledAsset,
       _stateDirectory = stateDirectory ?? getApplicationSupportDirectory;

  static const String assetPath = 'assets/catalog/ricettario_fit_v1.json';
  static const String stateFileName = 'kal-tracker-recipe-catalog-state.json';

  final RecipeRepository _repository;
  final Future<String> Function() _loadAsset;
  final Future<Directory> Function() _stateDirectory;

  static Future<String> _loadBundledAsset() => rootBundle.loadString(assetPath);

  /// Id deterministico della ricetta installata: dipende SOLO dallo slug,
  /// stabile tra le version dell'asset, mai dal profileId locale (che è un
  /// uuid v4 casuale, diverso per ogni installazione). Così un reinstall o
  /// un secondo device riproducono gli stessi id: il sync riconcilia invece
  /// di duplicare e i tombstone pushati da un'altra installazione restano
  /// validi. Il pull riconduce comunque ogni riga al profilo locale.
  static String recipeId(String slug) => const Uuid().v5(
    Namespace.url.value,
    'https://kal-tracker.local/recipe-catalog/$slug',
  );

  /// Non lancia mai: se qualcosa va storto l'app parte lo stesso e
  /// l'import si ritenta al lancio successivo.
  Future<RecipeCatalogImportResult> importIfNeeded(String profileId) async {
    try {
      final asset = RecipeCatalogAsset.fromJsonString(await _loadAsset());
      final imported = await _readState();
      if (imported != null &&
          imported.profileId == profileId &&
          imported.version >= asset.version) {
        return RecipeCatalogImportResult.upToDate(version: imported.version);
      }

      final installed = await _repository.installMissingRecipes(
        profileId: profileId,
        entries: [
          for (final entry in asset.recipes)
            (id: recipeId(entry.slug), draft: entry.draft),
        ],
      );
      await _writeState(asset.version, profileId, AppTime.nowUtc());
      return RecipeCatalogImportResult.imported(
        version: asset.version,
        installedCount: installed,
      );
    } on Object {
      return const RecipeCatalogImportResult.failed();
    }
  }

  Future<({int version, String? profileId})?> _readState() async {
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
      final profileId = decoded['profile_id'];
      if (version is! int) {
        return null;
      }
      return (version: version, profileId: profileId as String?);
    } on Object {
      return null;
    }
  }

  Future<void> _writeState(int version, String profileId, DateTime now) async {
    final file = await _stateFile();
    await file.writeAsString(
      jsonEncode({
        'imported_version': version,
        'profile_id': profileId,
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
