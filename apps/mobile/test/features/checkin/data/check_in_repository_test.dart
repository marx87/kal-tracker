import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/checkin/data/check_in_repository.dart';
import 'package:kal_tracker/features/checkin/data/check_in_store.dart';
import 'package:kal_tracker/features/checkin/domain/daily_check_in.dart';

void main() {
  setUp(AppTime.initialize);

  final day = DateTime.utc(2026, 8, 5, 7);

  test(
    'sonno ed energia si scrivono uno alla volta senza cancellarsi',
    () async {
      final repository = CheckInRepository(InMemoryCheckInStore());

      await repository.save(day: day, sleepHours: 7.5);
      final afterEnergy = await repository.save(day: day, energyScore: 4);

      final entry = afterEnergy.forDay(checkInDayOf(day))!;
      expect(entry.sleepHours, 7.5);
      expect(entry.energyScore, 4);
      expect(entry.isComplete, isTrue);
    },
  );

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
