import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/goal/domain/definition_level.dart';

import '../marco.dart';

/// La curva scritta a mano nella roadmap, arrotondata al chilo.
const Map<DefinitionLevel, double> _roadmapLadder = {
  DefinitionLevel.soft: 95,
  DefinitionLevel.normal: 90,
  DefinitionLevel.lean: 86,
  DefinitionLevel.athletic: 84,
  DefinitionLevel.defined: 80,
  DefinitionLevel.veryDefined: 78,
};

void main() {
  group('la curva di Marco', () {
    test('riproduce la scala della roadmap entro l\'arrotondamento', () {
      for (final entry in _roadmapLadder.entries) {
        final computed = DefinitionCurve.weightFor(
          level: entry.key,
          fatFreeMassKg: marcoFatFreeMass,
        );
        expect(
          computed,
          closeTo(entry.value, 0.8),
          reason:
              '${entry.key.label}: la formula dà $computed, la roadmap '
              'scrive ${entry.value}',
        );
      }
    });

    test('più asciutto vuol dire meno chili, senza eccezioni', () {
      final weights = [
        for (final level in DefinitionLevel.values)
          DefinitionCurve.weightFor(
            level: level,
            fatFreeMassKg: marcoFatFreeMass,
          ),
      ];

      for (var index = 1; index < weights.length; index++) {
        expect(weights[index], lessThan(weights[index - 1]));
      }
    });

    test('peso e definizione sono la stessa scelta: si torna sempre '
        'allo stesso livello', () {
      for (final level in DefinitionLevel.values) {
        final weight = DefinitionCurve.weightFor(
          level: level,
          fatFreeMassKg: marcoFatFreeMass,
        );
        final reading = DefinitionCurve.read(
          weightKg: weight,
          fatFreeMassKg: marcoFatFreeMass,
        );

        expect(reading.level, level);
        expect(reading.isOnScale, isTrue);
      }
    });

    test('con più muscolo lo stesso «definito» pesa di più', () {
      final now = DefinitionCurve.weightFor(
        level: DefinitionLevel.defined,
        fatFreeMassKg: marcoFatFreeMass,
      );
      final afterBulk = DefinitionCurve.weightFor(
        level: DefinitionLevel.defined,
        fatFreeMassKg: marcoFatFreeMass + 4,
      );

      expect(afterBulk, greaterThan(now));
      expect(afterBulk - now, closeTo(4 / 0.89, 0.001));
    });
  });

  group('fuori scala', () {
    test(
      'sotto il livello più asciutto la parola non descrive più il peso',
      () {
        final reading = DefinitionCurve.read(
          weightKg: 75,
          fatFreeMassKg: marcoFatFreeMass,
        );

        expect(reading.position, ScalePosition.leanerThanScale);
        expect(reading.isOnScale, isFalse);
        expect(reading.level, DefinitionLevel.veryDefined);
      },
    );

    test('sopra il livello più morbido vale lo stesso', () {
      final reading = DefinitionCurve.read(
        weightKg: 110,
        fatFreeMassKg: marcoFatFreeMass,
      );

      expect(reading.position, ScalePosition.softerThanScale);
      expect(reading.level, DefinitionLevel.soft);
    });

    test('a metà tra due livelli vince il più vicino', () {
      // 82 kg su 71,66 di massa magra sono il 12,6 %: più vicino ad
      // «atletico» (14) che a «definito» (11).
      final reading = DefinitionCurve.read(
        weightKg: 82,
        fatFreeMassKg: marcoFatFreeMass,
      );

      expect(reading.level, DefinitionLevel.athletic);
      expect(reading.bodyFatPct, closeTo(12.61, 0.01));
    });
  });

  group('escursione della manopola', () {
    test('copre tutta la scala e va oltre da entrambe le parti', () {
      final range = DefinitionCurve.dialRange(marcoFatFreeMass);

      expect(
        range.minKg,
        lessThan(DefinitionCurve.leanestWeight(marcoFatFreeMass)),
      );
      expect(
        range.maxKg,
        greaterThan(DefinitionCurve.softestWeight(marcoFatFreeMass)),
      );
      // Deve essere possibile chiedere i 75 kg «definito» della roadmap:
      // senza quel margine il verdetto di fattibilità non comparirebbe mai.
      expect(range.minKg, lessThan(75));
    });

    test('non scende mai sotto la massa magra', () {
      // Corpo piccolo: con un margine fisso il fondo scala finirebbe sotto
      // la massa magra, cioè a grasso negativo.
      final range = DefinitionCurve.dialRange(40);

      expect(range.minKg, greaterThan(40));
    });
  });
}
