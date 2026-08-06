import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/theme/app_breakpoints.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/checkin/data/check_in_store.dart';
import 'package:kal_tracker/features/checkin/presentation/check_in_providers.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/diary/presentation/today_diary_screen.dart';
import 'package:kal_tracker/features/diary/presentation/widgets/wellness_meal_card.dart';
import 'package:kal_tracker/features/wellbeing/presentation/water_day_sheet.dart';

/// La schermata Oggi alle tre taglie di finestra.
///
/// Questi test difendono una cosa sola ma la difendono davvero: sul tablet di
/// Marco (1706 punti) il contenuto non deve stirarsi da un bordo all'altro.
/// Se qualcuno toglie l'adattamento — due colonne su schermo largo, colonna
/// centrata e limitata su tablet verticale — qui si accende il rosso.
Widget _host(AppDatabase database) => ProviderScope(
  overrides: [
    databaseProvider.overrideWithValue(database),
    appConfigProvider.overrideWithValue(const AppConfig.offline()),
    checkInStoreProvider.overrideWithValue(InMemoryCheckInStore()),
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
    home: const TodayDiaryScreen(),
  ),
);

/// Le misure contano: la schermata si monta sulla finestra dichiarata, non
/// sugli 800×600 di default del test.
void _useWindow(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Il tablet di Marco in orizzontale: la taglia in cui la schermata si
/// stirava.
const _tablet = Size(1706, 1150);

/// Tablet in verticale: c'è spazio, ma non per due colonne.
const _tabletPortrait = Size(900, 1400);

const _phone = Size(390, 844);

/// La colonna più larga che si può ancora leggere, presa dalla fonte unica.
final _readable = AppBreakpoints.contentMaxWidth(AppWindowSize.expanded);

Future<void> _dispose(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(database.close);
}

/// Larghezza di una cosa a schermo, per chiave.
double _widthOf(WidgetTester tester, String key) =>
    tester.getSize(find.byKey(Key(key))).width;

void main() {
  setUpAll(() => initializeDateFormatting('it'));
  setUp(AppTime.initialize);

  testWidgets('sul tablet il diario sta su due colonne, non su una striscia '
      'lunga tutto lo schermo', (tester) async {
    _useWindow(tester, _tablet);
    final database = AppDatabase(NativeDatabase.memory());

    await tester.pumpWidget(_host(database));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('diary_summary_column')), findsOneWidget);
    expect(find.byKey(const Key('diary_meals_column')), findsOneWidget);
    expect(find.byKey(const Key('diary_single_column')), findsNothing);

    // Nessuna card supera la colonna leggibile: è il punto di tutto.
    for (final key in const [
      'calorie_progress_card',
      // La barra delle proteine è il sintomo raccontato da Marco: prima
      // attraversava lo schermo intero.
      'protein_progress_bar',
      'morning_check_in_card',
      'water_card',
    ]) {
      expect(
        _widthOf(tester, key),
        lessThanOrEqualTo(_readable),
        reason: '«$key» supera la colonna leggibile di $_readable punti',
      );
    }
    expect(
      tester.getSize(find.byType(WellnessMealCard).first).width,
      lessThanOrEqualTo(_readable),
      reason: 'anche le card dei pasti stanno dentro la loro colonna',
    );

    // Due colonne vere: affiancate e insieme riempiono la finestra, invece di
    // lasciare mezzo schermo vuoto.
    final summary = tester.getRect(
      find.byKey(const Key('diary_summary_column')),
    );
    final meals = tester.getRect(find.byKey(const Key('diary_meals_column')));
    expect(summary.right, lessThanOrEqualTo(meals.left));
    expect(meals.right, greaterThan(_tablet.width * 0.9));

    await _dispose(tester, database);
  });

  testWidgets('a due colonne il riepilogo resta fermo mentre scorrono i '
      'pasti, e il FAB non copre l\'ultima riga', (tester) async {
    _useWindow(tester, _tablet);
    final database = AppDatabase(NativeDatabase.memory());

    await tester.pumpWidget(_host(database));
    await tester.pumpAndSettle();

    final caloriesBefore = tester.getRect(
      find.byKey(const Key('daily_calories')),
    );
    await tester.drag(
      find.byKey(const Key('diary_meals_column')),
      const Offset(0, -4000),
    );
    await tester.pumpAndSettle();

    // È il motivo per cui le due colonne scorrono separate: quante calorie e
    // quante proteine restano si continuano a vedere.
    expect(
      tester.getRect(find.byKey(const Key('daily_calories'))),
      caloriesBefore,
    );

    final last = tester.getRect(
      find.byKey(const Key('photo_meal_button_snack')),
    );
    final fab = tester.getRect(find.byKey(const Key('add_food_button')));
    expect(
      fab.overlaps(last),
      isFalse,
      reason:
          'il FAB galleggia sopra la colonna dei pasti: deve restare la '
          'riserva in fondo',
    );

    await _dispose(tester, database);
  });

  testWidgets('sul tablet in verticale resta una colonna sola, centrata e '
      'limitata', (tester) async {
    _useWindow(tester, _tabletPortrait);
    final database = AppDatabase(NativeDatabase.memory());

    await tester.pumpWidget(_host(database));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('diary_single_column')), findsOneWidget);
    expect(find.byKey(const Key('diary_summary_column')), findsNothing);

    final card = tester.getRect(find.byKey(const Key('calorie_progress_card')));
    expect(
      card.width,
      lessThanOrEqualTo(AppBreakpoints.contentMaxWidth(AppWindowSize.medium)),
    );
    // Centrata: quello che avanza si divide in parti uguali ai due lati.
    expect(card.left, closeTo(_tabletPortrait.width - card.right, 1));
    expect(card.left, greaterThan(0));

    await _dispose(tester, database);
  });

  testWidgets('sul telefono niente cambia: una colonna che riempie lo '
      'schermo', (tester) async {
    _useWindow(tester, _phone);
    final database = AppDatabase(NativeDatabase.memory());

    await tester.pumpWidget(_host(database));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('diary_single_column')), findsOneWidget);
    expect(find.byKey(const Key('diary_summary_column')), findsNothing);

    // 16 punti di margine per lato, come sempre: sotto gli 840 punti non c'è
    // niente da limitare.
    final margin = AppBreakpoints.pagePadding(AppWindowSize.compact).horizontal;
    expect(_widthOf(tester, 'calorie_progress_card'), _phone.width - margin);

    await _dispose(tester, database);
  });

  testWidgets('anche il foglio dell\'acqua resta stretto e centrato sul '
      'tablet', (tester) async {
    _useWindow(tester, _tablet);
    final database = AppDatabase(NativeDatabase.memory());

    await tester.pumpWidget(_host(database));
    await tester.pumpAndSettle();

    final card = find.byKey(const Key('water_card_tap'));
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tester.tap(card);
    await tester.pumpAndSettle();

    // Qui non c'è niente di nostro da difendere se non la decisione di non
    // toccare nulla: Material 3 limita già i fogli modali a 640 punti e li
    // centra. Il test c'è perché passare un `constraints:` più largo
    // «per usare lo spazio» sarebbe un peggioramento, e si vedrebbe qui.
    final sheet = tester.getRect(find.byType(WaterDaySheet));
    expect(sheet.width, lessThanOrEqualTo(_readable));
    expect(sheet.center.dx, closeTo(_tablet.width / 2, 1));

    await _dispose(tester, database);
  });
}
