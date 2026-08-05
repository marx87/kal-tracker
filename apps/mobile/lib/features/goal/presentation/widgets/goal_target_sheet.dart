import 'package:flutter/material.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/goal/domain/definition_level.dart';
import 'package:kal_tracker/features/goal/domain/goal_feasibility.dart';
import 'package:kal_tracker/features/goal/domain/goal_pace.dart';
import 'package:kal_tracker/features/goal/presentation/goal_formats.dart';

/// Quello che la manopola restituisce: un peso e una parola.
class GoalTargetChoice {
  const GoalTargetChoice({required this.weightKg, required this.level});

  final double weightKg;
  final DefinitionLevel level;
}

/// **Il selettore: una manopola sola.**
///
/// A massa magra invariata peso e definizione non sono due scelte: se ne
/// scegli uno l'altro segue. Qui c'è quindi un solo cursore, e le due
/// etichette si muovono insieme sopra di esso, con i chili di grasso da
/// perdere e il tempo stimato che si aggiornano mentre il dito è ancora giù.
///
/// L'interruttore «tieni ferma la definizione» serve a poter chiedere
/// l'impossibile: bloccata la parola, il cursore esce dalla curva e compare
/// il verdetto di fattibilità. È il caso d'uso del coach che sa dire di no,
/// e senza un modo di uscire dalla curva non esisterebbe.
class GoalTargetSheet extends StatefulWidget {
  const GoalTargetSheet({
    required this.currentWeightKg,
    required this.fatFreeMassKg,
    required this.paceKgPerWeek,
    this.initialTargetWeightKg,
    this.initialLevel,
    super.key,
  });

  final double currentWeightKg;
  final double fatFreeMassKg;

  /// Serve solo a mostrare il tempo stimato mentre si sceglie: il ritmo si
  /// cambia altrove, e cambiarlo non tocca il traguardo.
  final double paceKgPerWeek;

  final double? initialTargetWeightKg;
  final DefinitionLevel? initialLevel;

  @override
  State<GoalTargetSheet> createState() => _GoalTargetSheetState();
}

class _GoalTargetSheetState extends State<GoalTargetSheet> {
  /// Il passo della manopola. Mezzo chilo è la risoluzione onesta di una
  /// bilancia da casa: passi più fini darebbero una precisione inventata.
  static const double _stepKg = 0.5;

  late double _weightKg;

  /// Gli estremi, già portati sulla griglia dei mezzi chili: così ogni
  /// posizione del cursore è un valore tondo e il numero grande non balla
  /// mai su un decimale che nessuno ha scelto.
  late final double _minKg;
  late final double _maxKg;

  DefinitionLevel? _lockedLevel;

  @override
  void initState() {
    super.initState();
    final range = DefinitionCurve.dialRange(widget.fatFreeMassKg);
    _minKg = (range.minKg / _stepKg).ceil() * _stepKg;
    _maxKg = (range.maxKg / _stepKg).floor() * _stepKg;
    final start =
        widget.initialTargetWeightKg ??
        DefinitionCurve.weightFor(
          level: DefinitionLevel.lean,
          fatFreeMassKg: widget.fatFreeMassKg,
        );
    _weightKg = _snap(start);
    // Il blocco NON si eredita da un obiettivo qualunque: si accende solo se
    // il traguardo salvato era già fuori curva. Riaprendo un traguardo
    // normale la definizione deve tornare a seguire il peso, altrimenti la
    // manopola nascerebbe bloccata senza che nessuno l'abbia bloccata.
    final initialLevel = widget.initialLevel;
    _lockedLevel =
        initialLevel != null &&
            DefinitionCurve.read(
                  weightKg: _weightKg,
                  fatFreeMassKg: widget.fatFreeMassKg,
                ).level !=
                initialLevel
        ? initialLevel
        : null;
  }

  double _snap(double value) =>
      ((value / _stepKg).round() * _stepKg).clamp(_minKg, _maxKg);

  /// Il gradino più vicino alla curva che sta **dentro** la scala.
  ///
  /// Arrotondare al mezzo chilo può far scivolare la controproposta appena
  /// fuori scala (78,7 diventerebbe 78,5, di nuovo troppo asciutto): in quel
  /// caso si prende il gradino successivo verso l'interno, altrimenti il
  /// pulsante che promette di riportarti sulla curva non ce la fa.
  double _snapOntoScale(double raw) {
    final snapped = _snap(raw);
    final reading = DefinitionCurve.read(
      weightKg: snapped,
      fatFreeMassKg: widget.fatFreeMassKg,
    );
    return switch (reading.position) {
      ScalePosition.leanerThanScale => _snap(snapped + _stepKg),
      ScalePosition.softerThanScale => _snap(snapped - _stepKg),
      ScalePosition.onScale => snapped,
    };
  }

  DefinitionReading get _reading => DefinitionCurve.read(
    weightKg: _weightKg,
    fatFreeMassKg: widget.fatFreeMassKg,
  );

  DefinitionLevel get _level => _lockedLevel ?? _reading.level;

  FeasibilityVerdict get _verdict => GoalFeasibility.assess(
    currentWeightKg: widget.currentWeightKg,
    currentFatFreeMassKg: widget.fatFreeMassKg,
    targetWeightKg: _weightKg,
    targetLevel: _level,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final verdict = _verdict;
    final proposalKg = _snapOntoScale(verdict.onCurveWeightKg);
    final days = GoalPace.daysToLose(
      fatToLoseKg: verdict.fatToLoseKg,
      kgPerWeek: widget.paceKgPerWeek,
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
                'Dove vuoi arrivare',
                style: theme.textTheme.headlineSmall,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Trascina: peso e definizione si muovono insieme, perché con il '
              'muscolo che hai sono la stessa scelta.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: accents.mutedInk,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 18),
            _TargetReadout(
              weightKg: _weightKg,
              level: _level,
              onScale: _lockedLevel != null || _reading.isOnScale,
            ),
            const SizedBox(height: 10),
            _CurveDial(
              value: _weightKg,
              minKg: _minKg,
              maxKg: _maxKg,
              stepKg: _stepKg,
              level: _level,
              onChanged: (value) => setState(() => _weightKg = _snap(value)),
            ),
            const SizedBox(height: 4),
            _LevelLock(
              level: _level,
              locked: _lockedLevel != null,
              onChanged: (locked) =>
                  setState(() => _lockedLevel = locked ? _level : null),
            ),
            const SizedBox(height: 14),
            _VerdictPanel(
              verdict: verdict,
              proposalKg: proposalKg,
              onTakeCounterProposal: () =>
                  setState(() => _weightKg = proposalKg),
            ),
            const SizedBox(height: 6),
            StatRow(
              key: const Key('goal_sheet_fat_to_lose'),
              label: 'Grasso da perdere',
              value: GoalFormats.kg(verdict.fatToLoseKg),
              unit: 'kg',
              unitSemantics: 'chilogrammi',
              icon: Icons.local_fire_department_rounded,
            ),
            StatRow(
              key: const Key('goal_sheet_horizon'),
              label: 'Tempo stimato',
              value: GoalFormats.horizon(days),
              caption:
                  'al ritmo di adesso, '
                  '${GoalFormats.kgPrecise(widget.paceKgPerWeek)} kg a '
                  'settimana',
              icon: Icons.event_rounded,
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              key: const Key('goal_sheet_save'),
              onPressed: () => Navigator.pop(
                context,
                GoalTargetChoice(weightKg: _weightKg, level: _level),
              ),
              icon: const Icon(Icons.flag_rounded),
              label: const Text('Salva il traguardo'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Le due etichette che si muovono insieme. Il peso è il numero grande, la
/// definizione la parola sotto: mai una percentuale di grasso.
class _TargetReadout extends StatelessWidget {
  const _TargetReadout({
    required this.weightKg,
    required this.level,
    required this.onScale,
  });

  final double weightKg;
  final DefinitionLevel level;

  /// Fuori scala la parola non descrive più il peso, e dirlo è parte
  /// dell'onestà del selettore.
  final bool onScale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return Semantics(
      container: true,
      label: 'Traguardo',
      value: onScale
          ? '${GoalFormats.kg(weightKg)} chilogrammi, ${level.inlineLabel}'
          : '${GoalFormats.kg(weightKg)} chilogrammi, fuori dalla scala '
                'delle definizioni',
      child: ExcludeSemantics(
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  GoalFormats.kg(weightKg),
                  key: const Key('goal_sheet_weight'),
                  style: theme.textTheme.headlineLarge?.tabular,
                ),
                const SizedBox(width: 6),
                Text(
                  'kg',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: accents.mutedInk,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              key: const Key('goal_sheet_level'),
              onScale ? level.label : 'Fuori scala',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              onScale
                  ? level.description
                  : 'Nessuna definizione descrive questo peso con il muscolo '
                        'che hai oggi.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: accents.mutedInk,
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Il cursore, con le tacche della scala sotto.
class _CurveDial extends StatelessWidget {
  const _CurveDial({
    required this.value,
    required this.minKg,
    required this.maxKg,
    required this.stepKg,
    required this.level,
    required this.onChanged,
  });

  final double value;
  final double minKg;
  final double maxKg;
  final double stepKg;
  final DefinitionLevel level;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return Column(
      children: [
        Slider(
          key: const Key('goal_dial'),
          value: value.clamp(minKg, maxKg),
          min: minKg,
          max: maxKg,
          divisions: ((maxKg - minKg) / stepKg).round(),
          label: '${GoalFormats.kg(value)} kg',
          // Il lettore di schermo deve sentire la stessa cosa che si vede:
          // il numero e la parola, non «ottanta virgola cinque».
          semanticFormatterCallback: (raw) =>
              '${GoalFormats.kg(raw)} chilogrammi, ${level.inlineLabel}',
          onChanged: onChanged,
        ),
        // Gli estremi scritti a parole: il cursore da solo non dice dove
        // finisce la scala e dove comincia l'assurdo.
        ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'più asciutto',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: accents.mutedInk,
                  ),
                ),
                Text(
                  'più morbido',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: accents.mutedInk,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _LevelLock extends StatelessWidget {
  const _LevelLock({
    required this.level,
    required this.locked,
    required this.onChanged,
  });

  final DefinitionLevel level;
  final bool locked;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final accents = AppAccents.of(context);
    return SwitchListTile.adaptive(
      key: const Key('goal_lock_level'),
      contentPadding: EdgeInsets.zero,
      value: locked,
      onChanged: onChanged,
      title: Text('Tieni ferma la definizione «${level.inlineLabel}»'),
      subtitle: Text(
        locked
            ? 'Ora il cursore muove solo il peso: se esce dalla curva te lo '
                  'dico qui sotto.'
            : 'Sbloccata, la definizione segue il peso lungo la curva.',
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: accents.mutedInk, height: 1.3),
      ),
    );
  }
}

/// Il verdetto di fattibilità, con la controproposta a portata di pollice.
class _VerdictPanel extends StatelessWidget {
  const _VerdictPanel({
    required this.verdict,
    required this.proposalKg,
    required this.onTakeCounterProposal,
  });

  final FeasibilityVerdict verdict;

  /// Il peso che il pulsante applica davvero: sta qui e non nel verdetto
  /// perché è già portato sulla griglia della manopola, e un pulsante deve
  /// promettere il numero che poi mette.
  final double proposalKg;

  final VoidCallback onTakeCounterProposal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final level = switch (verdict.kind) {
      FeasibilityKind.achievable => AppStatusLevel.good,
      FeasibilityKind.needsMuscleGain => AppStatusLevel.warning,
      FeasibilityKind.needsMuscleLoss => AppStatusLevel.critical,
    };

    return DecoratedBox(
      key: const Key('goal_feasibility'),
      decoration: BoxDecoration(
        color: level.background(accents),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: level.foreground(accents).withValues(alpha: 0.35),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StatusChip(level: level, label: verdict.headline),
            const SizedBox(height: 10),
            Text(
              verdict.explanation,
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
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const Key('goal_take_counter_proposal'),
                  onPressed: onTakeCounterProposal,
                  icon: const Icon(Icons.trending_flat_rounded),
                  label: Text('Portami a ${GoalFormats.kg(proposalKg)} kg'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
