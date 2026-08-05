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

  testWidgets('completo si richiude, «Modifica» lo riapre', (tester) async {
    final store = InMemoryCheckInStore();
    await tester.pumpWidget(_host(store: store));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('check_in_sleep_plus')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('check_in_energy_5')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('check_in_summary')), findsOneWidget);
    expect(find.byKey(const Key('check_in_sleep_plus')), findsNothing);

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
