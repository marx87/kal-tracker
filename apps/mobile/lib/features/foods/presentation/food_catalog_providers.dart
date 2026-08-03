import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/foods/data/catalog_seed_importer.dart';
import 'package:kal_tracker/features/foods/data/food_catalog_repository.dart';
import 'package:kal_tracker/features/foods/domain/catalog_asset.dart';
import 'package:kal_tracker/features/foods/domain/food_models.dart';

enum FoodCatalogSection { all, mine, favorites, recent }

final foodCatalogRepositoryProvider = Provider<FoodCatalogRepository>(
  (ref) => FoodCatalogRepository(ref.watch(databaseProvider)),
);

final catalogSeedImporterProvider = Provider<CatalogSeedImporter>(
  (ref) => CatalogSeedImporter(ref.watch(databaseProvider)),
);

/// Indice alias/categorie caricato dall'asset del catalogo: vive in memoria,
/// la tabella Foods non cambia. Se l'asset manca la ricerca resta su
/// nome e marca e i chip di categoria non compaiono.
final catalogSearchIndexProvider = FutureProvider<CatalogSearchIndex>((
  ref,
) async {
  try {
    final raw = await rootBundle.loadString(CatalogSeedImporter.assetPath);
    return CatalogSearchIndex.fromAsset(CatalogAsset.fromJsonString(raw));
  } on Object {
    return CatalogSearchIndex.empty;
  }
});

final foodSearchQueryProvider = StateProvider.autoDispose<String>((ref) => '');

final foodCatalogSectionProvider =
    StateProvider.autoDispose<FoodCatalogSection>(
      (ref) => FoodCatalogSection.all,
    );

/// Categoria del catalogo selezionata (null = tutte).
final foodCategoryFilterProvider = StateProvider.autoDispose<String?>(
  (ref) => null,
);

final visibleFoodsProvider = StreamProvider.autoDispose<List<FoodCatalogItem>>((
  ref,
) async* {
  // Tutte le watch sincrone PRIMA del primo await: durante il rebuild i
  // provider autoDispose osservati (es. la query) resterebbero altrimenti
  // senza listener nel gap asincrono e verrebbero azzerati.
  final repository = ref.watch(foodCatalogRepositoryProvider);
  final section = ref.watch(foodCatalogSectionProvider);
  final query = ref.watch(foodSearchQueryProvider);
  // Finché l'indice non è pronto la ricerca funziona comunque su nome e marca.
  final index =
      ref.watch(catalogSearchIndexProvider).valueOrNull ??
      CatalogSearchIndex.empty;
  final category = ref.watch(foodCategoryFilterProvider);
  final profile = await ref.watch(marcoProfileProvider.future);
  final categoryIds = category == null ? null : index.idsForCategory(category);
  final aliasIds = index.aliasMatchIds(query);
  // Le categorie dell'asset contano 70-90 piatti, più del limit di default
  // (50): con un filtro attivo si sale al tetto del repository, altrimenti
  // le voci oltre la 50esima non comparirebbero mai sfogliando.
  final limit = categoryIds == null ? 50 : 200;

  final stream = switch (section) {
    FoodCatalogSection.all => repository.watchCatalog(
      profileId: profile.id,
      query: query,
      limit: limit,
      aliasMatchIds: aliasIds,
      restrictToIds: categoryIds,
    ),
    FoodCatalogSection.mine => repository.watchMine(
      profileId: profile.id,
      query: query,
      limit: limit,
      aliasMatchIds: aliasIds,
      restrictToIds: categoryIds,
    ),
    FoodCatalogSection.favorites => repository.watchFavorites(
      profileId: profile.id,
    ),
    FoodCatalogSection.recent => repository.watchRecent(profileId: profile.id),
  };
  final filtersOnDatabase =
      section == FoodCatalogSection.all || section == FoodCatalogSection.mine;

  await for (final foods in stream) {
    var visible = foods;
    if (!filtersOnDatabase && categoryIds != null) {
      visible = visible
          .where((food) => categoryIds.contains(food.id))
          .toList(growable: false);
    }
    final cleanQuery = query.trim().toLowerCase();
    if (filtersOnDatabase || cleanQuery.isEmpty) {
      yield visible;
      continue;
    }
    yield visible
        .where(
          (food) =>
              food.name.toLowerCase().contains(cleanQuery) ||
              (food.brand?.toLowerCase().contains(cleanQuery) ?? false) ||
              index.aliasMatches(food.id, query),
        )
        .toList(growable: false);
  }
});

final foodPickerProvider = StreamProvider.autoDispose
    .family<List<FoodCatalogItem>, String>((ref, query) async* {
      final repository = ref.watch(foodCatalogRepositoryProvider);
      final index =
          ref.watch(catalogSearchIndexProvider).valueOrNull ??
          CatalogSearchIndex.empty;
      final profile = await ref.watch(marcoProfileProvider.future);
      yield* repository.watchCatalog(
        profileId: profile.id,
        query: query,
        limit: 100,
        aliasMatchIds: index.aliasMatchIds(query),
      );
    });
