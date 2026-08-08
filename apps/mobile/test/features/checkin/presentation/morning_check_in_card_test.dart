import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/checkin/data/check_in_store.dart';
import 'package:kal_tracker/features/checkin/domain/daily_check_in.dart';
import 'package:kal_tracker/features/checkin/presentation/check_in_providers.dart';
import 'package:kal_tracker/features/checkin/presentation/morning_check_in_card.dart';
import 'package:kal_tracker/features/goal/domain/body_state.dart';
import 'package:kal_tracker/features/goal/presentation/goal_providers.dart';

/// [theme] nullo significa «MaterialApp spoglio»: serve a verificare che i
/// mattoni condivisi ripieghino sui colori di default invece di lanciare.
Widget _host({
  required CheckInStore store,
  BodyState state = const BodyState.unknown(),
  ThemeData? theme,
  double textScale = 1,
  VoidCallback? onWeighIn,
}) => ProviderScope(
  overrides: [
    checkInStoreProvider.overrideWithValue(store),
    bodyStateProvider.overrideWith((ref) => Stream.value(state)),
  ],
  child: MaterialApp(
    theme: theme,
    locale: const Locale('it'),
    supportedLocales: const [Locale('it')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: MorningCheckInCard(onWeighIn: onWeighIn ?? () {}),
        ),
      ),
    ),
  ),
);

/// Tocca un controllo portandolo prima nella finestra.
///
/// La card è più alta del riquadro dei test e i controlli del movimento sono
/// gli ultimi: senza lo scorrimento il tocco cadrebbe nel vuoto e il test
/// passerebbe o fallirebbe per la dimensione della finestra, non per il
/// comportamento della card.
Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => initializeDateFormatting('it'));
  setUp(AppTime.initialize);

  testWidgets('senza pesata di oggi invita, non lascia un buco', (
    tester,
  ) async {
    await tester.pumpWidget(_host(store: InMemoryCheckInStore()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('check_in_weight_missing')), findsOneWidget);
    expect(find.text('Non ti sei ancora pesato oggi.'), findsOneWidget);
    expect(find.byKey(const Key('check_in_weight')), findsNothing);
  });

  testWidgets('la pesata di ieri non passa per quella di oggi', (tester) async {
    final yesterday = AppTime.nowUtc().subtract(const Duration(days: 1));
    await tester.pumpWidget(
      _host(
        store: InMemoryCheckInStore(),
        state: BodyState(latest: WeightPoint(at: yesterday, weightKg: 95.8)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('check_in_weight_missing')), findsOneWidget);
  });

  testWidgets('la pesata di oggi si mostra com\'è, senza giudizi', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        store: InMemoryCheckInStore(),
        state: BodyState(
          latest: WeightPoint(
            at: AppTime.nowUtc(),
            weightKg: 95.8,
            bodyFatPct: 25.2,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('check_in_weight')), findsOneWidget);
    expect(find.text('95,8'), findsOneWidget);
  });

  testWidgets('il pulsante della pesata chiama chi sa aprirla', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      _host(store: InMemoryCheckInStore(), onWeighIn: () => opened++),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('check_in_weigh_in_button')));
    await tester.pumpAndSettle();

    expect(opened, 1);
  });

  testWidgets('il sonno parte da 7,5 h e si muove di mezz\'ora', (
    tester,
  ) async {
    final store = InMemoryCheckInStore();
    await tester.pumpWidget(_host(store: store));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('check_in_sleep_value'))).data,
      'da inserire',
    );

    await tester.tap(find.byKey(const Key('check_in_sleep_plus')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('check_in_sleep_value'))).data,
      '7,5 h',
    );

    await tester.tap(find.byKey(const Key('check_in_sleep_minus')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('check_in_sleep_value'))).data,
      '7 h',
    );

    expect(
      (await store.read())
          .forDay(checkInDayOf(AppTime.nowInRome()))!
          .sleepHours,
      7,
    );
  });

  testWidgets('l\'energia dice a parole cosa significa il numero', (
    tester,
  ) async {
    await tester.pumpWidget(_host(store: InMemoryCheckInStore()));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('check_in_energy_label'))).data,
      '1 è scarico, 5 è carico.',
    );

    await tester.tap(find.byKey(const Key('check_in_energy_2')));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('check_in_energy_label'))).data,
      '2: fiacco.',
    );
  });

  testWidgets('i passi partono da 6.000 e si muovono di mille', (tester) async {
    final store = InMemoryCheckInStore();
    await tester.pumpWidget(_host(store: store));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('check_in_steps_value'))).data,
      'da inserire',
    );

    await _tap(tester, 'check_in_steps_plus');
    expect(
      tester.widget<Text>(find.byKey(const Key('check_in_steps_value'))).data,
      '6.000',
    );

    await _tap(tester, 'check_in_steps_plus');
    expect(
      tester.widget<Text>(find.byKey(const Key('check_in_steps_value'))).data,
      '7.000',
    );

    expect(
      (await store.read()).forDay(checkInDayOf(AppTime.nowInRome()))!.steps,
      7000,
    );
  });

  testWidgets('i minuti a piedi partono da 30 e si muovono di dieci', (
    tester,
  ) async {
    final store = InMemoryCheckInStore();
    await tester.pumpWidget(_host(store: store));
    await tester.pumpAndSettle();

    await _tap(tester, 'check_in_walk_plus');
    expect(
      tester.widget<Text>(find.byKey(const Key('check_in_walk_value'))).data,
      '30 min',
    );

    await _tap(tester, 'check_in_walk_minus');
    expect(
      tester.widget<Text>(find.byKey(const Key('check_in_walk_value'))).data,
      '20 min',
    );
  });

  testWidgets('«Giornata ferma» segna lo zero in un tocco solo', (
    tester,
  ) async {
    final store = InMemoryCheckInStore();
    await tester.pumpWidget(_host(store: store));
    await tester.pumpAndSettle();

    await _tap(tester, 'check_in_neat_still');

    // Zero e non «da inserire»: è la distinzione su cui si regge tutto il
    // campo, e scendere di mille passi alla volta fino a zero significa non
    // segnarlo mai.
    final entry = (await store.read()).forDay(
      checkInDayOf(AppTime.nowInRome()),
    )!;
    expect(entry.steps, 0);
    expect(entry.walkMinutes, 0);
    expect(
      tester.widget<Text>(find.byKey(const Key('check_in_steps_value'))).data,
      '0',
    );

    // Lo stesso tocco lo annulla: il chip preso per sbaglio non obbliga a
    // risalire a colpi di mille.
    await _tap(tester, 'check_in_neat_still');
    expect(
      tester.widget<Text>(find.byKey(const Key('check_in_steps_value'))).data,
      'da inserire',
    );
  });

  testWidgets('il movimento da solo si salva, e non si avvisa del contrario', (
    tester,
  ) async {
    // **Questo test faceva da guardia a un'affermazione diventata falsa.** La
    // card diceva «il movimento da solo non basta a salvare il check-in», e
    // fino alla v7 era vero: il vincolo dello schema pretendeva sonno o
    // energia. La v10 l'ha allargato, il magazzino ha smesso di cancellare
    // quelle righe — e l'avviso è rimasto, a dire a Marco che stava perdendo
    // ottomila passi mentre l'app glieli salvava. Peggio: per «ancorarli»
    // avrebbe inventato un'ora di sonno, sporcando l'unico dato che quella
    // riga aveva davvero.
    final store = InMemoryCheckInStore();
    await tester.pumpWidget(_host(store: store));
    await tester.pumpAndSettle();

    await _tap(tester, 'check_in_walk_plus');

    expect(find.byKey(const Key('check_in_neat_needs_anchor')), findsNothing);
    expect(
      find.textContaining('non basta a salvare'),
      findsNothing,
      reason: 'la v10 ha reso salvabile la giornata di solo movimento',
    );
  });

  testWidgets('completo si richiude, «Modifica» lo riapre', (tester) async {
    final store = InMemoryCheckInStore();
    await tester.pumpWidget(_host(store: store));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('check_in_sleep_plus')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('check_in_energy_5')));
    await tester.pumpAndSettle();

    // Sonno ed energia si richiudono subito, ma il movimento resta lì: è la
    // domanda su ieri, e nessuno riaprirebbe una card per rispondere a una
    // cosa che non sa di dover rispondere.
    expect(find.byKey(const Key('check_in_summary')), findsOneWidget);
    expect(find.byKey(const Key('check_in_sleep_plus')), findsNothing);
    expect(find.byKey(const Key('check_in_neat_still')), findsOneWidget);
    expect(find.text('Manca solo quanto ti sei mosso.'), findsOneWidget);

    await _tap(tester, 'check_in_neat_still');

    // Adesso non manca più niente e sparisce anche il movimento, che finisce
    // nella riga di riepilogo.
    expect(find.byKey(const Key('check_in_neat_still')), findsNothing);
    expect(find.textContaining('giornata ferma'), findsOneWidget);

    await tester.tap(find.text('Modifica'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('check_in_sleep_plus')), findsOneWidget);
  });

  testWidgets('regge il tema scuro e il testo al 200%', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _host(
        store: InMemoryCheckInStore(),
        theme: AppTheme.dark,
        textScale: 2,
        state: BodyState(
          latest: WeightPoint(at: AppTime.nowUtc(), weightKg: 95.8),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
