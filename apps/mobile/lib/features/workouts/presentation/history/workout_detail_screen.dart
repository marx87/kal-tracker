import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/workouts/data/workout_history_models.dart';
import 'package:kal_tracker/features/workouts/presentation/history/widgets/workout_exercise_card.dart';
import 'package:kal_tracker/features/workouts/presentation/history/widgets/workout_session_card.dart';
import 'package:kal_tracker/features/workouts/presentation/history/workout_formatting.dart';
import 'package:kal_tracker/features/workouts/presentation/history/workout_history_providers.dart';

/// Una sessione aperta: come si è svolta, blocco per blocco.
///
/// L'ordine è quello con cui Gym la registrava — riscaldamento, allenamento,
/// blocchi a tempo, finisher, defaticamento — e le superserie restano
/// incatenate. Sola lettura, come la lista.
class WorkoutDetailScreen extends ConsumerWidget {
  const WorkoutDetailScreen({required this.workoutId, super.key});

  final String workoutId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(workoutDetailProvider(workoutId));

    return Scaffold(
      appBar: AppBar(
        title: _AppBarTitle(day: detail.valueOrNull?.summary.startedAt),
      ),
      body: detail.when(
        data: (value) => value == null
            ? const _SessionNotFound()
            : _DetailBody(detail: value),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: AppEmptyState(
              key: const Key('workout_detail_error'),
              icon: Icons.cloud_off_rounded,
              title: 'Sessione non leggibile',
              message:
                  'Non riesco a leggere questa sessione dall’archivio '
                  'locale. Riprova.',
              actionLabel: 'Riprova',
              onAction: () => ref.invalidate(workoutDetailProvider(workoutId)),
            ),
          ),
        ),
      ),
    );
  }
}

class _AppBarTitle extends StatelessWidget {
  const _AppBarTitle({required this.day});

  final DateTime? day;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Allenamento'),
        if (day case final day?)
          Text(
            formatSessionDay(day),
            style: theme.textTheme.bodySmall?.copyWith(
              color: accents.mutedInk,
              fontWeight: FontWeight.w500,
            ),
          ),
      ],
    );
  }
}

class _DetailBody extends StatelessWidget {
  const _DetailBody({required this.detail});

  final WorkoutDetail detail;

  @override
  Widget build(BuildContext context) {
    final sections = buildWorkoutSections(detail);
    final summary = detail.summary;

    return AdaptiveContent(
      child: ListView(
        key: const Key('workout_detail_list'),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        children: [
          _HeaderCard(summary: summary),
          const SizedBox(height: 18),
          if (summary.withoutExercises)
            const AppEmptyState(
              key: Key('workout_detail_no_exercises'),
              icon: Icons.edit_calendar_rounded,
              title: 'Sessione senza dettaglio',
              message:
                  'Registrata a posteriori dal modulo «sessione esterna»: '
                  'Gym ha salvato quanto è durata e le calorie stimate, non '
                  'i singoli esercizi. Non manca niente, non c’era altro.',
            )
          else
            for (final section in sections) ...[
              _SectionHeader(section: section),
              for (final group in section.groups) ...[
                WorkoutExerciseGroupCard(group: group),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 8),
            ],
          if (summary.hasFeedback || detail.painPoints.isNotEmpty) ...[
            const SizedBox(height: 4),
            _FeedbackCard(detail: detail),
          ],
        ],
      ),
    );
  }
}

/// L'intestazione: che sessione era, quando, e i suoi numeri.
class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.summary});

  final WorkoutSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final kind = summary.kind;
    final suspectNote = suspectDurationNote(summary);
    final duration = summary.duration;

    return Card(
      key: const Key('workout_detail_header'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                WorkoutKindTile(kind: kind, size: 48),
                const SizedBox(width: 12),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          summary.routineName ?? 'Allenamento libero',
                          style: theme.textTheme.titleLarge,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${formatSessionMoment(summary.startedAt)}'
                          ' · ${kind.label}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: accents.mutedInk,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (summary.xpEarned case final xp?)
                  WorkoutFeedbackPill(
                    icon: Icons.bolt_rounded,
                    text: '+$xp XP',
                    spoken: '$xp punti esperienza',
                  ),
              ],
            ),
            if (summary.routineDeleted) ...[
              const SizedBox(height: 10),
              const WorkoutNoteLine(
                icon: Icons.history_rounded,
                text:
                    'Scheda non più in archivio: questo è il nome che aveva '
                    'allora.',
              ),
            ],
            const SizedBox(height: 8),
            StatRow(
              key: const Key('workout_detail_duration'),
              label: 'Durata',
              value: formatDuration(duration),
              icon: Icons.timer_outlined,
              trailing: summary.durationSuspect
                  ? const StatusChip(
                      level: AppStatusLevel.warning,
                      label: 'Non attendibile',
                      compact: true,
                    )
                  : null,
            ),
            if (suspectNote != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  suspectNote,
                  key: const Key('workout_detail_suspect_note'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: accents.mutedInk,
                    height: 1.35,
                  ),
                ),
              ),
            if (summary.totalVolume > 0) ...[
              const Divider(),
              StatRow(
                label: 'Volume',
                value: formatVolume(summary.totalVolume),
                unit: 'kg',
                unitSemantics: 'chilogrammi',
                icon: Icons.fitness_center_rounded,
              ),
            ],
            if (summary.totalKcal case final kcal?) ...[
              const Divider(),
              StatRow(
                label: 'Calorie stimate',
                value: formatKcal(kcal),
                unit: 'kcal',
                unitSemantics: 'chilocalorie',
                caption: 'Stima di Gym, non una misura',
                icon: Icons.local_fire_department_rounded,
              ),
            ],
            if (!summary.withoutExercises) ...[
              const Divider(),
              StatRow(
                label: 'Esercizi',
                value: formatWholeNumber(summary.exerciseCount),
                caption: summary.setCount == 1
                    ? '1 serie registrata'
                    : '${formatWholeNumber(summary.setCount)} serie '
                          'registrate',
                icon: Icons.list_alt_rounded,
              ),
            ],
            if (summary.notes case final notes? when notes.isNotEmpty) ...[
              const SizedBox(height: 10),
              _NoteBox(text: notes),
            ],
          ],
        ),
      ),
    );
  }
}

/// L'intestazione di un blocco. Per i circuiti porta anche i marcatori di
/// completamento, che in Gym erano due liste indipendenti: un blocco può
/// risultare completato E ripreso a metà, e mostrarne uno solo nasconderebbe
/// metà della storia.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.section});

  final WorkoutSection section;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final marker = section.marker;
    final title = section.isCircuit
        ? 'Circuito · blocco ${section.segmentIndex! + 1}'
        : section.block.label;
    final count = section.exerciseCount;

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ExcludeSemantics(
                child: Icon(
                  section.isCircuit ? Icons.timer_rounded : section.block.icon,
                  size: 18,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    '$title · ${count == 1 ? '1 esercizio' : '$count esercizi'}',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ),
            ],
          ),
          if (section.isCircuit) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: Text(
                'Blocco a tempo: gli esercizi giravano a rotazione.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: accents.mutedInk,
                ),
              ),
            ),
            if (marker != null && (marker.completed || marker.partial)) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 26),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (marker.completed)
                      StatusChip(
                        key: Key(
                          'workout_segment_done_${section.segmentIndex}',
                        ),
                        level: AppStatusLevel.good,
                        label: 'Completato',
                        compact: true,
                      ),
                    if (marker.partial)
                      StatusChip(
                        key: Key(
                          'workout_segment_partial_${section.segmentIndex}',
                        ),
                        level: AppStatusLevel.warning,
                        label: 'Chiuso in anticipo',
                        compact: true,
                      ),
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _FeedbackCard extends StatelessWidget {
  const _FeedbackCard({required this.detail});

  final WorkoutDetail detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final summary = detail.summary;

    return SectionCard(
      key: const Key('workout_detail_feedback'),
      title: 'Come è andata',
      subtitle: 'Quello che Marco ha segnato a fine sessione',
      icon: Icons.psychology_alt_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (summary.mood != null ||
              summary.rpe != null ||
              summary.satisfaction != null)
            WorkoutFeedbackWrap(summary: summary),
          if (summary.satisfaction case final stars?) ...[
            const SizedBox(height: 12),
            _SatisfactionStars(stars: stars),
          ],
          if (detail.painPoints.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Dove ha sentito fastidio',
              style: theme.textTheme.labelLarge?.copyWith(
                color: accents.mutedInk,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final point in detail.painPoints)
                  StatusChip(
                    key: Key('workout_pain_$point'),
                    level: AppStatusLevel.warning,
                    label: point,
                    compact: true,
                  ),
              ],
            ),
          ],
          if (summary.feedbackNotes case final notes?
              when notes.isNotEmpty) ...[
            const SizedBox(height: 16),
            _NoteBox(text: notes),
          ],
        ],
      ),
    );
  }
}

/// Le stelle di soddisfazione. Il numero viene detto per esteso: cinque
/// icone identiche non si contano ad orecchio.
class _SatisfactionStars extends StatelessWidget {
  const _SatisfactionStars({required this.stars});

  final int stars;

  @override
  Widget build(BuildContext context) {
    final accents = AppAccents.of(context);
    return Semantics(
      container: true,
      label: 'Soddisfazione: $stars stelle su 5',
      child: ExcludeSemantics(
        child: Row(
          children: [
            for (var index = 1; index <= 5; index++)
              Padding(
                padding: const EdgeInsets.only(right: 2),
                child: Icon(
                  index <= stars
                      ? Icons.star_rounded
                      : Icons.star_border_rounded,
                  size: 22,
                  color: index <= stars ? accents.warning : accents.mutedInk,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Una nota scritta da Marco, nel suo riquadro tenue.
class _NoteBox extends StatelessWidget {
  const _NoteBox({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outline),
      ),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
      ),
    );
  }
}

class _SessionNotFound extends StatelessWidget {
  const _SessionNotFound();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: AppEmptyState(
          key: const Key('workout_detail_missing'),
          icon: Icons.search_off_rounded,
          title: 'Sessione non trovata',
          message:
              'Questa sessione non è più nell’archivio locale. Se l’hai '
              'aperta da un collegamento vecchio, torna allo storico.',
          actionLabel: 'Torna allo storico',
          onAction: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }
}
