import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';
import 'package:kal_tracker/features/exercises/presentation/exercise_detail_screen.dart';
import 'package:kal_tracker/features/exercises/presentation/exercise_providers.dart';
import 'package:kal_tracker/features/exercises/presentation/widgets/exercise_editor_sheet.dart';
import 'package:kal_tracker/features/exercises/presentation/widgets/muscle_group_presentation.dart';

/// Il catalogo esercizi: una lista sola con due origini (base e miei), come
/// in Gym Tracker, ma vestita come Kal.
class ExercisesScreen extends ConsumerWidget {
  const ExercisesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exercises = ref.watch(visibleExercisesProvider);
    final catalog = ref.watch(exerciseCatalogProvider).valueOrNull;
    final hasFilters =
        ref.watch(exerciseSearchQueryProvider).trim().isNotEmpty ||
        ref.watch(exerciseMuscleFilterProvider) != null ||
        ref.watch(exerciseOriginFilterProvider) != ExerciseOrigin.all;

    return Scaffold(
      appBar: AppBar(
        title: const _ScreenTitle(
          title: 'Esercizi',
          subtitle: 'La libreria da cui nascono le schede',
        ),
      ),
      body: AdaptiveContent(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 6, 16, 10),
              child: _ExerciseFilters(),
            ),
            Expanded(
              child: exercises.when(
                data: (items) => ListView(
                  key: const Key('exercises_list'),
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 112),
                  children: [
                    _LibraryIntroCard(
                      total: catalog?.length ?? items.length,
                      mine:
                          catalog
                              ?.where(
                                (exercise) =>
                                    exercise.origin == ExerciseOrigin.mine,
                              )
                              .length ??
                          0,
                    ),
                    const SizedBox(height: 16),
                    if (items.isEmpty)
                      AppEmptyState(
                        key: const Key('exercises_empty_state'),
                        icon: Icons.fitness_center_rounded,
                        title: hasFilters
                            ? 'Nessun esercizio con questi filtri'
                            : 'La libreria è vuota',
                        message: hasFilters
                            ? 'Prova un nome diverso, oppure azzera i filtri e '
                                  'riparti dalla lista intera.'
                            : 'Crea il primo esercizio: nome, gruppo muscolare '
                                  'e come lo vuoi misurare.',
                        actionLabel: hasFilters ? 'Azzera i filtri' : null,
                        onAction: hasFilters ? () => _resetFilters(ref) : null,
                      )
                    else
                      ..._groupedRows(context, items),
                  ],
                ),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, stackTrace) => _LoadError(
                  onRetry: () => ref.invalidate(visibleExercisesProvider),
                ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('create_exercise_button'),
        onPressed: () => showExerciseEditorSheet(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Crea esercizio'),
      ),
    );
  }

  /// Gli esercizi raggruppati per gruppo muscolare, con l'intestazione di
  /// sezione. Ordinati per etichetta: è l'ordine in cui Marco li cerca a
  /// occhio, non quello dell'enum.
  List<Widget> _groupedRows(BuildContext context, List<Exercise> items) {
    final grouped = <MuscleGroup, List<Exercise>>{};
    for (final exercise in items) {
      grouped.putIfAbsent(exercise.muscleGroup, () => []).add(exercise);
    }
    final groups = grouped.keys.toList()
      ..sort((a, b) => a.label.compareTo(b.label));

    return [
      for (final group in groups) ...[
        _MuscleSectionHeader(group: group, count: grouped[group]!.length),
        for (final exercise in grouped[group]!) ...[
          _ExerciseCard(exercise: exercise),
          const SizedBox(height: 10),
        ],
      ],
    ];
  }

  void _resetFilters(WidgetRef ref) {
    ref.read(exerciseSearchQueryProvider.notifier).state = '';
    ref.read(exerciseMuscleFilterProvider.notifier).state = null;
    ref.read(exerciseOriginFilterProvider.notifier).state = ExerciseOrigin.all;
  }
}

/// Titolo dell'AppBar con la sua riga di contesto sotto, come nelle altre
/// schermate di Kal.
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

class _ExerciseFilters extends ConsumerStatefulWidget {
  const _ExerciseFilters();

  @override
  ConsumerState<_ExerciseFilters> createState() => _ExerciseFiltersState();
}

class _ExerciseFiltersState extends ConsumerState<_ExerciseFilters> {
  final _search = TextEditingController();
  var _allMuscles = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(exerciseSearchQueryProvider, (previous, next) {
      if (next != _search.text) {
        _search.text = next;
      }
    });
    final origin = ref.watch(exerciseOriginFilterProvider);
    final muscle = ref.watch(exerciseMuscleFilterProvider);

    final muscleChips = <Widget>[
      FilterChip(
        key: const Key('exercise_muscle_any'),
        label: const Text('Ogni muscolo'),
        selected: muscle == null,
        showCheckmark: false,
        onSelected: (_) =>
            ref.read(exerciseMuscleFilterProvider.notifier).state = null,
      ),
      for (final group in MuscleGroup.values)
        FilterChip(
          key: Key('exercise_muscle_${group.name}'),
          label: Text(group.label),
          selected: muscle == group,
          showCheckmark: false,
          onSelected: (selected) =>
              ref.read(exerciseMuscleFilterProvider.notifier).state = selected
              ? group
              : null,
        ),
    ];
    final toggle = FilterChip(
      key: const Key('exercise_muscles_toggle'),
      label: Text(_allMuscles ? 'Comprimi' : 'Tutti i muscoli'),
      avatar: Icon(
        _allMuscles ? Icons.unfold_less_rounded : Icons.unfold_more_rounded,
        size: 18,
      ),
      selected: _allMuscles,
      onSelected: (value) => setState(() => _allMuscles = value),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('exercise_search_field'),
          controller: _search,
          textInputAction: TextInputAction.search,
          onChanged: (value) =>
              ref.read(exerciseSearchQueryProvider.notifier).state = value,
          decoration: InputDecoration(
            hintText: 'Cerca per nome o gruppo muscolare',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Cancella la ricerca',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () {
                      _search.clear();
                      ref.read(exerciseSearchQueryProvider.notifier).state = '';
                    },
                  ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final value in ExerciseOrigin.values)
              ChoiceChip(
                key: Key('exercise_origin_${value.name}'),
                label: Text(value.label),
                selected: origin == value,
                onSelected: (_) =>
                    ref.read(exerciseOriginFilterProvider.notifier).state =
                        value,
              ),
          ],
        ),
        const SizedBox(height: 8),
        // Dodici gruppi non stanno su una riga: di default scorrono, il
        // pulsante apre la griglia intera per chi cerca a colpo d'occhio.
        if (_allMuscles)
          Wrap(spacing: 8, runSpacing: 8, children: [...muscleChips, toggle])
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final chip in muscleChips) ...[
                  chip,
                  const SizedBox(width: 8),
                ],
                toggle,
              ],
            ),
          ),
      ],
    );
  }
}

class _LibraryIntroCard extends StatelessWidget {
  const _LibraryIntroCard({required this.total, required this.mine});

  final int total;
  final int mine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                Icons.fitness_center_rounded,
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
                    'La tua libreria',
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    total == 0
                        ? 'Ancora nessun esercizio.'
                        : '$total esercizi · $mine creati da te',
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

class _MuscleSectionHeader extends StatelessWidget {
  const _MuscleSectionHeader({required this.group, required this.count});

  final MuscleGroup group;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = MuscleGroupStyle.of(context, group);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 2, 10),
      child: Semantics(
        header: true,
        child: Row(
          children: [
            MuscleGroupBadge(group: group, size: 34),
            const SizedBox(width: 10),
            Expanded(
              child: Text(group.label, style: theme.textTheme.titleMedium),
            ),
            Text(
              count == 1 ? '1 esercizio' : '$count esercizi',
              style: theme.textTheme.labelMedium?.copyWith(
                color: style.foreground,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExerciseCard extends ConsumerWidget {
  const _ExerciseCard({required this.exercise});

  final Exercise exercise;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('exercise_card_${exercise.id}'),
        onTap: () => openExerciseDetail(context, exercise.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MuscleGroupBadge(group: exercise.muscleGroup),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            exercise.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _OriginTag(origin: exercise.origin),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      exercise.trackingMode.label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: accents.mutedInk,
                      ),
                    ),
                    if (exercise.notes case final notes?) ...[
                      const SizedBox(height: 3),
                      Text(
                        notes,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: accents.mutedInk,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              _ExerciseMenu(exercise: exercise),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExerciseMenu extends ConsumerWidget {
  const _ExerciseMenu({required this.exercise});

  final Exercise exercise;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      key: Key('exercise_menu_${exercise.id}'),
      tooltip: 'Azioni per ${exercise.name}',
      icon: const Icon(Icons.more_vert_rounded),
      onSelected: (value) async {
        if (value == 'edit') {
          await showExerciseEditorSheet(context, exercise: exercise);
        } else if (value == 'delete') {
          await _confirmDelete(context, ref);
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(value: 'edit', child: Text('Modifica')),
        PopupMenuItem(value: 'delete', child: Text('Elimina')),
      ],
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Eliminare questo esercizio?'),
        content: Text(
          '«${exercise.name}» sparisce dalla libreria. Le schede che lo '
          'contengono lo mostreranno come non più disponibile.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            key: const Key('confirm_delete_exercise'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Elimina'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await ref.read(exerciseRepositoryProvider).deleteExercise(exercise.id);
    messenger.showSnackBar(
      SnackBar(content: Text('«${exercise.name}» non è più in libreria.')),
    );
  }
}

/// Da dove arriva l'esercizio. È una parola, non un colore: «BASE» e «MIO»
/// si distinguono anche senza vedere la differenza di tinta.
class _OriginTag extends StatelessWidget {
  const _OriginTag({required this.origin});

  final ExerciseOrigin origin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final isBase = origin == ExerciseOrigin.base;
    final foreground = isBase ? accents.mutedInk : accents.positive;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isBase
            ? theme.colorScheme.surfaceContainerHighest
            : accents.positiveSurface,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        isBase ? 'BASE' : 'MIO',
        style: theme.textTheme.labelSmall?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: AppEmptyState(
          icon: Icons.wifi_off_rounded,
          title: 'Non riesco a leggere la libreria',
          message: 'È un problema del database locale, non della rete.',
          actionLabel: 'Riprova',
          onAction: onRetry,
        ),
      ),
    );
  }
}
