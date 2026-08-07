import 'package:flutter/material.dart';
import 'package:kal_tracker/features/workouts/domain/session_effort.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/workouts/data/workout_history_models.dart';
import 'package:kal_tracker/features/workouts/presentation/history/workout_formatting.dart';

/// La scheda di una sessione in lista.
///
/// Tre casi hanno una forma loro e nessuno dei tre è un errore: la sessione
/// con la durata non attendibile (marcata, mai corretta), quella che cita una
/// scheda cancellata (mostra il nome storico) e quella registrata a posteriori
/// senza esercizi (spiega perché è vuota invece di sembrare rotta).
class WorkoutSessionCard extends StatelessWidget {
  const WorkoutSessionCard({
    required this.summary,
    required this.onOpen,
    super.key,
  });

  final WorkoutSummary summary;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final kind = summary.kind;
    final suspectNote = suspectDurationNote(summary);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('workout_card_${summary.id}'),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  WorkoutKindTile(kind: kind),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          summary.routineName ?? 'Allenamento libero',
                          style: theme.textTheme.titleMedium,
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
                  Padding(
                    padding: const EdgeInsets.only(top: 4, left: 4),
                    child: ExcludeSemantics(
                      child: Icon(
                        Icons.chevron_right_rounded,
                        color: accents.mutedInk,
                      ),
                    ),
                  ),
                ],
              ),
              if (summary.routineDeleted) ...[
                const SizedBox(height: 10),
                WorkoutNoteLine(
                  icon: Icons.history_rounded,
                  // Non è un errore da segnalare: è il nome che quella
                  // sessione aveva, e resta l'unica cosa vera da mostrare.
                  text:
                      'Scheda non più in archivio: questo è il nome che aveva '
                      'allora.',
                ),
              ],
              const SizedBox(height: 12),
              if (summary.withoutExercises)
                const AppEmptyState(
                  compact: true,
                  icon: Icons.edit_calendar_rounded,
                  message:
                      'Registrata a posteriori: Gym ha salvato durata e '
                      'calorie, non i singoli esercizi.',
                )
              else
                WorkoutMetricsWrap(summary: summary),
              if (suspectNote != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: StatusChip(
                    key: Key('workout_suspect_chip_${summary.id}'),
                    level: AppStatusLevel.warning,
                    label: 'Durata non attendibile',
                    compact: true,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  suspectNote,
                  key: Key('workout_suspect_note_${summary.id}'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: accents.mutedInk,
                    height: 1.35,
                  ),
                ),
              ],
              if (summary.hasFeedback) ...[
                const SizedBox(height: 12),
                WorkoutFeedbackWrap(summary: summary),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Il riquadro con l'icona del tipo di sessione. Il colore non porta
/// informazione: la parola sta accanto, nel sottotitolo.
class WorkoutKindTile extends StatelessWidget {
  const WorkoutKindTile({required this.kind, this.size = 44, super.key});

  final WorkoutKind kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(size / 2.8),
        ),
        child: Icon(
          kind.icon,
          size: size * 0.48,
          color: scheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

/// I numeri della sessione: esercizi, volume, durata, calorie stimate.
class WorkoutMetricsWrap extends StatelessWidget {
  const WorkoutMetricsWrap({required this.summary, super.key});

  final WorkoutSummary summary;

  @override
  Widget build(BuildContext context) {
    final duration = summary.duration;
    return Wrap(
      spacing: 14,
      runSpacing: 8,
      children: [
        WorkoutMetric(
          icon: Icons.list_alt_rounded,
          text: '${summary.exerciseCount} esercizi',
          spoken: '${summary.exerciseCount} esercizi',
        ),
        if (summary.totalVolume > 0)
          WorkoutMetric(
            icon: Icons.fitness_center_rounded,
            text: '${formatVolume(summary.totalVolume)} kg',
            spoken:
                '${formatVolume(summary.totalVolume)} chilogrammi '
                'di volume',
          ),
        if (duration != null)
          WorkoutMetric(
            icon: Icons.timer_outlined,
            text: formatDuration(duration),
            spoken: 'durata ${formatDuration(duration)}',
          ),
        if (summary.totalKcal case final kcal?)
          WorkoutMetric(
            icon: Icons.local_fire_department_rounded,
            text: '${formatKcal(kcal)} kcal',
            // «stimate» va detto: è una stima di Gym, non una misura.
            spoken: '${formatKcal(kcal)} chilocalorie stimate',
          ),
      ],
    );
  }
}

/// Un numero con la sua icona. La lettura ad alta voce scioglie le sigle,
/// che altrimenti verrebbero scandite lettera per lettera.
class WorkoutMetric extends StatelessWidget {
  const WorkoutMetric({
    required this.icon,
    required this.text,
    required this.spoken,
    super.key,
  });

  final IconData icon;
  final String text;
  final String spoken;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    return Semantics(
      container: true,
      label: spoken,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: accents.mutedInk),
            const SizedBox(width: 4),
            Text(
              text,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)
                  .tabular,
            ),
          ],
        ),
      ),
    );
  }
}

/// Il feedback di fine sessione: umore, sforzo percepito, soddisfazione.
class WorkoutFeedbackWrap extends StatelessWidget {
  const WorkoutFeedbackWrap({required this.summary, super.key});

  final WorkoutSummary summary;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (summary.mood case final mood?)
          WorkoutFeedbackPill(
            icon: Icons.sentiment_satisfied_rounded,
            text: moodLabel(mood),
            spoken: 'Umore: ${moodLabel(mood)}',
          ),
        if (summary.rpe case final rpe?)
          WorkoutFeedbackPill(
            icon: Icons.speed_rounded,
            // La parola che Marco ha toccato, non il numero che l'app ha
            // scritto per sé: «RPE 6 su 10» restituisce una scala che nessuno
            // gli ha mai mostrato.
            text: SessionEffort.nearest(rpe)?.label ?? 'RPE $rpe',
            spoken:
                'Sforzo: ${SessionEffort.nearest(rpe)?.label ?? '$rpe su 10'}',
          ),
        if (summary.satisfaction case final satisfaction?)
          WorkoutFeedbackPill(
            icon: Icons.star_rounded,
            text: '$satisfaction/5',
            spoken: 'Soddisfazione $satisfaction su 5',
          ),
      ],
    );
  }
}

/// Una pastiglia tenue di feedback. Non è uno [StatusChip]: quello dice se
/// una cosa va bene o male, questo riporta soltanto com'è andata.
class WorkoutFeedbackPill extends StatelessWidget {
  const WorkoutFeedbackPill({
    required this.icon,
    required this.text,
    required this.spoken,
    super.key,
  });

  final IconData icon;
  final String text;
  final String spoken;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      container: true,
      label: spoken,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: scheme.outline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: scheme.onSurface),
              const SizedBox(width: 5),
              Text(
                text,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Una riga di nota discreta: icona e frase, nel grigio dei testi secondari.
class WorkoutNoteLine extends StatelessWidget {
  const WorkoutNoteLine({required this.icon, required this.text, super.key});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(child: Icon(icon, size: 16, color: accents.mutedInk)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: accents.mutedInk,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}
