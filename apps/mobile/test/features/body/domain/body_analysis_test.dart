import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/body/domain/body_analysis.dart';
import 'package:kal_tracker/features/body/domain/body_models.dart';

/// Una pesata a un'ora romana comoda (le 8 del mattino), così i test
/// ragionano in giorni di calendario come la schermata.
BodyMeasurement measurement({
  required DateTime day,
  required double weightKg,
  double? bodyFatPct,
  int hour = 8,
  int minute = 0,
  String? id,
  Map<String, double> circumferences = const {},
}) {
  final at = AppTime.fromRomeLocal(
    DateTime(day.year, day.month, day.day, hour, minute),
  );
  return BodyMeasurement(
    id: id ?? 'm-${at.toIso8601String()}-$weightKg',
    measuredAt: at,
    weightKg: weightKg,
    hasImpedance: bodyFatPct != null,
    bodyFatPct: bodyFatPct,
    circumferences: circumferences,
  );
}

void main() {
  setUp(AppTime.initialize);

  final today = DateTime(2026, 8, 5);

  group('media del giorno', () {
    test('più pesate nello stesso giorno diventano un punto solo', () {
      final points = BodyAnalysis.collapseDays([
        measurement(day: DateTime(2026, 8, 1), weightKg: 94.0, hour: 7),
        measurement(day: DateTime(2026, 8, 1), weightKg: 95.0, hour: 8),
        measurement(day: DateTime(2026, 8, 2), weightKg: 96.0),
      ]);

      expect(points, hasLength(2));
      expect(points.first.weightKg, closeTo(94.5, 0.001));
      expect(points.first.readings, 2);
      expect(points.last.weightKg, closeTo(96, 0.001));
    });

    test('la pesata di mezzanotte resta nel giorno romano, non in quello '
        'UTC', () {
      // Le 00:30 di Roma sono le 22:30 del giorno prima in UTC: leggerla
      // come UTC sposterebbe la pesata al giorno sbagliato.
      final points = BodyAnalysis.collapseDays([
        measurement(
          day: DateTime(2026, 8, 2),
          weightKg: 94,
          hour: 0,
          minute: 30,
        ),
      ]);

      expect(points.single.day, DateTime.utc(2026, 8, 2));
    });

    test('grassa e magra si mediano solo sulle letture che le portano, e la '
        'loro somma resta il peso di quelle letture', () {
      final points = BodyAnalysis.collapseDays([
        // Senza impedenza: entra nel peso, non nella composizione.
        measurement(day: DateTime(2026, 8, 1), weightKg: 90, hour: 7),
        measurement(
          day: DateTime(2026, 8, 1),
          weightKg: 100,
          bodyFatPct: 20,
          hour: 8,
        ),
      ]);

      final point = points.single;
      expect(point.weightKg, closeTo(95, 0.001));
      expect(point.readings, 2);
      expect(point.compositionReadings, 1);
      expect(point.fatMassKg, closeTo(20, 0.001));
      expect(point.leanMassKg, closeTo(80, 0.001));
      // La pila del grafico è internamente coerente: 20 + 80 = 100, il peso
      // della lettura con impedenza, non i 95 della media del giorno.
      expect(point.compositionWeightKg, closeTo(100, 0.001));
    });
  });

  group('media mobile a 7 giorni', () {
    test('la finestra è di calendario e un giorno vale un voto, anche se ci '
        'si è pesati quattro volte', () {
      final days = BodyAnalysis.collapseDays([
        for (var index = 0; index < 4; index++)
          measurement(
            day: DateTime(2026, 8, 1),
            weightKg: 100,
            hour: 7 + index,
            id: 'primo-$index',
          ),
        measurement(day: DateTime(2026, 8, 2), weightKg: 90),
      ]);
      final smoothed = BodyAnalysis.smooth(days);

      // Se le letture pesassero una a una, la media sarebbe 98: le quattro
      // salite del primo giorno schiaccerebbero il secondo.
      expect(smoothed.last.weightKg, closeTo(95, 0.001));
      expect(smoothed.last.weightDays, 2);
    });

    test('dopo una pausa più lunga della finestra la media riparte, non '
        'finge continuità', () {
      final days = BodyAnalysis.collapseDays([
        measurement(day: DateTime(2026, 7, 1), weightKg: 100),
        measurement(day: DateTime(2026, 7, 20), weightKg: 90),
      ]);
      final smoothed = BodyAnalysis.smooth(days);

      expect(smoothed.last.weightKg, closeTo(90, 0.001));
      expect(smoothed.last.weightDays, 1);
    });

    test('la media mobile smorza il rumore della BIA', () {
      // Grasso che oscilla di ±1 punto attorno al 20% a peso fermo.
      final noisy = [
        for (var index = 0; index < 7; index++)
          measurement(
            day: DateTime(2026, 8, 1).add(Duration(days: index)),
            weightKg: 100,
            bodyFatPct: index.isEven ? 21 : 19,
          ),
      ];
      final smoothed = BodyAnalysis.smooth(BodyAnalysis.collapseDays(noisy));

      // L'ultimo giorno grezzo direbbe 21 kg di grasso; la media a 7 giorni
      // dice 20,1 e non si fa trascinare.
      expect(smoothed.last.fatMassKg, closeTo(20.14, 0.01));
      expect(smoothed.last.compositionDays, 7);
    });
  });

  group('variazioni', () {
    test('confronta con la media di una settimana prima e dichiara la '
        'distanza reale', () {
      final measurements = [
        for (var index = 0; index < 21; index++)
          measurement(
            day: DateTime(2026, 7, 16).add(Duration(days: index)),
            // Cala di 100 g al giorno.
            weightKg: 100 - index * 0.1,
          ),
      ];
      final insights = BodyAnalysis.build(
        measurements: measurements,
        range: BodyRange.quarter,
        now: today,
      );

      expect(insights.weightChange, isNotNull);
      expect(insights.weightChange!.spanDays, 7);
      expect(insights.weightChange!.deltaKg, closeTo(-0.7, 0.001));
    });

    test('con una sola pesata non si inventa nessun confronto', () {
      final insights = BodyAnalysis.build(
        measurements: [measurement(day: DateTime(2026, 8, 4), weightKg: 94)],
        range: BodyRange.quarter,
        now: today,
      );

      expect(insights.weightChange, isNull);
      expect(insights.fatChange, isNull);
      expect(insights.verdict, BodyVerdict.unknown);
    });

    test('due pesate troppo vicine non bastano: le finestre si '
        'sovrappongono quasi tutte', () {
      final insights = BodyAnalysis.build(
        measurements: [
          measurement(day: DateTime(2026, 8, 3), weightKg: 95),
          measurement(day: DateTime(2026, 8, 5), weightKg: 94),
        ],
        range: BodyRange.quarter,
        now: today,
      );

      expect(insights.weightChange, isNull);
    });
  });

  group('verdetto', () {
    BodyVerdict verdictFor(double fat, double lean) => BodyAnalysis.verdictOf(
      fatChange: BodyChange(deltaKg: fat, spanDays: 7),
      leanChange: BodyChange(deltaKg: lean, spanDays: 7),
    );

    test('grasso giù e magra su è ricomposizione', () {
      expect(verdictFor(-1.2, 0.8), BodyVerdict.recomposition);
    });

    test('grasso giù e magra ferma è dimagrimento pulito', () {
      expect(verdictFor(-1.2, 0.1), BodyVerdict.cleanFatLoss);
    });

    test('giù entrambe è dimagrimento e basta', () {
      expect(verdictFor(-1.2, -0.9), BodyVerdict.weightLoss);
    });

    test('sotto la tolleranza non si chiama movimento: è la BIA che '
        'respira', () {
      expect(verdictFor(-0.3, 0.2), BodyVerdict.stable);
    });

    test('grasso su e magra giù non si addolcisce', () {
      expect(verdictFor(0.9, -0.6), BodyVerdict.adverse);
    });

    test('senza composizione il verdetto resta «non so»', () {
      expect(
        BodyAnalysis.verdictOf(
          fatChange: null,
          leanChange: const BodyChange(deltaKg: 1, spanDays: 7),
        ),
        BodyVerdict.unknown,
      );
    });

    test('una ricomposizione vera si riconosce sui dati, non sul peso', () {
      // Il peso non si muove di un grammo in tre settimane: 4 kg di grasso in
      // meno e 4 di magra in più. Guardando la sola linea del peso non sarebbe
      // successo niente.
      final measurements = [
        for (var index = 0; index < 21; index++)
          measurement(
            day: DateTime(2026, 7, 16).add(Duration(days: index)),
            weightKg: 100,
            bodyFatPct: 25 - index * 0.2,
          ),
      ];
      final insights = BodyAnalysis.build(
        measurements: measurements,
        range: BodyRange.quarter,
        now: today,
      );

      expect(insights.weightChange!.deltaKg, closeTo(0, 0.0001));
      expect(insights.fatChange!.deltaKg, lessThan(-1));
      expect(insights.leanChange!.deltaKg, greaterThan(1));
      expect(insights.verdict, BodyVerdict.recomposition);
    });
  });

  group('rumore della BIA', () {
    test(
      'si misura sui giorni con più pesate, dove il corpo era lo stesso',
      () {
        final spread = BodyAnalysis.measureSpread([
          measurement(
            day: DateTime(2026, 8, 1),
            weightKg: 100,
            bodyFatPct: 24.9,
            hour: 8,
          ),
          measurement(
            day: DateTime(2026, 8, 1),
            weightKg: 100,
            bodyFatPct: 25.3,
            hour: 8,
            minute: 5,
          ),
          // Giorno con una sola lettura: non dice niente sul rumore.
          measurement(day: DateTime(2026, 8, 2), weightKg: 100, bodyFatPct: 20),
        ]);

        expect(spread.isMeasured, isTrue);
        expect(spread.dayCount, 1);
        expect(spread.bodyFatPoints, closeTo(0.4, 0.001));
        // Tradotto nell'unità del grafico: 0,4 punti su 100 kg sono 0,4 kg.
        expect(spread.fatMassKg, closeTo(0.4, 0.001));
      },
    );

    test('senza pesate ripetute non si inventa un numero', () {
      final spread = BodyAnalysis.measureSpread([
        measurement(day: DateTime(2026, 8, 1), weightKg: 100, bodyFatPct: 25),
        measurement(day: DateTime(2026, 8, 2), weightKg: 100, bodyFatPct: 20),
      ]);

      expect(spread.isMeasured, isFalse);
      expect(spread.dayCount, 0);
    });
  });

  group('circonferenze', () {
    test(
      'confronta la prima e l’ultima del periodo, con i giorni in mezzo',
      () {
        final trends = BodyAnalysis.circumferenceTrends([
          measurement(
            day: DateTime(2026, 6, 1),
            weightKg: 100,
            circumferences: const {'Vita': 96, 'Braccio': 36},
          ),
          measurement(
            day: DateTime(2026, 7, 31),
            weightKg: 98,
            circumferences: const {'Vita': 93.5},
          ),
        ]);

        final vita = trends.firstWhere((trend) => trend.label == 'Vita');
        expect(vita.latestCm, 93.5);
        expect(vita.deltaCm, closeTo(-2.5, 0.001));
        expect(vita.spanDays, 60);
        expect(vita.samples, 2);

        // Una misura sola non produce un confronto: non c'è niente da
        // confrontare, e mostrare «0,0» sarebbe una bugia.
        final braccio = trends.firstWhere((trend) => trend.label == 'Braccio');
        expect(braccio.deltaCm, isNull);
        expect(braccio.spanDays, isNull);
        // E con due punti non si disegna nemmeno: sarebbe una retta.
        expect(vita.isDrawable, isFalse);
        expect(vita.series.map((sample) => sample.$2), [96, 93.5]);
      },
    );

    test('due misure a pochi giorni non si confrontano: è come si tiene il '
        'metro', () {
      final trends = BodyAnalysis.circumferenceTrends([
        measurement(
          day: DateTime(2026, 8, 1),
          weightKg: 100,
          circumferences: const {'Vita': 96},
        ),
        measurement(
          day: DateTime(2026, 8, 4),
          weightKg: 100,
          circumferences: const {'Vita': 94},
        ),
      ]);

      expect(trends.single.deltaCm, isNull);
      expect(trends.single.latestCm, 94);
    });
  });

  group('finestra visibile', () {
    test('i punti fuori dal periodo servono alla media ma non si mostrano', () {
      // Quaranta giorni consecutivi che finiscono oggi: la finestra da 30 ne
      // mostra 30 e usa i 10 precedenti solo per riempire le medie.
      final measurements = [
        for (var index = 39; index >= 0; index--)
          measurement(day: today.subtract(Duration(days: index)), weightKg: 95),
      ];
      final insights = BodyAnalysis.build(
        measurements: measurements,
        range: BodyRange.month,
        now: today,
      );

      expect(insights.days.length, 40);
      expect(insights.trend.length, 30);
      expect(insights.trend.first.day, DateTime.utc(2026, 7, 7));
      expect(insights.trend.last.day, DateTime.utc(2026, 8, 5));
      // Il primo punto visibile è già una media piena: i giorni prima del
      // periodo sono serviti da riscaldamento.
      expect(insights.trend.first.weightDays, BodyAnalysis.smoothingDays);
      expect(insights.staleDays, 0);
    });

    test('senza pesate torna il vuoto, non un grafico di zeri', () {
      final insights = BodyAnalysis.build(
        measurements: const [],
        range: BodyRange.quarter,
        now: today,
      );

      expect(insights.isEmpty, isTrue);
      expect(insights.latest, isNull);
      expect(insights.hasCompositionSeries, isFalse);
      expect(insights.verdict, BodyVerdict.unknown);
    });
  });
}
