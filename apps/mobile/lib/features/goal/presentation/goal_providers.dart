import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/goal/data/activity_settings_store.dart';
import 'package:kal_tracker/features/goal/data/body_state_repository.dart';
import 'package:kal_tracker/features/goal/data/goal_repository.dart';
import 'package:kal_tracker/features/goal/data/goal_store.dart';
import 'package:kal_tracker/features/goal/domain/activity_multiplier.dart';
import 'package:kal_tracker/features/goal/domain/body_composition.dart';
import 'package:kal_tracker/features/goal/domain/body_state.dart';
import 'package:kal_tracker/features/goal/domain/definition_level.dart';
import 'package:kal_tracker/features/goal/domain/goal.dart';
import 'package:kal_tracker/features/goal/domain/goal_plan.dart';
import 'package:kal_tracker/features/goal/domain/tdee.dart';

/// Store Drift dell'Obiettivo (v7): nei test si sostituisce con quello in
/// memoria. Alla prima lettura porta dentro il vecchio file JSON e lo
/// archivia.
final goalStoreProvider = Provider<GoalStore>(
  (ref) => DriftGoalStore(ref.watch(databaseProvider)),
);

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

/// Store su file JSON di quanto ci si muove: nei test si sostituisce con
/// quello in memoria.
final activitySettingsStoreProvider = Provider<ActivitySettingsStore>(
  (ref) => FileActivitySettingsStore(),
);

final activitySettingsProvider =
    AsyncNotifierProvider<ActivitySettingsController, ActivitySettings>(
      ActivitySettingsController.new,
    );

/// Il livello scelto e l'eventuale derivato accettato, con un posto dove
/// scriverli.
///
/// Prima erano una costante: `ActivityLevel.moderate` scritto nel provider.
/// Con una costante il sì di Marco alla proposta del moltiplicatore non
/// avrebbe avuto dove andare — l'app avrebbe chiesto «vuoi aggiornare?» e poi
/// dimenticato la risposta al primo rebuild.
class ActivitySettingsController extends AsyncNotifier<ActivitySettings> {
  @override
  Future<ActivitySettings> build() =>
      ref.watch(activitySettingsStoreProvider).read();

  ActivitySettings get _current =>
      state.valueOrNull ?? const ActivitySettings();

  /// Stesso patto dell'Obiettivo e delle impostazioni acqua: lo stato in
  /// memoria cambia subito, il file arriva dopo.
  Future<void> setDeclared(ActivityLevel level) =>
      _save(_current.withDeclared(level));

  /// Il sì di Marco alla proposta. **È l'unico modo in cui il derivato entra
  /// nel TDEE**: nessun percorso automatico porta qui.
  ///
  /// La forbice è quella di [AdaptiveTdee.isUsableMultiplier] e non un
  /// controllo nuovo: un numero che il TDEE ignorerebbe non va scritto, o
  /// resterebbe per sempre in un file a non fare niente.
  Future<void> acceptDerivedMultiplier(double multiplier) async {
    if (!AdaptiveTdee.isUsableMultiplier(multiplier)) {
      throw const FormatException('Il moltiplicatore non è utilizzabile.');
    }
    await _save(_current.withAcceptedMultiplier(multiplier));
  }

  /// Il ripensamento: si torna al livello dichiarato, che era rimasto lì
  /// sotto tutto il tempo.
  Future<void> discardDerivedMultiplier() =>
      _save(_current.withoutAcceptedMultiplier());

  Future<void> _save(ActivitySettings updated) async {
    state = AsyncData(updated);
    await ref.read(activitySettingsStoreProvider).write(updated);
  }
}

/// Quanto ci si muove secondo la tendina. Finché la lettura non è finita vale
/// «Attivo»: è la stima delle prime due settimane, poi il TDEE misurato la
/// sostituisce e questo valore smette di contare.
final activityLevelProvider = Provider<ActivityLevel>(
  (ref) =>
      ref.watch(activitySettingsProvider).valueOrNull?.declared ??
      const ActivitySettings().declared,
);

/// Il moltiplicatore derivato **in vigore**: c'è solo dopo un sì esplicito, e
/// finché è nullo il TDEE resta sul dichiarato.
final acceptedActivityMultiplierProvider = Provider<double?>(
  (ref) => ref.watch(activitySettingsProvider).valueOrNull?.acceptedMultiplier,
);

/// Gli allenamenti su cui misurare il moltiplicatore, e il giorno da cui
/// esistono dati.
typedef ActivityTrainingHistory = ({
  List<TrainingSessionKcal> sessions,
  DateTime? firstRecordedAt,
});

/// Da dove arrivano gli allenamenti. **Oggi è vuoto.**
///
/// Riempirlo tocca al repository degli allenamenti, che deve esporre per ogni
/// sessione le kcal, il MET medio con cui sono state calcolate e se gli
/// snapshot dei gruppi muscolari erano completi: tre cose che oggi
/// `WorkoutSummary` non porta. Finché resta vuoto la proposta si rifiuta da
/// sola e dichiara il perché — nessun numero inventato entra da qui, e il
/// TDEE continua a usare il livello dichiarato.
final activityTrainingHistoryProvider = Provider<ActivityTrainingHistory>(
  (ref) => (sessions: const [], firstRecordedAt: null),
);

/// La proposta del moltiplicatore derivato, o `null` mentre il corpo si sta
/// ancora leggendo.
///
/// Una proposta esiste anche quando si rifiuta: è quella che porta la frase
/// da mostrare al posto del numero. Quello che NON fa è applicarsi — il TDEE
/// qui sotto legge [acceptedActivityMultiplierProvider], non questo.
final activityMultiplierProposalProvider =
    Provider<ActivityMultiplierProposal?>((ref) {
      final body = ref.watch(bodyStateProvider);
      if (body.isLoading || body.hasError) {
        return null;
      }
      final fatFreeMass = body.valueOrNull?.fatFreeMassKg;
      final history = ref.watch(activityTrainingHistoryProvider);
      final now = ref.watch(todayProvider);

      return DerivedActivityMultiplier.propose(
        // Zero non è una massa magra: si passa di proposito perché la frase
        // da mostrare («senza una pesata completa...») la sa il dominio, e
        // riscriverla qui vorrebbe dire tenerla in due posti.
        basalMetabolicRate: fatFreeMass == null
            ? 0
            : BodyComposition.basalMetabolicRate(fatFreeMass),
        declared: ref.watch(activityLevelProvider),
        sessions: history.sessions,
        now: now,
        // I passi non li misura nessuno, per ora: il NEAT resta al pavimento
        // invece di inventare il movimento che non si è visto.
        averageDailySteps: null,
        // Senza nemmeno un allenamento registrato lo storico comincia adesso:
        // zero settimane coperte, e il derivato si rifiuta da sé.
        historyStartsAt: history.firstRecordedAt ?? now,
      );
    });

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
        // Nullo finché Marco non ha detto sì: la proposta esiste da un'altra
        // parte e resta lì fino a quel momento.
        derivedMultiplier: ref.watch(acceptedActivityMultiplierProvider),
      ),
      today: ref.watch(todayProvider),
    ),
  );
});
