import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
// Le righe generate da drift si chiamano come le entità di dominio: qui
// vince il dominio, come nel repository.
import 'package:kal_tracker/core/database/app_database.dart'
    hide TrainingLimitation, TrainingProfile;
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/training_profile/data/training_profile_repository.dart';
import 'package:kal_tracker/features/training_profile/domain/training_profile.dart';
import 'package:kal_tracker/features/training_profile/presentation/training_settings_screen.dart';

void main() {
  late AppDatabase database;
  late TrainingProfileRepository repository;
  late String profileId;

  setUpAll(() => initializeDateFormatting('it'));

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
    repository = TrainingProfileRepository(database);
  });

  /// La finestra dei test è più corta di un telefono vero, e questa pagina è
  /// lunga: si allunga finché ci sta tutta, altrimenti ogni prova diventa una
  /// prova dello scorrimento invece che di quello che le interessa.
  void tallViewport(WidgetTester tester, {double height = 3600}) {
    tester.view.physicalSize = Size(400 * 3, height * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

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
      home: const TrainingSettingsScreen(),
    ),
  );

  /// Rilettura dal database DENTRO un widget test: il tempo qui è finto e le
  /// query di drift aspettano timer veri, quindi girano in `runAsync`.
  Future<TrainingProfile> readBack(WidgetTester tester) async =>
      (await tester.runAsync(() => repository.loadProfile(profileId)))!;

  testWidgets('l\'attrezzatura spuntata finisce nel profilo salvato', (
    tester,
  ) async {
    tallViewport(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    // Il tasto salva non si accende finché non c'è niente da salvare.
    final save = find.byKey(const Key('training_settings_save_button'));
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    await tester.tap(find.byKey(const Key('training_equipment_manubri')));
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('training_equipment_elasticiAncorabili')),
    );
    await tester.pump();

    await tester.tap(save);
    await tester.pumpAndSettle();

    final profile = await readBack(tester);
    expect(profile.equipment, {
      Equipment.elasticiAncorabili,
      Equipment.manubri,
    });
    expect(find.textContaining('Salvato.'), findsOneWidget);

    await _dispose(tester, database);
  });

  testWidgets(
    'senza attrezzatura dichiarata la schermata dice che non esclude niente',
    (tester) async {
      tallViewport(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('training_equipment_declaration')),
            )
            .data,
        contains('non escludo niente'),
      );

      await tester.tap(find.byKey(const Key('training_equipment_corpoLibero')));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('training_equipment_declaration')),
            )
            .data,
        isNot(contains('non escludo niente')),
      );

      await _dispose(tester, database);
    },
  );

  testWidgets('una limitazione si apre dal foglio e si chiude solo a mano', (
    tester,
  ) async {
    tallViewport(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('training_limitations_empty')), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Aggiungi'));
    await tester.pumpAndSettle();

    // Senza zona e senza gravità non si apre niente.
    final confirm = find.byKey(const Key('limitation_sheet_save_button'));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.tap(find.byKey(const Key('limitation_area_spalla')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('limitation_part_spalla_dx')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('limitation_severity_dolore')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('limitation_note_field')),
      'Rotazione esterna sopra i 90°',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    final opened = await readBack(tester);
    expect(opened.activeLimitations, hasLength(1));
    expect(opened.activeLimitations.single.bodyPart, BodyPart.spallaDx);
    expect(opened.activeLimitations.single.severity, LimitationSeverity.dolore);
    expect(
      opened.activeLimitations.single.note,
      'Rotazione esterna sopra i 90°',
    );
    expect(find.text('Spalla destra'), findsOneWidget);
    expect(find.text('«Rotazione esterna sopra i 90°»'), findsOneWidget);

    // Nessuna scadenza automatica: la chiusura è un gesto, e lo dice anche la
    // schermata.
    expect(find.textContaining('Nessuna scadenza automatica'), findsOneWidget);

    final close = find.byKey(
      Key('training_close_limitation_${opened.activeLimitations.single.id}'),
    );
    await tester.tap(close);
    await tester.pumpAndSettle();

    final closed = await readBack(tester);
    expect(closed.activeLimitations, isEmpty);
    expect(closed.limitations.single.resolvedAt, isNotNull);
    expect(find.text('Riapri'), findsOneWidget);

    await _dispose(tester, database);
  });

  testWidgets('la limitazione chiusa si riapre con la sua storia', (
    tester,
  ) async {
    final id = await repository.addLimitation(
      profileId: profileId,
      bodyPart: BodyPart.ginocchioSx,
      severity: LimitationSeverity.stop,
    );
    await repository.resolveLimitation(id);

    tallViewport(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    final reopen = find.byKey(Key('training_reopen_limitation_$id'));
    await tester.tap(reopen);
    await tester.pumpAndSettle();

    final profile = await readBack(tester);
    expect(profile.activeLimitations, hasLength(1));
    expect(profile.activeLimitations.single.id, id);

    await _dispose(tester, database);
  });

  testWidgets('la disponibilità si conta a passi e si può non indicare', (
    tester,
  ) async {
    tallViewport(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    final value = find.byKey(const Key('training_sessions_value'));
    expect(tester.widget<Text>(value).data, 'Non indicato');

    // Da «non indicato» si parte dal valore proposto, non da 1: il primo
    // tocco deve portare a una risposta plausibile.
    await tester.tap(find.byKey(const Key('training_sessions_increase')));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(value).data, '3 a settimana');

    await tester.tap(find.byKey(const Key('training_sessions_decrease')));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(value).data, '2 a settimana');

    await tester.tap(find.byKey(const Key('training_minutes_increase')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('training_minutes_value'))).data,
      '60 minuti',
    );

    await tester.tap(find.byKey(const Key('training_day_mar')));
    await tester.pumpAndSettle();

    final save = find.byKey(const Key('training_settings_save_button'));
    await tester.tap(save);
    await tester.pumpAndSettle();

    final profile = await readBack(tester);
    expect(profile.sessionsPerWeek, 2);
    expect(profile.minutesPerSession, 60);
    expect(profile.preferredDays, [TrainingDay.mar]);

    // «Non indicato» resta una risposta possibile anche dopo aver risposto.
    final clear = find.byKey(const Key('training_sessions_clear'));
    await tester.tap(clear);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect((await readBack(tester)).sessionsPerWeek, isNull);

    await _dispose(tester, database);
  });

  testWidgets('lo scarico parte da «Chiedimelo prima»', (tester) async {
    tallViewport(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    final description = find.byKey(const Key('training_deload_description'));
    expect(
      tester.widget<Text>(description).data,
      DeloadPreference.suggerito.description,
    );

    await tester.tap(find.byKey(const Key('training_deload_automatico')));
    await tester.pumpAndSettle();
    final save = find.byKey(const Key('training_settings_save_button'));
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(
      (await readBack(tester)).deloadPreference,
      DeloadPreference.automatico,
    );

    await _dispose(tester, database);
  });

  testWidgets('a testo 150 % la schermata regge senza traboccare', (
    tester,
  ) async {
    await repository.addLimitation(
      profileId: profileId,
      bodyPart: BodyPart.ginocchioSx,
      severity: LimitationSeverity.fastidio,
      note: 'Scende male dalle scale dopo gli affondi',
    );

    tallViewport(tester, height: 5200);
    await tester.pumpWidget(app(textScale: 1.5));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Impostazioni'), findsOneWidget);
    expect(find.text('Ginocchio sinistro'), findsOneWidget);

    await _dispose(tester, database);
  });

  testWidgets('i bersagli tattili arrivano a 48', (tester) async {
    final id = await repository.addLimitation(
      profileId: profileId,
      bodyPart: BodyPart.spallaSx,
      severity: LimitationSeverity.fastidio,
    );

    tallViewport(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    final chip = find.byKey(const Key('training_equipment_manubri'));
    expect(tester.getSize(chip).height, greaterThanOrEqualTo(48));

    final increase = find.byKey(const Key('training_sessions_increase'));
    expect(tester.getSize(increase).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(increase).width, greaterThanOrEqualTo(48));

    // Chiudere una limitazione è l'azione più delicata della pagina: il suo
    // bersaglio non può essere più piccolo degli altri.
    final close = find.byKey(Key('training_close_limitation_$id'));
    expect(tester.getSize(close).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(close).width, greaterThanOrEqualTo(48));

    await _dispose(tester, database);
  });

  testWidgets('al buio si disegna con i colori del tema', (tester) async {
    tallViewport(tester);
    await tester.pumpWidget(app(theme: AppTheme.dark));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final context = tester.element(find.byType(TrainingSettingsScreen));
    expect(Theme.of(context).colorScheme.brightness, Brightness.dark);

    await _dispose(tester, database);
  });
}

Future<void> _dispose(WidgetTester tester, AppDatabase database) async {
  // Smaltisce il timer di chiusura forzata delle snackbar con azione
  // (showAutoClosingSnackBar), altrimenti il teardown fallisce.
  await tester.pump(const Duration(seconds: 9));
  await tester.pumpAndSettle();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(database.close);
}
