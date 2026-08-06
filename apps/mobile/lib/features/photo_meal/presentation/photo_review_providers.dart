import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/sync/sync_auth.dart';
import 'package:kal_tracker/core/sync/sync_gateway.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/photo_meal/data/photo_meal_repository.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_jobs_gateway.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_meal_job.dart';
import 'package:kal_tracker/features/photo_meal/presentation/photo_review_local_store.dart';

/// Il polling parte solo con Supabase configurato e Marco autenticato:
/// offline o senza sessione il diario resta pienamente usabile a mano.
final photoJobsEnabledProvider = Provider<bool>((ref) {
  final auth = ref.watch(syncAuthProvider);
  return auth.configured && auth.signedIn;
});

/// Aggiornato da [PhotoProposalsListener]: in background il polling tace.
final photoForegroundProvider = StateProvider<bool>((ref) => true);

/// Polling gentile: una lettura ogni ~25 s, solo con job attivi in coda.
final photoPollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 25),
);

class PhotoJobsState {
  const PhotoJobsState({
    required this.enabled,
    this.loading = false,
    this.jobs = const [],
    this.error,
    this.lastRefreshAt,
  });

  const PhotoJobsState.disabled()
    : enabled = false,
      loading = false,
      jobs = const [],
      error = null,
      lastRefreshAt = null;

  final bool enabled;
  final bool loading;

  /// Job non ancora gestiti localmente, dal più recente.
  final List<PhotoMealJob> jobs;
  final String? error;
  final DateTime? lastRefreshAt;

  bool get hasActiveJobs => jobs.any((job) => job.isActive);

  List<PhotoMealJob> get readyProposals => [
    for (final job in jobs)
      if (job.isReadyForReview) job,
  ];

  PhotoJobsState copyWith({
    bool? loading,
    List<PhotoMealJob>? jobs,
    String? error,
    bool clearError = false,
    DateTime? lastRefreshAt,
  }) => PhotoJobsState(
    enabled: enabled,
    loading: loading ?? this.loading,
    jobs: jobs ?? this.jobs,
    error: clearError ? null : (error ?? this.error),
    lastRefreshAt: lastRefreshAt ?? this.lastRefreshAt,
  );
}

/// Osserva i job foto in corso con polling gentile (SELECT diretto sulla
/// tabella, canale previsto dal contratto: il feed sync oggi scarta
/// `meal_analysis_jobs`). Si ferma da solo quando non restano job attivi
/// e quando l'app va in background.
class PhotoJobsController extends Notifier<PhotoJobsState> {
  Timer? _timer;
  bool _disposed = false;
  bool _refreshing = false;

  @override
  PhotoJobsState build() {
    final enabled = ref.watch(photoJobsEnabledProvider);
    _disposed = false;
    _timer?.cancel();
    ref.onDispose(() {
      _disposed = true;
      _timer?.cancel();
    });
    ref.listen<bool>(photoForegroundProvider, (previous, next) {
      if (next) {
        unawaited(refreshNow());
      } else {
        _timer?.cancel();
      }
    });
    // Aggancio dopo l'enqueue: quando il registro locale del diario
    // acquista un job nuovo (foto appena accodata) la lettura parte
    // subito, senza aspettare un riavvio o un cambio di lifecycle.
    ref.listen(photoMealJobsProvider, (previous, next) {
      final before = previous?.valueOrNull?.length ?? 0;
      final after = next.valueOrNull?.length ?? 0;
      if (after > before) {
        unawaited(refreshNow());
      }
    });
    if (!enabled) {
      return const PhotoJobsState.disabled();
    }
    Future.microtask(refreshNow);
    return const PhotoJobsState(enabled: true, loading: true);
  }

  /// Lettura immediata: usata all'avvio, al rientro in primo piano e
  /// come aggancio dopo l'enqueue di una nuova foto.
  Future<void> refreshNow() async {
    if (_disposed || !ref.read(photoJobsEnabledProvider)) {
      return;
    }
    _timer?.cancel();
    if (_refreshing) {
      return;
    }
    _refreshing = true;
    try {
      // Prima le chiusure in sospeso, poi la lettura: così un job chiuso
      // offline sparisce dal server nello stesso giro in cui si torna online,
      // invece di ripresentarsi ancora una volta.
      await _retryPendingResolves();
      await _retryPendingPhotoDeletes();
      final handled = await ref
          .read(photoReviewLocalStoreProvider)
          .handledJobIds();
      final jobs = await ref.read(photoJobsGatewayProvider).fetchJobs();
      if (_disposed) {
        return;
      }
      state = PhotoJobsState(
        enabled: true,
        jobs: List.unmodifiable([
          for (final job in jobs)
            if (!handled.contains(job.id)) job,
        ]),
        lastRefreshAt: AppTime.nowUtc(),
      );
    } on SyncGatewayException catch (error) {
      if (_disposed) {
        return;
      }
      state = state.copyWith(loading: false, error: error.message);
    } on Object {
      if (_disposed) {
        return;
      }
      state = state.copyWith(
        loading: false,
        error: 'Non riesco a leggere lo stato delle analisi foto.',
      );
    } finally {
      _refreshing = false;
    }
    _scheduleNext();
  }

  /// Chiusura SOLO locale del job (il contratto v0.2 non dà al client
  /// UPDATE né RPC di conferma: la riga remota resta needs_review).
  /// Registra l'esito nel registro locale, toglie il job dal registro del
  /// diario (così la riga «proposta pronta» sparisce e il file non cresce
  /// per sempre) e rimuove la foto dal bucket; se la delete fallisce la
  /// foto finisce nel registro pending e viene ritentata ai poll successivi.
  Future<void> closeJobLocally(
    PhotoMealJob job, {
    required String outcome,
  }) async {
    final store = ref.read(photoReviewLocalStoreProvider);
    await store.markHandled(jobId: job.id, outcome: outcome);
    // E poi si dice al server, perché «gestita» deve valere su tutti gli
    // apparecchi e non solo su quello che l'ha toccata. Se non parte resta in
    // coda: sparire in silenzio è ciò che lasciava il banner acceso sul tablet
    // per una foto registrata dal telefono.
    try {
      await ref
          .read(photoJobsGatewayProvider)
          .resolveJob(jobId: job.id, outcome: outcome);
    } on Object {
      await store.addPendingResolve(jobId: job.id, outcome: outcome);
    }
    try {
      await ref.read(photoMealJobsProvider.notifier).remove(job.id);
    } on Object {
      // Registro del diario best-effort: la chiusura locale vale comunque.
    }
    try {
      await ref.read(photoJobsGatewayProvider).deletePhoto(job.storageObject);
    } on Object {
      // Niente silenzi: la foto resta registrata come da cancellare.
      await store.addPendingPhotoDelete(job.storageObject);
    }
    if (_disposed) {
      return;
    }
    state = state.copyWith(
      jobs: List.unmodifiable([
        for (final existing in state.jobs)
          if (existing.id != job.id) existing,
      ]),
      clearError: true,
    );
    _scheduleNext();
  }

  /// Ritenta le chiusure che il server non ha ancora accettato.
  ///
  /// La RPC è idempotente — chiudere un job già chiuso torna lo stato che ha
  /// senza toccarlo — quindi ritentare non ha nessun costo e non c'è niente da
  /// distinguere fra «non era partita» e «era partita e non l'ho saputo».
  Future<void> _retryPendingResolves() async {
    final store = ref.read(photoReviewLocalStoreProvider);
    final gateway = ref.read(photoJobsGatewayProvider);
    try {
      for (final pending in await store.pendingResolves()) {
        try {
          await gateway.resolveJob(
            jobId: pending.jobId,
            outcome: pending.outcome,
          );
          await store.removePendingResolve(pending.jobId);
        } on Object {
          // Ancora offline: si riprova al prossimo giro.
        }
      }
    } on Object {
      // Il registro pending non deve mai bloccare il polling.
    }
  }

  /// Ritenta le delete di foto rimaste sul bucket (chiusure avvenute
  /// offline): a ogni successo l'oggetto esce dal registro pending.
  Future<void> _retryPendingPhotoDeletes() async {
    final store = ref.read(photoReviewLocalStoreProvider);
    final gateway = ref.read(photoJobsGatewayProvider);
    try {
      for (final storageObject in await store.pendingPhotoDeletes()) {
        try {
          await gateway.deletePhoto(storageObject);
          await store.removePendingPhotoDelete(storageObject);
        } on Object {
          // Ancora offline: si riprova al prossimo giro.
        }
      }
    } on Object {
      // Il registro pending non deve mai bloccare il polling.
    }
  }

  void _scheduleNext() {
    if (_disposed) {
      return;
    }
    _timer?.cancel();
    // Si riarma anche su errore con lista vuota: la prima fetch fallita
    // (offline all'avvio) non deve spegnere il polling per sempre.
    final shouldPoll = state.hasActiveJobs || state.error != null;
    if (!ref.read(photoForegroundProvider) || !shouldPoll) {
      return;
    }
    _timer = Timer(
      ref.read(photoPollIntervalProvider),
      () => unawaited(refreshNow()),
    );
  }
}

final photoJobsControllerProvider =
    NotifierProvider<PhotoJobsController, PhotoJobsState>(
      PhotoJobsController.new,
    );

/// Proposte pronte da rivedere (badge e notifica in-app).
final photoProposalsReadyProvider = Provider<List<PhotoMealJob>>(
  (ref) => ref.watch(photoJobsControllerProvider).readyProposals,
);

/// Job per la schermata di revisione: prima dalla cache del polling,
/// altrimenti una SELECT mirata (deep link o proposta più vecchia).
final photoReviewJobProvider = FutureProvider.autoDispose
    .family<PhotoMealJob?, String>((ref, jobId) async {
      final cached = ref.watch(photoJobsControllerProvider).jobs;
      for (final job in cached) {
        if (job.id == jobId) {
          return job;
        }
      }
      return ref.watch(photoJobsGatewayProvider).fetchJob(jobId);
    });
