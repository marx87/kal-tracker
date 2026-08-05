import 'package:flutter/material.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';

/// Cifre a larghezza fissa. Serve ovunque si incolonnino numeri che
/// cambiano (peso, kcal, serie): senza, «1» è più stretta di «8» e la
/// colonna balla a ogni aggiornamento.
extension TabularFigures on TextStyle {
  TextStyle get tabular =>
      copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
}

/// Riga statistica: etichetta a sinistra, valore grande e unità a destra.
///
/// È il mattone dei riepiloghi (peso, calorie, volume, riposo). Il valore
/// arriva già formattato — la formattazione è del dominio, non della UI —
/// e qui viene solo incolonnato.
class StatRow extends StatelessWidget {
  const StatRow({
    required this.label,
    required this.value,
    this.unit,
    this.unitSemantics,
    this.caption,
    this.icon,
    this.trailing,
    super.key,
  });

  /// Che cosa si misura: «Peso», «Calorie», «Volume».
  final String label;

  /// Il numero, già formattato in italiano dal chiamante.
  final String value;

  /// Unità breve mostrata a schermo: «kg», «kcal».
  final String? unit;

  /// Come si legge l'unità ad alta voce: «chilogrammi». Il lettore di
  /// schermo scandirebbe «kg» lettera per lettera.
  final String? unitSemantics;

  /// Nota sotto l'etichetta: confronto, data, contesto.
  final String? caption;

  final IconData? icon;

  /// Segnale a destra del valore, tipicamente uno [StatusChip].
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    // A caratteri molto ingranditi la riga non ci sta più in larghezza:
    // sopra 1.3× si impila invece di troncare il valore.
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final stacked = scale > 1.3;

    // Etichetta e valore sono già riassunti nel nodo semantico della riga:
    // esclusi qui, il lettore di schermo non li ripete una seconda volta.
    // Fuori dall'esclusione resta solo [trailing], che porta un'informazione
    // sua (per esempio lo stato).
    final labelBlock = ExcludeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: accents.mutedInk,
            ),
          ),
          if (caption case final caption?) ...[
            const SizedBox(height: 2),
            Text(
              caption,
              style: theme.textTheme.bodySmall?.copyWith(
                color: accents.mutedInk,
                height: 1.3,
              ),
            ),
          ],
        ],
      ),
    );

    final valueStyle = (theme.textTheme.headlineSmall ?? const TextStyle())
        .copyWith(
          color: theme.colorScheme.onSurface,
          fontWeight: FontWeight.w900,
        )
        .tabular;

    final valueBlock = ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: valueStyle,
            ),
          ),
          if (unit case final unit?) ...[
            const SizedBox(width: 4),
            Text(
              unit,
              style: theme.textTheme.titleSmall?.copyWith(
                color: accents.mutedInk,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );

    final spokenUnit = unitSemantics ?? unit;
    final body = stacked
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (icon case final icon?) ...[
                    _StatIcon(icon: icon),
                    const SizedBox(width: 10),
                  ],
                  Expanded(child: labelBlock),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(child: valueBlock),
                  ?trailing,
                ],
              ),
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (icon case final icon?) ...[
                _StatIcon(icon: icon),
                const SizedBox(width: 12),
              ],
              Expanded(child: labelBlock),
              const SizedBox(width: 12),
              valueBlock,
              if (trailing case final trailing?) ...[
                const SizedBox(width: 10),
                trailing,
              ],
            ],
          );

    return Semantics(
      container: true,
      label: label,
      value: [value, spokenUnit].nonNulls.join(' '),
      hint: caption,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: body,
      ),
    );
  }
}

class _StatIcon extends StatelessWidget {
  const _StatIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(13),
        ),
        child: Icon(icon, size: 19, color: scheme.onPrimaryContainer),
      ),
    );
  }
}
