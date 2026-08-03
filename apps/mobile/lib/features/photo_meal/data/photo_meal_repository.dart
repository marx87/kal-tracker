import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/sync/sync_gateway.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/domain/diary_models.dart';
import 'package:kal_tracker/features/photo_meal/data/photo_meal_gateway.dart';
import 'package:kal_tracker/features/photo_meal/data/photo_meal_job_store.dart';
import 'package:kal_tracker/features/photo_meal/data/photo_meal_picker.dart';
import 'package:kal_tracker/features/photo_meal/domain/photo_meal_job.dart';
import 'package:kal_tracker/features/photo_meal/domain/photo_pipeline.dart';
import 'package:uuid/uuid.dart';

typedef PhotoMealPickPhoto =
    Future<Uint8List?> Function(PhotoMealSource source);
typedef PhotoMealProcess = ProcessedMealPhoto Function(Uint8List bytes);

/// Orchestrazione cattura → pipeline → upload → enqueue → stato locale.
/// L'AI propone e Marco conferma: qui NULLA entra nel diario, si accoda
/// solo la richiesta di analisi (il job remoto si ferma a needs_review).
class PhotoMealRepository {
  PhotoMealRepository({
    required this._gateway,
    required this._store,
    PhotoMealPickPhoto? pickPhoto,
    PhotoMealProcess? process,
    String Function()? generateId,
    DateTime Function()? now,
  }) : _pickPhoto = pickPhoto ?? pickMealPhotoWithImagePicker,
       _process = process ?? MealPhotoPipeline.process,
       _generateId = generateId ?? _uuidV4,
       _now = now ?? AppTime.nowUtc;

  static const String photoFileName = 'meal.jpg';
  static const int maxUserNoteChars = 500;

  final PhotoMealGateway _gateway;
  final PhotoMealJobStore _store;
  final PhotoMealPickPhoto _pickPhoto;
  final PhotoMealProcess _process;
  final String Function() _generateId;
  final DateTime Function() _now;

  static String _uuidV4() => const Uuid().v4();

  /// Scatta o sceglie la foto e accoda il job. Ritorna null se Marco
  /// annulla la scelta. La sessione si verifica PRIMA di aprire la camera.
  Future<PhotoMealJob?> captureAndEnqueue({
    required PhotoMealSource source,
    required String profileId,
    required MealType mealType,
    required DateTime day,
    String? note,
  }) async {
    final account = await _requireAccount();
    final original = await _pickPhoto(source);
    if (original == null) {
      return null;
    }
    return _enqueueBytes(
      account: account,
      original: original,
      profileId: profileId,
      mealType: mealType,
      day: day,
      note: note,
    );
  }

  /// Variante con i byte già in mano (test e riusi futuri).
  Future<PhotoMealJob> enqueueBytes({
    required Uint8List original,
    required String profileId,
    required MealType mealType,
    required DateTime day,
    String? note,
  }) async {
    final account = await _requireAccount();
    return _enqueueBytes(
      account: account,
      original: original,
      profileId: profileId,
      mealType: mealType,
      day: day,
      note: note,
    );
  }

  Future<List<PhotoMealJob>> loadJobs() => _store.readJobs();

  /// Poll dello stato remoto per i job seguiti localmente. I job arrivati
  /// a `confirmed` spariscono dal file; se il server non risponde lo stato
  /// locale resta com'è (local-first: mai bloccare per la rete).
  Future<List<PhotoMealJob>> refreshJobStatuses() async {
    final jobs = await _store.readJobs();
    final trackedIds = [for (final job in jobs) job.id];
    if (trackedIds.isEmpty) {
      return jobs;
    }
    final rows = await _gateway.fetchJobRows(trackedIds);
    final updated = <PhotoMealJob>[];
    for (final job in jobs) {
      final row = rows[job.id];
      if (row == null) {
        updated.add(job);
        continue;
      }
      final status =
          PhotoMealJobStatus.tryFromRemote(row['status']) ?? job.status;
      if (status == PhotoMealJobStatus.confirmed) {
        continue;
      }
      final analysisResult = row['analysis_result'];
      updated.add(
        PhotoMealJob(
          id: job.id,
          profileId: job.profileId,
          mealType: job.mealType,
          day: job.day,
          createdAt: job.createdAt,
          storageObject: job.storageObject,
          status: status,
          userNote: job.userNote,
          errorCode: row['error_code'] is String
              ? row['error_code'] as String
              : null,
          attemptCount: row['attempt_count'] is num
              ? (row['attempt_count'] as num).toInt()
              : job.attemptCount,
          analysisResult: analysisResult is Map
              ? Map<String, Object?>.from(analysisResult)
              : job.analysisResult,
        ),
      );
    }
    await _store.writeJobs(updated);
    return updated;
  }

  /// Toglie un job dal file locale (dopo la conferma nel diario o quando
  /// Marco decide di ignorarne l'esito). Il job remoto resta com'è: il
  /// client non ha UPDATE su meal_analysis_jobs in v0.2.
  Future<List<PhotoMealJob>> removeJob(String jobId) async {
    final jobs = await _store.readJobs();
    final remaining = [
      for (final job in jobs)
        if (job.id != jobId) job,
    ];
    await _store.writeJobs(remaining);
    return remaining;
  }

  Future<PhotoMealJob> _enqueueBytes({
    required PhotoMealAccount account,
    required Uint8List original,
    required String profileId,
    required MealType mealType,
    required DateTime day,
    String? note,
  }) async {
    // sha256/size si calcolano sui byte FINALI post riduzione ed EXIF-strip:
    // il worker verifica l'identità esatta di ciò che scarica.
    final processed = _process(original);
    final jobId = _generateId();
    final storageObject = '${account.userId}/$jobId/$photoFileName';
    final userNote = _cleanNote(note);
    final remoteProfileId = await _gateway.ensureRemoteProfile(profileId);
    // Ordine obbligato dal contratto: prima la foto sullo Storage,
    // poi la riga del job (il CHECK sul percorso pretende owner/job già noti).
    await _gateway.uploadPhoto(
      storageObject: storageObject,
      bytes: processed.bytes,
      contentType: processed.mimeType,
    );
    try {
      // SOLO le 10 colonne concesse dal grant: qualsiasi altra colonna
      // (anche con il valore di default) produce 42501.
      await _gateway.enqueueJob({
        'id': jobId,
        'owner_id': account.userId,
        'profile_id': remoteProfileId,
        'storage_object': storageObject,
        'image_sha256': processed.sha256Hex,
        'image_size_bytes': processed.sizeBytes,
        'image_mime_type': processed.mimeType,
        'requested_meal_type': mealType.storageValue,
        'user_note': userNote,
        'last_mutation_id': SyncIds.derived('photo-job', jobId),
      });
    } on Object {
      // Senza la riga job la foto resterebbe orfana sul bucket.
      await _gateway.deletePhoto(storageObject);
      rethrow;
    }
    final job = PhotoMealJob(
      id: jobId,
      profileId: profileId,
      mealType: mealType,
      day: DiaryDay.instantFor(day),
      createdAt: _now(),
      storageObject: storageObject,
      userNote: userNote,
    );
    final jobs = await _store.readJobs();
    await _store.writeJobs([...jobs, job]);
    return job;
  }

  Future<PhotoMealAccount> _requireAccount() async {
    final account = await _gateway.currentAccount();
    if (account == null) {
      throw const PhotoMealException(
        'Per fotografare il pasto serve l’accesso al cloud: vai in '
        'Progressi → Sincronizzazione e accedi.',
        authRequired: true,
      );
    }
    return account;
  }

  String? _cleanNote(String? note) {
    final trimmed = note?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed.length > maxUserNoteChars
        ? trimmed.substring(0, maxUserNoteChars)
        : trimmed;
  }
}

final photoMealJobStoreProvider = Provider<PhotoMealJobStore>(
  (ref) => FilePhotoMealJobStore(),
);

final photoMealGatewayProvider = Provider<PhotoMealGateway>(
  (ref) => SupabasePhotoMealGateway(),
);

final photoMealRepositoryProvider = Provider<PhotoMealRepository>(
  (ref) => PhotoMealRepository(
    gateway: ref.watch(photoMealGatewayProvider),
    store: ref.watch(photoMealJobStoreProvider),
  ),
);

/// Lista dei job foto seguiti dal telefono, per la UI del diario.
class PhotoMealJobsController extends AsyncNotifier<List<PhotoMealJob>> {
  @override
  Future<List<PhotoMealJob>> build() =>
      ref.watch(photoMealRepositoryProvider).loadJobs();

  /// Cattura e accoda; rilancia gli errori al chiamante (la UI mostra
  /// il messaggio in italiano) ma aggiorna subito la lista in caso di
  /// successo. Ritorna null se Marco annulla la scelta della foto.
  Future<PhotoMealJob?> capture({
    required PhotoMealSource source,
    required String profileId,
    required MealType mealType,
    required DateTime day,
    String? note,
  }) async {
    final repository = ref.read(photoMealRepositoryProvider);
    final job = await repository.captureAndEnqueue(
      source: source,
      profileId: profileId,
      mealType: mealType,
      day: day,
      note: note,
    );
    if (job != null) {
      state = AsyncData(await repository.loadJobs());
    }
    return job;
  }

  /// Aggiorna lo stato dal server; offline si resta sullo stato locale.
  Future<void> refresh() async {
    final repository = ref.read(photoMealRepositoryProvider);
    try {
      state = AsyncData(await repository.refreshJobStatuses());
    } on Object {
      state = AsyncData(await repository.loadJobs());
    }
  }

  Future<void> remove(String jobId) async {
    state = AsyncData(
      await ref.read(photoMealRepositoryProvider).removeJob(jobId),
    );
  }
}

final photoMealJobsProvider =
    AsyncNotifierProvider<PhotoMealJobsController, List<PhotoMealJob>>(
      PhotoMealJobsController.new,
    );
