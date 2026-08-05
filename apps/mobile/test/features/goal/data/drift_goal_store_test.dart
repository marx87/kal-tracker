import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/goal/data/goal_repository.dart';
import 'package:kal_tracker/features/goal/data/goal_store.dart';
import 'package:kal_tracker/features/goal/domain/definition_level.dart';
import 'package:kal_tracker/features/goal/domain/goal.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

Future<Directory> _legacyDirectory(Map<String, Object?> content) async {
  final directory = await Directory.systemTemp.createTemp('kal_goal_');
  File(
    '${directory.path}/${FileGoalStore.fileName}',
  ).writeAsStringSync(jsonEncode(content));
  return directory;
}

Map<String, Object?> _goalJson({
  required String id,
  double targetWeightKg = 80.5,
  String targetLevel = 'defined',
  String startedAt = '2026-07-01T06:00:00.000Z',
  String? closedAt,
  String? outcome,
  double startWeightKg = 95.8,
  double startFatFreeMassKg = 71.66,
  double paceKgPerWeek = 0.5,
}) => {
  'id': id,
  'target_weight_kg': targetWeightKg,
  'target_level': targetLevel,
  'pace_kg_per_week': paceKgPerWeek,
  'started_at': startedAt,
  'start_weight_kg': startWeightKg,
  'start_fat_free_mass_kg': startFatFreeMassKg,
  'phase': 'approach',
  'phase_started_at': startedAt,
  'closed_at': closedAt,
  'outcome': outcome,
};

void main() {
  setUpAll(AppTime.initialize);

  late AppDatabase database;
  late String profileId;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
  });

  tearDown(() => database.close());

  DriftGoalStore storeWith({FileGoalStore? legacy}) => DriftGoalStore(
    database,
    legacy: legacy ?? FileGoalStore(directory: Directory.systemTemp.createTemp),
    profileId: () async => profileId,
  );

  Future<void> insertGoal({
    required String id,
    required DateTime startedAt,
    DateTime? closedAt,
    String? outcome,
    double targetWeightKg = 80.5,
  }) => database
      .into(database.goals)
      .insert(
        GoalsCompanion.insert(
          id: id,
          profileId: profileId,
          targetWeightKg: targetWeightKg,
          targetLevel: 'defined',
          paceKgPerWeek: 0.5,
          startedAt: startedAt,
          startWeightKg: 95.8,
          startFatFreeMassKg: 71.66,
          createdAt: startedAt,
          updatedAt: startedAt,
          closedAt: Value(closedAt),
          outcome: Value(outcome),
        ),
      );

  test('il traguardo sopravvive alla riapertura', () async {
    await GoalRepository(storeWith()).setGoal(
      targetWeightKg: 80.5,
      targetLevel: DefinitionLevel.defined,
      paceKgPerWeek: 0.5,
      currentWeightKg: 95.8,
      fatFreeMassKg: 71.66,
    );

    // Uno store nuovo sullo stesso database: è la riapertura dell'app.
    final history = await storeWith().read();
    expect(history.current, isNotNull);
    expect(history.current!.targetWeightKg, closeTo(80.5, 0.0001));
    expect(history.current!.targetLevel, DefinitionLevel.defined);
    expect(history.current!.phase, GoalPhase.approach);
    expect(history.past, isEmpty);

    final row = await database.select(database.goals).getSingle();
    expect(row.targetLevel, 'defined');
    expect(row.closedAt, isNull);
    expect(row.deletedAt, isNull);
  });

  test('cambiare traguardo archivia il vecchio senza perderlo', () async {
    final repository = GoalRepository(storeWith());
    await repository.setGoal(
      targetWeightKg: 86,
      targetLevel: DefinitionLevel.lean,
      paceKgPerWeek: 0.5,
      currentWeightKg: 95.8,
      fatFreeMassKg: 71.66,
    );
    await repository.setGoal(
      targetWeightKg: 80.5,
      targetLevel: DefinitionLevel.defined,
      paceKgPerWeek: 0.6,
      currentWeightKg: 95.8,
      fatFreeMassKg: 71.66,
    );

    final history = await storeWith().read();
    expect(history.current!.targetWeightKg, closeTo(80.5, 0.0001));
    expect(history.past, hasLength(1));
    expect(history.past.single.targetWeightKg, closeTo(86, 0.0001));
    expect(history.past.single.outcome, GoalOutcome.replaced);
    expect(await database.select(database.goals).get(), hasLength(2));
  });

  test('Annulla rimette in corsa il traguardo di prima', () async {
    final repository = GoalRepository(storeWith());
    await repository.setGoal(
      targetWeightKg: 86,
      targetLevel: DefinitionLevel.lean,
      paceKgPerWeek: 0.5,
      currentWeightKg: 95.8,
      fatFreeMassKg: 71.66,
    );
    final primo = (await storeWith().read()).current!.id;
    await repository.setGoal(
      targetWeightKg: 80.5,
      targetLevel: DefinitionLevel.defined,
      paceKgPerWeek: 0.6,
      currentWeightKg: 95.8,
      fatFreeMassKg: 71.66,
    );

    await repository.undoLastChange();

    final history = await storeWith().read();
    expect(history.current!.id, primo);
    expect(history.current!.closedAt, isNull);
    expect(history.past, isEmpty);

    // Il traguardo buttato via è un tombstone, non una riga sparita: l'altro
    // dispositivo deve poter imparare che non c'è più.
    final righe = await database.select(database.goals).get();
    expect(righe, hasLength(2));
    expect(righe.where((row) => row.deletedAt != null), hasLength(1));
  });

  test('la fase e il ritmo si cambiano senza toccare lo storico', () async {
    final repository = GoalRepository(storeWith());
    await repository.setGoal(
      targetWeightKg: 80.5,
      targetLevel: DefinitionLevel.defined,
      paceKgPerWeek: 0.5,
      currentWeightKg: 95.8,
      fatFreeMassKg: 71.66,
    );
    final id = (await storeWith().read()).current!.id;

    await repository.setPace(paceKgPerWeek: 0.66, currentWeightKg: 95.8);
    await repository.setPhase(GoalPhase.consolidation);

    final history = await storeWith().read();
    expect(history.current!.id, id, reason: 'lo stesso obiettivo');
    expect(history.current!.paceKgPerWeek, closeTo(0.66, 0.0001));
    expect(history.current!.phase, GoalPhase.consolidation);
    expect(history.current!.phaseStartedAt, isNotNull);
    expect(await database.select(database.goals).get(), hasLength(1));
  });

  test(
    'due obiettivi aperti: vince il più recente, l\'altro si archivia',
    () async {
      await insertGoal(
        id: 'telefono',
        startedAt: DateTime.utc(2026, 7, 1),
        targetWeightKg: 86,
      );
      await insertGoal(
        id: 'tablet',
        startedAt: DateTime.utc(2026, 7, 3),
        targetWeightKg: 80.5,
      );

      final store = storeWith();
      final history = await store.read();

      expect(history.current!.id, 'tablet');
      expect(history.past.single.id, 'telefono');
      expect(history.past.single.outcome, GoalOutcome.replaced);

      // La prima scrittura mette per iscritto la stessa decisione.
      await store.write(history);
      final archiviato = await (database.select(
        database.goals,
      )..where((row) => row.id.equals('telefono'))).getSingle();
      expect(archiviato.closedAt, isNotNull);
      expect(archiviato.outcome, 'replaced');
      expect(
        archiviato.deletedAt,
        isNull,
        reason: 'archiviato, non cancellato',
      );
    },
  );

  test('gli obiettivi fuori dalla finestra non vengono cancellati', () async {
    // Ventidue traguardi chiusi: due sono oltre la finestra dello storico.
    for (var i = 0; i < 22; i++) {
      final started = DateTime.utc(2026, 1, 1).add(Duration(days: i * 7));
      await insertGoal(
        id: 'obiettivo-$i',
        startedAt: started,
        closedAt: started.add(const Duration(days: 6)),
        outcome: 'replaced',
      );
    }

    final store = storeWith();
    final history = await store.read();
    expect(history.past, hasLength(DriftGoalStore.historyWindow));

    await store.write(history);

    final vivi = await (database.select(
      database.goals,
    )..where((row) => row.deletedAt.isNull())).get();
    expect(
      vivi,
      hasLength(22),
      reason: 'i due più vecchi restano nell\'archivio, solo fuori dalla vista',
    );
  });

  test(
    'il file JSON entra alla prima apertura e poi viene archiviato',
    () async {
      final directory = await _legacyDirectory({
        'current': _goalJson(id: 'goal-corrente'),
        'past': [
          _goalJson(
            id: 'goal-vecchio',
            targetWeightKg: 86,
            targetLevel: 'lean',
            startedAt: '2026-05-01T06:00:00.000Z',
            closedAt: '2026-06-30T06:00:00.000Z',
            outcome: 'replaced',
          ),
          // Un file troncato: pesi a zero. Non è un traguardo, è rumore, e non
          // deve far fallire tutta la migrazione.
          _goalJson(id: 'goal-rotto', targetWeightKg: 0, startWeightKg: 0),
        ],
      });
      addTearDown(() => directory.delete(recursive: true));

      final history = await storeWith(
        legacy: FileGoalStore(directory: () async => directory),
      ).read();

      expect(history.current!.id, 'goal-corrente');
      expect(history.past.single.id, 'goal-vecchio');
      expect(history.past.single.outcome, GoalOutcome.replaced);
      expect(await database.select(database.goals).get(), hasLength(2));
      expect(
        File('${directory.path}/${FileGoalStore.fileName}').existsSync(),
        isFalse,
      );
      expect(
        File(
          '${directory.path}/${FileGoalStore.archivedFileName}',
        ).existsSync(),
        isTrue,
      );
    },
  );

  test('quello che c\'è già nella tabella vince sul file', () async {
    final directory = await _legacyDirectory({
      'current': _goalJson(id: 'goal-corrente', targetWeightKg: 90),
      'past': const <Object?>[],
    });
    addTearDown(() => directory.delete(recursive: true));

    await insertGoal(
      id: 'goal-corrente',
      startedAt: DateTime.utc(2026, 7, 1),
      targetWeightKg: 80.5,
    );

    final history = await storeWith(
      legacy: FileGoalStore(directory: () async => directory),
    ).read();

    expect(history.current!.targetWeightKg, closeTo(80.5, 0.0001));
    expect(await database.select(database.goals).get(), hasLength(1));
  });
}
