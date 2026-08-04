import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/sync/sync_gateway.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Errore del flusso piano, già scritto in italiano per la UI.
class WeeklyPlanException implements Exception {
  const WeeklyPlanException(
    this.message, {
    this.retryable = false,
    this.authRequired = false,
  });

  final String message;

  /// Vale la pena riprovare fra poco (rete, server occupato).
  final bool retryable;

  /// Serve l'accesso al cloud: la UI rimanda a Progressi → Sincronizzazione.
  final bool authRequired;

  @override
  String toString() => message;
}

class WeeklyPlanAccount {
  const WeeklyPlanAccount({required this.userId});

  /// auth.uid() della sessione: è l'`owner_id` della riga del job.
  final String userId;
}

/// Contratto verso Supabase per la coda `weekly_plan_jobs`: il repository
/// dipende solo da qui, così i test girano con un finto gateway e senza rete.
abstract class WeeklyPlanGateway {
  /// Null quando Supabase non è configurato o non c'è sessione: il piano
  /// non si può generare, ma quelli già generati restano leggibili.
  Future<WeeklyPlanAccount?> currentAccount();

  /// Garantisce la riga `profiles` remota e ritorna l'id da usare nel job
  /// (adotta un profilo già esistente con id diverso, mai l'id alla cieca).
  Future<String> ensureRemoteProfile(String localProfileId);

  /// INSERT PostgREST diretto su `weekly_plan_jobs` (non è una RPC).
  /// Un 23505 (id o last_mutation_id già visti) è un retry dopo risposta
  /// persa e va trattato come successo.
  Future<void> enqueueJob(Map<String, Object?> row);

  /// SELECT del job proprio per il polling dello stato. Null se la riga
  /// non esiste (o non è più visibile).
  Future<Map<String, Object?>?> fetchJobRow(String jobId);
}

class SupabaseWeeklyPlanGateway implements WeeklyPlanGateway {
  SupabaseWeeklyPlanGateway({SupabaseClient? client})
    : _clientOverride = client;

  static const String schemaName = 'kal_tracker';
  static const String jobsTable = 'weekly_plan_jobs';

  /// Le sole colonne che servono al polling. `request` non si rilegge dal
  /// server: la copia locale in `weekly_plans.request_json` è la fonte con
  /// cui il risultato va validato, anche offline.
  static const String _columns =
      'id, status, result, error_code, attempt_count, created_at, completed_at';

  final SupabaseClient? _clientOverride;
  final Map<String, String> _ensuredProfiles = {};

  SupabaseClient? get _clientOrNull {
    final client = _clientOverride;
    if (client != null) {
      return client;
    }
    try {
      return Supabase.instance.client;
    } on Object {
      // Supabase non inizializzato (build offline): non è un errore da
      // mostrare, semplicemente non si può accodare nulla.
      return null;
    }
  }

  SupabaseClient get _client {
    final client = _clientOrNull;
    if (client == null) {
      throw const WeeklyPlanException(
        'Il cloud non è pronto: riapri l’app e riprova.',
        retryable: true,
      );
    }
    return client;
  }

  SupabaseQuerySchema get _db => _client.schema(schemaName);

  @override
  Future<WeeklyPlanAccount?> currentAccount() async {
    final client = _clientOrNull;
    if (client == null) {
      return null;
    }
    final user = client.auth.currentUser;
    if (user == null || client.auth.currentSession == null) {
      return null;
    }
    return WeeklyPlanAccount(userId: user.id);
  }

  /// Stesso pattern del flusso foto: `unique(owner_id)` sul server impone
  /// di adottare un profilo già esistente con un altro id.
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
    } on WeeklyPlanException {
      rethrow;
    } on Object catch (error) {
      throw _wrap(error);
    }
  }

  @override
  Future<void> enqueueJob(Map<String, Object?> row) async {
    _requireSession();
    try {
      await _db.from(jobsTable).insert(row);
    } on PostgrestException catch (error) {
      if (error.code == '23505') {
        // Retry dopo risposta persa: il job esiste già, niente doppioni.
        return;
      }
      throw _wrap(error);
    } on Object catch (error) {
      throw _wrap(error);
    }
  }

  @override
  Future<Map<String, Object?>?> fetchJobRow(String jobId) async {
    _requireSession();
    try {
      final rows = await _db
          .from(jobsTable)
          .select(_columns)
          .eq('id', jobId)
          .isFilter('deleted_at', null)
          .limit(1);
      if (rows.isEmpty) {
        return null;
      }
      return Map<String, Object?>.from(rows.first);
    } on WeeklyPlanException {
      rethrow;
    } on Object catch (error) {
      throw _wrap(error);
    }
  }

  void _requireSession() {
    final client = _clientOrNull;
    if (client == null || client.auth.currentSession == null) {
      throw const WeeklyPlanException(
        'Per il piano serve l’accesso al cloud: vai in Progressi → '
        'Sincronizzazione e accedi.',
        authRequired: true,
      );
    }
  }

  WeeklyPlanException _wrap(Object error) {
    if (error is AuthException) {
      return const WeeklyPlanException(
        'La sessione è scaduta: accedi di nuovo da Progressi → '
        'Sincronizzazione.',
        authRequired: true,
      );
    }
    if (error is PostgrestException) {
      const retryableCodes = {'408', '425', '429', '500', '502', '503', '504'};
      return WeeklyPlanException(
        'Il server ha rifiutato la richiesta (codice ${error.code ?? '?'}).',
        retryable: retryableCodes.contains(error.code),
      );
    }
    if (error is SocketException || error is TimeoutException) {
      return const WeeklyPlanException(
        'Connessione assente: la richiesta non è partita, riprova quando '
        'torni online.',
        retryable: true,
      );
    }
    return const WeeklyPlanException(
      'Errore di rete mentre parlavo con il Mac: riprova tra poco.',
      retryable: true,
    );
  }
}

final weeklyPlanGatewayProvider = Provider<WeeklyPlanGateway>(
  (ref) => SupabaseWeeklyPlanGateway(),
);
