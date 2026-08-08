import 'package:flutter/material.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/training_profile/domain/exercise_screening.dart';
import 'package:kal_tracker/features/training_profile/domain/training_profile.dart';

/// Come il catalogo veste un esito dello screening.
///
/// Sta in un posto solo perché la stessa pastiglia e la stessa frase compaiono
/// nella lista e nella scheda di dettaglio: se le due divergessero, «escluso»
/// finirebbe per voler dire due cose diverse nella stessa app.
extension ScreeningOutcomeStyle on ScreeningOutcome {
  /// I tre livelli del design system dicono già quel che serve: verde va bene,
  /// giallo tienilo d'occhio, rosso oggi no.
  AppStatusLevel get level => switch (this) {
    ScreeningOutcome.libero => AppStatusLevel.good,
    ScreeningOutcome.segnalato => AppStatusLevel.warning,
    ScreeningOutcome.escluso => AppStatusLevel.critical,
  };

  /// Le parole del dominio, non dei sinonimi: lo screening, la lista e la
  /// scheda devono chiamare la stessa cosa allo stesso modo.
  String get label => switch (this) {
    ScreeningOutcome.libero => 'Libero',
    ScreeningOutcome.segnalato => 'Segnalato',
    ScreeningOutcome.escluso => 'Escluso',
  };
}

/// La pastiglia con l'esito.
class ExerciseScreeningTag extends StatelessWidget {
  const ExerciseScreeningTag({
    required this.outcome,
    this.compact = true,
    super.key,
  });

  final ScreeningOutcome outcome;
  final bool compact;

  @override
  Widget build(BuildContext context) =>
      StatusChip(level: outcome.level, label: outcome.label, compact: compact);
}

/// **Perché**, e cosa fare al posto suo.
///
/// L'alternativa non è un di più: segnalare senza dire come aggirare
/// l'ostacolo rimanderebbe a Marco lo stesso lavoro che il profilo esiste per
/// togliergli. Sotto un esito senza ragione — cioè [ScreeningOutcome.libero] —
/// non c'è niente da scrivere, e infatti non si scrive niente.
class ExerciseScreeningNote extends StatelessWidget {
  const ExerciseScreeningNote({
    required this.screening,
    this.compact = false,
    super.key,
  });

  final ExerciseScreening screening;

  /// Nella lista la ragione si tronca: lì serve a capire *che* qualcosa c'è,
  /// per esteso si legge nella scheda.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final reason = screening.reason;
    if (reason == null) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final foreground = screening.outcome.level.foreground(accents);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          reason,
          maxLines: compact ? 3 : null,
          overflow: compact ? TextOverflow.ellipsis : null,
          style: theme.textTheme.bodySmall?.copyWith(
            color: foreground,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (screening.alternative case final alternative?) ...[
          const SizedBox(height: 3),
          Text(
            'Al posto suo: $alternative',
            maxLines: compact ? 2 : null,
            overflow: compact ? TextOverflow.ellipsis : null,
            style: theme.textTheme.bodySmall?.copyWith(color: accents.mutedInk),
          ),
        ],
      ],
    );
  }
}

/// L'elenco di quel che ha deciso l'esito: le limitazioni toccate e gli
/// attrezzi che mancano.
///
/// **Ci sono tutte**, anche quelle che non hanno deciso: quando a escludere è
/// l'attrezzatura, la spalla che intanto faceva male non sparisce dietro
/// quella ragione — comprare il manubrio non la fa passare.
class ExerciseScreeningCauses extends StatelessWidget {
  const ExerciseScreeningCauses({required this.screening, super.key});

  final ExerciseScreening screening;

  @override
  Widget build(BuildContext context) {
    final limitations = screening.limitations;
    final missing = screening.missingEquipment;
    if (limitations.isEmpty && missing.isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (limitations.isNotEmpty) ...[
          Text(
            limitations.length == 1
                ? 'La limitazione che lo tocca'
                : 'Le limitazioni che lo toccano',
            style: theme.textTheme.labelLarge?.copyWith(
              color: accents.mutedInk,
            ),
          ),
          const SizedBox(height: 6),
          for (final limitation in limitations)
            _CauseRow(
              key: Key('screening_limitation_${limitation.id}'),
              icon: Icons.healing_rounded,
              color: _severityColor(limitation.severity, accents),
              title:
                  '${limitation.bodyPart.label} · '
                  '${limitation.severity.label.toLowerCase()}',
              // La nota è con le parole di Marco: è quella che gli ricorda di
              // cosa si trattava, tre settimane dopo averla scritta.
              subtitle: limitation.note,
            ),
        ],
        if (missing.isNotEmpty) ...[
          if (limitations.isNotEmpty) const SizedBox(height: 12),
          Text(
            missing.length == 1 ? 'Cosa manca' : 'Cosa manca in casa',
            style: theme.textTheme.labelLarge?.copyWith(
              color: accents.mutedInk,
            ),
          ),
          const SizedBox(height: 6),
          for (final requirement in missing)
            _CauseRow(
              icon: Icons.inventory_2_outlined,
              color: accents.critical,
              title: requirement.label,
              subtitle: requirement.options.isEmpty
                  // Un requisito senza alternative non è un attrezzo da
                  // comprare: è la palestra. Dirlo evita che Marco vada a
                  // cercarlo nell'elenco delle sue cose.
                  ? 'Non è roba da appartamento: serve una palestra.'
                  : null,
            ),
        ],
      ],
    );
  }

  static Color _severityColor(
    LimitationSeverity severity,
    AppAccents accents,
  ) => switch (severity) {
    LimitationSeverity.fastidio => accents.warning,
    LimitationSeverity.dolore => accents.critical,
    LimitationSeverity.stop => accents.critical,
  };
}

class _CauseRow extends StatelessWidget {
  const _CauseRow({
    required this.icon,
    required this.color,
    required this.title,
    this.subtitle,
    super.key,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.bodyMedium),
                if (subtitle case final subtitle?)
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: accents.mutedInk,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
