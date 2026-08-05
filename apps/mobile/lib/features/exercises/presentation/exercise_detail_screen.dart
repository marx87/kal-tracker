import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';
import 'package:kal_tracker/features/exercises/presentation/exercise_providers.dart';
import 'package:kal_tracker/features/exercises/presentation/widgets/exercise_editor_sheet.dart';
import 'package:kal_tracker/features/exercises/presentation/widgets/muscle_group_presentation.dart';
import 'package:kal_tracker/features/routines/domain/routine_models.dart';
import 'package:kal_tracker/features/routines/presentation/routine_editor_screen.dart';
import 'package:kal_tracker/features/routines/presentation/routine_providers.dart';

/// Apre la scheda di un esercizio.
///
/// Passa dal `Navigator` e non da una rotta con nome perché il router è di
/// un'altra area: quando l'integratore registrerà le rotte, questo è l'unico
/// punto da cambiare.
Future<void> openExerciseDetail(BuildContext context, String exerciseId) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ExerciseDetailScreen(exerciseId: exerciseId),
      ),
    );

/// Che cos'è questo esercizio e dove lo usi. Non è un cruscotto di
/// progressione — quello vive con gli allenamenti — ma la carta d'identità
/// della riga di catalogo.
class ExerciseDetailScreen extends ConsumerWidget {
  const ExerciseDetailScreen({required this.exerciseId, super.key});

  final String exerciseId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exercise = ref.watch(exerciseDetailProvider(exerciseId));
    final loading = ref.watch(exerciseCatalogProvider).isLoading;

    if (exercise == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Esercizio')),
        body: Center(
          child: loading
              ? const CircularProgressIndicator()
              : const Padding(
                  padding: EdgeInsets.all(24),
                  child: AppEmptyState(
                    icon: Icons.search_off_rounded,
                    title: 'Esercizio non trovato',
                    message:
                        'Potrebbe essere stato eliminato dalla libreria. Le '
                        'schede che lo citavano lo mostrano come non più '
                        'disponibile.',
                  ),
                ),
        ),
      );
    }

    final usages = ref.watch(routinesUsingExerciseProvider(exerciseId));

    return Scaffold(
      appBar: AppBar(
        title: Text(
          exercise.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            key: const Key('edit_exercise_button'),
            onPressed: () =>
                showExerciseEditorSheet(context, exercise: exercise),
            child: const Text('Modifica'),
          ),
        ],
      ),
      body: AdaptiveContent(
        child: ListView(
          key: const Key('exercise_detail_list'),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _IdentityCard(exercise: exercise),
            if (exercise.notes case final notes?) ...[
              const SizedBox(height: 14),
              SectionCard(
                title: 'Note',
                icon: Icons.sticky_note_2_rounded,
                child: Text(
                  notes,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
            if (exercise.imageUrl case final imageUrl?) ...[
              const SizedBox(height: 14),
              _DemoImage(url: imageUrl),
            ],
            const SizedBox(height: 14),
            SectionCard(
              title: 'Dove lo usi',
              subtitle: 'Le schede che lo contengono',
              icon: Icons.checklist_rounded,
              child: usages.when(
                data: (list) => list.isEmpty
                    ? const AppEmptyState(
                        compact: true,
                        icon: Icons.checklist_rounded,
                        message:
                            'Nessuna scheda lo usa ancora: aggiungilo a una '
                            'scheda per trovarlo in allenamento.',
                      )
                    : Column(
                        children: [
                          for (final usage in list)
                            _UsageTile(
                              key: Key(
                                'usage_${usage.routineId}_${usage.block.name}',
                              ),
                              usage: usage,
                            ),
                        ],
                      ),
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (error, stackTrace) => const AppEmptyState(
                  compact: true,
                  icon: Icons.error_outline_rounded,
                  message: 'Non riesco a leggere le schede collegate.',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.exercise});

  final Exercise exercise;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MuscleGroupBadge(group: exercise.muscleGroup, size: 62),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(exercise.name, style: theme.textTheme.titleLarge),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          MuscleGroupChip(group: exercise.muscleGroup),
                          _InfoChip(
                            icon: exercise.trackingMode.isTimed
                                ? Icons.timer_outlined
                                : Icons.repeat_rounded,
                            label: exercise.trackingMode.label,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              exercise.trackingMode.hint,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: accents.mutedInk,
              ),
            ),
            const SizedBox(height: 14),
            StatRow(
              label: 'Recupero predefinito',
              value: exercise.defaultRestSec?.toString() ?? '—',
              unit: exercise.defaultRestSec == null ? null : 'sec',
              unitSemantics: exercise.defaultRestSec == null ? null : 'secondi',
              caption: exercise.defaultRestSec == null
                  ? 'Lo decide la scheda'
                  : 'Proposto quando lo aggiungi a una scheda',
              icon: Icons.hourglass_bottom_rounded,
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: accents.mutedInk),
          const SizedBox(width: 5),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: accents.mutedInk,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// L'immagine dimostrativa, se l'esercizio ne porta una dall'import.
///
/// Non blocca nulla: se il link è morto o non c'è rete resta un riquadro con
/// una frase, non un errore rosso in mezzo alla scheda.
class _DemoImage extends StatelessWidget {
  const _DemoImage({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Image.network(
        url,
        height: 200,
        width: double.infinity,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => Container(
          height: 90,
          alignment: Alignment.center,
          color: theme.colorScheme.surfaceContainerHighest,
          child: Text(
            'Immagine non raggiungibile',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppAccents.of(context).mutedInk,
            ),
          ),
        ),
        loadingBuilder: (context, child, progress) => progress == null
            ? child
            : Container(
                height: 200,
                alignment: Alignment.center,
                color: theme.colorScheme.surfaceContainerHighest,
                child: const CircularProgressIndicator(strokeWidth: 2),
              ),
      ),
    );
  }
}

class _UsageTile extends StatelessWidget {
  const _UsageTile({required this.usage, super.key});

  final RoutineUsage usage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      minVerticalPadding: 12,
      leading: Icon(Icons.assignment_rounded, color: theme.colorScheme.primary),
      title: Text(usage.routineName, style: theme.textTheme.titleSmall),
      subtitle: Text('Blocco ${usage.block.label.toLowerCase()}'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => openRoutineEditor(context, routineId: usage.routineId),
    );
  }
}
