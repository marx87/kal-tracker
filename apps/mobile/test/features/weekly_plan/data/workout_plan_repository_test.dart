// `Value` di drift serve alle companion; i matcher vengono da flutter_test,
// quindi l'import di drift nasconde quelli che collidono (`isNull`).
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/weekly_plan/data/workout_plan_repository.dart';
import 'package:kal_tracker/features/weekly_plan/domain/plan_week.dart';

void main() {
  late AppDatabase database;
  late LocalProfile profile;
  late WorkoutPlanRepository repository;

  final now = DateTime.utc(2026, 8, 4, 9);

  Future<void> addRoutine(
    String id,
    String name, {
    bool isCircuit = false,
    int mainExercises = 0,
    bool deleted = false,
  }) async {
    await database
        .into(database.routines)
        .insert(
          RoutinesCompanion.insert(
            id: id,
            profileId: profile.id,
            name: name,
            isCircuit: Value(isCircuit),
            createdAt: now,
            updatedAt: now,
            deletedAt: Value(deleted ? now : null),
          ),
        );
    for (var position = 0; position < mainExercises; position++) {
      await database
          .into(database.routineExercises)
          .insert(
            RoutineExercisesCompanion.insert(
              id: '$id-ex-$position',
              routineId: id,
              block: 'main',
              position: position,
              exerciseRefId: 'exercise-$position',
              exerciseNameSnapshot: 'Esercizio $position',
            ),
          );
    }
  }

  Future<void> planDay(int weekday, {String? routineId, String? snapshot}) =>
      database
          .into(database.routineWeeklyPlan)
          .insert(
            RoutineWeeklyPlanCompanion.insert(
              id: 'rwp-$weekday',
              profileId: profile.id,
              weekday: weekday,
              routineId: Value(routineId),
              // Il CHECK del database pretende che l'id esterno coincida con la
              // chiave esterna quando c'è: sono lo stesso identificatore.
              routineExternalId: Value(routineId),
              routineNameSnapshot: Value(snapshot),
              updatedAt: now,
            ),
          );

  /// Una sessione chiusa: il database ne ammette UNA sola aperta per profilo
  /// (`idx_workouts_one_active`), quindi lo storico va chiuso.
  Future<void> addWorkout(String id, DateTime startedAt) => database
      .into(database.workouts)
      .insert(
        WorkoutsCompanion.insert(
          id: id,
          profileId: profile.id,
          startedAt: startedAt,
          endedAt: Value(startedAt.add(const Duration(minutes: 50))),
          createdAt: now,
          updatedAt: now,
        ),
      );

  setUp(() async {
    AppTime.initialize();
    database = AppDatabase(NativeDatabase.memory());
    profile = await LocalProfileRepository(database).getOrCreateMarco();
    repository = WorkoutPlanRepository(database);
  });

  tearDown(() => database.close());

  test(
    'la settimana torna in ordine di giorno, con gli esercizi contati',
    () async {
      await addRoutine('routine-gambe', 'Gambe', mainExercises: 5);
      await addRoutine('routine-hiit', 'Circuito', isCircuit: true);
      await planDay(5, routineId: 'routine-hiit', snapshot: 'Circuito');
      await planDay(2, routineId: 'routine-gambe', snapshot: 'Gambe');

      final workouts = await repository.plannedWorkouts(profile.id);

      expect(workouts.map((workout) => workout.weekday), [2, 5]);
      expect(workouts.first.routineName, 'Gambe');
      expect(workouts.first.exerciseCount, 5);
      expect(workouts.first.isCircuit, isFalse);
      expect(workouts.first.isMissing, isFalse);
      expect(workouts.last.isCircuit, isTrue);
      expect(workouts.last.exerciseCount, 0);
    },
  );

  test('la scheda cancellata lascia il giorno e il suo nome', () async {
    // Nell'export di Gym succede davvero: un giorno punta a una scheda che
    // non esiste più. Il giorno resta, ma non c'è niente da avviare.
    await addRoutine('routine-vecchia', 'Vecchia', deleted: true);
    await planDay(3, routineId: 'routine-vecchia', snapshot: 'Vecchia');

    final workouts = await repository.plannedWorkouts(profile.id);

    expect(workouts.single.routineName, 'Vecchia');
    expect(workouts.single.isMissing, isTrue);
  });

  test('lo stream si aggiorna quando la settimana cambia', () async {
    await addRoutine('routine-gambe', 'Gambe', mainExercises: 2);
    final emissions = <List<PlannedWorkout>>[];
    final subscription = repository
        .watchPlannedWorkouts(profile.id)
        .listen(emissions.add);
    await pumpEventQueue();

    await planDay(4, routineId: 'routine-gambe', snapshot: 'Gambe');
    await pumpEventQueue();
    await subscription.cancel();

    expect(emissions.first, isEmpty);
    expect(emissions.last.single.routineName, 'Gambe');
    expect(emissions.last.single.exerciseCount, 2);
  });

  test('l’ora di allenamento è la mediana delle sessioni vere', () async {
    // Istanti UTC: d'estate a Roma sono due ore più tardi.
    await addWorkout('w-1', DateTime.utc(2026, 8, 1, 16));
    await addWorkout('w-2', DateTime.utc(2026, 8, 2, 16, 30));
    await addWorkout('w-3', DateTime.utc(2026, 8, 3, 5));

    expect(await repository.trainingHour(profile.id), 18);
  });

  test('senza sessioni non si dichiara nessun orario', () async {
    expect(await repository.trainingHour(profile.id), isNull);
  });
}
