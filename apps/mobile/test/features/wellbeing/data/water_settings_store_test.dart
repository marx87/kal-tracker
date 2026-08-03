import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/wellbeing/data/water_settings_store.dart';
import 'package:kal_tracker/features/wellbeing/domain/water_settings.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('water-settings-test');
  });

  tearDown(() => directory.delete(recursive: true));

  FileWaterSettingsStore store() =>
      FileWaterSettingsStore(directory: () async => directory);

  test('senza file ritorna i default', () async {
    final settings = await store().read();

    expect(settings, const WaterSettings());
    expect(settings.goalMilliliters, 2000);
    expect(settings.remindersEnabled, isFalse);
    expect(settings.reminderIntervalHours, 2);
    expect(settings.reminderStartHour, 9);
    expect(settings.reminderEndHour, 21);
  });

  test('scrive e rilegge le impostazioni (anche da un nuovo store)', () async {
    const settings = WaterSettings(
      goalMilliliters: 2500,
      remindersEnabled: true,
      reminderIntervalHours: 3,
      reminderStartHour: 8,
      reminderEndHour: 20,
    );

    await store().write(settings);
    final reloaded = await store().read();

    expect(reloaded, settings);
  });

  test('file corrotto: si riparte dai default senza crash', () async {
    final file = File('${directory.path}/${FileWaterSettingsStore.fileName}');
    await file.writeAsString('questo non è JSON {');

    expect(await store().read(), const WaterSettings());
  });

  test('valori assurdi nel JSON vengono sanificati', () async {
    final file = File('${directory.path}/${FileWaterSettingsStore.fileName}');
    await file.writeAsString(
      '{"goal_milliliters": -5, "reminders_enabled": "sì", '
      '"reminder_interval_hours": 7, '
      '"reminder_start_hour": 22, "reminder_end_hour": 9}',
    );

    final settings = await store().read();

    expect(settings.goalMilliliters, 2000);
    expect(settings.remindersEnabled, isFalse);
    expect(settings.reminderIntervalHours, 2);
    // Fascia invertita: torna quella di default 9-21.
    expect(settings.reminderStartHour, 9);
    expect(settings.reminderEndHour, 21);
  });
}
