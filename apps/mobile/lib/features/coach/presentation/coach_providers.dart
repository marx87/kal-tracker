import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/checkin/domain/neat_trend.dart';
import 'package:kal_tracker/features/coach/data/coach_gateway.dart';
import 'package:kal_tracker/features/coach/data/coach_repository.dart';
import 'package:kal_tracker/features/coach/data/coach_snapshot_repository.dart';
import 'package:kal_tracker/features/coach/data/coach_store.dart';
import 'package:kal_tracker/features/coach/domain/coach_metrics.dart';
import 'package:kal_tracker/features/coach/domain/coach_feed_item.dart';
import 'package:kal_tracker/features/coach/domain/coach_narrative.dart';
import 'package:kal_tracker/features/coach/domain/coach_snapshot.dart';
import 'package:kal_tracker/features/coach/domain/coach_week.dart';
import 'package:kal_tracker/features/coach/presentation/coach_feed_providers.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/goal/presentation/goal_providers.dart';
import 'package:kal_tracker/features/targets/presentation/target_providers.dart';

final coachStoreProvider = Provider<CoachStore>((ref) => FileCoachStore());

final coachRepositoryProvider = Provider<CoachRepository>(
  (ref) => CoachRepository(
    gateway: ref.watch(coachGatewayProvider),
    store: ref.watch(coachStoreProvider),
  ),
);

final coachSnapshotRepositoryProvider = Provider<CoachSnapshotRepository>(
  (ref) => CoachSnapshotRepository(ref.watch(databaseProvider)),
);

/// La settimana del rapporto: l'ultima domenica non successiva a oggi.
///
/// Lunedì mattina si legge ancora la settimana appena finita: è quella di cui
/// c'è qualcosa da dire.
final coachWeekProvider = Provider<CoachWeek>(
  (ref) => CoachWeek.lastSunday(ref.watch(todayProvider)),
);

/// Quello che era previsto. Nell'ordine: i target dell'Obiettivo se c'è,
/// altrimenti quelli del diario — che esistono sempre.
final coachTargetsProvider = FutureProvider.autoDispose<CoachTargets>((
  ref,
) async {
  final profile = await ref.watch(marcoProfileProvider.future);
  final targets = await ref.watch(effectiveNutritionTargetProvider.future);
  final workouts = await ref
      .watch(coachSnapshotRepositoryProvider)
      .plannedWorkoutsPerWeek(profile.id);

  return CoachTargets(
    dailyCalories: targets.calories,
    dailyProtein: targets.protein,
    weeklyWorkouts: workouts,
  );
});

/// Il traguardo, per la sola proiezione. Nullo senza obiettivo: il rapporto
/// funziona lo stesso, semplicemente non proietta niente.
final coachGoalContextProvider = Provider<CoachGoalContext?>((ref) {
  final plan = ref.watch(goalPlanProvider).valueOrNull;
  if (plan == null) {
    return null;
  }
  return CoachGoalContext(
    targetWeightKg: plan.goal.targetWeightKg,
    paceKgPerWeek: plan.goal.paceKgPerWeek,
    plannedDate: plan.estimatedDate,
    phaseLabel: plan.goal.phase.label,
  );
});

/// La fotografia su cui lavora il motore.
final coachSnapshotProvider = FutureProvider.autoDispose<CoachSnapshot>((
  ref,
) async {
  final profile = await ref.watch(marcoProfileProvider.future);
  final targets = await ref.watch(coachTargetsProvider.future);
  return ref
      .watch(coachSnapshotRepositoryProvider)
      .load(
        profileId: profile.id,
        week: ref.watch(coachWeekProvider),
        targets: targets,
        goal: ref.watch(coachGoalContextProvider),
      );
});

/// **Il rapporto, per la parte che è aritmetica.** Si ricalcola a ogni
/// apertura dal database locale: c'è sempre, anche offline e col Mac spento.
final coachMetricsProvider = Provider.autoDispose<AsyncValue<CoachMetrics>>((
  ref,
) {
  final snapshot = ref.watch(coachSnapshotProvider);
  return snapshot.whenData(
    (value) => CoachEngine.run(value, today: ref.watch(coachWeekProvider).end),
  );
});

/// **Il movimento della settimana contro quella prima.** Nullo quando Marco
/// non l'ha mai segnato: il rapporto non ha niente da dire e non lo finge.
///
/// Sta fuori da [coachMetricsProvider] perché il motore non lo calcola: il
/// NEAT non entra in nessuna formula del rapporto, spiega i numeri che quelle
/// formule hanno già prodotto.
final coachNeatProvider = Provider.autoDispose<NeatTrend?>(
  (ref) => ref.watch(coachSnapshotProvider).valueOrNull?.neat,
);

/// Polling gentile mentre il Mac scrive: una lettura ogni 15 s, e solo
/// finché c'è una richiesta in volo.
final coachPollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 15),
);

class CoachUiState {
  const CoachUiState({
    this.archive = const CoachArchive.empty(),
    this.busy = false,
    this.error,
    this.lastCheckedAt,
  });

  final CoachArchive archive;

  /// Richiesta in partenza (il tocco su «Chiedi il commento»).
  final bool busy;

  /// Messaggio già in italiano, pronto da mostrare. Diverso da
  /// `archive.lastError`: questo è l'errore del gesto appena fatto, quello è
  /// l'ultimo esito del Mac.
  final String? error;

  final DateTime? lastCheckedAt;

  bool get isWaiting => archive.pending != null;

  CoachUiState copyWith({
    CoachArchive? archive,
    bool? busy,
    String? error,
    bool clearError = false,
    DateTime? lastCheckedAt,
  }) => CoachUiState(
    archive: archive ?? this.archive,
    busy: busy ?? this.busy,
    error: clearError ? null : (error ?? this.error),
    lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
  );
}

/// Azioni della schermata Coach: chiedi il commento, aspetta, rinuncia.
///
/// Nessun generatore locale di riserva: se il Mac non risponde il commento
/// non arriva e lo si dice. I numeri, quelli, non dipendono da qui.
class CoachController extends AsyncNotifier<CoachUiState> {
  /// Tetto per un singolo controllo, oltre al timeout di rete del gateway:
  /// qualunque cosa succeda, il giro successivo deve poter ripartire.
  static const checkTimeout = Duration(seconds: 30);

  Timer? _timer;
  bool _disposed = false;
  bool _refreshing = false;

  @override
  Future<CoachUiState> build() async {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _timer?.cancel();
      _timer = null;
    });

    final archive = await ref.watch(coachRepositoryProvider).read();
    // Riaprendo l'app con una richiesta già in volo nessuno la controllerebbe
    // più e l'attesa resterebbe appesa per sempre: il primo giro parte qui,
    // fuori dal build per non toccare lo stato mentre si costruisce.
    if (archive.pending != null) {
      Future.microtask(() {
        if (!_disposed) {
          unawaited(refreshNow());
        }
      });
    }
    return CoachUiState(archive: archive);
  }

  Future<bool> requestNarrative(CoachMetrics metrics) async {
    final current = state.valueOrNull;
    if (current == null || current.busy) {
      return false;
    }
    state = AsyncData(current.copyWith(busy: true, clearError: true));
    try {
      final profile = await ref.read(marcoProfileProvider.future);
      final archive = await ref
          .read(coachRepositoryProvider)
          .requestNarrative(profileId: profile.id, metrics: metrics);
      if (!_disposed) {
        state = AsyncData(
          current.copyWith(archive: archive, busy: false, clearError: true),
        );
        _scheduleNext();
      }
      return true;
    } on Object catch (error) {
      if (!_disposed) {
        state = AsyncData(
          current.copyWith(busy: false, error: _messageOf(error)),
        );
      }
      return false;
    }
  }

  Future<void> refreshNow() async {
    if (_disposed || _refreshing) {
      return;
    }
    _timer?.cancel();
    _timer = null;
    final current = state.valueOrNull;
    if (current == null || current.archive.pending == null) {
      return;
    }
    _refreshing = true;
    try {
      // Cintura di sicurezza: se un controllo restasse appeso (rete che cade
      // a metà richiesta), `_refreshing` non tornerebbe mai false e il ciclo
      // morirebbe lasciando l'attesa sullo schermo per sempre.
      final archive = await ref
          .read(coachRepositoryProvider)
          .refresh()
          .timeout(checkTimeout);
      await _publishNarrativeIfNew(current.archive.last, archive.last);
      if (!_disposed) {
        state = AsyncData(
          current.copyWith(
            archive: archive,
            clearError: true,
            lastCheckedAt: AppTime.nowUtc(),
          ),
        );
      }
    } on Object {
      // Offline non si dichiara nulla: si riproverà al prossimo giro.
    } finally {
      _refreshing = false;
      // Nel `finally`: il prossimo giro va riarmato anche quando questo
      // fallisce, altrimenti basta un errore per fermare il polling.
      _scheduleNext();
    }
  }

  /// Smette di aspettare. Il rapporto resta, il commento no.
  Future<void> cancelPending() async {
    final current = state.valueOrNull;
    if (current == null) {
      return;
    }
    // Anche il giro già armato va spento: continuare a chiedere di un job a
    // cui si è rinunciato terrebbe vivo un timer per sempre.
    _timer?.cancel();
    _timer = null;
    final archive = await ref.read(coachRepositoryProvider).cancelPending();
    if (!_disposed) {
      state = AsyncData(current.copyWith(archive: archive, clearError: true));
    }
  }

  void _scheduleNext() {
    if (_disposed) {
      return;
    }
    _timer?.cancel();
    _timer = null;
    if (state.valueOrNull?.archive.pending == null) {
      return;
    }
    _timer = Timer(
      ref.read(coachPollIntervalProvider),
      () => unawaited(refreshNow()),
    );
  }

  Future<void> _publishNarrativeIfNew(
    CoachNarrative? previous,
    CoachNarrative? next,
  ) async {
    if (next == null ||
        (previous?.week == next.week &&
            previous?.writtenAt == next.writtenAt)) {
      return;
    }
    final profile = await ref.read(marcoProfileProvider.future);
    final weekEnd = next.week.end.toIso8601String().substring(0, 10);
    await ref
        .read(coachFeedRepositoryProvider)
        .publish(
          profileId: profile.id,
          kind: 'weekly_narrative',
          source: CoachFeedSource.ai,
          externalId: 'week:$weekEnd',
          title: next.headline ?? 'Il commento del Coach è pronto',
          body: next.paragraphs.first,
          occurredAt: next.writtenAt,
          actionLabel: 'Leggi il rapporto',
          actionPath: '/coach',
        );
  }

  String _messageOf(Object error) => switch (error) {
    CoachException(:final message) => message,
    _ => 'Qualcosa è andato storto con il coach: riprova.',
  };
}

final coachControllerProvider =
    AsyncNotifierProvider<CoachController, CoachUiState>(CoachController.new);
