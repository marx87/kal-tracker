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
import 'package:kal_tracker/features/quick_add/barcode_scan_screen.dart';

/// Il tablet di Marco in orizzontale.
const _tablet = Size(1706, 1200);

/// La colonna leggibile, presa dalla fonte unica delle soglie.
final _readable = AppBreakpoints.contentMaxWidth(AppWindowSize.expanded);

/// Il limite che Material 3 mette da solo ai fogli modali. Non lo scriviamo
/// noi da nessuna parte: il test lo controlla perché l'aggiunta rapida ci si
/// appoggia invece di rimettere un secondo limite addosso al primo.
const _sheetMaxWidth = 640.0;

Widget _app(AppDatabase database) => ProviderScope(
  overrides: [
    databaseProvider.overrideWithValue(database),
    appConfigProvider.overrideWithValue(const AppConfig.offline()),
    // Mai il plugin reale della fotocamera nei test.
    barcodeScannerViewBuilderProvider.overrideWithValue(
      (context, onBarcode) => const SizedBox.expand(),
    ),
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

Future<void> _openQuickAdd(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(_app(database));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('add_food_button')));
  await tester.pumpAndSettle();
}

void main() {
  late AppDatabase database;

  setUp(() {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
  });

  testWidgets('a 1706 dp il menu dell’aggiunta rapida non si stira: resta '
      'nel foglio da 640 dp', (tester) async {
    _resize(tester, _tablet);
    await _openQuickAdd(tester, database);

    for (final key in const [
      'quick_add_manual',
      'quick_add_catalog',
      'quick_add_photo',
      'quick_add_barcode',
    ]) {
      expect(
        tester.getSize(find.byKey(Key(key))).width,
        lessThanOrEqualTo(_sheetMaxWidth),
        reason:
            'la voce $key è larga tutto lo schermo: il foglio ha perso il '
            'suo limite di larghezza',
      );
    }

    await _disposeApp(tester, database);
  });

  testWidgets('a 1706 dp la didascalia dello scanner resta una riga '
      'leggibile', (tester) async {
    _resize(tester, _tablet);
    await _openQuickAdd(tester, database);

    await tester.tap(find.byKey(const Key('quick_add_barcode')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('barcode_scan_screen')), findsOneWidget);

    expect(
      tester.getSize(find.byKey(const Key('barcode_scan_hint'))).width,
      lessThanOrEqualTo(_readable),
      reason:
          'la spiegazione sotto il mirino è testo: larga 1700 dp si legge '
          'come una riga di giornale sbagliata',
    );

    await _disposeApp(tester, database);
  });
}
