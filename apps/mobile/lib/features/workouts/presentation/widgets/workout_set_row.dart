import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/workouts/domain/exercise_kind.dart';
import 'package:kal_tracker/features/workouts/domain/live_workout_focus.dart';
import 'package:kal_tracker/features/workouts/domain/workout.dart';
import 'package:kal_tracker/features/workouts/presentation/widgets/plate_calculator_sheet.dart';
import 'package:kal_tracker/features/workouts/presentation/widgets/set_input_controls.dart';

/// Una riga di serie dentro la sessione dal vivo.
///
/// Sta in piedi da sola: riceve la serie, restituisce la serie nuova, e non sa
/// niente di repository né di indici. La schermata le passa il cursore solo
/// per dire «questa è quella che tocca adesso».
class WorkoutSetRow extends StatelessWidget {
  const WorkoutSetRow({
    required this.set,
    required this.setNumber,
    required this.trackingMode,
    required this.onChanged,
    required this.onComplete,
    this.isCurrent = false,
    this.isBusy = false,
    this.exerciseName,
    super.key,
  });

  final WorkoutSet set;

  /// Il numero mostrato: 1-based, come lo conta chi si allena.
  final int setNumber;

  final ExerciseTrackingMode trackingMode;

  /// Cambio di un valore. NON completa la serie: sono due gesti distinti,
  /// perché si aggiusta il peso anche dopo averla spuntata.
  final ValueChanged<WorkoutSet> onChanged;

  /// «Fatta». Asincrono lato schermata: qui arriva solo il tocco.
  final VoidCallback onComplete;

  /// La serie su cui è il fuoco: è quella che il pulsante grande in fondo
  /// completa, e va riconoscibile a colpo d'occhio.
  final bool isCurrent;

  /// Un salvataggio è in volo per questa cella: il pulsante si spegne, così
  /// due tocchi rapidi non producono due scritture.
  final bool isBusy;

  /// Serve al calcola-dischi per dire di quale esercizio sta parlando.
  final String? exerciseName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accents = AppAccents.of(context);
    final done = set.completed;

    // La riga corrente si distingue in tre modi insieme: fondo tenue, bordo
    // marcato e — nel testo semantico — la parola «adesso». Non basta il
    // colore.
    final background = done
        ? accents.positiveSurface
        : (isCurrent ? scheme.primaryContainer : scheme.surfaceContainerLow);
    final border = done
        ? accents.positive.withValues(alpha: 0.35)
        : (isCurrent ? scheme.primary : scheme.outline);

    return Semantics(
      container: true,
      label: [
        'Serie $setNumber',
        if (set.isWarmup) 'di riscaldamento',
        if (isCurrent && !done) '— tocca a questa adesso',
      ].join(' '),
      value: [
        describeWorkoutSet(set, trackingMode),
        if (set.rpe case final rpe?) 'sforzo $rpe su 10',
        if (done) 'fatta',
      ].join(', '),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: border,
            width: isCurrent && !done ? 1.6 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _SetBadge(
                  number: setNumber,
                  isWarmup: set.isWarmup,
                  done: done,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ExcludeSemantics(
                    child: Text(
                      set.isWarmup ? 'Riscaldamento' : 'Serie $setNumber',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: accents.mutedInk,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                RpeChip(
                  value: set.rpe,
                  onChanged: (value) => onChanged(
                    value == null
                        ? set.copyWith(clearRpe: true)
                        : set.copyWith(rpe: value),
                  ),
                ),
                const SizedBox(width: 8),
                _CompleteButton(
                  done: done,
                  isBusy: isBusy,
                  setNumber: setNumber,
                  onTap: onComplete,
                ),
              ],
            ),
            const SizedBox(height: 10),
            _SetFields(
              set: set,
              trackingMode: trackingMode,
              exerciseName: exerciseName,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }
}

class _SetBadge extends StatelessWidget {
  const _SetBadge({
    required this.number,
    required this.isWarmup,
    required this.done,
  });

  final int number;
  final bool isWarmup;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accents = AppAccents.of(context);
    return ExcludeSemantics(
      child: Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: done ? accents.positive : scheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: done ? accents.positive : scheme.outline),
        ),
        child: done
            ? Icon(Icons.check_rounded, size: 19, color: scheme.surface)
            : Text(
                isWarmup ? 'R' : '$number',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: scheme.onSurface,
                ),
              ),
      ),
    );
  }
}

class _CompleteButton extends StatelessWidget {
  const _CompleteButton({
    required this.done,
    required this.isBusy,
    required this.setNumber,
    required this.onTap,
  });

  final bool done;
  final bool isBusy;
  final int setNumber;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accents = AppAccents.of(context);
    final enabled = !isBusy;

    return Semantics(
      button: true,
      enabled: enabled,
      label: done
          ? 'Serie $setNumber fatta. Tocca per riaprirla.'
          : 'Segna la serie $setNumber come fatta',
      onTap: enabled ? onTap : null,
      child: ExcludeSemantics(
        child: Material(
          color: done ? accents.positive : scheme.primary,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            onTap: enabled ? onTap : null,
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              width: 48,
              height: 48,
              child: isBusy
                  ? Padding(
                      padding: const EdgeInsets.all(13),
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: scheme.onPrimary,
                      ),
                    )
                  : Icon(
                      done ? Icons.undo_rounded : Icons.check_rounded,
                      color: scheme.onPrimary,
                      size: 24,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// I campi che cambiano con la modalità. Sono in un `Wrap`: a caratteri
/// ingranditi vanno a capo invece di traboccare.
class _SetFields extends StatelessWidget {
  const _SetFields({
    required this.set,
    required this.trackingMode,
    required this.exerciseName,
    required this.onChanged,
  });

  final WorkoutSet set;
  final ExerciseTrackingMode trackingMode;
  final String? exerciseName;
  final ValueChanged<WorkoutSet> onChanged;

  static String _number(double value) => value == value.truncateToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(1);

  Future<void> _editWeight(BuildContext context) async {
    final value = await askExactNumber(
      context,
      title: 'Peso',
      unit: 'kg',
      initialValue: set.weightKg,
    );
    if (value == null) return;
    onChanged(set.copyWith(weightKg: value.clamp(0, 1000)));
  }

  Future<void> _editReps(BuildContext context) async {
    final value = await askExactNumber(
      context,
      title: 'Ripetizioni',
      unit: 'rip.',
      initialValue: set.reps?.toDouble(),
      decimal: false,
    );
    if (value == null) return;
    onChanged(set.copyWith(reps: value.round().clamp(0, 1000)));
  }

  Future<void> _editDistance(BuildContext context) async {
    final value = await askExactNumber(
      context,
      title: 'Distanza',
      unit: 'm',
      initialValue: set.distanceM,
    );
    if (value == null) return;
    onChanged(set.copyWith(distanceM: value.clamp(0, 200000)));
  }

  Future<void> _editDuration(BuildContext context) async {
    final value = await askExactNumber(
      context,
      title: 'Durata in secondi',
      unit: 's',
      initialValue: set.durationSec?.toDouble(),
      decimal: false,
    );
    if (value == null) return;
    onChanged(set.copyWith(durationSec: value.round().clamp(0, 3599)));
  }

  Widget _weightField(BuildContext context) => _LabeledField(
    label: 'kg',
    // Il calcola-dischi vive accanto al peso e non in un menu: è lì che
    // serve, con il bilanciere davanti.
    trailing: IconButton(
      key: const Key('set_open_plates'),
      onPressed: () {
        HapticFeedback.selectionClick();
        PlateCalculatorSheet.show(context, initialWeight: set.weightKg);
      },
      tooltip: exerciseName == null
          ? 'Calcola i dischi'
          : 'Calcola i dischi per $exerciseName',
      constraints: const BoxConstraints.tightFor(width: 48, height: 48),
      icon: const Icon(Icons.donut_large_rounded, size: 22),
    ),
    child: StepperField(
      fieldKey: const Key('set_weight_value'),
      semanticLabel: 'peso in chilogrammi',
      value: set.weightKg == null ? '' : _number(set.weightKg!),
      onMinus: () => onChanged(
        set.copyWith(weightKg: ((set.weightKg ?? 0) - 2.5).clamp(0, 1000)),
      ),
      onPlus: () => onChanged(
        set.copyWith(weightKg: ((set.weightKg ?? 0) + 2.5).clamp(0, 1000)),
      ),
      onTapValue: () => _editWeight(context),
    ),
  );

  Widget _repsField(BuildContext context) => _LabeledField(
    label: 'ripetizioni',
    child: StepperField(
      fieldKey: const Key('set_reps_value'),
      semanticLabel: 'ripetizioni',
      value: set.reps?.toString() ?? '',
      onMinus: () =>
          onChanged(set.copyWith(reps: ((set.reps ?? 0) - 1).clamp(0, 1000))),
      onPlus: () =>
          onChanged(set.copyWith(reps: ((set.reps ?? 0) + 1).clamp(0, 1000))),
      onTapValue: () => _editReps(context),
    ),
  );

  Widget _durationField(BuildContext context) => _LabeledField(
    label: 'durata',
    child: DurationStepper(
      fieldKey: const Key('set_duration_value'),
      seconds: set.durationSec,
      onChanged: (seconds) => onChanged(set.copyWith(durationSec: seconds)),
      onTapValue: () => _editDuration(context),
    ),
  );

  Widget _distanceField(BuildContext context) => _LabeledField(
    label: 'metri',
    child: StepperField(
      fieldKey: const Key('set_distance_value'),
      semanticLabel: 'distanza in metri',
      value: set.distanceM == null ? '' : _number(set.distanceM!),
      onMinus: () => onChanged(
        set.copyWith(distanceM: ((set.distanceM ?? 0) - 50).clamp(0, 200000)),
      ),
      onPlus: () => onChanged(
        set.copyWith(distanceM: ((set.distanceM ?? 0) + 50).clamp(0, 200000)),
      ),
      onTapValue: () => _editDistance(context),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final fields = switch (trackingMode) {
      ExerciseTrackingMode.weightReps => [
        _weightField(context),
        _repsField(context),
      ],
      ExerciseTrackingMode.bodyweightReps => [_repsField(context)],
      ExerciseTrackingMode.timeOnly => [_durationField(context)],
      ExerciseTrackingMode.timed => [
        _durationField(context),
        _weightField(context),
      ],
      ExerciseTrackingMode.distanceTime => [
        _durationField(context),
        _distanceField(context),
      ],
    };

    return Wrap(spacing: 12, runSpacing: 10, children: fields);
  }
}

class _LabeledField extends StatelessWidget {
  const _LabeledField({
    required this.label,
    required this.child,
    this.trailing,
  });

  final String label;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: accents.mutedInk,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        Row(mainAxisSize: MainAxisSize.min, children: [child, ?trailing]),
      ],
    );
  }
}
