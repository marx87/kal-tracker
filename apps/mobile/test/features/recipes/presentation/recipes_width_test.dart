import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/app.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/theme/app_breakpoints.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';

/// Il tablet di Marco in orizzontale: la misura che stirava le schermate.
const _tablet = Size(1706, 1200);

/// La colonna leggibile, presa dalla fonte unica delle soglie.
final _readable = AppBreakpoints.contentMaxWidth(AppWindowSize.expanded);

Widget _app(AppDatabase database) => ProviderScope(
  overrides: [
    databaseProvider.overrideWithValue(database),
    appConfigProvider.overrideWithValue(const AppConfig.offline()),
  ],
  child: const KalTrackerApp(),
);

Future<void> _disposeApp(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(database.close);
}

void _resize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _openRecipes(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(_app(database));
  await tester.pumpAndSettle();
  // Sul tablet la navigazione è la guida laterale, che non ha le chiavi
  // della barra in basso: si tocca l'etichetta.
  final rail = find.byKey(const Key('main_navigation_rail'));
  await tester.tap(
    rail.evaluate().isEmpty
        ? find.byKey(const Key('nav_food'))
        : find.descendant(of: rail, matching: find.text('Cibo')),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('food_open_recipes_button')));
  await tester.pumpAndSettle();
}

Finder get _recipeCards => find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith('recipe_card_'),
);

Iterable<Rect> _rects(Finder finder) => finder.evaluate().map((element) {
  final box = element.renderObject! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
});

void main() {
  late AppDatabase database;

  setUp(() {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
  });

  testWidgets('a 1706 dp il ricettario si affianca su più colonne e nessuna '
      'card supera la colonna leggibile', (tester) async {
    _resize(tester, _tablet);
    await _openRecipes(tester, database);

    final cards = _rects(_recipeCards).toList(growable: false);
    expect(cards, isNotEmpty, reason: 'le ricette di base devono mostrarsi');

    for (final card in cards) {
      expect(
        card.width,
        lessThanOrEqualTo(_readable),
        reason:
            'una card larga ${card.width.round()} dp vuol dire titolo e '
            'descrizione stirati da un bordo all’altro',
      );
    }

    final perRow = <double, int>{};
    for (final card in cards) {
      perRow.update(card.top, (count) => count + 1, ifAbsent: () => 1);
    }
    expect(
      perRow.values.any((count) => count >= 2),
      isTrue,
      reason: 'su tablet le ricette devono stare in griglia, non in colonna',
    );

    expect(
      tester.getSize(find.byKey(const Key('recipe_search_field'))).width,
      lessThanOrEqualTo(_readable),
    );

    await _disposeApp(tester, database);
  });

  testWidgets('sul telefono il ricettario resta a una colonna piena', (
    tester,
  ) async {
    _resize(tester, const Size(400, 900));
    await _openRecipes(tester, database);

    final cards = _rects(_recipeCards).toList(growable: false);
    expect(cards, isNotEmpty);
    for (final card in cards) {
      expect(card.width, greaterThan(300));
    }

    await _disposeApp(tester, database);
  });

  testWidgets('a 1706 dp dettaglio ed editor della ricetta restano una '
      'colonna leggibile', (tester) async {
    _resize(tester, _tablet);
    await _openRecipes(tester, database);

    await tester.tap(_recipeCards.first);
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const Key('recipe_detail_list'))).width,
      lessThanOrEqualTo(_readable),
      reason: 'ingredienti e preparazione sono testo da leggere in fila',
    );

    await tester.tap(find.byKey(const Key('edit_recipe_button')));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const Key('recipe_editor_list'))).width,
      lessThanOrEqualTo(_readable),
      reason: 'un modulo largo 1700 dp è scomodo da compilare',
    );

    await _disposeApp(tester, database);
  });
}
