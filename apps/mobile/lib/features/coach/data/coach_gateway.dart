import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/sync/sync_gateway.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Errore del flusso coach, già scritto in italiano per la UI.
class CoachException implements Exception {
  const CoachException(
    this.message, {
    this.retryable = false,
    this.authRequired = false,
  });

  final String message;

  /// Vale la pena riprovare fra poco (rete, server occupato).
  final bool retryable;

  /// Serve l'accesso al cloud: la UI rimanda a Corpo → Sincronizzazione.
  final bool authRequired;

  @override
  String toString() => message;
}

class CoachAccount {
  const CoachAccount({required this.userId});

  /// `auth.uid()` della sessione: è l'`owner_id` della riga del job.
  final String userId;
}

/// Contratto verso Supabase per la coda `coach_jobs`.
///
/// È il terzo della famiglia, dopo le foto e il piano settimanale: stessa
/// forma, stesso patto. Il repository dipende solo da qui, così i test
/// girano senza rete.
abstract class CoachGateway {
  /// Nullo quando Supabase non è configurato o non c'è sessione: il commento
  /// non si può chiedere, ma il rapporto resta leggibile con i suoi numeri.
  Future<CoachAccount?> currentAccount();

  /// Garantisce la riga `profiles` remota e ritorna l'id da usare nel job.
  Future<String> ensureRemoteProfile(String localProfileId);

  /// INSERT PostgREST diretto su `coach_jobs` (non è una RPC). Un 23505 è un
  /// retry dopo risposta persa e va trattato come successo.
  Future<void> enqueueJob(Map<String, Object?> row);

  /// SELECT del proprio job per il polling. Nullo se la riga non c'è più.
  Future<Map<String, Object?>?> fetchJobRow(String jobId);
}

class SupabaseCoachGateway implements CoachGateway {
  SupabaseCoachGateway({SupabaseClient? client}) : _clientOverride = client;

  static const String schemaName = 'kal_tracker';
  static const String jobsTable = 'coach_jobs';

  /// Le sole colonne che servono al polling. `request` non si rilegge: i
  /// numeri li ha già l'app, e sono la fonte.
  static const String _columns =
      'id, status, result, error_code, attempt_count, created_at, completed_at';

  /// Nessuna chiamata di rete può restare appesa: una richiesta che non torna
  /// mai bloccherebbe il ciclo di attesa e lascerebbe «il Mac sta scrivendo»
  /// sullo schermo per sempre.
  static const networkTimeout = Duration(seconds: 20);

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
      throw const CoachException(
        'Il cloud non è pronto: riapri l’app e riprova.',
        retryable: true,
      );
    }
    return client;
  }

  SupabaseQuerySchema get _db => _client.schema(schemaName);

  @override
  Future<CoachAccount?> currentAccount() async {
    final client = _clientOrNull;
    if (client == null) {
      return null;
    }
    final user = client.auth.currentUser;
    if (user == null || client.auth.currentSession == null) {
      return null;
    }
    return CoachAccount(userId: user.id);
  }

  /// Stesso pattern del piano: `unique(owner_id)` sul server impone di
  /// adottare un profilo già esistente con un altro id.
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
          .limit(1)
          .timeout(networkTimeout);
      var actualId = existing.isNotEmpty
          ? existing.first['id'] as String?
          : null;
      if (actualId == null) {
        actualId = remoteId;
        await _db
            .from('profiles')
            .upsert({
              'id': remoteId,
              'display_name': 'Marco',
              'time_zone': SyncPushMapper.timeZone,
              'locale': 'it_IT',
              'last_mutation_id': SyncIds.derived('profile', remoteId),
            })
            .timeout(networkTimeout);
      }
      _ensuredProfiles[remoteId] = actualId;
      return actualId;
    } on CoachException {
      rethrow;
    } on Object catch (error) {
      throw _wrap(error);
    }
  }

  @override
  Future<void> enqueueJob(Map<String, Object?> row) async {
    _requireSession();
    try {
      await _db.from(jobsTable).insert(row).timeout(networkTimeout);
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
          .limit(1)
          .timeout(networkTimeout);
      if (rows.isEmpty) {
        return null;
      }
      return Map<String, Object?>.from(rows.first);
    } on CoachException {
      rethrow;
    } on Object catch (error) {
      throw _wrap(error);
    }
  }

  void _requireSession() {
    final client = _clientOrNull;
    if (client == null || client.auth.currentSession == null) {
      throw const CoachException(
        'Per il commento del coach serve l’accesso al cloud: vai in Corpo → '
        'Sincronizzazione e accedi.',
        authRequired: true,
      );
    }
  }

  CoachException _wrap(Object error) {
    if (error is AuthException) {
      return const CoachException(
        'La sessione è scaduta: accedi di nuovo da Corpo → Sincronizzazione.',
        authRequired: true,
      );
    }
    if (error is PostgrestException) {
      const retryableCodes = {'408', '425', '429', '500', '502', '503', '504'};
      return CoachException(
        'Il server ha rifiutato la richiesta (codice ${error.code ?? '?'}).',
        retryable: retryableCodes.contains(error.code),
      );
    }
    if (error is SocketException || error is TimeoutException) {
      return const CoachException(
        'Connessione assente: la richiesta non è partita, riprova quando '
        'torni online.',
        retryable: true,
      );
    }
    return const CoachException(
      'Errore di rete mentre parlavo con il Mac: riprova tra poco.',
      retryable: true,
    );
  }
}

final coachGatewayProvider = Provider<CoachGateway>(
  (ref) => SupabaseCoachGateway(),
);
