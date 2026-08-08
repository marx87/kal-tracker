import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/app.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/onboarding/data/onboarding_store.dart';
import 'package:kal_tracker/features/onboarding/data/personal_details_repository.dart';
import 'package:kal_tracker/features/onboarding/domain/personal_details.dart';
import 'package:kal_tracker/features/onboarding/presentation/onboarding_providers.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

/// Il primo avvio visto da fuori: si monta l'app vera, con il suo router e la
/// sua shell, perché la domanda «l'app si apre lo stesso?» non si può
/// rispondere guardando la sola schermata.
void main() {
  late AppDatabase database;
  late String profileId;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
  });

  Widget app(OnboardingStore store) => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(database),
      appConfigProvider.overrideWithValue(const AppConfig.offline()),
      onboardingStoreProvider.overrideWithValue(store),
    ],
    child: const KalTrackerApp(),
  );

  /// Il riquadro di prova predefinito è 800x600, che non è nessun telefono:
  /// una pagina che su un vero schermo si vede tutta lì finisce sotto la
  /// piega, e i tocchi cadono su widget mai costruiti.
  void phoneViewport(
    WidgetTester tester, {
    double width = 400,
    double height = 1000,
  }) {
    tester.view.physicalSize = Size(width * 3, height * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  /// Il giro completo per riaprire i dati personali dopo il primo avvio:
  /// Corpo → Progressi → in fondo alla pagina. È il percorso che la
  /// schermata di benvenuto promette a chi tocca «lo faccio dopo».
  Future<void> openPersonalDetails(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('nav_body')));
    await tester.pumpAndSettle();
    final directProgressButton = find.byKey(
      const Key('body_open_progress_button'),
    );
    if (directProgressButton.evaluate().isNotEmpty) {
      await tester.tap(directProgressButton);
    } else {
      await tester.tap(find.byKey(const Key('body_more_actions_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Progressi e impostazioni').last);
    }
    await tester.pumpAndSettle();
    final entry = find.byKey(const Key('open_personal_details_button'));
    // La voce sta in fondo alla pagina: si scorre fino a lì, come farebbe
    // Marco. La finestra alta di questi test serve solo a non trasformare
    // ogni prova in una prova dello scorrimento.
    await tester.scrollUntilVisible(
      entry,
      200,
      scrollable: find.descendant(
        of: find.byKey(const Key('progress_list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(entry);
    await tester.pumpAndSettle();
  }

  /// Chiude l'app prima di chiudere il database: senza, gli stream di Drift
  /// restano appesi e il test fallisce alla fine invece che dove serve.
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await database.close();
  }

  testWidgets('al primo avvio chiede i tre dati e non mostra la shell', (
    tester,
  ) async {
    phoneViewport(tester);
    await tester.pumpWidget(app(InMemoryOnboardingStore()));
    await tester.pumpAndSettle();

    expect(find.text('Prima di iniziare'), findsOneWidget);
    expect(find.byKey(const Key('personal_details_height_field')), findsOne);
    expect(find.byKey(const Key('main_navigation_bar')), findsNothing);

    await close(tester);
  });

  testWidgets('«lo faccio dopo» apre l’app e non ripropone la domanda', (
    tester,
  ) async {
    final store = InMemoryOnboardingStore();
    phoneViewport(tester);
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('personal_details_skip_button')));
    await tester.pumpAndSettle();

    // L'app si apre: è il punto di tutta la schermata.
    expect(find.byKey(const Key('main_navigation_bar')), findsOneWidget);
    expect(find.text('Prima di iniziare'), findsNothing);
    // E la domanda risulta fatta, altrimenti «dopo» sarebbe «al prossimo
    // avvio».
    expect(store.askedAt, isNotNull);

    await close(tester);
  });

  testWidgets('saltando non si scrive niente sul profilo', (tester) async {
    phoneViewport(tester);
    await tester.pumpWidget(app(InMemoryOnboardingStore()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('personal_details_skip_button')));
    await tester.pumpAndSettle();

    final details = await PersonalDetailsRepository(database).read(profileId);
    expect(details.isEmpty, isTrue);

    await close(tester);
  });

  testWidgets('quello che si scrive finisce sul profilo e l’app si apre', (
    tester,
  ) async {
    final store = InMemoryOnboardingStore();
    phoneViewport(tester);
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('personal_details_height_field')),
      '182,4',
    );
    await tester.tap(find.byKey(const Key('personal_details_sex_M')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('personal_details_save_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('main_navigation_bar')), findsOneWidget);

    final details = await PersonalDetailsRepository(database).read(profileId);
    expect(details.heightCm, 182.4);
    expect(details.sex, BiologicalSex.male);
    // Salvare due campi su tre è una risposta completa: chi non vuole dire la
    // data di nascita non deve ritrovarsi la domanda al prossimo avvio.
    expect(details.birthDate, isNull);
    expect(store.askedAt, isNotNull);

    await close(tester);
  });

  testWidgets('un’altezza impossibile non passa e non chiude la schermata', (
    tester,
  ) async {
    final store = InMemoryOnboardingStore();
    phoneViewport(tester);
    await tester.pumpWidget(app(store));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('personal_details_height_field')),
      '1820',
    );
    await tester.tap(find.byKey(const Key('personal_details_save_button')));
    await tester.pumpAndSettle();

    expect(find.text('Fra 50 e 260 cm'), findsOneWidget);
    expect(find.text('Prima di iniziare'), findsOneWidget);
    expect(store.askedAt, isNull);

    await close(tester);
  });

  testWidgets('il calendario della nascita si apre e la data scelta resta', (
    tester,
  ) async {
    phoneViewport(tester);
    await tester.pumpWidget(app(InMemoryOnboardingStore()));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('personal_details_birth_date_field')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    // La data iniziale del selettore è trentacinque anni fa: quello che conta
    // qui è che il valore scelto torni scritto nella riga, non quale sia.
    final expectedYear = AppTime.nowInRome().year - 35;
    expect(find.textContaining('$expectedYear'), findsWidgets);

    await close(tester);
  });

  testWidgets('con i tre dati già a posto la domanda non si fa', (
    tester,
  ) async {
    phoneViewport(tester);
    await PersonalDetailsRepository(database).write(
      profileId,
      PersonalDetails(
        heightCm: 182,
        birthDate: DateTime.utc(1987, 9, 13),
        sex: BiologicalSex.male,
      ),
    );

    await tester.pumpWidget(app(InMemoryOnboardingStore()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('main_navigation_bar')), findsOneWidget);
    expect(find.text('Prima di iniziare'), findsNothing);

    await close(tester);
  });

  testWidgets('senza un posto dove segnare la risposta non si chiede', (
    tester,
  ) async {
    // È la condizione dei test degli altri — `path_provider` non esiste — e
    // di un'installazione con lo spazio di supporto rotto. Chiedere ogni
    // volta sarebbe peggio che non chiedere.
    await tester.pumpWidget(app(InMemoryOnboardingStore(readable: false)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('main_navigation_bar')), findsOneWidget);
    expect(find.text('Prima di iniziare'), findsNothing);

    await close(tester);
  });

  testWidgets('da Progressi si torna sui dati personali', (tester) async {
    // Chi salta il benvenuto deve avere una porta per rientrare, altrimenti
    // «lo faccio dopo» è un vicolo cieco: l'altezza non si può inserire da
    // nessun'altra parte.
    phoneViewport(tester, height: 1400);
    await tester.pumpWidget(
      app(InMemoryOnboardingStore(askedAt: DateTime.utc(2026))),
    );
    await tester.pumpAndSettle();

    await openPersonalDetails(tester);

    expect(find.text('Dati personali'), findsWidgets);
    expect(find.byKey(const Key('personal_details_height_field')), findsOne);
    // Rientrando non c'è più «lo faccio dopo»: la via d'uscita è indietro.
    expect(find.byKey(const Key('personal_details_skip_button')), findsNothing);

    await close(tester);
  });

  testWidgets('rientrando i valori salvati sono già scritti', (tester) async {
    phoneViewport(tester, height: 1400);
    await PersonalDetailsRepository(database).write(
      profileId,
      PersonalDetails(
        heightCm: 182.5,
        birthDate: DateTime.utc(1987, 9, 13),
        sex: BiologicalSex.female,
      ),
    );

    await tester.pumpWidget(
      app(InMemoryOnboardingStore(askedAt: DateTime.utc(2026))),
    );
    await tester.pumpAndSettle();
    await openPersonalDetails(tester);

    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const Key('personal_details_height_field')),
          )
          .controller
          ?.text,
      '182,5',
    );
    expect(find.textContaining('13 settembre 1987'), findsOneWidget);
    // 39 anni compiuti il 13 settembre 1987, letti a oggi.
    expect(
      find.textContaining(
        '${PersonalDetails(birthDate: DateTime.utc(1987, 9, 13)).ageOn(AppTime.nowInRome())} anni',
      ),
      findsOneWidget,
    );

    await close(tester);
  });

  testWidgets('il profilo non si tocca finché non si salva', (tester) async {
    // Scrivere nei campi non è salvare: se l'app si chiude a metà compilazione
    // il profilo deve essere ancora quello di prima.
    phoneViewport(tester);
    await tester.pumpWidget(app(InMemoryOnboardingStore()));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('personal_details_height_field')),
      '175',
    );
    await tester.pumpAndSettle();

    final details = await PersonalDetailsRepository(database).read(profileId);
    expect(details.heightCm, isNull);

    await close(tester);
  });

  testWidgets('un profilo senza riga in tabella non blocca il benvenuto', (
    tester,
  ) async {
    // Caso limite di un ripristino andato storto: la schermata deve
    // comparire lo stesso, vuota, invece di mostrare un errore.
    phoneViewport(tester);
    await (database.delete(
      database.appProfiles,
    )..where((p) => p.id.equals(profileId))).go();

    await tester.pumpWidget(app(InMemoryOnboardingStore()));
    await tester.pumpAndSettle();

    // `getOrCreateMarco` ne ricrea uno vuoto: la domanda si fa.
    expect(find.text('Prima di iniziare'), findsOneWidget);

    await close(tester);
  });

  group('accessibilità', () {
    testWidgets('bersagli, etichette e contrasto reggono le linee guida', (
      tester,
    ) async {
      phoneViewport(tester);
      await tester.pumpWidget(app(InMemoryOnboardingStore()));
      await tester.pumpAndSettle();

      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));

      await close(tester);
    });

    testWidgets('il lettore di schermo sente la data come un bottone', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      phoneViewport(tester);
      await tester.pumpWidget(app(InMemoryOnboardingStore()));
      await tester.pumpAndSettle();

      // Non «testo, testo, icona»: un nodo solo, con la sua etichetta e il
      // suo valore.
      expect(
        tester.getSemantics(
          find.byKey(const Key('personal_details_birth_date_field')),
        ),
        isSemantics(
          label: 'Data di nascita',
          value: 'non indicata',
          isButton: true,
          hasTapAction: true,
        ),
      );

      handle.dispose();
      await close(tester);
    });

    testWidgets('al 150% di testo su schermo stretto niente trabocca', (
      tester,
    ) async {
      // 320 logici è il telefono più stretto che vale la pena servire; il
      // 150% è la taglia di sistema che rompe le righe affiancate. La
      // finestra è alta perché a quel corpo la pagina cresce: qui interessa
      // che niente trabocchi in larghezza, non quanto si debba scorrere.
      phoneViewport(tester, width: 320, height: 1600);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(database),
            appConfigProvider.overrideWithValue(const AppConfig.offline()),
            onboardingStoreProvider.overrideWithValue(
              InMemoryOnboardingStore(),
            ),
          ],
          child: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: const KalTrackerApp(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Prima di iniziare'), findsOneWidget);
      // Le due scelte del sesso vanno a capo invece di stringersi: è il
      // motivo per cui non sono un `SegmentedButton`.
      expect(find.byKey(const Key('personal_details_sex_M')), findsOne);
      expect(find.byKey(const Key('personal_details_sex_F')), findsOne);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));

      await close(tester);
    });

    testWidgets('anche di notte i bersagli e il contrasto reggono', (
      tester,
    ) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      phoneViewport(tester);
      await tester.pumpWidget(app(InMemoryOnboardingStore()));
      await tester.pumpAndSettle();

      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));

      await close(tester);
    });
  });

  testWidgets('svuotare il sesso lo svuota davvero', (tester) async {
    phoneViewport(tester, height: 1400);
    await PersonalDetailsRepository(database).write(
      profileId,
      const PersonalDetails(heightCm: 182, sex: BiologicalSex.male),
    );
    // La domanda è già stata fatta: si entra dalla porta di Progressi.
    await tester.pumpWidget(
      app(InMemoryOnboardingStore(askedAt: DateTime.utc(2026))),
    );
    await tester.pumpAndSettle();
    await openPersonalDetails(tester);

    final clear = find.byKey(const Key('personal_details_clear_sex_button'));
    await tester.ensureVisible(clear);
    await tester.tap(clear);
    await tester.pumpAndSettle();

    final save = find.byKey(const Key('personal_details_save_button'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    final details = await PersonalDetailsRepository(database).read(profileId);
    expect(details.sex, isNull);
    expect(details.heightCm, 182);

    await close(tester);
  });

  testWidgets('un profilo con dati arrivati da fuori si legge lo stesso', (
    tester,
  ) async {
    // Un sesso che questa versione non conosce (o una riga scritta a mano)
    // non deve far esplodere la schermata: si mostra il resto.
    phoneViewport(tester, height: 1400);
    await (database.update(
      database.appProfiles,
    )..where((p) => p.id.equals(profileId))).write(
      const AppProfilesCompanion(heightCm: Value(182), sex: Value('X')),
    );

    await tester.pumpWidget(
      app(InMemoryOnboardingStore(askedAt: DateTime.utc(2026))),
    );
    await tester.pumpAndSettle();
    await openPersonalDetails(tester);

    expect(tester.takeException(), isNull);
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const Key('personal_details_height_field')),
          )
          .controller
          ?.text,
      '182',
    );

    await close(tester);
  });
}
