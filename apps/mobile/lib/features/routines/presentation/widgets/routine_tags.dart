import 'package:flutter/material.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';

/// Le tre proprietà che cambiano il modo di eseguire una scheda: è un
/// circuito, contiene superserie, contiene blocchi a tempo.
///
/// Non è uno [StatusChip]: quelle pastiglie dicono «va bene / attenzione /
/// intervieni», e qui non si giudica niente. Come loro, però, il significato
/// sta in tre posti insieme — parola, icona e colore — così regge anche
/// stampato in bianco e nero.
class RoutineTag extends StatelessWidget {
  /// Tutta la scheda si esegue a tempo.
  const RoutineTag.circuit({super.key}) : _kind = _TagKind.circuit, _count = 0;

  /// Quante coppie (o triplette) si alternano senza riposo in mezzo.
  const RoutineTag.superset(int count, {super.key})
    : _kind = _TagKind.superset,
      _count = count;

  /// Quante finestre a tempo stanno dentro il blocco principale.
  const RoutineTag.segments(int count, {super.key})
    : _kind = _TagKind.segments,
      _count = count;

  // Privati di proposito: il tipo che li descrive non deve uscire da questo
  // file, e l'etichetta si compone qui invece di arrivare da fuori — così due
  // schermate non possono scrivere «2 superset» e «2 superserie».
  final _TagKind _kind;
  final int _count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final (label, icon, foreground, background) = switch (_kind) {
      _TagKind.circuit => (
        'Circuito',
        Icons.bolt_rounded,
        accents.warning,
        accents.warningSurface,
      ),
      _TagKind.superset => (
        _count == 1 ? '1 superserie' : '$_count superserie',
        Icons.link_rounded,
        accents.info,
        accents.infoSurface,
      ),
      _TagKind.segments => (
        _count == 1 ? '1 blocco a tempo' : '$_count blocchi a tempo',
        Icons.timer_outlined,
        accents.positive,
        accents.positiveSurface,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: foreground.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: foreground),
          const SizedBox(width: 5),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

enum _TagKind { circuit, superset, segments }
