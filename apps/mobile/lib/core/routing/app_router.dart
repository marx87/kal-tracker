import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kal_tracker/core/presentation/app_shell.dart';
import 'package:kal_tracker/core/sync/sync_engine.dart';
import 'package:kal_tracker/features/backup/presentation/backup_screen.dart';
import 'package:kal_tracker/features/diary/presentation/today_diary_screen.dart';
import 'package:kal_tracker/features/foods/presentation/food_catalog_screen.dart';
import 'package:kal_tracker/features/foods/presentation/food_editor_screen.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_proposals_listener.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_review_screen.dart';
import 'package:kal_tracker/features/quick_add/barcode_scan_screen.dart';
import 'package:kal_tracker/features/recipes/presentation/recipe_detail_screen.dart';
import 'package:kal_tracker/features/recipes/presentation/recipe_editor_screen.dart';
import 'package:kal_tracker/features/recipes/presentation/recipes_screen.dart';
import 'package:kal_tracker/features/sync/presentation/sync_screen.dart';
import 'package:kal_tracker/features/weekly_plan/presentation/shopping_list_screen.dart';
import 'package:kal_tracker/features/weekly_plan/presentation/weekly_plan_screen.dart';
import 'package:kal_tracker/features/wellbeing/presentation/progress_screen.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  // Avvia il motore di sync insieme all'app (inerte senza configurazione).
  ref.watch(syncBootstrapProvider);
  final router = GoRouter(
    routes: [
      StatefulShellRoute.indexedStack(
        // Il listener tiene vivo il polling dei job foto e mostra la
        // notifica in-app "Proposta pronta da rivedere".
        builder: (context, state, navigationShell) => PhotoProposalsListener(
          child: AppShell(navigationShell: navigationShell),
        ),
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
                routes: [
                  GoRoute(
                    path: 'new',
                    name: 'food-create',
                    builder: (context, state) => const FoodEditorScreen(),
                  ),
                  GoRoute(
                    path: ':foodId/edit',
                    name: 'food-edit',
                    builder: (context, state) => FoodEditorScreen(
                      foodId: state.pathParameters['foodId'],
                    ),
                  ),
                ],
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
                    path: ':recipeId/edit',
                    name: 'recipe-edit',
                    builder: (context, state) => RecipeEditorScreen(
                      recipeId: state.pathParameters['recipeId'],
                    ),
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
          // Quarto branch: deve restare allineato alla quarta destinazione
          // ('nav_plan') della barra in app_shell.dart. La lista della spesa
          // è una sottorotta, quindi conserva la barra in basso.
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/plan',
                name: 'plan',
                builder: (context, state) => const WeeklyPlanScreen(),
                routes: [
                  GoRoute(
                    path: 'shopping',
                    name: 'plan-shopping',
                    builder: (context, state) => const ShoppingListScreen(),
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
                routes: [
                  GoRoute(
                    path: 'backup',
                    name: 'backup',
                    builder: (context, state) => const BackupScreen(),
                  ),
                  GoRoute(
                    path: 'sync',
                    name: 'sync',
                    builder: (context, state) => const SyncScreen(),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      // Fuori dalla shell: la revisione delle proposte foto è a schermo
      // intero e raggiungibile anche dalla notifica in-app.
      GoRoute(
        path: '/photo-review/:jobId',
        name: 'photo-review',
        builder: (context, state) =>
            PhotoReviewScreen(jobId: state.pathParameters['jobId']!),
      ),
      // Anche lo scanner vive fuori dalla shell: schermo intero,
      // raggiungibile dal menu smart del FAB o direttamente come rotta.
      GoRoute(
        path: '/barcode-scan',
        name: 'barcode-scan',
        builder: (context, state) => const BarcodeScanScreen(),
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
