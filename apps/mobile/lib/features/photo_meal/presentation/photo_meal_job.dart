import 'package:kal_tracker/features/photo_meal/presentation/meal_analysis_result.dart';

/// Stati del job remoto `kal_tracker.meal_analysis_jobs`.
enum PhotoMealJobStatus {
  queued('queued'),
  claimed('claimed'),
  processing('processing'),
  needsReview('needs_review'),
  confirmed('confirmed'),
  failed('failed'),
  cancelled('cancelled'),
  expired('expired'),
  unknown('unknown');

  const PhotoMealJobStatus(this.storageValue);

  final String storageValue;

  static PhotoMealJobStatus fromStorage(Object? value) =>
      PhotoMealJobStatus.values.firstWhere(
        (status) => status.storageValue == value,
        orElse: () => PhotoMealJobStatus.unknown,
      );
}

/// Vista di sola lettura di un job di analisi foto. Il client non può
/// aggiornare la riga remota (UPDATE revocato): la chiusura è solo locale.
class PhotoMealJob {
  const PhotoMealJob({
    required this.id,
    required this.status,
    required this.storageObject,
    this.result,
    this.resultError,
    this.errorCode,
    this.attemptCount = 0,
    this.requestedMealType,
    this.userNote,
    this.createdAt,
    this.completedAt,
  });

  /// Costruisce il job da una riga PostgREST. `analysis_result` viene
  /// validato con il contratto rigido: se non è conforme il job resta
  /// leggibile e l'errore finisce in [resultError] (mai un crash).
  factory PhotoMealJob.fromRow(Map<String, Object?> row) {
    final status = PhotoMealJobStatus.fromStorage(row['status']);
    MealAnalysisResult? result;
    String? resultError;
    final rawResult = row['analysis_result'];
    if (status == PhotoMealJobStatus.needsReview) {
      try {
        result = MealAnalysisResult.fromJson(rawResult);
      } on FormatException catch (error) {
        resultError = error.message;
      }
    }
    return PhotoMealJob(
      id: row['id'] as String? ?? '',
      status: status,
      storageObject: row['storage_object'] as String? ?? '',
      result: result,
      resultError: resultError,
      errorCode: row['error_code'] as String?,
      attemptCount: row['attempt_count'] is num
          ? (row['attempt_count'] as num).toInt()
          : 0,
      requestedMealType: row['requested_meal_type'] as String?,
      userNote: row['user_note'] as String?,
      createdAt: _instant(row['created_at']),
      completedAt: _instant(row['completed_at']),
    );
  }

  final String id;
  final PhotoMealJobStatus status;
  final String storageObject;

  /// Risultato valido secondo il contratto, presente solo in needs_review.
  final MealAnalysisResult? result;

  /// Motivo per cui `analysis_result` non rispetta il contratto.
  final String? resultError;

  final String? errorCode;
  final int attemptCount;
  final String? requestedMealType;
  final String? userNote;
  final DateTime? createdAt;
  final DateTime? completedAt;

  /// Il worker ci sta ancora lavorando (o lo farà quando il Mac è acceso).
  bool get isActive =>
      status == PhotoMealJobStatus.queued ||
      status == PhotoMealJobStatus.claimed ||
      status == PhotoMealJobStatus.processing;

  /// Proposta pronta e conforme: si può aprire la revisione.
  bool get isReadyForReview =>
      status == PhotoMealJobStatus.needsReview && result != null;

  static DateTime? _instant(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toUtc() : null;
}
