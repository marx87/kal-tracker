import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/sync/sync_gateway.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_meal_job.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Lettura dello stato dei job foto e pulizia della foto remota.
/// Il contratto v0.2 non prevede RPC di conferma/cancellazione lato client:
/// qui ci sono solo SELECT (policy `meal_analysis_jobs_select_own`) e la
/// delete dell'oggetto Storage (policy `_delete_own` sulla cartella di Marco).
abstract class PhotoJobsGateway {
  Future<List<PhotoMealJob>> fetchJobs({int limit = 30});

  Future<PhotoMealJob?> fetchJob(String jobId);

  /// Best-effort: la foto va rimossa dopo conferma o scarto, ma un errore
  /// di rete non deve bloccare la chiusura locale.
  Future<void> deletePhoto(String storageObject);

  /// Chiude il job sul server: `confirmed` o `discarded`.
  ///
  /// È la metà mancante di «già gestita». Senza, quel fatto restava un file
  /// dentro un apparecchio solo e ogni altro dispositivo continuava a vedere
  /// la proposta aperta — il tablet mostrava «Proposta pronta da rivedere» per
  /// una foto registrata dal telefono mezz'ora prima.
  Future<void> resolveJob({required String jobId, required String outcome});
}

class SupabasePhotoJobsGateway implements PhotoJobsGateway {
  SupabasePhotoJobsGateway({SupabaseClient? client}) : _clientOverride = client;

  static const schemaName = 'kal_tracker';
  static const bucketName = 'kal-tracker-meal-photos';
  static const _columns =
      'id, status, analysis_result, error_code, attempt_count, '
      'requested_meal_type, user_note, storage_object, created_at, '
      'completed_at';

  final SupabaseClient? _clientOverride;

  SupabaseClient get _client {
    final client = _clientOverride;
    if (client != null) {
      return client;
    }
    try {
      return Supabase.instance.client;
    } on Object {
      throw const SyncGatewayException(
        'Il cloud non è pronto: riapri l’app e riprova.',
        retryable: true,
      );
    }
  }

  @override
  Future<List<PhotoMealJob>> fetchJobs({int limit = 30}) async {
    _requireSession();
    try {
      final rows = await _client
          .schema(schemaName)
          .from('meal_analysis_jobs')
          .select(_columns)
          .isFilter('deleted_at', null)
          .order('created_at', ascending: false)
          .limit(limit);
      return [
        for (final row in rows)
          PhotoMealJob.fromRow(Map<String, Object?>.from(row)),
      ];
    } on SyncGatewayException {
      rethrow;
    } on Object catch (error) {
      throw _wrap(error);
    }
  }

  @override
  Future<PhotoMealJob?> fetchJob(String jobId) async {
    _requireSession();
    try {
      final rows = await _client
          .schema(schemaName)
          .from('meal_analysis_jobs')
          .select(_columns)
          .eq('id', jobId)
          .isFilter('deleted_at', null)
          .limit(1);
      if (rows.isEmpty) {
        return null;
      }
      return PhotoMealJob.fromRow(Map<String, Object?>.from(rows.first));
    } on SyncGatewayException {
      rethrow;
    } on Object catch (error) {
      throw _wrap(error);
    }
  }

  @override
  Future<void> resolveJob({
    required String jobId,
    required String outcome,
  }) async {
    // Una RPC e non un UPDATE: al client il permesso di scrivere su questa
    // tabella è tolto di proposito, perché con l'UPDATE potrebbe riscriversi
    // il risultato dell'analisi e fingersi il worker. Qui può fare una cosa
    // sola, e solo su un job suo già arrivato in revisione.
    await _client.rpc<Object?>(
      'resolve_meal_analysis_job',
      params: {'p_job_id': jobId, 'p_outcome': outcome},
    );
  }

  @override
  Future<void> deletePhoto(String storageObject) async {
    if (storageObject.isEmpty) {
      return;
    }
    _requireSession();
    try {
      await _client.storage.from(bucketName).remove([storageObject]);
    } on SyncGatewayException {
      rethrow;
    } on Object catch (error) {
      throw _wrap(error);
    }
  }

  void _requireSession() {
    if (_client.auth.currentSession == null) {
      throw const SyncGatewayException(
        'Serve l’accesso per leggere le analisi foto.',
        authRequired: true,
      );
    }
  }

  SyncGatewayException _wrap(Object error) {
    if (error is AuthException) {
      return const SyncGatewayException(
        'La sessione è scaduta: accedi di nuovo.',
        authRequired: true,
      );
    }
    if (error is SocketException || error is TimeoutException) {
      return const SyncGatewayException(
        'Connessione assente: riproverò più tardi.',
        retryable: true,
      );
    }
    if (error is PostgrestException) {
      const retryableCodes = {'408', '425', '429', '500', '502', '503', '504'};
      return SyncGatewayException(
        'Il server ha rifiutato la lettura (codice ${error.code ?? '?'}).',
        retryable: retryableCodes.contains(error.code),
      );
    }
    if (error is StorageException) {
      return SyncGatewayException(
        'Pulizia della foto non riuscita (${error.statusCode ?? '?'}).',
        retryable: true,
      );
    }
    return const SyncGatewayException(
      'Errore di rete durante la lettura delle analisi foto.',
      retryable: true,
    );
  }
}

final photoJobsGatewayProvider = Provider<PhotoJobsGateway>(
  (ref) => SupabasePhotoJobsGateway(),
);
