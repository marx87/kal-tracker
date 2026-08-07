import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:kal_tracker/core/presentation/design_system.dart';
import 'package:kal_tracker/core/time/app_time.dart';
import 'package:kal_tracker/features/training_profile/domain/training_profile.dart';
import 'package:kal_tracker/features/training_profile/presentation/limitation_sheet.dart';
import 'package:kal_tracker/features/training_profile/presentation/training_profile_providers.dart';

/// **Impostazioni.** La settima area: quella che possiede il profilo di
/// allenamento.
///
/// Attrezzatura, limitazioni e disponibilità non appartengono a nessuna delle
/// sei aree esistenti — stanno in mezzo, e servono a tutte: al catalogo per
/// sapere cosa proporre, alla scheda per sapere cosa evitare, al coach per
/// sapere quanto puoi allenarti. Finché non hanno una casa restano dati che
/// nessuno può cambiare.
///
/// **Niente qui è obbligatorio.** Senza risposte l'app non filtra niente: la
/// lista vuota è silenzio, non un «non ho attrezzi» — e quando un dato resta
/// fuori dai conti, questa schermata lo dice invece di lasciarlo intuire.
class TrainingSettingsScreen extends ConsumerWidget {
  const TrainingSettingsScreen({super.key});

  /// Il nome della rotta, per chi vorrà aggiungere una scorciatoia dalla
  /// propria barra in alto senza andarselo a cercare nel router.
  static const routeName = 'training-settings';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final profile = ref.watch(trainingProfileProvider);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Impostazioni'),
            Text(
              'Attrezzatura, limitazioni e disponibilità',
              style: theme.textTheme.bodySmall?.copyWith(
                color: accents.mutedInk,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
      body: profile.when(
        data: (value) => _SettingsForm(profile: value),
        loading: () => const Center(
          key: Key('training_settings_loading'),
          child: CircularProgressIndicator(),
        ),
        error: (error, stackTrace) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: AppEmptyState(
              key: const Key('training_settings_error'),
              icon: Icons.cloud_off_rounded,
              title: 'Non riesco a leggere il profilo',
              message:
                  'I dati sono sul dispositivo e non si perdono: riprova a '
                  'caricarli.',
              actionLabel: 'Riprova',
              onAction: () => ref.invalidate(trainingProfileProvider),
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsForm extends ConsumerStatefulWidget {
  const _SettingsForm({required this.profile});

  final TrainingProfile profile;

  @override
  ConsumerState<_SettingsForm> createState() => _SettingsFormState();
}

class _SettingsFormState extends ConsumerState<_SettingsForm> {
  static const _suggestedSessions = 3;
  static const _suggestedMinutes = 60;

  late Set<Equipment> _equipment;
  late Set<TrainingDay> _days;
  late DeloadPreference _deload;
  int? _sessions;
  int? _minutes;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final profile = widget.profile;
    _equipment = {...profile.equipment};
    _days = {...profile.preferredDays};
    _deload = profile.deloadPreference;
    _sessions = profile.sessionsPerWeek;
    _minutes = profile.minutesPerSession;
  }

  // Nessun `didUpdateWidget` che ri-semina il modulo: lo stream del profilo
  // riemette a ogni limitazione aperta o chiusa, e quelle si salvano subito.
  // Ricopiare il profilo salvato dentro il modulo a ogni emissione
  // cancellerebbe le caselle che Marco ha appena spuntato e non ha ancora
  // salvato. Questa schermata è l'unica che scrive quei campi: se un giorno
  // lo farà anche la sincronizzazione, il modo giusto sarà avvisare, non
  // sovrascrivere in silenzio.

  bool get _dirty {
    final saved = widget.profile;
    return !setEquals(_equipment, saved.equipment) ||
        !setEquals(_days, saved.preferredDays.toSet()) ||
        _deload != saved.deloadPreference ||
        _sessions != saved.sessionsPerWeek ||
        _minutes != saved.minutesPerSession;
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;
    final active = profile.activeLimitations;
    final closed = profile.limitations
        .where((limitation) => !limitation.isActive)
        .toList(growable: false);

    return AdaptiveContent(
      child: ListView(
        key: const Key('training_settings_list'),
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 32),
        children: [
          const _Intro(),
          const SizedBox(height: 16),
          _EquipmentSection(
            selected: _equipment,
            onToggle: (item) => setState(
              () => _equipment.contains(item)
                  ? _equipment.remove(item)
                  : _equipment.add(item),
            ),
          ),
          const SizedBox(height: 14),
          _LimitationsSection(
            active: active,
            closed: closed,
            unreadable: profile.unreadableLimitations,
            onAdd: _addLimitation,
            onResolve: _resolve,
            onReopen: _reopen,
          ),
          const SizedBox(height: 14),
          _AvailabilitySection(
            sessions: _sessions,
            minutes: _minutes,
            days: _days,
            onSessions: (value) => setState(() => _sessions = value),
            onMinutes: (value) => setState(() => _minutes = value),
            onToggleDay: (day) => setState(
              () => _days.contains(day) ? _days.remove(day) : _days.add(day),
            ),
            suggestedSessions: _suggestedSessions,
            suggestedMinutes: _suggestedMinutes,
          ),
          const SizedBox(height: 14),
          _DeloadSection(
            value: _deload,
            onChanged: (value) => setState(() => _deload = value),
          ),
          const SizedBox(height: 22),
          FilledButton(
            key: const Key('training_settings_save_button'),
            onPressed: _saving || !_dirty ? null : _save,
            child: const Text('Salva'),
          ),
          const SizedBox(height: 8),
          const _SaveFootnote(),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await ref
          .read(trainingProfileRepositoryProvider)
          .saveProfile(
            widget.profile.copyWith(
              equipment: _equipment,
              // Sempre in ordine di settimana: l'ordine in cui sono state
              // toccate le caselle non è un'informazione da conservare.
              preferredDays: TrainingDay.values
                  .where(_days.contains)
                  .toList(growable: false),
              deloadPreference: _deload,
              sessionsPerWeek: _sessions,
              minutesPerSession: _minutes,
              clearSessionsPerWeek: _sessions == null,
              clearMinutesPerSession: _minutes == null,
            ),
          );
    } on Object {
      if (mounted) {
        setState(() => _saving = false);
      }
      _say(
        messenger,
        const Text('Non riesco a salvare: il profilo resta quello di prima.'),
      );
      return;
    }
    if (mounted) {
      setState(() => _saving = false);
    }
    _say(messenger, Text(_confirmation()));
  }

  /// Un messaggio alla volta.
  ///
  /// Chiudere prima quello di adesso non è cosmetica: due messaggi in fila
  /// finiscono in coda, e il timer di chiusura del secondo arriva mentre a
  /// schermo c'è ancora il primo — che per `ScaffoldMessenger` è un errore.
  void _say(ScaffoldMessengerState messenger, Widget content) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: content));
  }

  /// Non «fatto», ma cosa cambia adesso.
  String _confirmation() {
    if (_equipment.isEmpty) {
      return 'Salvato. Senza attrezzatura dichiarata il catalogo resta '
          'intero: niente viene escluso.';
    }
    return 'Salvato. Da adesso l\'app propone solo quello che puoi fare con '
        'quello che hai.';
  }

  Future<void> _addLimitation() async {
    final draft = await showModalBottomSheet<LimitationDraft>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => const LimitationSheet(),
    );
    if (draft == null || !mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(trainingProfileRepositoryProvider)
          .addLimitation(
            profileId: widget.profile.profileId,
            bodyPart: draft.bodyPart,
            severity: draft.severity,
            note: draft.note,
          );
    } on Object {
      _say(messenger, const Text('Non riesco ad aprire la limitazione.'));
      return;
    }
    _say(
      messenger,
      Text(
        '${draft.bodyPart.label}: da adesso il catalogo la tiene in conto. '
        'Resta aperta finché non la chiudi tu.',
      ),
    );
  }

  Future<void> _resolve(TrainingLimitation limitation) async {
    final repository = ref.read(trainingProfileRepositoryProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await repository.resolveLimitation(limitation.id);
    } on Object {
      _say(messenger, const Text('Non riesco a chiuderla.'));
      return;
    }
    // Con l'azione «Annulla» la SnackBar di Material 3 non si chiuderebbe mai
    // da sola: questa la chiude comunque, lasciando il tempo di toccarla.
    messenger.hideCurrentSnackBar();
    showAutoClosingSnackBar(
      messenger,
      SnackBar(
        content: Text(
          '${limitation.bodyPart.label}: chiusa. Non toglie più niente dal '
          'catalogo, ma resta nello storico.',
        ),
        action: SnackBarAction(
          label: 'Annulla',
          onPressed: () => repository.reopenLimitation(limitation.id),
        ),
      ),
    );
  }

  Future<void> _reopen(TrainingLimitation limitation) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(trainingProfileRepositoryProvider)
          .reopenLimitation(limitation.id);
    } on Object {
      _say(messenger, const Text('Non riesco a riaprirla.'));
      return;
    }
    _say(
      messenger,
      Text(
        '${limitation.bodyPart.label}: riaperta, con la sua storia di prima.',
      ),
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return Text(
      'Chi sei come atleta: cosa hai in casa, cosa ti fa male, quanto puoi '
      'allenarti. Serve al catalogo e alle schede per proporti solo quello '
      'che puoi fare davvero.',
      style: theme.textTheme.bodyMedium?.copyWith(
        color: accents.mutedInk,
        height: 1.4,
      ),
    );
  }
}

class _SaveFootnote extends StatelessWidget {
  const _SaveFootnote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return Text(
      'Attrezzatura, disponibilità e scarico si salvano con questo tasto. Le '
      'limitazioni no: valgono appena le apri o le chiudi.',
      style: theme.textTheme.bodySmall?.copyWith(
        color: accents.mutedInk,
        height: 1.35,
      ),
    );
  }
}

class _EquipmentSection extends StatelessWidget {
  const _EquipmentSection({required this.selected, required this.onToggle});

  final Set<Equipment> selected;
  final ValueChanged<Equipment> onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return SectionCard(
      title: 'Attrezzatura',
      subtitle: 'Quello che hai davvero sotto mano, non quello che vorresti',
      icon: Icons.fitness_center_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // In una `Wrap` di pastiglie e non in una colonna di nove caselle:
          // con il testo al 150 % nove righe sono uno scorrimento, e qui
          // vanno a capo invece di traboccare.
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final item in Equipment.values)
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: FilterChip(
                    key: Key('training_equipment_${item.name}'),
                    selected: selected.contains(item),
                    // La spunta è il segnale ridondante al colore: la
                    // selezione si vede anche senza distinguere il verde.
                    showCheckmark: true,
                    label: Text(item.label),
                    labelPadding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 8,
                    ),
                    onSelected: (_) => onToggle(item),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            selected.isEmpty
                ? 'Non hai ancora risposto, e infatti non escludo niente: il '
                      'catalogo resta intero. Se ti alleni senza attrezzi, '
                      'dillo scegliendo «Corpo libero» — è una risposta, il '
                      'vuoto no.'
                : 'Fuori dal catalogo resta quello che chiede un attrezzo che '
                      'non hai spuntato.',
            key: const Key('training_equipment_declaration'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: accents.mutedInk,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

class _LimitationsSection extends StatelessWidget {
  const _LimitationsSection({
    required this.active,
    required this.closed,
    required this.unreadable,
    required this.onAdd,
    required this.onResolve,
    required this.onReopen,
  });

  final List<TrainingLimitation> active;
  final List<TrainingLimitation> closed;
  final int unreadable;
  final VoidCallback onAdd;
  final ValueChanged<TrainingLimitation> onResolve;
  final ValueChanged<TrainingLimitation> onReopen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return SectionCard(
      title: 'Limitazioni attive',
      subtitle: 'Cosa oggi non si può caricare',
      icon: Icons.healing_rounded,
      actionLabel: 'Aggiungi',
      onAction: onAdd,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (unreadable > 0) ...[
            _UnreadableNotice(count: unreadable),
            const SizedBox(height: 12),
          ],
          if (active.isEmpty)
            const AppEmptyState(
              key: Key('training_limitations_empty'),
              compact: true,
              icon: Icons.check_circle_outline_rounded,
              message:
                  'Nessuna limitazione aperta: il catalogo non viene filtrato.',
            )
          else
            for (final limitation in active) ...[
              _LimitationTile(
                limitation: limitation,
                onResolve: () => onResolve(limitation),
              ),
              const SizedBox(height: 10),
            ],
          const SizedBox(height: 4),
          Text(
            'Nessuna scadenza automatica: una limitazione resta aperta finché '
            'non sei tu a chiuderla.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: accents.mutedInk,
              height: 1.35,
            ),
          ),
          if (closed.isNotEmpty) ...[
            const SizedBox(height: 14),
            Semantics(
              header: true,
              child: Text('Chiuse', style: theme.textTheme.titleSmall),
            ),
            const SizedBox(height: 2),
            Text(
              'Non filtrano più niente. Restano qui perché spiegano le schede '
              'di quel periodo.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: accents.mutedInk,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 10),
            for (final limitation in closed) ...[
              _ClosedLimitationTile(
                limitation: limitation,
                onReopen: () => onReopen(limitation),
              ),
              const SizedBox(height: 8),
            ],
          ],
        ],
      ),
    );
  }
}

/// Le righe che questa versione dell'app non sa leggere si contano e si
/// dicono: lo screening sta filtrando con meno informazioni di quante ce ne
/// sono, e nasconderlo sarebbe peggio del non averle.
class _UnreadableNotice extends StatelessWidget {
  const _UnreadableNotice({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final text = count == 1
        ? 'C\'è una limitazione che questa versione dell\'app non sa leggere: '
              'non compare qui sotto e non filtra il catalogo.'
        : 'Ci sono $count limitazioni che questa versione dell\'app non sa '
              'leggere: non compaiono qui sotto e non filtrano il catalogo.';

    return Semantics(
      container: true,
      label: text,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: accents.warningSurface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: accents.warning,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  key: const Key('training_unreadable_notice'),
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LimitationTile extends StatelessWidget {
  const _LimitationTile({required this.limitation, required this.onResolve});

  final TrainingLimitation limitation;
  final VoidCallback onResolve;

  static AppStatusLevel _levelOf(LimitationSeverity severity) =>
      switch (severity) {
        LimitationSeverity.fastidio => AppStatusLevel.warning,
        LimitationSeverity.dolore => AppStatusLevel.critical,
        LimitationSeverity.stop => AppStatusLevel.critical,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final since = DateFormat(
      'd MMMM y',
      'it',
    ).format(AppTime.inRome(limitation.startedAt));

    return Container(
      key: Key('training_limitation_${limitation.id}'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Titolo e pastiglia in una `Wrap`: al 150 % «Ginocchio sinistro»
          // più «Fastidio» non stanno su una riga, e qui vanno a capo.
          Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                limitation.bodyPart.label,
                style: theme.textTheme.titleSmall,
              ),
              StatusChip(
                level: _levelOf(limitation.severity),
                label: limitation.severity.label,
                compact: true,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            limitation.severity.description,
            style: theme.textTheme.bodySmall?.copyWith(
              color: accents.mutedInk,
              height: 1.35,
            ),
          ),
          if (limitation.note case final note?) ...[
            const SizedBox(height: 6),
            Text(
              '«$note»',
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
            ),
          ],
          const SizedBox(height: 6),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              Text(
                'Aperta dal $since',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: accents.mutedInk,
                ),
              ),
              TextButton(
                key: Key('training_close_limitation_${limitation.id}'),
                onPressed: onResolve,
                child: const Text('Chiudi'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ClosedLimitationTile extends StatelessWidget {
  const _ClosedLimitationTile({
    required this.limitation,
    required this.onReopen,
  });

  final TrainingLimitation limitation;
  final VoidCallback onReopen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final closedAt = limitation.resolvedAt;
    final when = closedAt == null
        ? ''
        : DateFormat('d MMMM y', 'it').format(AppTime.inRome(closedAt));

    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: [
        Text(
          when.isEmpty
              ? limitation.bodyPart.label
              : '${limitation.bodyPart.label} · chiusa il $when',
          style: theme.textTheme.bodySmall?.copyWith(color: accents.mutedInk),
        ),
        TextButton(
          key: Key('training_reopen_limitation_${limitation.id}'),
          onPressed: onReopen,
          child: const Text('Riapri'),
        ),
      ],
    );
  }
}

class _AvailabilitySection extends StatelessWidget {
  const _AvailabilitySection({
    required this.sessions,
    required this.minutes,
    required this.days,
    required this.onSessions,
    required this.onMinutes,
    required this.onToggleDay,
    required this.suggestedSessions,
    required this.suggestedMinutes,
  });

  final int? sessions;
  final int? minutes;
  final Set<TrainingDay> days;
  final ValueChanged<int?> onSessions;
  final ValueChanged<int?> onMinutes;
  final ValueChanged<TrainingDay> onToggleDay;
  final int suggestedSessions;
  final int suggestedMinutes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return SectionCard(
      title: 'Disponibilità',
      subtitle: 'Quanto puoi allenarti, e quando',
      icon: Icons.event_available_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CountRow(
            fieldKey: 'training_sessions',
            label: 'Sessioni a settimana',
            hint: 'Quelle che reggi davvero, non quelle che vorresti.',
            value: sessions,
            // Gli stessi limiti dei CHECK del database: qui non si arriva a
            // un valore che poi verrebbe rifiutato al salvataggio.
            minimum: 1,
            maximum: 14,
            step: 1,
            suggested: suggestedSessions,
            unit: (value) =>
                value == 1 ? '1 a settimana' : '$value a settimana',
            onChanged: onSessions,
          ),
          const SizedBox(height: 16),
          _CountRow(
            fieldKey: 'training_minutes',
            label: 'Minuti a sessione',
            hint: 'Quanto dura una seduta, riscaldamento compreso.',
            value: minutes,
            minimum: 10,
            maximum: 300,
            step: 15,
            suggested: suggestedMinutes,
            unit: (value) => '$value minuti',
            onChanged: onMinutes,
          ),
          const SizedBox(height: 18),
          Semantics(
            header: true,
            child: Text('Giorni preferiti', style: theme.textTheme.titleSmall),
          ),
          const SizedBox(height: 2),
          Text(
            'Una preferenza, non un vincolo: nessuno ti sposta un allenamento '
            'perché è di martedì.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: accents.mutedInk,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final day in TrainingDay.values)
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: FilterChip(
                    key: Key('training_day_${day.name}'),
                    selected: days.contains(day),
                    showCheckmark: true,
                    label: Text(day.label),
                    labelPadding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 8,
                    ),
                    onSelected: (_) => onToggleDay(day),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Un numero che si muove a passi, con la possibilità di non rispondere.
///
/// Passi e non cursore: un cursore da 1 a 14 chiede una precisione che il
/// pollice non ha, e con il testo grande l'etichetta del valore finirebbe
/// sopra la manopola. «Non indicato» è uno stato pieno — vuol dire «non l'ho
/// ancora deciso» — e va poter essere scelto anche dopo aver risposto.
class _CountRow extends StatelessWidget {
  const _CountRow({
    required this.fieldKey,
    required this.label,
    required this.hint,
    required this.value,
    required this.minimum,
    required this.maximum,
    required this.step,
    required this.suggested,
    required this.unit,
    required this.onChanged,
  });

  final String fieldKey;
  final String label;
  final String hint;
  final int? value;
  final int minimum;
  final int maximum;
  final int step;

  /// Il valore da cui si parte quando non c'è ancora una risposta.
  final int suggested;

  final String Function(int value) unit;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);
    final current = value;
    final text = current == null ? 'Non indicato' : unit(current);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(label, style: theme.textTheme.titleSmall),
        ),
        const SizedBox(height: 2),
        Text(
          hint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: accents.mutedInk,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 6),
        Semantics(
          container: true,
          label: label,
          value: text,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  text,
                  key: Key('${fieldKey}_value'),
                  style: theme.textTheme.titleMedium,
                ),
              ),
              IconButton.outlined(
                key: Key('${fieldKey}_decrease'),
                tooltip: 'Diminuisci: $label',
                onPressed: current == null || current <= minimum
                    ? null
                    : () => onChanged(_clamp(current - step)),
                icon: const Icon(Icons.remove_rounded),
              ),
              const SizedBox(width: 8),
              IconButton.outlined(
                key: Key('${fieldKey}_increase'),
                tooltip: 'Aumenta: $label',
                onPressed: current != null && current >= maximum
                    ? null
                    : () => onChanged(
                        current == null ? suggested : _clamp(current + step),
                      ),
                icon: const Icon(Icons.add_rounded),
              ),
            ],
          ),
        ),
        if (current != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: Key('${fieldKey}_clear'),
              onPressed: () => onChanged(null),
              child: const Text('Non indicare'),
            ),
          ),
      ],
    );
  }

  int _clamp(int value) => value.clamp(minimum, maximum);
}

class _DeloadSection extends StatelessWidget {
  const _DeloadSection({required this.value, required this.onChanged});

  final DeloadPreference value;
  final ValueChanged<DeloadPreference> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accents = AppAccents.of(context);

    return SectionCard(
      title: 'Scarico',
      subtitle: 'Cosa fare quando la settimana va alleggerita',
      icon: Icons.battery_charging_full_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // **Va detto che oggi non fa niente.** La preferenza si salva e si
          // sincronizza, ma il motore dello scarico non esiste ancora:
          // un'impostazione che promette un comportamento inesistente è
          // peggio di un'impostazione assente, perché chi la sceglie smette
          // di guardare quel problema credendo di averlo delegato.
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Per ora la scelta si registra e basta: lo scarico automatico '
              'non è ancora scritto, quindi in entrambi i casi decidi tu. '
              'Quando arriverà, questa preferenza sarà già a posto.',
              key: const Key('training_deload_not_wired_note'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: accents.mutedInk,
                height: 1.4,
              ),
            ),
          ),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final option in DeloadPreference.values)
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: ChoiceChip(
                    key: Key('training_deload_${option.name}'),
                    selected: option == value,
                    showCheckmark: true,
                    label: Text(option.label),
                    labelPadding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 8,
                    ),
                    onSelected: (_) => onChanged(option),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            value.description,
            key: const Key('training_deload_description'),
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
          ),
          const SizedBox(height: 6),
          Text(
            'Si parte da «Chiedimelo prima»: l\'app propone, tu confermi. '
            '«Applicalo da solo» esiste perché puoi sceglierlo, non perché ti '
            'capiti addosso.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: accents.mutedInk,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}
