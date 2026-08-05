import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/routines/domain/routine_models.dart';
import 'package:kal_tracker/features/routines/presentation/routine_editor_screen.dart';
import 'package:kal_tracker/features/routines/presentation/routine_providers.dart';
import 'package:kal_tracker/features/routines/presentation/weekly_schedule_providers.dart';
import 'package:kal_tracker/features/weekly_plan/domain/plan_week.dart';

/// Apre il comporre-settimana. Come per l'editor delle schede è una
/// `MaterialPageRoute` e non una rotta con nome: la settimana si compone
/// dentro Palestra e si chiude tornando lì, senza passare dal router.
Future<void> openWeeklySchedule(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const WeeklyScheduleScreen()));

/// «Il martedì faccio Giorno1»: la settimana di allenamenti si compone qui.
///
/// Prima questa tabella la riempiva soltanto l'import di Gym, e una settimana
/// arrivata da un'app spenta non era più modificabile. La schermata Piano la
/// mostra già accanto ai pasti: quello che manca(va) è il posto dove deciderla.
///
/// Il giorno di riposo non è una scelta da registrare, è l'assenza di una
/// scheda: toglierla riporta il giorno a non esistere, esattamente come la
/// tabella si aspetta.
class WeeklyScheduleScreen extends ConsumerWidget {
  const WeeklyScheduleScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final schedule = ref.watch(weeklyScheduleProvider);
    final routines = ref.watch(routinesProvider);
    final today = ref.watch(todayWeekdayProvider);

    return Scaffold(
      appBar: AppBar(
        title: const _ScreenTitle(
          title: 'La settimana',
          subtitle: 'Che scheda fai, giorno per giorno',
        ),
      ),
      body: AdaptiveContent(
        child: switch ((schedule, routines)) {
          (AsyncError(:final error), _) ||
          (_, AsyncError(:final error)) => _LoadFailed(error: error),
          (AsyncData(value: final days), AsyncData(value: final available)) =>
            _Week(days: days, routines: available, today: today),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
    );
  }
}

class _Week extends ConsumerWidget {
  const _Week({
    required this.days,
    required this.routines,
    required this.today,
  });

  final Map<int, PlannedWorkout> days;
  final List<RoutineSummary> routines;
  final int today;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Senza schede e senza giorni non c'è niente da comporre: si dice cosa
    // manca invece di mostrare sette righe che non si possono riempire.
    if (routines.isEmpty && days.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: AppEmptyState(
            key: const Key('weekly_schedule_empty_state'),
            icon: Icons.calendar_month_rounded,
            title: 'Prima serve una scheda',
            message:
                'La settimana assegna una scheda a ogni giorno: quando ne '
                'avrai almeno una potrai dire «il martedì faccio quella».',
            actionLabel: 'Crea la prima scheda',
            onAction: () => openRoutineEditor(context),
          ),
        ),
      );
    }

    return ListView(
      key: const Key('weekly_schedule_list'),
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 32),
      children: [
        _WeekSummary(days: days),
        const SizedBox(height: 16),
        for (var weekday = 1; weekday <= 7; weekday++) ...[
          _DayCard(
            weekday: weekday,
            planned: days[weekday],
            routines: routines,
            isToday: weekday == today,
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _WeekSummary extends StatelessWidget {
  const _WeekSummary({required this.days});

  final Map<int, PlannedWorkout> days;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final training = days.length;
    final rest = 7 - training;

    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(19),
              ),
              child: Icon(
                Icons.calendar_month_rounded,
                size: 28,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    key: const Key('weekly_schedule_summary'),
                    switch (training) {
                      0 => 'Nessun allenamento previsto',
                      1 => '1 allenamento a settimana',
                      _ => '$training allenamenti a settimana',
                    },
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    switch (rest) {
                      0 => 'nessun giorno di riposo',
                      1 => '1 giorno di riposo',
                      _ => '$rest giorni di riposo',
                    },
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DayCard extends ConsumerWidget {
  const _DayCard({
    required this.weekday,
    required this.planned,
    required this.routines,
    required this.isToday,
  });

  final int weekday;
  final PlannedWorkout? planned;
  final List<RoutineSummary> routines;
  final bool isToday;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final workout = planned;
    final title = workout?.routineName ?? 'Riposo';

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('weekly_schedule_day_$weekday'),
        onTap: () => _choose(context, ref),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: isToday
                      ? theme.colorScheme.primary
                      : workout == null
                      ? theme.colorScheme.surfaceContainerHighest
                      : theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(17),
                ),
                child: Center(
                  child: Text(
                    weekdayShortLabel(weekday).toUpperCase(),
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: isToday
                          ? theme.colorScheme.onPrimary
                          : workout == null
                          ? accents.mutedInk
                          : theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      // «Oggi» sta nel testo e non solo nel colore del
                      // riquadro: il colore da solo non arriva a chi non lo
                      // distingue.
                      isToday
                          ? '${weekdayLabel(weekday)} · oggi'
                          : weekdayLabel(weekday),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: isToday
                            ? theme.colorScheme.primary
                            : accents.mutedInk,
                        fontWeight: isToday ? FontWeight.w600 : null,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: workout == null ? accents.mutedInk : null,
                      ),
                    ),
                    if (_detail(workout) case final detail?) ...[
                      const SizedBox(height: 4),
                      Text(
                        detail,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: accents.mutedInk,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: accents.mutedInk),
            ],
          ),
        ),
      ),
    );
  }

  /// La riga sotto al nome. Una scheda che non esiste più lo dice: il giorno
  /// resta, ma non c'è niente da aprire.
  String? _detail(PlannedWorkout? workout) {
    if (workout == null) {
      return null;
    }
    if (workout.isMissing) {
      return 'Questa scheda non c\'è più';
    }
    return [
      workout.exerciseCount == 1
          ? '1 esercizio'
          : '${workout.exerciseCount} esercizi',
      if (workout.isCircuit) 'circuito',
    ].join(' · ');
  }

  Future<void> _choose(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final choice = await showModalBottomSheet<_DayChoice>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => _RoutinePickerSheet(
        weekday: weekday,
        routines: routines,
        selectedRoutineId: planned?.routineId,
      ),
    );
    if (choice == null) {
      return;
    }
    final previous = planned;
    // Toccare la scheda già assegnata (o «Riposo» su un giorno già libero)
    // non è una modifica: niente scrittura, niente riga di sincronizzazione.
    if (choice.routineId == previous?.routineId &&
        (choice.routineId != null || previous == null)) {
      return;
    }

    final controller = await ref.read(weeklyScheduleControllerProvider.future);
    try {
      await controller.restoreDay(weekday, choice.routineId);
    } on Object {
      showAutoClosingSnackBar(
        messenger,
        const SnackBar(content: Text('Non riesco a salvare la settimana.')),
      );
      return;
    }

    // L'annulla si offre solo quando lo stato di prima è ricostruibile: un
    // giorno che puntava a una scheda cancellata non si può rimettere com'era
    // senza far risorgere la scheda, e prometterlo sarebbe una bugia.
    final restorable = previous == null || previous.routineId != null;
    final label = choice.routineId == null
        ? '${weekdayLabel(weekday)}: riposo'
        : '${weekdayLabel(weekday)}: ${choice.routineName}';
    showAutoClosingSnackBar(
      messenger,
      SnackBar(
        content: Text(label),
        action: restorable
            ? SnackBarAction(
                label: 'Annulla',
                onPressed: () async {
                  try {
                    await controller.restoreDay(weekday, previous?.routineId);
                  } on Object {
                    showAutoClosingSnackBar(
                      messenger,
                      const SnackBar(
                        content: Text(
                          'Non riesco a rimettere il giorno com\'era.',
                        ),
                      ),
                    );
                  }
                },
              )
            : null,
      ),
    );
  }
}

/// Cosa si è scelto per il giorno: una scheda, oppure il riposo
/// ([routineId] nullo). Non è `String?` perché «annullato il foglio» e
/// «scelto riposo» devono restare due cose diverse.
class _DayChoice {
  const _DayChoice({this.routineId, this.routineName = ''});

  final String? routineId;
  final String routineName;
}

class _RoutinePickerSheet extends StatelessWidget {
  const _RoutinePickerSheet({
    required this.weekday,
    required this.routines,
    required this.selectedRoutineId,
  });

  final int weekday;
  final List<RoutineSummary> routines;
  final String? selectedRoutineId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(weekdayLabel(weekday), style: theme.textTheme.titleLarge),
            const SizedBox(height: 2),
            Text(
              'Scegli la scheda, o lascia riposo.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: accents.mutedInk,
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView(
                key: const Key('weekly_schedule_picker'),
                shrinkWrap: true,
                children: [
                  ListTile(
                    key: const Key('weekly_schedule_pick_rest'),
                    leading: const Icon(Icons.hotel_rounded),
                    title: const Text('Riposo'),
                    trailing: selectedRoutineId == null
                        ? const Icon(Icons.check_rounded)
                        : null,
                    onTap: () => Navigator.of(context).pop(const _DayChoice()),
                  ),
                  for (final routine in routines)
                    ListTile(
                      key: Key('weekly_schedule_pick_${routine.id}'),
                      leading: Icon(
                        routine.isCircuit
                            ? Icons.bolt_rounded
                            : Icons.assignment_rounded,
                      ),
                      title: Text(routine.name),
                      subtitle: Text(
                        routine.exerciseCount == 1
                            ? '1 esercizio'
                            : '${routine.exerciseCount} esercizi',
                      ),
                      trailing: routine.id == selectedRoutineId
                          ? const Icon(Icons.check_rounded)
                          : null,
                      onTap: () => Navigator.of(context).pop(
                        _DayChoice(
                          routineId: routine.id,
                          routineName: routine.name,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadFailed extends ConsumerWidget {
  const _LoadFailed({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: AppEmptyState(
        icon: Icons.error_outline_rounded,
        title: 'Non riesco a leggere la settimana',
        message: 'Il database locale non ha risposto.',
        actionLabel: 'Riprova',
        onAction: () => ref.invalidate(routinesProvider),
      ),
    ),
  );
}

class _ScreenTitle extends StatelessWidget {
  const _ScreenTitle({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title),
        Text(
          subtitle,
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppAccents.of(context).mutedInk,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

/// Il 1° gennaio 2024 era un lunedì: `DateTime(2024, 1, n).weekday == n`.
/// Serve una data qualsiasi perché i nomi dei giorni vengono da `intl`, che
/// li sa solo a partire da un giorno vero — non da un numero ISO.
DateTime _referenceDay(int weekday) => DateTime(2024, 1, weekday);

String weekdayLabel(int weekday) =>
    _capitalize(DateFormat('EEEE', 'it').format(_referenceDay(weekday)));

String weekdayShortLabel(int weekday) =>
    DateFormat('EEE', 'it').format(_referenceDay(weekday));

String _capitalize(String value) =>
    value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);
