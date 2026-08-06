import 'package:go_router/go_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/body/domain/body_analysis.dart';
import 'package:kal_tracker/features/body/domain/body_models.dart';
import 'package:kal_tracker/features/body/presentation/body_charts.dart';
import 'package:kal_tracker/features/body/presentation/body_formats.dart';
import 'package:kal_tracker/features/body/presentation/body_providers.dart';
import 'package:kal_tracker/features/body/presentation/weigh_in_sheet.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';

/// La schermata Corpo: quella che giustifica la bilancia.
///
/// Non è «l'andamento del peso» con qualche numero attorno. Il peso da solo
/// non distingue una ricomposizione da un dimagrimento, quindi il grafico
/// principale sono due aree impilate — kg di grasso e kg di massa magra — e
/// tutto, ma proprio tutto, si legge a medie mobili di 7 giorni.
///
/// Quello che qui NON si vedrà mai: età metabolica, peso ottimale, tipo di
/// corpo. La bilancia li stampa, ma sono giudizi ricavati da una formula
/// chiusa, non misure: non stanno nel modello e non entrano nella UI.
class BodyScreen extends ConsumerWidget {
  const BodyScreen({super.key});

  /// Nome della rotta che l'integratore collegherà nel router.
  static const routeName = 'body';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final insights = ref.watch(bodyInsightsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Corpo'),
            Text(
              'Peso e composizione, a medie di 7 giorni',
              style: theme.textTheme.bodySmall?.copyWith(
                color: accents.mutedInk,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        actions: [
          // L'obiettivo vive accanto alla composizione perché è lì che si
          // legge se ci si sta arrivando; backup, sincronizzazione e travaso
          // da Gym Tracker riguardano gli stessi dati personali.
          // La bilancia prima di tutto: è il modo normale di registrare una
          // pesata, e il foglio manuale è la strada di riserva.
          IconButton(
            key: const Key('body_open_scale_button'),
            tooltip: 'Leggi dalla bilancia',
            onPressed: () => context.goNamed('scale'),
            icon: const Icon(Icons.bluetooth_searching_rounded),
          ),
          IconButton(
            key: const Key('body_open_coach_button'),
            tooltip: 'Rapporto del coach',
            onPressed: () => context.goNamed('coach'),
            icon: const Icon(Icons.insights_outlined),
          ),
          IconButton(
            key: const Key('body_open_goal_button'),
            tooltip: 'Obiettivo',
            onPressed: () => context.goNamed('goal'),
            icon: const Icon(Icons.flag_outlined),
          ),
          IconButton(
            key: const Key('body_open_progress_button'),
            tooltip: 'Progressi e impostazioni',
            onPressed: () => context.goNamed('progress'),
            icon: const Icon(Icons.tune_rounded),
          ),
          IconButton.filled(
            key: const Key('body_add_measurement_button'),
            tooltip: 'Registra una pesata',
            onPressed: () => openWeighInSheet(context, ref),
            icon: const Icon(Icons.add_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: insights.when(
        data: (value) => _BodyContent(insights: value),
        loading: () => const Center(
          key: Key('body_loading'),
          child: CircularProgressIndicator(),
        ),
        error: (error, stackTrace) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: AppEmptyState(
              icon: Icons.cloud_off_rounded,
              title: 'Non riesco a leggere le pesate',
              message:
                  'I dati sono sul dispositivo e non si perdono: riprova a '
                  'caricarli.',
              actionLabel: 'Riprova',
              onAction: () => ref.invalidate(bodyMeasurementsProvider),
            ),
          ),
        ),
      ),
    );
  }
}

/// Apre il foglio della pesata e salva quello che torna.
///
/// È una funzione e non un metodo della schermata perché la chiamano anche le
/// card interne (lo stato vuoto, la sezione circonferenze): meglio un punto
/// solo che tre `showModalBottomSheet` da tenere allineate.
Future<void> openWeighInSheet(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  final labels = ref.read(knownCircumferenceLabelsProvider);
  final draft = await showModalBottomSheet<WeighInDraft>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) =>
        WeighInSheet(knownLabels: labels, now: AppTime.nowInRome()),
  );
  if (draft == null) {
    return;
  }
  try {
    final profile = await ref.read(marcoProfileProvider.future);
    await ref
        .read(bodyRepositoryProvider)
        .addMeasurement(
          profileId: profile.id,
          weightKg: draft.weightKg,
          measuredAt: draft.measuredAt,
          bodyFatPct: draft.bodyFatPct,
          musclePct: draft.musclePct,
          waterPct: draft.waterPct,
          impedanceOhm: draft.impedanceOhm,
          note: draft.note,
          circumferences: draft.circumferences,
        );
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          draft.hasComposition
              ? 'Pesata registrata: entra nelle medie di peso e composizione.'
              : 'Peso registrato. Senza percentuale di grasso resta fuori '
                    'dalle medie della composizione.',
        ),
      ),
    );
  } on FormatException catch (error) {
    messenger.showSnackBar(SnackBar(content: Text(error.message)));
  } on Object {
    messenger.showSnackBar(
      const SnackBar(content: Text('Non riesco a salvare la pesata.')),
    );
  }
}

class _BodyContent extends ConsumerWidget {
  const _BodyContent({required this.insights});

  final BodyInsights insights;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AdaptiveLayout(
      builder: (context, size) => AdaptiveContent(
        child: ListView(
          key: const Key('body_list'),
          padding: AppBreakpoints.pagePadding(size),
          children: [
            _RangePicker(current: insights.range),
            const SizedBox(height: 14),
            if (insights.isEmpty)
              AppEmptyState(
                key: const Key('body_empty_state'),
                icon: Icons.monitor_weight_outlined,
                title: 'Nessuna pesata in questo periodo',
                message:
                    'Registra una pesata: dalla settima il grafico inizia a '
                    'dire qualcosa di affidabile.',
                actionLabel: 'Registra una pesata',
                onAction: () => openWeighInSheet(context, ref),
              )
            else ...[
              _SummaryCard(
                insights: insights,
                onAdd: () => openWeighInSheet(context, ref),
              ),
              const SizedBox(height: 14),
            ],
            _TrustCard(spread: insights.spread),
            if (!insights.isEmpty) ...[
              const SizedBox(height: 14),
              _CompositionCard(insights: insights),
              if (insights.hasCompositionSeries) ...[
                const SizedBox(height: 14),
                _ZoomCard(points: insights.compositionTrend),
              ],
              const SizedBox(height: 14),
              _CircumferencesCard(
                trends: insights.circumferences,
                onAdd: () => openWeighInSheet(context, ref),
              ),
              const SizedBox(height: 14),
              _MeasurementsCard(insights: insights),
            ],
          ],
        ),
      ),
    );
  }
}

/// I chip della finestra temporale. Sono chip e non un menù perché la scelta
/// è di tre valori e deve costare un tocco solo.
class _RangePicker extends ConsumerWidget {
  const _RangePicker({required this.current});

  final BodyRange current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Semantics(
      container: true,
      label: 'Periodo mostrato',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final range in BodyRange.values)
            ChoiceChip(
              key: Key('body_range_${range.days}'),
              selected: range == current,
              label: Text(range.label),
              onSelected: (_) =>
                  ref.read(bodyRangeProvider.notifier).state = range,
            ),
        ],
      ),
    );
  }
}

/// Dove sei adesso: le tre medie a 7 giorni e cosa stanno facendo insieme.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.insights, required this.onAdd});

  final BodyInsights insights;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final latest = insights.latest;

    return SectionCard(
      key: const Key('body_summary_card'),
      title: 'Ultimi 7 giorni',
      subtitle: 'Medie mobili: non è l’ultima pesata, è la settimana.',
      icon: Icons.insights_rounded,
      actionLabel: 'Registra',
      onAction: onAdd,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _VerdictBanner(verdict: insights.verdict),
          if (insights.staleDays case final stale? when stale >= 3) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: StatusChip(
                key: const Key('body_stale_chip'),
                level: AppStatusLevel.warning,
                label: 'Ultima pesata ${BodyFormats.daysAgo(stale)}',
              ),
            ),
          ],
          const SizedBox(height: 6),
          if (latest == null)
            const AppEmptyState(
              compact: true,
              message:
                  'Nessuna pesata dentro il periodo scelto: allarga la '
                  'finestra o registrane una.',
            )
          else ...[
            StatRow(
              key: const Key('body_weight_stat'),
              label: 'Peso',
              icon: Icons.monitor_weight_outlined,
              value: BodyFormats.kg(latest.weightKg),
              unit: 'kg',
              unitSemantics: 'chilogrammi',
              caption: _caption(insights.weightChange, latest.weightDays),
              trailing: _DirectionArrow(change: insights.weightChange),
            ),
            const Divider(),
            if (latest.hasComposition) ...[
              StatRow(
                key: const Key('body_fat_stat'),
                label: 'Massa grassa',
                icon: Icons.local_fire_department_outlined,
                value: BodyFormats.kg(latest.fatMassKg!),
                unit: 'kg',
                unitSemantics: 'chilogrammi',
                caption: _caption(insights.fatChange, latest.compositionDays),
                trailing: _DirectionArrow(
                  change: insights.fatChange,
                  desired: _Direction.down,
                ),
              ),
              const Divider(),
              StatRow(
                key: const Key('body_lean_stat'),
                label: 'Massa magra',
                icon: Icons.fitness_center_rounded,
                value: BodyFormats.kg(latest.leanMassKg!),
                unit: 'kg',
                unitSemantics: 'chilogrammi',
                caption: _caption(insights.leanChange, latest.compositionDays),
                trailing: _DirectionArrow(
                  change: insights.leanChange,
                  desired: _Direction.up,
                ),
              ),
              const Divider(),
              StatRow(
                key: const Key('body_fat_percent_stat'),
                label: 'Grasso',
                icon: Icons.percent_rounded,
                value: BodyFormats.percent(latest.bodyFatPct!),
                unit: '%',
                unitSemantics: 'per cento',
                caption:
                    'Media di ${latest.compositionDays} '
                    '${latest.compositionDays == 1 ? 'giorno' : 'giorni'} con '
                    'impedenza. Il valore assoluto è indicativo.',
              ),
            ] else
              const AppEmptyState(
                key: Key('body_no_composition'),
                compact: true,
                icon: Icons.bolt_outlined,
                message:
                    'In questo periodo nessuna pesata con impedenza: posso '
                    'mostrarti il peso, non come è fatto.',
              ),
          ],
        ],
      ),
    );
  }

  /// La didascalia dice la variazione E su quanti giorni poggia la media:
  /// una media a due giorni non è la stessa cosa di una media a sette, e chi
  /// legge deve poterlo sapere senza aprire il codice.
  String _caption(BodyChange? change, int days) {
    final base = 'media su $days ${days == 1 ? 'giorno' : 'giorni'} di pesate';
    if (change == null) {
      return 'Nessun confronto ancora: serve una pesata di almeno '
          '${BodyAnalysis.minimumComparisonDays} giorni fa. $base.';
    }
    return '${BodyFormats.signedKg(change.deltaKg)} kg in '
        '${change.spanDays} giorni · $base';
  }
}

enum _Direction { up, down }

/// La freccia accanto al valore. Il verso è nella FORMA, non nel colore: chi
/// non distingue il verde dal grigio vede comunque dove punta, e la
/// variazione è comunque scritta a parole nella didascalia della riga.
class _DirectionArrow extends StatelessWidget {
  const _DirectionArrow({required this.change, this.desired});

  final BodyChange? change;

  /// La direzione che in questo contesto è quella cercata (grasso giù, magra
  /// su). Nulla per il peso: scendere non è un merito in sé.
  final _Direction? desired;

  @override
  Widget build(BuildContext context) {
    final accents = AppAccents.of(context);
    final change = this.change;
    if (change == null || BodyFormats.isFlat(change.deltaKg)) {
      return ExcludeSemantics(
        child: Icon(Icons.remove_rounded, size: 20, color: accents.mutedInk),
      );
    }
    final goingUp = change.deltaKg > 0;
    final matches =
        desired != null &&
        ((goingUp && desired == _Direction.up) ||
            (!goingUp && desired == _Direction.down));
    return ExcludeSemantics(
      child: Icon(
        goingUp ? Icons.north_rounded : Icons.south_rounded,
        size: 20,
        color: matches ? accents.positive : accents.mutedInk,
      ),
    );
  }
}

/// Il verdetto: ricomposizione, dimagrimento, o niente di leggibile.
class _VerdictBanner extends StatelessWidget {
  const _VerdictBanner({required this.verdict});

  final BodyVerdict verdict;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final (background, foreground) = switch (verdict) {
      BodyVerdict.recomposition ||
      BodyVerdict.cleanFatLoss => (accents.positiveSurface, accents.positive),
      BodyVerdict.adverse => (accents.warningSurface, accents.warning),
      BodyVerdict.unknown => (
        theme.colorScheme.surfaceContainerHigh,
        accents.mutedInk,
      ),
      _ => (accents.infoSurface, accents.info),
    };

    return Semantics(
      container: true,
      label: 'Lettura del periodo: ${verdict.label}',
      value: verdict.description,
      child: ExcludeSemantics(
        child: Container(
          key: const Key('body_verdict_banner'),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: foreground.withValues(alpha: 0.28)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(_icon, color: foreground, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      verdict.label,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      verdict.description,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData get _icon => switch (verdict) {
    BodyVerdict.recomposition => Icons.swap_vert_rounded,
    BodyVerdict.cleanFatLoss => Icons.trending_down_rounded,
    BodyVerdict.weightLoss => Icons.south_rounded,
    BodyVerdict.gain => Icons.trending_up_rounded,
    BodyVerdict.adverse => Icons.priority_high_rounded,
    BodyVerdict.stable => Icons.drag_handle_rounded,
    BodyVerdict.unknown => Icons.help_outline_rounded,
  };
}

/// Il pezzo che dice, con un numero, perché il grafico è fatto di medie.
class _TrustCard extends StatelessWidget {
  const _TrustCard({required this.spread});

  final BiaSpread spread;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final measured = spread.isMeasured;

    return SectionCard(
      key: const Key('body_trust_card'),
      title: 'Quanto fidarsi della bilancia',
      background: accents.infoSurface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            measured
                // Il numero non è un'opinione sulla BIA in generale: è
                // misurato sui giorni in cui Marco è salito più volte, in cui
                // il corpo era lo stesso e la differenza è tutta strumento.
                ? 'Nei giorni in cui ti sei pesato più volte, la percentuale '
                      'di grasso è cambiata di '
                      '${BodyFormats.percent(spread.bodyFatPoints)} punti — '
                      '${BodyFormats.kg(spread.fatMassKg)} kg — a corpo '
                      'fermo. Il valore assoluto è indicativo; il trend no.'
                : 'Il valore assoluto della BIA è indicativo: la stessa '
                      'bilancia, a cinque minuti di distanza, dà percentuali '
                      'diverse. Il trend invece regge.',
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
          ),
          const SizedBox(height: 8),
          Text(
            measured
                ? 'Misurato sulle tue pesate: ${spread.dayCount} '
                      '${spread.dayCount == 1 ? 'giorno' : 'giorni'} con più '
                      'di una salita sulla bilancia. Per questo qui non trovi '
                      'confronti giorno-su-giorno, solo medie a 7 giorni.'
                : 'Ogni tanto pesati due volte di fila: così posso dirti di '
                      'quanto balla la TUA bilancia, con un numero. Intanto '
                      'qui si legge tutto a medie di 7 giorni.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: accents.mutedInk,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _CompositionCard extends StatelessWidget {
  const _CompositionCard({required this.insights});

  final BodyInsights insights;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final points = insights.compositionTrend;

    return ChartCard(
      key: const Key('body_composition_chart_card'),
      title: 'Grasso e massa magra',
      subtitle:
          'Aree impilate, medie a 7 giorni: la somma delle due è il peso.',
      icon: Icons.stacked_line_chart_rounded,
      height: 220,
      series: [
        ChartSeries(
          label: 'Massa grassa',
          color: scheme.secondary,
          marker: Icons.square_rounded,
        ),
        ChartSeries(
          label: 'Massa magra',
          color: scheme.primary,
          marker: Icons.circle,
        ),
      ],
      emptyIcon: Icons.bolt_outlined,
      emptyMessage:
          'Servono almeno due giorni con pesata a impedenza in questo '
          'periodo: senza la percentuale di grasso le due masse non si '
          'separano.',
      chart: insights.hasCompositionSeries
          ? BodyCompositionChart(
              key: const Key('body_composition_chart'),
              points: points,
            )
          : null,
    );
  }
}

/// I due zoom. Servono perché nella pila a scala piena un chilo di grasso in
/// meno è alto pochi pixel: qui ogni serie ha il suo asse e il movimento si
/// vede, col prezzo — dichiarato a schermo — di un asse tagliato.
class _ZoomCard extends StatelessWidget {
  const _ZoomCard({required this.points});

  /// Punti con composizione, almeno due: chi costruisce la card lo garantisce
  /// con `hasCompositionSeries`.
  final List<BodyTrendPoint> points;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fat = [for (final point in points) (point.day, point.fatMassKg!)];
    final lean = [for (final point in points) (point.day, point.leanMassKg!)];

    return SectionCard(
      key: const Key('body_zoom_card'),
      title: 'Il dettaglio del cambiamento',
      subtitle:
          'Le stesse due serie, ognuna col proprio asse: qui si vede quello '
          'che nella pila vale due pixel.',
      icon: Icons.zoom_in_rounded,
      child: AdaptiveLayout(
        builder: (context, size) {
          final charts = [
            BodyZoomChart(
              key: const Key('body_zoom_fat'),
              title: 'Massa grassa',
              points: fat,
              color: scheme.secondary,
            ),
            BodyZoomChart(
              key: const Key('body_zoom_lean'),
              title: 'Massa magra',
              points: lean,
              color: scheme.primary,
            ),
          ];
          if (size.isCompact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [charts.first, const SizedBox(height: 18), charts.last],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: charts.first),
              SizedBox(width: AppBreakpoints.gutter(size)),
              Expanded(child: charts.last),
            ],
          );
        },
      ),
    );
  }
}

class _CircumferencesCard extends StatelessWidget {
  const _CircumferencesCard({required this.trends, required this.onAdd});

  final List<CircumferenceTrend> trends;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      key: const Key('body_circumferences_card'),
      title: 'Circonferenze',
      subtitle:
          'Il metro dice cose che la bilancia non sa. Niente medie qui: si '
          'misura di rado, e mediare cancellerebbe l’unico dato.',
      icon: Icons.straighten_rounded,
      actionLabel: 'Aggiungi',
      onAction: onAdd,
      child: trends.isEmpty
          ? const AppEmptyState(
              key: Key('body_circumferences_empty'),
              compact: true,
              icon: Icons.straighten_rounded,
              message:
                  'Nessuna circonferenza nel periodo. Si registrano insieme '
                  'a una pesata.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, trend) in trends.indexed) ...[
                  if (index > 0) const Divider(),
                  StatRow(
                    key: Key('body_circumference_${trend.label}'),
                    label: trend.label,
                    value: BodyFormats.cm(trend.latestCm),
                    unit: 'cm',
                    unitSemantics: 'centimetri',
                    caption: _caption(trend),
                  ),
                  // Da tre misure in su l'andamento vale un disegno: due
                  // punti sono una retta, e la retta la dice già il numero.
                  if (trend.isDrawable) ...[
                    const SizedBox(height: 6),
                    BodyZoomChart(
                      key: Key('body_circumference_chart_${trend.label}'),
                      title: 'Andamento',
                      points: trend.series,
                      color: Theme.of(context).colorScheme.tertiary,
                      unit: 'cm',
                      semanticsUnit: 'centimetri',
                    ),
                  ],
                ],
              ],
            ),
    );
  }

  String _caption(CircumferenceTrend trend) {
    final delta = trend.deltaCm;
    final span = trend.spanDays;
    if (delta == null || span == null) {
      return 'Unica misura, del ${BodyFormats.stamp(trend.latestAt)}. '
          'Servono due misure a qualche settimana di distanza.';
    }
    return '${BodyFormats.signedCm(delta)} cm in $span giorni · ultima il '
        '${BodyFormats.stamp(trend.latestAt)}';
  }
}

class _MeasurementsCard extends ConsumerWidget {
  const _MeasurementsCard({required this.insights});

  final BodyInsights insights;

  static const _visible = 8;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final measurements = insights.measurements;
    final shown = measurements.take(_visible).toList(growable: false);

    return SectionCard(
      key: const Key('body_measurements_card'),
      title: 'Ultime pesate',
      subtitle: 'Valori grezzi, come sono stati registrati: non mediati.',
      icon: Icons.list_alt_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final measurement in shown)
            _MeasurementTile(
              measurement: measurement,
              onDelete: () => _delete(context, ref, measurement),
            ),
          if (measurements.length > shown.length) ...[
            const SizedBox(height: 8),
            Text(
              'Mostro le ultime ${shown.length} di ${measurements.length} '
              'nel periodo.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: accents.mutedInk,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    BodyMeasurement measurement,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final repository = ref.read(bodyRepositoryProvider);
    try {
      await repository.deleteMeasurement(measurement.id);
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Non riesco a eliminare la pesata.')),
      );
      return;
    }
    // Snackbar CON azione: su questo Flutter non si chiude da sola, quindi
    // passa dall'helper. È un bug già pagato una volta.
    showAutoClosingSnackBar(
      messenger,
      SnackBar(
        content: Text(
          'Pesata del ${BodyFormats.stamp(measurement.measuredAt)} eliminata.',
        ),
        action: SnackBarAction(
          label: 'Annulla',
          onPressed: () async {
            try {
              await repository.restoreMeasurement(measurement.id);
            } on Object {
              messenger.showSnackBar(
                const SnackBar(
                  content: Text('Non riesco a ripristinare la pesata.'),
                ),
              );
            }
          },
        ),
      ),
    );
  }
}

class _MeasurementTile extends StatelessWidget {
  const _MeasurementTile({required this.measurement, required this.onDelete});

  final BodyMeasurement measurement;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final details = [
      BodyFormats.stamp(measurement.measuredAt),
      if (measurement.hasComposition)
        '${BodyFormats.percent(measurement.bodyFatPct!)}% grasso'
      else
        'solo peso',
      BodyFormats.source(measurement.source),
    ].join(' · ');

    return ListTile(
      key: Key('body_measurement_${measurement.id}'),
      contentPadding: EdgeInsets.zero,
      title: Text(
        '${BodyFormats.kg(measurement.weightKg)} kg',
        style: theme.textTheme.titleMedium?.tabular,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            details,
            style: theme.textTheme.bodySmall?.copyWith(color: accents.mutedInk),
          ),
          if (measurement.circumferences.isNotEmpty)
            Text(
              measurement.circumferences.entries
                  .map(
                    (entry) => '${entry.key} ${BodyFormats.cm(entry.value)} cm',
                  )
                  .join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: accents.mutedInk,
              ),
            ),
          if (measurement.note case final note?)
            Text(
              note,
              style: theme.textTheme.bodySmall?.copyWith(
                fontStyle: FontStyle.italic,
                color: accents.mutedInk,
              ),
            ),
        ],
      ),
      trailing: IconButton(
        key: Key('delete_measurement_${measurement.id}'),
        tooltip:
            'Elimina la pesata del ${BodyFormats.stamp(measurement.measuredAt)}',
        onPressed: onDelete,
        icon: const Icon(Icons.delete_outline_rounded),
      ),
    );
  }
}
