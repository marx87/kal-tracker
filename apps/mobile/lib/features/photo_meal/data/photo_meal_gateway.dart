import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:kal_tracker/core/sync/sync_gateway.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PhotoMealException implements Exception {
  const PhotoMealException(
    this.message, {
    this.retryable = false,
    this.authRequired = false,
  });

  final String message;
  final bool retryable;
  final bool authRequired;

  @override
  String toString() => message;
}

class PhotoMealAccount {
  const PhotoMealAccount({required this.userId});

  /// auth.uid() della sessione: è il primo segmento del percorso Storage.
  final String userId;
}

/// Contratto verso Supabase per il flusso foto: il repository dipende solo
/// da qui, così i test girano con un finto gateway.
abstract class PhotoMealGateway {
  Future<PhotoMealAccount?> currentAccount();

  /// Garantisce la riga `profiles` remota e ritorna l'id da usare nel job
  /// (adotta un profilo già esistente con id diverso, mai l'id alla cieca).
  Future<String> ensureRemoteProfile(String localProfileId);

  Future<void> uploadPhoto({
    required String storageObject,
    required Uint8List bytes,
    required String contentType,
  });

  /// Pulizia best-effort di una foto rimasta orfana (insert del job fallito).
  Future<void> deletePhoto(String storageObject);

  /// INSERT PostgREST diretto su `meal_analysis_jobs` (non è una RPC).
  /// Un 23505 (id o last_mutation_id già visti) è un retry dopo risposta
  /// persa e va trattato come successo.
  Future<void> enqueueJob(Map<String, Object?> row);

  /// SELECT sui job propri per aggiornare lo stato locale (polling).
  Future<Map<String, Map<String, Object?>>> fetchJobRows(List<String> jobIds);
}

class SupabasePhotoMealGateway implements PhotoMealGateway {
  SupabasePhotoMealGateway({SupabaseClient? client}) : _clientOverride = client;

  static const String schemaName = 'kal_tracker';
  static const String bucketName = 'kal-tracker-meal-photos';
  static const String jobsTable = 'meal_analysis_jobs';

  final SupabaseClient? _clientOverride;
  final Map<String, String> _ensuredProfiles = {};

  SupabaseClient get _client {
    final client = _clientOverride;
    if (client != null) {
      return client;
    }
    try {
      return Supabase.instance.client;
    } on Object {
      throw const PhotoMealException(
        'Il cloud non è pronto: riapri l’app e riprova.',
        retryable: true,
      );
    }
  }

  SupabaseQuerySchema get _db => _client.schema(schemaName);

  @override
  Future<PhotoMealAccount?> currentAccount() async {
    final user = _client.auth.currentUser;
    if (user == null || _client.auth.currentSession == null) {
      return null;
    }
    return PhotoMealAccount(userId: user.id);
  }

  /// Replica del pattern di `SupabaseSyncGateway._ensureProfile` (privato
  /// lì, quindi non riusabile direttamente): unique(owner_id) sul server
  /// impone di adottare un profilo già esistente con un altro id.
  @override
  Future<String> ensureRemoteProfile(String localProfileId) async {
    _requireSession();
    final remoteId = SyncIds.remoteId(localProfileId);
    final known = _ensuredProfiles[remoteId];
    if (known != null) {
      return known;
    }
    try {
      final existing = await _db
          .from('profiles')
          .select('id')
          .isFilter('deleted_at', null)
          .limit(1);
      var actualId = existing.isNotEmpty
          ? existing.first['id'] as String?
          : null;
      if (actualId == null) {
        actualId = remoteId;
        await _db.from('profiles').upsert({
          'id': remoteId,
          'display_name': 'Marco',
          'time_zone': SyncPushMapper.timeZone,
          'locale': 'it_IT',
          'last_mutation_id': SyncIds.derived('profile', remoteId),
        });
      }
      _ensuredProfiles[remoteId] = actualId;
      return actualId;
    } on PhotoMealException {
      rethrow;
    } on Object catch (error) {
      throw _wrap(error);
    }
  }

  @override
  Future<void> uploadPhoto({
    required String storageObject,
    required Uint8List bytes,
    required String contentType,
  }) async {
    _requireSession();
    try {
      // Niente upsert: sul bucket non esiste una policy UPDATE, riprovare
      // sullo stesso percorso darebbe comunque 403.
      await _client.storage
          .from(bucketName)
          .uploadBinary(
            storageObject,
            bytes,
            fileOptions: FileOptions(contentType: contentType, upsert: false),
          );
    } on StorageException catch (error) {
      throw PhotoMealException(
        'Non riesco a caricare la foto (codice ${error.statusCode ?? '?'}): '
        'riprova tra poco.',
        retryable: true,
      );
    } on Object catch (error) {
      throw _wrap(error);
    }
  }

  @override
  Future<void> deletePhoto(String storageObject) async {
    try {
      await _client.storage.from(bucketName).remove([storageObject]);
    } on Object {
      // Best effort: se resta una foto orfana la policy delete permette
      // di ripulirla in un secondo momento.
      return;
    }
  }

  @override
  Future<void> enqueueJob(Map<String, Object?> row) async {
    _requireSession();
    try {
      await _db.from(jobsTable).insert(row);
    } on PostgrestException catch (error) {
      if (error.code == '23505') {
        // Retry dopo risposta persa: il job esiste già, niente duplicati.
        return;
      }
      throw _wrap(error);
    } on Object catch (error) {
      throw _wrap(error);
    }
  }

  @override
  Future<Map<String, Map<String, Object?>>> fetchJobRows(
    List<String> jobIds,
  ) async {
    if (jobIds.isEmpty) {
      return const {};
    }
    _requireSession();
    try {
      final rows = await _db
          .from(jobsTable)
          .select('id, status, error_code, attempt_count, analysis_result')
          .inFilter('id', jobIds);
      return {
        for (final row in rows)
          if (row['id'] is String)
            row['id'] as String: Map<String, Object?>.from(row),
      };
    } on PhotoMealException {
      rethrow;
    } on Object catch (error) {
      throw _wrap(error);
    }
  }

  void _requireSession() {
    if (_client.auth.currentSession == null) {
      throw const PhotoMealException(
        'Per fotografare il pasto serve l’accesso al cloud: vai in '
        'Progressi → Sincronizzazione e accedi.',
        authRequired: true,
      );
    }
  }

  PhotoMealException _wrap(Object error) {
    if (error is AuthException) {
      return const PhotoMealException(
        'La sessione è scaduta: accedi di nuovo da Progressi → '
        'Sincronizzazione.',
        authRequired: true,
      );
    }
    if (error is PostgrestException) {
      const retryableCodes = {'408', '425', '429', '500', '502', '503', '504'};
      return PhotoMealException(
        'Il server ha rifiutato la richiesta (codice ${error.code ?? '?'}).',
        retryable: retryableCodes.contains(error.code),
      );
    }
    if (error is SocketException || error is TimeoutException) {
      return const PhotoMealException(
        'Connessione assente: la foto non è partita, riprova quando '
        'torni online.',
        retryable: true,
      );
    }
    return const PhotoMealException(
      'Errore di rete durante l’invio della foto: riprova tra poco.',
      retryable: true,
    );
  }
}
