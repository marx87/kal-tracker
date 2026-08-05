import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/gym_import/data/gym_tracker_importer.dart';
import 'package:kal_tracker/features/gym_import/domain/gym_import_report.dart';
import 'package:kal_tracker/features/gym_import/presentation/gym_import_file_gateway.dart';
import 'package:kal_tracker/features/gym_import/presentation/gym_import_providers.dart';
import 'package:kal_tracker/features/gym_import/presentation/gym_import_screen.dart';

import '../gym_fixtures.dart';

void main() {
  late AppDatabase database;
  late _FakeGateway gateway;

  setUp(() {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    gateway = _FakeGateway({
      'export': _fixture(exportPath),
      'dump': _fixture(dumpPath),
      // Un JSON valido che però non è un export di Gym Tracker: è il caso in
      // cui a fermarsi deve essere l'importer, non la schermata.
      'altro': const GymImportFile(
        name: 'kal-tracker-backup.json',
        contents: '{"app":"kal-tracker","schemaVersion":1}',
        sizeBytes: 40,
      ),
    });
  });

  tearDown(() async => database.close());

  Future<int> countWorkouts() async =>
      (await database.select(database.workouts).get()).length;

  testWidgets('l’anteprima mostra i numeri veri senza scrivere niente', (
    tester,
  ) async {
    await _pumpScreen(tester, database, gateway);

    // Prima di scegliere qualcosa: nessuna anteprima e nessun bottone attivo.
    expect(find.byKey(const Key('gym_import_empty')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('gym_import_preview_button')),
          )
          .onPressed,
      isNull,
    );
    expect(find.text('Prima scegli l\'export di Gym Tracker.'), findsOneWidget);

    await _chooseFile(tester, const Key('gym_import_pick_export'), 'export');
    expect(_slotLabel(tester, 'export'), contains('gym-tracker-export.json'));

    await _tap(tester, const Key('gym_import_preview_button'));

    expect(find.byKey(const Key('gym_import_preview')), findsOneWidget);
    expect(find.byKey(const Key('gym_import_result')), findsNothing);
    // Gli stessi conteggi dei test dell'importer: l'anteprima è l'import
    // vero, annullato.
    expect(find.text('308'), findsOneWidget);
    expect(find.text('29'), findsOneWidget);
    expect(find.byKey(const Key('gym_import_warnings')), findsOneWidget);
    expect(find.byKey(const Key('gym_import_not_imported')), findsOneWidget);

    // Senza dump la schermata lo dichiara invece di lasciarlo intuire.
    expect(find.text('Senza dump Firestore'), findsOneWidget);

    // E soprattutto: il database è ancora vuoto.
    expect(await countWorkouts(), 0);
  });

  testWidgets('si scrive solo dopo la conferma, e il secondo giro è a vuoto', (
    tester,
  ) async {
    await _pumpScreen(tester, database, gateway);
    await _chooseFile(tester, const Key('gym_import_pick_export'), 'export');
    await _chooseFile(tester, const Key('gym_import_pick_dump'), 'dump');
    await _tap(tester, const Key('gym_import_preview_button'));

    expect(find.text('Con il dump Firestore'), findsOneWidget);
    final confirm = await _reveal(
      tester,
      const Key('gym_import_confirm_button'),
    );
    expect(
      tester
          .widget<Text>(
            find.descendant(of: confirm, matching: find.byType(Text)),
          )
          .data,
      startsWith('Importa le '),
    );

    await _tap(tester, const Key('gym_import_confirm_button'));

    expect(find.byKey(const Key('gym_import_result')), findsOneWidget);
    expect(find.byKey(const Key('gym_import_preview')), findsNothing);
    expect(await countWorkouts(), 29);

    // Rieseguibile senza paura: si rifà lo stesso import e la schermata dice
    // che non entra niente, invece di far temere i doppioni.
    await _tap(tester, const Key('gym_import_restart_button'));
    await _chooseFile(tester, const Key('gym_import_pick_export'), 'export');
    await _tap(tester, const Key('gym_import_preview_button'));

    expect(find.text('Non entra niente'), findsOneWidget);
    expect(find.byKey(const Key('gym_import_confirm_button')), findsNothing);
    expect(
      find.byKey(const Key('gym_import_change_files_button')),
      findsOneWidget,
    );
    expect(await countWorkouts(), 29);
  });

  testWidgets('un file che non è di Gym Tracker si ferma prima di scrivere', (
    tester,
  ) async {
    await _pumpScreen(tester, database, gateway);
    await _chooseFile(tester, const Key('gym_import_pick_export'), 'altro');
    await _tap(tester, const Key('gym_import_preview_button'));

    expect(find.byKey(const Key('gym_import_error')), findsOneWidget);
    expect(
      find.textContaining('non è un export di Gym Tracker'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('gym_import_preview')), findsNothing);
    expect(await countWorkouts(), 0);
  });

  testWidgets('un percorso sbagliato lo dice appena scelto', (tester) async {
    await _pumpScreen(tester, database, gateway);
    await _chooseFile(
      tester,
      const Key('gym_import_pick_export'),
      '/percorso/inventato.json',
    );

    expect(find.byKey(const Key('gym_import_error')), findsOneWidget);
    expect(find.textContaining('Non trovo nessun file'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('gym_import_preview_button')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets(
    'togliere il dump si può annullare, e l’avviso sparisce da solo',
    (tester) async {
      await _pumpScreen(tester, database, gateway);
      await _chooseFile(tester, const Key('gym_import_pick_export'), 'export');
      await _chooseFile(tester, const Key('gym_import_pick_dump'), 'dump');
      expect(_slotLabel(tester, 'dump'), contains('gym-firestore-dump.json'));

      await _tap(tester, const Key('gym_import_remove_dump'));
      expect(_slotLabel(tester, 'dump'), startsWith('Facoltativo.'));
      expect(find.text('Annulla'), findsOneWidget);

      await tester.tap(find.text('Annulla'));
      await tester.pumpAndSettle();
      expect(_slotLabel(tester, 'dump'), contains('gym-firestore-dump.json'));

      // Seconda rimozione: stavolta non si tocca «Annulla» e la snackbar deve
      // chiudersi da sola. Su questo Flutter quelle con azione non lo fanno, e
      // senza showAutoClosingSnackBar resterebbe lì per sempre.
      await _tap(tester, const Key('gym_import_remove_dump'));
      expect(find.text('Annulla'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.text('Annulla'), findsNothing);
      expect(_slotLabel(tester, 'dump'), startsWith('Facoltativo.'));
    },
  );

  testWidgets('con un selettore di sistema non si passa dal percorso', (
    tester,
  ) async {
    final browsing = _FakeGateway(
      const {},
      canBrowse: true,
      browseResult: _fixture(exportPath),
    );
    await _pumpScreen(tester, database, browsing);

    await _tap(tester, const Key('gym_import_pick_export'));

    // Nessun foglio: il selettore ha già dato il file.
    expect(find.byKey(const Key('gym_import_source_field')), findsNothing);
    expect(browsing.browseCalls, 1);
    expect(_slotLabel(tester, 'export'), contains('gym-tracker-export.json'));
  });

  testWidgets('mentre lavora mostra il passo e toglie i bottoni', (
    tester,
  ) async {
    // Un importer che si ferma a comando: è l'unico modo di vedere la barra,
    // perché con le fixture vere il lavoro finisce prima del frame dopo.
    final gate = Completer<void>();
    await _pumpScreen(
      tester,
      database,
      gateway,
      importer: _SlowImporter(database, gate),
    );
    await _chooseFile(tester, const Key('gym_import_pick_export'), 'export');

    final button = await _reveal(
      tester,
      const Key('gym_import_preview_button'),
    );
    await tester.tap(button);
    // Niente pumpAndSettle: la barra del passo in corso non si ferma mai.
    await tester.pump();

    expect(find.byKey(const Key('gym_import_progress')), findsOneWidget);
    expect(find.text('Passo 2 di 3'), findsOneWidget);
    expect(find.text('Provo l\'import a vuoto'), findsOneWidget);
    expect(find.byKey(const Key('gym_import_preview_button')), findsNothing);
    // Anche la scelta dei file è spenta: cambiarli a metà corsa non avrebbe
    // senso.
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('gym_import_pick_export')))
          .onPressed,
      isNull,
    );

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('gym_import_progress')), findsNothing);
    expect(find.byKey(const Key('gym_import_preview')), findsOneWidget);
    expect(await countWorkouts(), 0);
  });

  testWidgets('bersagli da 48 e testo leggibile, con l’anteprima aperta', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pumpScreen(tester, database, gateway);
    await _chooseFile(tester, const Key('gym_import_pick_export'), 'export');
    await _tap(tester, const Key('gym_import_preview_button'));

    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));

    semantics.dispose();
  });

  testWidgets('regge il testo al 150% e il tema scuro', (tester) async {
    await _pumpScreen(
      tester,
      database,
      gateway,
      theme: AppTheme.dark,
      textScale: 1.5,
    );
    await _chooseFile(tester, const Key('gym_import_pick_export'), 'export');
    await _tap(tester, const Key('gym_import_preview_button'));

    expect(find.byKey(const Key('gym_import_preview')), findsOneWidget);
    // Il colore DAVVERO disegnato dalla card, non quello dichiarato: se
    // qualcuno reintroduce un colore letterale della tavolozza di giorno, qui
    // si vede.
    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byKey(const Key('gym_import_preview')),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.color, AppTheme.dark.cardTheme.color);
  });
}

/// Che cosa dice la riga del file scelto. Si legge dalla sua chiave e non dal
/// testo, perché lo stesso nome di file compare anche nella snackbar.
String _slotLabel(WidgetTester tester, String slot) =>
    tester.widget<Text>(find.byKey(Key('gym_import_${slot}_name'))).data!;

/// Legge una fixture in modo sincrono: dentro `testWidgets` l'I/O vero non
/// verrebbe completato dal falso orologio del test.
GymImportFile _fixture(String path) {
  final contents = File(path).readAsStringSync();
  return GymImportFile(
    name: path.split('/').last,
    contents: contents,
    sizeBytes: utf8.encode(contents).length,
  );
}

Future<void> _pumpScreen(
  WidgetTester tester,
  AppDatabase database,
  GymImportFileGateway gateway, {
  ThemeData? theme,
  double textScale = 1,
  GymTrackerImporter? importer,
}) async {
  // Finestra alta: la schermata è una lista lunga e i figli fuori viewport
  // non verrebbero nemmeno costruiti.
  tester.view.physicalSize = const Size(430, 3600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        gymImportFileGatewayProvider.overrideWithValue(gateway),
        if (importer != null)
          gymTrackerImporterProvider.overrideWithValue(importer),
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
        home: const GymImportScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Porta in vista un elemento della lista, costruendolo se serve: con il
/// rendiconto aperto la schermata è più lunga di qualunque finestra, e i figli
/// fuori dalla viewport non esistono ancora nell'albero.
Future<Finder> _reveal(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      300,
      scrollable: find.descendant(
        of: find.byKey(const Key('gym_import_list')),
        matching: find.byType(Scrollable),
      ),
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  return finder;
}

Future<void> _tap(WidgetTester tester, Key key) async {
  final finder = await _reveal(tester, key);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Sceglie un file passando dal foglio del percorso, come farebbe Marco
/// finché non c'è un selettore di sistema.
Future<void> _chooseFile(WidgetTester tester, Key slot, String source) async {
  await _tap(tester, slot);
  await tester.enterText(
    find.byKey(const Key('gym_import_source_field')),
    source,
  );
  tester.testTextInput.hide();
  await tester.pumpAndSettle();
  await _tap(tester, const Key('gym_import_source_confirm'));
}

/// L'importer vero, che però aspetta il via: serve a fermare la schermata a
/// metà e guardarla mentre lavora.
class _SlowImporter extends GymTrackerImporter {
  _SlowImporter(super.database, this.gate);

  final Completer<void> gate;

  @override
  Future<GymImportReport> importExport({
    required String profileId,
    required Map<String, Object?> export,
    Map<String, Object?>? firestoreDump,
    String? firestoreUserId,
    bool enqueueSync = false,
  }) async {
    await gate.future;
    return super.importExport(
      profileId: profileId,
      export: export,
      firestoreDump: firestoreDump,
      firestoreUserId: firestoreUserId,
      enqueueSync: enqueueSync,
    );
  }
}

class _FakeGateway implements GymImportFileGateway {
  _FakeGateway(this.files, {this.canBrowse = false, this.browseResult});

  final Map<String, GymImportFile> files;
  final GymImportFile? browseResult;
  int browseCalls = 0;

  @override
  final bool canBrowse;

  @override
  Future<GymImportFile?> browse() async {
    browseCalls++;
    return browseResult;
  }

  @override
  Future<GymImportFile> read(String rawInput) async {
    final file = files[rawInput.trim()];
    if (file == null) {
      throw GymImportFileException('Non trovo nessun file in «$rawInput».');
    }
    return file;
  }
}
