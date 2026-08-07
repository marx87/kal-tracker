import 'package:flutter/material.dart';
import 'package:kal_tracker/features/workouts/domain/session_effort.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/workouts/data/workout_history_models.dart';
import 'package:kal_tracker/features/workouts/presentation/history/widgets/workout_session_card.dart';
import 'package:kal_tracker/features/workouts/presentation/history/workout_formatting.dart';

/// Un gruppo di esercizi del dettaglio.
///
/// Con un esercizio solo è una card normale; con più di uno è una superserie,
/// e allora la card è una sola apposta: la catena si vede perché gli esercizi
/// stanno dentro lo stesso riquadro, non perché c'è scritto da qualche parte.
class WorkoutExerciseGroupCard extends StatelessWidget {
  const WorkoutExerciseGroupCard({required this.group, super.key});

  final WorkoutExerciseGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      key: Key('workout_group_${group.exercises.first.id}'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (group.isSuperset) ...[
              Row(
                children: [
                  ExcludeSemantics(
                    child: Icon(
                      Icons.link_rounded,
                      size: 17,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Superserie · ${group.exercises.length} esercizi',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              const WorkoutNoteLine(
                icon: Icons.autorenew_rounded,
                text: 'Si passava da un esercizio all’altro senza riposo.',
              ),
              const SizedBox(height: 12),
            ],
            for (final (index, exercise) in group.exercises.indexed) ...[
              if (index > 0) const Divider(height: 24),
              WorkoutExerciseBlock(exercise: exercise),
            ],
          ],
        ),
      ),
    );
  }
}

/// Un esercizio con le sue serie, come Gym le aveva registrate.
class WorkoutExerciseBlock extends StatelessWidget {
  const WorkoutExerciseBlock({required this.exercise, super.key});

  final WorkoutExerciseEntry exercise;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                exercise.name,
                key: Key('workout_exercise_name_${exercise.id}'),
                style: theme.textTheme.titleMedium,
              ),
            ),
            const SizedBox(width: 10),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                exercise.trackingMode.label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: accents.mutedInk,
                ),
              ),
            ),
          ],
        ),
        if (exercise.exerciseDeleted) ...[
          const SizedBox(height: 6),
          const WorkoutNoteLine(
            icon: Icons.history_rounded,
            // Stesso principio della scheda cancellata: il nome storico è
            // un dato, non un difetto da segnalare in rosso.
            text: 'Esercizio non più in catalogo: resta il nome di allora.',
          ),
        ],
        if (exercise.restSeconds case final rest? when rest > 0) ...[
          const SizedBox(height: 6),
          WorkoutNoteLine(
            icon: Icons.hourglass_bottom_rounded,
            text: 'Riposo previsto: ${formatClock(rest)}',
          ),
        ],
        const SizedBox(height: 10),
        if (exercise.sets.isEmpty)
          const AppEmptyState(
            compact: true,
            icon: Icons.playlist_remove_rounded,
            message: 'Nessuna serie registrata per questo esercizio.',
          )
        else
          for (final (index, set) in exercise.sets.indexed)
            WorkoutSetRow(
              set: set,
              mode: exercise.trackingMode,
              number: index + 1,
            ),
      ],
    );
  }
}

/// Una riga di serie: numero, cosa è stato fatto, sforzo, esito.
///
/// L'esito non è affidato al colore: la serie completata ha il cerchio
/// spuntato, quella no ha il cerchio vuoto, e chi ascolta se lo sente dire.
class WorkoutSetRow extends StatelessWidget {
  const WorkoutSetRow({
    required this.set,
    required this.mode,
    required this.number,
    super.key,
  });

  final WorkoutSetEntry set;
  final WorkoutTrackingMode mode;
  final int number;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accents = AppAccents.of(context);
    final done = set.completed;

    return Semantics(
      container: true,
      label: spokenSet(set, mode, number: number),
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 26,
                child: Text(
                  // «R» come riscaldamento: in Gym era una W, ma la lista è
                  // in italiano e la lettera deve dire qualcosa a Marco.
                  set.isWarmup ? 'R' : '$number',
                  style: theme.textTheme.labelMedium
                      ?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: set.isWarmup
                            ? accents.warning
                            : accents.mutedInk,
                      )
                      .tabular,
                ),
              ),
              Expanded(
                child: Text(
                  describeSet(set, mode),
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(
                        color: done ? scheme.onSurface : accents.mutedInk,
                      )
                      .tabular,
                ),
              ),
              if (set.rpe case final rpe?) ...[
                const SizedBox(width: 8),
                Text(
                  SessionEffort.nearest(rpe)?.label ?? 'RPE $rpe',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: accents.mutedInk,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              const SizedBox(width: 8),
              Icon(
                done
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 16,
                color: done ? accents.positive : accents.mutedInk,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
