import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/wellbeing/data/wellbeing_repository.dart';

void main() {
  late AppDatabase database;
  late WellbeingRepository repository;
  late String profileId;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
    repository = WellbeingRepository(database);
  });

  tearDown(() => database.close());

  test('somma soltanto l’acqua del giorno richiesto', () async {
    final day = DateTime(2026, 8, 2, 9);
    final firstId = await repository.addWater(
      profileId: profileId,
      milliliters: 250,
      loggedAt: day,
    );
    await repository.addWater(
      profileId: profileId,
      milliliters: 500,
      loggedAt: day.add(const Duration(hours: 4)),
    );
    await repository.addWater(
      profileId: profileId,
      milliliters: 750,
      loggedAt: day.add(const Duration(days: 1)),
    );

    var summary = await repository
        .watchWaterDay(profileId: profileId, day: day)
        .first;
    expect(summary.totalMilliliters, 750);
    expect(summary.entries, hasLength(2));

    await repository.deleteWater(firstId);
    await repository.deleteWater(firstId);
    summary = await repository
        .watchWaterDay(profileId: profileId, day: day)
        .first;
    expect(summary.totalMilliliters, 500);

    final waterOperations = (await database.select(database.syncOutbox).get())
        .where((row) => row.entityType == 'water_log')
        .map((row) => row.operation);
    expect(waterOperations, ['upsert', 'upsert', 'upsert', 'delete']);
  });

  test('salva e ordina le misurazioni del peso', () async {
    final older = await repository.addWeight(
      profileId: profileId,
      weightKg: 82.4,
      measuredAt: DateTime.utc(2026, 7, 1),
      note: '  Inizio  ',
    );
    await repository.addWeight(
      profileId: profileId,
      weightKg: 80.9,
      measuredAt: DateTime.utc(2026, 8, 1),
    );

    var weights = await repository.watchRecentWeights(profileId).first;
    expect(weights.map((row) => row.weightKg), [80.9, 82.4]);
    expect(weights.last.note, 'Inizio');

    await repository.deleteWeight(older);
    await repository.deleteWeight(older);
    weights = await repository.watchRecentWeights(profileId).first;
    expect(weights.map((row) => row.weightKg), [80.9]);
  });

  test('valida quantità d’acqua e peso', () async {
    await expectLater(
      repository.addWater(
        profileId: profileId,
        milliliters: 0,
        loggedAt: DateTime.now(),
      ),
      throwsFormatException,
    );
    await expectLater(
      repository.addWeight(
        profileId: profileId,
        weightKg: double.nan,
        measuredAt: DateTime.now(),
      ),
      throwsFormatException,
    );
  });
}
