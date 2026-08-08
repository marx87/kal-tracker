import 'package:flutter/material.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/workouts/domain/rest_timer_controller.dart';

/// La fascia del recupero, in fondo alla sessione.
///
/// In Gym Tracker era blu (`0xFF1565C0`) e diventava verde a fine recupero:
/// due colori letterali che al buio restano accesi come una torcia. Qui il
/// recupero in corso usa il contenitore primario del tema e quello finito
/// l'accento «buono», quindi cambia da solo fra giorno e notte.
///
/// La differenza fra «sto riposando» e «puoi ripartire» NON è affidata al
/// colore: cambiano il testo, l'icona e — a fine recupero — la fascia diventa
/// toccabile per intero.
class RestTimerBanner extends StatelessWidget {
  const RestTimerBanner({
    required this.controller,
    this.contextLabel,
    this.nextLabel,
    this.guided = false,
    this.onStop,
    this.onSkip,
    this.onDismiss,
    this.onAdjusted,
    super.key,
  });

  final RestTimerController controller;

  /// Da dove viene questo recupero: «Panca piana · serie 2».
  final String? contextLabel;

  /// Cosa arriva dopo: si legge senza guardare, mentre si respira.
  final String? nextLabel;

  /// Vero durante una superserie guidata: là chiudere il timer non basta,
  /// bisogna poter fermare tutta la sequenza.
  final bool guided;
  final VoidCallback? onStop;

  /// Hook della regia persistente. Se mancano, il banner continua a
  /// funzionare da solo come prima (utile nei test e negli usi semplici).
  final VoidCallback? onSkip;
  final VoidCallback? onDismiss;
  final ValueChanged<Duration>? onAdjusted;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (!controller.isVisible) return const SizedBox.shrink();
        return controller.isCompleted
            ? _RestDoneBar(onDismiss: onDismiss ?? controller.cancel)
            : _RestRunningBar(
                controller: controller,
                contextLabel: contextLabel,
                nextLabel: nextLabel,
                guided: guided,
                onStop: onStop,
                onSkip: onSkip,
                onDismiss: onDismiss,
                onAdjusted: onAdjusted,
              );
      },
    );
  }
}

class _RestDoneBar extends StatelessWidget {
  const _RestDoneBar({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return Semantics(
      container: true,
      liveRegion: true,
      button: true,
      label: 'Recupero finito. Tocca per chiudere e ripartire.',
      onTap: onDismiss,
      child: ExcludeSemantics(
        child: SafeArea(
          top: false,
          child: Material(
            color: accents.positiveSurface,
            child: InkWell(
              onTap: onDismiss,
              child: Container(
                constraints: const BoxConstraints(minHeight: 56),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 14,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.check_circle_rounded,
                      color: accents.positive,
                      size: 22,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        'Recupero finito — tocca e riparti',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: accents.positive,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RestRunningBar extends StatelessWidget {
  const _RestRunningBar({
    required this.controller,
    required this.contextLabel,
    required this.nextLabel,
    required this.guided,
    required this.onStop,
    required this.onSkip,
    required this.onDismiss,
    required this.onAdjusted,
  });

  final RestTimerController controller;
  final String? contextLabel;
  final String? nextLabel;
  final bool guided;
  final VoidCallback? onStop;
  final VoidCallback? onSkip;
  final VoidCallback? onDismiss;
  final ValueChanged<Duration>? onAdjusted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final seconds = controller.remaining.inSeconds;
    final total = controller.total.inMilliseconds;
    final elapsed = total == 0
        ? 0.0
        : 1 - controller.remaining.inMilliseconds / total;

    return Semantics(
      container: true,
      // `liveRegion` no: il lettore di schermo rileggerebbe la fascia a ogni
      // secondo e coprirebbe tutto il resto. Il numero si va a leggere.
      label:
          'Recupero, $seconds ${seconds == 1 ? 'secondo' : 'secondi'} '
          'rimasti.${nextLabel == null ? '' : ' Poi: $nextLabel.'}',
      child: SafeArea(
        top: false,
        child: Material(
          color: scheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.hourglass_bottom_rounded,
                      size: 18,
                      color: scheme.onPrimaryContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ExcludeSemantics(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'RECUPERO',
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: scheme.onPrimaryContainer,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 1,
                              ),
                            ),
                            if (contextLabel != null || nextLabel != null)
                              Text(
                                [
                                  ?contextLabel,
                                  if (nextLabel case final next?) 'Poi: $next',
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onPrimaryContainer,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ExcludeSemantics(
                      child: Text(
                        '$seconds',
                        key: const Key('rest_timer_seconds'),
                        style: theme.textTheme.headlineMedium
                            ?.copyWith(
                              color: scheme.onPrimaryContainer,
                              fontWeight: FontWeight.w900,
                              height: 1,
                            )
                            .tabular,
                      ),
                    ),
                    Text(
                      's',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onPrimaryContainer,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    IconButton(
                      key: const Key('rest_timer_close'),
                      onPressed: guided && onStop != null
                          ? onStop
                          : (onDismiss ?? controller.cancel),
                      tooltip: guided
                          ? 'Ferma la sequenza guidata'
                          : 'Chiudi il recupero',
                      constraints: const BoxConstraints.tightFor(
                        width: 48,
                        height: 48,
                      ),
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        Icons.close_rounded,
                        size: 22,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: elapsed.clamp(0.0, 1.0),
                    minHeight: 5,
                    backgroundColor: scheme.onPrimaryContainer.withValues(
                      alpha: 0.2,
                    ),
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _RestAction(
                      label: '−15',
                      semanticLabel: 'Togli 15 secondi al recupero',
                      onTap: () {
                        controller.addSeconds(-15);
                        onAdjusted?.call(controller.remaining);
                      },
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _RestAction(
                        key: const Key('rest_timer_skip'),
                        label: 'Riparti ora',
                        semanticLabel: 'Salta il recupero e riparti',
                        primary: true,
                        onTap: () {
                          if (onSkip != null) {
                            onSkip!();
                            return;
                          }
                          controller.skip();
                          // Nel flusso guidato la callback fa già partire il
                          // lavoro dopo. Nel flusso manuale si chiude subito.
                          if (controller.isCompleted) controller.cancel();
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    _RestAction(
                      label: '+15',
                      semanticLabel: 'Aggiungi 15 secondi al recupero',
                      onTap: () {
                        controller.addSeconds(15);
                        onAdjusted?.call(controller.remaining);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RestAction extends StatelessWidget {
  const _RestAction({
    required this.label,
    required this.semanticLabel,
    required this.onTap,
    this.primary = false,
    super.key,
  });

  final String label;
  final String semanticLabel;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      button: true,
      label: semanticLabel,
      onTap: onTap,
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: primary
                  ? scheme.primary
                  : scheme.surface.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: primary
                    ? scheme.primary
                    : scheme.onPrimaryContainer.withValues(alpha: 0.35),
              ),
            ),
            child: Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: primary ? scheme.onPrimary : scheme.onPrimaryContainer,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
