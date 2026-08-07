import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/workouts/domain/session_effort.dart';

/// L'ultima domanda della sessione, e l'unica obbligatoria.
///
/// Non è dismissibile — né toccando fuori, né trascinando, né col gesto
/// «indietro» — perché saltarla è esattamente il difetto che questo foglio
/// esiste per chiudere: quando la risposta era facoltativa arrivava in 17
/// sessioni su 29.
///
/// «Obbligatoria» finisce qui, però: non c'è nessuna risposta preselezionata e
/// nessuna scorciatoia che decida al posto di Marco. L'app propone i tre
/// bersagli, Marco ne tocca uno.
///
/// Torna `null` solo se il foglio viene smontato dal sistema. Chi chiama in
/// quel caso NON deve chiudere la sessione: senza risposta si resta aperti,
/// che è dove il lavoro è comunque al sicuro.
Future<SessionEffort?> askSessionEffort(BuildContext context) {
  return showModalBottomSheet<SessionEffort>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    // Tre bersagli grossi non stanno nei 9/16 di schermo del foglio normale, e
    // con i caratteri ingranditi il taglio cadrebbe proprio sull'ultimo: qui
    // il foglio si prende l'altezza che serve, e se non basta si scorre.
    isScrollControlled: true,
    builder: (sheetContext) => const _SessionEffortSheet(),
  );
}

class _SessionEffortSheet extends StatelessWidget {
  const _SessionEffortSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return PopScope(
      // `isDismissible: false` ferma il tocco fuori, non il gesto indietro di
      // Android: senza questo, il foglio si chiuderebbe proprio col gesto che
      // in palestra parte da solo.
      canPop: false,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(
                  'Com\'è andata?',
                  style: theme.textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Una risposta e chiudo. È quella che accende il semaforo del '
                'sovrallenamento: senza, resta spento — e spento non vuol dire '
                'che va tutto bene, vuol dire che non lo so.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: accents.mutedInk,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 18),
              for (final effort in SessionEffort.values) ...[
                _EffortTarget(effort: effort),
                if (effort != SessionEffort.values.last)
                  const SizedBox(height: 12),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Un bersaglio: largo quanto il foglio, alto abbastanza da prenderlo senza
/// guardare.
class _EffortTarget extends StatelessWidget {
  const _EffortTarget({required this.effort});

  final SessionEffort effort;

  /// La stessa rampa dell'RPE — verde, giallo, corallo — presa dagli accenti
  /// semantici e non da colori letterali, così al buio segue il tema. Qui è
  /// intensità, non giudizio: nessuno dei tre è la risposta giusta.
  Color _color(BuildContext context) {
    final accents = AppAccents.of(context);
    return switch (effort) {
      SessionEffort.facile => accents.positive,
      SessionEffort.giusta => accents.warning,
      SessionEffort.dura => accents.critical,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final color = _color(context);

    void choose() {
      HapticFeedback.selectionClick();
      Navigator.of(context).pop(effort);
    }

    return Semantics(
      button: true,
      label: effort.spoken,
      onTap: choose,
      child: ExcludeSemantics(
        child: InkWell(
          key: Key('session_effort_${effort.name}'),
          onTap: choose,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            constraints: const BoxConstraints(minHeight: 76),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color.withValues(alpha: 0.65)),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  effort.label,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: color,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  effort.hint,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: accents.mutedInk,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
