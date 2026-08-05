import 'package:go_router/go_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/routines/domain/routine_models.dart';
import 'package:kal_tracker/features/routines/presentation/routine_editor_screen.dart';
import 'package:kal_tracker/features/routines/presentation/routine_providers.dart';
import 'package:kal_tracker/features/routines/presentation/widgets/routine_tags.dart';

/// L'elenco delle schede. Ogni riga dice in una frase che allenamento è:
/// quanti esercizi, quanto dura, se è un circuito e se contiene superserie o
/// blocchi a tempo.
class RoutinesScreen extends ConsumerWidget {
  const RoutinesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routines = ref.watch(routinesProvider);
    final searching = ref.watch(routineSearchQueryProvider).trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const _ScreenTitle(
          title: 'Schede',
          subtitle: 'Gli allenamenti che hai preparato',
        ),
        // Le tre facce della palestra stanno sotto la stessa voce: quello che
        // hai preparato, quello che puoi fare e quello che hai già fatto.
        actions: [
          IconButton(
            key: const Key('gym_open_exercises_button'),
            tooltip: 'Catalogo esercizi',
            onPressed: () => context.goNamed('exercises'),
            icon: const Icon(Icons.list_alt_outlined),
          ),
          IconButton(
            key: const Key('gym_open_history_button'),
            tooltip: 'Storico allenamenti',
            onPressed: () => context.goNamed('workout-history'),
            icon: const Icon(Icons.history_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: AdaptiveContent(
        child: routines.when(
          data: (items) => ListView(
            key: const Key('routines_list'),
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 112),
            children: [
              const _RoutineSearchField(),
              const SizedBox(height: 14),
              if (items.isNotEmpty) ...[
                _RoutinesIntroCard(routines: items),
                const SizedBox(height: 16),
              ],
              if (items.isEmpty)
                AppEmptyState(
                  key: const Key('routines_empty_state'),
                  icon: Icons.assignment_rounded,
                  title: searching
                      ? 'Nessuna scheda con questo nome'
                      : 'Ancora nessuna scheda',
                  message: searching
                      ? 'Prova con un altro nome, oppure svuota la ricerca.'
                      : 'Una scheda è la lista degli esercizi di una sessione: '
                            'la prepari una volta e la esegui quando vuoi.',
                  actionLabel: searching ? null : 'Crea la prima scheda',
                  onAction: searching ? null : () => openRoutineEditor(context),
                )
              else
                for (final routine in items) ...[
                  _RoutineCard(routine: routine),
                  const SizedBox(height: 12),
                ],
            ],
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: AppEmptyState(
                icon: Icons.error_outline_rounded,
                title: 'Non riesco a leggere le schede',
                message: 'Il database locale non ha risposto.',
                actionLabel: 'Riprova',
                onAction: () => ref.invalidate(routinesProvider),
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('create_routine_button'),
        onPressed: () => openRoutineEditor(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Nuova scheda'),
      ),
    );
  }
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

class _RoutineSearchField extends ConsumerStatefulWidget {
  const _RoutineSearchField();

  @override
  ConsumerState<_RoutineSearchField> createState() =>
      _RoutineSearchFieldState();
}

class _RoutineSearchFieldState extends ConsumerState<_RoutineSearchField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(routineSearchQueryProvider, (previous, next) {
      if (next != _controller.text) {
        _controller.text = next;
      }
    });
    return TextField(
      key: const Key('routine_search_field'),
      controller: _controller,
      textInputAction: TextInputAction.search,
      onChanged: (value) =>
          ref.read(routineSearchQueryProvider.notifier).state = value,
      decoration: InputDecoration(
        hintText: 'Cerca una scheda',
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: _controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Cancella la ricerca',
                icon: const Icon(Icons.close_rounded),
                onPressed: () {
                  _controller.clear();
                  ref.read(routineSearchQueryProvider.notifier).state = '';
                },
              ),
      ),
    );
  }
}

class _RoutinesIntroCard extends StatelessWidget {
  const _RoutinesIntroCard({required this.routines});

  final List<RoutineSummary> routines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final circuits = routines.where((routine) => routine.isCircuit).length;
    final minutes = routines.fold<int>(
      0,
      (sum, routine) => sum + routine.estimatedMinutes,
    );
    final average = routines.isEmpty ? 0 : (minutes / routines.length).round();

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
                Icons.assignment_rounded,
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
                    routines.length == 1
                        ? '1 scheda pronta'
                        : '${routines.length} schede pronte',
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      if (circuits > 0)
                        circuits == 1 ? '1 circuito' : '$circuits circuiti',
                      if (average > 0) 'in media ~$average min',
                    ].join(' · '),
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

class _RoutineCard extends ConsumerWidget {
  const _RoutineCard({required this.routine});

  final RoutineSummary routine;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final detail = [
      routine.exerciseCount == 1
          ? '1 esercizio'
          : '${routine.exerciseCount} esercizi',
      if (routine.warmupCount > 0) 'riscaldamento ${routine.warmupCount}',
      if (routine.isCircuit)
        '${routine.rounds} round · ${routine.workSec}″/${routine.shortRestSec}″',
      if (routine.estimatedMinutes > 0) '~${routine.estimatedMinutes} min',
    ].join(' · ');

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('routine_card_${routine.id}'),
        onTap: () => openRoutineEditor(context, routineId: routine.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 6, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: routine.isCircuit
                      ? accents.warningSurface
                      : theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(17),
                ),
                child: Icon(
                  routine.isCircuit
                      ? Icons.bolt_rounded
                      : Icons.assignment_rounded,
                  color: routine.isCircuit
                      ? accents.warning
                      : theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      routine.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      detail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: accents.mutedInk,
                      ),
                    ),
                    if (routine.isCircuit ||
                        routine.supersetGroupCount > 0 ||
                        routine.segmentCount > 0) ...[
                      const SizedBox(height: 9),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (routine.isCircuit) const RoutineTag.circuit(),
                          if (routine.supersetGroupCount > 0)
                            RoutineTag.superset(routine.supersetGroupCount),
                          if (routine.segmentCount > 0)
                            RoutineTag.segments(routine.segmentCount),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              _RoutineMenu(routine: routine),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoutineMenu extends ConsumerWidget {
  const _RoutineMenu({required this.routine});

  final RoutineSummary routine;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      key: Key('routine_menu_${routine.id}'),
      tooltip: 'Azioni per ${routine.name}',
      icon: const Icon(Icons.more_vert_rounded),
      onSelected: (value) async {
        if (value == 'edit') {
          await openRoutineEditor(context, routineId: routine.id);
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
        title: const Text('Eliminare questa scheda?'),
        content: Text(
          '«${routine.name}» sparisce dall\'elenco. Gli allenamenti già '
          'registrati con questa scheda restano nello storico.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            key: const Key('confirm_delete_routine'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Elimina'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await ref.read(routineRepositoryProvider).deleteRoutine(routine.id);
    messenger.showSnackBar(
      SnackBar(content: Text('«${routine.name}» eliminata.')),
    );
  }
}
