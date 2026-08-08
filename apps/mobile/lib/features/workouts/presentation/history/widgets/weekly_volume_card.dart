import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/exercises/presentation/widgets/muscle_group_presentation.dart';
import 'package:kal_tracker/features/workouts/domain/weekly_muscle_volume.dart';
import 'package:kal_tracker/features/workouts/presentation/history/weekly_volume_providers.dart';

/// Quante serie a settimana ha ricevuto ogni gruppo, con la banda accanto.
///
/// La domanda a cui risponde è quella che nessuna schermata sapeva ancora
/// dire: l'obiettivo sono braccia, spalle e addome, ma con una spalla
/// limitata e mezza scheda sostituita un gruppo può essersi svuotato in
/// silenzio.
///
/// Il numero da solo non basterebbe a rispondere — dodici serie sono tante o
/// poche a seconda di cosa si sta facendo — e per questo il riferimento è una
/// BANDA, come per il peso: dentro non c'è niente da correggere. La banda si
/// vede come intervallo e non come bersaglio anche nel disegno: un binario
/// con una zona larga, non una barra che si riempie.
class WeeklyVolumeCard extends ConsumerWidget {
  const WeeklyVolumeCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final volume = ref.watch(weeklyMuscleVolumeProvider);

    return SectionCard(
      key: const Key('weekly_volume_card'),
      title: 'Volume settimanale',
      subtitle:
          'Solo le serie spuntate, riscaldamento e defaticamento esclusi. '
          'La banda è un intervallo, non un numero da centrare.',
      icon: Icons.equalizer_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _WeekStepper(),
          const SizedBox(height: 14),
          volume.when(
            data: (data) => _WeekBody(volume: data),
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, stackTrace) => _CountFailed(
              onRetry: () => ref.invalidate(weekWorkoutsProvider),
            ),
          ),
        ],
      ),
    );
  }
}

/// La settimana mostrata, con le due frecce.
///
/// Avanti si ferma alla settimana in corso: la prossima non ha serie da
/// contare e mostrerebbe otto zeri, cioè otto gruppi apparentemente svuotati.
class _WeekStepper extends ConsumerWidget {
  const _WeekStepper();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final offset = ref.watch(weeklyVolumeWeekOffsetProvider);
    final firstDay = ref.watch(weeklyVolumeWeekStartProvider);
    final lastDay = firstDay.add(const Duration(days: 6));

    void move(int by) =>
        ref.read(weeklyVolumeWeekOffsetProvider.notifier).state = math.max(
          0,
          offset + by,
        );

    return Row(
      children: [
        IconButton(
          key: const Key('weekly_volume_previous_week'),
          onPressed: () => move(1),
          icon: const Icon(Icons.chevron_left_rounded),
          tooltip: 'Settimana precedente',
        ),
        Expanded(
          child: Column(
            children: [
              Text(
                key: const Key('weekly_volume_range'),
                _formatWeekRange(firstDay, lastDay),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              Text(
                _relativeWeekLabel(offset),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: accents.mutedInk,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          key: const Key('weekly_volume_next_week'),
          // Disattivato e non nascosto: una freccia che sparisce fa cercare
          // dove è finita.
          onPressed: offset == 0 ? null : () => move(-1),
          icon: const Icon(Icons.chevron_right_rounded),
          tooltip: 'Settimana successiva',
        ),
      ],
    );
  }
}

class _WeekBody extends StatelessWidget {
  const _WeekBody({required this.volume});

  final WeeklyMuscleVolume volume;

  @override
  Widget build(BuildContext context) {
    final others = [
      for (final entry in volume.groups)
        if (!volume.focus.contains(entry.group)) entry,
    ];

    // Nessuna serie contata: le liste sarebbero otto zeri in fila, che
    // sembrano un difetto della schermata invece che una settimana ferma.
    // Quel che è rimasto fuori dal conteggio però si dice lo stesso — è
    // proprio il caso in cui una sessione c'è stata ma era tutta
    // riscaldamento.
    if (volume.sessions == 0) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            key: const Key('weekly_volume_empty_week'),
            'Nessuna serie contata in questi sette giorni. '
            'Con la freccia si guarda la settimana prima.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: AppAccents.of(context).mutedInk,
              height: 1.35,
            ),
          ),
          _Exclusions(volume: volume),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _LensPicker(),
        const SizedBox(height: 14),
        _Totals(volume: volume),
        const SizedBox(height: 10),
        _GroupsBlock(
          // «Che guardiamo», non «il tuo obiettivo»: quei quattro gruppi sono
          // una costante scritta nel codice, e Marco non li ha mai scelti né
          // può toglierli. Presentarli come un fatto suo significa contestargli
          // ogni settimana le spalle a zero durante un blocco gambe — per una
          // scelta che non ha fatto. Il giorno in cui il profilo avrà il campo,
          // questa riga torna a dire «il tuo obiettivo».
          title: 'I gruppi che sto guardando: braccia, spalle e addome',
          groups: volume.focusGroups,
          showSessions: true,
        ),
        if (others.isNotEmpty)
          _GroupsBlock(title: 'Gli altri gruppi', groups: others),
        _Readings(volume: volume),
        _Exclusions(volume: volume),
      ],
    );
  }
}

/// Con che lente si legge la banda. L'app propone, Marco sceglie.
class _LensPicker extends ConsumerWidget {
  const _LensPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final chosen = ref.watch(volumeIntentOverrideProvider);
    final intent = ref.watch(volumeIntentProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Leggila come',
          style: theme.textTheme.labelLarge?.copyWith(color: accents.mutedInk),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final option in VolumeIntent.values)
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: ChoiceChip(
                  key: Key('weekly_volume_intent_${option.name}'),
                  selected: option == intent,
                  // La spunta è il segnale ridondante al colore: chi non
                  // distingue il verde vede comunque quale lente è in uso.
                  showCheckmark: true,
                  label: Text('${option.label} · ${option.band.label}'),
                  onSelected: (_) =>
                      ref.read(volumeIntentOverrideProvider.notifier).state =
                          option,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          key: const Key('weekly_volume_lens_note'),
          _lensNote(intent: intent, chosenByHand: chosen != null),
          style: theme.textTheme.bodySmall?.copyWith(
            color: accents.mutedInk,
            height: 1.35,
          ),
        ),
      ],
    );
  }
}

/// Da dove viene la lente e che cosa cambia. Senza questa riga la banda che
/// si stringe cambiando fase sembrerebbe un capriccio dell'app.
String _lensNote({required VolumeIntent intent, required bool chosenByHand}) {
  final source = chosenByHand
      ? 'Lente scelta da te.'
      : 'Lente di partenza, non una tua scelta: l\'obiettivo di allenamento '
            'non si può ancora dichiarare.';
  final reason = switch (intent) {
    VolumeIntent.maintenance =>
      'Con un deficit in corso il muscolo non cresce, si difende: la banda '
          'della crescita direbbe «sotto» quasi dappertutto e chiederebbe '
          'serie che il recupero non regge.',
    VolumeIntent.growth =>
      'Fuori dal deficit la banda si alza: c\'è recupero da spendere.',
  };
  return '$source $reason';
}

class _Totals extends StatelessWidget {
  const _Totals({required this.volume});

  final WeeklyMuscleVolume volume;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    return Text(
      key: const Key('weekly_volume_totals'),
      '${_sessions(volume.sessions)} · ${_sets(volume.totalSets)} contate',
      style: theme.textTheme.bodyMedium?.copyWith(color: accents.mutedInk),
    );
  }
}

/// Un gruppo di righe con la sua intestazione.
class _GroupsBlock extends StatelessWidget {
  const _GroupsBlock({
    required this.title,
    required this.groups,
    this.showSessions = false,
  });

  final String title;
  final List<MuscleGroupVolume> groups;

  /// In quante sessioni sono arrivate le serie. Si mostra sui gruppi
  /// dell'obiettivo: dieci serie in un giorno solo e dieci spalmate su tre
  /// allenamenti sono lo stesso numero e due settimane diverse.
  final bool showSessions;

  @override
  Widget build(BuildContext context) {
    if (groups.isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Semantics(
          header: true,
          child: Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              color: accents.mutedInk,
            ),
          ),
        ),
        for (final entry in groups)
          _GroupRow(entry: entry, showSessions: showSessions),
      ],
    );
  }
}

class _GroupRow extends StatelessWidget {
  const _GroupRow({required this.entry, required this.showSessions});

  final MuscleGroupVolume entry;
  final bool showSessions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final style = MuscleGroupStyle.of(context, entry.group);
    final band = entry.band;

    return Semantics(
      // Una riga sola da leggere ad alta voce: nome, serie, sessioni e come
      // sta rispetto alla banda. A pezzi il lettore di schermo direbbe «8»
      // senza dire 8 di che cosa.
      label: _spokenRow(entry),
      child: ExcludeSemantics(
        child: Padding(
          key: Key('weekly_volume_group_${entry.group.name}'),
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(style.icon, size: 18, color: style.foreground),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      entry.group.label,
                      style: theme.textTheme.labelLarge,
                    ),
                  ),
                  Text(
                    '${entry.sets}',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w800)
                        .tabular,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'serie',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: accents.mutedInk,
                    ),
                  ),
                ],
              ),
              if (band != null) ...[
                const SizedBox(height: 6),
                _BandTrack(band: band, sets: entry.sets, status: entry.status),
              ],
              if (band == null || (showSessions && entry.sessions > 0)) ...[
                const SizedBox(height: 4),
                Text(
                  band == null
                      // Cardio, mobilità e full body si contano ma non si
                      // giudicano: dare loro una banda inviterebbe a
                      // riempirla.
                      ? VolumeBandStatus.unbanded.label.toLowerCase()
                      : 'in ${_sessions(entry.sessions)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: accents.mutedInk,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Il binario con la banda larga e il segno del valore.
///
/// Non è una barra che si riempie: una barra racconta «quanto manca al
/// pieno», e qui il pieno non esiste — sopra la banda si spende recupero che
/// in deficit non c'è. Il colore del segno non è mai da solo: lo stesso stato
/// è scritto a parole nelle righe sotto e nella lettura ad alta voce.
class _BandTrack extends StatelessWidget {
  const _BandTrack({
    required this.band,
    required this.sets,
    required this.status,
  });

  final WeeklyVolumeBand band;
  final int sets;
  final VolumeBandStatus status;

  static const double _height = 12;
  static const double _markerWidth = 4;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accents = AppAccents.of(context);
    // Metà banda di margine oltre l'estremo alto: senza, una settimana dentro
    // la banda finirebbe schiacciata contro il bordo destro e sembrerebbe già
    // fuori. Se le serie superano anche quello, è il valore a dettare la
    // scala.
    final scale = math.max(band.highSets * 1.5, sets.toDouble());

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        double at(num value) => scale <= 0 ? 0 : width * value / scale;
        final start = at(band.lowSets);
        final end = at(band.highSets);

        return SizedBox(
          height: _height,
          child: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(_height / 2),
                  ),
                ),
              ),
              Positioned(
                left: start,
                width: math.max(end - start, _markerWidth),
                top: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: accents.positiveSurface,
                    borderRadius: BorderRadius.circular(_height / 2),
                  ),
                ),
              ),
              Positioned(
                // A zero il segno resta appoggiato al bordo sinistro: un
                // gruppo vuoto deve vedersi, non sparire fuori dal binario.
                left: (at(sets) - _markerWidth / 2).clamp(
                  0,
                  math.max(width - _markerWidth, 0),
                ),
                width: _markerWidth,
                top: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: status == VolumeBandStatus.inside
                        ? accents.positive
                        : accents.warning,
                    borderRadius: BorderRadius.circular(_markerWidth / 2),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Le frasi che leggono i numeri. Descrivono, non rimproverano.
class _Readings extends StatelessWidget {
  const _Readings({required this.volume});

  final WeeklyMuscleVolume volume;

  @override
  Widget build(BuildContext context) {
    final empty = volume.emptyBandedGroups;
    // I vuoti si dicono in due frasi diverse, e non è un vezzo: petto e gambe
    // a zero in una settimana di braccia sono una scheda che fa il suo
    // mestiere, un gruppo dell'obiettivo a zero è la domanda per cui questa
    // card esiste. Nominarli insieme farebbe sparire la seconda dentro la
    // prima.
    final emptyFocus = [
      for (final entry in empty)
        if (volume.focus.contains(entry.group)) entry,
    ];
    final emptyOthers = [
      for (final entry in empty)
        if (!volume.focus.contains(entry.group)) entry,
    ];
    final below = volume.belowBand;
    final above = [
      for (final entry in volume.groups)
        if (entry.status == VolumeBandStatus.above) entry,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (emptyFocus.isNotEmpty)
          _Note(
            noteKey: const Key('weekly_volume_empty_focus'),
            icon: Icons.error_outline_rounded,
            emphasis: true,
            text:
                'Niente sull\'obiettivo: ${_names(emptyFocus)} '
                '${emptyFocus.length == 1 ? 'è rimasto' : 'sono rimasti'} a '
                'zero. Un gruppo a zero di solito è un esercizio saltato o '
                'escluso, non una scheda leggera.',
          ),
        if (emptyOthers.isNotEmpty)
          _Note(
            noteKey: const Key('weekly_volume_empty_others'),
            icon: Icons.remove_circle_outline_rounded,
            text:
                'Fuori dall\'obiettivo restano a zero: ${_names(emptyOthers)}.',
          ),
        // La frase della banda arriva dal dominio parola per parola: è lì che
        // sta scritto che cosa significa stare sotto o sopra, e riscriverla
        // qui vorrebbe dire avere due versioni della stessa regola.
        if (below.isNotEmpty)
          _Note(
            noteKey: const Key('weekly_volume_below_groups'),
            icon: Icons.trending_down_rounded,
            emphasis: true,
            text:
                '${_names(below)}: poche serie. '
                '${volume.intent.readingOf(VolumeBandStatus.below)}',
          ),
        if (above.isNotEmpty)
          _Note(
            noteKey: const Key('weekly_volume_above_groups'),
            icon: Icons.trending_up_rounded,
            text:
                '${_names(above)}: tante serie. '
                '${volume.intent.readingOf(VolumeBandStatus.above)}',
          ),
        if (empty.isEmpty && below.isEmpty)
          _Note(
            noteKey: const Key('weekly_volume_all_inside'),
            icon: Icons.check_circle_outline_rounded,
            text:
                'Nessun gruppo con banda è rimasto sotto. '
                '${volume.intent.readingOf(VolumeBandStatus.inside)}',
          ),
      ],
    );
  }
}

/// Che cosa è rimasto fuori dal conteggio.
///
/// Si dichiara sempre quando c'è: un gruppo può sembrare vuoto solo perché a
/// una riga manca il gruppo muscolare, e tacerlo trasformerebbe un dato
/// mancante in una diagnosi sbagliata.
class _Exclusions extends StatelessWidget {
  const _Exclusions({required this.volume});

  final WeeklyMuscleVolume volume;

  @override
  Widget build(BuildContext context) {
    if (!volume.hasExclusions) {
      return const SizedBox.shrink();
    }

    final parts = <String>[
      if (volume.warmupAndCooldownSets > 0)
        '${_sets(volume.warmupAndCooldownSets)} fra riscaldamento e '
            'defaticamento, che sono lavoro ma non stimolo',
      if (volume.setsWithoutMuscleGroup > 0)
        '${_sets(volume.setsWithoutMuscleGroup)} su righe senza gruppo '
            'muscolare, che non stanno in nessun gruppo qui sopra',
    ];

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(),
          _Note(
            noteKey: const Key('weekly_volume_exclusions'),
            icon: Icons.filter_alt_off_rounded,
            text: 'Fuori dal conteggio: ${parts.join('; ')}.',
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({
    required this.noteKey,
    required this.icon,
    required this.text,
    this.emphasis = false,
  });

  final Key noteKey;
  final IconData icon;
  final String text;

  /// Alza il tono di un grado: il colore d'attenzione invece del grigio. Le
  /// parole restano le stesse — è il testo a dire la cosa, non la tinta.
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final color = emphasis ? accents.warning : accents.mutedInk;

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              key: noteKey,
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: color,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CountFailed extends StatelessWidget {
  const _CountFailed({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          key: const Key('weekly_volume_error'),
          'Non riesco a contare le serie di questa settimana: le sessioni '
          'non si leggono dall\'archivio locale.',
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const Key('weekly_volume_retry'),
            onPressed: onRetry,
            child: const Text('Riprova'),
          ),
        ),
      ],
    );
  }
}

/// Come si legge una riga ad alta voce.
String _spokenRow(MuscleGroupVolume entry) {
  final band = entry.band;
  final sessions = entry.sessions == 0
      ? ''
      : ', in ${_sessions(entry.sessions)}';
  final reference = band == null
      ? 'senza banda di riferimento'
      : '${entry.status.label.toLowerCase()} di ${band.label}';
  return '${entry.group.label}: ${_sets(entry.sets)}$sessions. $reference.';
}

/// «Spalle», «Spalle e Addome», «Spalle, Bicipiti e Addome».
String _names(List<MuscleGroupVolume> groups) {
  final labels = [for (final entry in groups) entry.group.label];
  if (labels.length == 1) {
    return labels.single;
  }
  return '${labels.sublist(0, labels.length - 1).join(', ')} e ${labels.last}';
}

/// «Serie» è invariabile, «sessione» no: il plurale sbagliato in una frase
/// che deve suonare naturale si nota più di un numero storto.
String _sets(int count) => '$count serie';

String _sessions(int count) => count == 1 ? '1 sessione' : '$count sessioni';

/// «3 – 9 agosto», «31 agosto – 6 settembre».
///
/// I due estremi sono etichette di giorno (mezzanotte UTC), non istanti:
/// passarli per il fuso di Roma li sposterebbe indietro di due ore, cioè al
/// giorno prima.
String _formatWeekRange(DateTime firstDay, DateTime lastDay) {
  final month = DateFormat('MMMM', 'it');
  final opening = firstDay.month == lastDay.month
      ? '${firstDay.day}'
      : '${firstDay.day} ${month.format(firstDay)}';
  return '$opening – ${lastDay.day} ${month.format(lastDay)}';
}

String _relativeWeekLabel(int offset) => switch (offset) {
  0 => 'Questa settimana',
  1 => 'Settimana scorsa',
  _ => '$offset settimane fa',
};
