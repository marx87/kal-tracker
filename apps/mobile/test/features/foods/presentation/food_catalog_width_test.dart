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

/// Il tablet di Marco in orizzontale. È la misura che rompeva tutto: senza
/// adattamento una card di alimento si stira da un bordo all'altro.
const _tablet = Size(1706, 1200);

/// Oltre questa larghezza una riga smette di essere leggibile: è la stessa
/// soglia che usano `AdaptiveContent` e le griglie, presa dalla fonte unica.
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

/// Sul tablet la voce «Cibo» è nella guida laterale, che non usa le chiavi
/// della barra in basso: si tocca l'etichetta.
Future<void> _openCatalog(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(_app(database));
  await tester.pumpAndSettle();
  final rail = find.byKey(const Key('main_navigation_rail'));
  await tester.tap(
    rail.evaluate().isEmpty
        ? find.byKey(const Key('nav_food'))
        : find.descendant(of: rail, matching: find.text('Cibo')),
  );
  await tester.pumpAndSettle();
}

/// Tutte le card di alimento a schermo, con posizione e dimensione reali.
Iterable<Rect> _cardRects(WidgetTester tester) => find
    .byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('food_card_'),
    )
    .evaluate()
    .map((element) {
      final box = element.renderObject! as RenderBox;
      return box.localToGlobal(Offset.zero) & box.size;
    });

void main() {
  late AppDatabase database;

  setUp(() {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
  });

  testWidgets('a 1706 dp il catalogo diventa una griglia: nessuna card più '
      'larga della colonna leggibile', (tester) async {
    _resize(tester, _tablet);
    await _openCatalog(tester, database);

    final cards = _cardRects(tester).toList(growable: false);
    expect(cards, isNotEmpty, reason: 'il catalogo di base deve mostrarsi');

    for (final card in cards) {
      expect(
        card.width,
        lessThanOrEqualTo(_readable),
        reason:
            'una card larga ${card.width.round()} dp è una riga di testo '
            'lunga mezzo schermo: il catalogo deve stare su più colonne',
      );
    }

    // Che le card siano più d'una per riga è il punto: se qualcuno rimette
    // la colonna unica, qui non ci sono due card con lo stesso bordo alto.
    final perRow = <double, int>{};
    for (final card in cards) {
      perRow.update(card.top, (count) => count + 1, ifAbsent: () => 1);
    }
    expect(
      perRow.values.any((count) => count >= 2),
      isTrue,
      reason: 'su tablet le card devono affiancarsi, non incolonnarsi',
    );

    // Il campo di ricerca è testo: si ferma alla colonna leggibile anche se
    // la griglia accanto è più larga.
    expect(
      tester.getSize(find.byKey(const Key('food_search_field'))).width,
      lessThanOrEqualTo(_readable),
    );

    await _disposeApp(tester, database);
  });

  testWidgets('sul telefono il catalogo resta a una colonna piena', (
    tester,
  ) async {
    _resize(tester, const Size(400, 900));
    await _openCatalog(tester, database);

    final cards = _cardRects(tester).toList(growable: false);
    expect(cards, isNotEmpty);
    for (final card in cards) {
      expect(
        card.width,
        greaterThan(300),
        reason:
            'a 400 dp non c’è spazio per due colonne: la card prende tutta '
            'la larghezza meno i margini',
      );
    }

    await _disposeApp(tester, database);
  });

  testWidgets('a 1706 dp il modulo del nuovo alimento resta una colonna '
      'leggibile', (tester) async {
    _resize(tester, _tablet);
    await _openCatalog(tester, database);

    await tester.tap(find.byKey(const Key('create_food_button')));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const Key('food_editor_list'))).width,
      lessThanOrEqualTo(_readable),
      reason: 'un campo di testo largo 1700 dp è scomodo da compilare',
    );

    await _disposeApp(tester, database);
  });
}
