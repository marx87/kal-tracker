import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/workouts/data/workout_history_models.dart';
import 'package:kal_tracker/features/workouts/presentation/history/widgets/weekly_volume_card.dart';
import 'package:kal_tracker/features/workouts/presentation/history/widgets/workout_session_card.dart';
import 'package:kal_tracker/features/workouts/presentation/history/workout_detail_screen.dart';
import 'package:kal_tracker/features/workouts/presentation/history/workout_formatting.dart';
import 'package:kal_tracker/features/workouts/presentation/history/workout_history_providers.dart';
import 'package:kal_tracker/features/workouts/presentation/history/workout_history_stats.dart';

/// Lo storico degli allenamenti: la prima finestra sulle sessioni arrivate
/// da Gym Tracker.
///
/// È una schermata di sola lettura. Niente eliminazioni con lo scorrimento
/// come in Gym: su dati appena migrati, e ancora senza un annulla, un gesto
/// distratto costerebbe una sessione che non si può rifare.
class WorkoutHistoryScreen extends ConsumerWidget {
  const WorkoutHistoryScreen({super.key, this.onOpenSession});

  /// Come si apre una sessione. Lasciato nullo la schermata si apre da sola
  /// con una rotta locale: così funziona anche prima che l'integratore
  /// registri il dettaglio nel router, e dopo basta passare la callback.
  final void Function(BuildContext context, String workoutId)? onOpenSession;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final history = ref.watch(workoutHistoryProvider);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Allenamenti'),
            Text(
              'Lo storico che arriva da Gym',
              style: theme.textTheme.bodySmall?.copyWith(
                color: accents.mutedInk,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
      body: history.when(
        data: (sessions) => sessions.isEmpty
            ? const _NothingImportedYet()
            : _HistoryBody(
                sessions: sessions,
                onOpenSession: (workoutId) => _open(context, workoutId),
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => _HistoryError(
          onRetry: () => ref.invalidate(workoutHistoryProvider),
        ),
      ),
    );
  }

  void _open(BuildContext context, String workoutId) {
    final handler = onOpenSession;
    if (handler != null) {
      handler(context, workoutId);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => WorkoutDetailScreen(workoutId: workoutId),
      ),
    );
  }
}

class _HistoryBody extends ConsumerWidget {
  const _HistoryBody({required this.sessions, required this.onOpenSession});

  final List<WorkoutSummary> sessions;
  final ValueChanged<String> onOpenSession;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final period = ref.watch(workoutPeriodProvider);
    final filtered = filterByPeriod(sessions, period, historyNow());
    final stats = aggregateHistory(filtered);
    final months = groupByMonth(filtered);

    return AdaptiveContent(
      child: ListView(
        key: const Key('workout_history_list'),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          _PeriodChips(
            selected: period,
            onChanged: (value) =>
                ref.read(workoutPeriodProvider.notifier).state = value,
          ),
          const SizedBox(height: 16),
          _TotalsCard(stats: stats, period: period),
          const SizedBox(height: 18),
          // Il volume settimanale sta SOTTO i totali e non sopra perché non
          // obbedisce alle pastiglie del periodo: ha una settimana sua, con
          // le sue frecce, e messo in mezzo alle pastiglie sembrerebbe
          // filtrato da loro.
          const WeeklyVolumeCard(),
          const SizedBox(height: 18),
          if (filtered.isEmpty)
            const AppEmptyState(
              key: Key('workout_period_empty'),
              icon: Icons.event_busy_rounded,
              title: 'Niente in questo periodo',
              message:
                  'Nessuna sessione nell’intervallo scelto. Allarga il '
                  'periodo per rivedere lo storico più vecchio.',
            )
          else
            for (final month in months) ...[
              _MonthHeader(month: month),
              for (final session in month.sessions) ...[
                WorkoutSessionCard(
                  summary: session,
                  onOpen: () => onOpenSession(session.id),
                ),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 6),
            ],
        ],
      ),
    );
  }
}

/// Le cinque finestre temporali. Sono pastiglie a scelta singola, con il
/// bersaglio da 48 garantito dall'altezza minima.
class _PeriodChips extends StatelessWidget {
  const _PeriodChips({required this.selected, required this.onChanged});

  final WorkoutPeriod selected;
  final ValueChanged<WorkoutPeriod> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: WorkoutPeriod.values.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final period = WorkoutPeriod.values[index];
          final isSelected = period == selected;
          return Center(
            child: ChoiceChip(
              key: Key('workout_period_${period.name}'),
              selected: isSelected,
              onSelected: (_) => onChanged(period),
              showCheckmark: false,
              label: Text(period.label),
              labelStyle: theme.textTheme.labelLarge?.copyWith(
                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                color: isSelected
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurface,
              ),
              selectedColor: theme.colorScheme.primaryContainer,
              backgroundColor: theme.colorScheme.surfaceContainerLow,
              side: BorderSide(color: theme.colorScheme.outline),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// I totali del periodo. Il tempo dichiara sempre che cosa NON ha sommato.
class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.stats, required this.period});

  final WorkoutHistoryStats stats;
  final WorkoutPeriod period;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return SectionCard(
      key: const Key('workout_totals_card'),
      title: 'Totali · ${period.label}',
      subtitle: 'Solo le sessioni chiuse',
      icon: Icons.insights_rounded,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
      child: Column(
        children: [
          StatRow(
            key: const Key('workout_total_sessions'),
            label: 'Sessioni',
            value: formatWholeNumber(stats.sessions),
            icon: Icons.event_available_rounded,
          ),
          const Divider(),
          StatRow(
            key: const Key('workout_total_volume'),
            label: 'Volume',
            value: formatVolume(stats.volume),
            unit: 'kg',
            unitSemantics: 'chilogrammi',
            icon: Icons.fitness_center_rounded,
          ),
          const Divider(),
          StatRow(
            key: const Key('workout_total_kcal'),
            label: 'Calorie stimate',
            value: formatKcal(stats.kcal),
            unit: 'kcal',
            unitSemantics: 'chilocalorie',
            caption: 'Stima di Gym, non una misura',
            icon: Icons.local_fire_department_rounded,
          ),
          const Divider(),
          StatRow(
            key: const Key('workout_total_time'),
            label: 'Tempo',
            value: formatDuration(stats.time),
            icon: Icons.timer_outlined,
            trailing: stats.hasSuspect
                ? const StatusChip(
                    level: AppStatusLevel.warning,
                    label: 'Parziale',
                    compact: true,
                  )
                : null,
          ),
          if (stats.hasSuspect)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 8),
              child: Text(
                key: const Key('workout_total_time_note'),
                stats.suspectSessions == 1
                    ? 'Una sessione è fuori dal totale: la sua durata non è '
                          'attendibile e sommarla falserebbe il tempo.'
                    : '${stats.suspectSessions} sessioni sono fuori dal '
                          'totale: la loro durata non è attendibile e '
                          'sommarle falserebbe il tempo.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: accents.mutedInk,
                  height: 1.35,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MonthHeader extends StatelessWidget {
  const _MonthHeader({required this.month});

  final WorkoutMonthGroup month;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final sessions = month.sessions.length;
    final details = <String>[
      sessions == 1 ? '1 sessione' : '$sessions sessioni',
      if (month.volume > 0) '${formatVolume(month.volume)} kg',
      if (month.kcal > 0) '${formatKcal(month.kcal)} kcal',
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
      child: Semantics(
        header: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(month.label, style: theme.textTheme.titleLarge),
            const SizedBox(height: 2),
            Text(
              details.join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: accents.mutedInk,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NothingImportedYet extends StatelessWidget {
  const _NothingImportedYet();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: AdaptiveContent(
          child: const AppEmptyState(
            key: Key('workout_history_empty'),
            icon: Icons.fitness_center_rounded,
            title: 'Ancora nessun allenamento',
            message:
                'Qui compaiono le sessioni di Gym Tracker appena vengono '
                'importate: data, durata, volume e come è andata.',
          ),
        ),
      ),
    );
  }
}

class _HistoryError extends StatelessWidget {
  const _HistoryError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: AppEmptyState(
          key: const Key('workout_history_error'),
          icon: Icons.cloud_off_rounded,
          title: 'Storico non leggibile',
          message:
              'Non riesco a leggere le sessioni dal database locale. '
              'Riprova: se insiste, il problema è nell’archivio, non nella '
              'connessione.',
          actionLabel: 'Riprova',
          onAction: onRetry,
        ),
      ),
    );
  }
}
