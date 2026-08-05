import 'package:kal_tracker/core/sync/sync_gateway.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/coach/data/coach_gateway.dart';
import 'package:kal_tracker/features/coach/data/coach_store.dart';
import 'package:kal_tracker/features/coach/domain/coach_metrics.dart';
import 'package:kal_tracker/features/coach/domain/coach_narrative.dart';
import 'package:uuid/uuid.dart';

/// Orchestrazione del commento del coach: richiesta → coda sul Mac → attesa →
/// commento archiviato.
///
/// Regole incise nel flusso:
/// * **i numeri non passano di qui.** Il rapporto è già calcolato quando
///   questa classe entra in scena: sul Mac va una fotografia di numeri già
///   fatti e torna solo del testo;
/// * qualunque cifra nel testo di ritorno viene scartata insieme al suo
///   capoverso ([CoachNarrative.fromResult]);
/// * col Mac spento non c'è nessun generatore locale di riserva: si aspetta,
///   poi si dichiara il silenzio. **L'ultimo commento resta leggibile per
///   sempre**, e i numeri della settimana ci sono comunque.
class CoachRepository {
  CoachRepository({
    required this._gateway,
    required this._store,
    Uuid? uuid,
    DateTime Function()? now,
  }) : _uuid = uuid ?? const Uuid(),
       _now = now ?? AppTime.nowUtc;

  /// Il Mac non ha ancora preso in carico il job: dopo questo tempo si smette
  /// di aspettare. Lo stato remoto resta 'queued' per sempre (nessun TTL sul
  /// server), quindi il criterio è per forza temporale e sta qui.
  static const Duration queuedTimeout = Duration(minutes: 8);

  /// Job preso in carico ma mai concluso (worker morto a metà). Un commento
  /// è molto più corto di un piano settimanale: dieci minuti bastano.
  static const Duration workTimeout = Duration(minutes: 10);

  final CoachGateway _gateway;
  final CoachStore _store;
  final Uuid _uuid;
  final DateTime Function() _now;

  Future<CoachArchive> read() => _store.read();

  /// Chiede al Mac il commento della settimana di [metrics].
  ///
  /// Il rapporto esiste già: questa è la parte che si può non avere.
  Future<CoachArchive> requestNarrative({
    required String profileId,
    required CoachMetrics metrics,
  }) async {
    final archive = await _store.read();
    if (archive.pending != null) {
      throw const CoachException(
        'C’è già un commento in preparazione: aspetta che il Mac risponda.',
      );
    }

    final account = await _gateway.currentAccount();
    if (account == null) {
      throw const CoachException(
        'Per il commento del coach serve l’accesso al cloud: vai in Corpo → '
        'Sincronizzazione e accedi.',
        authRequired: true,
      );
    }

    final jobId = _uuid.v4();
    final remoteProfileId = await _gateway.ensureRemoteProfile(profileId);
    // SOLO le 5 colonne concesse dal grant: qualsiasi altra colonna (anche
    // con il valore di default) produce 42501.
    await _gateway.enqueueJob({
      'id': jobId,
      'owner_id': account.userId,
      'profile_id': remoteProfileId,
      'request': metrics.toRequestJson(),
      'last_mutation_id': SyncIds.derived('coach-job', jobId),
    });

    final updated = archive.copyWith(
      pending: CoachPendingJob(
        jobId: jobId,
        week: metrics.week,
        requestedAt: _now(),
      ),
      clearError: true,
    );
    await _store.write(updated);
    return updated;
  }

  /// Un giro di polling sul commento in attesa.
  ///
  /// Gli errori di rete risalgono al chiamante e per un po' lo stato locale
  /// NON si tocca: «non riesco a chiedere» non è «il Mac è spento». Ma
  /// passata la finestra dell'attesa anche il silenzio va dichiarato, o
  /// l'attesa resterebbe aperta per sempre.
  Future<CoachArchive> refresh() async {
    final archive = await _store.read();
    final pending = archive.pending;
    if (pending == null) {
      return archive;
    }

    final Map<String, Object?>? remote;
    try {
      remote = await _gateway.fetchJobRow(pending.jobId);
    } on Object {
      if (_age(pending) > queuedTimeout) {
        return _fail(archive, _unreachableMessage);
      }
      rethrow;
    }

    final age = _age(pending);
    if (remote == null) {
      // Riga non trovata: o non è mai arrivata, o è stata rimossa. Si aspetta
      // comunque la finestra del "queued" prima di dichiarare il fallimento.
      return age > queuedTimeout ? _fail(archive, _macSilentMessage) : archive;
    }

    switch (remote['status']) {
      case 'needs_review' || 'confirmed':
        return _archiveNarrative(archive, pending, remote['result']);
      case 'failed' || 'cancelled' || 'expired':
        final code = remote['error_code'];
        return _fail(
          archive,
          code is String && code.trim().isNotEmpty
              ? 'Il Mac non è riuscito a scrivere il commento '
                    '(${code.trim()}): i numeri qui sotto restano validi.'
              : 'Il Mac non è riuscito a scrivere il commento: i numeri qui '
                    'sotto restano validi.',
        );
      case 'queued':
        return age > queuedTimeout
            ? _fail(archive, _macSilentMessage)
            : archive;
      default:
        // claimed / processing: il Mac ci sta lavorando, gli si dà tempo.
        return age > workTimeout
            ? _fail(
                archive,
                'Il Mac ha iniziato ma non ha finito: riprova quando è '
                'libero.',
              )
            : archive;
    }
  }

  /// Butta via la richiesta in volo senza aspettare il timeout.
  Future<CoachArchive> cancelPending() async {
    final archive = await _store.read();
    if (archive.pending == null) {
      return archive;
    }
    final updated = archive.copyWith(clearPending: true, clearError: true);
    await _store.write(updated);
    return updated;
  }

  Duration _age(CoachPendingJob pending) =>
      _now().difference(pending.requestedAt);

  Future<CoachArchive> _archiveNarrative(
    CoachArchive archive,
    CoachPendingJob pending,
    Object? rawResult,
  ) async {
    final narrative = CoachNarrative.fromResult(
      rawResult,
      week: pending.week,
      writtenAt: _now(),
    );
    if (narrative == null) {
      // Tutto scartato (o illeggibile): il commento vecchio resta, e si dice
      // perché non ce n'è uno nuovo.
      return _fail(
        archive,
        'Il commento arrivato dal Mac non era utilizzabile: conteneva numeri '
        'o era vuoto. I numeri veri sono quelli qui sotto.',
      );
    }
    final updated = archive.copyWith(
      last: narrative,
      clearPending: true,
      clearError: true,
    );
    await _store.write(updated);
    return updated;
  }

  Future<CoachArchive> _fail(CoachArchive archive, String message) async {
    final updated = archive.copyWith(clearPending: true, lastError: message);
    await _store.write(updated);
    return updated;
  }

  static const String _macSilentMessage =
      'Il Mac non ha risposto: il rapporto è comunque qui, manca solo il '
      'commento. Riprova quando è acceso.';

  static const String _unreachableMessage =
      'Non sono riuscito a chiedere al Mac come sta andando: controlla la '
      'connessione (e l’accesso al cloud). Il rapporto resta leggibile.';
}
