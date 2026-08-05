import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/checkin/domain/daily_check_in.dart';

void main() {
  setUp(AppTime.initialize);

  group('checkInDayOf', () {
    test('la mezzanotte e mezza di Roma resta nel suo giorno', () {
      // 00:30 del 6 agosto a Roma sono le 22:30 del 5 in UTC: letto come
      // giorno UTC il check-in finirebbe nel giorno prima.
      final instant = DateTime.utc(2026, 8, 5, 22, 30);
      expect(checkInDayOf(instant), DateTime.utc(2026, 8, 6));
    });

    test('le 23:30 di Roma restano nel giorno che si sta vivendo', () {
      final instant = DateTime.utc(2026, 8, 5, 21, 30);
      expect(checkInDayOf(instant), DateTime.utc(2026, 8, 5));
    });
  });

  group('normalizzazione', () {
    test('le ore si arrotondano alla mezz\'ora e restano nei limiti', () {
      expect(DailyCheckIn.normalizeSleep(7.4), 7.5);
      expect(DailyCheckIn.normalizeSleep(7.1), 7.0);
      expect(DailyCheckIn.normalizeSleep(-3), 0);
      expect(DailyCheckIn.normalizeSleep(40), DailyCheckIn.maxSleepHours);
      expect(DailyCheckIn.normalizeSleep(double.nan), isNull);
      expect(DailyCheckIn.normalizeSleep(null), isNull);
    });

    test('l\'energia sta fra 1 e 5', () {
      expect(DailyCheckIn.normalizeEnergy(0), 1);
      expect(DailyCheckIn.normalizeEnergy(9), 5);
      expect(DailyCheckIn.normalizeEnergy(3), 3);
      expect(DailyCheckIn.normalizeEnergy(null), isNull);
    });
  });

  test('un check-in con un solo campo è valido ma non completo', () {
    final entry = DailyCheckIn(
      day: DateTime.utc(2026, 8, 5),
      updatedAt: DateTime.utc(2026, 8, 5, 6),
      sleepHours: 7,
    );
    expect(entry.isEmpty, isFalse);
    expect(entry.isComplete, isFalse);
    expect(entry.energy, isNull);
  });

  test('l\'energia porta con sé la sua etichetta', () {
    expect(EnergyLevel.fromScore(5), EnergyLevel.charged);
    expect(EnergyLevel.fromScore(5)!.label, 'Carico');
    expect(EnergyLevel.fromScore(7), isNull);
  });

  group('CheckInLog', () {
    final today = DateTime.utc(2026, 8, 5, 8);

    DailyCheckIn entryOn(DateTime day, {double? sleep = 7, int? energy = 4}) =>
        DailyCheckIn(
          day: checkInDayOf(day),
          updatedAt: day,
          sleepHours: sleep,
          energyScore: energy,
        );

    test('scrivere due volte lo stesso giorno sostituisce, non accoda', () {
      final log = const CheckInLog.empty()
          .upsert(entryOn(today, sleep: 6), now: today)
          .upsert(entryOn(today, sleep: 8), now: today);
      expect(log.entries, hasLength(1));
      expect(log.forDay(checkInDayOf(today))!.sleepHours, 8);
    });

    test('un check-in svuotato sparisce dallo storico', () {
      final log = const CheckInLog.empty()
          .upsert(entryOn(today), now: today)
          .upsert(entryOn(today, sleep: null, energy: null), now: today);
      expect(log.entries, isEmpty);
    });

    test('oltre la finestra i giorni vecchi si potano', () {
      final old = today.subtract(
        const Duration(days: CheckInLog.historyDays + 2),
      );
      final log = const CheckInLog.empty()
          .upsert(entryOn(old), now: old)
          .upsert(entryOn(today), now: today);
      expect(log.entries, hasLength(1));
      expect(log.forDay(checkInDayOf(old)), isNull);
    });

    test('il giro completo su JSON conserva i valori', () {
      final log = const CheckInLog.empty()
          .upsert(entryOn(today, sleep: 7.5, energy: 2), now: today)
          .upsert(
            entryOn(
              today.subtract(const Duration(days: 1)),
              sleep: 6,
              energy: 5,
            ),
            now: today,
          );
      final decoded = CheckInLog.fromJson(
        jsonDecode(jsonEncode(log.toJson())) as Map<String, Object?>,
      );
      expect(decoded.entries, hasLength(2));
      expect(decoded.forDay(checkInDayOf(today))!.sleepHours, 7.5);
      expect(decoded.forDay(checkInDayOf(today))!.energyScore, 2);
      // Dal più recente: è l'ordine in cui il coach leggerà la settimana.
      expect(decoded.recentFirst.first.day, checkInDayOf(today));
    });

    test('un file rovinato vale «nessun check-in», non un\'eccezione', () {
      expect(CheckInLog.fromJson(const {}).entries, isEmpty);
      expect(
        CheckInLog.fromJson(const {'entries': 'non una lista'}).entries,
        isEmpty,
      );
      expect(
        CheckInLog.fromJson(const {
          'entries': [
            {'day': 'non-una-data', 'sleep_hours': 7},
            {'day': '2026-08-05', 'sleep_hours': 7},
          ],
        }).entries,
        hasLength(1),
      );
    });
  });
}
