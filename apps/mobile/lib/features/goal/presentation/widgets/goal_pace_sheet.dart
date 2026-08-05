import 'package:flutter/material.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/goal/domain/goal_pace.dart';
import 'package:kal_tracker/features/goal/presentation/goal_formats.dart';

/// **Il ritmo, sempre modificabile.**
///
/// Non è una scelta iniziale irreversibile: si apre, si trascina, e deficit e
/// data stimata si ricalcolano. L'obiettivo non si tocca.
///
/// Il cursore arriva volutamente **oltre** il limite di sicurezza: è l'unico
/// modo perché il rifiuto esista davvero. Superato lo 0,7 % del peso a
/// settimana il salvataggio si chiude, compare la spiegazione e la
/// controproposta è a un tocco.
class GoalPaceSheet extends StatefulWidget {
  const GoalPaceSheet({
    required this.currentWeightKg,
    required this.fatToLoseKg,
    required this.paceKgPerWeek,
    super.key,
  });

  final double currentWeightKg;

  /// Serve solo a mostrare quanto ci vuole: zero quando non c'è più grasso
  /// da perdere, e allora la stima sparisce invece di dire «0 giorni».
  final double fatToLoseKg;

  final double paceKgPerWeek;

  @override
  State<GoalPaceSheet> createState() => _GoalPaceSheetState();
}

class _GoalPaceSheetState extends State<GoalPaceSheet> {
  /// Cinquanta grammi a settimana: sotto questo passo la manopola darebbe
  /// una precisione che la bilancia non ha.
  static const double _stepKg = 0.05;

  late double _paceKgPerWeek;

  double get _safeMaximum =>
      GoalPace.safeMaximumKgPerWeek(widget.currentWeightKg);

  /// Il fondo scala sta oltre il limite: si deve poter chiedere troppo.
  double get _dialMaximum => _snap(_safeMaximum * 1.6);

  @override
  void initState() {
    super.initState();
    _paceKgPerWeek = _snap(
      widget.paceKgPerWeek.clamp(GoalPace.minimumKgPerWeek, _dialMaximum),
    );
  }

  double _snap(double value) => (value / _stepKg).round() * _stepKg;

  /// Il gradino subito **sotto** un valore. Serve alla controproposta: il
  /// massimo sicuro cade quasi sempre tra due tacche, e arrotondando per
  /// eccesso il pulsante che dovrebbe rientrare nel limite lo supererebbe.
  double _snapDown(double value) => ((value / _stepKg).floor() * _stepKg).clamp(
    GoalPace.minimumKgPerWeek,
    _dialMaximum,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final verdict = GoalPace.assess(
      currentWeightKg: widget.currentWeightKg,
      requestedKgPerWeek: _paceKgPerWeek,
    );
    final named = PaceChoice.nearest(
      currentWeightKg: widget.currentWeightKg,
      kgPerWeek: _paceKgPerWeek,
    );
    final days = GoalPace.daysToLose(
      fatToLoseKg: widget.fatToLoseKg,
      kgPerWeek: verdict.appliedKgPerWeek,
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              header: true,
              child: Text(
                'Con che ritmo',
                style: theme.textTheme.headlineSmall,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Cambialo quando vuoi: si ricalcolano deficit e data stimata, '
              'il traguardo resta dov\'è.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: accents.mutedInk,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 18),
            Semantics(
              container: true,
              label: 'Ritmo scelto',
              value:
                  '${GoalFormats.kgPrecise(_paceKgPerWeek)} chilogrammi a '
                  'settimana, ${named.label.toLowerCase()}',
              child: ExcludeSemantics(
                child: Column(
                  children: [
                    Text(
                      '${GoalFormats.kgPrecise(_paceKgPerWeek)} kg',
                      key: const Key('pace_value'),
                      style: theme.textTheme.headlineLarge?.tabular,
                    ),
                    Text(
                      'a settimana',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: accents.mutedInk,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      named.label,
                      key: const Key('pace_label'),
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    Text(
                      named.description,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: accents.mutedInk,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Slider(
              key: const Key('pace_dial'),
              value: _paceKgPerWeek.clamp(
                GoalPace.minimumKgPerWeek,
                _dialMaximum,
              ),
              min: GoalPace.minimumKgPerWeek,
              max: _dialMaximum,
              divisions: ((_dialMaximum - GoalPace.minimumKgPerWeek) / _stepKg)
                  .round(),
              label: '${GoalFormats.kgPrecise(_paceKgPerWeek)} kg',
              semanticFormatterCallback: (raw) =>
                  '${GoalFormats.kgPrecise(raw)} chilogrammi a settimana',
              onChanged: (value) =>
                  setState(() => _paceKgPerWeek = _snap(value)),
            ),
            const SizedBox(height: 6),
            StatRow(
              key: const Key('pace_deficit'),
              label: 'Deficit al giorno',
              value: GoalFormats.round(
                GoalPace.dailyDeficitKcal(_paceKgPerWeek),
              ),
              unit: 'kcal',
              unitSemantics: 'chilocalorie',
              icon: Icons.remove_circle_outline_rounded,
            ),
            if (widget.fatToLoseKg > 0)
              StatRow(
                key: const Key('pace_horizon'),
                label: 'Tempo stimato',
                value: GoalFormats.horizon(days),
                caption: verdict.accepted
                    ? null
                    : 'calcolato sul massimo sicuro, non sul ritmo chiesto',
                icon: Icons.event_rounded,
              ),
            if (!verdict.accepted) ...[
              const SizedBox(height: 12),
              _RefusalPanel(
                verdict: verdict,
                proposalKgPerWeek: _snapDown(verdict.appliedKgPerWeek),
                onAcceptCounterProposal: () => setState(
                  () => _paceKgPerWeek = _snapDown(verdict.appliedKgPerWeek),
                ),
              ),
            ],
            const SizedBox(height: 18),
            FilledButton.icon(
              key: const Key('pace_save'),
              // Rifiutato vuol dire rifiutato: il salvataggio si chiude e la
              // strada per riaprirlo è la controproposta qui sopra.
              onPressed: verdict.accepted
                  ? () => Navigator.pop(context, _paceKgPerWeek)
                  : null,
              icon: const Icon(Icons.check_rounded),
              label: const Text('Salva il ritmo'),
            ),
          ],
        ),
      ),
    );
  }
}

class _RefusalPanel extends StatelessWidget {
  const _RefusalPanel({
    required this.verdict,
    required this.proposalKgPerWeek,
    required this.onAcceptCounterProposal,
  });

  final PaceVerdict verdict;

  /// Quello che il pulsante mette davvero: la tacca subito sotto il limite,
  /// non il limite esatto, che non è raggiungibile con la manopola.
  final double proposalKgPerWeek;

  final VoidCallback onAcceptCounterProposal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return DecoratedBox(
      key: const Key('pace_refusal'),
      decoration: BoxDecoration(
        color: accents.criticalSurface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accents.critical.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const StatusChip(
              level: AppStatusLevel.critical,
              label: 'Troppo in fretta',
            ),
            const SizedBox(height: 10),
            Text(
              verdict.refusal ?? '',
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
            ),
            if (verdict.counterProposal case final proposal?) ...[
              const SizedBox(height: 8),
              Text(
                proposal,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: accents.mutedInk,
                  height: 1.35,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const Key('pace_accept_counter_proposal'),
                onPressed: onAcceptCounterProposal,
                icon: const Icon(Icons.speed_rounded),
                label: Text(
                  'Metti ${GoalFormats.kgPrecise(proposalKgPerWeek)} kg '
                  'a settimana',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
