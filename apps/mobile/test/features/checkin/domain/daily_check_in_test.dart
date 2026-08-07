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

  group('movimento', () {
    test('i passi si tagliano ai limiti ma non si arrotondano', () {
      // 8437 arriva com'è: il passo da mille è dell'inserimento, non della
      // misura, e il giorno in cui i passi arriveranno da un dispositivo
      // arrotondarli sarebbe buttare precisione che nessuno aveva chiesto.
      expect(DailyCheckIn.normalizeSteps(8437), 8437);
      expect(DailyCheckIn.normalizeSteps(-100), 0);
      expect(DailyCheckIn.normalizeSteps(999999), DailyCheckIn.maxSteps);
      expect(DailyCheckIn.normalizeSteps(null), isNull);
    });

    test('i minuti a piedi stanno fra zero e dieci ore', () {
      expect(DailyCheckIn.normalizeWalkMinutes(45), 45);
      expect(DailyCheckIn.normalizeWalkMinutes(-5), 0);
      expect(
        DailyCheckIn.normalizeWalkMinutes(2000),
        DailyCheckIn.maxWalkMinutes,
      );
    });

    test('zero conta come compilato, null no', () {
      final fermo = DailyCheckIn(
        day: DateTime.utc(2026, 8, 5),
        updatedAt: DateTime.utc(2026, 8, 5, 6),
        steps: 0,
        walkMinutes: 0,
      );
      final vuoto = DailyCheckIn(
        day: DateTime.utc(2026, 8, 5),
        updatedAt: DateTime.utc(2026, 8, 5, 6),
      );

      // È la distinzione su cui si regge il campo: un giorno fermo e un
      // giorno non segnato devono restare due cose diverse.
      expect(fermo.hasNeat, isTrue);
      expect(fermo.isEmpty, isFalse);
      expect(vuoto.hasNeat, isFalse);
      expect(vuoto.isEmpty, isTrue);
    });

    test('la sola camminata è un check-in valido ma non salvabile', () {
      final entry = DailyCheckIn(
        day: DateTime.utc(2026, 8, 5),
        updatedAt: DateTime.utc(2026, 8, 5, 6),
        walkMinutes: 40,
      );

      // La CHECK di `daily_check_ins` pretende ancora sonno o energia: per il
      // dominio la giornata esiste, per la tabella no.
      expect(entry.isEmpty, isFalse);
      expect(entry.isStorable, isFalse);
      expect(entry.copyWith(sleepHours: 7).isStorable, isTrue);
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

  test('sonno ed energia si chiudono da soli, il movimento no', () {
    final entry = DailyCheckIn(
      day: DateTime.utc(2026, 8, 5),
      updatedAt: DateTime.utc(2026, 8, 5, 6),
      sleepHours: 7,
      energyScore: 4,
    );

    // Due condizioni diverse per due momenti diversi: la card richiude sonno
    // ed energia appena ci sono, e tiene sotto gli occhi il movimento — che
    // è la domanda su ieri — finché non arriva anche quello.
    expect(entry.isComplete, isTrue);
    expect(entry.isFullyLogged, isFalse);
    expect(entry.copyWith(steps: 8000).isFullyLogged, isTrue);
  });

  test('l\'energia porta con sé la sua etichetta', () {
    expect(EnergyLevel.fromScore(5), EnergyLevel.charged);
    expect(EnergyLevel.fromScore(5)!.label, 'Carico');
    expect(EnergyLevel.fromScore(7), isNull);
  });

  group('CheckInLog', () {
    final today = DateTime.utc(2026, 8, 5, 8);

    DailyCheckIn entryOn(
      DateTime day, {
      double? sleep = 7,
      int? energy = 4,
      int? steps,
      int? walk,
    }) => DailyCheckIn(
      day: checkInDayOf(day),
      updatedAt: day,
      sleepHours: sleep,
      energyScore: energy,
      steps: steps,
      walkMinutes: walk,
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

    test('un giorno di solo movimento resta nello storico', () {
      final log = const CheckInLog.empty().upsert(
        entryOn(today, sleep: null, energy: null, steps: 0, walk: 0),
        now: today,
      );
      expect(log.entries, hasLength(1));
      expect(log.forDay(checkInDayOf(today))!.hasNeat, isTrue);
    });

    test('il giro completo su JSON conserva i valori', () {
      final log = const CheckInLog.empty()
          .upsert(
            entryOn(today, sleep: 7.5, energy: 2, steps: 8437, walk: 45),
            now: today,
          )
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
      expect(decoded.forDay(checkInDayOf(today))!.steps, 8437);
      expect(decoded.forDay(checkInDayOf(today))!.walkMinutes, 45);
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
