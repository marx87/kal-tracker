// `drift` esporta `isNull`/`isNotNull` come costruttori di espressioni SQL e
// si scontrerebbero con i matcher di flutter_test: qui servono i matcher.
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/coach/data/coach_snapshot_repository.dart';

import '../fixtures.dart';

void main() {
  late AppDatabase database;
  late CoachSnapshotRepository repository;

  const profileId = 'profile-marco';
  final sunday = DateTime.utc(2026, 8, 2);
  final now = DateTime.utc(2026, 8, 2, 20);

  /// Le 12 UTC del giorno: mezzogiorno a Roma, lontano da ogni confine.
  DateTime at(DateTime day, {int hour = 12}) =>
      DateTime.utc(day.year, day.month, day.day, hour);

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    repository = CoachSnapshotRepository(database);
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

  Future<void> addMeal({
    required DateTime eatenAt,
    required double kcal,
    required double protein,
    String suffix = '',
  }) async {
    final id = 'meal-${eatenAt.toIso8601String()}$suffix';
    await database
        .into(database.meals)
        .insert(
          MealsCompanion.insert(
            id: id,
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
            id: 'item-$id',
            mealId: id,
            foodName: 'Pasto',
            grams: 100,
            caloriesPer100g: kcal,
            proteinPer100g: protein,
            carbsPer100g: 0,
            fatPer100g: 0,
            totalCalories: kcal,
            totalProtein: protein,
            totalCarbs: 0,
            totalFat: 0,
            createdAt: now,
            updatedAt: now,
          ),
        );
  }

  Future<void> addWeighIn({
    required DateTime measuredAt,
    required double weightKg,
    double? bodyFatPct,
    double? waterPct,
  }) => database
      .into(database.bodyMeasurements)
      .insert(
        BodyMeasurementsCompanion.insert(
          id: 'w-${measuredAt.toIso8601String()}',
          profileId: profileId,
          weightKg: weightKg,
          measuredAt: measuredAt,
          hasImpedance: Value(bodyFatPct != null),
          bodyFatPct: Value(bodyFatPct),
          waterPct: Value(waterPct),
          createdAt: now,
          updatedAt: now,
        ),
      );

  Future<void> addWorkout({
    required DateTime startedAt,
    DateTime? endedAt,
    int? rpe,
    bool durationSuspect = false,
    int pauseSeconds = 0,
  }) => database
      .into(database.workouts)
      .insert(
        WorkoutsCompanion.insert(
          id: 'workout-${startedAt.toIso8601String()}',
          profileId: profileId,
          startedAt: startedAt,
          endedAt: Value(endedAt),
          accumulatedPauseSeconds: Value(pauseSeconds),
          durationSuspect: Value(durationSuspect),
          rpe: Value(rpe),
          createdAt: now,
          updatedAt: now,
        ),
      );

  Future<void> addWater({required DateTime loggedAt, required int ml}) =>
      database
          .into(database.waterLogs)
          .insert(
            WaterLogsCompanion.insert(
              id: 'water-${loggedAt.toIso8601String()}-$ml',
              profileId: profileId,
              milliliters: ml,
              loggedAt: loggedAt,
              createdAt: now,
              updatedAt: now,
            ),
          );

  group('il diario', () {
    test('somma calorie e proteine per giorno civile romano', () async {
      await addMeal(eatenAt: at(sunday, hour: 8), kcal: 500, protein: 30);
      await addMeal(
        eatenAt: at(sunday, hour: 19),
        kcal: 700,
        protein: 50,
        suffix: '-b',
      );

      final snapshot = await repository.load(
        profileId: profileId,
        week: testWeek,
      );

      expect(snapshot.diary, hasLength(1));
      expect(snapshot.diary.single.kcal, closeTo(1200, 0.001));
      expect(snapshot.diary.single.proteinGrams, closeTo(80, 0.001));
    });

    test('le 23:30 UTC di domenica sono già lunedì a Roma', () async {
      await addMeal(
        eatenAt: DateTime.utc(2026, 8, 2, 23, 30),
        kcal: 500,
        protein: 30,
      );

      final snapshot = await repository.load(
        profileId: profileId,
        week: testWeek,
      );

      // La riga si carica (la finestra è generosa) ma cade fuori settimana.
      expect(snapshot.diaryIn(testWeek), isEmpty);
    });

    test('un pasto cancellato non conta', () async {
      await addMeal(eatenAt: at(sunday), kcal: 500, protein: 30);
      await (database.update(database.meals)
            ..where((row) => row.profileId.equals(profileId)))
          .write(MealsCompanion(deletedAt: Value(now)));

      final snapshot = await repository.load(
        profileId: profileId,
        week: testWeek,
      );

      expect(snapshot.diary, isEmpty);
    });

    test('un giorno senza pasti non compare come zero', () async {
      await addMeal(eatenAt: at(sunday), kcal: 500, protein: 30);

      final snapshot = await repository.load(
        profileId: profileId,
        week: testWeek,
      );

      expect(snapshot.diaryIn(testWeek), hasLength(1));
    });
  });

  group('le pesate', () {
    test('portano composizione e acqua, e restano grezze', () async {
      await addWeighIn(
        measuredAt: at(sunday, hour: 5),
        weightKg: 95,
        bodyFatPct: 24.5,
        waterPct: 54,
      );

      final snapshot = await repository.load(
        profileId: profileId,
        week: testWeek,
      );

      expect(snapshot.weighIns, hasLength(1));
      expect(snapshot.weighIns.single.bodyFatPct, 24.5);
      expect(snapshot.weighIns.single.waterPct, 54);
      expect(snapshot.weighIns.single.hasComposition, isTrue);
      expect(snapshot.latestFatFreeMassKg, closeTo(71.725, 0.001));
    });

    test(
      'la finestra copre quattro settimane più quella del rapporto',
      () async {
        await addWeighIn(measuredAt: at(sunday, hour: 5), weightKg: 95);
        await addWeighIn(
          measuredAt: at(sunday.subtract(const Duration(days: 34)), hour: 5),
          weightKg: 99,
        );
        await addWeighIn(
          measuredAt: at(sunday.subtract(const Duration(days: 40)), hour: 5),
          weightKg: 100,
        );

        final snapshot = await repository.load(
          profileId: profileId,
          week: testWeek,
        );

        expect(snapshot.weighIns, hasLength(2));
        expect(snapshot.weighIns.map((measurement) => measurement.weightKg), [
          99,
          95,
        ]);
      },
    );
  });

  group('gli allenamenti', () {
    test(
      'una sessione ancora aperta non è una settimana di allenamento',
      () async {
        await addWorkout(startedAt: at(sunday, hour: 16));

        final snapshot = await repository.load(
          profileId: profileId,
          week: testWeek,
        );

        expect(snapshot.sessions, isEmpty);
      },
    );

    test('la durata toglie le pause', () async {
      await addWorkout(
        startedAt: at(sunday, hour: 16),
        endedAt: at(sunday, hour: 18),
        pauseSeconds: 600,
        rpe: 8,
      );

      final snapshot = await repository.load(
        profileId: profileId,
        week: testWeek,
      );

      expect(snapshot.sessions.single.durationMinutes, 110);
      expect(snapshot.sessions.single.rpe, 8);
    });

    test(
      'una durata sospetta produce un buco, non un numero inventato',
      () async {
        await addWorkout(
          startedAt: at(sunday, hour: 8),
          endedAt: at(sunday, hour: 18),
          durationSuspect: true,
        );

        final snapshot = await repository.load(
          profileId: profileId,
          week: testWeek,
        );

        expect(snapshot.sessions, hasLength(1));
        expect(snapshot.sessions.single.durationMinutes, isNull);
      },
    );
  });

  group('l\'acqua', () {
    test('si somma per giorno', () async {
      await addWater(loggedAt: at(sunday, hour: 9), ml: 500);
      await addWater(loggedAt: at(sunday, hour: 15), ml: 600);
      await addWater(
        loggedAt: at(sunday.subtract(const Duration(days: 1)), hour: 9),
        ml: 2000,
      );

      final snapshot = await repository.load(
        profileId: profileId,
        week: testWeek,
      );

      expect(snapshot.water, hasLength(2));
      expect(snapshot.water.last.milliliters, 1100);
    });
  });

  group('gli allenamenti previsti', () {
    test('contano i giorni con una scheda, non quelli di riposo', () async {
      await database
          .into(database.routineWeeklyPlan)
          .insert(
            RoutineWeeklyPlanCompanion.insert(
              id: 'plan-1',
              profileId: profileId,
              weekday: 1,
              routineNameSnapshot: const Value('Spinta'),
              updatedAt: now,
            ),
          );
      await database
          .into(database.routineWeeklyPlan)
          .insert(
            RoutineWeeklyPlanCompanion.insert(
              id: 'plan-2',
              profileId: profileId,
              weekday: 3,
              updatedAt: now,
            ),
          );

      expect(await repository.plannedWorkoutsPerWeek(profileId), 1);
    });
  });
}
