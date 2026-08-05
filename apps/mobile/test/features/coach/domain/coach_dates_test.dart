import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/coach/domain/coach_dates.dart';

void main() {
  group('le date in italiano', () {
    test('il giorno si scrive senza zeri davanti', () {
      expect(coachDayLabel(DateTime.utc(2026, 12, 2)), '2 dicembre');
      expect(coachDayLabel(DateTime.utc(2026, 1, 31)), '31 gennaio');
    });

    test('la domenica si chiama domenica', () {
      expect(coachWeekdayLabel(DateTime.utc(2026, 8, 2)), 'domenica 2 agosto');
    });

    test('l\'anno compare solo dove serve', () {
      expect(coachFullDayLabel(DateTime.utc(2027, 3, 8)), '8 marzo 2027');
    });
  });

  group('i plurali', () {
    test('una settimana è singolare, due no', () {
      expect(coachWeeksLabel(1), '1 settimana');
      expect(coachWeeksLabel(2), '2 settimane');
      // Il segno non deve arrivare nella frase: «−2 settimane prima» sarebbe
      // una doppia negazione.
      expect(coachWeeksLabel(-2), '2 settimane');
    });

    test('un giorno è singolare, zero no', () {
      expect(coachDaysLabel(1), '1 giorno');
      expect(coachDaysLabel(0), '0 giorni');
    });
  });

  group('i numeri', () {
    test('la virgola è quella italiana', () {
      expect(coachNumber(87.42), '87,4');
      expect(coachNumber(87.42, decimals: 2), '87,42');
    });

    test('le variazioni portano sempre il segno', () {
      expect(coachSignedNumber(0.3), '+0,3');
      expect(coachSignedNumber(-0.7), '−0,7');
    });

    test('lo zero non ha segno, e nemmeno il quasi-zero arrotondato', () {
      expect(coachSignedNumber(0), '0,0');
      expect(coachSignedNumber(-0.04), '0,0');
    });

    test('il meno è il segno tipografico, non il trattino', () {
      // A corpo piccolo un trattino sparisce e «-0,7» si legge «0,7».
      expect(coachSignedNumber(-0.7).codeUnitAt(0), 0x2212);
    });
  });
}
