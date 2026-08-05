import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';
import 'package:kal_tracker/features/exercises/presentation/exercise_providers.dart';
import 'package:kal_tracker/features/exercises/presentation/widgets/exercise_editor_sheet.dart';
import 'package:kal_tracker/features/exercises/presentation/widgets/muscle_group_presentation.dart';

/// Sceglie più esercizi in una volta sola e li restituisce nell'ordine in cui
/// sono stati toccati.
///
/// Uno alla volta, com'era all'inizio in Gym, costringeva a riaprire il
/// foglio per ogni esercizio: qui si seleziona tutto il blocco e si conferma.
Future<List<Exercise>?> showExercisePickerSheet(
  BuildContext context, {
  required String title,
  required Set<String> excludeIds,
}) => showModalBottomSheet<List<Exercise>>(
  context: context,
  isScrollControlled: true,
  builder: (_) => ExercisePickerSheet(title: title, excludeIds: excludeIds),
);

class ExercisePickerSheet extends ConsumerStatefulWidget {
  const ExercisePickerSheet({
    required this.title,
    required this.excludeIds,
    super.key,
  });

  final String title;

  /// Gli esercizi già presenti nella scheda: non si ripropongono, perché le
  /// prescrizioni sono per esercizio e due righe uguali si contenderebbero
  /// la stessa configurazione.
  final Set<String> excludeIds;

  @override
  ConsumerState<ExercisePickerSheet> createState() =>
      _ExercisePickerSheetState();
}

class _ExercisePickerSheetState extends ConsumerState<ExercisePickerSheet> {
  final _search = TextEditingController();
  final _selected = <Exercise>[];
  MuscleGroup? _group;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Exercise> _filter(List<Exercise> catalog) {
    final needle = _search.text.trim().toLowerCase();
    final available = [
      for (final exercise in catalog)
        if (!widget.excludeIds.contains(exercise.id)) exercise,
    ];
    return [
      for (final exercise in available)
        if ((_group == null || exercise.muscleGroup == _group) &&
            (needle.isEmpty ||
                exercise.name.toLowerCase().contains(needle) ||
                exercise.muscleGroup.label.toLowerCase().contains(needle)))
          exercise,
    ]..sort((a, b) {
      final byGroup = a.muscleGroup.label.compareTo(b.muscleGroup.label);
      return byGroup != 0 ? byGroup : a.name.compareTo(b.name);
    });
  }

  Future<void> _quickCreate() async {
    final name = _search.text.trim();
    final created = await showExerciseEditorSheet(
      context,
      initialName: name,
      initialGroup: _group,
    );
    if (created == null || !mounted) {
      return;
    }
    // Selezionato di default: chi lo ha appena creato lo sta aggiungendo,
    // non lo sta guardando.
    setState(() {
      _selected.add(created);
      _search.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final catalog = ref.watch(exerciseCatalogProvider).valueOrNull ?? const [];
    final filtered = _filter(catalog);
    final query = _search.text.trim();
    final exactMatch =
        query.isEmpty ||
        catalog.any(
          (exercise) => exercise.name.toLowerCase() == query.toLowerCase(),
        );
    final groups = <MuscleGroup>{
      for (final exercise in catalog) exercise.muscleGroup,
    }.toList()..sort((a, b) => a.label.compareTo(b.label));

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        widget.title,
                        style: theme.textTheme.headlineSmall,
                      ),
                    ),
                  ),
                  Text(
                    '${filtered.length} disponibili',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: accents.mutedInk,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                key: const Key('picker_search_field'),
                controller: _search,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: 'Cerca un esercizio',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  ChoiceChip(
                    key: const Key('picker_group_any'),
                    label: const Text('Tutti'),
                    selected: _group == null,
                    onSelected: (_) => setState(() => _group = null),
                  ),
                  for (final group in groups) ...[
                    const SizedBox(width: 8),
                    ChoiceChip(
                      key: Key('picker_group_${group.name}'),
                      label: Text(group.label),
                      selected: _group == group,
                      onSelected: (selected) =>
                          setState(() => _group = selected ? group : null),
                    ),
                  ],
                ],
              ),
            ),
            const Divider(height: 18),
            Expanded(
              child: filtered.isEmpty && exactMatch
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: AppEmptyState(
                        icon: Icons.search_off_rounded,
                        message: catalog.isEmpty
                            ? 'La libreria è vuota: crea qui il primo '
                                  'esercizio.'
                            : 'Nessun esercizio con questi filtri. Scrivi un '
                                  'nome nuovo per crearlo al volo.',
                      ),
                    )
                  : ListView(
                      key: const Key('picker_list'),
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                      children: [
                        if (!exactMatch)
                          _CreateTile(query: query, onTap: _quickCreate),
                        for (final exercise in filtered)
                          _PickerRow(
                            exercise: exercise,
                            selected: _selected.any(
                              (item) => item.id == exercise.id,
                            ),
                            onChanged: (value) => setState(() {
                              _selected.removeWhere(
                                (item) => item.id == exercise.id,
                              );
                              if (value) {
                                _selected.add(exercise);
                              }
                            }),
                          ),
                      ],
                    ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Annulla'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        key: const Key('picker_confirm_button'),
                        onPressed: _selected.isEmpty
                            ? null
                            : () => Navigator.of(
                                context,
                              ).pop(List<Exercise>.from(_selected)),
                        icon: const Icon(Icons.check_rounded),
                        label: Text(
                          _selected.isEmpty
                              ? 'Aggiungi'
                              : 'Aggiungi ${_selected.length}',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.exercise,
    required this.selected,
    required this.onChanged,
  });

  final Exercise exercise;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CheckboxListTile(
      key: Key('pick_exercise_${exercise.id}'),
      value: selected,
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: EdgeInsets.zero,
      secondary: MuscleGroupBadge(group: exercise.muscleGroup, size: 42),
      title: Text(exercise.name, style: theme.textTheme.titleSmall),
      subtitle: Text(
        '${exercise.muscleGroup.label} · ${exercise.trackingMode.label}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: AppAccents.of(context).mutedInk,
        ),
      ),
      onChanged: (value) => onChanged(value ?? false),
    );
  }
}

/// La riga «Crea «…»» in cima ai risultati: se l'esercizio non esiste, si fa
/// da qui invece di abbandonare la scheda a metà.
class _CreateTile extends StatelessWidget {
  const _CreateTile({required this.query, required this.onTap});

  final String query;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        key: const Key('picker_create_tile'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              Icon(
                Icons.add_circle_outline_rounded,
                color: theme.colorScheme.onPrimaryContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Crea «$query»',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                    Text(
                      'Lo aggiunge alla libreria e a questa scheda',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
