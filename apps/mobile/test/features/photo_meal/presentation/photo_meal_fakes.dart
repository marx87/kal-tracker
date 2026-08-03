import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/photo_meal/data/photo_meal_job_store.dart';
import 'package:kal_tracker/features/photo_meal/domain/photo_meal_job.dart'
    as domain;
import 'package:kal_tracker/features/photo_meal/presentation/meal_analysis_result.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_jobs_gateway.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_meal_job.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_review_local_store.dart';

/// Gateway finto: risponde con le liste in sequenza (l'ultima si ripete).
class FakePhotoJobsGateway implements PhotoJobsGateway {
  FakePhotoJobsGateway(this.responses);

  final List<List<PhotoMealJob>> responses;
  int fetchCount = 0;
  final List<String> deletedPhotos = [];
  Object? fetchError;
  Object? deleteError;

  @override
  Future<List<PhotoMealJob>> fetchJobs({int limit = 30}) async {
    fetchCount++;
    if (fetchError case final error?) {
      throw error;
    }
    final index = fetchCount - 1;
    return responses[index < responses.length ? index : responses.length - 1];
  }

  @override
  Future<PhotoMealJob?> fetchJob(String jobId) async {
    if (fetchError case final error?) {
      throw error;
    }
    for (final job in responses.last) {
      if (job.id == jobId) {
        return job;
      }
    }
    return null;
  }

  @override
  Future<void> deletePhoto(String storageObject) async {
    if (deleteError case final error?) {
      throw error;
    }
    deletedPhotos.add(storageObject);
  }
}

/// Registro locale in memoria: niente file system nei test widget.
class InMemoryPhotoReviewLocalStore implements PhotoReviewLocalStore {
  final Map<String, String> outcomes = {};
  final List<String> pendingDeletes = [];
  Object? markHandledError;

  @override
  Future<Set<String>> handledJobIds() async => outcomes.keys.toSet();

  @override
  Future<void> markHandled({
    required String jobId,
    required String outcome,
  }) async {
    if (markHandledError case final error?) {
      throw error;
    }
    outcomes[jobId] = outcome;
  }

  @override
  Future<void> unmarkHandled({required String jobId}) async {
    outcomes.remove(jobId);
  }

  @override
  Future<List<String>> pendingPhotoDeletes() async => [...pendingDeletes];

  @override
  Future<void> addPendingPhotoDelete(String storageObject) async {
    if (!pendingDeletes.contains(storageObject)) {
      pendingDeletes.add(storageObject);
    }
  }

  @override
  Future<void> removePendingPhotoDelete(String storageObject) async {
    pendingDeletes.remove(storageObject);
  }
}

/// Registro in memoria dei job seguiti dal diario (file JSON in produzione).
class InMemoryPhotoMealJobStore implements PhotoMealJobStore {
  InMemoryPhotoMealJobStore([List<domain.PhotoMealJob>? seed])
    : jobs = [...?seed];

  List<domain.PhotoMealJob> jobs;

  @override
  Future<List<domain.PhotoMealJob>> readJobs() async => List.unmodifiable(jobs);

  @override
  Future<void> writeJobs(List<domain.PhotoMealJob> value) async {
    jobs = [...value];
  }
}

/// Job del registro locale del diario (conserva giorno e pasto richiesti).
domain.PhotoMealJob buildLocalJob({
  String id = 'job-1',
  MealType mealType = MealType.lunch,
  DateTime? day,
  domain.PhotoMealJobStatus status = domain.PhotoMealJobStatus.needsReview,
}) => domain.PhotoMealJob(
  id: id,
  profileId: 'profile-local',
  mealType: mealType,
  day: day ?? DiaryDay.instantFor(AppTime.nowInRome()),
  createdAt: AppTime.nowUtc(),
  storageObject: 'owner-1/$id/meal.jpg',
  status: status,
);

MealAnalysisFood buildFood({
  String name = 'Riso basmati',
  List<String> alternatives = const ['Riso venere'],
  double minimumGrams = 100,
  double suggestedGrams = 150,
  double maximumGrams = 250,
  double confidence = 0.8,
  String preparation = 'boiled',
  List<String> hiddenIngredients = const ['olio'],
  String uncertainty = 'Porzione stimata dal piatto.',
}) => MealAnalysisFood(
  name: name,
  alternatives: alternatives,
  minimumGrams: minimumGrams,
  suggestedGrams: suggestedGrams,
  maximumGrams: maximumGrams,
  confidence: confidence,
  preparation: preparation,
  hiddenIngredients: hiddenIngredients,
  uncertainty: uncertainty,
);

PhotoMealJob buildReviewJob({
  String id = 'job-1',
  List<MealAnalysisFood>? foods,
  String requestedMealType = 'lunch',
}) => PhotoMealJob(
  id: id,
  status: PhotoMealJobStatus.needsReview,
  storageObject: 'owner-1/$id/meal.jpg',
  result: MealAnalysisResult(
    foods: foods ?? [buildFood()],
    questions: const ['Riso in bianco o condito?'],
    overallConfidence: 0.7,
    notes: 'Piatto unico.',
  ),
  requestedMealType: requestedMealType,
);

PhotoMealJob buildActiveJob({
  String id = 'job-1',
  PhotoMealJobStatus status = PhotoMealJobStatus.queued,
  int attemptCount = 0,
}) => PhotoMealJob(
  id: id,
  status: status,
  storageObject: 'owner-1/$id/meal.jpg',
  attemptCount: attemptCount,
);
