import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/checkin/data/check_in_repository.dart';
import 'package:kal_tracker/features/checkin/data/check_in_store.dart';
import 'package:kal_tracker/features/checkin/domain/daily_check_in.dart';

void main() {
  setUp(AppTime.initialize);

  final day = DateTime.utc(2026, 8, 5, 7);

  test('i campi si scrivono uno alla volta senza cancellarsi', () async {
    final repository = CheckInRepository(InMemoryCheckInStore());

    await repository.save(day: day, sleepHours: 7.5);
    await repository.save(day: day, energyScore: 4);
    await repository.save(day: day, steps: 8000);
    final log = await repository.save(day: day, walkMinutes: 40);

    final entry = log.forDay(checkInDayOf(day))!;
    expect(entry.sleepHours, 7.5);
    expect(entry.energyScore, 4);
    expect(entry.steps, 8000);
    expect(entry.walkMinutes, 40);
    expect(entry.isFullyLogged, isTrue);
  });

  test('senza il movimento il check-in non è ancora tutto', () async {
    final repository = CheckInRepository(InMemoryCheckInStore());

    final log = await repository.save(
      day: day,
      sleepHours: 7.5,
      energyScore: 4,
    );

    // Sonno ed energia si chiudono da soli, ma il giorno non è finito: senza
    // questa distinzione la card sparirebbe prima di chiedere i passi, e il
    // campo che serve ad accorgersi del crollo del NEAT resterebbe vuoto
    // proprio nei giorni in cui il crollo c'è stato.
    final entry = log.forDay(checkInDayOf(day))!;
    expect(entry.isComplete, isTrue);
    expect(entry.isFullyLogged, isFalse);
    expect(entry.hasNeat, isFalse);
  });

  test('lo zero è una risposta, non un campo vuoto', () async {
    final repository = CheckInRepository(InMemoryCheckInStore());
    await repository.save(day: day, steps: 9000, walkMinutes: 50);

    final log = await repository.save(day: day, steps: 0, walkMinutes: 0);

    // Senza questo, «oggi fermo» erediterebbe i novemila di prima: `0` non è
    // `null`, e la giornata ferma deve poter sovrascrivere.
    final entry = log.forDay(checkInDayOf(day))!;
    expect(entry.steps, 0);
    expect(entry.walkMinutes, 0);
    expect(entry.hasNeat, isTrue);
    expect(entry.isEmpty, isFalse);
  });

  test('il movimento si può togliere senza toccare il resto', () async {
    final repository = CheckInRepository(InMemoryCheckInStore());
    await repository.save(
      day: day,
      sleepHours: 7,
      steps: 8000,
      walkMinutes: 40,
    );

    final log = await repository.save(
      day: day,
      clearSteps: true,
      clearWalkMinutes: true,
    );

    final entry = log.forDay(checkInDayOf(day))!;
    expect(entry.steps, isNull);
    expect(entry.walkMinutes, isNull);
    expect(entry.sleepHours, 7);
  });

  test('i passi fuori scala vengono riportati dentro', () async {
    final repository = CheckInRepository(InMemoryCheckInStore());

    final log = await repository.save(
      day: day,
      steps: 999999,
      walkMinutes: -30,
    );

    final entry = log.forDay(checkInDayOf(day))!;
    expect(entry.steps, DailyCheckIn.maxSteps);
    expect(entry.walkMinutes, 0);
  });

  test(
    'i valori fuori scala vengono riportati dentro, non rifiutati',
    () async {
      final repository = CheckInRepository(InMemoryCheckInStore());

      final log = await repository.save(
        day: day,
        sleepHours: 99,
        energyScore: 9,
      );

      final entry = log.forDay(checkInDayOf(day))!;
      expect(entry.sleepHours, DailyCheckIn.maxSleepHours);
      expect(entry.energyScore, 5);
    },
  );

  test('si può togliere un valore già inserito', () async {
    final repository = CheckInRepository(InMemoryCheckInStore());
    await repository.save(day: day, sleepHours: 7, energyScore: 3);

    final log = await repository.save(day: day, clearSleep: true);

    final entry = log.forDay(checkInDayOf(day))!;
    expect(entry.sleepHours, isNull);
    expect(entry.energyScore, 3);
  });

  test('quello che si scrive si rilegge dallo store', () async {
    final store = InMemoryCheckInStore();
    await CheckInRepository(store).save(day: day, sleepHours: 6.5);

    final reread = await CheckInRepository(store).read();

    expect(reread.forDay(checkInDayOf(day))!.sleepHours, 6.5);
  });

  test('cancellare un giorno lo toglie dallo storico', () async {
    final store = InMemoryCheckInStore();
    final repository = CheckInRepository(store);
    await repository.save(day: day, sleepHours: 7, energyScore: 3);

    final log = await repository.clearDay(day);

    expect(log.entries, isEmpty);
    expect((await store.read()).entries, isEmpty);
  });
}
