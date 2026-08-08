import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/goal/domain/body_state.dart';
import 'package:kal_tracker/features/goal/domain/goal.dart';
import 'package:kal_tracker/features/goal/domain/goal_pace.dart';
import 'package:kal_tracker/features/goal/domain/goal_plan.dart';
import 'package:kal_tracker/features/goal/presentation/goal_providers.dart';
import 'package:kal_tracker/features/goal/presentation/widgets/activity_multiplier_card.dart';
import 'package:kal_tracker/features/goal/presentation/widgets/goal_cards.dart';
import 'package:kal_tracker/features/goal/presentation/widgets/goal_pace_sheet.dart';
import 'package:kal_tracker/features/goal/presentation/widgets/goal_target_sheet.dart';

/// **Obiettivo.** Il cuore del prodotto: l'app non misura e basta, porta a un
/// traguardo e poi ci mantiene.
///
/// Funziona in tutti gli stati intermedi, perché sono tutti normali: senza
/// pesate, con il peso ma senza composizione corporea, e soprattutto **senza
/// obiettivo** — che non è un guasto da riparare con un avviso rosso ma una
/// scelta legittima.
class GoalScreen extends ConsumerStatefulWidget {
  const GoalScreen({super.key});

  @override
  ConsumerState<GoalScreen> createState() => _GoalScreenState();
}

class _GoalScreenState extends ConsumerState<GoalScreen> {
  /// Un passaggio di fase alla volta: senza questa guardia ogni frame ne
  /// programmerebbe un altro prima che il primo sia scritto.
  bool _advancingPhase = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    _maybeAdvancePhase(ref.watch(goalPlanProvider).valueOrNull);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Obiettivo'),
            Text(
              'Dove stai andando, e cosa comporta oggi',
              style: theme.textTheme.bodySmall?.copyWith(
                color: accents.mutedInk,
              ),
            ),
          ],
        ),
      ),
      body: AdaptiveContent(
        child: RefreshIndicator(
          // Le calorie del diario entrano nel TDEE misurato alla pesata
          // successiva: questa è la scorciatoia per non aspettarla.
          onRefresh: () async {
            ref.invalidate(bodyStateProvider);
            // Gli allenamenti si leggono una volta e restano: senza questa
            // riga la seduta chiusa stamattina non entrerebbe nella proposta
            // fino al riavvio dell'app.
            ref.invalidate(activityTrainingHistoryProvider);
          },
          child: ListView(
            key: const Key('goal_list'),
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
            children: _children(context, ref),
          ),
        ),
      ),
    );
  }

  /// **Il piano non si spegne da solo.** Arrivati al traguardo si passa al
  /// consolidamento, e quando il deficit è riassorbito al mantenimento: senza
  /// chiedere niente, ma dicendolo.
  ///
  /// Il controllo si legge in `build` perché è lì che il piano è fresco, ma la
  /// scrittura parte dopo il frame: cambiare stato durante una build è il
  /// modo più rapido per ritrovarsi con un ciclo infinito.
  void _maybeAdvancePhase(GoalPlan? plan) {
    if (plan == null || _advancingPhase) {
      return;
    }
    final next = GoalPhasePolicy.nextPhase(
      goal: plan.goal,
      currentWeightKg: plan.currentWeightKg,
      today: ref.read(todayProvider),
    );
    if (next == plan.goal.phase) {
      return;
    }

    _advancingPhase = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await ref.read(goalControllerProvider.notifier).setPhase(next);
      } finally {
        _advancingPhase = false;
      }
      if (!mounted) {
        return;
      }
      // Il peso che risale in consolidamento è glicogeno e acqua: spiegarlo
      // adesso evita di doverlo spiegare dopo, a scoraggiamento avvenuto.
      _say(context, switch (next) {
        GoalPhase.consolidation =>
          'Ci sei. Da oggi si risale piano: il chilo che torna su in questi '
              'giorni è glicogeno e acqua, non grasso.',
        GoalPhase.maintenance =>
          'Deficit riassorbito: da qui in poi conta la banda, non il numero '
              'esatto.',
        GoalPhase.approach => 'Si riparte con un avvicinamento.',
      });
    });
  }

  List<Widget> _children(BuildContext context, WidgetRef ref) {
    final body = ref.watch(bodyStateProvider);
    final history = ref.watch(goalControllerProvider);
    final plan = ref.watch(goalPlanProvider);

    if (body.hasError) {
      return [
        _RetryCard(
          label: 'Ricarica i dati del corpo',
          onRetry: () => ref.invalidate(bodyStateProvider),
        ),
      ];
    }
    if (body.isLoading || history.isLoading) {
      return const [_LoadingCard()];
    }

    final state = body.valueOrNull ?? const BodyState.unknown();
    final past = history.valueOrNull?.past ?? const <Goal>[];

    if (!state.hasWeight) {
      return const [
        AppEmptyState(
          key: Key('goal_needs_weight'),
          title: 'Prima una pesata',
          message:
              'L\'obiettivo si costruisce sul tuo corpo, non su una tabella. '
              'Registra una pesata e torna qui: bastano dieci secondi.',
          icon: Icons.monitor_weight_outlined,
        ),
      ];
    }

    if (!state.hasComposition) {
      return [
        const AppEmptyState(
          key: Key('goal_needs_composition'),
          title: 'Manca la composizione',
          message:
              'So quanto pesi ma non quanto di quel peso è muscolo, e senza '
              'quello peso e definizione tornano a essere due cose scollegate. '
              'Serve una pesata completa sulla bilancia, con i piedi asciutti '
              'e ben appoggiati.',
          icon: Icons.scale_rounded,
        ),
        const SizedBox(height: 14),
        _NoteCard(
          text:
              'Nel frattempo il diario, l\'acqua e le ricette funzionano '
              'normalmente: l\'obiettivo è un di più, non un interruttore.',
        ),
      ];
    }

    final current = plan.valueOrNull;
    if (current == null) {
      return [
        AppEmptyState(
          key: const Key('goal_empty_state'),
          title: 'Nessun traguardo, per ora',
          message:
              'L\'app funziona lo stesso: continua a registrare e basta. '
              'Quando vuoi che ti porti da qualche parte, scegli dove.',
          icon: Icons.flag_outlined,
          actionLabel: 'Scegli un traguardo',
          onAction: () => _chooseTarget(context, ref, state, null),
        ),
        if (past.isNotEmpty) ...[
          const SizedBox(height: 14),
          GoalHistoryCard(past: past),
        ],
      ];
    }

    return [
      GoalHeaderCard(
        plan: current,
        sevenDayAverageKg: state.sevenDayAverageKg,
        onChangeTarget: () => _chooseTarget(context, ref, state, current),
      ),
      const SizedBox(height: 14),
      GoalTargetsCard(
        plan: current,
        onChangePace: () => _changePace(context, ref, current),
      ),
      // Subito sotto il consumo, che è il numero di cui parla: la domanda
      // «gli allenamenti dicono 1,48 invece di 1,55» letta a schermate di
      // distanza dalle calorie che cambierebbe non si capisce. Lo spazio se
      // lo porta dietro la card, che il più delle volte non c'è.
      const ActivityMultiplierCard(key: Key('goal_activity_card')),
      const SizedBox(height: 14),
      GoalPhaseCard(plan: current),
      if (current.band case final band?) ...[
        const SizedBox(height: 14),
        GoalBandCard(band: band, sevenDayAverageKg: state.sevenDayAverageKg),
      ],
      if (past.isNotEmpty) ...[
        const SizedBox(height: 14),
        GoalHistoryCard(past: past),
      ],
    ];
  }

  Future<void> _chooseTarget(
    BuildContext context,
    WidgetRef ref,
    BodyState state,
    GoalPlan? plan,
  ) async {
    final weight = state.weightKg;
    final fatFreeMass = state.fatFreeMassKg;
    if (weight == null || fatFreeMass == null) {
      return;
    }

    final choice = await showModalBottomSheet<GoalTargetChoice>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => GoalTargetSheet(
        currentWeightKg: weight,
        fatFreeMassKg: fatFreeMass,
        paceKgPerWeek:
            plan?.goal.paceKgPerWeek ?? PaceChoice.steady.kgPerWeekFor(weight),
        initialTargetWeightKg: plan?.goal.targetWeightKg,
        initialLevel: plan?.goal.targetLevel,
      ),
    );
    if (choice == null || !context.mounted) {
      return;
    }

    final hadGoal = plan != null;
    try {
      await ref
          .read(goalControllerProvider.notifier)
          .setGoal(
            targetWeightKg: choice.weightKg,
            targetLevel: choice.level,
            paceKgPerWeek:
                plan?.goal.paceKgPerWeek ??
                PaceChoice.steady.kgPerWeekFor(weight),
            currentWeightKg: weight,
            fatFreeMassKg: fatFreeMass,
          );
    } on FormatException catch (error) {
      // Il rifiuto del dominio ha già le parole giuste: ripeterlo con «non
      // riesco» toglierebbe l'unica informazione utile.
      if (context.mounted) {
        _say(context, error.message);
      }
      return;
    } on Object {
      if (context.mounted) {
        _say(context, 'Non riesco a salvare il traguardo.');
      }
      return;
    }
    if (!context.mounted) {
      return;
    }

    if (!hadGoal) {
      _say(context, 'Traguardo impostato. Il ritmo si cambia quando vuoi.');
      return;
    }
    // Cambiare traguardo è normale; cambiarlo con un dito di troppo sulla
    // manopola pure. L'annullamento rimette in corsa quello di prima.
    showAutoClosingSnackBar(
      ScaffoldMessenger.of(context),
      SnackBar(
        content: const Text('Traguardo aggiornato. Lo storico è rimasto.'),
        action: SnackBarAction(
          label: 'Annulla',
          onPressed: () =>
              ref.read(goalControllerProvider.notifier).undoLastChange(),
        ),
      ),
    );
  }

  Future<void> _changePace(
    BuildContext context,
    WidgetRef ref,
    GoalPlan plan,
  ) async {
    final pace = await showModalBottomSheet<double>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => GoalPaceSheet(
        currentWeightKg: plan.currentWeightKg,
        fatToLoseKg: plan.fatToLoseKg,
        paceKgPerWeek: plan.goal.paceKgPerWeek,
      ),
    );
    if (pace == null || !context.mounted) {
      return;
    }
    try {
      await ref
          .read(goalControllerProvider.notifier)
          .setPace(paceKgPerWeek: pace, currentWeightKg: plan.currentWeightKg);
      if (context.mounted) {
        _say(context, 'Ritmo aggiornato: deficit e data si sono ricalcolati.');
      }
    } on FormatException catch (error) {
      if (context.mounted) {
        _say(context, error.message);
      }
    } on Object {
      if (context.mounted) {
        _say(context, 'Non riesco a salvare il ritmo.');
      }
    }
  }

  /// Messaggio senza azione: quelli con «Annulla» passano sempre da
  /// [showAutoClosingSnackBar], che è l'unico modo perché si chiudano.
  void _say(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();

  @override
  Widget build(BuildContext context) => const Card(
    child: SizedBox(
      height: 140,
      child: Center(child: CircularProgressIndicator()),
    ),
  );
}

class _RetryCard extends StatelessWidget {
  const _RetryCard({required this.label, required this.onRetry});

  final String label;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: OutlinedButton.icon(
        key: const Key('goal_retry'),
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded),
        label: Text(label),
      ),
    ),
  );
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Text(
          text,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: AppAccents.of(context).mutedInk,
            height: 1.35,
          ),
        ),
      ),
    );
  }
}
