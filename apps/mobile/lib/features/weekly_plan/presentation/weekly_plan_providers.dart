import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/targets/presentation/target_providers.dart';
import 'package:kal_tracker/features/weekly_plan/data/weekly_plan_gateway.dart';
import 'package:kal_tracker/features/weekly_plan/data/weekly_plan_repository.dart';
import 'package:kal_tracker/features/weekly_plan/domain/weekly_plan_models.dart';

/// Tutti i piani del profilo, dal più recente. Sorgente unica per la
/// schermata Piano e per la lista della spesa: legge solo il database
/// locale, quindi funziona anche offline.
final weeklyPlansProvider = StreamProvider<List<WeeklyPlan>>((ref) async* {
  final profile = await ref.watch(marcoProfileProvider.future);
  yield* ref.watch(weeklyPlanRepositoryProvider).watchPlans(profile.id);
});

/// Il piano pronto più recente: è quello che si mostra e da cui nasce la
/// lista della spesa.
final activeWeeklyPlanProvider = Provider<WeeklyPlan?>((ref) {
  final plans = ref.watch(weeklyPlansProvider).valueOrNull;
  for (final plan in plans ?? const <WeeklyPlan>[]) {
    if (plan.isReady) {
      return plan;
    }
  }
  return null;
});

/// Il piano che il Mac sta preparando (al massimo uno alla volta).
final pendingWeeklyPlanProvider = Provider<WeeklyPlan?>((ref) {
  final plans = ref.watch(weeklyPlansProvider).valueOrNull;
  for (final plan in plans ?? const <WeeklyPlan>[]) {
    if (plan.status == WeeklyPlanStatus.generating) {
      return plan;
    }
  }
  return null;
});

/// L'ultimo tentativo, se è finito male e non è già stato rimpiazzato da un
/// piano nuovo: serve a mostrare il messaggio onesto.
final failedWeeklyPlanProvider = Provider<WeeklyPlan?>((ref) {
  final plans = ref.watch(weeklyPlansProvider).valueOrNull;
  final latest = (plans ?? const <WeeklyPlan>[]).firstOrNull;
  return latest?.status == WeeklyPlanStatus.failed ? latest : null;
});

/// Polling gentile mentre il Mac lavora: una lettura ogni 15 s, e solo
/// finché esiste un piano in preparazione.
final weeklyPlanPollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 15),
);

class WeeklyPlanUiState {
  const WeeklyPlanUiState({
    this.busy = false,
    this.busySlotId,
    this.error,
    this.lastCheckedAt,
  });

  /// Generazione in corso (il tocco su "Genera il piano").
  final bool busy;

  /// Slot su cui è in corso un'azione ("Fatto", "Annulla", "Sostituisci").
  final String? busySlotId;

  /// Messaggio già in italiano, pronto da mostrare.
  final String? error;
  final DateTime? lastCheckedAt;

  WeeklyPlanUiState copyWith({
    bool? busy,
    String? busySlotId,
    bool clearBusySlot = false,
    String? error,
    bool clearError = false,
    DateTime? lastCheckedAt,
  }) => WeeklyPlanUiState(
    busy: busy ?? this.busy,
    busySlotId: clearBusySlot ? null : (busySlotId ?? this.busySlotId),
    error: clearError ? null : (error ?? this.error),
    lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
  );
}

/// Azioni della schermata Piano: generazione, attesa e gestione degli slot.
///
/// Nessun generatore locale di riserva: se il Mac non risponde il piano
/// diventa `failed` con un messaggio onesto e i piani vecchi restano.
class WeeklyPlanController extends Notifier<WeeklyPlanUiState> {
  Timer? _timer;
  bool _disposed = false;
  bool _refreshing = false;

  @override
  WeeklyPlanUiState build() {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _timer?.cancel();
      _timer = null;
    });
    // `listen` e non `watch`: un rebuild del notifier a ogni riga scritta
    // spegnerebbe il timer proprio mentre serve.
    ref.listen(weeklyPlansProvider, (previous, next) {
      final pending = (next.valueOrNull ?? const <WeeklyPlan>[]).any(
        (plan) => plan.status == WeeklyPlanStatus.generating,
      );
      if (!pending) {
        _timer?.cancel();
        _timer = null;
        return;
      }
      if (_timer == null && !_refreshing) {
        unawaited(refreshNow());
      }
    });
    return const WeeklyPlanUiState();
  }

  Future<bool> generate({
    required DateTime startDate,
    required int days,
    required Iterable<PlanMeal> meals,
    String notes = '',
  }) async {
    if (state.busy) {
      return false;
    }
    state = state.copyWith(busy: true, clearError: true);
    try {
      final profile = await ref.read(marcoProfileProvider.future);
      final targets = await ref.read(nutritionTargetProvider.future);
      await ref
          .read(weeklyPlanRepositoryProvider)
          .generatePlan(
            profileId: profile.id,
            startDate: startDate,
            days: days,
            meals: meals,
            targets: targets,
            notes: notes,
          );
      if (!_disposed) {
        state = state.copyWith(busy: false, clearError: true);
      }
      return true;
    } on Object catch (error) {
      if (!_disposed) {
        state = state.copyWith(busy: false, error: _messageOf(error));
      }
      return false;
    }
  }

  /// Un giro di polling immediato sul piano in attesa.
  Future<void> refreshNow() async {
    if (_disposed || _refreshing) {
      return;
    }
    _timer?.cancel();
    _timer = null;
    final pending = ref.read(pendingWeeklyPlanProvider);
    if (pending == null) {
      return;
    }
    _refreshing = true;
    try {
      await ref.read(weeklyPlanRepositoryProvider).refreshPlan(pending.id);
      if (!_disposed) {
        state = state.copyWith(
          clearError: true,
          lastCheckedAt: AppTime.nowUtc(),
        );
      }
    } on Object {
      // Offline non si dichiara nulla: si riproverà al prossimo giro.
    } finally {
      _refreshing = false;
    }
    _scheduleNext();
  }

  Future<bool> markDone(WeeklyPlanSlot slot) =>
      _slotAction(slot.id, (repository) => repository.markSlotDone(slot.id));

  Future<bool> undo(WeeklyPlanSlot slot) =>
      _slotAction(slot.id, (repository) => repository.undoSlotDone(slot.id));

  Future<bool> replace(WeeklyPlanSlot slot, String recipeId) => _slotAction(
    slot.id,
    (repository) =>
        repository.replaceSlotRecipe(slotId: slot.id, recipeId: recipeId),
  );

  Future<bool> _slotAction(
    String slotId,
    Future<void> Function(WeeklyPlanRepository repository) action,
  ) async {
    if (state.busySlotId != null) {
      return false;
    }
    state = state.copyWith(busySlotId: slotId, clearError: true);
    try {
      await action(ref.read(weeklyPlanRepositoryProvider));
      if (!_disposed) {
        state = state.copyWith(clearBusySlot: true, clearError: true);
      }
      return true;
    } on Object catch (error) {
      if (!_disposed) {
        state = state.copyWith(clearBusySlot: true, error: _messageOf(error));
      }
      return false;
    }
  }

  void _scheduleNext() {
    if (_disposed) {
      return;
    }
    _timer?.cancel();
    _timer = null;
    if (ref.read(pendingWeeklyPlanProvider) == null) {
      return;
    }
    _timer = Timer(
      ref.read(weeklyPlanPollIntervalProvider),
      () => unawaited(refreshNow()),
    );
  }

  String _messageOf(Object error) => switch (error) {
    WeeklyPlanException(:final message) => message,
    FormatException(:final message) => message,
    _ => 'Qualcosa è andato storto con il piano: riprova.',
  };
}

final weeklyPlanControllerProvider =
    NotifierProvider<WeeklyPlanController, WeeklyPlanUiState>(
      WeeklyPlanController.new,
    );
