import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kal_tracker/core/sync/sync_gateway.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/photo_meal/data/photo_meal_gateway.dart';
import 'package:kal_tracker/features/photo_meal/data/photo_meal_job_store.dart';
import 'package:kal_tracker/features/photo_meal/data/photo_meal_repository.dart';
import 'package:kal_tracker/features/photo_meal/domain/photo_meal_job.dart';

class _FakeGateway implements PhotoMealGateway {
  PhotoMealAccount? account = const PhotoMealAccount(userId: 'owner-1');
  bool failUpload = false;
  bool failEnqueue = false;

  final calls = <String>[];
  Map<String, Object?>? insertedRow;
  String? uploadedPath;
  Uint8List? uploadedBytes;
  String? uploadedContentType;
  String? deletedPath;
  Map<String, Map<String, Object?>> remoteRows = {};

  @override
  Future<PhotoMealAccount?> currentAccount() async {
    calls.add('account');
    return account;
  }

  @override
  Future<String> ensureRemoteProfile(String localProfileId) async {
    calls.add('profile');
    return 'remote-profile-1';
  }

  @override
  Future<void> uploadPhoto({
    required String storageObject,
    required Uint8List bytes,
    required String contentType,
  }) async {
    calls.add('upload');
    if (failUpload) {
      throw const PhotoMealException('Connessione assente.', retryable: true);
    }
    uploadedPath = storageObject;
    uploadedBytes = bytes;
    uploadedContentType = contentType;
  }

  @override
  Future<void> deletePhoto(String storageObject) async {
    calls.add('delete');
    deletedPath = storageObject;
  }

  @override
  Future<void> enqueueJob(Map<String, Object?> row) async {
    calls.add('enqueue');
    if (failEnqueue) {
      throw const PhotoMealException('Il server ha rifiutato la richiesta.');
    }
    insertedRow = row;
  }

  @override
  Future<Map<String, Map<String, Object?>>> fetchJobRows(
    List<String> jobIds,
  ) async {
    calls.add('fetch');
    return {for (final id in jobIds) id: ?remoteRows[id]};
  }
}

void main() {
  late Directory tempDir;
  late _FakeGateway gateway;
  late FilePhotoMealJobStore store;

  final day = DateTime(2026, 8, 3);
  final photoBytes = _tinyJpeg();

  PhotoMealRepository repository({Uint8List? picked, bool cancelPick = false}) {
    return PhotoMealRepository(
      gateway: gateway,
      store: store,
      pickPhoto: (source) async => cancelPick ? null : (picked ?? photoBytes),
      generateId: () => 'job-0000-1111',
      now: () => DateTime.utc(2026, 8, 3, 12, 30),
    );
  }

  setUp(() async {
    AppTime.initialize();
    tempDir = await Directory.systemTemp.createTemp('photo-meal-test');
    gateway = _FakeGateway();
    store = FilePhotoMealJobStore(stateDirectory: () async => tempDir);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test(
    'carica la foto e poi accoda il job, nell\'ordine del contratto',
    () async {
      final job = await repository().captureAndEnqueue(
        source: PhotoMealSource.camera,
        profileId: 'profile-local',
        mealType: MealType.lunch,
        day: day,
        note: '  Piatto unico  ',
      );

      expect(gateway.calls, ['account', 'profile', 'upload', 'enqueue']);
      expect(
        gateway.calls.indexOf('upload'),
        lessThan(gateway.calls.indexOf('enqueue')),
      );

      final row = gateway.insertedRow!;
      // SOLO le 10 colonne concesse dal grant, nessuna in più.
      expect(row.keys.toSet(), {
        'id',
        'owner_id',
        'profile_id',
        'storage_object',
        'image_sha256',
        'image_size_bytes',
        'image_mime_type',
        'requested_meal_type',
        'user_note',
        'last_mutation_id',
      });
      expect(row['id'], 'job-0000-1111');
      expect(row['owner_id'], 'owner-1');
      expect(row['profile_id'], 'remote-profile-1');
      expect(row['storage_object'], 'owner-1/job-0000-1111/meal.jpg');
      expect(row['storage_object'], gateway.uploadedPath);
      expect(row['image_mime_type'], 'image/jpeg');
      expect(row['requested_meal_type'], 'lunch');
      expect(row['user_note'], 'Piatto unico');
      expect(SyncIds.isUuid(row['last_mutation_id'] as String), isTrue);
      // sha256 e dimensione riferiti agli STESSI byte caricati sullo Storage.
      expect(row['image_size_bytes'], gateway.uploadedBytes!.length);
      expect(
        row['image_sha256'],
        sha256.convert(gateway.uploadedBytes!).toString(),
      );
      expect(gateway.uploadedContentType, 'image/jpeg');

      expect(job, isNotNull);
      expect(job!.status, PhotoMealJobStatus.queued);
      expect(job.mealType, MealType.lunch);
      expect(DiaryDay.isSameDay(job.day, day), isTrue);
    },
  );

  test('se l\'upload fallisce il job NON viene accodato né salvato', () async {
    gateway.failUpload = true;

    await expectLater(
      repository().captureAndEnqueue(
        source: PhotoMealSource.gallery,
        profileId: 'profile-local',
        mealType: MealType.dinner,
        day: day,
      ),
      throwsA(isA<PhotoMealException>()),
    );

    expect(gateway.calls, isNot(contains('enqueue')));
    expect(gateway.insertedRow, isNull);
    expect(await store.readJobs(), isEmpty);
  });

  test('se l\'insert fallisce la foto orfana viene ripulita', () async {
    gateway.failEnqueue = true;

    await expectLater(
      repository().captureAndEnqueue(
        source: PhotoMealSource.camera,
        profileId: 'profile-local',
        mealType: MealType.snack,
        day: day,
      ),
      throwsA(isA<PhotoMealException>()),
    );

    expect(gateway.calls.last, 'delete');
    expect(gateway.deletedPath, 'owner-1/job-0000-1111/meal.jpg');
    expect(await store.readJobs(), isEmpty);
  });

  test(
    'senza sessione la foto non parte e il messaggio invita ad accedere',
    () async {
      gateway.account = null;

      await expectLater(
        repository().captureAndEnqueue(
          source: PhotoMealSource.camera,
          profileId: 'profile-local',
          mealType: MealType.breakfast,
          day: day,
        ),
        throwsA(
          isA<PhotoMealException>()
              .having((e) => e.authRequired, 'authRequired', isTrue)
              .having(
                (e) => e.message,
                'message',
                contains('Progressi → Sincronizzazione'),
              ),
        ),
      );
      // Il controllo avviene PRIMA di aprire camera/galleria e upload.
      expect(gateway.calls, ['account']);
    },
  );

  test('se Marco annulla la scelta non succede nulla', () async {
    final job = await repository(cancelPick: true).captureAndEnqueue(
      source: PhotoMealSource.gallery,
      profileId: 'profile-local',
      mealType: MealType.lunch,
      day: day,
    );

    expect(job, isNull);
    expect(gateway.calls, ['account']);
    expect(await store.readJobs(), isEmpty);
  });

  test('lo stato del job sopravvive al riavvio (file JSON)', () async {
    await repository().captureAndEnqueue(
      source: PhotoMealSource.camera,
      profileId: 'profile-local',
      mealType: MealType.lunch,
      day: day,
    );

    // "Riavvio": store e repository nuovi sulla stessa cartella.
    final rebornStore = FilePhotoMealJobStore(
      stateDirectory: () async => tempDir,
    );
    final jobs = await rebornStore.readJobs();

    expect(jobs, hasLength(1));
    final job = jobs.single;
    expect(job.id, 'job-0000-1111');
    expect(job.profileId, 'profile-local');
    expect(job.mealType, MealType.lunch);
    expect(job.status, PhotoMealJobStatus.queued);
    expect(job.storageObject, 'owner-1/job-0000-1111/meal.jpg');
    expect(DiaryDay.isSameDay(job.day, day), isTrue);
  });

  test('il refresh aggiorna gli stati e scarta i job confermati', () async {
    await repository().captureAndEnqueue(
      source: PhotoMealSource.camera,
      profileId: 'profile-local',
      mealType: MealType.lunch,
      day: day,
    );
    gateway.remoteRows = {
      'job-0000-1111': {
        'id': 'job-0000-1111',
        'status': 'needs_review',
        'error_code': null,
        'attempt_count': 1,
        'analysis_result': {'foods': <Object?>[]},
      },
    };

    final updated = await repository().refreshJobStatuses();

    expect(updated.single.status, PhotoMealJobStatus.needsReview);
    expect(updated.single.attemptCount, 1);
    expect(updated.single.analysisResult, {'foods': <Object?>[]});
    // Persistito: un nuovo store rilegge lo stato aggiornato.
    final persisted = await FilePhotoMealJobStore(
      stateDirectory: () async => tempDir,
    ).readJobs();
    expect(persisted.single.status, PhotoMealJobStatus.needsReview);

    // claimed → in analisi.
    gateway.remoteRows['job-0000-1111']!['status'] = 'claimed';
    final claimed = await repository().refreshJobStatuses();
    expect(claimed.single.status, PhotoMealJobStatus.processing);

    // confirmed → il job locale si può dimenticare.
    gateway.remoteRows['job-0000-1111']!['status'] = 'confirmed';
    final confirmed = await repository().refreshJobStatuses();
    expect(confirmed, isEmpty);
    expect(await store.readJobs(), isEmpty);
  });

  test('removeJob toglie solo il job indicato', () async {
    await repository().captureAndEnqueue(
      source: PhotoMealSource.camera,
      profileId: 'profile-local',
      mealType: MealType.lunch,
      day: day,
    );

    final remaining = await repository().removeJob('job-0000-1111');

    expect(remaining, isEmpty);
    expect(await store.readJobs(), isEmpty);
  });
}

Uint8List _tinyJpeg() {
  final image = img.Image(width: 64, height: 48);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      image.setPixelRgb(x, y, (x * 3) % 256, (y * 11) % 256, (x + y) % 256);
    }
  }
  return img.encodeJpg(image, quality: 90);
}
