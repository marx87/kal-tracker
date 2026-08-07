import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:kal_tracker/core/presentation/app_shell.dart';
import 'package:kal_tracker/core/sync/sync_engine.dart';
import 'package:kal_tracker/features/backup/presentation/backup_screen.dart';
import 'package:kal_tracker/features/body/presentation/body_screen.dart';
import 'package:kal_tracker/features/body/presentation/scale_screen.dart';
import 'package:kal_tracker/features/coach/presentation/coach_screen.dart';
import 'package:kal_tracker/features/diary/presentation/today_diary_screen.dart';
import 'package:kal_tracker/features/exercises/presentation/exercises_screen.dart';
import 'package:kal_tracker/features/foods/presentation/food_catalog_screen.dart';
import 'package:kal_tracker/features/foods/presentation/food_editor_screen.dart';
import 'package:kal_tracker/features/goal/presentation/goal_screen.dart';
import 'package:kal_tracker/features/gym_import/presentation/gym_import_screen.dart';
import 'package:kal_tracker/features/onboarding/presentation/onboarding_gate.dart';
import 'package:kal_tracker/features/onboarding/presentation/personal_details_screen.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_proposals_listener.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_review_screen.dart';
import 'package:kal_tracker/features/quick_add/barcode_scan_screen.dart';
import 'package:kal_tracker/features/recipes/presentation/recipe_detail_screen.dart';
import 'package:kal_tracker/features/recipes/presentation/recipe_editor_screen.dart';
import 'package:kal_tracker/features/recipes/presentation/recipes_screen.dart';
import 'package:kal_tracker/features/routines/presentation/routine_editor_screen.dart';
import 'package:kal_tracker/features/routines/presentation/routines_screen.dart';
import 'package:kal_tracker/features/sync/presentation/sync_screen.dart';
import 'package:kal_tracker/features/training_profile/presentation/training_settings_screen.dart';
import 'package:kal_tracker/features/weekly_plan/presentation/shopping_list_screen.dart';
import 'package:kal_tracker/features/weekly_plan/presentation/weekly_plan_screen.dart';
import 'package:kal_tracker/features/wellbeing/presentation/progress_screen.dart';
import 'package:kal_tracker/features/workouts/presentation/history/workout_detail_screen.dart';
import 'package:kal_tracker/features/workouts/presentation/history/workout_history_screen.dart';
import 'package:kal_tracker/features/workouts/presentation/live/live_workout_screen.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  // Avvia il motore di sync insieme all'app (inerte senza configurazione).
  ref.watch(syncBootstrapProvider);
  final router = GoRouter(
    routes: [
      StatefulShellRoute.indexedStack(
        // Il listener tiene vivo il polling dei job foto e mostra la
        // notifica in-app "Proposta pronta da rivedere".
        // Il gate del primo avvio sta DENTRO la shell e non attorno al
        // router: il benvenuto apre il calendario della data di nascita, e
        // sopra il router un `Navigator` non c'è ancora.
        builder: (context, state, navigationShell) => PhotoProposalsListener(
          child: OnboardingGate(
            child: AppShell(navigationShell: navigationShell),
          ),
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
              // Le ricette stanno nella stessa voce degli alimenti: sono due
              // modi di rispondere alla stessa domanda, «cosa mangio». Restano
              // una rotta di primo livello per non spezzare i collegamenti
              // esistenti.
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
          // Terzo branch — «Palestra»: schede, catalogo esercizi e storico.
          // La sessione dal vivo sta FUORI dalla shell, in fondo al file: in
          // palestra il telefono deve mostrare una cosa sola.
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/gym',
                name: 'gym',
                builder: (context, state) => const RoutinesScreen(),
                routes: [
                  GoRoute(
                    path: 'new',
                    name: 'routine-create',
                    builder: (context, state) => const RoutineEditorScreen(),
                  ),
                  GoRoute(
                    path: ':routineId/edit',
                    name: 'routine-edit',
                    builder: (context, state) => RoutineEditorScreen(
                      routineId: state.pathParameters['routineId'],
                    ),
                  ),
                ],
              ),
              GoRoute(
                path: '/exercises',
                name: 'exercises',
                builder: (context, state) => const ExercisesScreen(),
              ),
              GoRoute(
                path: '/workouts',
                name: 'workout-history',
                builder: (context, state) => WorkoutHistoryScreen(
                  onOpenSession: (context, id) => context.pushNamed(
                    'workout-detail',
                    pathParameters: {'workoutId': id},
                  ),
                ),
                routes: [
                  GoRoute(
                    path: ':workoutId',
                    name: 'workout-detail',
                    builder: (context, state) => WorkoutDetailScreen(
                      workoutId: state.pathParameters['workoutId']!,
                    ),
                  ),
                ],
              ),
            ],
          ),
          // Quarto branch — «Corpo»: composizione, obiettivo e le funzioni di
          // servizio. Il vecchio «Progressi» vive qui: backup, sincronizzazione
          // e travaso da Gym Tracker riguardano i propri dati, non una sezione
          // a sé.
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/body',
                name: 'body',
                builder: (context, state) => const BodyScreen(),
              ),
              GoRoute(
                path: '/goal',
                name: 'goal',
                builder: (context, state) => const GoalScreen(),
              ),
              // Il rapporto del coach sta accanto a corpo e obiettivo: legge
              // gli stessi dati e risponde alla stessa domanda, «come sto
              // andando». I numeri li calcola l'app: con il Mac spento resta
              // tutto leggibile, manca solo il racconto.
              GoRoute(
                path: '/coach',
                name: 'coach',
                builder: (context, state) => const CoachScreen(),
              ),
              // La bilancia sta sotto Corpo perché è lì che finisce quello che
              // misura. Rotta a sé e non foglio modale: la scansione può
              // durare, e una schermata intera regge stati e messaggi meglio
              // di un foglio che si chiude per sbaglio.
              GoRoute(
                path: '/scale',
                name: 'scale',
                builder: (context, state) => const ScaleScreen(),
              ),
              GoRoute(
                path: '/progress',
                name: 'progress',
                // Progressi porta con sé la porta delle Impostazioni: è già
                // la pagina delle funzioni di servizio, e il profilo di
                // allenamento non appartiene a nessuna delle sei aree. Il
                // bottone lo aggiunge un involucro invece della schermata,
                // che è di un'altra area.
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
                  GoRoute(
                    path: 'import-gym',
                    name: 'gym-import',
                    builder: (context, state) => const GymImportScreen(),
                  ),
                  // Altezza, nascita e sesso dopo il primo avvio: chi ha
                  // saltato il benvenuto deve avere una porta per tornarci,
                  // altrimenti «lo faccio dopo» è un vicolo cieco.
                  GoRoute(
                    path: 'dati-personali',
                    name: 'personal-details',
                    builder: (context, state) => const PersonalDetailsScreen(),
                  ),
                  // La settima area: attrezzatura, limitazioni e
                  // disponibilità. Sotto Progressi e non a sé perché è da lì
                  // che ci si arriva, e una rotta che vive nello stesso ramo
                  // si apre con il tasto indietro al posto giusto.
                  GoRoute(
                    path: 'impostazioni-allenamento',
                    name: TrainingSettingsScreen.routeName,
                    builder: (context, state) => const TrainingSettingsScreen(),
                  ),
                ],
              ),
            ],
          ),
          // Quinto branch — «Piano»: la settimana di pasti e allenamenti.
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
        ],
      ),
      // La sessione dal vivo è a schermo intero e senza barra di navigazione:
      // durante una serie non si cambia sezione per sbaglio, e il vincolo del
      // database ammette una sola sessione aperta per profilo.
      GoRoute(
        path: '/workout/:workoutId',
        name: 'workout-live',
        builder: (context, state) => LiveWorkoutScreen(
          workoutId: state.pathParameters['workoutId']!,
          // Chiusa la sessione si torna allo storico, dove è appena comparsa,
          // invece di restare su una schermata che non ha più niente da fare.
          onClosed: (_) => context.goNamed('workout-history'),
        ),
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
