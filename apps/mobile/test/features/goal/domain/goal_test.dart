import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/goal/domain/definition_level.dart';
import 'package:kal_tracker/features/goal/domain/goal.dart';

import '../marco.dart';

Goal buildGoal() => Goal(
  id: 'goal-1',
  targetWeightKg: 80.5,
  targetLevel: DefinitionLevel.defined,
  paceKgPerWeek: 0.5,
  startedAt: DateTime.utc(2026, 8, 5, 6, 30),
  startWeightKg: marcoWeight,
  startFatFreeMassKg: marcoFatFreeMass,
  phaseStartedAt: DateTime.utc(2026, 8, 5, 6, 30),
);

void main() {
  group('l\'obiettivo', () {
    test('si dice a parole: peso più definizione', () {
      expect(buildGoal().headline, '80,5 kg definito');
    });

    test('sopravvive al giro attraverso il file', () {
      final goal = buildGoal().copyWith(
        phase: GoalPhase.consolidation,
        closedAt: DateTime.utc(2026, 12, 2),
        outcome: GoalOutcome.reached,
      );

      final restored = Goal.fromJson(goal.toJson());

      expect(restored.id, goal.id);
      expect(restored.targetWeightKg, goal.targetWeightKg);
      expect(restored.targetLevel, DefinitionLevel.defined);
      expect(restored.paceKgPerWeek, 0.5);
      expect(restored.phase, GoalPhase.consolidation);
      expect(restored.startedAt, goal.startedAt);
      expect(restored.closedAt, DateTime.utc(2026, 12, 2));
      expect(restored.outcome, GoalOutcome.reached);
      expect(restored.isOpen, isFalse);
    });

    test('un file rovinato non fa esplodere l\'app', () {
      final restored = Goal.fromJson(const {
        'id': 'x',
        'target_weight_kg': 'ottanta',
        'target_level': 'inesistente',
        'started_at': 'ieri',
      });

      expect(restored.targetWeightKg, 0);
      expect(restored.targetLevel, DefinitionLevel.normal);
      expect(restored.phase, GoalPhase.approach);
    });

    test('lo storico si serializza insieme al corrente', () {
      final history = GoalHistory(
        current: buildGoal(),
        past: [buildGoal().copyWith(outcome: GoalOutcome.replaced)],
      );

      final restored = GoalHistory.fromJson(history.toJson());

      expect(restored.current?.id, 'goal-1');
      expect(restored.past, hasLength(1));
      expect(restored.past.first.outcome, GoalOutcome.replaced);
      expect(restored.hasGoal, isTrue);
    });

    test('senza obiettivo lo storico è vuoto e valido', () {
      expect(const GoalHistory.empty().hasGoal, isFalse);
      expect(GoalHistory.fromJson(const {}).current, isNull);
    });
  });

  group('le tre fasi', () {
    test('hanno regole diverse e scritte', () {
      for (final phase in GoalPhase.values) {
        expect(phase.label, isNotEmpty);
        expect(phase.rule, isNotEmpty);
      }
      expect(GoalPhase.consolidation.rule, contains('glicogeno'));
      expect(GoalPhase.maintenance.rule, contains('banda'));
    });
  });

  group('la banda di mantenimento', () {
    final band = MaintenanceBand.around(87.5);

    test('è un intervallo, non un numero', () {
      expect(band.lowKg, closeTo(86.5, 0.001));
      expect(band.highKg, closeTo(88.5, 0.001));
      expect(band.label, '86,5 – 88,5 kg');
    });

    test('dentro la banda non succede niente', () {
      expect(band.statusOf(87.5), BandStatus.inside);
      expect(band.statusOf(86.5), BandStatus.inside);
      expect(band.statusOf(88.5), BandStatus.inside);
      expect(band.statusOf(89), BandStatus.above);
      expect(band.statusOf(86), BandStatus.below);
    });

    test('una settimana fuori non è una tendenza', () {
      expect(
        MaintenanceWatch.needsNewCycle(
          band: band,
          weeklyAverages: [87.4, 89.2],
        ),
        isFalse,
      );
    });

    test('due settimane fuori dalla stessa parte riaprono un ciclo', () {
      expect(
        MaintenanceWatch.needsNewCycle(
          band: band,
          weeklyAverages: [87.4, 89.2, 89.5],
        ),
        isTrue,
      );
    });

    test('due settimane fuori da parti opposte non significano niente', () {
      expect(
        MaintenanceWatch.needsNewCycle(
          band: band,
          weeklyAverages: [89.5, 85.9],
        ),
        isFalse,
      );
    });

    test('con una sola settimana di dati non si decide', () {
      expect(
        MaintenanceWatch.needsNewCycle(band: band, weeklyAverages: [92]),
        isFalse,
      );
    });
  });
}
