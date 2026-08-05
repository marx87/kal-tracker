import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/coach/domain/coach_adherence.dart';
import 'package:kal_tracker/features/coach/domain/coach_overtraining.dart';
import 'package:kal_tracker/features/coach/domain/coach_snapshot.dart';

import '../fixtures.dart';

const proteinOk = AdherenceLine(
  label: 'Proteine',
  grade: AdherenceGrade.onTrack,
  planned: 143,
  actual: 145,
  daysCounted: 7,
  daysExpected: 7,
);

const proteinLow = AdherenceLine(
  label: 'Proteine',
  grade: AdherenceGrade.off,
  planned: 143,
  actual: 100,
  daysCounted: 7,
  daysExpected: 7,
);

const proteinUnknown = AdherenceLine.unknown(
  label: 'Proteine',
  daysCounted: 2,
  daysExpected: 7,
);

CoachAverages week({
  required DateTime lastDay,
  required double weightKg,
  double? waterPct,
  int days = 3,
}) => CoachAverages.of(
  weighInSeries(
    lastDay: lastDay,
    weights: List.filled(days, weightKg),
    bodyFatPcts: List.filled(days, 25),
    waterPcts: waterPct == null ? null : List.filled(days, waterPct),
  ),
  testWeekEndingOn(lastDay),
);

void main() {
  setUp(AppTime.initialize);

  final thisWeek = DateTime.utc(2026, 8, 2);
  final lastWeek = DateTime.utc(2026, 7, 26);

  group('con tutti e quattro i segnali', () {
    test('tre accesi accendono lo scarico', () {
      final light = CoachOvertraining.assess(
        currentSessions: [
          session(DateTime.utc(2026, 7, 28), rpe: 9),
          session(DateTime.utc(2026, 7, 30), rpe: 9),
        ],
        previousSessions: [
          session(DateTime.utc(2026, 7, 21), rpe: 7),
          session(DateTime.utc(2026, 7, 23), rpe: 7),
        ],
        // 95,5 → 94,5: un chilo, oltre lo 0,7 % del peso.
        currentAverages: week(lastDay: thisWeek, weightKg: 94.5, waterPct: 54),
        previousAverages: week(lastDay: lastWeek, weightKg: 95.5, waterPct: 54),
        proteinLine: proteinLow,
      );

      expect(light.firedCount, 3);
      expect(light.level, OvertrainingLevel.deload);
      expect(light.headline, contains('scarico'));
      expect(light.reasons, hasLength(3));
      expect(light.missingDataNote, isNull);
    });

    test('due accesi sono da guardare, non da fermare', () {
      final light = CoachOvertraining.assess(
        currentSessions: [
          session(DateTime.utc(2026, 7, 28), rpe: 9),
          session(DateTime.utc(2026, 7, 30), rpe: 9),
        ],
        previousSessions: [
          session(DateTime.utc(2026, 7, 21), rpe: 7),
          session(DateTime.utc(2026, 7, 23), rpe: 7),
        ],
        currentAverages: week(lastDay: thisWeek, weightKg: 94.5, waterPct: 54),
        previousAverages: week(lastDay: lastWeek, weightKg: 95.5, waterPct: 54),
        proteinLine: proteinOk,
      );

      expect(light.firedCount, 2);
      expect(light.level, OvertrainingLevel.watch);
    });

    test('una settimana normale non accende niente', () {
      final light = CoachOvertraining.assess(
        currentSessions: [
          session(DateTime.utc(2026, 7, 28), rpe: 7),
          session(DateTime.utc(2026, 7, 30), rpe: 7),
        ],
        previousSessions: [
          session(DateTime.utc(2026, 7, 21), rpe: 7),
          session(DateTime.utc(2026, 7, 23), rpe: 7),
        ],
        currentAverages: week(lastDay: thisWeek, weightKg: 95.1, waterPct: 54),
        previousAverages: week(lastDay: lastWeek, weightKg: 95.5, waterPct: 54),
        proteinLine: proteinOk,
      );

      expect(light.level, OvertrainingLevel.clear);
      expect(light.knownCount, 4);
      expect(light.headline, contains('Nessun segnale'));
    });
  });

  group('con i buchi — il caso normale nei dati veri', () {
    test('l\'RPE mancante è "non lo so", non "va tutto bene"', () {
      final light = CoachOvertraining.assess(
        currentSessions: [session(DateTime.utc(2026, 7, 28))],
        previousSessions: [session(DateTime.utc(2026, 7, 21))],
        currentAverages: week(lastDay: thisWeek, weightKg: 95.1, waterPct: 54),
        previousAverages: week(lastDay: lastWeek, weightKg: 95.5, waterPct: 54),
        proteinLine: proteinOk,
      );

      expect(
        light.readings[OvertrainingSignal.risingEffort],
        SignalReading.unknown,
      );
      expect(light.knownCount, 3);
      expect(light.missingDataNote, contains('sforzo percepito'));
    });

    test('una sola sessione con RPE non fa una media', () {
      final light = CoachOvertraining.assess(
        currentSessions: [session(DateTime.utc(2026, 7, 28), rpe: 10)],
        previousSessions: [session(DateTime.utc(2026, 7, 21), rpe: 5)],
        currentAverages: week(lastDay: thisWeek, weightKg: 95.1),
        previousAverages: week(lastDay: lastWeek, weightKg: 95.5),
        proteinLine: proteinOk,
      );

      expect(
        light.readings[OvertrainingSignal.risingEffort],
        SignalReading.unknown,
      );
    });

    test('due segnali su due accesi bastano a far guardare', () {
      final light = CoachOvertraining.assess(
        currentSessions: const [],
        previousSessions: const [],
        currentAverages: week(lastDay: thisWeek, weightKg: 94.5),
        previousAverages: week(lastDay: lastWeek, weightKg: 95.5),
        proteinLine: proteinLow,
      );

      expect(light.knownCount, 2);
      expect(light.firedCount, 2);
      expect(light.level, OvertrainingLevel.watch);
      expect(light.missingDataNote, contains('acqua corporea'));
    });

    test('senza nessun dato il semaforo lo dice invece di stare verde', () {
      final light = CoachOvertraining.assess(
        currentSessions: const [],
        previousSessions: const [],
        currentAverages: CoachAverages.of(const [], testWeek),
        previousAverages: CoachAverages.of(const [], testWeek.previous),
        proteinLine: proteinUnknown,
      );

      expect(light.knownCount, 0);
      expect(light.level, OvertrainingLevel.clear);
      expect(light.headline, contains('Non ho abbastanza dati'));
    });

    test('una media di due giorni non basta a gridare al calo rapido', () {
      final light = CoachOvertraining.assess(
        currentSessions: const [],
        previousSessions: const [],
        currentAverages: week(lastDay: thisWeek, weightKg: 94.5, days: 2),
        previousAverages: week(lastDay: lastWeek, weightKg: 95.5),
        proteinLine: proteinOk,
      );

      expect(
        light.readings[OvertrainingSignal.fastWeightLoss],
        SignalReading.unknown,
      );
    });
  });

  group('l\'acqua corporea', () {
    test('un punto in meno accende il segnale', () {
      final light = CoachOvertraining.assess(
        currentSessions: const [],
        previousSessions: const [],
        currentAverages: week(lastDay: thisWeek, weightKg: 95.2, waterPct: 53),
        previousAverages: week(lastDay: lastWeek, weightKg: 95.5, waterPct: 54),
        proteinLine: proteinOk,
      );

      expect(
        light.readings[OvertrainingSignal.fallingBodyWater],
        SignalReading.fired,
      );
    });
  });
}
