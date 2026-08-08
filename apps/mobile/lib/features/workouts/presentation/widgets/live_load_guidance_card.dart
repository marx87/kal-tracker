import 'package:flutter/material.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/workouts/domain/live_load_guidance.dart';
import 'package:kal_tracker/features/workouts/domain/personal_records.dart';

/// Suggerimento compatto sopra le serie dell'esercizio corrente.
///
/// La proposta non si applica mai da sola: un solo tocco la estende alle
/// serie rimaste, e [onUndo] permette di ripristinare immediatamente la copia
/// precedente tenuta dalla schermata live.
class LiveLoadGuidanceCard extends StatelessWidget {
  const LiveLoadGuidanceCard({
    required this.guidance,
    required this.onApply,
    this.onUndo,
    super.key,
  });

  final LiveLoadGuidance guidance;
  final VoidCallback? onApply;
  final VoidCallback? onUndo;

  String _target() {
    final parts = <String>[];
    if (guidance.proposedWeightKg case final kg?) {
      parts.add('${formatKg(kg)} kg');
    }
    if (guidance.proposedReps case final reps?) parts.add('$reps rip.');
    return parts.join(' × ');
  }

  String? _last() {
    final parts = <String>[];
    if (guidance.lastWeightKg case final kg?) {
      parts.add('${formatKg(kg)} kg');
    }
    if (guidance.lastReps case final reps?) parts.add('$reps rip.');
    if (guidance.lastRpe case final rpe?) parts.add('RPE $rpe');
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final target = _target();
    final last = _last();

    return Semantics(
      container: true,
      label: [
        guidance.isProgression ? 'Progressione proposta' : 'Carico suggerito',
        if (target.isNotEmpty) target,
        if (last != null) 'ultima seduta $last',
        guidance.reason,
      ].join('. '),
      child: Container(
        key: const Key('live_load_guidance'),
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: theme.colorScheme.secondary.withValues(alpha: 0.35),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              guidance.isProgression
                  ? Icons.trending_up_rounded
                  : Icons.history_rounded,
              color: theme.colorScheme.secondary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    guidance.isProgression
                        ? 'Proposta per oggi'
                        : 'Riparti dall’ultima seduta',
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (target.isNotEmpty)
                    Text(
                      target,
                      key: const Key('live_load_target'),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  if (last != null)
                    Text(
                      'Ultima: $last',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: accents.mutedInk,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (onUndo != null)
              IconButton.filledTonal(
                key: const Key('live_load_undo'),
                onPressed: onUndo,
                tooltip: 'Annulla proposta applicata',
                icon: const Icon(Icons.undo_rounded),
              )
            else
              FilledButton.tonal(
                key: const Key('live_load_apply'),
                onPressed: guidance.canApply ? onApply : null,
                child: const Text('Applica'),
              ),
          ],
        ),
      ),
    );
  }
}
