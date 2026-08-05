import 'dart:async';

// `drift` esporta `isNull`/`isNotNull` come costruttori di espressioni SQL e
// si scontrerebbero con i matcher di flutter_test: qui servono i matcher.
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/goal/data/body_state_repository.dart';

import '../marco.dart';

void main() {
  late AppDatabase database;
  late BodyStateRepository repository;

  const profileId = 'profile-marco';
  final now = DateTime.now().toUtc();

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    repository = BodyStateRepository(database);
    await database
        .into(database.appProfiles)
        .insert(
          AppProfilesCompanion.insert(
            id: profileId,
            displayName: 'Marco',
            createdAt: now,
            updatedAt: now,
          ),
        );
  });

  tearDown(() => database.close());

  Future<void> addMeasurement({
    required int daysAgo,
    required double weightKg,
    double? bodyFatPct,
  }) => database
      .into(database.bodyMeasurements)
      .insert(
        BodyMeasurementsCompanion.insert(
          id: 'm-$daysAgo',
          profileId: profileId,
          weightKg: weightKg,
          measuredAt: now.subtract(Duration(days: daysAgo)),
          bodyFatPct: Value(bodyFatPct),
          hasImpedance: Value(bodyFatPct != null),
          createdAt: now,
          updatedAt: now,
        ),
      );

  Future<void> addDay({required int daysAgo, required double kcal}) async {
    final eatenAt = now.subtract(Duration(days: daysAgo));
    await database
        .into(database.meals)
        .insert(
          MealsCompanion.insert(
            id: 'meal-$daysAgo',
            profileId: profileId,
            mealType: 'lunch',
            eatenAt: eatenAt,
            createdAt: now,
            updatedAt: now,
          ),
        );
    await database
        .into(database.mealItems)
        .insert(
          MealItemsCompanion.insert(
            id: 'item-$daysAgo',
            mealId: 'meal-$daysAgo',
            foodName: 'Pasto',
            grams: 500,
            caloriesPer100g: kcal / 5,
            proteinPer100g: 10,
            carbsPer100g: 20,
            fatPer100g: 5,
            totalCalories: kcal,
            totalProtein: 50,
            totalCarbs: 100,
            totalFat: 25,
            createdAt: now,
            updatedAt: now,
          ),
        );
  }

  test('senza pesate lo stato è vuoto, non un errore', () async {
    final state = await repository.load(profileId);

    expect(state.hasWeight, isFalse);
    expect(state.hasComposition, isFalse);
    expect(state.tdeeSample, isNull);
  });

  test('con il solo peso manca la composizione, e si vede', () async {
    await addMeasurement(daysAgo: 0, weightKg: marcoWeight);

    final state = await repository.load(profileId);

    expect(state.hasWeight, isTrue);
    expect(state.weightKg, marcoWeight);
    expect(state.hasComposition, isFalse);
  });

  test('la massa magra arriva dalla pesata completa più recente', () async {
    await addMeasurement(daysAgo: 0, weightKg: 95.5);
    await addMeasurement(daysAgo: 2, weightKg: 95.8, bodyFatPct: 25);
    await addMeasurement(daysAgo: 30, weightKg: 98, bodyFatPct: 28);

    final state = await repository.load(profileId);

    expect(state.weightKg, 95.5);
    expect(state.fatFreeMassKg, closeTo(95.8 * 0.75, 0.0001));
    expect(state.fatFreeMassMeasuredAt, isNotNull);
  });

  test('la media a 7 giorni ignora le pesate vecchie', () async {
    await addMeasurement(daysAgo: 0, weightKg: 95);
    await addMeasurement(daysAgo: 3, weightKg: 96);
    await addMeasurement(daysAgo: 40, weightKg: 110);

    final state = await repository.load(profileId);

    expect(state.sevenDayAverageKg, closeTo(95.5, 0.0001));
  });

  test('tre settimane di pesate e di diario producono il campione', () async {
    for (var day = 0; day <= 21; day++) {
      await addMeasurement(
        daysAgo: day,
        weightKg: 95.5 + day * 0.05,
        bodyFatPct: day == 0 ? 25 : null,
      );
      await addDay(daysAgo: day, kcal: 2200);
    }

    final state = await repository.load(profileId);
    final sample = state.tdeeSample;

    expect(sample, isNotNull);
    expect(sample!.isUsable, isTrue);
    expect(sample.averageDailyKcal, closeTo(2200, 0.01));
    expect(sample.weightChangeKg, lessThan(0));
  });

  test('le pesate cancellate non contano', () async {
    await addMeasurement(daysAgo: 0, weightKg: 95.5, bodyFatPct: 25);
    await (database.update(database.bodyMeasurements)
          ..where((row) => row.id.equals('m-0')))
        .write(BodyMeasurementsCompanion(deletedAt: Value(now)));

    final state = await repository.load(profileId);

    expect(state.hasWeight, isFalse);
  });

  test('lo stream si aggiorna a ogni pesata nuova', () async {
    // Una sola sottoscrizione: lo stream nasce da un `async*` e non è
    // riascoltabile, quindi si avanza a mano evento per evento.
    final states = StreamIterator(repository.watch(profileId));

    expect(await states.moveNext(), isTrue);
    expect(states.current.hasWeight, isFalse);

    await addMeasurement(daysAgo: 0, weightKg: marcoWeight);

    expect(await states.moveNext(), isTrue);
    expect(states.current.weightKg, marcoWeight);
    await states.cancel();
  });
}
