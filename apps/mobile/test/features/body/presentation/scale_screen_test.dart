import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/body/data/scale_link.dart';
import 'package:kal_tracker/features/body/presentation/scale_providers.dart';
import 'package:kal_tracker/features/body/presentation/scale_screen.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

import '../data/fake_scale_link.dart';

void main() {
  late AppDatabase database;
  late String profileId;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
  });

  tearDown(() => database.close());

  Future<void> completeProfile() =>
      (database.update(
        database.appProfiles,
      )..where((row) => row.id.equals(profileId))).write(
        AppProfilesCompanion(
          heightCm: const Value(182),
          birthDate: Value(DateTime.utc(1987, 9, 13)),
          sex: const Value('M'),
        ),
      );

  // La schermata non è ancora agganciata al router (la rotta la collega
  // l'integratore), quindi si monta da sola dentro l'app minima che le serve.
  Widget app(FakeScaleLink link, {ThemeData? theme, double textScale = 1}) =>
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          scaleLinkProvider.overrideWithValue(link),
        ],
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
          home: const ScaleScreen(),
        ),
      );

  /// Una finestra alta: la schermata è una colonna lunga (stato, pesata,
  /// onestà, ricalcolo, registro) e in una `ListView` alta 600 px la coda non
  /// verrebbe proprio costruita.
  Future<void> open(
    WidgetTester tester,
    FakeScaleLink link, {
    ThemeData? theme,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = const Size(1000, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(link, theme: theme, textScale: textScale));
    await tester.pump();
  }

  /// Fa girare la sessione: il tempo dei test è finto e avanza solo con i
  /// fotogrammi, quindi la bilancia finta recita mentre si pompa.
  Future<void> runSession(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('scale_start_button')));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump();
  }

  testWidgets('all’apertura invita ad accendere la bilancia', (tester) async {
    await open(tester, FakeScaleLink());

    expect(find.byKey(const Key('scale_status_title')), findsOneWidget);
    expect(find.text('Pesata dalla bilancia'), findsOneWidget);
    expect(find.text('Cerca la bilancia'), findsOneWidget);
    expect(find.byKey(const Key('scale_log_empty')), findsOneWidget);
    // L'onestà è in schermata dall'inizio, non nascosta dopo la pesata.
    expect(find.byKey(const Key('scale_honesty_note')), findsOneWidget);
    expect(find.byKey(const Key('scale_formula_note')), findsOneWidget);
  });

  testWidgets('Bluetooth spento: lo dice e lascia riprovare', (tester) async {
    await open(tester, FakeScaleLink(radio: ScaleRadioState.off));
    await runSession(tester);

    expect(find.text('Bluetooth spento'), findsOneWidget);
    expect(find.text('Cerca di nuovo'), findsOneWidget);
  });

  testWidgets('permesso negato: nomina il permesso di Android', (tester) async {
    await open(tester, FakeScaleLink(radio: ScaleRadioState.unauthorized));
    await runSession(tester);

    expect(find.text('Permesso negato'), findsOneWidget);
    expect(find.textContaining('Dispositivi nelle vicinanze'), findsOneWidget);
  });

  testWidgets('bilancia non trovata: spiega che va svegliata', (tester) async {
    await open(tester, FakeScaleLink(devices: const []));
    await runSession(tester);

    expect(find.text('Bilancia non trovata'), findsOneWidget);
  });

  testWidgets('pesata completa: mostra misura, composizione e la salva', (
    tester,
  ) async {
    await completeProfile();
    final link = FakeScaleLink(
      autoFrames: [
        fakeHandshakeFrame(),
        fakeWeightFrame(weightKg: 95.8, stable: false),
        fakeWeightFrame(weightKg: 95.8, stable: true, resistance1: 442),
      ],
    );
    await open(tester, link);
    await runSession(tester);

    expect(find.text('Pesata completa'), findsOneWidget);
    expect(find.byKey(const Key('scale_weight_row')), findsOneWidget);
    expect(find.text('95,8'), findsOneWidget);
    expect(find.byKey(const Key('scale_impedance_row')), findsOneWidget);
    expect(find.byKey(const Key('scale_lean_row')), findsOneWidget);
    expect(find.byKey(const Key('scale_bmr_row')), findsOneWidget);
    // Il registro è in schermata, con le trame in esadecimale.
    expect(find.byKey(const Key('scale_log')), findsOneWidget);

    await tester.tap(find.byKey(const Key('scale_save_button')));
    await tester.pump();
    await tester.pump();

    final saved = await database.select(database.bodyMeasurements).getSingle();
    expect(saved.source, 'renpho_ble');
    expect(saved.impedanceOhm, 442);
    expect(saved.formulaVersion, 'bia-v1');

    await tester.pump();
    expect(find.byKey(const Key('scale_saved_note')), findsOneWidget);
  });

  testWidgets('senza contatto elettrodi: peso sì, composizione no', (
    tester,
  ) async {
    await completeProfile();
    final link = FakeScaleLink(
      autoFrames: [
        fakeHandshakeFrame(),
        fakeWeightFrame(
          weightKg: 95.8,
          stable: true,
          resistance1: 0,
          resistance2: 0,
        ),
      ],
    );
    await open(tester, link);
    await runSession(tester);
    // Il tempo di grazia concesso all'impedenza.
    await tester.pump(const Duration(seconds: 9));
    await tester.pump();

    expect(find.text('Solo il peso'), findsOneWidget);
    expect(find.byKey(const Key('scale_weight_only')), findsOneWidget);
    expect(find.byKey(const Key('scale_lean_row')), findsNothing);

    await tester.tap(find.byKey(const Key('scale_save_button')));
    await tester.pump();
    await tester.pump();

    final saved = await database.select(database.bodyMeasurements).getSingle();
    expect(saved.weightKg, closeTo(95.8, 0.001));
    expect(saved.bodyFatPct, isNull);
    expect(saved.formulaVersion, isNull);
  });

  testWidgets('profilo incompleto: chiede i dati invece di stimarli', (
    tester,
  ) async {
    // Nessuna altezza, nascita o sesso: la formula non ha niente da dire, e
    // la schermata lo dichiara invece di mostrare uno zero.
    final link = FakeScaleLink(
      autoFrames: [
        fakeHandshakeFrame(),
        fakeWeightFrame(weightKg: 95.8, stable: true, resistance1: 442),
      ],
    );
    await open(tester, link);
    await runSession(tester);

    expect(find.byKey(const Key('scale_profile_incomplete')), findsOneWidget);
    expect(find.byKey(const Key('scale_lean_row')), findsNothing);
  });

  testWidgets('lo storico da rifare si propone, non si esegue di nascosto', (
    tester,
  ) async {
    await completeProfile();
    final now = AppTime.nowUtc();
    await database
        .into(database.bodyMeasurements)
        .insert(
          BodyMeasurementsCompanion.insert(
            id: 'vecchia',
            profileId: profileId,
            weightKg: 95.8,
            measuredAt: DateTime.utc(2026, 8, 1, 5, 0),
            hasImpedance: const Value(true),
            impedanceOhm: const Value(442),
            bodyFatPct: const Value(11.1),
            formulaVersion: const Value('bia-v0'),
            source: const Value('renpho_ble'),
            externalId: const Value('vecchia'),
            createdAt: now,
            updatedAt: now,
          ),
        );

    await open(tester, FakeScaleLink());
    await tester.pump();

    expect(find.byKey(const Key('scale_recalculation_card')), findsOneWidget);

    await tester.tap(find.byKey(const Key('scale_recalculate_button')));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final row = await database.select(database.bodyMeasurements).getSingle();
    expect(row.formulaVersion, 'bia-v1');
    expect(row.impedanceOhm, 442, reason: 'la misura grezza non si tocca');
  });

  testWidgets('al 150% di testo nessuna card va in overflow', (tester) async {
    await completeProfile();
    final link = FakeScaleLink(
      autoFrames: [
        fakeHandshakeFrame(),
        fakeWeightFrame(weightKg: 95.8, stable: true, resistance1: 442),
      ],
    );
    await open(tester, link, textScale: 1.5);
    await runSession(tester);

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('scale_lean_row')), findsOneWidget);
  });

  testWidgets(
    'al buio i colori arrivano dal tema, non dalla tavolozza chiara',
    (tester) async {
      await open(tester, FakeScaleLink(), theme: AppTheme.dark);

      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(
        scaffold.backgroundColor,
        isNull,
        reason: 'niente colori letterali',
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('scale_honesty_note')), findsOneWidget);
    },
  );
}
