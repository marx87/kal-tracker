import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/body/presentation/body_formats.dart';
import 'package:kal_tracker/features/checkin/domain/daily_check_in.dart';
import 'package:kal_tracker/features/checkin/presentation/check_in_providers.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';
import 'package:kal_tracker/features/goal/domain/body_state.dart';

/// Il check-in del mattino: peso, sonno, energia, movimento. Dieci secondi.
///
/// Il peso non si inserisce qui — si mostra se la pesata di oggi c'è già e
/// altrimenti si invita a farla, aprendo il foglio della schermata Corpo. È
/// una sola strada per una sola tabella: due punti d'inserimento del peso
/// diventerebbero due storici che non tornano.
///
/// Tutto si salva al tocco, senza pulsante «Salva»: un modulo da dieci
/// secondi non può chiederne uno in più. Quello che è già stato risposto si
/// richiude in una riga di riepilogo — quello che non serve adesso non deve
/// occupare mezzo schermo — e resta fuori solo la domanda ancora aperta.
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
    // Il movimento sopravvive al richiudersi finché non c'è. È la domanda che
    // riguarda ieri e non stamattina, e se sparisse insieme a sonno ed
    // energia resterebbe vuota tutti i giorni: nessuno riapre una card per
    // rispondere a una cosa che non sa di dover rispondere.
    final showNeat = !collapsed || !(checkIn?.hasNeat ?? false);

    return SectionCard(
      key: const Key('morning_check_in_card'),
      title: 'Check-in di oggi',
      subtitle: switch ((collapsed, showNeat)) {
        (true, true) => 'Manca solo quanto ti sei mosso.',
        (true, false) =>
          'Fatto. Sonno, energia e movimento entrano nelle tendenze della '
              'settimana.',
        _ =>
          'Dieci secondi: quanto hai dormito, come ti senti, quanto ti sei '
              'mosso.',
      },
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
          if (showNeat) ...[
            const Divider(height: 26),
            _NeatSection(checkIn: checkIn, day: today),
          ],
        ],
      ),
    );
  }
}

/// **Il movimento della giornata: passi, minuti a piedi, o lo zero.**
///
/// Sta nel check-in del mattino e non in una schermata sua perché è il campo
/// che nessuno compilerebbe mai andandolo a cercare, ed è quello che spiega i
/// plateau: quando il consumo misurato cala, la risposta è quasi sempre qui e
/// non nel piatto.
class _NeatSection extends ConsumerWidget {
  const _NeatSection({required this.checkIn, required this.day});

  final DailyCheckIn? checkIn;
  final DateTime day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final entry = checkIn;
    final steps = entry?.steps;
    final walk = entry?.walkMinutes;
    final still = steps == 0 && walk == 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Movimento',
          style: theme.textTheme.labelLarge?.copyWith(color: accents.mutedInk),
        ),
        const SizedBox(height: 8),
        // Lo zero deve costare un tocco solo. Scendere di mille passi alla
        // volta fino a zero vuol dire non arrivarci mai, e un giorno fermo
        // non segnato è indistinguibile da un giorno non compilato: è
        // esattamente il buco che rende invisibile il crollo del NEAT.
        FilterChip(
          key: const Key('check_in_neat_still'),
          selected: still,
          onSelected: (value) => ref
              .read(checkInControllerProvider.notifier)
              .setStillDay(day, clear: !value),
          avatar: const Icon(Icons.chair_outlined, size: 18),
          label: const Text('Giornata ferma'),
        ),
        const SizedBox(height: 12),
        _ValueStepper(
          label: 'Passi',
          semanticsLabel: 'Passi del giorno',
          text: steps == null ? null : _integer.format(steps),
          valueKey: const Key('check_in_steps_value'),
          minusKey: const Key('check_in_steps_minus'),
          plusKey: const Key('check_in_steps_plus'),
          minusTooltip: 'Mille passi in meno',
          plusTooltip: 'Mille passi in più',
          onMinus: steps == null || steps > DailyCheckIn.minSteps
              ? () => ref
                    .read(checkInControllerProvider.notifier)
                    .setSteps(
                      day,
                      (steps ?? DailyCheckIn.defaultSteps) -
                          DailyCheckIn.stepsStep,
                    )
              : null,
          onPlus: steps == null || steps < DailyCheckIn.maxSteps
              // Il primo tocco vale come «inserisci»: si parte dai seimila
              // invece che da mille, così il check-in resta corto anche la
              // prima volta. Stessa regola del sonno.
              ? () => ref
                    .read(checkInControllerProvider.notifier)
                    .setSteps(
                      day,
                      steps == null
                          ? DailyCheckIn.defaultSteps
                          : steps + DailyCheckIn.stepsStep,
                    )
              : null,
        ),
        const SizedBox(height: 10),
        _ValueStepper(
          label: 'A piedi',
          semanticsLabel: 'Minuti a piedi',
          text: walk == null ? null : '$walk min',
          valueKey: const Key('check_in_walk_value'),
          minusKey: const Key('check_in_walk_minus'),
          plusKey: const Key('check_in_walk_plus'),
          minusTooltip: 'Dieci minuti in meno',
          plusTooltip: 'Dieci minuti in più',
          onMinus: walk == null || walk > DailyCheckIn.minWalkMinutes
              ? () => ref
                    .read(checkInControllerProvider.notifier)
                    .setWalkMinutes(
                      day,
                      (walk ?? DailyCheckIn.defaultWalkMinutes) -
                          DailyCheckIn.walkStepMinutes,
                    )
              : null,
          onPlus: walk == null || walk < DailyCheckIn.maxWalkMinutes
              ? () => ref
                    .read(checkInControllerProvider.notifier)
                    .setWalkMinutes(
                      day,
                      walk == null
                          ? DailyCheckIn.defaultWalkMinutes
                          : walk + DailyCheckIn.walkStepMinutes,
                    )
              : null,
        ),
        const SizedBox(height: 8),
        Text(
          // Le due cose che questo campo NON è. La prima perché il consumo
          // misurato include già il movimento e rimangiarselo lo conterebbe
          // due volte; la seconda perché senza gli zeri la media settimanale
          // si fa solo sui giorni buoni e il crollo sparisce.
          'Non diventano calorie da mangiare: servono a spiegare i cali del '
          'consumo. Segna anche i giorni fermi.',
          key: const Key('check_in_neat_caption'),
          style: theme.textTheme.bodySmall?.copyWith(color: accents.mutedInk),
        ),
      ],
    );
  }
}

/// Una riga «etichetta, valore, meno e più».
///
/// Stessa forma per sonno, passi e minuti: sono tre numeri che si muovono a
/// gradini, e tre controlli diversi per la stessa gestualità costringerebbero
/// a rileggere la card ogni mattina.
class _ValueStepper extends StatelessWidget {
  const _ValueStepper({
    required this.label,
    required this.semanticsLabel,
    required this.text,
    required this.valueKey,
    required this.minusKey,
    required this.plusKey,
    required this.minusTooltip,
    required this.plusTooltip,
    required this.onMinus,
    required this.onPlus,
  });

  final String label;
  final String semanticsLabel;

  /// Nullo quando il valore non c'è ancora: la riga lo dice a parole invece
  /// di mostrare uno zero che sembrerebbe una risposta.
  final String? text;

  final Key valueKey;
  final Key minusKey;
  final Key plusKey;
  final String minusTooltip;
  final String plusTooltip;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final value = text ?? _missing;

    return Semantics(
      container: true,
      label: semanticsLabel,
      value: value,
      child: Row(
        children: [
          Expanded(
            child: ExcludeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: accents.mutedInk,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    key: valueKey,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: text == null
                          ? accents.mutedInk
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton.outlined(
            key: minusKey,
            tooltip: minusTooltip,
            onPressed: onMinus,
            icon: const Icon(Icons.remove_rounded),
          ),
          const SizedBox(width: 8),
          IconButton.outlined(
            key: plusKey,
            tooltip: plusTooltip,
            onPressed: onPlus,
            icon: const Icon(Icons.add_rounded),
          ),
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
    final neat = _neatText(checkIn);

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Semantics(
        container: true,
        label: [
          if (sleep != null) '${_sleepText(sleep)} di sonno',
          if (energy != null) 'energia ${energy.score} su 5, ${energy.label}',
          ?neat,
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
                    ?neat,
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
    final value = hours ?? DailyCheckIn.defaultSleepHours;

    return _ValueStepper(
      label: 'Sonno',
      semanticsLabel: 'Ore di sonno',
      text: hours == null ? null : _sleepText(hours!),
      valueKey: const Key('check_in_sleep_value'),
      minusKey: const Key('check_in_sleep_minus'),
      plusKey: const Key('check_in_sleep_plus'),
      minusTooltip: 'Mezz\'ora in meno',
      plusTooltip: 'Mezz\'ora in più',
      onMinus: value > DailyCheckIn.minSleepHours
          ? () => onChanged(value - DailyCheckIn.sleepStepHours)
          : null,
      onPlus: value < DailyCheckIn.maxSleepHours
          // Il primo tocco vale come «inserisci»: senza un valore precedente
          // si parte dalle 7,5 h invece che da zero, così il check-in resta di
          // dieci secondi anche la prima volta.
          ? () => onChanged(
              hours == null ? value : value + DailyCheckIn.sleepStepHours,
            )
          : null,
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
final _integer = NumberFormat('#,##0', 'it');

/// Il testo mostrato quando un valore non c'è ancora. **Non uno zero**: qui
/// lo zero è una risposta, e scriverlo al posto del vuoto farebbe passare
/// per «giornata ferma» un campo che nessuno ha toccato.
const String _missing = 'da inserire';

String _sleepText(double hours) => '${_hours.format(hours)} h';

/// Il movimento in una manciata di caratteri, per la riga di riepilogo.
String? _neatText(DailyCheckIn checkIn) {
  final steps = checkIn.steps;
  final walk = checkIn.walkMinutes;
  if (steps == 0 && walk == 0) {
    return 'giornata ferma';
  }
  final parts = [
    if (steps != null) '${_integer.format(steps)} passi',
    if (walk != null) '$walk min a piedi',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}
