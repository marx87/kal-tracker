import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/app.dart';
import 'package:kal_tracker/core/config/app_config.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/notifications/water_reminder_providers.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/wellbeing/presentation/wellbeing_providers.dart';

import '../../../core/notifications/water_reminder_fakes.dart';

void main() {
  late AppDatabase database;
  late InMemoryWaterSettingsStore store;
  late FakeWaterReminderGateway gateway;

  setUp(() {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    store = InMemoryWaterSettingsStore();
    gateway = FakeWaterReminderGateway();
  });

  Widget app() => ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(database),
      appConfigProvider.overrideWithValue(const AppConfig.offline()),
      waterSettingsStoreProvider.overrideWithValue(store),
      waterReminderGatewayProvider.overrideWithValue(gateway),
    ],
    child: const KalTrackerApp(),
  );

  String waterTotal(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('water_daily_total'))).data!;

  // Il widget acqua sta sotto l'anello calorie: nel viewport dei test
  // serve scrollare prima di toccare.
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('il widget acqua mostra il progresso e i pulsanti rapidi '
      'aggiornano il totale', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('water_card')), findsOneWidget);
    expect(waterTotal(tester), '0 / 2000 ml');
    expect(
      tester.widget<Text>(find.byKey(const Key('water_percent'))).data,
      '0%',
    );

    await tapVisible(tester, find.byKey(const Key('water_add_500')));
    expect(waterTotal(tester), '500 / 2000 ml');
    expect(
      tester.widget<Text>(find.byKey(const Key('water_percent'))).data,
      '25%',
    );

    await tapVisible(tester, find.byKey(const Key('water_add_200')));
    expect(waterTotal(tester), '700 / 2000 ml');

    await _disposeApp(tester, database);
  });

  testWidgets('+330 e poi Annulla riporta il totale al valore di prima', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tapVisible(tester, find.byKey(const Key('water_add_500')));
    expect(waterTotal(tester), '500 / 2000 ml');

    await tapVisible(tester, find.byKey(const Key('water_add_330')));
    expect(waterTotal(tester), '830 / 2000 ml');
    expect(find.text('+330 ml: continua così!'), findsOneWidget);

    await tester.tap(find.text('Annulla'));
    await tester.pumpAndSettle();
    expect(waterTotal(tester), '500 / 2000 ml');

    await _disposeApp(tester, database);
  });

  testWidgets('l’obiettivo modificato dal sheet aggiorna il progresso', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tapVisible(tester, find.byKey(const Key('water_card_tap')));

    await tester.enterText(find.byKey(const Key('water_goal_field')), '2500');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('save_water_goal_button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('close_water_sheet')));
    await tester.pumpAndSettle();

    expect(waterTotal(tester), '0 / 2500 ml');
    expect(store.settings.goalMilliliters, 2500);

    await _disposeApp(tester, database);
  });

  testWidgets('il toggle promemoria chiede il permesso e pianifica; '
      'spegnerlo cancella tutto', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tapVisible(tester, find.byKey(const Key('water_card_tap')));

    await tester.tap(find.byKey(const Key('water_reminders_toggle')));
    await tester.pumpAndSettle();

    expect(gateway.permissionRequests, 1);
    expect(gateway.scheduled.map((slot) => slot.hour), [
      9,
      11,
      13,
      15,
      17,
      19,
      21,
    ]);
    expect(store.settings.remindersEnabled, isTrue);

    // Nuovo intervallo: ripianifica ogni 3 ore, sempre senza altri permessi.
    await tester.tap(find.byKey(const Key('water_interval_3')));
    await tester.pumpAndSettle();
    expect(gateway.permissionRequests, 1);
    expect(gateway.scheduled.map((slot) => slot.hour), [9, 12, 15, 18, 21]);
    expect(store.settings.reminderIntervalHours, 3);

    // Toggle off: via tutto.
    await tester.tap(find.byKey(const Key('water_reminders_toggle')));
    await tester.pumpAndSettle();
    expect(gateway.scheduled, isEmpty);
    expect(store.settings.remindersEnabled, isFalse);
    expect(find.text('Promemoria acqua disattivati.'), findsOneWidget);

    await _disposeApp(tester, database);
  });

  testWidgets('permesso negato: toggle resta spento e spiega cosa fare', (
    tester,
  ) async {
    gateway.permissionGranted = false;

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tapVisible(tester, find.byKey(const Key('water_card_tap')));

    await tester.tap(find.byKey(const Key('water_reminders_toggle')));
    await tester.pumpAndSettle();

    expect(gateway.scheduled, isEmpty);
    expect(store.settings.remindersEnabled, isFalse);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const Key('water_reminders_toggle')),
          )
          .value,
      isFalse,
    );
    expect(
      find.textContaining('serve il permesso alle notifiche'),
      findsOneWidget,
    );

    await _disposeApp(tester, database);
  });

  testWidgets('lo storico del giorno elenca i bicchieri e li sa eliminare', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tapVisible(tester, find.byKey(const Key('water_add_330')));

    await tapVisible(tester, find.byKey(const Key('water_card_tap')));
    expect(find.text('330 ml'), findsOneWidget);

    final deleteButton = find.byWidgetPredicate(
      (widget) =>
          widget.key != null &&
          widget.key.toString().contains('water_entry_delete_'),
    );
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();

    expect(
      find.text('Ancora nessun bicchiere registrato in questo giorno.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('close_water_sheet')));
    await tester.pumpAndSettle();
    expect(waterTotal(tester), '0 / 2000 ml');

    await _disposeApp(tester, database);
  });
}

Future<void> _disposeApp(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(database.close);
}
