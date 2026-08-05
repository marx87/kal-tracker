import 'package:flutter/material.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/workouts/domain/circuit_flow.dart';

/// Il palco del circuito: il numerone, cosa stai facendo, cosa viene dopo, e i
/// due comandi grandi.
///
/// In Gym Tracker le fasi erano quattro gradienti pieni (`_gradientForPhase`)
/// che riempivano lo schermo di blu e arancione. Qui il fondo resta quello
/// dell'app e la fase si riconosce dal CONTENITORE dell'accento: primario
/// quando si lavora, «buono» quando si respira, secondario in preparazione.
/// Il nome della fase è comunque scritto a caratteri grandi — a due metri di
/// distanza, sudati, il colore non basta.
class CircuitStage extends StatelessWidget {
  const CircuitStage({
    required this.state,
    required this.onTogglePause,
    required this.onSkip,
    super.key,
  });

  final CircuitFlowState state;
  final VoidCallback onTogglePause;
  final VoidCallback onSkip;

  ({Color surface, Color ink}) _paint(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accents = AppAccents.of(context);
    return switch (state.phase) {
      CircuitPhase.work => (
        surface: scheme.primaryContainer,
        ink: scheme.onPrimaryContainer,
      ),
      CircuitPhase.shortRest || CircuitPhase.longRest => (
        surface: accents.positiveSurface,
        ink: accents.positive,
      ),
      CircuitPhase.prep => (
        surface: scheme.secondaryContainer,
        ink: scheme.onSecondaryContainer,
      ),
      CircuitPhase.paused => (
        surface: accents.warningSurface,
        ink: accents.warning,
      ),
      CircuitPhase.done => (
        surface: scheme.surfaceContainer,
        ink: scheme.onSurface,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final paint = _paint(context);
    final current = state.currentStep;
    final next = state.nextStep;
    final isWorking = state.phase == CircuitPhase.work;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Semantics(
            container: true,
            label: state.phase.label,
            value: [
              '${state.secondsLeft} secondi',
              if (isWorking && current != null) current.exerciseName,
              if (!isWorking && next != null) 'poi ${next.exerciseName}',
            ].join(', '),
            child: ExcludeSemantics(
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: paint.surface,
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(color: theme.colorScheme.outline),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      state.phase.label,
                      key: const Key('circuit_phase_label'),
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: paint.ink,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.4,
                      ),
                    ),
                    const SizedBox(height: 6),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '${state.secondsLeft}',
                        key: const Key('circuit_seconds'),
                        style:
                            (theme.textTheme.displayLarge ?? const TextStyle())
                                .copyWith(
                                  color: paint.ink,
                                  fontSize: 128,
                                  height: 1,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -4,
                                )
                                .tabular,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (isWorking && current != null)
                      _StepName(name: current.exerciseName, ink: paint.ink)
                    else if (next != null)
                      _StepName(
                        name: 'Poi: ${next.exerciseName}',
                        ink: paint.ink,
                      ),
                    if (current?.hint case final hint? when isWorking) ...[
                      const SizedBox(height: 8),
                      Text(
                        hint,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: paint.ink.withValues(alpha: 0.85),
                          height: 1.35,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: state.phaseProgress,
                        minHeight: 10,
                        backgroundColor: paint.ink.withValues(alpha: 0.18),
                        color: paint.ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: Text(
                state.progressLabel,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: accents.mutedInk,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              '${(state.progress * 100).round()}%',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(
                    color: accents.mutedInk,
                    fontWeight: FontWeight.w700,
                  )
                  .tabular,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('circuit_toggle_pause'),
                onPressed: onTogglePause,
                icon: Icon(
                  state.phase == CircuitPhase.paused
                      ? Icons.play_arrow_rounded
                      : Icons.pause_rounded,
                ),
                label: Text(
                  state.phase == CircuitPhase.paused ? 'Riprendi' : 'Pausa',
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                key: const Key('circuit_skip'),
                onPressed: state.phase == CircuitPhase.paused ? null : onSkip,
                icon: const Icon(Icons.skip_next_rounded),
                label: const Text('Salta'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _StepName extends StatelessWidget {
  const _StepName({required this.name, required this.ink});

  final String name;
  final Color ink;

  @override
  Widget build(BuildContext context) => Text(
    name,
    key: const Key('circuit_step_name'),
    textAlign: TextAlign.center,
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
    style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: ink),
  );
}
