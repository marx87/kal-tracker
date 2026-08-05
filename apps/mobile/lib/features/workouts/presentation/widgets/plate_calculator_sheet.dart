import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/workouts/domain/plate_calculator.dart';

/// «Quanti dischi metto?», in un foglio.
///
/// Il calcolo sta nel dominio (`plate_calculator.dart`); qui c'è solo il
/// vestito. I dischi restano colorati con il codice IPF — rosso 25, blu 20,
/// giallo 15, verde 10 — perché in palestra li si riconosce così: è l'unico
/// punto dell'app dove il colore imita il mondo invece di seguire il tema, e
/// per questo ogni disco porta ANCHE il suo numero scritto sopra.
class PlateCalculatorSheet extends StatefulWidget {
  const PlateCalculatorSheet({this.initialWeight, super.key});

  final double? initialWeight;

  static Future<void> show(BuildContext context, {double? initialWeight}) {
    HapticFeedback.lightImpact();
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => PlateCalculatorSheet(initialWeight: initialWeight),
    );
  }

  @override
  State<PlateCalculatorSheet> createState() => _PlateCalculatorSheetState();
}

class _PlateCalculatorSheetState extends State<PlateCalculatorSheet> {
  late final TextEditingController _weightController;
  late final TextEditingController _barController;
  double _bar = 20;

  @override
  void initState() {
    super.initState();
    _weightController = TextEditingController(
      text: widget.initialWeight == null
          ? ''
          : formatPlateKg(widget.initialWeight!),
    );
    _barController = TextEditingController(text: formatPlateKg(_bar));
  }

  @override
  void dispose() {
    _weightController.dispose();
    _barController.dispose();
    super.dispose();
  }

  static double _parse(String raw, double fallback) =>
      double.tryParse(raw.replaceAll(',', '.')) ?? fallback;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final target = _parse(_weightController.text, 0);
    final bar = _parse(_barController.text, _bar);
    final breakdown = computePlateBreakdown(targetKg: target, barKg: bar);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 4,
          bottom: 24 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(
                  'Calcola i dischi',
                  style: theme.textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Dischi disponibili: '
                '${kPlatesKg.map(formatPlateKg).join(' · ')} kg',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: accents.mutedInk,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('plate_target_field'),
                      controller: _weightController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Peso totale',
                        suffixText: 'kg',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      key: const Key('plate_bar_field'),
                      controller: _barController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Bilanciere',
                        suffixText: 'kg',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final preset in kBarPresetsKg)
                    ChoiceChip(
                      label: Text('${formatPlateKg(preset)} kg'),
                      selected: bar == preset,
                      onSelected: (_) => setState(() {
                        _bar = preset;
                        _barController.text = formatPlateKg(preset);
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              _BreakdownView(
                targetKg: target,
                barKg: bar,
                perSide: breakdown.perSide,
                residual: breakdown.residual,
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Chiudi'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BreakdownView extends StatelessWidget {
  const _BreakdownView({
    required this.targetKg,
    required this.barKg,
    required this.perSide,
    required this.residual,
  });

  final double targetKg;
  final double barKg;
  final List<double> perSide;
  final double residual;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    if (targetKg <= 0) {
      return const AppEmptyState(
        icon: Icons.fitness_center_rounded,
        message: 'Scrivi il peso totale e ti dico cosa infilare per lato.',
        compact: true,
      );
    }
    if (targetKg < barKg) {
      return _Notice(
        level: AppStatusLevel.warning,
        text:
            'Il peso che vuoi è meno del bilanciere da '
            '${formatPlateKg(barKg)} kg. Usa un bilanciere più leggero o i '
            'manubri.',
      );
    }
    if (targetKg == barKg) {
      return const _Notice(
        level: AppStatusLevel.good,
        text: 'Solo il bilanciere: nessun disco.',
      );
    }

    final achievable = achievablePlateTotal(perSide: perSide, barKg: barKg);
    final hasResidual = residual > 0.01;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StatRow(
              key: const Key('plate_total'),
              label: 'Con il bilanciere da ${formatPlateKg(barKg)} kg',
              value: formatPlateKg(achievable),
              unit: 'kg',
              unitSemantics: 'chilogrammi',
              icon: Icons.straighten_rounded,
              trailing: hasResidual
                  ? const StatusChip(
                      level: AppStatusLevel.warning,
                      label: 'Non esatto',
                      compact: true,
                    )
                  : null,
            ),
            if (hasResidual) ...[
              const SizedBox(height: 4),
              Text(
                'Con questi dischi non arrivi a ${formatPlateKg(targetKg)} kg: '
                'restano ${formatPlateKg(residual)} kg per lato che non hai. '
                'Il carico più vicino è ${formatPlateKg(achievable)} kg.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: accents.warning,
                  height: 1.35,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              'PER LATO (POI SPECCHIA)',
              style: theme.textTheme.labelSmall?.copyWith(
                color: accents.mutedInk,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 10),
            if (perSide.isEmpty)
              Text(
                'Nessun disco: solo il bilanciere.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: accents.mutedInk,
                ),
              )
            else
              Semantics(
                container: true,
                label:
                    'Per lato: '
                    '${perSide.map((p) => '${formatPlateKg(p)} chili').join(', ')}',
                child: ExcludeSemantics(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [for (final plate in perSide) _Plate(kg: plate)],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.level, required this.text});

  final AppStatusLevel level;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: level.background(accents),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: level.foreground(accents).withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(level.icon, size: 20, color: level.foreground(accents)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: level.foreground(accents),
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Un disco. La dimensione cresce col peso, come sul castelletto vero.
class _Plate extends StatelessWidget {
  const _Plate({required this.kg});

  final double kg;

  /// Codifica IPF. È l'eccezione consapevole alla regola «niente colori
  /// letterali»: qui il colore È il dato, non la decorazione, e il numero
  /// scritto sopra fa da ridondanza per chi non lo distingue.
  ({Color fill, Color ink}) get _paint {
    if (kg >= 25) return (fill: const Color(0xFFC62828), ink: Colors.white);
    if (kg >= 20) return (fill: const Color(0xFF1565C0), ink: Colors.white);
    if (kg >= 15) return (fill: const Color(0xFFF9A825), ink: Colors.black);
    if (kg >= 10) return (fill: const Color(0xFF2E7D32), ink: Colors.white);
    return (fill: const Color(0xFF4E4E4E), ink: Colors.white);
  }

  @override
  Widget build(BuildContext context) {
    final paint = _paint;
    final height = 26.0 + kg.clamp(0, 25) * 1.4;
    return Container(
      width: 62,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: paint.fill,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        formatPlateKg(kg),
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: paint.ink,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}
