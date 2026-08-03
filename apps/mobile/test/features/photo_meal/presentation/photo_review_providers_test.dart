import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kal_tracker/core/sync/sync_gateway.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/photo_meal/data/photo_meal_gateway.dart';
import 'package:kal_tracker/features/photo_meal/data/photo_meal_repository.dart';
import 'package:kal_tracker/features/photo_meal/domain/photo_meal_job.dart'
    show PhotoMealSource;
import 'package:kal_tracker/features/photo_meal/domain/photo_pipeline.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_jobs_gateway.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_meal_job.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_review_local_store.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_review_providers.dart';

import 'photo_meal_fakes.dart';

/// Gateway del flusso di cattura ridotto all'osso: sempre disponibile.
class _FakePhotoMealGateway implements PhotoMealGateway {
  @override
  Future<PhotoMealAccount?> currentAccount() async =>
      const PhotoMealAccount(userId: 'owner-1');

  @override
  Future<String> ensureRemoteProfile(String localProfileId) async =>
      'remote-profile-1';

  @override
  Future<void> uploadPhoto({
    required String storageObject,
    required Uint8List bytes,
    required String contentType,
  }) async {}

  @override
  Future<void> deletePhoto(String storageObject) async {}

  @override
  Future<void> enqueueJob(Map<String, Object?> row) async {}

  @override
  Future<Map<String, Map<String, Object?>>> fetchJobRows(
    List<String> jobIds,
  ) async => {};
}

ProviderContainer _container({
  required FakePhotoJobsGateway gateway,
  required InMemoryPhotoReviewLocalStore store,
  bool enabled = true,
  Duration interval = const Duration(milliseconds: 40),
  InMemoryPhotoMealJobStore? jobStore,
  PhotoMealRepository? repository,
}) => ProviderContainer(
  overrides: [
    photoJobsEnabledProvider.overrideWithValue(enabled),
    photoJobsGatewayProvider.overrideWithValue(gateway),
    photoReviewLocalStoreProvider.overrideWithValue(store),
    photoPollIntervalProvider.overrideWithValue(interval),
    if (jobStore != null) photoMealJobStoreProvider.overrideWithValue(jobStore),
    if (repository != null)
      photoMealRepositoryProvider.overrideWithValue(repository),
  ],
);

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Condizione non raggiunta entro il tempo massimo.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('esegue il polling con job attivi e si ferma quando arriva '
      'la proposta', () async {
    final gateway = FakePhotoJobsGateway([
      [buildActiveJob()],
      [buildActiveJob(status: PhotoMealJobStatus.processing)],
      [buildReviewJob()],
    ]);
    final store = InMemoryPhotoReviewLocalStore();
    final container = _container(gateway: gateway, store: store);
    addTearDown(container.dispose);
    final subscription = container.listen(
      photoJobsControllerProvider,
      (previous, next) {},
    );
    addTearDown(subscription.close);

    await _until(() => gateway.fetchCount >= 3);
    await _until(
      () =>
          container.read(photoJobsControllerProvider).readyProposals.length ==
          1,
    );
    expect(container.read(photoProposalsReadyProvider), hasLength(1));
    expect(container.read(photoJobsControllerProvider).hasActiveJobs, isFalse);

    // Senza job attivi il polling si ferma da solo.
    final settledCount = gateway.fetchCount;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(gateway.fetchCount, settledCount);
  });

  test('senza sessione non parte nessuna lettura', () async {
    final gateway = FakePhotoJobsGateway([
      [buildActiveJob()],
    ]);
    final container = _container(
      gateway: gateway,
      store: InMemoryPhotoReviewLocalStore(),
      enabled: false,
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      photoJobsControllerProvider,
      (previous, next) {},
    );
    addTearDown(subscription.close);

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(gateway.fetchCount, 0);
    expect(container.read(photoJobsControllerProvider).enabled, isFalse);
    expect(container.read(photoJobsControllerProvider).jobs, isEmpty);
  });

  test('closeJobLocally registra l’esito, pulisce la foto ed esclude '
      'il job dai giri successivi', () async {
    final job = buildReviewJob();
    final gateway = FakePhotoJobsGateway([
      [job],
    ]);
    final store = InMemoryPhotoReviewLocalStore();
    final container = _container(gateway: gateway, store: store);
    addTearDown(container.dispose);
    final subscription = container.listen(
      photoJobsControllerProvider,
      (previous, next) {},
    );
    addTearDown(subscription.close);

    await _until(
      () => container.read(photoJobsControllerProvider).jobs.length == 1,
    );

    final notifier = container.read(photoJobsControllerProvider.notifier);
    await notifier.closeJobLocally(job, outcome: 'confirmed');

    expect(store.outcomes, {'job-1': 'confirmed'});
    expect(gateway.deletedPhotos, ['owner-1/job-1/meal.jpg']);
    expect(container.read(photoJobsControllerProvider).jobs, isEmpty);

    // Il server la terrebbe in needs_review per sempre: il registro
    // locale la esclude anche dalle letture successive.
    await notifier.refreshNow();
    expect(container.read(photoJobsControllerProvider).jobs, isEmpty);
  });

  test('in background il polling tace e riparte al rientro', () async {
    final gateway = FakePhotoJobsGateway([
      [buildActiveJob()],
    ]);
    final container = _container(
      gateway: gateway,
      store: InMemoryPhotoReviewLocalStore(),
      interval: const Duration(milliseconds: 30),
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      photoJobsControllerProvider,
      (previous, next) {},
    );
    addTearDown(subscription.close);

    await _until(() => gateway.fetchCount >= 1);
    container.read(photoForegroundProvider.notifier).state = false;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final backgroundCount = gateway.fetchCount;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(gateway.fetchCount, backgroundCount);

    container.read(photoForegroundProvider.notifier).state = true;
    await _until(() => gateway.fetchCount > backgroundCount);
  });

  test('un errore di lettura non perde i job già noti e riprova', () async {
    final gateway = FakePhotoJobsGateway([
      [buildActiveJob()],
    ]);
    final store = InMemoryPhotoReviewLocalStore();
    final container = _container(gateway: gateway, store: store);
    addTearDown(container.dispose);
    final subscription = container.listen(
      photoJobsControllerProvider,
      (previous, next) {},
    );
    addTearDown(subscription.close);

    await _until(
      () => container.read(photoJobsControllerProvider).jobs.length == 1,
    );

    gateway.fetchError = const SyncGatewayException(
      'Connessione assente: riproverò più tardi.',
      retryable: true,
    );
    final failingCount = gateway.fetchCount;
    await _until(() => gateway.fetchCount > failingCount);
    await _until(
      () => container.read(photoJobsControllerProvider).error != null,
    );
    // I job attivi già visti restano: il retry continua da solo.
    expect(container.read(photoJobsControllerProvider).jobs, hasLength(1));

    gateway.fetchError = null;
    await _until(
      () => container.read(photoJobsControllerProvider).error == null,
    );
  });

  test('una delete foto fallita resta registrata e viene ritentata '
      'al poll successivo', () async {
    final job = buildReviewJob();
    final gateway = FakePhotoJobsGateway([
      [job],
    ]);
    final store = InMemoryPhotoReviewLocalStore();
    final container = _container(gateway: gateway, store: store);
    addTearDown(container.dispose);
    final subscription = container.listen(
      photoJobsControllerProvider,
      (previous, next) {},
    );
    addTearDown(subscription.close);

    await _until(
      () => container.read(photoJobsControllerProvider).jobs.length == 1,
    );

    gateway.deleteError = const SyncGatewayException(
      'Connessione assente: riproverò più tardi.',
      retryable: true,
    );
    final notifier = container.read(photoJobsControllerProvider.notifier);
    await notifier.closeJobLocally(job, outcome: 'discarded');

    // La chiusura locale vale comunque, ma la foto NON è sparita in
    // silenzio: resta nel registro delle cancellazioni da ritentare.
    expect(store.outcomes, {'job-1': 'discarded'});
    expect(gateway.deletedPhotos, isEmpty);
    expect(store.pendingDeletes, ['owner-1/job-1/meal.jpg']);

    // Tornata la rete, il giro successivo completa la promessa
    // «la foto viene tolta dal cloud».
    gateway.deleteError = null;
    await notifier.refreshNow();
    expect(gateway.deletedPhotos, ['owner-1/job-1/meal.jpg']);
    expect(store.pendingDeletes, isEmpty);
  });

  test(
    'la prima lettura fallita (offline all’avvio) riprova da sola',
    () async {
      final gateway = FakePhotoJobsGateway([
        [buildActiveJob()],
      ]);
      gateway.fetchError = const SyncGatewayException(
        'Connessione assente: riproverò più tardi.',
        retryable: true,
      );
      final container = _container(
        gateway: gateway,
        store: InMemoryPhotoReviewLocalStore(),
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        photoJobsControllerProvider,
        (previous, next) {},
      );
      addTearDown(subscription.close);

      // Con jobs=[] ed errore il timer deve riarmarsi comunque.
      await _until(() => gateway.fetchCount >= 2);
      expect(container.read(photoJobsControllerProvider).jobs, isEmpty);

      gateway.fetchError = null;
      await _until(
        () => container.read(photoJobsControllerProvider).jobs.length == 1,
      );
    },
  );

  test('dopo l’enqueue di una foto il polling parte subito', () async {
    AppTime.initialize();
    final gateway = FakePhotoJobsGateway([
      const [],
      [buildActiveJob()],
    ]);
    final repository = PhotoMealRepository(
      gateway: _FakePhotoMealGateway(),
      store: InMemoryPhotoMealJobStore(),
      pickPhoto: (source) async => Uint8List.fromList([1, 2, 3]),
      process: (bytes) => ProcessedMealPhoto(
        bytes: bytes,
        mimeType: 'image/jpeg',
        width: 4,
        height: 4,
        sha256Hex: 'a' * 64,
      ),
    );
    final container = _container(
      gateway: gateway,
      store: InMemoryPhotoReviewLocalStore(),
      repository: repository,
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      photoJobsControllerProvider,
      (previous, next) {},
    );
    addTearDown(subscription.close);

    // Nessun job attivo: dopo la prima lettura il polling tace.
    await _until(() => gateway.fetchCount >= 1);
    final settledCount = gateway.fetchCount;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(gateway.fetchCount, settledCount);

    // La cattura accoda la foto: la lettura riparte senza aspettare
    // un riavvio o un cambio di lifecycle.
    await container
        .read(photoMealJobsProvider.notifier)
        .capture(
          source: PhotoMealSource.camera,
          profileId: 'profile-local',
          mealType: MealType.lunch,
          day: AppTime.nowInRome(),
        );
    await _until(() => gateway.fetchCount > settledCount);
    await _until(
      () => container.read(photoJobsControllerProvider).hasActiveJobs,
    );
  });

  test(
    'la chiusura locale toglie il job anche dal registro del diario',
    () async {
      AppTime.initialize();
      final job = buildReviewJob();
      final gateway = FakePhotoJobsGateway([
        [job],
      ]);
      final store = InMemoryPhotoReviewLocalStore();
      final jobStore = InMemoryPhotoMealJobStore([buildLocalJob()]);
      final container = _container(
        gateway: gateway,
        store: store,
        jobStore: jobStore,
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        photoJobsControllerProvider,
        (previous, next) {},
      );
      addTearDown(subscription.close);

      await _until(
        () => container.read(photoJobsControllerProvider).jobs.length == 1,
      );

      await container
          .read(photoJobsControllerProvider.notifier)
          .closeJobLocally(job, outcome: 'confirmed');

      // Niente riga «proposta pronta da rivedere» per sempre nel diario e
      // niente file che cresce senza limite: il registro locale si svuota.
      expect(jobStore.jobs, isEmpty);
      final tracked = await container.read(photoMealJobsProvider.future);
      expect(tracked, isEmpty);
    },
  );
}
