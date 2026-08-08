import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/database/app_database.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/profile/data/local_profile_repository.dart';
import 'package:kal_tracker/features/weekly_plan/domain/plan_workout_start.dart';
import 'package:kal_tracker/features/weekly_plan/presentation/weekly_plan_providers.dart';

void main() {
  test(
    'lo starter di default usa Drift e riprende la sessione esistente',
    () async {
      AppTime.initialize();
      final database = AppDatabase(NativeDatabase.memory());
      final profile = await LocalProfileRepository(database).getOrCreateMarco();
      final now = AppTime.nowUtc();
      await database
          .into(database.routines)
          .insert(
            RoutinesCompanion.insert(
              id: 'routine-1',
              profileId: profile.id,
              name: 'Giorno uno',
              createdAt: now,
              updatedAt: now,
            ),
          );
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final starter = container.read(planWorkoutStarterProvider)!;
      final first = await starter('routine-1');
      final second = await starter('routine-1');
      final missing = await starter('routine-assente');

      expect(first, isA<PlanWorkoutRunning>());
      expect((first as PlanWorkoutRunning).resumed, isFalse);
      expect(second, isA<PlanWorkoutRunning>());
      expect((second as PlanWorkoutRunning).workoutId, first.workoutId);
      expect(second.resumed, isTrue);
      expect(missing, isA<PlanWorkoutNotStarted>());
    },
  );
}
