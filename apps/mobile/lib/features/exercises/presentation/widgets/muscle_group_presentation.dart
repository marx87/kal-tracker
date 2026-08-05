import 'package:flutter/material.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/exercises/domain/exercise_models.dart';

/// Come si veste un gruppo muscolare: un'icona e una coppia di colori.
///
/// Sta in un posto solo perché la stessa pastiglia compare nel catalogo,
/// nell'editor delle schede e nel selettore: se ognuno scegliesse la sua,
/// «Cardio» sarebbe di tre colori diversi nella stessa app. I colori arrivano
/// sempre dal tema (`colorScheme` o `AppAccents`), mai da costanti: al buio
/// devono cambiare da soli.
@immutable
class MuscleGroupStyle {
  const MuscleGroupStyle({
    required this.icon,
    required this.foreground,
    required this.background,
  });

  final IconData icon;
  final Color foreground;
  final Color background;

  static MuscleGroupStyle of(BuildContext context, MuscleGroup group) {
    final scheme = Theme.of(context).colorScheme;
    final accents = AppAccents.of(context);
    return switch (group) {
      MuscleGroup.cardio => MuscleGroupStyle(
        icon: Icons.directions_run_rounded,
        foreground: accents.critical,
        background: accents.criticalSurface,
      ),
      MuscleGroup.fullbody => MuscleGroupStyle(
        icon: Icons.accessibility_new_rounded,
        foreground: accents.warning,
        background: accents.warningSurface,
      ),
      MuscleGroup.mobilita => MuscleGroupStyle(
        icon: Icons.self_improvement_rounded,
        foreground: accents.info,
        background: accents.infoSurface,
      ),
      MuscleGroup.altro => MuscleGroupStyle(
        icon: Icons.category_rounded,
        foreground: accents.mutedInk,
        background: scheme.surfaceContainerHighest,
      ),
      _ => MuscleGroupStyle(
        icon: _icon(group),
        foreground: scheme.onPrimaryContainer,
        background: scheme.primaryContainer,
      ),
    };
  }

  /// Icone diverse per gruppi diversi: il colore da solo non basta a
  /// distinguerli, e nel catalogo la miniatura è spesso l'unico segnale.
  static IconData _icon(MuscleGroup group) => switch (group) {
    MuscleGroup.petto => Icons.fitness_center_rounded,
    MuscleGroup.schiena => Icons.rowing_rounded,
    MuscleGroup.spalle => Icons.sports_handball_rounded,
    MuscleGroup.bicipiti => Icons.sports_mma_rounded,
    MuscleGroup.tricipiti => Icons.sports_kabaddi_rounded,
    MuscleGroup.gambe => Icons.directions_walk_rounded,
    MuscleGroup.polpacci => Icons.stairs_rounded,
    MuscleGroup.addome => Icons.grid_view_rounded,
    MuscleGroup.cardio => Icons.directions_run_rounded,
    MuscleGroup.fullbody => Icons.accessibility_new_rounded,
    MuscleGroup.mobilita => Icons.self_improvement_rounded,
    MuscleGroup.altro => Icons.category_rounded,
  };
}

/// La miniatura quadrata di un esercizio: l'icona del suo gruppo nel riquadro
/// tenue del gruppo stesso.
///
/// Non carica immagini di rete: l'app è local-first e una foto che non arriva
/// lascerebbe un buco grigio in mezzo alla lista. L'eventuale `imageUrl`
/// dell'esercizio si vede nella scheda di dettaglio, dove c'è spazio per un
/// messaggio se non si carica.
class MuscleGroupBadge extends StatelessWidget {
  const MuscleGroupBadge({required this.group, this.size = 52, super.key});

  final MuscleGroup group;
  final double size;

  @override
  Widget build(BuildContext context) {
    final style = MuscleGroupStyle.of(context, group);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: style.background,
          borderRadius: BorderRadius.circular(size / 3),
        ),
        child: Icon(style.icon, color: style.foreground, size: size * 0.46),
      ),
    );
  }
}

/// Pastiglia con il nome del gruppo muscolare. Parola + icona + colore: il
/// significato regge anche stampato in bianco e nero.
class MuscleGroupChip extends StatelessWidget {
  const MuscleGroupChip({required this.group, super.key});

  final MuscleGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = MuscleGroupStyle.of(context, group);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: style.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: style.foreground.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(style.icon, size: 15, color: style.foreground),
          const SizedBox(width: 5),
          Text(
            group.label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: style.foreground,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
