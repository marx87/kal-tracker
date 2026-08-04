import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/recipes/data/recipe_catalog_importer.dart';
import 'package:kal_tracker/features/recipes/data/recipe_repository.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_catalog_asset.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';
import 'package:uuid/uuid.dart';

Map<String, Object?> _ingredient({
  required String name,
  required double grams,
  double calories = 110,
  double protein = 23,
  double carbs = 0,
  double fat = 1.5,
}) => {
  'name': name,
  'grams': grams,
  'per100g': {
    'calories': calories,
    'protein': protein,
    'carbs': carbs,
    'fat': fat,
  },
};

/// Stessa forma prodotta da scripts/build_recipe_catalog.py: i totali sono
/// sempre CALCOLATI dagli ingredienti, mai dichiarati.
Map<String, Object?> _recipe({
  required String slug,
  required String name,
  List<String> tags = const ['pranzo', 'proteico'],
  int servings = 2,
  List<Map<String, Object?>>? ingredients,
}) {
  final rows =
      ingredients ??
      [
        _ingredient(name: 'Petto di pollo', grams: 300),
        _ingredient(
          name: 'Riso basmati cotto',
          grams: 200,
          calories: 130,
          protein: 2.7,
          carbs: 28.2,
          fat: 0.3,
        ),
      ];
  var calories = 0.0, protein = 0.0, carbs = 0.0, fat = 0.0;
  for (final row in rows) {
    final per100g = row['per100g']! as Map<String, Object?>;
    final factor = (row['grams']! as double) / 100;
    calories += (per100g['calories']! as double) * factor;
    protein += (per100g['protein']! as double) * factor;
    carbs += (per100g['carbs']! as double) * factor;
    fat += (per100g['fat']! as double) * factor;
  }
  return {
    'slug': slug,
    'name': name,
    'tags': tags,
    'description': 'Descrizione di prova del ricettario.',
    'instructions': '1. Prepara gli ingredienti.\n2. Cuoci e servi.',
    'servings': servings,
    'prepMinutes': 15,
    'ingredients': rows,
    'totals': {
      'calories': calories,
      'protein': protein,
      'carbs': carbs,
      'fat': fat,
    },
  };
}

String _asset({int version = 1, required List<Map<String, Object?>> recipes}) =>
    jsonEncode({'version': version, 'recipes': recipes});

void main() {
  late AppDatabase database;
  late RecipeRepository repository;
  late String profileId;
  late Directory stateDirectory;

  final baseRecipes = [
    _recipe(slug: 'bowl-di-prova', name: 'Bowl di prova'),
    _recipe(
      slug: 'insalata-di-prova',
      name: 'Insalata di prova',
      tags: const ['cena', 'leggero'],
    ),
  ];

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
    repository = RecipeRepository(database);
    stateDirectory = await Directory.systemTemp.createTemp('kal-recipe-test');
  });

  tearDown(() async {
    await database.close();
    await stateDirectory.delete(recursive: true);
  });

  RecipeCatalogImporter importer(String Function() asset) =>
      RecipeCatalogImporter(
        repository,
        loadAsset: () async => asset(),
        stateDirectory: () async => stateDirectory,
      );

  Future<List<LocalFitRecipe>> allRows() =>
      database.select(database.fitRecipes).get();

  Future<List<SyncOutboxData>> outboxRows() async =>
      (await database.select(database.syncOutbox).get())
          .where((row) => row.entityType == 'fit_recipe')
          .toList(growable: false);

  test('la prima esecuzione installa tutte le ricette con outbox', () async {
    final result = await importer(
      () => _asset(recipes: baseRecipes),
    ).importIfNeeded(profileId);

    expect(result.status, RecipeCatalogImportStatus.imported);
    expect(result.version, 1);
    expect(result.installedCount, 2);

    final rows = await allRows();
    expect(rows, hasLength(2));
    expect(rows.every((row) => row.profileId == profileId), isTrue);
    expect(rows.every((row) => row.deletedAt == null), isTrue);
    expect(
      await database.select(database.recipeIngredients).get(),
      hasLength(4),
    );

    // Ogni ricetta installata è una FitRecipe normale: una riga di outbox
    // 'upsert' a testa, come una ricetta creata a mano.
    final outbox = await outboxRows();
    expect(outbox, hasLength(2));
    expect(outbox.every((row) => row.operation == 'upsert'), isTrue);

    // Lo snapshot in tabella è ricalcolato dagli ingredienti e combacia con
    // i totali scritti nell'asset dallo script di build.
    final asset = RecipeCatalogAsset.fromJsonString(
      _asset(recipes: baseRecipes),
    );
    for (final entry in asset.recipes) {
      final row = rows.singleWhere(
        (row) => row.id == RecipeCatalogImporter.recipeId(entry.slug),
      );
      expect(row.totalCalories, closeTo(entry.totals.calories, 0.01));
      expect(row.totalProtein, closeTo(entry.totals.protein, 0.01));
      expect(row.totalCarbs, closeTo(entry.totals.carbs, 0.01));
      expect(row.totalFat, closeTo(entry.totals.fat, 0.01));
    }
  });

  test('la seconda esecuzione è un no-op grazie alla version', () async {
    final catalogImporter = importer(() => _asset(recipes: baseRecipes));
    await catalogImporter.importIfNeeded(profileId);

    // Se il no-op non funzionasse, questa riga tornerebbe alla seconda run.
    await (database.delete(database.fitRecipes)..where(
          (row) =>
              row.id.equals(RecipeCatalogImporter.recipeId('bowl-di-prova')),
        ))
        .go();

    final second = await catalogImporter.importIfNeeded(profileId);
    expect(second.status, RecipeCatalogImportStatus.upToDate);
    expect(second.version, 1);
    expect(await allRows(), hasLength(1));
    expect(await outboxRows(), hasLength(2));
  });

  test(
    'il version bump installa solo le nuove e rispetta i tombstone',
    () async {
      final catalogImporter = importer(() => _asset(recipes: baseRecipes));
      await catalogImporter.importIfNeeded(profileId);

      final bowlId = RecipeCatalogImporter.recipeId('bowl-di-prova');
      final insalataId = RecipeCatalogImporter.recipeId('insalata-di-prova');
      await repository.deleteRecipe(bowlId);
      final untouchedBefore = (await allRows()).singleWhere(
        (row) => row.id == insalataId,
      );

      final bumped = await importer(
        () => _asset(
          version: 2,
          recipes: [
            ...baseRecipes,
            _recipe(slug: 'zuppa-di-prova', name: 'Zuppa di prova'),
          ],
        ),
      ).importIfNeeded(profileId);

      expect(bumped.status, RecipeCatalogImportStatus.imported);
      expect(bumped.version, 2);
      expect(bumped.installedCount, 1);

      final rows = await allRows();
      expect(rows, hasLength(3));

      // La ricetta cancellata resta un tombstone: non risorge al re-import.
      final bowl = rows.singleWhere((row) => row.id == bowlId);
      expect(bowl.deletedAt, isNotNull);

      // Quella già presente non viene toccata in alcun campo.
      final untouchedAfter = rows.singleWhere((row) => row.id == insalataId);
      expect(untouchedAfter.updatedAt, untouchedBefore.updatedAt);
      expect(untouchedAfter.totalCalories, untouchedBefore.totalCalories);

      // In outbox: 2 install v1 + 1 delete + SOLO la nuova del bump.
      final operations = (await outboxRows()).map((row) => row.operation);
      expect(operations, ['upsert', 'upsert', 'delete', 'upsert']);
    },
  );

  test('un asset illeggibile non blocca: si ritenta al lancio dopo', () async {
    final failed = await importer(
      () => throw Exception('asset mancante'),
    ).importIfNeeded(profileId);
    expect(failed.status, RecipeCatalogImportStatus.failed);
    expect(await allRows(), isEmpty);

    final retried = await importer(
      () => _asset(recipes: baseRecipes),
    ).importIfNeeded(profileId);
    expect(retried.status, RecipeCatalogImportStatus.imported);
    expect(await allRows(), hasLength(2));
  });

  group('asset reale del ricettario', () {
    final raw = File(
      'assets/catalog/ricettario_fit_v1.json',
    ).readAsStringSync();

    test('i totali dell\'asset combaciano con RecipeNutritionCalculator', () {
      final asset = RecipeCatalogAsset.fromJsonString(raw);
      expect(asset.version, 1);
      expect(asset.recipes, hasLength(152));
      expect(
        asset.recipes.map((entry) => entry.slug).toSet(),
        hasLength(152),
        reason: 'gli slug sono API permanenti e devono essere unici',
      );

      for (final entry in asset.recipes) {
        final nutrition = RecipeNutritionCalculator.calculate(
          ingredients: entry.draft.ingredients,
          servings: entry.draft.servings,
        );
        expect(
          nutrition.total.calories,
          closeTo(entry.totals.calories, 0.01),
          reason: entry.slug,
        );
        expect(
          nutrition.total.protein,
          closeTo(entry.totals.protein, 0.01),
          reason: entry.slug,
        );
        expect(
          nutrition.total.carbs,
          closeTo(entry.totals.carbs, 0.01),
          reason: entry.slug,
        );
        expect(
          nutrition.total.fat,
          closeTo(entry.totals.fat, 0.01),
          reason: entry.slug,
        );
      }
    });

    test(
      'installa 152 ricette e lista, ricerca e tag restano corretti',
      () async {
        final asset = RecipeCatalogAsset.fromJsonString(raw);
        final result = await importer(() => raw).importIfNeeded(profileId);
        expect(result.status, RecipeCatalogImportStatus.imported);
        expect(result.installedCount, 152);
        expect(await outboxRows(), hasLength(152));

        final all = await repository.watchRecipes(profileId).first;
        expect(all, hasLength(152));

        // Il filtro tag è un match esatto sul vocabolario controllato: lo
        // stesso insieme che si ottiene leggendo l'asset.
        final mealPrep = await repository
            .watchRecipes(profileId, tag: 'meal prep')
            .first;
        expect(mealPrep.map((recipe) => recipe.name).toSet(), {
          for (final entry in asset.recipes)
            if (entry.draft.tags.contains('meal prep')) entry.draft.name,
        });

        // La ricerca copre nome e ingredienti anche con il ricettario pieno.
        final straccetti = await repository
            .watchRecipes(profileId, search: 'straccetti')
            .first;
        expect(straccetti.map((recipe) => recipe.name).toSet(), {
          for (final entry in asset.recipes)
            if (entry.draft.name.toLowerCase().contains('straccetti') ||
                entry.draft.ingredients.any(
                  (ingredient) =>
                      ingredient.name.toLowerCase().contains('straccetti'),
                ))
              entry.draft.name,
        });
        expect(straccetti, isNotEmpty);

        // Le starter convivono con il ricettario senza doppioni.
        await repository.ensureStarterRecipes(profileId);
        expect(await repository.watchRecipes(profileId).first, hasLength(158));
        expect(await outboxRows(), hasLength(158));
      },
    );
  });

  test('gli id dei seed non dipendono dal profilo: una reinstallazione '
      'riproduce gli stessi id e le starter legacy non si duplicano', () async {
    await importer(
      () => _asset(recipes: baseRecipes),
    ).importIfNeeded(profileId);
    await repository.ensureStarterRecipes(profileId);
    final firstInstallIds = {for (final row in await allRows()) row.id};

    // «Reinstallazione»: database nuovo e profileId v4 nuovo, stesso asset.
    final reinstall = AppDatabase(NativeDatabase.memory());
    addTearDown(reinstall.close);
    final reinstallProfileId = (await LocalProfileRepository(
      reinstall,
    ).getOrCreateMarco()).id;
    expect(reinstallProfileId, isNot(profileId));
    final reinstallRepository = RecipeRepository(reinstall);
    final reinstallState = await Directory.systemTemp.createTemp('kal-recipe');
    addTearDown(() => reinstallState.delete(recursive: true));
    await RecipeCatalogImporter(
      reinstallRepository,
      loadAsset: () async => _asset(recipes: baseRecipes),
      stateDirectory: () async => reinstallState,
    ).importIfNeeded(reinstallProfileId);
    await reinstallRepository.ensureStarterRecipes(reinstallProfileId);

    // Stessi id nonostante il profilo diverso: con il sync attivo il pull
    // riconcilia le righe invece di duplicarle e i tombstone pushati da
    // un'altra installazione restano validi.
    final reinstallIds = {
      for (final row in await reinstall.select(reinstall.fitRecipes).get())
        row.id,
    };
    expect(reinstallIds, firstInstallIds);

    // Migrazione: un device aggiornato ha già le starter con il vecchio id
    // per-profilo; ensureStarterRecipes non le reinstalla con l'id nuovo.
    final legacy = AppDatabase(NativeDatabase.memory());
    addTearDown(legacy.close);
    final legacyProfileId = (await LocalProfileRepository(
      legacy,
    ).getOrCreateMarco()).id;
    final legacyRepository = RecipeRepository(legacy);
    final legacyBowlId = const Uuid().v5(
      Namespace.url.value,
      'https://kal-tracker.local/starter/$legacyProfileId/bowl-pollo-riso',
    );
    await legacyRepository.installMissingRecipes(
      profileId: legacyProfileId,
      entries: [
        (
          id: legacyBowlId,
          draft: const FitRecipeDraft(
            name: 'Bowl pollo e riso',
            tags: ['pranzo', 'proteico'],
            servings: 2,
            ingredients: [
              RecipeIngredientDraft(
                name: 'Petto di pollo',
                grams: 300,
                per100g: Nutrients(
                  calories: 165,
                  protein: 31,
                  carbs: 0,
                  fat: 3.6,
                ),
              ),
            ],
          ),
        ),
      ],
    );
    await legacyRepository.ensureStarterRecipes(legacyProfileId);
    final legacyRows = await legacy.select(legacy.fitRecipes).get();
    expect(legacyRows, hasLength(6), reason: '1 legacy + 5 starter nuove');
    expect(
      legacyRows.where((row) => row.name == 'Bowl pollo e riso'),
      hasLength(1),
      reason: 'la starter legacy non deve rinascere con l\'id nuovo',
    );
    expect(legacyRows.map((row) => row.id), contains(legacyBowlId));
  });
}
