import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/notifications/water_reminders.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/wellbeing/domain/water_settings.dart';
import 'package:timezone/timezone.dart' as tz;

import 'water_reminder_fakes.dart';

void main() {
  setUp(AppTime.initialize);

  group('waterReminderSlots', () {
    test('ogni 2 ore dalle 9 alle 21 sono 7 promemoria esatti', () {
      final slots = waterReminderSlots(const WaterSettings());

      expect(slots.map((slot) => slot.hour), [9, 11, 13, 15, 17, 19, 21]);
      expect(slots.map((slot) => slot.id), [
        for (var index = 0; index < 7; index++)
          waterReminderBaseNotificationId + index,
      ]);
      // Id tutti diversi e messaggi sempre presenti.
      expect(slots.map((slot) => slot.id).toSet(), hasLength(slots.length));
      for (final slot in slots) {
        expect(slot.title, isNotEmpty);
        expect(slot.body, isNotEmpty);
      }
    });

    test('ogni 3 ore dalle 9 alle 21 e ogni ora dalle 9 alle 12', () {
      final everyThree = waterReminderSlots(
        const WaterSettings(reminderIntervalHours: 3),
      );
      expect(everyThree.map((slot) => slot.hour), [9, 12, 15, 18, 21]);

      final everyHour = waterReminderSlots(
        const WaterSettings(
          reminderIntervalHours: 1,
          reminderStartHour: 9,
          reminderEndHour: 12,
        ),
      );
      expect(everyHour.map((slot) => slot.hour), [9, 10, 11, 12]);
    });

    test('nessun promemoria fuori dalla fascia oraria', () {
      for (final interval in WaterSettings.allowedIntervals) {
        final settings = WaterSettings(
          reminderIntervalHours: interval,
          reminderStartHour: 8,
          reminderEndHour: 20,
        );
        for (final slot in waterReminderSlots(settings)) {
          expect(slot.hour, inInclusiveRange(8, 20));
        }
      }
    });
  });

  group('nextWaterReminderInstance', () {
    test('con orologio finto sceglie oggi o domani correttamente', () {
      final rome = tz.getLocation(AppTime.zoneName);
      final now = tz.TZDateTime(rome, 2026, 8, 3, 10, 30);

      // Le 11 devono ancora arrivare: oggi.
      expect(
        nextWaterReminderInstance(11, now),
        tz.TZDateTime(rome, 2026, 8, 3, 11),
      );
      // Le 9 sono passate: domani.
      expect(
        nextWaterReminderInstance(9, now),
        tz.TZDateTime(rome, 2026, 8, 4, 9),
      );
      // Le 10 in punto sono passate da mezz'ora: domani.
      expect(
        nextWaterReminderInstance(10, now),
        tz.TZDateTime(rome, 2026, 8, 4, 10),
      );
    });

    test('resta alle ore esatte anche oltre il cambio ora', () {
      final rome = tz.getLocation(AppTime.zoneName);
      // Notte del passaggio all'ora solare (25/10/2026).
      final now = tz.TZDateTime(rome, 2026, 10, 24, 22);
      final next = nextWaterReminderInstance(9, now);
      expect(next.hour, 9);
      expect(next.day, 25);
    });
  });

  group('WaterRemindersService', () {
    late FakeWaterReminderGateway gateway;
    late WaterRemindersService service;

    setUp(() {
      gateway = FakeWaterReminderGateway();
      service = WaterRemindersService(gateway);
    });

    test('enable chiede il permesso e pianifica tutti gli slot', () async {
      final enabled = await service.enable(
        const WaterSettings(remindersEnabled: true),
      );

      expect(enabled, isTrue);
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
    });

    test('permesso negato: niente pianificazioni e ritorna false', () async {
      gateway.permissionGranted = false;

      final enabled = await service.enable(
        const WaterSettings(remindersEnabled: true),
      );

      expect(enabled, isFalse);
      expect(gateway.scheduled, isEmpty);
    });

    test('disable cancella tutto', () async {
      await service.enable(const WaterSettings(remindersEnabled: true));
      expect(gateway.scheduled, isNotEmpty);

      await service.disable();

      expect(gateway.scheduled, isEmpty);
      expect(gateway.cancelAllCount, greaterThanOrEqualTo(2));
    });

    test('applySettings ripianifica al nuovo intervallo senza richiedere '
        'di nuovo il permesso', () async {
      await service.enable(const WaterSettings(remindersEnabled: true));

      await service.applySettings(
        const WaterSettings(remindersEnabled: true, reminderIntervalHours: 3),
      );

      expect(gateway.permissionRequests, 1);
      expect(gateway.scheduled.map((slot) => slot.hour), [9, 12, 15, 18, 21]);
    });

    test('applySettings con promemoria spenti cancella e basta', () async {
      await service.enable(const WaterSettings(remindersEnabled: true));

      await service.applySettings(const WaterSettings());

      expect(gateway.scheduled, isEmpty);
    });

    test('rescheduleOnStartup non tocca nulla se i promemoria sono '
        'spenti', () async {
      await service.rescheduleOnStartup(const WaterSettings());

      expect(gateway.initializeCount, 0);
      expect(gateway.scheduled, isEmpty);
      expect(gateway.cancelAllCount, 0);
    });

    test('rescheduleOnStartup ripianifica se attivi', () async {
      await service.rescheduleOnStartup(
        const WaterSettings(remindersEnabled: true, reminderIntervalHours: 3),
      );

      expect(gateway.permissionRequests, 0);
      expect(gateway.scheduled.map((slot) => slot.hour), [9, 12, 15, 18, 21]);
    });
  });
}
