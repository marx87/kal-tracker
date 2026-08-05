import 'package:flutter/material.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/goal/domain/goal.dart';
import 'package:kal_tracker/features/goal/domain/goal_feasibility.dart';
import 'package:kal_tracker/features/goal/domain/goal_plan.dart';
import 'package:kal_tracker/features/goal/presentation/goal_formats.dart';

/// Il traguardo, la fase, e quanto manca.
class GoalHeaderCard extends StatelessWidget {
  const GoalHeaderCard({
    required this.plan,
    required this.sevenDayAverageKg,
    required this.onChangeTarget,
    super.key,
  });

  final GoalPlan plan;
  final double? sevenDayAverageKg;
  final VoidCallback onChangeTarget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final date = plan.estimatedDate;

    return SectionCard(
      title: 'Il traguardo',
      icon: Icons.flag_rounded,
      actionLabel: 'Cambia',
      onAction: onChangeTarget,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  plan.goal.headline,
                  key: const Key('goal_headline'),
                  style: theme.textTheme.headlineSmall,
                ),
              ),
              const SizedBox(width: 10),
              _PhaseBadge(phase: plan.goal.phase),
            ],
          ),
          const SizedBox(height: 14),
          _ProgressBar(progress: plan.progress),
          const SizedBox(height: 6),
          StatRow(
            key: const Key('goal_current_weight'),
            label: 'Peso di oggi',
            value: GoalFormats.kg(plan.currentWeightKg),
            unit: 'kg',
            unitSemantics: 'chilogrammi',
            caption: sevenDayAverageKg == null
                ? null
                : 'media a 7 giorni ${GoalFormats.kg(sevenDayAverageKg!)} kg',
            icon: Icons.monitor_weight_outlined,
          ),
          StatRow(
            key: const Key('goal_fat_to_lose'),
            label: 'Grasso da perdere',
            value: GoalFormats.kg(plan.fatToLoseKg),
            unit: 'kg',
            unitSemantics: 'chilogrammi',
            caption: 'la massa magra resta dov\'è',
            icon: Icons.local_fire_department_rounded,
          ),
          StatRow(
            key: const Key('goal_estimated_date'),
            label: 'Arrivo stimato',
            value: date == null ? '—' : GoalFormats.date(date),
            caption: date == null
                ? 'non in questa fase'
                : 'tra ${GoalFormats.horizon(plan.remainingDays)}, al ritmo '
                      'di ${GoalFormats.kgPrecise(plan.goal.paceKgPerWeek)} kg '
                      'a settimana',
            icon: Icons.event_rounded,
          ),
          if (!plan.feasibility.isAchievable) ...[
            const SizedBox(height: 8),
            _FeasibilityNote(verdict: plan.feasibility, accents: accents),
          ],
        ],
      ),
    );
  }
}

/// Le tre fasi con le loro regole diverse, e dove si è adesso.
class GoalPhaseCard extends StatelessWidget {
  const GoalPhaseCard({required this.plan, super.key});

  final GoalPlan plan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final current = plan.goal.phase;

    return SectionCard(
      key: const Key('goal_phase_card'),
      title: 'Fase: ${current.label}',
      subtitle: current.rule,
      icon: Icons.route_rounded,
      child: Column(
        children: [
          for (final phase in GoalPhase.values)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Semantics(
                container: true,
                label: phase == current
                    ? '${phase.label}, fase attuale'
                    : phase.label,
                child: ExcludeSemantics(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        phase.index < current.index
                            ? Icons.check_circle_rounded
                            : phase == current
                            ? Icons.play_circle_fill_rounded
                            : Icons.circle_outlined,
                        size: 20,
                        color: phase.index <= current.index
                            ? theme.colorScheme.primary
                            : accents.mutedInk,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              // La fase attuale è scritta, non solo colorata:
                              // il pallino pieno da solo non basta.
                              phase == current
                                  ? '${phase.label} — adesso'
                                  : phase.label,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: phase == current
                                    ? FontWeight.w800
                                    : FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              phase.rule,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: accents.mutedInk,
                                height: 1.3,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Cosa comporta **oggi**: calorie, proteine, deficit, e da dove viene il
/// consumo su cui sono calcolati.
class GoalTargetsCard extends StatelessWidget {
  const GoalTargetsCard({
    required this.plan,
    required this.onChangePace,
    super.key,
  });

  final GoalPlan plan;
  final VoidCallback onChangePace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final targets = plan.targets;

    return SectionCard(
      key: const Key('goal_targets_card'),
      title: 'Cosa comporta oggi',
      icon: Icons.restaurant_rounded,
      actionLabel: 'Ritmo',
      onAction: onChangePace,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StatRow(
            key: const Key('goal_daily_calories'),
            label: 'Calorie',
            value: GoalFormats.round(targets.calories),
            unit: 'kcal',
            unitSemantics: 'chilocalorie',
            caption: plan.dailyDeficitKcal > 0
                ? '${GoalFormats.round(plan.tdee.kcal)} di consumo meno '
                      '${GoalFormats.round(plan.dailyDeficitKcal)} di deficit'
                : 'nessun deficit in questa fase',
            icon: Icons.local_dining_rounded,
          ),
          StatRow(
            key: const Key('goal_daily_protein'),
            label: 'Proteine',
            value: GoalFormats.round(targets.protein),
            unit: 'g',
            unitSemantics: 'grammi',
            caption:
                '${GoalPlanner.proteinGramsPerKgFatFreeMass.toStringAsFixed(0)}'
                ' g per kg di massa magra, non di peso',
            icon: Icons.egg_alt_rounded,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: Text(
              'Carboidrati ${GoalFormats.round(targets.carbs)} g · '
              'Grassi ${GoalFormats.round(targets.fat)} g',
              style: theme.textTheme.bodySmall?.copyWith(
                color: accents.mutedInk,
              ),
            ),
          ),
          if (targets.clampedToBasal)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: StatusChip(
                key: const Key('goal_basal_clamp'),
                level: AppStatusLevel.warning,
                label: 'Calorie tenute al metabolismo basale',
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              StatusChip(
                key: const Key('goal_tdee_source'),
                level: plan.tdee.isMeasured
                    ? AppStatusLevel.good
                    : AppStatusLevel.warning,
                label: 'Consumo ${plan.tdee.source.label.toLowerCase()}',
                compact: true,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  plan.tdee.explanation,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: accents.mutedInk,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Il mantenimento: una banda, non un numero.
class GoalBandCard extends StatelessWidget {
  const GoalBandCard({
    required this.band,
    required this.sevenDayAverageKg,
    super.key,
  });

  final MaintenanceBand band;
  final double? sevenDayAverageKg;

  @override
  Widget build(BuildContext context) {
    final average = sevenDayAverageKg;
    final status = average == null ? null : band.statusOf(average);

    return SectionCard(
      key: const Key('goal_band_card'),
      title: 'La banda',
      subtitle:
          'Dentro la banda non succede niente. Si riapre un ciclo solo se la '
          'media a 7 giorni resta fuori per due settimane di fila.',
      icon: Icons.horizontal_rule_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StatRow(
            key: const Key('goal_band_range'),
            label: 'Intervallo',
            value: band.label,
            icon: Icons.swap_vert_rounded,
          ),
          StatRow(
            key: const Key('goal_band_average'),
            label: 'Media a 7 giorni',
            value: average == null ? '—' : GoalFormats.kg(average),
            unit: average == null ? null : 'kg',
            unitSemantics: 'chilogrammi',
            icon: Icons.timeline_rounded,
            trailing: status == null
                ? null
                : StatusChip(
                    level: status == BandStatus.inside
                        ? AppStatusLevel.good
                        : AppStatusLevel.warning,
                    label: status.label,
                    compact: true,
                  ),
          ),
        ],
      ),
    );
  }
}

/// Gli obiettivi di prima. Cambiare idea non cancella il percorso.
class GoalHistoryCard extends StatelessWidget {
  const GoalHistoryCard({required this.past, super.key});

  final List<Goal> past;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return SectionCard(
      key: const Key('goal_history_card'),
      title: 'Prima di questo',
      subtitle: 'Il traguardo si è spostato, il percorso no.',
      icon: Icons.history_rounded,
      child: Column(
        children: [
          for (final goal in past.take(5))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      goal.headline,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    [
                      goal.outcome?.label,
                      if (goal.closedAt case final closedAt?)
                        GoalFormats.date(closedAt),
                    ].nonNulls.join(' · '),
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

/// La fase in una pastiglia. Non è uno [StatusChip] di proposito: una fase
/// non è un giudizio buono/attenzione/critico, è dove sei nel percorso.
class _PhaseBadge extends StatelessWidget {
  const _PhaseBadge({required this.phase});

  final GoalPhase phase;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: 'Fase ${phase.label.toLowerCase()}',
      child: ExcludeSemantics(
        child: Container(
          key: const Key('goal_phase_badge'),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            phase.label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final percent = (progress * 100).round();

    return Semantics(
      container: true,
      label: 'Percorso completato',
      value: '$percent per cento',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LinearProgressIndicator(
              key: const Key('goal_progress'),
              value: progress,
              minHeight: 10,
              borderRadius: BorderRadius.circular(10),
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 6),
            Text(
              '$percent% del percorso',
              style: theme.textTheme.labelMedium?.copyWith(
                color: AppAccents.of(context).mutedInk,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeasibilityNote extends StatelessWidget {
  const _FeasibilityNote({required this.verdict, required this.accents});

  final FeasibilityVerdict verdict;
  final AppAccents accents;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final level = verdict.kind == FeasibilityKind.needsMuscleLoss
        ? AppStatusLevel.critical
        : AppStatusLevel.warning;

    return DecoratedBox(
      key: const Key('goal_feasibility_note'),
      decoration: BoxDecoration(
        color: level.background(accents),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: level.foreground(accents).withValues(alpha: 0.35),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StatusChip(level: level, label: verdict.headline, compact: true),
            const SizedBox(height: 8),
            Text(
              verdict.explanation,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
            ),
          ],
        ),
      ),
    );
  }
}
