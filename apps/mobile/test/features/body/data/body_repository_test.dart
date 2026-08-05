import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/body/data/body_repository.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';

void main() {
  late AppDatabase database;
  late BodyRepository repository;
  late String profileId;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
    repository = BodyRepository(database);
  });

  tearDown(() => database.close());

  Future<List<Map<String, Object?>>> outbox() async {
    final rows = await database.select(database.syncOutbox).get();
    return rows
        .where((row) => row.entityType == 'body_measurement')
        .map(
          (row) => {
            'operation': row.operation,
            ...jsonDecode(row.payloadJson) as Map<String, Object?>,
          },
        )
        .toList(growable: false);
  }

  test('la pesata con impedenza conserva percentuali e ohm, e si dichiara '
      'completa', () async {
    await repository.addMeasurement(
      profileId: profileId,
      weightKg: 94.7,
      measuredAt: DateTime.utc(2026, 8, 5, 6, 30),
      bodyFatPct: 24.3,
      musclePct: 71.2,
      waterPct: 55.1,
      impedanceOhm: 512,
    );

    final saved = await repository
        .watchMeasurements(profileId: profileId)
        .first;
    final measurement = saved.single;
    expect(measurement.weightKg, 94.7);
    expect(measurement.hasImpedance, isTrue);
    expect(measurement.bodyFatPct, 24.3);
    expect(measurement.impedanceOhm, 512);
    expect(measurement.hasComposition, isTrue);
    expect(measurement.fatMassKg, closeTo(23.0, 0.05));
    expect(measurement.leanMassKg, closeTo(71.7, 0.05));
    expect(measurement.source, 'manual');
  });

  test('la pesata senza impedenza resta una pesata di solo peso: i derivati '
      'non si inventano', () async {
    await repository.addMeasurement(
      profileId: profileId,
      weightKg: 95,
      measuredAt: DateTime.utc(2026, 8, 5, 6, 30),
    );

    final measurement =
        (await repository.watchMeasurements(profileId: profileId).first).single;
    expect(measurement.hasImpedance, isFalse);
    expect(measurement.bodyFatPct, isNull);
    expect(measurement.fatMassKg, isNull);
    expect(measurement.hasComposition, isFalse);
  });

  test('le circonferenze restano attaccate alla loro pesata e viaggiano nel '
      'payload di sincronizzazione', () async {
    await repository.addMeasurement(
      profileId: profileId,
      weightKg: 94,
      measuredAt: DateTime.utc(2026, 8, 5, 6, 30),
      circumferences: const {'Vita': 93.5, 'Braccio': 36},
      note: '  a digiuno  ',
    );

    final measurement =
        (await repository.watchMeasurements(profileId: profileId).first).single;
    expect(measurement.circumferences, {'Vita': 93.5, 'Braccio': 36.0});
    // La nota si ripulisce: gli spazi in coda non sono un contenuto.
    expect(measurement.note, 'a digiuno');

    final payload = (await outbox()).single;
    expect(payload['operation'], 'upsert');
    expect(payload['body_fat_pct'], isNull);
    final values = (payload['values']! as List).cast<Map<String, Object?>>();
    expect(
      values.map((value) => value['label']),
      containsAll(['Vita', 'Braccio']),
    );
  });

  test('la finestra chiesta esclude le pesate più vecchie', () async {
    await repository.addMeasurement(
      profileId: profileId,
      weightKg: 99,
      measuredAt: DateTime.utc(2026, 1, 10),
    );
    await repository.addMeasurement(
      profileId: profileId,
      weightKg: 94,
      measuredAt: DateTime.utc(2026, 8, 1),
    );

    final recent = await repository
        .watchMeasurements(profileId: profileId, since: DateTime.utc(2026, 7))
        .first;
    expect(recent, hasLength(1));
    expect(recent.single.weightKg, 94);
  });

  test(
    'elimina e ripristina: la pesata torna con le sue circonferenze',
    () async {
      final id = await repository.addMeasurement(
        profileId: profileId,
        weightKg: 94,
        measuredAt: DateTime.utc(2026, 8, 5),
        circumferences: const {'Vita': 93},
      );

      await repository.deleteMeasurement(id);
      expect(
        await repository.watchMeasurements(profileId: profileId).first,
        isEmpty,
      );

      await repository.restoreMeasurement(id);
      final restored =
          (await repository.watchMeasurements(profileId: profileId).first)
              .single;
      expect(restored.circumferences, {'Vita': 93.0});

      final operations = (await outbox()).map((row) => row['operation']);
      expect(operations, ['upsert', 'delete', 'upsert']);
    },
  );

  test('eliminare due volte non accoda una seconda cancellazione', () async {
    final id = await repository.addMeasurement(
      profileId: profileId,
      weightKg: 94,
      measuredAt: DateTime.utc(2026, 8, 5),
    );
    await repository.deleteMeasurement(id);
    await repository.deleteMeasurement(id);

    final operations = (await outbox()).map((row) => row['operation']);
    expect(operations, ['upsert', 'delete']);
  });

  test(
    'i valori impossibili si fermano qui, non al CHECK del database',
    () async {
      Future<void> save({
        double weight = 94,
        double? fat,
        double? impedance,
        Map<String, double> circumferences = const {},
      }) => repository.addMeasurement(
        profileId: profileId,
        weightKg: weight,
        measuredAt: DateTime.utc(2026, 8, 5),
        bodyFatPct: fat,
        impedanceOhm: impedance,
        circumferences: circumferences,
      );

      expect(save(weight: 4), throwsA(isA<FormatException>()));
      expect(save(fat: 120), throwsA(isA<FormatException>()));
      expect(save(impedance: 5000), throwsA(isA<FormatException>()));
      expect(
        save(circumferences: const {'Vita': 0}),
        throwsA(isA<FormatException>()),
      );
      expect(
        save(
          circumferences: {
            for (var index = 0; index < 20; index++) 'Misura $index': 30,
          },
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('una pesata di un altro profilo non entra nella serie', () async {
    final now = AppTime.nowUtc();
    await database
        .into(database.appProfiles)
        .insert(
          AppProfilesCompanion.insert(
            id: 'altro',
            displayName: 'Altro',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await repository.addMeasurement(
      profileId: 'altro',
      weightKg: 60,
      measuredAt: DateTime.utc(2026, 8, 5),
    );
    await repository.addMeasurement(
      profileId: profileId,
      weightKg: 94,
      measuredAt: DateTime.utc(2026, 8, 5),
    );

    final mine = await repository.watchMeasurements(profileId: profileId).first;
    expect(mine.map((item) => item.weightKg), [94]);
  });
}
