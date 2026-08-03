import 'package:kal_tracker/features/diary/domain/diary_models.dart';

/// Da dove arriva la foto del pasto.
enum PhotoMealSource { camera, gallery }

/// Stato locale di un job di analisi foto, specchio degli stati remoti di
/// `meal_analysis_jobs` (claimed/processing collassano su "in analisi",
/// cancelled/expired su "non riuscita").
enum PhotoMealJobStatus {
  queued('queued', 'In attesa di analisi'),
  processing('processing', 'In analisi'),
  needsReview('needs_review', 'Proposta pronta da rivedere'),
  failed('failed', 'Analisi non riuscita'),
  confirmed('confirmed', 'Confermato nel diario');

  const PhotoMealJobStatus(this.storageValue, this.label);

  final String storageValue;
  final String label;

  static PhotoMealJobStatus fromStorage(Object? value) =>
      tryFromRemote(value) ?? PhotoMealJobStatus.queued;

  /// Mappa uno stato remoto sul locale; null se lo stato non è riconosciuto
  /// (worker più nuovo dell'app: meglio non toccare lo stato salvato).
  static PhotoMealJobStatus? tryFromRemote(Object? value) => switch (value) {
    'queued' => PhotoMealJobStatus.queued,
    'claimed' || 'processing' => PhotoMealJobStatus.processing,
    'needs_review' => PhotoMealJobStatus.needsReview,
    'failed' || 'cancelled' || 'expired' => PhotoMealJobStatus.failed,
    'confirmed' => PhotoMealJobStatus.confirmed,
    _ => null,
  };
}

/// Un job di analisi foto seguito dal telefono. Vive su file JSON locale
/// (lo schema Drift resta alla v3): il server è la fonte di verità dello
/// stato, questa riga serve a ritrovare i job dopo un riavvio.
class PhotoMealJob {
  const PhotoMealJob({
    required this.id,
    required this.profileId,
    required this.mealType,
    required this.day,
    required this.createdAt,
    required this.storageObject,
    this.status = PhotoMealJobStatus.queued,
    this.userNote,
    this.errorCode,
    this.attemptCount = 0,
    this.analysisResult,
  });

  /// Uuid generato PRIMA dell'upload: è dentro il percorso Storage.
  final String id;

  /// Profilo LOCALE del diario (non l'id remoto adottato).
  final String profileId;

  final MealType mealType;

  /// Istante rappresentativo del giorno di diario scelto.
  final DateTime day;

  final DateTime createdAt;
  final String storageObject;
  final PhotoMealJobStatus status;
  final String? userNote;
  final String? errorCode;
  final int attemptCount;

  /// Copia del risultato remoto quando lo stato arriva a needs_review.
  /// Va comunque rivalidato contro il contratto prima di mostrarlo.
  final Map<String, Object?>? analysisResult;

  bool get inProgress =>
      status == PhotoMealJobStatus.queued ||
      status == PhotoMealJobStatus.processing;

  Map<String, Object?> toJson() => {
    'id': id,
    'profile_id': profileId,
    'meal_type': mealType.storageValue,
    'day': day.toUtc().toIso8601String(),
    'created_at': createdAt.toUtc().toIso8601String(),
    'storage_object': storageObject,
    'status': status.storageValue,
    'user_note': userNote,
    'error_code': errorCode,
    'attempt_count': attemptCount,
    'analysis_result': analysisResult,
  };

  /// Parse difensivo: una voce corrotta si scarta senza far cadere le altre.
  static PhotoMealJob? fromJson(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final id = raw['id'];
    final profileId = raw['profile_id'];
    final mealType = raw['meal_type'];
    final storageObject = raw['storage_object'];
    final day = raw['day'] is String
        ? DateTime.tryParse(raw['day'] as String)
        : null;
    if (id is! String ||
        id.isEmpty ||
        profileId is! String ||
        profileId.isEmpty ||
        mealType is! String ||
        storageObject is! String ||
        day == null) {
      return null;
    }
    final createdAt = raw['created_at'] is String
        ? DateTime.tryParse(raw['created_at'] as String)
        : null;
    final analysisResult = raw['analysis_result'];
    return PhotoMealJob(
      id: id,
      profileId: profileId,
      mealType: MealType.fromStorage(mealType),
      day: day.toUtc(),
      createdAt: (createdAt ?? day).toUtc(),
      storageObject: storageObject,
      status: PhotoMealJobStatus.fromStorage(raw['status']),
      userNote: raw['user_note'] is String ? raw['user_note'] as String : null,
      errorCode: raw['error_code'] is String
          ? raw['error_code'] as String
          : null,
      attemptCount: raw['attempt_count'] is num
          ? (raw['attempt_count'] as num).toInt()
          : 0,
      analysisResult: analysisResult is Map
          ? Map<String, Object?>.from(analysisResult)
          : null,
    );
  }
}
