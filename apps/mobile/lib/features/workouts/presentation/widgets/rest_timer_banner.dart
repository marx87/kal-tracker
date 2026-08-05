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

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (!controller.isVisible) return const SizedBox.shrink();
        return controller.isCompleted
            ? _RestDoneBar(onDismiss: controller.cancel)
            : _RestRunningBar(
                controller: controller,
                contextLabel: contextLabel,
                nextLabel: nextLabel,
                guided: guided,
                onStop: onStop,
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
  });

  final RestTimerController controller;
  final String? contextLabel;
  final String? nextLabel;
  final bool guided;
  final VoidCallback? onStop;

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
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
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
                        child: Text(
                          'RECUPERO',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: scheme.onPrimaryContainer,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      key: const Key('rest_timer_close'),
                      onPressed: guided && onStop != null
                          ? onStop
                          : controller.cancel,
                      tooltip: guided
                          ? 'Ferma la superserie guidata'
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
                ExcludeSemantics(
                  child: Text(
                    '$seconds',
                    key: const Key('rest_timer_seconds'),
                    style: theme.textTheme.displayLarge
                        ?.copyWith(
                          color: scheme.onPrimaryContainer,
                          fontWeight: FontWeight.w900,
                          height: 1,
                          letterSpacing: -2,
                        )
                        .tabular,
                  ),
                ),
                if (contextLabel != null || nextLabel != null) ...[
                  const SizedBox(height: 4),
                  ExcludeSemantics(
                    child: Text(
                      [
                        ?contextLabel,
                        if (nextLabel case final next?) 'Poi: $next',
                      ].join(' · '),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onPrimaryContainer,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: elapsed.clamp(0.0, 1.0),
                    minHeight: 8,
                    backgroundColor: scheme.onPrimaryContainer.withValues(
                      alpha: 0.2,
                    ),
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _RestAction(
                      label: '−15s',
                      semanticLabel: 'Togli 15 secondi al recupero',
                      onTap: () => controller.addSeconds(-15),
                    ),
                    _RestAction(
                      key: const Key('rest_timer_skip'),
                      label: 'Riparti ora',
                      semanticLabel: 'Salta il recupero e riparti',
                      onTap: () {
                        controller.skip();
                        // Nel flusso guidato la callback fa già partire il
                        // lavoro dopo (e azzera il controller). In quello
                        // manuale la fascia «finito» resterebbe lì a coprire
                        // il pulsante della serie: qui si chiude subito.
                        if (controller.isCompleted) controller.cancel();
                      },
                    ),
                    _RestAction(
                      label: '+15s',
                      semanticLabel: 'Aggiungi 15 secondi al recupero',
                      onTap: () => controller.addSeconds(15),
                    ),
                    if (guided && onStop != null)
                      _RestAction(
                        label: 'Ferma la superserie',
                        semanticLabel: 'Ferma la superserie guidata',
                        onTap: onStop!,
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
    super.key,
  });

  final String label;
  final String semanticLabel;
  final VoidCallback onTap;

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
              color: scheme.surface.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: scheme.onPrimaryContainer.withValues(alpha: 0.35),
              ),
            ),
            child: Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
