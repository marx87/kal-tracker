import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kal_tracker/core/presentation/app_shell.dart';
import 'package:kal_tracker/features/diary/presentation/today_diary_screen.dart';
import 'package:kal_tracker/features/foods/presentation/food_catalog_screen.dart';
import 'package:kal_tracker/features/recipes/presentation/recipe_detail_screen.dart';
import 'package:kal_tracker/features/recipes/presentation/recipe_editor_screen.dart';
import 'package:kal_tracker/features/recipes/presentation/recipes_screen.dart';
import 'package:kal_tracker/features/wellbeing/presentation/progress_screen.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            AppShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/',
                name: 'today',
                builder: (context, state) => const TodayDiaryScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/foods',
                name: 'foods',
                builder: (context, state) => const FoodCatalogScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/recipes',
                name: 'recipes',
                builder: (context, state) => const RecipesScreen(),
                routes: [
                  GoRoute(
                    path: 'new',
                    name: 'recipe-create',
                    builder: (context, state) => const RecipeEditorScreen(),
                  ),
                  GoRoute(
                    path: ':recipeId',
                    name: 'recipe-details',
                    builder: (context, state) => RecipeDetailScreen(
                      recipeId: state.pathParameters['recipeId']!,
                    ),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/progress',
                name: 'progress',
                builder: (context, state) => const ProgressScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
