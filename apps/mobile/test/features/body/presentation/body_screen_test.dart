import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/body/data/body_repository.dart';
import 'package:kal_tracker/features/body/presentation/body_screen.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

void main() {
  late AppDatabase database;
  late BodyRepository repository;
  late String profileId;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
    repository = BodyRepository(database);
  });

  // La schermata non è ancora agganciata al router (la rotta la collega
  // l'integratore), quindi si monta da sola dentro l'app minima che le serve:
  // tema di Kal e localizzazione italiana, come in `app.dart`.
  Widget app({ThemeData? theme, double textScale = 1}) => ProviderScope(
    overrides: [databaseProvider.overrideWithValue(database)],
    child: MaterialApp(
      theme: theme ?? AppTheme.light,
      locale: const Locale('it'),
      supportedLocales: const [Locale('it')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: const BodyScreen(),
    ),
  );

  /// Un istante di oggi meno [daysAgo], alle 8 del mattino romane.
  DateTime morning(int daysAgo, {int hour = 8, int minute = 0}) {
    final day = AppTime.nowInRome().subtract(Duration(days: daysAgo));
    return AppTime.fromRomeLocal(
      DateTime(day.year, day.month, day.day, hour, minute),
    );
  }

  /// Tre settimane di ricomposizione: il peso non si muove di un grammo, il
  /// grasso scende e la magra sale. È il caso che la schermata esiste per
  /// mostrare, e che una linea del peso non racconterebbe.
  Future<void> seedRecomposition() async {
    for (var daysAgo = 20; daysAgo >= 0; daysAgo--) {
      await repository.addMeasurement(
        profileId: profileId,
        weightKg: 100,
        measuredAt: morning(daysAgo),
        bodyFatPct: 25 - (20 - daysAgo) * 0.2,
      );
    }
  }

  /// Rilettura dal database DENTRO un widget test.
  ///
  /// Un `watch(...).first` atteso normalmente non tornerebbe mai: il tempo di
  /// un widget test è finto e la stream di drift aspetta un timer vero.
  /// `runAsync` la fa girare nel tempo reale.
  Future<List<T>> readBack<T>(
    WidgetTester tester,
    Stream<List<T>> stream,
  ) async => (await tester.runAsync(() => stream.first))!;

  /// La schermata è più lunga del viewport dei test: quasi tutto va portato in
  /// vista prima di poterlo toccare. Con [delta] negativo si risale.
  Future<void> scrollTo(
    WidgetTester tester,
    Finder finder, {
    double delta = 280,
  }) async {
    await tester.scrollUntilVisible(
      finder,
      delta,
      scrollable: find.descendant(
        of: find.byKey(const Key('body_list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('senza pesate invita a registrarne una e dichiara comunque i '
      'limiti della BIA', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('body_empty_state')), findsOneWidget);
    expect(find.byKey(const Key('body_summary_card')), findsNothing);
    expect(find.byKey(const Key('body_trust_card')), findsOneWidget);
    expect(
      find.textContaining('Il valore assoluto della BIA è indicativo'),
      findsOneWidget,
    );

    await _dispose(tester, database);
  });

  testWidgets('su telefono e testo al 150% le azioni restano raggiungibili', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(app(textScale: 1.5));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('body_open_scale_button')), findsOneWidget);
    expect(
      find.byKey(const Key('body_add_measurement_button')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('body_more_actions_button')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('body_more_actions_button')));
    await tester.pumpAndSettle();
    expect(find.text('Coach'), findsOneWidget);
    expect(find.text('Health360'), findsOneWidget);
    expect(find.text('Impostazioni allenamento'), findsOneWidget);

    await _dispose(tester, database);
  });

  testWidgets('con tre settimane di dati riconosce la ricomposizione e '
      'disegna le due aree impilate', (tester) async {
    await seedRecomposition();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    // Il verdetto guarda le due masse, non il peso: il peso è fermo.
    expect(find.text('Ricomposizione'), findsOneWidget);
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const Key('body_weight_stat')),
              matching: find.text('100,0'),
            ),
          )
          .data,
      '100,0',
    );

    await scrollTo(tester, find.byKey(const Key('body_composition_chart')));
    expect(find.byKey(const Key('body_composition_chart')), findsOneWidget);
    expect(find.text('Massa grassa'), findsWidgets);

    await scrollTo(tester, find.byKey(const Key('body_zoom_card')));
    expect(find.byKey(const Key('body_zoom_fat')), findsOneWidget);
    expect(find.byKey(const Key('body_zoom_lean')), findsOneWidget);

    await _dispose(tester, database);
  });

  testWidgets('i giudizi della bilancia non compaiono da nessuna parte', (
    tester,
  ) async {
    await seedRecomposition();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    for (final judgement in const [
      'Età metabolica',
      'età metabolica',
      'Peso ottimale',
      'peso ottimale',
      'Tipo di corpo',
      'tipo di corpo',
    ]) {
      expect(
        find.textContaining(judgement),
        findsNothing,
        reason: '«$judgement» è un giudizio della bilancia, non una misura',
      );
    }

    await _dispose(tester, database);
  });

  testWidgets('lo scarto della BIA è misurato sui giorni con due pesate', (
    tester,
  ) async {
    await repository.addMeasurement(
      profileId: profileId,
      weightKg: 100,
      measuredAt: morning(1, hour: 8),
      bodyFatPct: 24.9,
    );
    await repository.addMeasurement(
      profileId: profileId,
      weightKg: 100,
      measuredAt: morning(1, hour: 8, minute: 5),
      bodyFatPct: 25.3,
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await scrollTo(tester, find.byKey(const Key('body_trust_card')));
    expect(find.textContaining('0,4 punti'), findsOneWidget);
    expect(find.textContaining('a corpo fermo'), findsOneWidget);

    await _dispose(tester, database);
  });

  testWidgets('registra una pesata con composizione dal foglio', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('body_add_measurement_button')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('weigh_in_weight_field')),
      '95,4',
    );
    await tester.tap(find.byKey(const Key('weigh_in_composition_switch')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('weigh_in_body_fat_field')),
      '24,5',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();

    final save = find.byKey(const Key('save_weigh_in_button'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(
      find.text('Pesata registrata: entra nelle medie di peso e composizione.'),
      findsOneWidget,
    );

    final saved = await readBack(
      tester,
      repository.watchMeasurements(profileId: profileId),
    );
    expect(saved.single.weightKg, 95.4);
    expect(saved.single.bodyFatPct, 24.5);
    expect(saved.single.hasImpedance, isTrue);

    await _dispose(tester, database);
  });

  testWidgets('senza composizione il foglio salva il solo peso e lo dice', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('body_add_measurement_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('weigh_in_weight_field')),
      '96',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();

    final save = find.byKey(const Key('save_weigh_in_button'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('resta fuori dalle medie della composizione'),
      findsOneWidget,
    );
    final saved = await readBack(
      tester,
      repository.watchMeasurements(profileId: profileId),
    );
    expect(saved.single.bodyFatPct, isNull);

    await _dispose(tester, database);
  });

  testWidgets('eliminare una pesata si può annullare', (tester) async {
    final id = await repository.addMeasurement(
      profileId: profileId,
      weightKg: 94.2,
      measuredAt: morning(1),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    final delete = find.byKey(Key('delete_measurement_$id'));
    await scrollTo(tester, delete);
    await tester.tap(delete);
    await tester.pumpAndSettle();

    expect(find.byKey(Key('body_measurement_$id')), findsNothing);
    expect(find.text('Annulla'), findsOneWidget);

    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle();

    await scrollTo(tester, find.byKey(Key('body_measurement_$id')));
    expect(find.byKey(Key('body_measurement_$id')), findsOneWidget);
    final restored = await readBack(
      tester,
      repository.watchMeasurements(profileId: profileId),
    );
    expect(restored, hasLength(1));

    await _dispose(tester, database);
  });

  testWidgets('la snackbar con «Annulla» si chiude da sola: su questo Flutter '
      'non lo farebbe', (tester) async {
    final id = await repository.addMeasurement(
      profileId: profileId,
      weightKg: 94.2,
      measuredAt: morning(1),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await scrollTo(tester, find.byKey(Key('delete_measurement_$id')));
    await tester.tap(find.byKey(Key('delete_measurement_$id')));
    await tester.pumpAndSettle();
    expect(find.text('Annulla'), findsOneWidget);

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.text('Annulla'), findsNothing);

    await _dispose(tester, database);
  });

  testWidgets('il periodo scelto restringe davvero la serie', (tester) async {
    final vecchia = await repository.addMeasurement(
      profileId: profileId,
      weightKg: 99,
      measuredAt: morning(60),
    );
    final recente = await repository.addMeasurement(
      profileId: profileId,
      weightKg: 94,
      measuredAt: morning(1),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await scrollTo(tester, find.byKey(const Key('body_measurements_card')));
    expect(find.byKey(Key('body_measurement_$vecchia')), findsOneWidget);
    expect(find.byKey(Key('body_measurement_$recente')), findsOneWidget);

    // I chip del periodo stanno in cima: da qui si risale.
    await scrollTo(tester, find.byKey(const Key('body_range_30')), delta: -280);
    await tester.tap(find.byKey(const Key('body_range_30')));
    await tester.pumpAndSettle();

    await scrollTo(tester, find.byKey(const Key('body_measurements_card')));
    expect(find.byKey(Key('body_measurement_$vecchia')), findsNothing);
    expect(find.byKey(Key('body_measurement_$recente')), findsOneWidget);

    await _dispose(tester, database);
  });

  testWidgets('le circonferenze si vedono con la loro variazione', (
    tester,
  ) async {
    await repository.addMeasurement(
      profileId: profileId,
      weightKg: 100,
      measuredAt: morning(60),
      circumferences: const {'Vita': 96},
    );
    await repository.addMeasurement(
      profileId: profileId,
      weightKg: 98,
      measuredAt: morning(1),
      circumferences: const {'Vita': 93.5},
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await scrollTo(tester, find.byKey(const Key('body_circumference_Vita')));
    expect(find.text('93,5'), findsOneWidget);
    expect(find.textContaining('-2,5 cm in 59 giorni'), findsOneWidget);

    await _dispose(tester, database);
  });

  testWidgets('al 150% di testo nessuna card va in overflow', (tester) async {
    await seedRecomposition();
    await tester.pumpWidget(app(textScale: 1.5));
    await tester.pumpAndSettle();

    // Scorrere fino in fondo obbliga OGNI card a impaginarsi davvero: un
    // overflow in una qualsiasi di loro fa fallire il test.
    await scrollTo(tester, find.byKey(const Key('body_measurements_card')));
    expect(tester.takeException(), isNull);

    await _dispose(tester, database);
  });

  testWidgets('al buio i colori arrivano dal tema, non dalla tavolozza '
      'chiara', (tester) async {
    await seedRecomposition();
    await tester.pumpWidget(app(theme: AppTheme.dark));
    await tester.pumpAndSettle();

    final banner = tester.widget<Container>(
      find.byKey(const Key('body_verdict_banner')),
    );
    // Il fondo del verdetto è quello notturno degli accenti: se qualcuno
    // scrivesse un colore letterale, qui resterebbe il set chiaro.
    expect(
      (banner.decoration! as BoxDecoration).color,
      AppAccents.dark.positiveSurface,
    );

    await _dispose(tester, database);
  });

  testWidgets('con dati vecchi la schermata dice che il dato non è fresco', (
    tester,
  ) async {
    await repository.addMeasurement(
      profileId: profileId,
      weightKg: 94,
      measuredAt: morning(9),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('body_stale_chip')), findsOneWidget);
    expect(find.textContaining('Ultima pesata 9 giorni fa'), findsOneWidget);

    await _dispose(tester, database);
  });
}

Future<void> _dispose(WidgetTester tester, AppDatabase database) async {
  // Smaltisce il timer di chiusura forzata delle snackbar con azione
  // (showAutoClosingSnackBar) e quello di mezzanotte di `todayProvider`,
  // altrimenti il teardown fallisce.
  await tester.pump(const Duration(seconds: 9));
  await tester.pumpAndSettle();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(database.close);
}
