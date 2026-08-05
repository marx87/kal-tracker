import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/coach/domain/coach_projection.dart';

final DateTime sunday = DateTime.utc(2026, 8, 2);

GoalProjection project({
  double targetWeightKg = 87,
  double? currentAverageKg = 95,
  double? observedKgPerWeek = -0.5,
  int weeksObserved = 4,
  DateTime? plannedDate,
}) => CoachProjection.project(
  targetWeightKg: targetWeightKg,
  currentAverageKg: currentAverageKg,
  observedKgPerWeek: observedKgPerWeek,
  weeksObserved: weeksObserved,
  today: sunday,
  plannedKgPerWeek: 0.5,
  plannedDate: plannedDate,
);

void main() {
  group('il ritmo osservato', () {
    test('è la differenza fra due medie, divisa per le settimane', () {
      final rate = CoachProjection.rateKgPerWeek(
        currentAverageKg: 94,
        olderAverageKg: 96,
        weeks: 4,
      );

      expect(rate, closeTo(-0.5, 0.001));
    });

    test('senza una delle due medie non esiste', () {
      expect(
        CoachProjection.rateKgPerWeek(
          currentAverageKg: 94,
          olderAverageKg: null,
          weeks: 4,
        ),
        isNull,
      );
    });
  });

  group('la proiezione', () {
    test('otto chili a mezzo chilo a settimana fanno sedici settimane', () {
      final projection = project();

      expect(projection.state, ProjectionState.moving);
      expect(projection.projectedDate, sunday.add(const Duration(days: 112)));
      expect(projection.headline, contains('87,0 kg'));
      expect(projection.headline, contains('novembre'));
    });

    test('il ritardo si dice in settimane, non in colpe', () {
      final projection = project(
        plannedDate: sunday.add(const Duration(days: 98)),
      );

      expect(projection.weeksLate, 2);
      expect(projection.headline, contains('2 settimane dopo il previsto'));
      expect(projection.headline, isNot(contains('doves')));
    });

    test('arrivare prima si dice altrettanto', () {
      final projection = project(
        observedKgPerWeek: -1,
        plannedDate: sunday.add(const Duration(days: 112)),
      );

      expect(projection.weeksLate, -8);
      expect(projection.headline, contains('prima del previsto'));
    });

    test('in linea con il previsto non è né merito né colpa', () {
      final projection = project(
        plannedDate: sunday.add(const Duration(days: 112)),
      );

      expect(projection.weeksLate, 0);
      expect(projection.headline, contains('in linea con il previsto'));
    });

    test('un peso fermo non produce una data', () {
      final projection = project(observedKgPerWeek: 0);

      expect(projection.state, ProjectionState.stalled);
      expect(projection.projectedDate, isNull);
      expect(projection.headline, contains('non è scesa'));
    });

    test('salire mentre si vuole scendere non allunga la data: la toglie', () {
      final projection = project(observedKgPerWeek: 0.4);

      expect(projection.state, ProjectionState.stalled);
      expect(projection.projectedDate, isNull);
    });

    test('un ritmo lentissimo non promette una data fra dieci anni', () {
      final projection = project(observedKgPerWeek: -0.02);

      expect(projection.state, ProjectionState.stalled);
    });

    test('dentro la tolleranza si è arrivati', () {
      final projection = project(currentAverageKg: 87.2);

      expect(projection.state, ProjectionState.arrived);
      expect(projection.headline, contains('Ci sei'));
    });

    test('senza pesate non si sa a che ritmo si va', () {
      final projection = project(currentAverageKg: null);

      expect(projection.state, ProjectionState.unknown);
      expect(projection.headline, contains('abbastanza pesate'));
    });

    test('anche in salita la proiezione funziona', () {
      final projection = project(
        targetWeightKg: 98,
        currentAverageKg: 95,
        observedKgPerWeek: 0.25,
      );

      expect(projection.state, ProjectionState.moving);
      expect(projection.remainingKg, closeTo(-3, 0.001));
      expect(projection.projectedDate, sunday.add(const Duration(days: 84)));
    });
  });
}
