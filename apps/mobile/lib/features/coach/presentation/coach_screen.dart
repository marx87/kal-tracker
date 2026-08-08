import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/coach/domain/coach_dates.dart';
import 'package:kal_tracker/features/coach/domain/coach_metrics.dart';
import 'package:kal_tracker/features/coach/presentation/coach_providers.dart';
import 'package:kal_tracker/features/coach/presentation/widgets/coach_cards.dart';

/// **Il rapporto della domenica.**
///
/// Due metà con due destini diversi: i numeri li calcola il telefono e ci
/// sono sempre — offline, senza obiettivo, col Mac spento — mentre il perché
/// lo scrive il Mac e può mancare. Quando manca lo si dice, e l'ultimo
/// commento arrivato resta leggibile con la data della sua settimana.
class CoachScreen extends ConsumerWidget {
  const CoachScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final week = ref.watch(coachWeekProvider);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Coach'),
            Text(
              'Rapporto della ${coachWeekdayLabel(week.end)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: accents.mutedInk,
              ),
            ),
          ],
        ),
      ),
      body: AdaptiveContent(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(coachSnapshotProvider);
            await ref.read(coachControllerProvider.notifier).refreshNow();
          },
          child: ListView(
            key: const Key('coach_list'),
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
            children: _children(context, ref),
          ),
        ),
      ),
    );
  }

  List<Widget> _children(BuildContext context, WidgetRef ref) {
    final metrics = ref.watch(coachMetricsProvider);
    final controller = ref.watch(coachControllerProvider);

    if (metrics.hasError) {
      return [
        _RetryCard(
          label: 'Ricarica il rapporto',
          onRetry: () => ref.invalidate(coachSnapshotProvider),
        ),
      ];
    }
    if (metrics.isLoading) {
      return const [_LoadingCard()];
    }

    final report = metrics.requireValue;
    final ui = controller.valueOrNull;

    return [
      _HeaderCard(metrics: report),
      // Il movimento prima del consumo, sempre: è l'ordine in cui si legge
      // una settimana che si è fermata. Al contrario il rapporto direbbe
      // «consumi meno» e solo dopo «ti sei mosso meno», cioè proporrebbe di
      // togliere calorie prima di aver nominato la causa.
      if (ref.watch(coachNeatProvider) case final neat?) ...[
        const SizedBox(height: 14),
        CoachNeatCard(trend: neat),
      ],
      const SizedBox(height: 14),
      CoachTdeeCard(metrics: report),
      const SizedBox(height: 14),
      CoachAdherenceCard(adherence: report.adherence),
      const SizedBox(height: 14),
      CoachRecompositionCard(recomposition: report.recomposition),
      if (report.projection case final projection?) ...[
        const SizedBox(height: 14),
        CoachProjectionCard(projection: projection),
      ],
      const SizedBox(height: 14),
      CoachOvertrainingCard(light: report.overtraining),
      if (report.falseMovement.explanation != null) ...[
        const SizedBox(height: 14),
        CoachFalseMovementCard(movement: report.falseMovement),
      ],
      const SizedBox(height: 14),
      CoachNarrativeCard(
        narrative: ui?.archive.last,
        isWaiting: ui?.isWaiting ?? false,
        currentWeekEnd: report.week.end,
        // L'errore del gesto appena fatto ha la precedenza su quello vecchio
        // del Mac: parla di adesso.
        error: ui?.error ?? ui?.archive.lastError,
        busy: ui?.busy ?? controller.isLoading,
        onRequest: ui == null ? null : () => _request(context, ref, report),
        onCancel: ui == null
            ? null
            : () => ref.read(coachControllerProvider.notifier).cancelPending(),
      ),
    ];
  }

  Future<void> _request(
    BuildContext context,
    WidgetRef ref,
    CoachMetrics metrics,
  ) async {
    final sent = await ref
        .read(coachControllerProvider.notifier)
        .requestNarrative(metrics);
    if (!context.mounted || !sent) {
      return;
    }
    // Senza azione: quelli con «Annulla» passano sempre da
    // [showAutoClosingSnackBar], che è l'unico modo perché si chiudano.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Chiesto al Mac. I numeri sono già tutti qui: manca solo il perché.',
        ),
      ),
    );
  }
}

/// La settimana, e quanto è piena.
class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.metrics});

  final CoachMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final filled = metrics.filledSlots;

    return SectionCard(
      key: const Key('coach_header_card'),
      title: 'Settimana del ${coachDayLabel(metrics.week.start)}',
      subtitle:
          'Dal ${coachDayLabel(metrics.week.start)} al '
          '${coachDayLabel(metrics.week.end)}',
      icon: Icons.insights_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StatRow(
            label: 'Dati della settimana',
            value: '$filled/${CoachMetrics.totalSlots}',
            caption: filled == CoachMetrics.totalSlots
                ? 'Diario, pesate, composizione e segnali: c’è tutto.'
                : 'Quello che manca non viene indovinato: resta vuoto.',
            trailing: StatusChip(
              level: filled >= 3
                  ? AppStatusLevel.good
                  : filled >= 2
                  ? AppStatusLevel.warning
                  : AppStatusLevel.critical,
              label: filled >= 3
                  ? 'Solido'
                  : filled >= 2
                  ? 'Parziale'
                  : 'Scarso',
              compact: true,
            ),
          ),
          StatRow(
            label: 'Allenamenti',
            value: metrics.workoutsDone.toString(),
            caption: 'Sessioni chiuse nella settimana',
            icon: Icons.fitness_center_rounded,
          ),
          if (metrics.intake.days == 0)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: AppEmptyState(
                key: Key('coach_no_diary'),
                compact: true,
                icon: Icons.restaurant_outlined,
                message:
                    'In questa settimana non c’è nessun giorno di diario: '
                    'senza, le calorie non si possono né misurare né '
                    'giudicare.',
              ),
            ),
        ],
      ),
    );
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
        key: const Key('coach_retry'),
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded),
        label: Text(label),
      ),
    ),
  );
}
