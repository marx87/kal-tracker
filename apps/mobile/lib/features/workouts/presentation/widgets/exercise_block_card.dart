import 'package:flutter/material.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/workouts/domain/live_load_guidance.dart';
import 'package:kal_tracker/features/workouts/domain/live_workout_focus.dart';
import 'package:kal_tracker/features/workouts/domain/superset_flow.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';
import 'package:kal_tracker/features/workouts/presentation/widgets/live_load_guidance_card.dart';
import 'package:kal_tracker/features/workouts/presentation/widgets/workout_set_row.dart';

/// Cosa la card sa fare, in un oggetto solo: così aggiungere un'azione non
/// vuol dire aggiungere il quinto parametro a due costruttori.
class WorkoutBlockActions {
  const WorkoutBlockActions({
    required this.onSetChanged,
    required this.onSetComplete,
    required this.onAddRound,
    this.onEditRest,
  });

  /// (indice esercizio, indice serie, serie nuova).
  final void Function(int exerciseIndex, int setIndex, WorkoutSet set)
  onSetChanged;

  /// (indice esercizio, indice serie).
  final void Function(int exerciseIndex, int setIndex) onSetComplete;

  /// Un round in più. Per un esercizio singolo è una serie; per una
  /// superserie è una cella per ogni membro.
  final void Function(List<int> exerciseIndices) onAddRound;

  /// Cambia il recupero del blocco. Nullo quando non è modificabile
  /// (defaticamento).
  final void Function(List<int> exerciseIndices)? onEditRest;
}

/// Un esercizio con le sue serie.
class ExerciseBlockCard extends StatelessWidget {
  const ExerciseBlockCard({
    required this.exercise,
    required this.exerciseIndex,
    required this.actions,
    this.current,
    this.busyCursor,
    this.guidance,
    this.onApplyGuidance,
    this.onUndoGuidance,
    super.key,
  });

  final WorkoutExercise exercise;
  final int exerciseIndex;
  final WorkoutBlockActions actions;

  /// La cella su cui è il fuoco in tutta la sessione, non solo qui.
  final WorkoutCursor? current;

  /// La cella con un salvataggio in volo.
  final WorkoutCursor? busyCursor;
  final LiveLoadGuidance? guidance;
  final VoidCallback? onApplyGuidance;
  final VoidCallback? onUndoGuidance;

  @override
  Widget build(BuildContext context) {
    final done = exercise.sets.where((set) => set.completed).length;

    return SectionCard(
      title: exercise.exerciseName,
      subtitle: _blockSubtitle(exercise, done),
      icon: _blockIcon(exercise),
      actionLabel: exercise.isCooldown ? null : 'Serie +',
      onAction: exercise.isCooldown
          ? null
          : () => actions.onAddRound([exerciseIndex]),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BlockChips(
            exercise: exercise,
            onEditRest: actions.onEditRest == null
                ? null
                : () => actions.onEditRest!([exerciseIndex]),
          ),
          if (guidance case final suggestion?) ...[
            const SizedBox(height: 12),
            LiveLoadGuidanceCard(
              guidance: suggestion,
              onApply: onApplyGuidance,
              onUndo: onUndoGuidance,
            ),
          ],
          const SizedBox(height: 12),
          for (var setIndex = 0; setIndex < exercise.sets.length; setIndex++)
            WorkoutSetRow(
              key: ValueKey('set-$exerciseIndex-$setIndex'),
              set: exercise.sets[setIndex],
              setNumber: setIndex + 1,
              trackingMode: exercise.trackingMode,
              exerciseName: exercise.exerciseName,
              isCurrent:
                  current?.exerciseIndex == exerciseIndex &&
                  current?.setIndex == setIndex,
              isBusy:
                  busyCursor?.exerciseIndex == exerciseIndex &&
                  busyCursor?.setIndex == setIndex,
              onChanged: (set) =>
                  actions.onSetChanged(exerciseIndex, setIndex, set),
              onComplete: () => actions.onSetComplete(exerciseIndex, setIndex),
            ),
        ],
      ),
    );
  }
}

/// Una superserie: due o più esercizi che si alternano senza recupero in
/// mezzo.
///
/// La presentazione è PER ROUND e non per esercizio, perché è così che la si
/// esegue: A1, B1, poi recupero, poi A2, B2. Mostrarla come due elenchi
/// affiancati sarebbe fedele ai dati e sbagliata per chi si allena.
class SupersetGroupCard extends StatelessWidget {
  const SupersetGroupCard({
    required this.workout,
    required this.memberIndices,
    required this.actions,
    this.current,
    this.busyCursor,
    this.guidanceByExercise = const {},
    this.guidanceUndoIndices = const {},
    this.onApplyGuidance,
    this.onUndoGuidance,
    super.key,
  });

  final Workout workout;
  final List<int> memberIndices;
  final WorkoutBlockActions actions;
  final WorkoutCursor? current;
  final WorkoutCursor? busyCursor;
  final Map<int, LiveLoadGuidance> guidanceByExercise;
  final Set<int> guidanceUndoIndices;
  final void Function(int exerciseIndex)? onApplyGuidance;
  final void Function(int exerciseIndex)? onUndoGuidance;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final flow = calculateSupersetFlow(workout, memberIndices);
    final members = [
      for (final index in memberIndices) workout.exercises[index],
    ];
    final restSeconds = members.first.restSeconds;

    return SectionCard(
      title: 'Superserie',
      subtitle: members.map((member) => member.exerciseName).join(' + '),
      icon: Icons.repeat_rounded,
      actionLabel: 'Round +',
      onAction: () => actions.onAddRound(memberIndices),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${flow.completedCells} celle su ${flow.totalCells}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: accents.mutedInk,
                  ),
                ),
              ),
              if (restSeconds != null)
                _RestChip(
                  seconds: restSeconds,
                  onTap: actions.onEditRest == null
                      ? null
                      : () => actions.onEditRest!(memberIndices),
                ),
            ],
          ),
          for (final exerciseIndex in memberIndices)
            if (guidanceByExercise[exerciseIndex] case final suggestion?) ...[
              const SizedBox(height: 10),
              LiveLoadGuidanceCard(
                guidance: suggestion,
                onApply: onApplyGuidance == null
                    ? null
                    : () => onApplyGuidance!(exerciseIndex),
                onUndo:
                    onUndoGuidance == null ||
                        !guidanceUndoIndices.contains(exerciseIndex)
                    ? null
                    : () => onUndoGuidance!(exerciseIndex),
              ),
            ],
          const SizedBox(height: 12),
          for (var round = 0; round < flow.roundCount; round++) ...[
            _RoundHeader(round: round + 1, total: flow.roundCount),
            for (var position = 0; position < memberIndices.length; position++)
              if (round < members[position].sets.length)
                _SupersetCellRow(
                  key: ValueKey('cell-${memberIndices[position]}-$round'),
                  letter: _memberLetter(position),
                  exercise: members[position],
                  exerciseIndex: memberIndices[position],
                  setIndex: round,
                  actions: actions,
                  current: current,
                  busyCursor: busyCursor,
                ),
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }
}

/// A, B, C… La lettera non è decorativa: è come la superserie viene chiamata
/// nella scheda e nel parlato («torna su A»).
String _memberLetter(int position) =>
    String.fromCharCode('A'.codeUnitAt(0) + position);

class _RoundHeader extends StatelessWidget {
  const _RoundHeader({required this.round, required this.total});

  final int round;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Text(
              'Round $round di $total',
              style: theme.textTheme.labelLarge?.copyWith(
                color: accents.mutedInk,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: Divider(color: theme.colorScheme.outline)),
          ],
        ),
      ),
    );
  }
}

class _SupersetCellRow extends StatelessWidget {
  const _SupersetCellRow({
    required this.letter,
    required this.exercise,
    required this.exerciseIndex,
    required this.setIndex,
    required this.actions,
    required this.current,
    required this.busyCursor,
    super.key,
  });

  final String letter;
  final WorkoutExercise exercise;
  final int exerciseIndex;
  final int setIndex;
  final WorkoutBlockActions actions;
  final WorkoutCursor? current;
  final WorkoutCursor? busyCursor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, right: 10),
          child: Semantics(
            label: 'Stazione $letter, ${exercise.exerciseName}',
            child: ExcludeSemantics(
              child: Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Text(
                  letter,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: scheme.onSecondaryContainer,
                  ),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: WorkoutSetRow(
            set: exercise.sets[setIndex],
            setNumber: setIndex + 1,
            trackingMode: exercise.trackingMode,
            exerciseName: exercise.exerciseName,
            isCurrent:
                current?.exerciseIndex == exerciseIndex &&
                current?.setIndex == setIndex,
            isBusy:
                busyCursor?.exerciseIndex == exerciseIndex &&
                busyCursor?.setIndex == setIndex,
            onChanged: (set) =>
                actions.onSetChanged(exerciseIndex, setIndex, set),
            onComplete: () => actions.onSetComplete(exerciseIndex, setIndex),
          ),
        ),
      ],
    );
  }
}

class _BlockChips extends StatelessWidget {
  const _BlockChips({required this.exercise, required this.onEditRest});

  final WorkoutExercise exercise;
  final VoidCallback? onEditRest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final chips = <Widget>[
      if (exercise.muscleGroup case final group?)
        _InfoChip(icon: Icons.accessibility_new_rounded, label: group.label)
      else
        // Il gruppo mancante non è un dettaglio estetico: senza, le calorie
        // di questo esercizio verranno calcolate su 5.0 MET di ripiego. Va
        // detto, non nascosto.
        const StatusChip(
          level: AppStatusLevel.warning,
          label: 'Gruppo muscolare assente',
          compact: true,
        ),
      _InfoChip(icon: Icons.tune_rounded, label: exercise.trackingMode.label),
      if (exercise.restSeconds case final seconds?)
        _RestChip(seconds: seconds, onTap: onEditRest),
    ];

    return DefaultTextStyle.merge(
      style: theme.textTheme.labelMedium?.copyWith(color: accents.mutedInk),
      child: Wrap(spacing: 8, runSpacing: 8, children: chips),
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: accents.mutedInk),
          const SizedBox(width: 6),
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

/// Il recupero del blocco. Toccabile quando si può cambiare, e allora rispetta
/// i 48 di bersaglio; altrimenti resta un'etichetta.
class _RestChip extends StatelessWidget {
  const _RestChip({required this.seconds, this.onTap});

  final int seconds;
  final VoidCallback? onTap;

  String get _label {
    if (seconds < 60) return 'Recupero ${seconds}s';
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return rest == 0
        ? 'Recupero $minutes′'
        : 'Recupero $minutes′${rest.toString().padLeft(2, '0')}″';
  }

  @override
  Widget build(BuildContext context) {
    final chip = _InfoChip(icon: Icons.timer_outlined, label: _label);
    if (onTap == null) {
      return Semantics(
        label: _label,
        child: ExcludeSemantics(child: chip),
      );
    }
    return Semantics(
      button: true,
      label: '$_label. Tocca per cambiarlo.',
      onTap: onTap,
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Center(child: chip),
          ),
        ),
      ),
    );
  }
}

String _blockSubtitle(WorkoutExercise exercise, int done) {
  final prefix = switch (exercise) {
    _ when exercise.isWarmup => 'Riscaldamento · ',
    _ when exercise.isCooldown => 'Defaticamento · ',
    _ when exercise.isFinisher => 'Finisher · ',
    _ => '',
  };
  return '$prefix$done di ${exercise.sets.length} '
      '${exercise.sets.length == 1 ? 'serie' : 'serie'} fatte';
}

IconData _blockIcon(WorkoutExercise exercise) {
  if (exercise.isWarmup) return Icons.local_fire_department_rounded;
  if (exercise.isCooldown) return Icons.self_improvement_rounded;
  if (exercise.isFinisher) return Icons.bolt_rounded;
  return Icons.fitness_center_rounded;
}
