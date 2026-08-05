import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/goal/domain/body_state.dart';

import '../marco.dart';

final DateTime _now = DateTime.utc(2026, 8, 5, 7);

WeightPoint point(int daysAgo, double kg, {double? bodyFatPct}) => WeightPoint(
  at: _now.subtract(Duration(days: daysAgo)),
  weightKg: kg,
  bodyFatPct: bodyFatPct,
);

void main() {
  setUp(AppTime.initialize);

  group('massa magra', () {
    test('si calcola dalla pesata che aveva davvero la composizione', () {
      final points = [
        point(0, 95.5),
        point(2, 95.8, bodyFatPct: 25),
        point(9, 96.4, bodyFatPct: 26),
      ];

      final chosen = BodyStateMath.latestWithComposition(points);

      expect(chosen?.weightKg, 95.8);
      expect(BodyStateMath.fatFreeMassOf(chosen), closeTo(95.8 * 0.75, 0.0001));
    });

    test('senza nessuna pesata completa non si inventa niente', () {
      expect(
        BodyStateMath.latestWithComposition([point(0, 95.5), point(3, 96)]),
        isNull,
      );
      expect(BodyStateMath.fatFreeMassOf(null), isNull);
    });

    test('lo stato vuoto è uno stato valido', () {
      const state = BodyState.unknown();

      expect(state.hasWeight, isFalse);
      expect(state.hasComposition, isFalse);
      expect(state.weightKg, isNull);
    });
  });

  group('media a 7 giorni', () {
    test('prende solo le pesate dentro la finestra', () {
      final average = BodyStateMath.averageWithinDays(
        points: [point(0, 95), point(3, 96), point(20, 100)],
        now: _now,
      );

      expect(average, closeTo(95.5, 0.0001));
    });

    test('senza pesate recenti non c\'è media, e non è zero', () {
      expect(
        BodyStateMath.averageWithinDays(points: [point(30, 95)], now: _now),
        isNull,
      );
    });
  });

  group('finestra per il TDEE misurato', () {
    List<WeightPoint> series() => [
      for (var day = 0; day <= 21; day++) point(day, 95.5 + day * 0.05),
    ];

    Map<String, double> kcal(int days, {double value = 2200}) => {
      for (var day = 0; day < days; day++)
        AppTime.romeDateString(_now.subtract(Duration(days: day))): value,
    };

    test('con tre settimane di pesate e di diario esce un campione', () {
      final sample = BodyStateMath.buildSample(
        points: series(),
        dailyKcal: kcal(22),
        dayKeyOf: AppTime.romeDateString,
      );

      expect(sample, isNotNull);
      expect(sample!.days, 21);
      expect(sample.averageDailyKcal, closeTo(2200, 0.01));
      // Le pesate salgono di 50 g al giorno: da 95,5 a 96,55. Gli estremi
      // sono mediati su tre giorni, quindi il salto misurato è poco meno.
      expect(sample.weightChangeKg, closeTo(-0.9, 0.05));
      expect(sample.isUsable, isTrue);
    });

    test('sotto le due settimane non si misura niente', () {
      final sample = BodyStateMath.buildSample(
        points: [for (var day = 0; day <= 10; day++) point(day, 95.5)],
        dailyKcal: kcal(11),
        dayKeyOf: AppTime.romeDateString,
      );

      expect(sample, isNull);
    });

    test('i giorni senza diario non valgono zero calorie: si escludono', () {
      // Solo 8 giorni di diario su tre settimane: troppo pochi. Contarli
      // come digiuni farebbe sembrare il consumo enorme.
      final sample = BodyStateMath.buildSample(
        points: series(),
        dailyKcal: kcal(8),
        dayKeyOf: AppTime.romeDateString,
      );

      expect(sample, isNull);
    });

    test('la media delle calorie non viene diluita dai giorni mancanti', () {
      final withHoles = <String, double>{
        ...kcal(22),
        AppTime.romeDateString(_now.subtract(const Duration(days: 5))): 0,
      };

      final sample = BodyStateMath.buildSample(
        points: series(),
        dailyKcal: withHoles,
        dayKeyOf: AppTime.romeDateString,
      );

      expect(sample!.averageDailyKcal, closeTo(2200, 0.01));
    });

    test('con una sola pesata non c\'è nessuna finestra', () {
      expect(
        BodyStateMath.buildSample(
          points: [point(0, marcoWeight)],
          dailyKcal: kcal(30),
          dayKeyOf: AppTime.romeDateString,
        ),
        isNull,
      );
    });
  });
}
