import 'package:flutter/material.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';

/// I tre livelli con cui l'app giudica un dato: va bene, tienilo d'occhio,
/// intervieni.
enum AppStatusLevel {
  good,
  warning,
  critical;

  /// Etichetta predefinita, in italiano.
  String get defaultLabel => switch (this) {
    AppStatusLevel.good => 'Buono',
    AppStatusLevel.warning => 'Attenzione',
    AppStatusLevel.critical => 'Critico',
  };

  /// Forme diverse, non solo colori diversi: cerchio spuntato, triangolo,
  /// ottagono. Si distinguono anche in bianco e nero e con una discromatopsia.
  IconData get icon => switch (this) {
    AppStatusLevel.good => Icons.check_circle_rounded,
    AppStatusLevel.warning => Icons.warning_amber_rounded,
    AppStatusLevel.critical => Icons.dangerous_rounded,
  };

  Color foreground(AppAccents accents) => switch (this) {
    AppStatusLevel.good => accents.positive,
    AppStatusLevel.warning => accents.warning,
    AppStatusLevel.critical => accents.critical,
  };

  Color background(AppAccents accents) => switch (this) {
    AppStatusLevel.good => accents.positiveSurface,
    AppStatusLevel.warning => accents.warningSurface,
    AppStatusLevel.critical => accents.criticalSurface,
  };
}

/// Pastiglia di stato. Il significato sta in tre posti insieme — la parola,
/// la forma dell'icona e il colore — così regge anche quando il colore non
/// arriva: stampa in bianco e nero, daltonismo, schermo al sole.
///
/// Non è interattiva: è un'etichetta, quindi non deve rispettare il bersaglio
/// da 48. Se serve un'azione, mettila accanto, non dentro.
class StatusChip extends StatelessWidget {
  const StatusChip({
    required this.level,
    this.label,
    this.compact = false,
    super.key,
  });

  final AppStatusLevel level;

  /// Testo mostrato al posto dell'etichetta predefinita: «3 giorni fa»,
  /// «Sopra soglia». Resta comunque accompagnato dall'icona del livello.
  final String? label;

  /// Versione stretta per stare in fondo a una riga già piena.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final foreground = level.foreground(accents);
    final text = label ?? level.defaultLabel;

    return Semantics(
      container: true,
      // Il livello viene detto per esteso: chi ascolta non vede né forma né
      // colore, e «Attenzione» da solo non direbbe che è uno stato.
      label: 'Stato ${level.defaultLabel.toLowerCase()}: $text',
      child: ExcludeSemantics(
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 10,
            vertical: compact ? 4 : 6,
          ),
          decoration: BoxDecoration(
            color: level.background(accents),
            borderRadius: BorderRadius.circular(compact ? 10 : 12),
            border: Border.all(color: foreground.withValues(alpha: 0.35)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(level.icon, size: compact ? 14 : 16, color: foreground),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      (compact
                              ? theme.textTheme.labelSmall
                              : theme.textTheme.labelMedium)
                          ?.copyWith(
                            color: foreground,
                            fontWeight: FontWeight.w800,
                          ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
