import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/photo_meal/data/photo_meal_job_store.dart';
import 'package:kal_tracker/features/photo_meal/domain/photo_meal_job.dart';

void main() {
  late Directory tempDir;
  late FilePhotoMealJobStore store;

  setUp(() async {
    AppTime.initialize();
    tempDir = await Directory.systemTemp.createTemp('photo-job-store-test');
    store = FilePhotoMealJobStore(stateDirectory: () async => tempDir);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('senza file lo store risponde con lista vuota', () async {
    expect(await store.readJobs(), isEmpty);
  });

  test('un file corrotto non fa cadere l\'app: lista vuota', () async {
    final file = File('${tempDir.path}/${FilePhotoMealJobStore.stateFileName}');
    await file.writeAsString('{"jobs": [{"id": 42}], nonsense');

    expect(await store.readJobs(), isEmpty);
  });

  test('una voce corrotta si scarta senza perdere le altre', () async {
    final good = PhotoMealJob(
      id: 'job-1',
      profileId: 'profile-1',
      mealType: MealType.dinner,
      day: DateTime.utc(2026, 8, 3, 10),
      createdAt: DateTime.utc(2026, 8, 3, 10, 5),
      storageObject: 'owner/job-1/meal.jpg',
      status: PhotoMealJobStatus.processing,
      errorCode: null,
      attemptCount: 2,
    );
    await store.writeJobs([good]);
    final file = File('${tempDir.path}/${FilePhotoMealJobStore.stateFileName}');
    final contents = await file.readAsString();
    await file.writeAsString(
      contents.replaceFirst('[', '[{"id": null, "meal_type": 3},'),
    );

    final jobs = await store.readJobs();

    expect(jobs, hasLength(1));
    expect(jobs.single.id, 'job-1');
    expect(jobs.single.status, PhotoMealJobStatus.processing);
    expect(jobs.single.attemptCount, 2);
    expect(jobs.single.mealType, MealType.dinner);
  });
}
