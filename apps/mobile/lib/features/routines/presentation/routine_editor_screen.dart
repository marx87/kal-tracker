import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/exercises/presentation/widgets/muscle_group_presentation.dart';
import 'package:kal_tracker/features/routines/domain/routine_draft.dart';
import 'package:kal_tracker/features/routines/domain/routine_models.dart';
import 'package:kal_tracker/features/routines/presentation/routine_providers.dart';
import 'package:kal_tracker/features/routines/presentation/widgets/exercise_picker_sheet.dart';
import 'package:kal_tracker/features/routines/presentation/widgets/interval_segment_sheet.dart';
import 'package:kal_tracker/features/routines/presentation/widgets/prescription_sheet.dart';

/// Apre l'editor di una scheda (nuova se [routineId] è nullo).
///
/// Come per gli esercizi si passa dal `Navigator`: le rotte con nome sono del
/// router, che è di un'altra area. Cambiare qui basta a cambiarlo ovunque.
Future<void> openRoutineEditor(BuildContext context, {String? routineId}) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RoutineEditorScreen(routineId: routineId),
      ),
    );

/// Costruisce e modifica una scheda: nome, esecuzione, riscaldamento,
/// esercizi con superserie e prescrizioni, blocchi a tempo, finisher.
class RoutineEditorScreen extends ConsumerStatefulWidget {
  const RoutineEditorScreen({this.routineId, super.key});

  final String? routineId;

  @override
  ConsumerState<RoutineEditorScreen> createState() =>
      _RoutineEditorScreenState();
}

class _RoutineEditorScreenState extends ConsumerState<RoutineEditorScreen> {
  var _draft = RoutineDraft.empty();
  final _name = TextEditingController();
  final _notes = TextEditingController();
  final _work = TextEditingController(text: '30');
  final _shortRest = TextEditingController(text: '30');
  final _longRest = TextEditingController(text: '60');
  final _rounds = TextEditingController(text: '3');
  final _warmupWork = TextEditingController(text: '30');
  final _warmupRest = TextEditingController(text: '15');

  var _loading = false;
  var _missing = false;
  var _saving = false;
  var _showNameError = false;
  var _showExercisesError = false;

  bool get _isEditing => widget.routineId != null;

  @override
  void initState() {
    super.initState();
    final routineId = widget.routineId;
    if (routineId != null) {
      _loading = true;
      unawaited(_load(routineId));
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    _work.dispose();
    _shortRest.dispose();
    _longRest.dispose();
    _rounds.dispose();
    _warmupWork.dispose();
    _warmupRest.dispose();
    super.dispose();
  }

  Future<void> _load(String routineId) async {
    final details = await ref
        .read(routineRepositoryProvider)
        .getRoutine(routineId);
    if (!mounted) {
      return;
    }
    if (details == null) {
      setState(() {
        _loading = false;
        _missing = true;
      });
      return;
    }
    setState(() {
      _draft = RoutineDraft.fromDetails(details);
      _name.text = details.name;
      _notes.text = details.notes ?? '';
      _work.text = '${details.workSec}';
      _shortRest.text = '${details.shortRestSec}';
      _longRest.text = '${details.longRestSec}';
      _rounds.text = '${details.rounds}';
      _warmupWork.text = '${details.warmupWorkSec}';
      _warmupRest.text = '${details.warmupRestSec}';
      _loading = false;
    });
  }

  /// Applica una modifica alla bozza e avvisa se un blocco a tempo si è
  /// sciolto per strada: succede quando i suoi esercizi smettono di essere
  /// consecutivi, ed è il genere di cosa che non deve accadere in silenzio.
  void _apply(RoutineDraft next) {
    final lost = _draft.segments.length - next.segments.length;
    setState(() => _draft = next);
    if (lost > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            lost == 1
                ? 'Un blocco a tempo si è sciolto: i suoi esercizi non sono '
                      'più consecutivi.'
                : '$lost blocchi a tempo si sono sciolti: i loro esercizi non '
                      'sono più consecutivi.',
          ),
        ),
      );
    }
  }

  Future<void> _addExercises(RoutineBlock block) async {
    final picked = await showExercisePickerSheet(
      context,
      title: switch (block) {
        RoutineBlock.warmup => 'Aggiungi al riscaldamento',
        RoutineBlock.main => 'Aggiungi esercizi',
        RoutineBlock.finisher => 'Aggiungi al finisher',
      },
      excludeIds: _draft.usedExerciseIds,
    );
    if (picked == null || picked.isEmpty) {
      return;
    }
    final stamp = DateTime.now().microsecondsSinceEpoch;
    _apply(
      _draft.addExercises(block, [
        for (final (index, exercise) in picked.indexed)
          DraftExercise.fromExercise(
            exercise,
            // La chiave locale deve essere unica anche fra due aggiunte
            // successive: l'ora in microsecondi più la posizione basta, e
            // resta stabile per tutta la sessione di modifica.
            key: '${block.name}-$stamp-$index',
            warmupDurationSec: block == RoutineBlock.warmup
                ? _draft.warmupWorkSec
                : null,
          ),
      ]),
    );
    setState(() => _showExercisesError = false);
  }

  Future<void> _editPrescription(RoutineBlock block, int index) async {
    final exercise = _draft.block(block)[index];
    final updated = await showPrescriptionSheet(
      context,
      exerciseName: exercise.name,
      mode: exercise.trackingMode,
      initial: exercise.prescription,
    );
    if (updated == null) {
      return;
    }
    _apply(
      _draft.replaceAt(
        block,
        index,
        (current) => DraftExercise(
          key: current.key,
          exerciseRefId: current.exerciseRefId,
          name: current.name,
          muscleGroup: current.muscleGroup,
          trackingMode: current.trackingMode,
          isMissing: current.isMissing,
          inSupersetWithPrevious: current.inSupersetWithPrevious,
          warmupDurationSec: current.warmupDurationSec,
          prescription: updated,
        ),
      ),
    );
  }

  Future<void> _editSegment({DraftSegment? existing}) async {
    final range = existing == null ? null : _draft.rangeOf(existing);
    final segment = await showIntervalSegmentSheet(
      context,
      main: _draft.main,
      initialStart: range?.start ?? 0,
      initialEnd: range?.end ?? 1,
      existing: existing,
    );
    if (segment == null) {
      return;
    }
    setState(() => _draft = _draft.upsertSegment(segment, replacing: existing));
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    setState(() {
      _showNameError = name.isEmpty;
      _showExercisesError = _draft.main.isEmpty;
    });
    if (name.isEmpty || _draft.main.isEmpty) {
      return;
    }
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final draft = _draft.copyWith(name: name, notes: _notes.text);
    try {
      final profile = await ref.read(marcoProfileProvider.future);
      await ref
          .read(routineRepositoryProvider)
          .saveRoutine(profileId: profile.id, draft: draft);
      messenger.showSnackBar(SnackBar(content: Text('«$name» salvata.')));
      navigator.pop();
    } on Object {
      if (!mounted) {
        return;
      }
      setState(() => _saving = false);
      messenger.showSnackBar(
        const SnackBar(content: Text('Non riesco a salvare questa scheda.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Scheda')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_missing) {
      return Scaffold(
        appBar: AppBar(title: const Text('Scheda')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: AppEmptyState(
              icon: Icons.search_off_rounded,
              title: 'Scheda non trovata',
              message: 'Potrebbe essere stata eliminata da un altro accesso.',
            ),
          ),
        ),
      );
    }

    final preview = _draft.preview();

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Modifica scheda' : 'Nuova scheda'),
      ),
      body: AdaptiveContent(
        child: ListView(
          key: const Key('routine_editor_list'),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _identityCard(),
            const SizedBox(height: 14),
            _executionCard(),
            const SizedBox(height: 14),
            _warmupSection(),
            const SizedBox(height: 14),
            _mainSection(),
            if (!_draft.isCircuit && _draft.main.isNotEmpty) ...[
              const SizedBox(height: 14),
              _segmentsSection(),
            ],
            if (_draft.isCircuit) ...[
              const SizedBox(height: 14),
              _finisherSection(),
            ],
            const SizedBox(height: 20),
            _EstimateLine(minutes: preview.estimatedMinutes),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('save_routine_button'),
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_rounded),
              label: Text(_isEditing ? 'Salva le modifiche' : 'Crea la scheda'),
            ),
            if (_showExercisesError) ...[
              const SizedBox(height: 8),
              Text(
                'Una scheda senza esercizi non si può eseguire: aggiungine '
                'almeno uno.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ─── Sezioni ─────────────────────────────────────────────────────────

  Widget _identityCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('routine_name_field'),
            controller: _name,
            enabled: !_saving,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) {
              if (_showNameError) {
                setState(() => _showNameError = false);
              }
            },
            decoration: InputDecoration(
              labelText: 'Nome della scheda',
              errorText: _showNameError ? 'Serve un nome.' : null,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('routine_notes_field'),
            controller: _notes,
            enabled: !_saving,
            maxLines: 3,
            maxLength: 1000,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Note (facoltative)',
              alignLabelWithHint: true,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _executionCard() => SectionCard(
    title: 'Come si esegue',
    subtitle: 'A serie e ripetizioni, oppure tutta a tempo.',
    icon: Icons.play_circle_outline_rounded,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const Key('routine_circuit_switch'),
          contentPadding: EdgeInsets.zero,
          value: _draft.isCircuit,
          title: const Text('Circuito a tempo'),
          subtitle: const Text(
            'Tutti gli esercizi a tempo, con recuperi automatici.',
          ),
          onChanged: _saving
              ? null
              : (value) =>
                    setState(() => _draft = _draft.copyWith(isCircuit: value)),
        ),
        if (_draft.isCircuit) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _NumberField(
                  fieldKey: const Key('routine_work_field'),
                  controller: _work,
                  label: 'Lavoro',
                  suffix: 'sec',
                  onValue: (value) =>
                      setState(() => _draft = _draft.copyWith(workSec: value)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _NumberField(
                  fieldKey: const Key('routine_short_rest_field'),
                  controller: _shortRest,
                  label: 'Recupero',
                  suffix: 'sec',
                  onValue: (value) => setState(
                    () => _draft = _draft.copyWith(shortRestSec: value),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _NumberField(
                  fieldKey: const Key('routine_long_rest_field'),
                  controller: _longRest,
                  label: 'Pausa tra i giri',
                  suffix: 'sec',
                  onValue: (value) => setState(
                    () => _draft = _draft.copyWith(longRestSec: value),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _NumberField(
                  fieldKey: const Key('routine_rounds_field'),
                  controller: _rounds,
                  label: 'Giri',
                  onValue: (value) =>
                      setState(() => _draft = _draft.copyWith(rounds: value)),
                ),
              ),
            ],
          ),
        ],
      ],
    ),
  );

  Widget _warmupSection() => SectionCard(
    title: 'Riscaldamento',
    subtitle: 'Facoltativo: un giro solo, ogni esercizio col suo tempo.',
    icon: Icons.local_fire_department_rounded,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_draft.warmup.isEmpty)
          const AppEmptyState(
            compact: true,
            icon: Icons.local_fire_department_rounded,
            message:
                'Nessun riscaldamento: la sessione parte dal primo esercizio.',
          )
        else ...[
          Row(
            children: [
              Expanded(
                child: _NumberField(
                  fieldKey: const Key('warmup_work_field'),
                  controller: _warmupWork,
                  label: 'Durata proposta',
                  suffix: 'sec',
                  onValue: (value) => setState(
                    () => _draft = _draft.copyWith(warmupWorkSec: value),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _NumberField(
                  fieldKey: const Key('warmup_rest_field'),
                  controller: _warmupRest,
                  label: 'Recupero',
                  suffix: 'sec',
                  onValue: (value) => setState(
                    () => _draft = _draft.copyWith(warmupRestSec: value),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ReorderableListView.builder(
            key: const Key('warmup_list'),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: _draft.warmup.length,
            onReorderItem: (oldIndex, newIndex) => _apply(
              _draft.reorderSimple(RoutineBlock.warmup, oldIndex, newIndex),
            ),
            itemBuilder: (context, index) {
              final step = _draft.warmup[index];
              return _WarmupRow(
                key: ValueKey(step.key),
                index: index,
                step: step,
                fallbackDuration: _draft.warmupWorkSec,
                onDuration: (seconds) => _apply(
                  _draft.replaceAt(
                    RoutineBlock.warmup,
                    index,
                    (current) => current.copyWith(warmupDurationSec: seconds),
                  ),
                ),
                onRemove: () =>
                    _apply(_draft.removeAt(RoutineBlock.warmup, index)),
              );
            },
          ),
        ],
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('add_warmup_button'),
          onPressed: _saving ? null : () => _addExercises(RoutineBlock.warmup),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Aggiungi al riscaldamento'),
        ),
      ],
    ),
  );

  Widget _mainSection() {
    final blocks = _draft.mainBlocks;
    return SectionCard(
      title: 'Esercizi',
      subtitle: _draft.main.isEmpty
          ? 'Il cuore della scheda.'
          : 'Trascina per riordinare, unisci due esercizi per farne una '
                'superserie.',
      icon: Icons.fitness_center_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_draft.main.isEmpty)
            const AppEmptyState(
              compact: true,
              icon: Icons.fitness_center_rounded,
              message: 'Ancora nessun esercizio: aggiungine dal catalogo.',
            )
          else
            ReorderableListView.builder(
              key: const Key('main_list'),
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: blocks.length,
              onReorderItem: (oldIndex, newIndex) =>
                  _apply(_draft.reorderMainBlocks(oldIndex, newIndex)),
              itemBuilder: (context, blockIndex) {
                final group = blocks[blockIndex];
                final isLast = blockIndex == blocks.length - 1;
                if (group.length >= 2) {
                  return _SupersetCard(
                    key: ValueKey('group-${_draft.main[group.first].key}'),
                    blockIndex: blockIndex,
                    letter: _letterFor(blocks, blockIndex),
                    members: [for (final index in group) _draft.main[index]],
                    memberIndices: group,
                    isLast: isLast,
                    onMergeNext: () =>
                        _apply(_draft.mergeBlockWithNext(blockIndex)),
                    onUngroup: () => _apply(_draft.ungroupBlock(blockIndex)),
                    onPrescription: (index) =>
                        _editPrescription(RoutineBlock.main, index),
                    onRemove: (index) =>
                        _apply(_draft.removeAt(RoutineBlock.main, index)),
                  );
                }
                final index = group.first;
                return _MainExerciseCard(
                  key: ValueKey(_draft.main[index].key),
                  blockIndex: blockIndex,
                  exercise: _draft.main[index],
                  segmentLabel: _segmentLabelFor(index),
                  isLast: isLast,
                  onMergeNext: () =>
                      _apply(_draft.mergeBlockWithNext(blockIndex)),
                  onPrescription: () =>
                      _editPrescription(RoutineBlock.main, index),
                  onRemove: () =>
                      _apply(_draft.removeAt(RoutineBlock.main, index)),
                );
              },
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('add_main_button'),
            onPressed: _saving ? null : () => _addExercises(RoutineBlock.main),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Aggiungi esercizi'),
          ),
        ],
      ),
    );
  }

  Widget _segmentsSection() {
    final segments = _draft.resolvedSegments;
    return SectionCard(
      title: 'Blocchi a tempo',
      subtitle: 'Una parte della scheda eseguita a tempo, come un circuito.',
      icon: Icons.timer_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (segments.isEmpty)
            const AppEmptyState(
              compact: true,
              icon: Icons.timer_outlined,
              message:
                  'Nessun blocco a tempo: tutti gli esercizi vanno a serie e '
                  'ripetizioni.',
            )
          else
            for (final segment in segments)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _SegmentCard(
                  segment: segment,
                  range: _draft.rangeOf(segment)!,
                  main: _draft.main,
                  onEdit: () => _editSegment(existing: segment),
                  onRemove: () =>
                      setState(() => _draft = _draft.removeSegment(segment)),
                ),
              ),
          const SizedBox(height: 4),
          OutlinedButton.icon(
            key: const Key('add_segment_button'),
            onPressed: _saving ? null : () => _editSegment(),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Aggiungi un blocco a tempo'),
          ),
        ],
      ),
    );
  }

  Widget _finisherSection() => SectionCard(
    title: 'Finisher',
    subtitle: 'Dopo il circuito e prima del defaticamento.',
    icon: Icons.bolt_rounded,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_draft.finisher.isEmpty)
          const AppEmptyState(
            compact: true,
            icon: Icons.bolt_rounded,
            message: 'Nessun finisher: la sessione chiude col circuito.',
          )
        else
          ReorderableListView.builder(
            key: const Key('finisher_list'),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: _draft.finisher.length,
            onReorderItem: (oldIndex, newIndex) => _apply(
              _draft.reorderSimple(RoutineBlock.finisher, oldIndex, newIndex),
            ),
            itemBuilder: (context, index) {
              final exercise = _draft.finisher[index];
              return _SimpleExerciseRow(
                key: ValueKey(exercise.key),
                index: index,
                exercise: exercise,
                onPrescription: () =>
                    _editPrescription(RoutineBlock.finisher, index),
                onRemove: () =>
                    _apply(_draft.removeAt(RoutineBlock.finisher, index)),
              );
            },
          ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('add_finisher_button'),
          onPressed: _saving
              ? null
              : () => _addExercises(RoutineBlock.finisher),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Aggiungi al finisher'),
        ),
      ],
    ),
  );

  /// Lettera della superserie (A, B, C…) nell'ordine in cui compaiono: un
  /// numero di blocco non direbbe niente a chi legge la scheda in palestra.
  String _letterFor(List<List<int>> blocks, int blockIndex) {
    var letter = 0;
    for (var index = 0; index < blockIndex; index++) {
      if (blocks[index].length >= 2) {
        letter++;
      }
    }
    return String.fromCharCode(65 + (letter % 26));
  }

  /// Se l'esercizio sta dentro un blocco a tempo, la riga che lo dice.
  String? _segmentLabelFor(int index) {
    for (final segment in _draft.resolvedSegments) {
      final range = _draft.rangeOf(segment);
      if (range != null && index >= range.start && index < range.end) {
        return '${segment.workSec}″ lavoro · ${segment.restSec}″ recupero · '
            '${segment.rounds} ${segment.rounds == 1 ? "giro" : "giri"}';
      }
    }
    return null;
  }
}

// ─── Pezzi di lista ────────────────────────────────────────────────────

/// Un esercizio singolo del blocco principale.
class _MainExerciseCard extends StatelessWidget {
  const _MainExerciseCard({
    required this.blockIndex,
    required this.exercise,
    required this.isLast,
    required this.onMergeNext,
    required this.onPrescription,
    required this.onRemove,
    this.segmentLabel,
    super.key,
  });

  final int blockIndex;
  final DraftExercise exercise;
  final String? segmentLabel;
  final bool isLast;
  final VoidCallback onMergeNext;
  final VoidCallback onPrescription;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _RowFrame(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ExerciseHeader(
              dragIndex: blockIndex,
              exercise: exercise,
              onRemove: onRemove,
            ),
            if (segmentLabel case final label?) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(
                    Icons.timer_outlined,
                    size: 15,
                    color: AppAccents.of(context).positive,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppAccents.of(context).positive,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _PrescriptionButton(
                    exercise: exercise,
                    onTap: onPrescription,
                  ),
                ),
                if (!isLast) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    key: Key('merge_block_$blockIndex'),
                    tooltip: 'Unisci in superserie con il prossimo',
                    onPressed: onMergeNext,
                    icon: Icon(
                      Icons.link_rounded,
                      color: AppAccents.of(context).info,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Una superserie: due o più esercizi alternati, con il riposo solo a fine
/// giro. La lettera e i numeri (A1, A2) sono gli stessi che si leggono
/// durante l'allenamento.
class _SupersetCard extends StatelessWidget {
  const _SupersetCard({
    required this.blockIndex,
    required this.letter,
    required this.members,
    required this.memberIndices,
    required this.isLast,
    required this.onMergeNext,
    required this.onUngroup,
    required this.onPrescription,
    required this.onRemove,
    super.key,
  });

  final int blockIndex;
  final String letter;
  final List<DraftExercise> members;

  /// Posizioni degli esercizi nel blocco principale: servono a rimandare
  /// indietro l'indice giusto quando si tocca una riga del gruppo.
  final List<int> memberIndices;

  final bool isLast;
  final VoidCallback onMergeNext;
  final VoidCallback onUngroup;
  final void Function(int mainIndex) onPrescription;
  final void Function(int mainIndex) onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: BoxDecoration(
          color: accents.infoSurface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: accents.info.withValues(alpha: 0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ReorderableDragStartListener(
                  index: blockIndex,
                  child: Tooltip(
                    message: 'Trascina per spostare la superserie',
                    // 48 di lato: è una maniglia, va presa al primo colpo.
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Icon(
                        Icons.drag_indicator_rounded,
                        color: accents.info,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    'Superserie $letter · ${members.length} alternati',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: accents.info,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                if (!isLast)
                  IconButton(
                    key: Key('merge_block_$blockIndex'),
                    tooltip: 'Aggiungi il prossimo alla superserie',
                    onPressed: onMergeNext,
                    icon: Icon(Icons.add_link_rounded, color: accents.info),
                  ),
                IconButton(
                  key: Key('ungroup_block_$blockIndex'),
                  tooltip: 'Sciogli la superserie',
                  onPressed: onUngroup,
                  icon: Icon(Icons.link_off_rounded, color: accents.mutedInk),
                ),
              ],
            ),
            for (final (position, member) in members.indexed) ...[
              const SizedBox(height: 8),
              _RowFrame(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _ExerciseHeader(
                      exercise: member,
                      badgeLabel: '$letter${position + 1}',
                      onRemove: () => onRemove(memberIndices[position]),
                    ),
                    const SizedBox(height: 8),
                    _PrescriptionButton(
                      exercise: member,
                      onTap: () => onPrescription(memberIndices[position]),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Riga del finisher: nessuna catena, nessun blocco a tempo, solo l'esercizio
/// e la sua prescrizione.
class _SimpleExerciseRow extends StatelessWidget {
  const _SimpleExerciseRow({
    required this.index,
    required this.exercise,
    required this.onPrescription,
    required this.onRemove,
    super.key,
  });

  final int index;
  final DraftExercise exercise;
  final VoidCallback onPrescription;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _RowFrame(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ExerciseHeader(
              dragIndex: index,
              exercise: exercise,
              onRemove: onRemove,
            ),
            const SizedBox(height: 8),
            _PrescriptionButton(exercise: exercise, onTap: onPrescription),
          ],
        ),
      ),
    );
  }
}

/// Passo di riscaldamento: il tempo è suo, non della scheda, perché
/// Cat-Cow 45″ e 90/90 60″ convivono nello stesso riscaldamento.
class _WarmupRow extends StatefulWidget {
  const _WarmupRow({
    required this.index,
    required this.step,
    required this.fallbackDuration,
    required this.onDuration,
    required this.onRemove,
    super.key,
  });

  final int index;
  final DraftExercise step;
  final int fallbackDuration;
  final ValueChanged<int> onDuration;
  final VoidCallback onRemove;

  @override
  State<_WarmupRow> createState() => _WarmupRowState();
}

class _WarmupRowState extends State<_WarmupRow> {
  late final TextEditingController _duration;

  @override
  void initState() {
    super.initState();
    _duration = TextEditingController(
      text: '${widget.step.warmupDurationSec ?? widget.fallbackDuration}',
    );
  }

  @override
  void dispose() {
    _duration.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _RowFrame(
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: widget.index,
              child: const _DragHandle(),
            ),
            MuscleGroupBadge(group: widget.step.muscleGroup, size: 40),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.step.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            SizedBox(
              width: 96,
              child: TextField(
                key: Key('warmup_duration_${widget.step.exerciseRefId}'),
                controller: _duration,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  suffixText: 'sec',
                  isDense: true,
                ),
                onChanged: (value) {
                  final parsed = int.tryParse(value);
                  if (parsed != null && parsed > 0) {
                    widget.onDuration(parsed);
                  }
                },
              ),
            ),
            IconButton(
              key: Key('remove_warmup_${widget.step.exerciseRefId}'),
              tooltip: 'Togli ${widget.step.name}',
              onPressed: widget.onRemove,
              icon: const Icon(Icons.remove_circle_outline_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _SegmentCard extends StatelessWidget {
  const _SegmentCard({
    required this.segment,
    required this.range,
    required this.main,
    required this.onEdit,
    required this.onRemove,
  });

  final DraftSegment segment;
  final ({int start, int end}) range;
  final List<DraftExercise> main;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final from = main[range.start].name;
    final to = main[range.end - 1].name;
    return _RowFrame(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.timer_outlined, color: accents.positive),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  range.end - range.start == 1 ? from : 'Da «$from» a «$to»',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 3),
                Text(
                  '${segment.workSec}″ lavoro · ${segment.restSec}″ recupero · '
                  '${segment.rounds} ${segment.rounds == 1 ? "giro" : "giri"}'
                  '${segment.longRestSec > 0 ? " · ${segment.longRestSec}″ tra i giri" : ""}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: accents.mutedInk,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: Key('edit_segment_${segment.memberKeys.first}'),
            tooltip: 'Modifica il blocco a tempo',
            onPressed: onEdit,
            icon: const Icon(Icons.tune_rounded),
          ),
          IconButton(
            key: Key('remove_segment_${segment.memberKeys.first}'),
            tooltip: 'Togli il blocco a tempo',
            onPressed: onRemove,
            icon: const Icon(Icons.remove_circle_outline_rounded),
          ),
        ],
      ),
    );
  }
}

/// Intestazione comune a tutte le righe di esercizio: maniglia, miniatura,
/// nome, gruppo e il pulsante per toglierlo.
class _ExerciseHeader extends StatelessWidget {
  const _ExerciseHeader({
    required this.exercise,
    required this.onRemove,
    this.dragIndex,
    this.badgeLabel,
  });

  final DraftExercise exercise;
  final VoidCallback onRemove;

  /// Presente quando la riga è trascinabile per conto suo (riscaldamento,
  /// finisher, esercizio singolo). Dentro una superserie si trascina il
  /// gruppo, non il membro.
  final int? dragIndex;

  /// «A1», «A2»: la posizione dentro la superserie.
  final String? badgeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    return Row(
      children: [
        if (dragIndex case final index?)
          ReorderableDragStartListener(
            index: index,
            child: const _DragHandle(),
          ),
        if (badgeLabel case final label?)
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            margin: const EdgeInsets.only(right: 10),
            decoration: BoxDecoration(
              color: accents.info,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.surface,
                fontWeight: FontWeight.w900,
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: MuscleGroupBadge(group: exercise.muscleGroup, size: 40),
          ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                exercise.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 2),
              if (exercise.isMissing)
                const StatusChip(
                  compact: true,
                  level: AppStatusLevel.warning,
                  label: 'Non più in libreria',
                )
              else
                Text(
                  exercise.muscleGroup.label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: accents.mutedInk,
                  ),
                ),
            ],
          ),
        ),
        IconButton(
          key: Key('remove_exercise_${exercise.key}'),
          tooltip: 'Togli ${exercise.name}',
          onPressed: onRemove,
          icon: const Icon(Icons.remove_circle_outline_rounded),
        ),
      ],
    );
  }
}

/// La prescrizione, leggibile e toccabile: è qui che serie, ripetizioni e
/// recupero smettono di essere solo dati importati.
class _PrescriptionButton extends StatelessWidget {
  const _PrescriptionButton({required this.exercise, required this.onTap});

  final DraftExercise exercise;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final isSet = !exercise.prescription.isEmpty;
    return InkWell(
      key: Key('prescription_${exercise.key}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSet
              ? accents.positiveSurface
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSet
                ? accents.positive.withValues(alpha: 0.4)
                : theme.colorScheme.outline,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.tune_rounded,
              size: 17,
              color: isSet ? accents.positive : accents.mutedInk,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                exercise.prescription.summary(exercise.trackingMode),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: isSet ? accents.positive : accents.mutedInk,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// La cornice comune delle righe: fondo di carta, bordo sottile, raggio 20 —
/// un gradino sotto la card di sezione che le contiene.
class _RowFrame extends StatelessWidget {
  const _RowFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: theme.colorScheme.outline, width: 0.8),
      ),
      child: child,
    );
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Trascina per riordinare',
      child: SizedBox(
        width: 48,
        height: 48,
        child: Icon(
          Icons.drag_indicator_rounded,
          color: AppAccents.of(context).mutedInk,
        ),
      ),
    );
  }
}

/// Campo numerico dei tempi: filtra le cifre e riporta il valore appena è
/// leggibile, così l'anteprima dei minuti resta viva mentre si scrive.
class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.fieldKey,
    required this.controller,
    required this.label,
    required this.onValue,
    this.suffix,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final String? suffix;
  final ValueChanged<int> onValue;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: fieldKey,
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(labelText: label, suffixText: suffix),
      onChanged: (value) {
        final parsed = int.tryParse(value);
        if (parsed != null && parsed > 0) {
          onValue(parsed);
        }
      },
    );
  }
}

class _EstimateLine extends StatelessWidget {
  const _EstimateLine({required this.minutes});

  final int minutes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    return Row(
      key: const Key('routine_estimate'),
      children: [
        Icon(Icons.schedule_rounded, size: 18, color: accents.mutedInk),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            minutes <= 0
                ? 'La durata si calcola quando aggiungi gli esercizi.'
                : 'Durata indicativa: ~$minutes minuti.',
            style: theme.textTheme.bodySmall?.copyWith(color: accents.mutedInk),
          ),
        ),
      ],
    );
  }
}
