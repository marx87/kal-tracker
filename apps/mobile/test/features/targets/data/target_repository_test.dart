import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/targets/data/target_repository.dart';
import 'package:kal_tracker/features/targets/domain/nutrition_target.dart';

void main() {
  late AppDatabase database;
  late TargetRepository repository;
  late String profileId;

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profileId = (await LocalProfileRepository(database).getOrCreateMarco()).id;
    repository = TargetRepository(database);
  });

  tearDown(() => database.close());

  test('mantiene un solo obiettivo per profilo e lo aggiorna', () async {
    await repository.upsertTarget(
      profileId: profileId,
      target: const NutritionTarget.standard(),
    );
    await repository.upsertTarget(
      profileId: profileId,
      target: const NutritionTarget(
        calories: 2200,
        protein: 150,
        carbs: 240,
        fat: 70,
      ),
    );

    final target = await repository.getTarget(profileId);
    final rows = await database.select(database.nutritionTargets).get();
    final outbox = await database.select(database.syncOutbox).get();

    expect(rows, hasLength(1));
    expect(target?.calories, 2200);
    expect(target?.protein, 150);
    expect(
      outbox.where((row) => row.entityType == 'nutrition_target'),
      hasLength(2),
    );
  });

  test('soft-delete idempotente e riattivazione', () async {
    await repository.upsertTarget(
      profileId: profileId,
      target: const NutritionTarget.standard(),
    );
    await repository.deleteTarget(profileId);
    await repository.deleteTarget(profileId);

    expect(await repository.getTarget(profileId), isNull);
    var operations = (await database.select(database.syncOutbox).get())
        .where((row) => row.entityType == 'nutrition_target')
        .map((row) => row.operation);
    expect(operations, ['upsert', 'delete']);

    await repository.upsertTarget(
      profileId: profileId,
      target: const NutritionTarget.standard(),
    );
    expect(await repository.getTarget(profileId), isNotNull);
    operations = (await database.select(database.syncOutbox).get())
        .where((row) => row.entityType == 'nutrition_target')
        .map((row) => row.operation);
    expect(operations, ['upsert', 'delete', 'upsert']);
  });

  test('rifiuta obiettivi non validi prima di scrivere', () async {
    await expectLater(
      repository.upsertTarget(
        profileId: profileId,
        target: const NutritionTarget(
          calories: 0,
          protein: 100,
          carbs: 200,
          fat: 60,
        ),
      ),
      throwsFormatException,
    );
    expect(await database.select(database.nutritionTargets).get(), isEmpty);
  });
}
