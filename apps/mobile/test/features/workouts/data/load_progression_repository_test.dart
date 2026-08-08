import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/features/training_profile/domain/training_profile.dart';
import 'package:kal_tracker/features/workouts/data/load_progression_repository.dart';
import 'package:kal_tracker/features/workouts/domain/load_progression.dart';

import '../history/workout_history_fixtures.dart';

void main() {
  late AppDatabase database;
  late LoadProgressionRepository repository;
  late String profileId;

  setUp(() async {
    database = AppDatabase(NativeDatabase.memory());
    profileId = await seedProfile(database);
    repository = LoadProgressionRepository(database);
    await seedExercise(
      database,
      id: 'panca',
      profileId: profileId,
      name: 'Panca piana con manubri',
    );
  });

  tearDown(() => database.close());

  /// Una seduta con un esercizio solo e le serie che le si passano.
  Future<void> seedSession({
    required String id,
    required DateTime startedAt,
    DateTime? endedAt,
    String exerciseRefId = 'panca',
    bool isWarmupBlock = false,
    List<({double weight, int reps, bool warmup, bool completed})> sets =
        const [],
  }) async {
    await seedWorkout(
      database,
      id: id,
      profileId: profileId,
      startedAt: startedAt,
      endedAt: endedAt ?? startedAt.add(const Duration(minutes: 50)),
    );
    await seedWorkoutExercise(
      database,
      id: '$id-ex',
      workoutId: id,
      position: 0,
      name: 'Panca piana con manubri',
      exerciseRefId: exerciseRefId,
      isWarmup: isWarmupBlock,
    );
    for (final (index, set) in sets.indexed) {
      await seedSet(
        database,
        id: '$id-s$index',
        workoutExerciseId: '$id-ex',
        position: index,
        weightKg: set.weight,
        reps: set.reps,
        isWarmup: set.warmup,
        completed: set.completed,
      );
    }
  }

  test('porta le serie dell\'ultima seduta, non quelle di prima', () async {
    await seedSession(
      id: 'vecchia',
      startedAt: DateTime.utc(2026, 7, 1, 18),
      sets: const [
        (weight: 16, reps: 8, warmup: false, completed: true),
        (weight: 16, reps: 8, warmup: false, completed: true),
      ],
    );
    await seedSession(
      id: 'ultima',
      startedAt: DateTime.utc(2026, 8, 1, 18),
      sets: const [
        (weight: 18, reps: 12, warmup: false, completed: true),
        (weight: 18, reps: 12, warmup: false, completed: true),
      ],
    );

    final sets = await repository.lastWorkSets(
      profileId: profileId,
      exerciseRefIds: const ['panca'],
    );

    expect(sets['panca'], hasLength(2));
    expect(sets['panca']!.map((set) => set.weightKg), [18, 18]);
    expect(sets['panca']!.map((set) => set.reps), [12, 12]);
  });

  test('una seduta ancora aperta non è l\'ultima seduta', () async {
    await seedSession(
      id: 'chiusa',
      startedAt: DateTime.utc(2026, 8, 1, 18),
      sets: const [(weight: 18, reps: 10, warmup: false, completed: true)],
    );
    await seedWorkout(
      database,
      id: 'in-corso',
      profileId: profileId,
      startedAt: DateTime.utc(2026, 8, 5, 18),
    );
    await seedWorkoutExercise(
      database,
      id: 'in-corso-ex',
      workoutId: 'in-corso',
      position: 0,
      name: 'Panca piana con manubri',
      exerciseRefId: 'panca',
    );
    await seedSet(
      database,
      id: 'in-corso-s0',
      workoutExerciseId: 'in-corso-ex',
      position: 0,
      weightKg: 20,
      reps: 12,
    );

    final sets = await repository.lastWorkSets(
      profileId: profileId,
      exerciseRefIds: const ['panca'],
    );

    expect(
      sets['panca']!.single.weightKg,
      18,
      reason:
          'la seduta in corso non è finita: proporre un gradino lì '
          'vorrebbe dire leggerla a metà',
    );
  });

  test('una seduta cancellata non conta', () async {
    await seedSession(
      id: 'cancellata',
      startedAt: DateTime.utc(2026, 8, 4, 18),
      sets: const [(weight: 24, reps: 12, warmup: false, completed: true)],
    );
    await database.customStatement(
      'UPDATE workouts SET deleted_at = ? WHERE id = ?',
      [DateTime.utc(2026, 8, 5).millisecondsSinceEpoch ~/ 1000, 'cancellata'],
    );
    await seedSession(
      id: 'buona',
      startedAt: DateTime.utc(2026, 8, 1, 18),
      sets: const [(weight: 18, reps: 10, warmup: false, completed: true)],
    );

    final sets = await repository.lastWorkSets(
      profileId: profileId,
      exerciseRefIds: const ['panca'],
    );

    expect(sets['panca']!.single.weightKg, 18);
  });

  test('il blocco di riscaldamento resta fuori, la serie leggera no', () async {
    await seedSession(
      id: 'riscaldamento',
      startedAt: DateTime.utc(2026, 8, 4, 18),
      isWarmupBlock: true,
      sets: const [(weight: 8, reps: 15, warmup: false, completed: true)],
    );
    await seedSession(
      id: 'lavoro',
      startedAt: DateTime.utc(2026, 8, 1, 18),
      sets: const [
        // Una serie di avvicinamento dentro un blocco di lavoro arriva
        // eccome: a scartarla — dichiarandolo — è la progressione.
        (weight: 10, reps: 12, warmup: true, completed: true),
        (weight: 18, reps: 10, warmup: false, completed: true),
      ],
    );

    final sets = await repository.lastWorkSets(
      profileId: profileId,
      exerciseRefIds: const ['panca'],
    );

    expect(sets['panca'], hasLength(2));
    expect(sets['panca']!.first.isWarmup, isTrue);
  });

  test('chi non si è mai allenato non compare nella mappa', () async {
    expect(
      await repository.lastWorkSets(
        profileId: profileId,
        exerciseRefIds: const ['panca'],
      ),
      isEmpty,
    );
    expect(
      await repository.lastWorkSets(
        profileId: profileId,
        exerciseRefIds: const [],
      ),
      isEmpty,
    );
  });

  test('le serie lette bastano alla proposta di carico', () async {
    await seedSession(
      id: 'ultima',
      startedAt: DateTime.utc(2026, 8, 1, 18),
      sets: const [
        (weight: 18, reps: 12, warmup: false, completed: true),
        (weight: 18, reps: 12, warmup: false, completed: true),
        (weight: 18, reps: 12, warmup: false, completed: true),
      ],
    );

    final sets = await repository.lastWorkSets(
      profileId: profileId,
      exerciseRefIds: const ['panca'],
    );
    final advice = LoadProgression.advise(
      sets: sets['panca']!,
      range: RepRange.resolve(min: 8, max: 12),
      tools: const {Equipment.manubri},
      prescribedSets: 3,
    );

    expect(advice.verdict, ProgressionVerdict.salire);
    expect(advice.currentKg, 18);
    expect(advice.proposedKg, 20);
    expect(advice.proposedReps, 8);
  });
}
