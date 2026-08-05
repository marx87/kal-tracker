import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/features/goal/data/goal_repository.dart';
import 'package:kal_tracker/features/goal/data/goal_store.dart';
import 'package:kal_tracker/features/goal/domain/definition_level.dart';
import 'package:kal_tracker/features/goal/domain/goal.dart';

import '../marco.dart';

void main() {
  late InMemoryGoalStore store;
  late GoalRepository repository;

  setUp(() {
    store = InMemoryGoalStore();
    repository = GoalRepository(store);
  });

  Future<GoalHistory> setGoal({
    double targetWeightKg = 80.5,
    DefinitionLevel level = DefinitionLevel.defined,
    double paceKgPerWeek = 0.5,
    double currentWeightKg = marcoWeight,
  }) => repository.setGoal(
    targetWeightKg: targetWeightKg,
    targetLevel: level,
    paceKgPerWeek: paceKgPerWeek,
    currentWeightKg: currentWeightKg,
    fatFreeMassKg: marcoFatFreeMass,
  );

  test('senza niente salvato non c\'è obiettivo, e va bene così', () async {
    final history = await repository.read();

    expect(history.hasGoal, isFalse);
    expect(history.past, isEmpty);
  });

  test('il primo obiettivo registra da dove si parte', () async {
    final history = await setGoal();

    expect(history.current, isNotNull);
    expect(history.current!.targetWeightKg, 80.5);
    expect(history.current!.startWeightKg, marcoWeight);
    expect(history.current!.startFatFreeMassKg, marcoFatFreeMass);
    expect(history.current!.phase, GoalPhase.approach);
    expect(history.current!.phaseStartedAt, isNotNull);
    expect(history.past, isEmpty);
    expect((await store.read()).current!.id, history.current!.id);
  });

  test('cambiare traguardo archivia il precedente, non lo cancella', () async {
    final first = await setGoal();
    final second = await setGoal(
      targetWeightKg: 84,
      level: DefinitionLevel.athletic,
    );

    expect(second.current!.targetWeightKg, 84);
    expect(second.current!.id, isNot(first.current!.id));
    expect(second.past, hasLength(1));
    expect(second.past.first.id, first.current!.id);
    expect(second.past.first.outcome, GoalOutcome.replaced);
    expect(second.past.first.closedAt, isNotNull);
    expect(second.past.first.isOpen, isFalse);
  });

  test('cambiare ritmo NON cambia obiettivo né storico', () async {
    final before = await setGoal();
    final after = await repository.setPace(
      paceKgPerWeek: 0.65,
      currentWeightKg: marcoWeight,
    );

    expect(after.current!.id, before.current!.id);
    expect(after.current!.startedAt, before.current!.startedAt);
    expect(after.current!.targetWeightKg, before.current!.targetWeightKg);
    expect(after.current!.paceKgPerWeek, 0.65);
    expect(after.past, isEmpty);
  });

  test('senza obiettivo il ritmo non ha dove andare, e non esplode', () async {
    final history = await repository.setPace(
      paceKgPerWeek: 0.6,
      currentWeightKg: marcoWeight,
    );

    expect(history.hasGoal, isFalse);
  });

  test('il passaggio di fase segna quando è iniziata', () async {
    final before = await setGoal();
    final after = await repository.setPhase(GoalPhase.consolidation);

    expect(after.current!.phase, GoalPhase.consolidation);
    expect(
      after.current!.phaseStartedAt!.isAfter(before.current!.phaseStartedAt!) ||
          after.current!.phaseStartedAt == before.current!.phaseStartedAt,
      isTrue,
    );
  });

  group('annullamento', () {
    test('rimette in corsa l\'obiettivo di prima', () async {
      final first = await setGoal();
      await setGoal(targetWeightKg: 84, level: DefinitionLevel.athletic);

      final restored = await repository.undoLastChange();

      expect(restored.current!.id, first.current!.id);
      expect(restored.current!.targetWeightKg, 80.5);
      // Ripristinato vuol dire di nuovo aperto: niente data di chiusura.
      expect(restored.current!.isOpen, isTrue);
      expect(restored.current!.outcome, isNull);
      expect(restored.past, isEmpty);
    });

    test('senza niente da ripristinare non fa danni', () async {
      final history = await repository.undoLastChange();

      expect(history.hasGoal, isFalse);
      expect(history.past, isEmpty);
    });
  });

  group('il limite di sicurezza vale anche fuori dalla UI', () {
    test('un ritmo oltre lo 0,7 % non si salva, e spiega perché', () async {
      await setGoal();

      expect(
        () => repository.setPace(
          paceKgPerWeek: 1.2,
          currentWeightKg: marcoWeight,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('oltre il limite'),
          ),
        ),
      );
      expect((await repository.read()).current!.paceKgPerWeek, 0.5);
    });

    test('nemmeno impostando un obiettivo nuovo lo si può aggirare', () async {
      expect(
        () => setGoal(paceKgPerWeek: 1.5),
        throwsA(isA<FormatException>()),
      );
      expect((await repository.read()).hasGoal, isFalse);
    });

    test('un peso traguardo che non è un peso viene rifiutato', () async {
      expect(
        () => repository.setGoal(
          targetWeightKg: double.nan,
          targetLevel: DefinitionLevel.defined,
          paceKgPerWeek: 0.5,
          currentWeightKg: marcoWeight,
          fatFreeMassKg: marcoFatFreeMass,
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  test('si può restare senza obiettivo, tenendo lo storico', () async {
    await setGoal();
    final cleared = await repository.clearGoal();

    expect(cleared.hasGoal, isFalse);
    expect(cleared.past, hasLength(1));
    expect(cleared.past.first.outcome, GoalOutcome.abandoned);
  });

  test('lo storico non cresce all\'infinito', () async {
    for (var index = 0; index < GoalRepository.maxHistoryEntries + 5; index++) {
      await setGoal(targetWeightKg: 80 + index * 0.5);
    }

    final history = await repository.read();

    expect(history.past, hasLength(GoalRepository.maxHistoryEntries));
    // Il più recente sta in testa: è l'ordine in cui lo si guarda.
    expect(
      history.past.first.targetWeightKg,
      greaterThan(history.past.last.targetWeightKg),
    );
  });
}
