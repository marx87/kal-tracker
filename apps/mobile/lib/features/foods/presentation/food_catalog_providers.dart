import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/foods/data/food_catalog_repository.dart';
import 'package:kal_tracker/features/foods/domain/food_models.dart';

enum FoodCatalogSection { all, mine, favorites, recent }

final foodCatalogRepositoryProvider = Provider<FoodCatalogRepository>(
  (ref) => FoodCatalogRepository(ref.watch(databaseProvider)),
);

final foodSearchQueryProvider = StateProvider.autoDispose<String>((ref) => '');

final foodCatalogSectionProvider =
    StateProvider.autoDispose<FoodCatalogSection>(
      (ref) => FoodCatalogSection.all,
    );

final visibleFoodsProvider = StreamProvider.autoDispose<List<FoodCatalogItem>>((
  ref,
) async* {
  final profile = await ref.watch(marcoProfileProvider.future);
  final repository = ref.watch(foodCatalogRepositoryProvider);
  final section = ref.watch(foodCatalogSectionProvider);
  final query = ref.watch(foodSearchQueryProvider);

  final stream = switch (section) {
    FoodCatalogSection.all => repository.watchCatalog(
      profileId: profile.id,
      query: query,
    ),
    FoodCatalogSection.mine => repository.watchMine(
      profileId: profile.id,
      query: query,
    ),
    FoodCatalogSection.favorites => repository.watchFavorites(
      profileId: profile.id,
    ),
    FoodCatalogSection.recent => repository.watchRecent(profileId: profile.id),
  };
  final filtersOnDatabase =
      section == FoodCatalogSection.all || section == FoodCatalogSection.mine;

  await for (final foods in stream) {
    final cleanQuery = query.trim().toLowerCase();
    if (filtersOnDatabase || cleanQuery.isEmpty) {
      yield foods;
      continue;
    }
    yield foods
        .where(
          (food) =>
              food.name.toLowerCase().contains(cleanQuery) ||
              (food.brand?.toLowerCase().contains(cleanQuery) ?? false),
        )
        .toList(growable: false);
  }
});

final foodPickerProvider = StreamProvider.autoDispose
    .family<List<FoodCatalogItem>, String>((ref, query) async* {
      final profile = await ref.watch(marcoProfileProvider.future);
      yield* ref
          .watch(foodCatalogRepositoryProvider)
          .watchCatalog(profileId: profile.id, query: query, limit: 100);
    });
