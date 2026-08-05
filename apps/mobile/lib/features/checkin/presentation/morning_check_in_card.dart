import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/body/presentation/body_formats.dart';
import 'package:kal_tracker/features/checkin/domain/daily_check_in.dart';
import 'package:kal_tracker/features/checkin/presentation/check_in_providers.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/goal/domain/body_state.dart';

/// Il check-in del mattino: peso, sonno, energia. Dieci secondi.
///
/// Il peso non si inserisce qui — si mostra se la pesata di oggi c'è già e
/// altrimenti si invita a farla, aprendo il foglio della schermata Corpo. È
/// una sola strada per una sola tabella: due punti d'inserimento del peso
/// diventerebbero due storici che non tornano.
///
/// Sonno ed energia si salvano al tocco, senza pulsante «Salva»: un modulo
/// da dieci secondi non può chiederne uno in più. Quando ci sono tutti e
/// due, la card si richiude in una riga di riepilogo — quello che non serve
/// adesso non deve occupare mezzo schermo.
class MorningCheckInCard extends ConsumerStatefulWidget {
  const MorningCheckInCard({required this.onWeighIn, super.key});

  /// Apre il foglio della pesata. Arriva da fuori perché la pesata è di
  /// un'altra schermata: la card sa che serve, non come si fa.
  final VoidCallback onWeighIn;

  @override
  ConsumerState<MorningCheckInCard> createState() => _MorningCheckInCardState();
}

class _MorningCheckInCardState extends ConsumerState<MorningCheckInCard> {
  /// Vero quando Marco ha toccato «Modifica» su un check-in già completo.
  bool _reopened = false;

  @override
  Widget build(BuildContext context) {
    final today = ref.watch(todayProvider);
    final checkIn = ref.watch(todayCheckInProvider).valueOrNull;
    final weighIn = ref.watch(todayWeighInProvider).valueOrNull;
    final complete = checkIn?.isComplete ?? false;
    final collapsed = complete && !_reopened;

    return SectionCard(
      key: const Key('morning_check_in_card'),
      title: 'Check-in di oggi',
      subtitle: collapsed
          ? 'Fatto. Sonno ed energia entrano nelle tendenze della settimana.'
          : 'Dieci secondi: quanto hai dormito e come ti senti.',
      icon: Icons.wb_twilight_rounded,
      actionLabel: collapsed ? 'Modifica' : null,
      onAction: collapsed ? () => setState(() => _reopened = true) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _WeightRow(weighIn: weighIn, onWeighIn: widget.onWeighIn),
          if (collapsed)
            _CheckInSummary(checkIn: checkIn!)
          else ...[
            const Divider(height: 26),
            _SleepStepper(
              hours: checkIn?.sleepHours,
              onChanged: (value) => ref
                  .read(checkInControllerProvider.notifier)
                  .setSleepHours(today, value),
            ),
            const SizedBox(height: 14),
            _EnergyPicker(
              score: checkIn?.energyScore,
              onChanged: (value) => ref
                  .read(checkInControllerProvider.notifier)
                  .setEnergy(today, value),
            ),
          ],
        ],
      ),
    );
  }
}

/// Il peso di oggi, se c'è. Altrimenti l'invito, non un buco.
class _WeightRow extends StatelessWidget {
  const _WeightRow({required this.weighIn, required this.onWeighIn});

  final WeightPoint? weighIn;
  final VoidCallback onWeighIn;

  @override
  Widget build(BuildContext context) {
    final point = weighIn;
    if (point == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppEmptyState(
            key: Key('check_in_weight_missing'),
            compact: true,
            icon: Icons.monitor_weight_outlined,
            message: 'Non ti sei ancora pesato oggi.',
          ),
          const SizedBox(height: 10),
          // Il pulsante sta fuori dallo stato vuoto e non dentro: a testo
          // molto ingrandito una card con il bottone incastonato diventa
          // illeggibile prima di diventare intoccabile.
          OutlinedButton.icon(
            key: const Key('check_in_weigh_in_button'),
            onPressed: onWeighIn,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Registra la pesata'),
          ),
        ],
      );
    }
    return StatRow(
      key: const Key('check_in_weight'),
      label: 'Peso di oggi',
      value: BodyFormats.kg(point.weightKg),
      unit: 'kg',
      unitSemantics: 'chilogrammi',
      caption: point.hasComposition
          ? 'con composizione, ${BodyFormats.stamp(point.at)}'
          : 'solo peso, ${BodyFormats.stamp(point.at)}',
      icon: Icons.monitor_weight_outlined,
    );
  }
}

/// Riepilogo di un check-in già compilato: una riga, non tre controlli.
class _CheckInSummary extends StatelessWidget {
  const _CheckInSummary({required this.checkIn});

  final DailyCheckIn checkIn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final sleep = checkIn.sleepHours;
    final energy = checkIn.energy;

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Semantics(
        container: true,
        label: [
          if (sleep != null) '${_sleepText(sleep)} di sonno',
          if (energy != null) 'energia ${energy.score} su 5, ${energy.label}',
        ].join(', '),
        child: ExcludeSemantics(
          child: Row(
            key: const Key('check_in_summary'),
            children: [
              Icon(Icons.bedtime_outlined, size: 18, color: accents.mutedInk),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  [
                    if (sleep != null) _sleepText(sleep),
                    if (energy != null) 'energia ${energy.score}/5',
                  ].join(' · '),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Le ore di sonno, a mezz'ore, senza tastiera.
///
/// Il passo da mezz'ora è deliberato: al minuto sarebbe finta precisione su
/// un numero che si legge a occhio dall'orologio (i dati dell'orologio Huawei
/// entrano qui a mano — scelta di Marco, niente ponti di terze parti).
class _SleepStepper extends StatelessWidget {
  const _SleepStepper({required this.hours, required this.onChanged});

  final double? hours;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final value = hours ?? DailyCheckIn.defaultSleepHours;
    final canDecrease = value > DailyCheckIn.minSleepHours;
    final canIncrease = value < DailyCheckIn.maxSleepHours;

    return Semantics(
      container: true,
      label: 'Ore di sonno',
      value: hours == null ? 'da inserire' : _sleepText(hours!),
      child: Row(
        children: [
          Expanded(
            child: ExcludeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Sonno',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: accents.mutedInk,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hours == null ? 'da inserire' : _sleepText(hours!),
                    key: const Key('check_in_sleep_value'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: hours == null
                          ? accents.mutedInk
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton.outlined(
            key: const Key('check_in_sleep_minus'),
            tooltip: 'Mezz\'ora in meno',
            onPressed: canDecrease
                ? () => onChanged(value - DailyCheckIn.sleepStepHours)
                : null,
            icon: const Icon(Icons.remove_rounded),
          ),
          const SizedBox(width: 8),
          IconButton.outlined(
            key: const Key('check_in_sleep_plus'),
            tooltip: 'Mezz\'ora in più',
            onPressed: canIncrease
                // Il primo tocco vale come «inserisci»: senza un valore
                // precedente si parte dalle 7,5 h invece che da zero, così
                // il check-in resta di dieci secondi anche la prima volta.
                ? () => onChanged(
                    hours == null ? value : value + DailyCheckIn.sleepStepHours,
                  )
                : null,
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
    );
  }
}

/// L'energia percepita, 1-5. Cinque bersagli, un tocco.
class _EnergyPicker extends StatelessWidget {
  const _EnergyPicker({required this.score, required this.onChanged});

  final int? score;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final selected = EnergyLevel.fromScore(score);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Energia',
          style: theme.textTheme.labelLarge?.copyWith(color: accents.mutedInk),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final level in EnergyLevel.values)
              ChoiceChip(
                key: Key('check_in_energy_${level.score}'),
                selected: level == selected,
                onSelected: (_) => onChanged(level.score),
                label: Text('${level.score}'),
                // Il numero da solo non dice niente ad alta voce: qui si
                // legge per esteso.
                tooltip: level.label,
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          selected == null
              ? '1 è scarico, 5 è carico.'
              : '${selected.score}: ${selected.label.toLowerCase()}.',
          key: const Key('check_in_energy_label'),
          style: theme.textTheme.bodySmall?.copyWith(color: accents.mutedInk),
        ),
      ],
    );
  }
}

final _hours = NumberFormat('#,##0.#', 'it');

String _sleepText(double hours) => '${_hours.format(hours)} h';
