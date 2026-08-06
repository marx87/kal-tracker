import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/features/body/data/scale_link.dart';
import 'package:kal_tracker/features/body/domain/bia_formula.dart';
import 'package:kal_tracker/features/body/domain/scale_log.dart';
import 'package:kal_tracker/features/body/domain/scale_session.dart';
import 'package:kal_tracker/features/body/presentation/body_formats.dart';
import 'package:kal_tracker/features/body/presentation/body_providers.dart';
import 'package:kal_tracker/features/body/presentation/scale_providers.dart';
import 'package:kal_tracker/features/diary/presentation/diary_providers.dart';

/// La pesata dalla bilancia Renpho, letta direttamente via Bluetooth.
///
/// La schermata fa tre cose e nessun'altra: **dice a che punto siamo** in modo
/// che si capisca cosa fare, **mostra cosa è stato letto** prima di salvarlo,
/// e **tiene il registro di bordo** della sessione.
///
/// Il registro non è un lusso da sviluppatore. Questa funzione non si è potuta
/// provare su una bilancia vera: il primo tentativo di Marco sarà anche il
/// primo collaudo, e quando qualcosa non funzionerà l'unica cosa che resterà
/// sarà quell'elenco di trame. Per questo è in schermata e si copia con un
/// tocco.
class ScaleScreen extends ConsumerWidget {
  const ScaleScreen({super.key});

  /// Nome della rotta che l'integratore collegherà nel router.
  static const routeName = 'scale';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final status = ref.watch(scaleSessionProvider);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Bilancia'),
            Text(
              'Pesata via Bluetooth, senza l’app Renpho',
              style: theme.textTheme.bodySmall?.copyWith(
                color: accents.mutedInk,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
      body: ListView(
        key: const Key('scale_scroll'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _StatusCard(status: status),
          const SizedBox(height: 14),
          // L'elenco resta anche dopo un guasto, ed è una correzione: prima
          // spariva al primo tocco e non tornava più. Chi sbagliava riga si
          // ritrovava con quel dispositivo salvato come «la mia bilancia»,
          // quarantacinque secondi di attesa, e poi un «Cerca di nuovo» che lo
          // riportava dritto sullo stesso errore — senza mai rivedere
          // l'elenco. La via d'uscita da una scelta sbagliata dev'essere lì
          // dove la scelta è stata fatta.
          if (status.candidates.isNotEmpty && status.phase.canChooseDevice) ...[
            _DevicePickerCard(status: status),
            const SizedBox(height: 14),
          ],
          if (status.reading case final reading?) ...[
            _ReadingCard(reading: reading, status: status),
            const SizedBox(height: 14),
          ],
          const _HonestyCard(),
          const SizedBox(height: 14),
          const _RecalculationCard(),
          const SizedBox(height: 14),
          _LogCard(log: status.log),
        ],
      ),
    );
  }
}

/// La card che risponde alla domanda «e adesso?».
class _StatusCard extends ConsumerWidget {
  const _StatusCard({required this.status});

  final ScaleStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final phase = status.phase;

    return SectionCard(
      title: 'Stato',
      icon: Icons.bluetooth_searching_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  status.title,
                  key: const Key('scale_status_title'),
                  style: theme.textTheme.titleMedium,
                ),
              ),
              const SizedBox(width: 8),
              StatusChip(
                level: switch (phase.tone) {
                  ScaleTone.good => AppStatusLevel.good,
                  ScaleTone.warning => AppStatusLevel.warning,
                  ScaleTone.critical => AppStatusLevel.critical,
                  ScaleTone.working => AppStatusLevel.good,
                },
                label: switch (phase.tone) {
                  ScaleTone.working => 'In corso',
                  ScaleTone.good => 'Fatto',
                  ScaleTone.warning => 'Da sistemare',
                  ScaleTone.critical => 'Interrotto',
                },
                compact: true,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            status.detail,
            key: const Key('scale_status_detail'),
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
          ),
          if (status.errorDetail case final detail?) ...[
            const SizedBox(height: 8),
            Text(
              detail,
              key: const Key('scale_status_error'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: accents.mutedInk,
                height: 1.35,
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (status.isBusy)
            const Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
                SizedBox(width: 12),
                Expanded(child: Text('Sto lavorando…')),
              ],
            )
          else
            FilledButton.icon(
              key: const Key('scale_start_button'),
              onPressed: phase.canRetry || phase == ScalePhase.idle
                  ? () => ref.read(scaleSessionProvider.notifier).start()
                  : null,
              icon: const Icon(Icons.bluetooth_rounded),
              label: Text(
                phase == ScalePhase.idle
                    ? 'Cerca la bilancia'
                    : 'Cerca di nuovo',
              ),
            ),
          // Non mentre si sta chiedendo quale sia: «vado dritto su X» e «non
          // l'ho riconosciuta, dimmi qual è» nello stesso riquadro sono due
          // frasi che si smentiscono a vicenda. Se siamo arrivati a chiedere,
          // vuol dire che quella ricordata oggi non si è fatta vedere — e
          // dirlo è compito della card dell'elenco, non di questa riga.
          if (ref.watch(rememberedScaleProvider).valueOrNull
              case final remembered?
              when status.phase != ScalePhase.chooseDevice) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  Icons.push_pin_outlined,
                  size: 16,
                  color: accents.mutedInk,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Vado dritto su ${remembered.label}',
                    key: const Key('scale_remembered_note'),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: accents.mutedInk,
                    ),
                  ),
                ),
                TextButton(
                  key: const Key('scale_forget_button'),
                  onPressed: () =>
                      ref.read(scaleSessionProvider.notifier).forget(),
                  child: const Text('Dimentica'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// L'elenco dei dispositivi visti, da cui scegliere a mano.
///
/// È la via d'uscita da un problema che non si può risolvere indovinando:
/// riconoscere una bilancia dal suo annuncio Bluetooth è un'euristica, le
/// bilance sono decine di modelli e molte non dichiarano niente di
/// riconoscibile. Chi invece sa con certezza qual è la bilancia è la persona
/// che ci sta sopra. Le si chiede, una volta sola, e non si torna sull'argomento.
class _DevicePickerCard extends ConsumerWidget {
  const _DevicePickerCard({required this.status});

  final ScaleStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final scanning = status.phase == ScalePhase.scanning;
    final dopoUnGuasto = status.phase == ScalePhase.failed;

    return SectionCard(
      key: const Key('scale_picker_card'),
      title: dopoUnGuasto
          ? 'Non era quella?'
          : (scanning ? 'Visti finora' : 'Dispositivi visti'),
      subtitle: scanning
          ? 'Tocca la tua bilancia appena compare'
          : '${status.candidates.length} in tutto',
      icon: Icons.list_alt_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            switch (status.phase) {
              ScalePhase.scanning =>
                'Se la riconosco vado avanti da solo. Se la vedi tu prima, '
                    'non aspettarmi.',
              ScalePhase.failed =>
                'Scegline un’altra: quella che tocchi prende il posto della '
                    'precedente, senza passare da «Dimentica».',
              // L'ordine è quello di comparsa, e vale la pena dirlo: la
              // bilancia si annuncia solo mentre misura, quindi è comparsa
              // proprio mentre lui ci saliva — è l'ultima, non la prima.
              _ =>
                'Nessuno di questi si dichiara bilancia, ma uno di loro '
                    'probabilmente lo è. Sono in ordine di comparsa: la tua è '
                    'quella spuntata mentre ci salivi sopra, quindi guarda in '
                    'fondo.',
            },
            style: theme.textTheme.bodySmall?.copyWith(
              color: accents.mutedInk,
              height: 1.35,
            ),
          ),
          // Se una bilancia era già stata scelta e oggi non è comparsa, va
          // detto qui: altrimenti la domanda «quale di questi è la bilancia?»
          // sembra un ripensamento, e chi risponde sovrascrive senza saperlo
          // una scelta che andava benissimo.
          if (ref.watch(rememberedScaleProvider).valueOrNull
              case final remembered?
              when status.phase == ScalePhase.chooseDevice) ...[
            const SizedBox(height: 8),
            Text(
              '${remembered.label} non si è fatta vedere: forse sei sceso '
              'troppo presto. Riprova prima di cambiare — quella che tocchi '
              'prende il suo posto.',
              key: const Key('scale_remembered_absent'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: accents.info,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 6),
          for (final device in status.candidates)
            ListTile(
              key: Key('scale_candidate_${device.id}'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                device.knownToSystem
                    ? Icons.link_rounded
                    : Icons.bluetooth_rounded,
                color: accents.mutedInk,
              ),
              title: Text(
                device.name.isEmpty ? 'Senza nome' : device.name,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontStyle: device.name.isEmpty ? FontStyle.italic : null,
                ),
              ),
              subtitle: Text(
                _sottotitolo(device),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: accents.mutedInk,
                ),
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _choose(context, ref, device),
            ),
        ],
      ),
    );
  }

  /// Quel poco che si sa del dispositivo, e che aiuta a riconoscerlo:
  /// l'indirizzo, quanto arriva forte, e se ha annunciato qualcosa.
  static String _sottotitolo(ScaleDevice device) {
    final parti = <String>[device.id];
    if (device.rssi != 0) {
      parti.add('${device.rssi} dBm');
    }
    if (device.manufacturerData.isNotEmpty) {
      parti.add('dati costruttore');
    }
    if (device.knownToSystem) {
      parti.add('già accoppiato');
    }
    return parti.join(' · ');
  }

  Future<void> _choose(
    BuildContext context,
    WidgetRef ref,
    ScaleDevice device,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(scaleSessionProvider.notifier).choose(device);
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Non riesco a collegarmi: $error')),
      );
    }
  }
}

/// Quello che la bilancia ha letto, e quello che la formula ne ricava.
class _ReadingCard extends ConsumerWidget {
  const _ReadingCard({required this.reading, required this.status});

  final ScaleReading reading;
  final ScaleStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final preview = ref.watch(scalePreviewProvider);
    final saved = status.phase == ScalePhase.saved;

    return SectionCard(
      title: 'Pesata letta',
      subtitle: BodyFormats.stamp(reading.measuredAt),
      icon: Icons.monitor_weight_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StatRow(
            key: const Key('scale_weight_row'),
            label: 'Peso',
            value: BodyFormats.kg(reading.weightKg),
            unit: 'kg',
            unitSemantics: 'chilogrammi',
          ),
          const SizedBox(height: 10),
          StatRow(
            key: const Key('scale_impedance_row'),
            label: 'Impedenza',
            value: reading.hasImpedance
                ? BodyFormats.kg(reading.impedanceOhm!)
                : '—',
            unit: reading.hasImpedance ? 'Ω' : null,
            unitSemantics: reading.hasImpedance ? 'ohm' : null,
            caption: reading.hasImpedance
                ? 'L’unica cosa che la bilancia misura davvero.'
                : 'Elettrodi senza contatto: resta una pesata di solo peso.',
          ),
          const SizedBox(height: 14),
          preview.when(
            data: (value) => _CompositionBlock(preview: value),
            loading: () => const LinearProgressIndicator(),
            error: (error, _) => Text(
              'Non riesco a leggere il profilo: $error',
              style: theme.textTheme.bodySmall?.copyWith(
                color: accents.critical,
              ),
            ),
          ),
          const SizedBox(height: 18),
          if (saved)
            Row(
              children: [
                Icon(Icons.check_circle_rounded, color: accents.positive),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Salvata. Entra nelle medie a 7 giorni.',
                    key: const Key('scale_saved_note'),
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            )
          else
            FilledButton.icon(
              key: const Key('scale_save_button'),
              onPressed: () => _save(context, ref),
              icon: const Icon(Icons.check_rounded),
              label: const Text('Salva la pesata'),
            ),
        ],
      ),
    );
  }

  Future<void> _save(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(scaleSessionProvider.notifier).save();
      // Il ricalcolo pendente può essere cambiato: una pesata nuova con la
      // formula corrente non ne aggiunge, ma il conteggio va comunque riletto.
      ref.invalidate(scaleRecalculationProvider);
      messenger.showSnackBar(
        const SnackBar(content: Text('Pesata salvata nello storico.')),
      );
    } on FormatException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Non riesco a salvare la pesata.')),
      );
    }
  }
}

class _CompositionBlock extends StatelessWidget {
  const _CompositionBlock({required this.preview});

  final ScalePreview preview;

  @override
  Widget build(BuildContext context) {
    if (preview.profileIncomplete) {
      return const AppEmptyState(
        key: Key('scale_profile_incomplete'),
        icon: Icons.badge_outlined,
        message:
            'Per calcolare la composizione servono altezza, data di nascita e '
            'sesso nel profilo. Senza, resta il peso — che è comunque un dato '
            'buono.',
        compact: true,
      );
    }
    if (preview.outOfRange) {
      return const AppEmptyState(
        key: Key('scale_out_of_range'),
        icon: Icons.help_outline_rounded,
        message:
            'L’impedenza letta è fuori dai valori in cui la formula ha senso: '
            'probabilmente il contatto era parziale. Il peso vale, la '
            'composizione no.',
        compact: true,
      );
    }
    final composition = preview.composition;
    if (composition == null) {
      return const AppEmptyState(
        key: Key('scale_weight_only'),
        icon: Icons.water_drop_outlined,
        message:
            'Senza impedenza non si separa la massa grassa dalla magra. Il '
            'peso entra nelle medie, la composizione no.',
        compact: true,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StatRow(
          key: const Key('scale_lean_row'),
          label: 'Massa magra',
          value: BodyFormats.kg(composition.fatFreeMassKg),
          unit: 'kg',
          unitSemantics: 'chilogrammi',
          caption: 'È la metrica guida: il traguardo si misura su questa.',
        ),
        const SizedBox(height: 10),
        StatRow(
          key: const Key('scale_fat_row'),
          label: 'Grasso',
          value: BodyFormats.percent(composition.bodyFatPct),
          unit: '%',
          unitSemantics: 'per cento',
          caption:
              '${BodyFormats.kg(composition.fatMassKg)} kg di massa '
              'grassa',
        ),
        const SizedBox(height: 10),
        StatRow(
          key: const Key('scale_water_row'),
          label: 'Acqua',
          value: BodyFormats.percent(composition.waterPct),
          unit: '%',
          unitSemantics: 'per cento',
        ),
        const SizedBox(height: 10),
        StatRow(
          key: const Key('scale_bmr_row'),
          label: 'Metabolismo basale',
          value: '${composition.bmrKcal}',
          unit: 'kcal',
          unitSemantics: 'chilocalorie',
          caption: 'Katch-McArdle sulla massa magra.',
        ),
      ],
    );
  }
}

/// L'onestà dichiarata, non nascosta in una nota a piè di pagina.
class _HonestyCard extends StatelessWidget {
  const _HonestyCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final formula = BiaFormulas.current;

    return SectionCard(
      title: 'Come nascono questi numeri',
      icon: Icons.functions_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Dalla bilancia arriva solo l’impedenza. Le percentuali le calcola '
            'l’app con ${formula.label} (${formula.version}); il metabolismo '
            'basale con Katch-McArdle sulla massa magra.',
            key: const Key('scale_formula_note'),
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
          ),
          const SizedBox(height: 10),
          Text(
            formula.rationale,
            style: theme.textTheme.bodySmall?.copyWith(
              color: accents.mutedInk,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 12),
          DecoratedBox(
            decoration: BoxDecoration(
              color: accents.infoSurface,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 20,
                    color: accents.info,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'La BIA piede-piede misura soprattutto la parte bassa '
                      'del corpo, e i numeri non coincideranno con quelli '
                      'dell’app Renpho: il valore assoluto è indicativo, il '
                      'trend è affidabile.',
                      key: const Key('scale_honesty_note'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: accents.info,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Il ricalcolo dello storico quando la formula cambia versione.
class _RecalculationCard extends ConsumerWidget {
  const _RecalculationCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(scaleRecalculationProvider).valueOrNull ?? 0;
    if (pending == 0) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);

    return SectionCard(
      key: const Key('scale_recalculation_card'),
      title: 'Storico da rifare',
      icon: Icons.history_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            pending == 1
                ? 'Una pesata è stata calcolata con una versione precedente '
                      'della formula.'
                : '$pending pesate sono state calcolate con una versione '
                      'precedente della formula.',
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
          ),
          const SizedBox(height: 6),
          Text(
            'Si rifanno dall’impedenza salvata, che non è cambiata. Le pesate '
            'inserite a mano e quelle importate non si toccano: quei numeri '
            'non sono nostri da riscrivere.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppAccents.of(context).mutedInk,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.tonalIcon(
            key: const Key('scale_recalculate_button'),
            onPressed: () => _recalculate(context, ref),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Rifai i calcoli'),
          ),
        ],
      ),
    );
  }

  Future<void> _recalculate(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final profile = await ref.read(marcoProfileProvider.future);
      final done = await ref
          .read(bodyRepositoryProvider)
          .recalculateComposition(
            profileId: profile.id,
            heightCm: profile.heightCm,
            birthDate: profile.birthDate,
            sexCode: profile.sex,
          );
      ref.invalidate(scaleRecalculationProvider);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            done == 0
                ? 'Niente da rifare: mancano i dati del profilo.'
                : 'Rifatte $done pesate con la formula corrente.',
          ),
        ),
      );
    } on Object {
      messenger.showSnackBar(
        const SnackBar(content: Text('Non riesco a rifare i calcoli.')),
      );
    }
  }
}

/// Il diario di bordo della sessione.
class _LogCard extends StatelessWidget {
  const _LogCard({required this.log});

  final List<ScaleLogEntry> log;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return SectionCard(
      title: 'Registro della sessione',
      subtitle: 'Serve quando qualcosa non va',
      icon: Icons.terminal_rounded,
      actionLabel: log.isEmpty ? null : 'Copia',
      onAction: log.isEmpty
          ? null
          : () {
              final messenger = ScaffoldMessenger.of(context);
              Clipboard.setData(
                ClipboardData(
                  text: log.map((entry) => entry.toString()).join('\n'),
                ),
              );
              messenger.showSnackBar(
                const SnackBar(content: Text('Registro copiato.')),
              );
            },
      child: log.isEmpty
          ? const AppEmptyState(
              key: Key('scale_log_empty'),
              icon: Icons.notes_rounded,
              message:
                  'Qui compariranno le trame scambiate con la bilancia, in '
                  'chiaro e in esadecimale.',
              compact: true,
            )
          : Column(
              key: const Key('scale_log'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final entry in log.reversed.take(30))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.message,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: entry.isProblem
                                ? accents.critical
                                : theme.colorScheme.onSurface,
                            fontWeight: entry.isProblem
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                        if (entry.hex case final hex?)
                          Text(
                            hex,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: accents.mutedInk,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
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
