import 'package:flutter/material.dart';
import 'package:kal_tracker/core/presentation/empty_state.dart';
import 'package:kal_tracker/core/presentation/section_card.dart';
import 'package:kal_tracker/core/theme/app_theme.dart';

/// Una serie del grafico, come compare in legenda.
@immutable
class ChartSeries {
  const ChartSeries({required this.label, required this.color, this.marker});

  /// Il nome della serie: è questo a dire cosa rappresenta, non il colore.
  final String label;

  final Color color;

  /// Segno usato nel grafico (linea tratteggiata, punto, barra). Due serie
  /// dovrebbero differire anche di forma, non solo di tinta.
  final IconData? marker;
}

/// Il contenitore standard dei grafici: titolo, legenda, area del disegno e
/// — quando i dati non ci sono ancora — lo stato vuoto al loro posto.
///
/// Il grafico vero lo passa il chiamante in [chart]: qui non si disegna
/// nulla, si tiene solo la cornice uguale ovunque.
class ChartCard extends StatelessWidget {
  const ChartCard({
    required this.title,
    required this.chart,
    this.subtitle,
    this.icon,
    this.series = const [],
    this.height = 200,
    this.actionLabel,
    this.onAction,
    this.emptyMessage =
        'Ancora nessun dato da mostrare: torna qui dopo qualche '
        'registrazione.',
    this.emptyIcon = Icons.show_chart_rounded,
    super.key,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;

  /// Il grafico. Nullo significa «non ci sono dati»: al suo posto va lo
  /// stato vuoto, e la legenda sparisce perché non descrive più niente.
  final Widget? chart;

  final List<ChartSeries> series;

  /// Altezza dell'area di disegno. Fissa di proposito: un grafico che si
  /// adatta in verticale rende i confronti tra schermate inaffidabili.
  final double height;

  final String? actionLabel;
  final VoidCallback? onAction;

  final String emptyMessage;
  final IconData emptyIcon;

  @override
  Widget build(BuildContext context) {
    final chart = this.chart;

    return SectionCard(
      title: title,
      subtitle: subtitle,
      icon: icon,
      actionLabel: actionLabel,
      onAction: onAction,
      child: chart == null
          ? AppEmptyState(message: emptyMessage, icon: emptyIcon)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: height, child: chart),
                if (series.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _ChartLegend(series: series),
                ],
              ],
            ),
    );
  }
}

class _ChartLegend extends StatelessWidget {
  const _ChartLegend({required this.series});

  final List<ChartSeries> series;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return Semantics(
      container: true,
      label: 'Legenda: ${series.map((s) => s.label).join(', ')}',
      child: ExcludeSemantics(
        child: Wrap(
          spacing: 14,
          runSpacing: 8,
          children: [
            for (final entry in series)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (entry.marker case final marker?)
                    Icon(marker, size: 13, color: entry.color)
                  else
                    Container(
                      width: 11,
                      height: 11,
                      decoration: BoxDecoration(
                        color: entry.color,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  const SizedBox(width: 6),
                  Text(
                    entry.label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: accents.mutedInk,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
