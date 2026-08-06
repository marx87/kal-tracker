import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/theme/app_breakpoints.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/nutrition.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/recipes/data/recipe_repository.dart';
import 'package:kal_tracker/features/recipes/domain/recipe_models.dart';
import 'package:kal_tracker/features/weekly_plan/domain/shopping_checks.dart';
import 'package:kal_tracker/features/weekly_plan/presentation/shopping_list_providers.dart';
import 'package:kal_tracker/features/weekly_plan/presentation/shopping_list_screen.dart';

void main() {
  testWidgets('senza piano pronto la lista è vuota, ma spiega perché', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    await LocalProfileRepository(database).getOrCreateMarco();

    await tester.pumpWidget(_app(database, _FakeChecksStore()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('shopping_list')), findsOneWidget);
    expect(
      find.byKey(const Key('shopping_list_placeholder_title')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('shopping_list_counter')), findsNothing);

    await _dispose(tester, database);
  });

  testWidgets('la spesa somma gli ingredienti e li divide per reparto', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    await _seedPlan(database);

    await tester.pumpWidget(_app(database, _FakeChecksStore()));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('shopping_list_counter'))).data,
      '0 di 4 presi',
    );

    // Il primo reparto del giro è in cima alla lista.
    expect(
      find.byKey(const Key('shopping_department_ortofrutta')),
      findsOneWidget,
    );

    // Ortofrutta: 200 g di zucchine su 2 porzioni × 1,5 porzioni = 150 g.
    await _scrollTo(tester, const Key('shopping_item_zucchina'));
    expect(find.text('Zucchine'), findsOneWidget);
    expect(find.text('150 g'), findsOneWidget);

    // Macelleria: il pollo arriva da due ricette, 150 + 300 = 450 g.
    await _scrollTo(tester, const Key('shopping_item_petto pollo'));
    expect(find.text('450 g'), findsOneWidget);

    // Banco frigo: le uova si comprano a pezzi.
    await _scrollTo(tester, const Key('shopping_item_uovo'));
    expect(find.textContaining('2 uova'), findsOneWidget);

    await _dispose(tester, database);
  });

  testWidgets('la spunta si mette, si conta e si salva', (tester) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    await _seedPlan(database);
    final store = _FakeChecksStore();

    await tester.pumpWidget(_app(database, store));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('shopping_item_zucchina')));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('shopping_list_counter'))).data,
      '1 di 4 presi',
    );
    expect(store.saved?.planId, 'plan-1');
    expect(store.saved?.checked, {'zucchina'});

    // Rispuntare toglie la spunta.
    await tester.tap(find.byKey(const Key('shopping_item_zucchina')));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('shopping_list_counter'))).data,
      '0 di 4 presi',
    );
    expect(store.saved?.checked, isEmpty);

    await _dispose(tester, database);
  });

  testWidgets('le spunte salvate si ritrovano riaprendo la schermata', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    await _seedPlan(database);
    final store = _FakeChecksStore(
      initial: ShoppingChecks(planId: 'plan-1', checked: const ['zucchina']),
    );

    await tester.pumpWidget(_app(database, store));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('shopping_list_counter'))).data,
      '1 di 4 presi',
    );

    await tester.tap(find.byKey(const Key('shopping_list_reset_button')));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('shopping_list_counter'))).data,
      '0 di 4 presi',
    );
    expect(find.text('Spunte azzerate: la spesa riparte.'), findsOneWidget);

    await _dispose(tester, database);
  });

  testWidgets('il pulsante copia mette la lista negli appunti', (tester) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    await _seedPlan(database);

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(_app(database, _FakeChecksStore()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('shopping_list_copy_button')));
    await tester.pumpAndSettle();

    expect(copied, startsWith('Lista della spesa'));
    expect(copied, contains('ORTOFRUTTA'));
    expect(copied, contains('[ ] Zucchine — 150 g'));
    expect(copied, contains('Presi 0 di 4.'));
    expect(find.text('Lista copiata: incollala dove vuoi.'), findsOneWidget);

    await _dispose(tester, database);
  });

  testWidgets('una ricetta cancellata si dichiara, non si inventa', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    await _seedPlan(database, withMissingRecipe: true);

    await tester.pumpWidget(_app(database, _FakeChecksStore()));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('shopping_list_missing_recipes')),
      findsOneWidget,
    );
    expect(find.textContaining('Torta salata'), findsOneWidget);
    // Le ricette che ci sono ancora restano comunque in lista.
    expect(find.byKey(const Key('shopping_list_counter')), findsOneWidget);

    await _dispose(tester, database);
  });

  testWidgets('a schermo stretto non va niente in overflow', (tester) async {
    AppTime.initialize();
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final database = AppDatabase(NativeDatabase.memory());
    await _seedPlan(database, withMissingRecipe: true);

    await tester.pumpWidget(_app(database, _FakeChecksStore()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('shopping_list_counter')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _dispose(tester, database);
  });

  testWidgets('sul tablet largo la lista si ferma alla colonna leggibile', (
    tester,
  ) async {
    AppTime.initialize();
    _wideWindow(tester);
    final database = AppDatabase(NativeDatabase.memory());
    await _seedPlan(database);

    await tester.pumpWidget(_app(database, _FakeChecksStore()));
    await tester.pumpAndSettle();

    final width = tester.getSize(find.byKey(const Key('shopping_list'))).width;
    expect(width, AppBreakpoints.contentMaxWidth(AppWindowSize.expanded));
    expect(width, lessThan(1706));

    await _dispose(tester, database);
  });

  testWidgets('sul tablet largo i reparti stanno affiancati, in ordine di '
      'giro', (tester) async {
    // È l'eccezione del gruppo: qui affiancare serve davvero, perché le voci
    // sono corte e camminare fra gli scaffali con metà scorrimento è meglio.
    AppTime.initialize();
    _wideWindow(tester);
    final database = AppDatabase(NativeDatabase.memory());
    await _seedPlan(database);

    await tester.pumpWidget(_app(database, _FakeChecksStore()));
    await tester.pumpAndSettle();

    expect(
      _departmentHeaders.evaluate().length,
      greaterThanOrEqualTo(2),
      reason: 'servono almeno due reparti per verificare l’affiancamento',
    );
    final first = tester.getTopLeft(_departmentHeaders.at(0));
    final second = tester.getTopLeft(_departmentHeaders.at(1));
    expect(
      second.dy,
      first.dy,
      reason: 'i primi due reparti sono sulla stessa riga',
    );
    expect(
      second.dx,
      greaterThan(first.dx),
      reason: 'il secondo reparto del giro sta a destra del primo',
    );

    await _dispose(tester, database);
  });

  testWidgets('sul telefono i reparti restano incolonnati', (tester) async {
    AppTime.initialize();
    tester.view.physicalSize = const Size(400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final database = AppDatabase(NativeDatabase.memory());
    await _seedPlan(database);

    await tester.pumpWidget(_app(database, _FakeChecksStore()));
    await tester.pumpAndSettle();

    final first = tester.getTopLeft(_departmentHeaders.at(0));
    final second = tester.getTopLeft(_departmentHeaders.at(1));
    expect(second.dx, first.dx);
    expect(second.dy, greaterThan(first.dy));

    await _dispose(tester, database);
  });

  testWidgets('se tutte le ricette sono sparite resta la spiegazione', (
    tester,
  ) async {
    AppTime.initialize();
    final database = AppDatabase(NativeDatabase.memory());
    await _seedPlan(database, withMissingRecipe: true, onlyMissingRecipe: true);

    await tester.pumpWidget(_app(database, _FakeChecksStore()));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('shopping_list_placeholder_title')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('shopping_list_missing_recipes')),
      findsOneWidget,
    );

    await _dispose(tester, database);
  });
}

/// Il tablet di Marco in orizzontale, alto abbastanza da costruire i primi
/// reparti senza scorrere.
void _wideWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1706, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Le intestazioni di reparto, nell'ordine in cui sono nell'albero: la loro
/// posizione dice se sono incolonnate o affiancate.
Finder get _departmentHeaders => find.byWidgetPredicate((widget) {
  final key = widget.key;
  return key is ValueKey<String> &&
      key.value.startsWith('shopping_department_');
});

/// La lista è pigra: una voce in fondo esiste solo dopo che ci si è scrollati.
Finder get _scrollable => find.descendant(
  of: find.byKey(const Key('shopping_list')),
  matching: find.byType(Scrollable),
);

Future<void> _scrollTo(WidgetTester tester, Key key) async {
  await tester.scrollUntilVisible(
    find.byKey(key),
    120,
    scrollable: _scrollable,
  );
  await tester.pumpAndSettle();
}

Widget _app(AppDatabase database, ShoppingChecksStore store) => ProviderScope(
  overrides: [
    databaseProvider.overrideWithValue(database),
    shoppingChecksStoreProvider.overrideWithValue(store),
  ],
  child: MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('it'),
    supportedLocales: const [Locale('it')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: const ShoppingListScreen(),
  ),
);

/// Un piano pronto con due ricette vere: la spesa deve leggere gli
/// ingredienti dal ricettario, non da un JSON del piano.
Future<void> _seedPlan(
  AppDatabase database, {
  bool withMissingRecipe = false,
  bool onlyMissingRecipe = false,
}) async {
  final profileId = (await LocalProfileRepository(
    database,
  ).getOrCreateMarco()).id;
  final recipes = RecipeRepository(database);
  const per100g = Nutrients(calories: 120, protein: 12, carbs: 8, fat: 3);

  final bowl = await recipes.createRecipe(
    profileId: profileId,
    draft: const FitRecipeDraft(
      name: 'Bowl di pollo',
      servings: 2,
      ingredients: [
        RecipeIngredientDraft(name: 'Zucchine', grams: 200, per100g: per100g),
        RecipeIngredientDraft(
          name: 'Petto di pollo',
          grams: 200,
          per100g: per100g,
        ),
        RecipeIngredientDraft(
          name: 'Riso basmati',
          grams: 160,
          per100g: per100g,
        ),
      ],
    ),
  );
  final frittata = await recipes.createRecipe(
    profileId: profileId,
    draft: const FitRecipeDraft(
      name: 'Frittata',
      servings: 1,
      ingredients: [
        RecipeIngredientDraft(name: 'Uova', grams: 120, per100g: per100g),
        RecipeIngredientDraft(
          name: 'Petto di pollo',
          grams: 300,
          per100g: per100g,
        ),
      ],
    ),
  );

  final moment = DateTime.utc(2026, 8, 4, 9);
  await database
      .into(database.weeklyPlans)
      .insert(
        WeeklyPlansCompanion.insert(
          id: 'plan-1',
          profileId: profileId,
          startDate: DateTime(2026, 8, 5),
          days: 3,
          mealsCsv: 'pranzo,cena',
          status: 'ready',
          requestJson: '{}',
          createdAt: moment,
          updatedAt: moment,
        ),
      );
  if (!onlyMissingRecipe) {
    await database
        .into(database.weeklyPlanSlots)
        .insert(
          WeeklyPlanSlotsCompanion.insert(
            id: 'slot-1',
            planId: 'plan-1',
            date: DateTime(2026, 8, 5),
            meal: 'pranzo',
            recipeId: Value(bowl),
            recipeNameSnapshot: 'Bowl di pollo',
            servings: 1.5,
          ),
        );
    await database
        .into(database.weeklyPlanSlots)
        .insert(
          WeeklyPlanSlotsCompanion.insert(
            id: 'slot-2',
            planId: 'plan-1',
            date: DateTime(2026, 8, 6),
            meal: 'cena',
            recipeId: Value(frittata),
            recipeNameSnapshot: 'Frittata',
            servings: 1,
          ),
        );
  }
  if (withMissingRecipe) {
    await database
        .into(database.weeklyPlanSlots)
        .insert(
          WeeklyPlanSlotsCompanion.insert(
            id: 'slot-3',
            planId: 'plan-1',
            date: DateTime(2026, 8, 7),
            meal: 'cena',
            recipeNameSnapshot: 'Torta salata',
            servings: 1,
          ),
        );
  }
}

Future<void> _dispose(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(database.close);
}

class _FakeChecksStore implements ShoppingChecksStore {
  _FakeChecksStore({ShoppingChecks? initial})
    : _initial = initial ?? const ShoppingChecks.empty();

  final ShoppingChecks _initial;
  ShoppingChecks? saved;

  @override
  Future<ShoppingChecks> read() async => saved ?? _initial;

  @override
  Future<void> write(ShoppingChecks checks) async {
    saved = checks;
  }
}
