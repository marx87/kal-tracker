import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/checkin/domain/daily_check_in.dart';
import 'package:kal_tracker/features/checkin/domain/neat_trend.dart';

void main() {
  setUp(AppTime.initialize);

  /// La domenica del rapporto.
  final weekEnd = DateTime.utc(2026, 8, 9);

  /// Uno storico costruito a ritroso dalla domenica: [current] sono i sette
  /// giorni del rapporto, [previous] i sette prima.
  CheckInLog logOf({
    List<int?> current = const [],
    List<int?> previous = const [],
    bool asSteps = true,
  }) {
    final entries = <String, DailyCheckIn>{};
    void write(List<int?> values, int offset) {
      for (var index = 0; index < values.length; index++) {
        final value = values[index];
        if (value == null) {
          continue;
        }
        final day = weekEnd.subtract(Duration(days: offset + index));
        final entry = DailyCheckIn(
          day: day,
          updatedAt: day,
          sleepHours: 7,
          steps: asSteps ? value : null,
          walkMinutes: asSteps ? null : value,
        );
        entries[entry.dayKey] = entry;
      }
    }

    write(current, 0);
    write(previous, 7);
    return CheckInLog(entries);
  }

  group('media della settimana', () {
    test('si fa sui giorni segnati, non su sette', () {
      // Quattro giorni a diecimila fanno diecimila, non 10.000 × 4 / 7: i tre
      // giorni non segnati sono un buco, non tre giorni fermi. Dividere per
      // sette inventerebbe il crollo che questo campo esiste per trovare.
      final trend = CheckInNeat.measure(
        log: logOf(current: [10000, 10000, 10000, 10000]),
        weekEnd: weekEnd,
        measure: NeatMeasure.steps,
      );

      expect(trend.current, 10000);
      expect(trend.currentDays, 4);
    });

    test('sotto i tre giorni non c\'è media, e si dice quanti sono', () {
      final trend = CheckInNeat.measure(
        log: logOf(current: [10000, 4000]),
        weekEnd: weekEnd,
        measure: NeatMeasure.steps,
      );

      expect(trend.isKnown, isFalse);
      expect(trend.currentDays, 2);
      expect(trend.line, contains('2 giorni su 7'));
      expect(trend.line, contains('zeri'));
    });

    test('gli zeri abbassano la media invece di sparire', () {
      final trend = CheckInNeat.measure(
        log: logOf(current: [12000, 0, 0, 0]),
        weekEnd: weekEnd,
        measure: NeatMeasure.steps,
      );

      expect(trend.current, 3000);
      expect(trend.currentDays, 4);
    });

    test('i giorni fuori dalle due settimane non entrano', () {
      final vecchio = weekEnd.subtract(const Duration(days: 20));
      final log = CheckInLog({
        ...logOf(current: [8000, 8000, 8000]).entries,
        DailyCheckIn.dayKeyOf(vecchio): DailyCheckIn(
          day: vecchio,
          updatedAt: vecchio,
          steps: 30000,
        ),
      });

      final trend = CheckInNeat.measure(
        log: log,
        weekEnd: weekEnd,
        measure: NeatMeasure.steps,
      );

      expect(trend.current, 8000);
      expect(trend.currentDays, 3);
    });
  });

  group('confronto con la settimana prima', () {
    test('il crollo si vede e porta con sé la spiegazione', () {
      final trend = CheckInNeat.measure(
        log: logOf(
          current: [4000, 4000, 4000, 4000, 4000],
          previous: [11000, 11000, 11000, 11000, 11000],
        ),
        weekEnd: weekEnd,
        measure: NeatMeasure.steps,
      );

      expect(trend.direction, NeatDirection.down);
      expect(trend.change, closeTo(-0.636, 0.001));
      // È la frase che il consumo misurato non può dire da solo: senza,
      // l'app consiglierebbe di togliere calorie per un calo che è tutto qui.
      expect(trend.line, contains('4.000 passi al giorno'));
      expect(trend.line, contains('11.000 passi della settimana prima'));
      expect(trend.line, contains('prima di togliere calorie'));
    });

    test('una differenza piccola non è una notizia', () {
      final trend = CheckInNeat.measure(
        log: logOf(current: [9000, 9000, 9000], previous: [9800, 9800, 9800]),
        weekEnd: weekEnd,
        measure: NeatMeasure.steps,
      );

      expect(trend.direction, NeatDirection.steady);
      expect(trend.line, contains('Il movimento è lo stesso.'));
    });

    test('pochi minuti in meno non accendono niente, per quanto valgano in '
        'percentuale', () {
      // Da 6 a 4 minuti al giorno è un −33 % che non è una notizia: è un
      // semaforo rosso in più sulla strada di casa.
      final trend = CheckInNeat.measure(
        log: logOf(current: [4, 4, 4], previous: [6, 6, 6], asSteps: false),
        weekEnd: weekEnd,
        measure: NeatMeasure.walkMinutes,
      );

      expect(trend.direction, NeatDirection.steady);
    });

    test('senza la settimana prima si dichiara che manca', () {
      final trend = CheckInNeat.measure(
        log: logOf(current: [9000, 9000, 9000]),
        weekEnd: weekEnd,
        measure: NeatMeasure.steps,
      );

      expect(trend.hasComparison, isFalse);
      expect(trend.direction, NeatDirection.unknown);
      expect(trend.line, contains('non c\'è confronto'));
    });

    test('una settimana prima ferma davvero non dà una percentuale', () {
      final trend = CheckInNeat.measure(
        log: logOf(current: [8000, 8000, 8000], previous: [0, 0, 0]),
        weekEnd: weekEnd,
        measure: NeatMeasure.steps,
      );

      // Dividere per zero darebbe un infinito, non una notizia: resta la
      // direzione, che è l'unica cosa vera.
      expect(trend.change, isNull);
      expect(trend.direction, NeatDirection.up);
    });
  });

  group('la riga del rapporto', () {
    test('senza nemmeno un giorno segnato non c\'è riga', () {
      expect(
        CheckInNeat.weeklyLine(log: const CheckInLog.empty(), weekEnd: weekEnd),
        isNull,
      );
    });

    test('vince la misura con più giorni segnati', () {
      final log = CheckInLog({
        ...logOf(current: [30, 30, 30, 30, 30], asSteps: false).entries,
      });

      // I passi non ci sono affatto: la riga deve parlare dei minuti invece
      // di tacere.
      final line = CheckInNeat.weeklyLine(log: log, weekEnd: weekEnd);
      expect(line, startsWith('A piedi: 30 min al giorno'));
    });

    test('a pari giorni parlano i passi, e una volta sola', () {
      final entries = <String, DailyCheckIn>{};
      for (var index = 0; index < 5; index++) {
        final day = weekEnd.subtract(Duration(days: index));
        entries[DailyCheckIn.dayKeyOf(day)] = DailyCheckIn(
          day: day,
          updatedAt: day,
          steps: 9000,
          walkMinutes: 50,
        );
      }

      final line = CheckInNeat.weeklyLine(
        log: CheckInLog(entries),
        weekEnd: weekEnd,
      );

      // Una riga sola: passi e minuti raccontano la stessa camminata, e due
      // righe darebbero due numeri diversi per lo stesso fatto.
      expect(line, startsWith('Passi: 9.000 passi al giorno'));
      expect(line, isNot(contains('A piedi')));
    });
  });
}
