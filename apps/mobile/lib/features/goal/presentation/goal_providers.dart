import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/goal/data/body_state_repository.dart';
import 'package:kal_tracker/features/goal/data/goal_repository.dart';
import 'package:kal_tracker/features/goal/data/goal_store.dart';
import 'package:kal_tracker/features/goal/domain/body_state.dart';
import 'package:kal_tracker/features/goal/domain/definition_level.dart';
import 'package:kal_tracker/features/goal/domain/goal.dart';
import 'package:kal_tracker/features/goal/domain/goal_plan.dart';
import 'package:kal_tracker/features/goal/domain/tdee.dart';

/// Store su file JSON dell'Obiettivo: nei test si sostituisce con quello in
/// memoria.
final goalStoreProvider = Provider<GoalStore>((ref) => FileGoalStore());

final goalRepositoryProvider = Provider<GoalRepository>(
  (ref) => GoalRepository(ref.watch(goalStoreProvider)),
);

final bodyStateRepositoryProvider = Provider<BodyStateRepository>(
  (ref) => BodyStateRepository(ref.watch(databaseProvider)),
);

/// Peso, massa magra, media a 7 giorni e finestra per il TDEE.
final bodyStateProvider = StreamProvider<BodyState>((ref) async* {
  final repository = ref.watch(bodyStateRepositoryProvider);
  final profile = await ref.watch(marcoProfileProvider.future);
  yield* repository.watch(profile.id);
});

/// Quanto ci si muove. Finché il profilo non ha un campo suo, resta
/// «Attivo»: è la stima che vale solo le prime due settimane, poi il TDEE
/// misurato la sostituisce e questo valore smette di contare.
final activityLevelProvider = Provider<ActivityLevel>(
  (ref) => ActivityLevel.moderate,
);

final goalControllerProvider =
    AsyncNotifierProvider<GoalController, GoalHistory>(GoalController.new);

/// L'obiettivo corrente e il suo storico.
///
/// Ogni operazione riscrive lo stato e poi persiste: la schermata reagisce
/// subito, il file arriva dopo. È lo stesso patto delle impostazioni acqua.
class GoalController extends AsyncNotifier<GoalHistory> {
  @override
  Future<GoalHistory> build() => ref.watch(goalRepositoryProvider).read();

  Future<void> setGoal({
    required double targetWeightKg,
    required DefinitionLevel targetLevel,
    required double paceKgPerWeek,
    required double currentWeightKg,
    required double fatFreeMassKg,
  }) async {
    final updated = await ref
        .read(goalRepositoryProvider)
        .setGoal(
          targetWeightKg: targetWeightKg,
          targetLevel: targetLevel,
          paceKgPerWeek: paceKgPerWeek,
          currentWeightKg: currentWeightKg,
          fatFreeMassKg: fatFreeMassKg,
        );
    state = AsyncData(updated);
  }

  /// Il peso di adesso serve al limite di sicurezza: 0,7 % del peso, non
  /// una soglia in chili buona per chiunque.
  Future<void> setPace({
    required double paceKgPerWeek,
    required double currentWeightKg,
  }) async {
    state = AsyncData(
      await ref
          .read(goalRepositoryProvider)
          .setPace(
            paceKgPerWeek: paceKgPerWeek,
            currentWeightKg: currentWeightKg,
          ),
    );
  }

  Future<void> setPhase(GoalPhase phase) async {
    state = AsyncData(await ref.read(goalRepositoryProvider).setPhase(phase));
  }

  /// Rimette in corsa l'obiettivo di prima. Torna `false` quando non c'è
  /// niente da ripristinare, così la UI non promette un annullamento che non
  /// può fare.
  Future<bool> undoLastChange() async {
    final repository = ref.read(goalRepositoryProvider);
    final before = await repository.read();
    if (before.past.isEmpty) {
      return false;
    }
    state = AsyncData(await repository.undoLastChange());
    return true;
  }

  Future<void> clear() async {
    state = AsyncData(await ref.read(goalRepositoryProvider).clearGoal());
  }
}

/// Il piano di oggi, o `null` quando non c'è un obiettivo (o non ci sono
/// abbastanza dati per calcolarlo). **Nessun altro pezzo dell'app dipende da
/// questo**: senza obiettivo tutto il resto continua a funzionare.
final goalPlanProvider = Provider<AsyncValue<GoalPlan?>>((ref) {
  final history = ref.watch(goalControllerProvider);
  final body = ref.watch(bodyStateProvider);

  if (history.hasError) {
    return AsyncValue.error(
      history.error!,
      history.stackTrace ?? StackTrace.empty,
    );
  }
  if (body.hasError) {
    return AsyncValue.error(body.error!, body.stackTrace ?? StackTrace.empty);
  }
  if (history.isLoading || body.isLoading) {
    return const AsyncValue.loading();
  }

  final goal = history.valueOrNull?.current;
  final state = body.valueOrNull;
  final weight = state?.weightKg;
  final fatFreeMass = state?.fatFreeMassKg;
  if (goal == null || weight == null || fatFreeMass == null) {
    return const AsyncValue.data(null);
  }

  return AsyncValue.data(
    GoalPlanner.build(
      goal: goal,
      currentWeightKg: weight,
      fatFreeMassKg: fatFreeMass,
      tdee: AdaptiveTdee.resolve(
        fatFreeMassKg: fatFreeMass,
        activity: ref.watch(activityLevelProvider),
        sample: state?.tdeeSample,
      ),
      today: ref.watch(todayProvider),
    ),
  );
});
