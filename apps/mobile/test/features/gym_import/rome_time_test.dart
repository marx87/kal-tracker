import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/time/app_time.dart';

void main() {
  setUpAll(AppTime.initialize);

  test('una data senza fuso è ora di Roma, non UTC', () {
    // È la sessione del 4 agosto delle 22:34 dell'export: letta come UTC
    // finirebbe nel 5 agosto e sposterebbe un giorno di storico.
    final instant = AppTime.parseInstant('2026-08-04T22:34:30.293609');

    expect(instant.isUtc, isTrue);
    expect(instant, DateTime.utc(2026, 8, 4, 20, 34, 30, 293, 609));
    expect(AppTime.inRome(instant).day, 4);
  });

  test('una data con Z o con offset resta l istante che è', () {
    expect(
      AppTime.parseInstant('2026-08-04T20:34:30Z'),
      DateTime.utc(2026, 8, 4, 20, 34, 30),
    );
    expect(
      AppTime.parseInstant('2026-08-04T22:34:30+02:00'),
      DateTime.utc(2026, 8, 4, 20, 34, 30),
    );
  });

  test('l ora legale cambia lo scarto della stessa ora civile', () {
    expect(
      AppTime.fromRomeLocal(DateTime(2026, 1, 15, 12)),
      DateTime.utc(2026, 1, 15, 11),
    );
    expect(
      AppTime.fromRomeLocal(DateTime(2026, 7, 15, 12)),
      DateTime.utc(2026, 7, 15, 10),
    );
  });

  test('la data di calendario è quella romana, non quella UTC', () {
    // La mezzanotte di Roma del 4 agosto è il 3 agosto alle 22 UTC: mandare
    // l istante a una colonna `date` la farebbe diventare il giorno prima.
    final midnight = AppTime.startOfDayUtc(DateTime(2026, 8, 4));

    expect(midnight, DateTime.utc(2026, 8, 3, 22));
    expect(AppTime.romeDateString(midnight), '2026-08-04');
  });
}
