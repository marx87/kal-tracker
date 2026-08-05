import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/coach/domain/coach_week.dart';

void main() {
  setUp(AppTime.initialize);

  group('la settimana del rapporto', () {
    test('di mercoledì si parla ancora della domenica appena passata', () {
      // 5 agosto 2026 è un mercoledì.
      final week = CoachWeek.lastSunday(DateTime.utc(2026, 8, 5, 9));

      expect(week.end, DateTime.utc(2026, 8, 2));
      expect(week.start, DateTime.utc(2026, 7, 27));
    });

    test('di domenica il rapporto è di oggi', () {
      final week = CoachWeek.lastSunday(DateTime.utc(2026, 8, 2, 20));

      expect(week.end, DateTime.utc(2026, 8, 2));
    });

    test('di lunedì mattina si legge la settimana appena finita', () {
      final week = CoachWeek.lastSunday(DateTime.utc(2026, 8, 3, 6));

      expect(week.end, DateTime.utc(2026, 8, 2));
    });

    test(
      'la settimana precedente è i sette giorni prima, senza sovrapporsi',
      () {
        final week = CoachWeek(end: DateTime.utc(2026, 8, 2));
        final previous = week.previous;

        expect(previous.end, DateTime.utc(2026, 7, 26));
        expect(previous.start, DateTime.utc(2026, 7, 20));
        expect(previous.end.isBefore(week.start), isTrue);
        expect(week.weeksBefore(week), 0);
        expect(previous.weeksBefore(week), 1);
      },
    );

    test('gli estremi sono inclusi, il giorno fuori no', () {
      final week = CoachWeek(end: DateTime.utc(2026, 8, 2));

      expect(week.containsDay(DateTime.utc(2026, 7, 27)), isTrue);
      expect(week.containsDay(DateTime.utc(2026, 8, 2)), isTrue);
      expect(week.containsDay(DateTime.utc(2026, 7, 26)), isFalse);
      expect(week.containsDay(DateTime.utc(2026, 8, 3)), isFalse);
    });

    test('un istante entra nella settimana col suo giorno ROMANO', () {
      final week = CoachWeek(end: DateTime.utc(2026, 8, 2));

      // Le 23:30 UTC del 2 agosto sono già l'1:30 del 3 a Roma: fuori.
      expect(week.contains(DateTime.utc(2026, 8, 2, 23, 30)), isFalse);
      // Le 22:00 UTC del 26 luglio sono la mezzanotte del 27 a Roma: dentro.
      expect(week.contains(DateTime.utc(2026, 7, 26, 22, 30)), isTrue);
    });
  });
}
