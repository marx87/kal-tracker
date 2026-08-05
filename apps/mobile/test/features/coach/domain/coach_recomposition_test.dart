import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/coach/domain/coach_recomposition.dart';
import 'package:kal_tracker/features/coach/domain/coach_snapshot.dart';

import '../fixtures.dart';

/// Tre giorni di pesate complete dentro [week], tutte uguali.
CoachAverages averages({
  required DateTime lastDay,
  required double weightKg,
  required double bodyFatPct,
  int days = 3,
}) => CoachAverages.of(
  weighInSeries(
    lastDay: lastDay,
    weights: List.filled(days, weightKg),
    bodyFatPcts: List.filled(days, bodyFatPct),
  ),
  // Una settimana che finisce nell'ultimo giorno: serve solo a contenerli.
  testWeekEndingOn(lastDay),
);

void main() {
  setUp(AppTime.initialize);

  group('la massa magra', () {
    test('mezzo etto in meno è la BIA che respira, non un calo', () {
      final result = CoachRecomposition.assess(
        current: averages(
          lastDay: DateTime.utc(2026, 8, 2),
          weightKg: 95,
          bodyFatPct: 24.5,
        ),
        previous: averages(
          lastDay: DateTime.utc(2026, 7, 26),
          weightKg: 95.3,
          bodyFatPct: 24.7,
        ),
      );

      expect(result.leanTrend, LeanMassTrend.holding);
      expect(result.leanChangeKg!.abs(), lessThan(CoachRecomposition.noiseKg));
    });

    test('un chilo di magra in meno si chiama con il suo nome', () {
      final result = CoachRecomposition.assess(
        current: averages(
          lastDay: DateTime.utc(2026, 8, 2),
          weightKg: 94,
          bodyFatPct: 25.5,
        ),
        previous: averages(
          lastDay: DateTime.utc(2026, 7, 26),
          weightKg: 95.5,
          bodyFatPct: 25,
        ),
      );

      expect(result.leanTrend, LeanMassTrend.falling);
      expect(result.leanChangeKg, closeTo(-1.595, 0.01));
      expect(result.headline, contains('non è solo grasso'));
      expect(result.isRecomposition, isFalse);
    });

    test('grasso giù e magra tenuta è la combinazione che si cerca', () {
      final result = CoachRecomposition.assess(
        current: averages(
          lastDay: DateTime.utc(2026, 8, 2),
          weightKg: 94.5,
          bodyFatPct: 23.9,
        ),
        previous: averages(
          lastDay: DateTime.utc(2026, 7, 26),
          weightKg: 95.5,
          bodyFatPct: 25,
        ),
      );

      expect(result.leanTrend, LeanMassTrend.holding);
      expect(result.fatChangeKg, lessThan(-CoachRecomposition.noiseKg));
      expect(result.isRecomposition, isTrue);
      expect(result.headline, contains('combinazione che si cerca'));
    });
  });

  group('senza composizione', () {
    test('una sola pesata con impedenza non fa una media', () {
      final current = CoachAverages.of([
        weighIn(DateTime.utc(2026, 8, 2), weightKg: 95, bodyFatPct: 24),
        weighIn(DateTime.utc(2026, 8, 1), weightKg: 95),
      ], testWeekEndingOn(DateTime.utc(2026, 8, 2)));

      final result = CoachRecomposition.assess(
        current: current,
        previous: averages(
          lastDay: DateTime.utc(2026, 7, 26),
          weightKg: 95.5,
          bodyFatPct: 25,
        ),
      );

      expect(result.leanTrend, LeanMassTrend.unknown);
      expect(result.isKnown, isFalse);
      expect(result.headline, contains('impedenza'));
      // Il numero c'è comunque: si dichiara che non basta, non lo si butta.
      expect(result.leanMassNowKg, isNotNull);
    });

    test('senza nulla da confrontare il verdetto è "non lo so"', () {
      const nothing = Recomposition.unknown();

      expect(nothing.leanTrend, LeanMassTrend.unknown);
      expect(nothing.leanChangeKg, isNull);
      expect(nothing.isRecomposition, isFalse);
    });
  });
}
