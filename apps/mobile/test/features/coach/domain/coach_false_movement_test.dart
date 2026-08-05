import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/body/domain/body_models.dart';
import 'package:kal_tracker/features/coach/domain/coach_false_movement.dart';
import 'package:kal_tracker/features/coach/domain/coach_snapshot.dart';

import '../fixtures.dart';

CoachAverages averagesOf(List<BodyMeasurement> weighIns, DateTime lastDay) =>
    CoachAverages.of(weighIns, testWeekEndingOn(lastDay));

void main() {
  setUp(AppTime.initialize);

  final saturday = DateTime.utc(2026, 8, 1);
  final sunday = DateTime.utc(2026, 8, 2);

  group('il movimento falso', () {
    test('meno 700 g col trend fermo è acqua, e lo si dice', () {
      final weighIns = [
        weighIn(saturday, weightKg: 95.5),
        weighIn(sunday, weightKg: 94.8),
      ];

      final movement = CoachFalseMovement.detect(
        weighIns: weighIns,
        current: averagesOf(weighIns, sunday),
        previous: averagesOf([
          weighIn(DateTime.utc(2026, 7, 25), weightKg: 95.2),
          weighIn(DateTime.utc(2026, 7, 26), weightKg: 95.2),
        ], DateTime.utc(2026, 7, 26)),
        water: const [],
      );

      expect(movement.kind, WeightMoveKind.falseDrop);
      expect(movement.isFalse, isTrue);
      expect(movement.explanation, contains('−0,7 kg'));
      expect(movement.explanation, contains('acqua, non grasso'));
    });

    test('la bevuta del giorno prima entra nella spiegazione', () {
      final weighIns = [
        weighIn(saturday, weightKg: 95.5),
        weighIn(sunday, weightKg: 94.8),
      ];

      final movement = CoachFalseMovement.detect(
        weighIns: weighIns,
        current: averagesOf(weighIns, sunday),
        previous: averagesOf([
          weighIn(DateTime.utc(2026, 7, 26), weightKg: 95.2),
        ], DateTime.utc(2026, 7, 26)),
        water: [
          CoachWaterDay(day: saturday, milliliters: 1100),
          CoachWaterDay(day: DateTime.utc(2026, 7, 31), milliliters: 2500),
          CoachWaterDay(day: DateTime.utc(2026, 7, 30), milliliters: 2500),
        ],
      );

      expect(movement.waterMlYesterday, 1100);
      expect(movement.explanation, contains('1,1 L'));
      expect(movement.explanation, contains('meno del tuo solito'));
    });

    test('un aumento falso si spiega come il calo falso', () {
      final weighIns = [
        weighIn(saturday, weightKg: 94.8),
        weighIn(sunday, weightKg: 95.6),
      ];

      final movement = CoachFalseMovement.detect(
        weighIns: weighIns,
        current: averagesOf(weighIns, sunday),
        previous: averagesOf([
          weighIn(DateTime.utc(2026, 7, 26), weightKg: 95.2),
        ], DateTime.utc(2026, 7, 26)),
        water: const [],
      );

      expect(movement.kind, WeightMoveKind.falseGain);
      expect(movement.explanation, contains('aumento è acqua'));
    });
  });

  group('il movimento vero', () {
    test('se la tendenza segue, non c\'è niente da spiegare', () {
      final weighIns = [
        weighIn(saturday, weightKg: 95.4),
        weighIn(sunday, weightKg: 94.8),
      ];

      final movement = CoachFalseMovement.detect(
        weighIns: weighIns,
        current: averagesOf(weighIns, sunday),
        previous: averagesOf([
          weighIn(DateTime.utc(2026, 7, 26), weightKg: 96),
        ], DateTime.utc(2026, 7, 26)),
        water: const [],
      );

      expect(movement.kind, WeightMoveKind.real);
      expect(movement.explanation, isNull);
    });

    test('due etti non sono un movimento da commentare', () {
      final weighIns = [
        weighIn(saturday, weightKg: 95),
        weighIn(sunday, weightKg: 94.8),
      ];

      final movement = CoachFalseMovement.detect(
        weighIns: weighIns,
        current: averagesOf(weighIns, sunday),
        previous: averagesOf([
          weighIn(DateTime.utc(2026, 7, 26), weightKg: 95),
        ], DateTime.utc(2026, 7, 26)),
        water: const [],
      );

      expect(movement.kind, WeightMoveKind.real);
      expect(movement.explanation, isNull);
    });
  });

  group('senza dati', () {
    test('una sola pesata non si confronta con niente', () {
      final weighIns = [weighIn(sunday, weightKg: 95)];

      final movement = CoachFalseMovement.detect(
        weighIns: weighIns,
        current: averagesOf(weighIns, sunday),
        previous: CoachAverages.of(const [], testWeek.previous),
        water: const [],
      );

      expect(movement.kind, WeightMoveKind.unknown);
      expect(movement.explanation, isNull);
    });

    test('due pesate a una settimana di distanza non sono "ieri e oggi"', () {
      final weighIns = [
        weighIn(DateTime.utc(2026, 7, 27), weightKg: 96),
        weighIn(sunday, weightKg: 95),
      ];

      final movement = CoachFalseMovement.detect(
        weighIns: weighIns,
        current: averagesOf(weighIns, sunday),
        previous: CoachAverages.of(const [], testWeek.previous),
        water: const [],
      );

      expect(movement.kind, WeightMoveKind.unknown);
    });
  });
}
